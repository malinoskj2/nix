// Period/work pacing and Vulkan link-chain handling adapted from MangoHud.
// See LICENSE and SOURCES.md. No overlay or telemetry code is included.
#define _GNU_SOURCE 1
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <vulkan/vk_layer.h>

#define EXPORT extern "C" __attribute__((visibility("default")))

namespace {
std::atomic<bool> capped{false};
pthread_mutex_t pace_mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t pace_changed;
int64_t next_frame = 0;

pthread_once_t prepare_once = PTHREAD_ONCE_INIT;
bool eligible = false;
char token[33];
char socket_path[sizeof(sockaddr_un::sun_path)];

// Process eligibility and controller identity.
bool game_id(const char *value) {
    return value && *value && strspn(value, "0123456789") == strlen(value) &&
           strspn(value, "0") != strlen(value);
}

bool is_helper() {
    char path[PATH_MAX];
    auto length = readlink("/proc/self/exe", path, sizeof(path) - 1);
    if (length < 0) {
        return true;
    }
    path[length] = 0;
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    const char *names[] = {"steam",
                           "steamwebhelper",
                           "steamservice",
                           "steam_monitor",
                           "steam-runtime-launcher-service",
                           "steam-runtime-supervisor",
                           "steam-runtime-input-monitor",
                           "bwrap",
                           "pressure-vessel-wrap",
                           "pv-adverb",
                           "srt-logger",
                           nullptr};
    for (auto candidate : names) {
        if (!candidate) {
            break;
        }
        if (!strcmp(name, candidate)) {
            return true;
        }
    }
    return strstr(name, "-srt-launcher-service") != nullptr;
}

void prepare_body() {
    const char *off = getenv("GAME_BACKGROUND_LIMIT");
    if (off && !strcmp(off, "0")) {
        return;
    }
    const char *manual = getenv("GAME_BACKGROUND_FORCE");
    const char *automatic = getenv("GAME_BACKGROUND_LIMIT_AUTO");
    eligible = (manual && !strcmp(manual, "1")) ||
               (automatic && !strcmp(automatic, "1") &&
                (game_id(getenv("SteamAppId")) || game_id(getenv("SteamGameId"))) && !is_helper());
    if (!eligible) {
        return;
    }
    const char *inherited = getenv("GAME_BACKGROUND_LIMIT_ID");
    if (inherited && strlen(inherited) == 32 && strspn(inherited, "0123456789abcdef") == 32) {
        memcpy(token, inherited, 33);
    } else {
        unsigned char random[16];
        if (getrandom(random, sizeof(random), 0) != sizeof(random)) {
            eligible = false;
            return;
        }
        for (size_t i = 0; i < sizeof(random); ++i) {
            snprintf(token + 2 * i, 3, "%02x", random[i]);
        }
        setenv("GAME_BACKGROUND_LIMIT_ID", token, 1);
    }
    const char *override_path = getenv("GAME_BACKGROUND_LIMIT_SOCKET");
    const char *cache = getenv("XDG_CACHE_HOME");
    const char *home = getenv("HOME");
    int size = -1;
    if (override_path) {
        size = snprintf(socket_path, sizeof(socket_path), "%s", override_path);
    } else if (cache && *cache) {
        size = snprintf(socket_path, sizeof(socket_path), "%s/game-background-limit/control.sock", cache);
    } else if (home && *home) {
        size =
            snprintf(socket_path, sizeof(socket_path), "%s/.cache/game-background-limit/control.sock", home);
    }
    if (size < 0 || size >= int(sizeof(socket_path))) {
        eligible = false;
    }
}

void fork_child() {
    // Graphics drivers generally require fork -> exec. A continued-rendering
    // child has no receiver thread, so leave it uncapped even if the parent was
    // sleeping or held the pacing mutex when it forked.
    capped.store(false, std::memory_order_relaxed);
}

__attribute__((constructor)) void prepare() {
    pthread_once(&prepare_once, prepare_body);
}

// Background pacing. Focused presentation bypasses this state.
int64_t nanos() {
    timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return int64_t(now.tv_sec) * 1000000000 + now.tv_nsec;
}

void set_cap(bool enabled) {
    pthread_mutex_lock(&pace_mutex);
    capped.store(enabled, std::memory_order_relaxed);
    if (!enabled) {
        next_frame = 0;
    }
    pthread_cond_broadcast(&pace_changed);
    pthread_mutex_unlock(&pace_mutex);
}

void wait_if_capped() {
    // This is the complete focused timing path: no clocks, locks or waits.
    if (!capped.load(std::memory_order_relaxed)) {
        return;
    }
    pthread_mutex_lock(&pace_mutex);
    if (capped.load(std::memory_order_relaxed)) {
        int64_t now = nanos();
        if (!next_frame) {
            next_frame = now + 100000000;
        } else {
            next_frame += 100000000;
            if (next_frame < now) {
                next_frame = now;
            }
        }
        const int64_t target = next_frame;
        const timespec deadline{time_t(target / 1000000000), long(target % 1000000000)};
        while (capped.load(std::memory_order_relaxed) && nanos() < target) {
            if (pthread_cond_timedwait(&pace_changed, &pace_mutex, &deadline) == ETIMEDOUT) {
                break;
            }
        }
    }
    pthread_mutex_unlock(&pace_mutex);
}

// Controller transport runs only on the detached receiver thread.
bool connect_controller(int fd) {
    if (fd < 0) {
        return false;
    }
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, socket_path, strlen(socket_path) + 1);
    if (connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0) {
        return false;
    }
    ucred peer{};
    socklen_t size = sizeof(peer);
    return getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &size) == 0 && peer.uid == getuid();
}

void read_control(int fd) {
    char greeting[40];
    int length = snprintf(greeting, sizeof(greeting), "v1 %s\n", token);
    if (send(fd, greeting, length, MSG_NOSIGNAL) != length) {
        return;
    }
    char commands[128];
    ssize_t count;
    while ((count = recv(fd, commands, sizeof(commands), 0)) > 0) {
        for (ssize_t i = 0; i < count; ++i) {
            switch (commands[i]) {
            case 'F':
                set_cap(false);
                break;
            case 'B':
                set_cap(true);
                break;
            default:
                return;
            }
        }
    }
}

void *receive_control(void *) {
    while (true) {
        int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (connect_controller(fd)) {
            read_control(fd);
        }
        set_cap(false);
        if (fd >= 0) {
            close(fd);
        }
        // Only the disconnected receiver retries; focused presentation never polls.
        timespec retry{1, 0};
        nanosleep(&retry, nullptr);
    }
    return nullptr;
}

pthread_once_t control_once = PTHREAD_ONCE_INIT;
std::atomic<bool> graphics_ready{false};

void start_control() {
    prepare();
    pthread_atfork(nullptr, nullptr, fork_child);
    pthread_condattr_t attributes;
    pthread_condattr_init(&attributes);
    pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC);
    pthread_cond_init(&pace_changed, &attributes);
    pthread_condattr_destroy(&attributes);
    if (eligible) {
        pthread_t thread;
        if (pthread_create(&thread, nullptr, receive_control, nullptr) == 0) {
            pthread_detach(thread);
        }
    }
}

void graphics_started() {
    if (!graphics_ready.load(std::memory_order_acquire)) {
        pthread_once(&control_once, start_control);
        graphics_ready.store(true, std::memory_order_release);
    }
}

template <class Function> Function gl_function(const char *name, const char *library) {
    auto function = reinterpret_cast<Function>(dlsym(RTLD_NEXT, name));
    if (!function) {
        void *handle = dlopen(library, RTLD_NOW | RTLD_LOCAL);
        if (handle) {
            function = reinterpret_cast<Function>(dlsym(handle, name));
        }
    }
    return function;
}

using Proc = void (*)();
// No C++ ABI static-initialization guards or libstdc++ dependency. Publishing
// identical downstream pointers concurrently is safe; steady swaps only load it.
template <class Function, class Lookup>
Function cached_function(std::atomic<Function> &cache, Lookup lookup) {
    auto real = cache.load(std::memory_order_acquire);
    if (!real) {
        graphics_started();
        real = lookup();
        cache.store(real, std::memory_order_release);
    }
    return real;
}

} // namespace

EXPORT void glXSwapBuffers(void *display, unsigned long drawable) {
    using Function = void (*)(void *, unsigned long);
    static std::atomic<Function> cache{nullptr};
    auto real = cached_function(cache, [] { return gl_function<Function>("glXSwapBuffers", "libGL.so.1"); });
    if (real) {
        real(display, drawable);
    }
    wait_if_capped();
}

EXPORT int64_t glXSwapBuffersMscOML(void *display, unsigned long drawable, int64_t target, int64_t divisor,
                                    int64_t remainder) {
    using Function = int64_t (*)(void *, unsigned long, int64_t, int64_t, int64_t);
    static std::atomic<Function> cache{nullptr};
    auto real =
        cached_function(cache, [] { return gl_function<Function>("glXSwapBuffersMscOML", "libGL.so.1"); });
    auto result = real ? real(display, drawable, target, divisor, remainder) : 0;
    wait_if_capped();
    return result;
}

EXPORT unsigned int eglSwapBuffers(void *display, void *surface) {
    using Function = unsigned int (*)(void *, void *);
    static std::atomic<Function> cache{nullptr};
    auto real = cached_function(cache, [] { return gl_function<Function>("eglSwapBuffers", "libEGL.so.1"); });
    auto result = real ? real(display, surface) : 0;
    wait_if_capped();
    return result;
}

namespace {
using DamageSwap = unsigned int (*)(void *, void *, const int *, int);
DamageSwap damage_function(const char *name) {
    auto real = gl_function<DamageSwap>(name, "libEGL.so.1");
    if (!real) {
        auto get = gl_function<Proc (*)(const char *)>("eglGetProcAddress", "libEGL.so.1");
        if (get) {
            real = reinterpret_cast<DamageSwap>(get(name));
        }
    }
    return real;
}
} // namespace

EXPORT unsigned int eglSwapBuffersWithDamageKHR(void *display, void *surface, const int *rectangles,
                                                int count) {
    static std::atomic<DamageSwap> cache{nullptr};
    auto real = cached_function(cache, [] { return damage_function("eglSwapBuffersWithDamageKHR"); });
    auto result = real ? real(display, surface, rectangles, count) : 0;
    wait_if_capped();
    return result;
}

EXPORT unsigned int eglSwapBuffersWithDamageEXT(void *display, void *surface, const int *rectangles,
                                                int count) {
    static std::atomic<DamageSwap> cache{nullptr};
    auto real = cached_function(cache, [] { return damage_function("eglSwapBuffersWithDamageEXT"); });
    auto result = real ? real(display, surface, rectangles, count) : 0;
    wait_if_capped();
    return result;
}

EXPORT Proc glXGetProcAddress(const unsigned char *name);
EXPORT Proc glXGetProcAddressARB(const unsigned char *name);
EXPORT Proc eglGetProcAddress(const char *name);
namespace {
Proc gl_hook(const char *name) {
    if (!strcmp(name, "glXSwapBuffers")) {
        return reinterpret_cast<Proc>(glXSwapBuffers);
    }
    if (!strcmp(name, "glXSwapBuffersMscOML")) {
        return reinterpret_cast<Proc>(glXSwapBuffersMscOML);
    }
    if (!strcmp(name, "eglSwapBuffers")) {
        return reinterpret_cast<Proc>(eglSwapBuffers);
    }
    if (!strcmp(name, "eglSwapBuffersWithDamageKHR")) {
        return reinterpret_cast<Proc>(eglSwapBuffersWithDamageKHR);
    }
    if (!strcmp(name, "eglSwapBuffersWithDamageEXT")) {
        return reinterpret_cast<Proc>(eglSwapBuffersWithDamageEXT);
    }
    if (!strcmp(name, "glXGetProcAddress")) {
        return reinterpret_cast<Proc>(glXGetProcAddress);
    }
    if (!strcmp(name, "glXGetProcAddressARB")) {
        return reinterpret_cast<Proc>(glXGetProcAddressARB);
    }
    if (!strcmp(name, "eglGetProcAddress")) {
        return reinterpret_cast<Proc>(eglGetProcAddress);
    }
    return nullptr;
}
} // namespace

EXPORT Proc glXGetProcAddress(const unsigned char *name) {
    using Function = Proc (*)(const unsigned char *);
    static std::atomic<Function> cache{nullptr};
    auto real =
        cached_function(cache, [] { return gl_function<Function>("glXGetProcAddress", "libGL.so.1"); });
    auto function = real ? real(name) : nullptr;
    if (function) {
        if (auto hooked = gl_hook(reinterpret_cast<const char *>(name))) {
            return hooked;
        }
    }
    return function;
}

EXPORT Proc glXGetProcAddressARB(const unsigned char *name) {
    using Function = Proc (*)(const unsigned char *);
    static std::atomic<Function> cache{nullptr};
    auto real =
        cached_function(cache, [] { return gl_function<Function>("glXGetProcAddressARB", "libGL.so.1"); });
    auto function = real ? real(name) : nullptr;
    if (function) {
        if (auto hooked = gl_hook(reinterpret_cast<const char *>(name))) {
            return hooked;
        }
    }
    return function;
}

EXPORT Proc eglGetProcAddress(const char *name) {
    using Function = Proc (*)(const char *);
    static std::atomic<Function> cache{nullptr};
    auto real =
        cached_function(cache, [] { return gl_function<Function>("eglGetProcAddress", "libEGL.so.1"); });
    auto function = real ? real(name) : nullptr;
    if (function) {
        if (auto hooked = gl_hook(name)) {
            return hooked;
        }
    }
    return function;
}

namespace {
// Dispatchable queue/device handles share a loader dispatch key. Slots are
// published only after initialization. Vulkan requires external synchronization
// of destruction; no device is concurrently destroyed while its queues present.
constexpr size_t capacity = 256;
struct Instance {
    std::atomic<void *> key{nullptr};
    VkInstance handle;
    PFN_vkGetInstanceProcAddr gpa;
    PFN_GetPhysicalDeviceProcAddr physical_gpa;
};
struct Device {
    std::atomic<void *> key{nullptr};
    VkDevice handle;
    PFN_vkGetDeviceProcAddr gpa;
    PFN_vkQueuePresentKHR present;
};
// Value-initialize every field so these arrays require no dynamic constructor
// that could erase a registration made by an earlier linked-DSO constructor.
Instance instances[capacity]{};
Device devices[capacity]{};
pthread_mutex_t dispatch_mutex = PTHREAD_MUTEX_INITIALIZER;
template <class Handle> void *dispatch_key(Handle handle) {
    return handle ? *reinterpret_cast<void **>(handle) : nullptr;
}
template <class Entry, class Handle> Entry *find(Entry (&entries)[capacity], Handle handle) {
    auto key = dispatch_key(handle);
    if (key) {
        for (auto &entry : entries) {
            if (entry.key.load(std::memory_order_acquire) == key) {
                return &entry;
            }
        }
    }
    return nullptr;
}
// Called with dispatch_mutex held; the key is published after the slot is filled.
template <class Entry> Entry *vacant_slot(Entry (&entries)[capacity]) {
    for (auto &entry : entries) {
        if (!entry.key.load()) {
            return &entry;
        }
    }
    return nullptr;
}

template <class Handle> VkLayerInstanceCreateInfo *instance_chain(Handle info) {
    auto next = reinterpret_cast<const VkLayerInstanceCreateInfo *>(info->pNext);
    while (next) {
        if (next->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO &&
            next->function == VK_LAYER_LINK_INFO) {
            return const_cast<VkLayerInstanceCreateInfo *>(next);
        }
        next = reinterpret_cast<const VkLayerInstanceCreateInfo *>(next->pNext);
    }
    return nullptr;
}
VkLayerDeviceCreateInfo *device_chain(const VkDeviceCreateInfo *info) {
    auto next = reinterpret_cast<const VkLayerDeviceCreateInfo *>(info->pNext);
    while (next) {
        if (next->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO &&
            next->function == VK_LAYER_LINK_INFO) {
            return const_cast<VkLayerDeviceCreateInfo *>(next);
        }
        next = reinterpret_cast<const VkLayerDeviceCreateInfo *>(next->pNext);
    }
    return nullptr;
}
} // namespace

EXPORT PFN_vkVoidFunction VKAPI_CALL background_GetInstanceProcAddr(VkInstance, const char *);
EXPORT PFN_vkVoidFunction VKAPI_CALL background_GetDeviceProcAddr(VkDevice, const char *);

EXPORT VkResult VKAPI_CALL background_CreateInstance(const VkInstanceCreateInfo *info,
                                                     const VkAllocationCallbacks *allocator,
                                                     VkInstance *output) {
    auto chain = instance_chain(info);
    if (!chain || !chain->u.pLayerInfo) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    auto gpa = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    auto physical_gpa = chain->u.pLayerInfo->pfnNextGetPhysicalDeviceProcAddr;
    auto create = reinterpret_cast<PFN_vkCreateInstance>(gpa(nullptr, "vkCreateInstance"));
    chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;
    if (!create) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    auto result = create(info, allocator, output);
    if (result != VK_SUCCESS) {
        return result;
    }
    pthread_mutex_lock(&dispatch_mutex);
    auto slot = vacant_slot(instances);
    if (slot) {
        slot->handle = *output;
        slot->gpa = gpa;
        slot->physical_gpa = physical_gpa;
        slot->key.store(dispatch_key(*output), std::memory_order_release);
    }
    pthread_mutex_unlock(&dispatch_mutex);
    if (!slot) {
        auto destroy = reinterpret_cast<PFN_vkDestroyInstance>(gpa(*output, "vkDestroyInstance"));
        destroy(*output, allocator);
        return VK_ERROR_TOO_MANY_OBJECTS;
    }
    graphics_started();
    return result;
}

EXPORT void VKAPI_CALL background_DestroyInstance(VkInstance instance,
                                                  const VkAllocationCallbacks *allocator) {
    auto entry = find(instances, instance);
    if (!entry) {
        return;
    }
    auto destroy = reinterpret_cast<PFN_vkDestroyInstance>(entry->gpa(instance, "vkDestroyInstance"));
    destroy(instance, allocator);
    entry->key.store(nullptr, std::memory_order_release);
}

EXPORT VkResult VKAPI_CALL background_CreateDevice(VkPhysicalDevice physical, const VkDeviceCreateInfo *info,
                                                   const VkAllocationCallbacks *allocator, VkDevice *output) {
    auto chain = device_chain(info);
    auto owner = find(instances, physical);
    if (!chain || !chain->u.pLayerInfo || !owner) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    auto gpa = chain->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    auto create = reinterpret_cast<PFN_vkCreateDevice>(
        chain->u.pLayerInfo->pfnNextGetInstanceProcAddr(owner->handle, "vkCreateDevice"));
    chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;
    if (!create) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    auto result = create(physical, info, allocator, output);
    if (result != VK_SUCCESS) {
        return result;
    }
    pthread_mutex_lock(&dispatch_mutex);
    auto slot = vacant_slot(devices);
    if (slot) {
        slot->handle = *output;
        slot->gpa = gpa;
        slot->present = reinterpret_cast<PFN_vkQueuePresentKHR>(gpa(*output, "vkQueuePresentKHR"));
        slot->key.store(dispatch_key(*output), std::memory_order_release);
    }
    pthread_mutex_unlock(&dispatch_mutex);
    if (!slot) {
        auto destroy = reinterpret_cast<PFN_vkDestroyDevice>(gpa(*output, "vkDestroyDevice"));
        destroy(*output, allocator);
        return VK_ERROR_TOO_MANY_OBJECTS;
    }
    return result;
}

EXPORT void VKAPI_CALL background_DestroyDevice(VkDevice device, const VkAllocationCallbacks *allocator) {
    auto entry = find(devices, device);
    if (!entry) {
        return;
    }
    auto destroy = reinterpret_cast<PFN_vkDestroyDevice>(entry->gpa(device, "vkDestroyDevice"));
    destroy(device, allocator);
    entry->key.store(nullptr, std::memory_order_release);
}

EXPORT VkResult VKAPI_CALL background_QueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *info) {
    auto entry = find(devices, queue);
    if (!entry || !entry->present) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    auto result = entry->present(queue, info);
    wait_if_capped();
    return result;
}

EXPORT PFN_vkVoidFunction VKAPI_CALL background_GetDeviceProcAddr(VkDevice device, const char *name) {
    if (!name) {
        return nullptr;
    }
    if (!strcmp(name, "vkGetDeviceProcAddr")) {
        return reinterpret_cast<PFN_vkVoidFunction>(background_GetDeviceProcAddr);
    }
    auto entry = find(devices, device);
    if (!entry) {
        return nullptr;
    }
    if (!strcmp(name, "vkDestroyDevice")) {
        return reinterpret_cast<PFN_vkVoidFunction>(background_DestroyDevice);
    }
    if (!strcmp(name, "vkQueuePresentKHR") && entry->present) {
        return reinterpret_cast<PFN_vkVoidFunction>(background_QueuePresentKHR);
    }
    return entry->gpa(device, name);
}

EXPORT PFN_vkVoidFunction VKAPI_CALL background_GetInstanceProcAddr(VkInstance instance, const char *name) {
    if (!name) {
        return nullptr;
    }
    if (!strcmp(name, "vkGetInstanceProcAddr")) {
        return reinterpret_cast<PFN_vkVoidFunction>(background_GetInstanceProcAddr);
    }
    if (!strcmp(name, "vkCreateInstance")) {
        return reinterpret_cast<PFN_vkVoidFunction>(background_CreateInstance);
    }
    auto entry = find(instances, instance);
    if (!entry) {
        return nullptr;
    }
    if (!strcmp(name, "vkCreateDevice")) {
        return reinterpret_cast<PFN_vkVoidFunction>(background_CreateDevice);
    }
    if (!strcmp(name, "vkDestroyInstance")) {
        return reinterpret_cast<PFN_vkVoidFunction>(background_DestroyInstance);
    }
    if (!strcmp(name, "vkDestroyDevice")) {
        return reinterpret_cast<PFN_vkVoidFunction>(background_DestroyDevice);
    }
    if (!strcmp(name, "vkGetDeviceProcAddr")) {
        return reinterpret_cast<PFN_vkVoidFunction>(background_GetDeviceProcAddr);
    }
    if (!strcmp(name, "vkQueuePresentKHR") && entry->gpa(instance, name)) {
        return reinterpret_cast<PFN_vkVoidFunction>(background_QueuePresentKHR);
    }
    return entry->gpa(instance, name);
}

EXPORT PFN_vkVoidFunction VKAPI_CALL background_GetPhysicalDeviceProcAddr(VkInstance instance,
                                                                          const char *name) {
    auto entry = find(instances, instance);
    if (!entry || !name) {
        return nullptr;
    }
    return entry->physical_gpa ? entry->physical_gpa(instance, name) : entry->gpa(instance, name);
}

EXPORT VkResult VKAPI_CALL vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *version) {
    if (!version || version->sType != LAYER_NEGOTIATE_INTERFACE_STRUCT) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    if (version->loaderLayerInterfaceVersion > 2) {
        version->loaderLayerInterfaceVersion = 2;
    }
    version->pfnGetInstanceProcAddr = background_GetInstanceProcAddr;
    version->pfnGetDeviceProcAddr = background_GetDeviceProcAddr;
    version->pfnGetPhysicalDeviceProcAddr = background_GetPhysicalDeviceProcAddr;
    return VK_SUCCESS;
}
