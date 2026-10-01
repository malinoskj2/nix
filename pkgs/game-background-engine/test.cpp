#include <cassert>
#include <cstdio>
#include <pthread.h>
#include <atomic>
#include <time.h>
#include <sys/wait.h>
std::atomic<int> clock_calls{0};
int tracked_clock_gettime(clockid_t clock, timespec *value) {
    ++clock_calls;
    return clock_gettime(clock, value);
}
#define clock_gettime tracked_clock_gettime
#include "engine.cpp"
#undef clock_gettime

// Exercise graphics initialization before the preload's default constructor.
__attribute__((constructor(101))) void early_graphics() {
    graphics_started();
    instances[capacity - 1].key.store(reinterpret_cast<void *>(100));
}

namespace {
std::atomic<int> presented_one{0}, presented_two{0};
VkResult VKAPI_CALL present_one(VkQueue, const VkPresentInfoKHR *) { ++presented_one; return VK_SUCCESS; }
VkResult VKAPI_CALL present_two(VkQueue, const VkPresentInfoKHR *) { ++presented_two; return VK_SUBOPTIMAL_KHR; }
void *wait_frame(void *) { wait_if_capped(); return nullptr; }
struct FakeHandle { void *key; } fake_instance{reinterpret_cast<void *>(3)}, fake_device_one{reinterpret_cast<void *>(4)}, fake_device_two{reinterpret_cast<void *>(5)};
int created = 0, destroyed = 0;
VkResult VKAPI_CALL create_instance(const VkInstanceCreateInfo *info, const VkAllocationCallbacks *, VkInstance *output) {
    assert(instance_chain(info)->u.pLayerInfo == nullptr);
    *output = reinterpret_cast<VkInstance>(&fake_instance);
    return VK_SUCCESS;
}
void VKAPI_CALL destroy_instance(VkInstance, const VkAllocationCallbacks *) {}
VkResult VKAPI_CALL create_device(VkPhysicalDevice, const VkDeviceCreateInfo *info, const VkAllocationCallbacks *, VkDevice *output) {
    assert(device_chain(info)->u.pLayerInfo == nullptr);
    *output = reinterpret_cast<VkDevice>(created++ % 2 ? &fake_device_two : &fake_device_one);
    return VK_SUCCESS;
}
void VKAPI_CALL destroy_device(VkDevice, const VkAllocationCallbacks *) { ++destroyed; }
PFN_vkVoidFunction VKAPI_CALL device_gpa(VkDevice device, const char *name) {
    if (!strcmp(name, "vkDestroyDevice")) return reinterpret_cast<PFN_vkVoidFunction>(destroy_device);
    if (!strcmp(name, "vkQueuePresentKHR")) return reinterpret_cast<PFN_vkVoidFunction>(device == reinterpret_cast<VkDevice>(&fake_device_one) ? present_one : present_two);
    return nullptr;
}
PFN_vkVoidFunction VKAPI_CALL instance_gpa(VkInstance, const char *name) {
    if (!strcmp(name, "vkCreateInstance")) return reinterpret_cast<PFN_vkVoidFunction>(create_instance);
    if (!strcmp(name, "vkDestroyInstance")) return reinterpret_cast<PFN_vkVoidFunction>(destroy_instance);
    if (!strcmp(name, "vkCreateDevice")) return reinterpret_cast<PFN_vkVoidFunction>(create_device);
    if (!strcmp(name, "vkDestroyDevice")) return reinterpret_cast<PFN_vkVoidFunction>(destroy_device);
    return nullptr;
}
void lifecycle_test() {
    VkLayerInstanceLink link{}; link.pfnNextGetInstanceProcAddr = instance_gpa;
    VkLayerInstanceCreateInfo chain{}; chain.sType = VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO;
    chain.function = VK_LAYER_LINK_INFO; chain.u.pLayerInfo = &link;
    VkInstanceCreateInfo info{}; info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO; info.pNext = &chain;
    VkInstance instance;
    assert(background_CreateInstance(&info, nullptr, &instance) == VK_SUCCESS);
    assert(background_GetInstanceProcAddr(instance, "vkQueuePresentKHR") == nullptr);
    VkPhysicalDevice physical = reinterpret_cast<VkPhysicalDevice>(&fake_instance);
    auto make_device = [&]() {
        VkLayerDeviceLink next{}; next.pfnNextGetInstanceProcAddr = instance_gpa; next.pfnNextGetDeviceProcAddr = device_gpa;
        VkLayerDeviceCreateInfo device_chain_info{}; device_chain_info.sType = VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO;
        device_chain_info.function = VK_LAYER_LINK_INFO; device_chain_info.u.pLayerInfo = &next;
        VkDeviceCreateInfo device_info{}; device_info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO; device_info.pNext = &device_chain_info;
        VkDevice output;
        assert(background_CreateDevice(physical, &device_info, nullptr, &output) == VK_SUCCESS);
        return output;
    };
    auto first = make_device(), second = make_device();
    assert(background_GetDeviceProcAddr(first, "vkUnsupportedExtensionJESSE") == nullptr);
    assert(background_QueuePresentKHR(reinterpret_cast<VkQueue>(first), nullptr) == VK_SUCCESS);
    assert(background_QueuePresentKHR(reinterpret_cast<VkQueue>(second), nullptr) == VK_SUBOPTIMAL_KHR);
    auto destroy_first = reinterpret_cast<PFN_vkDestroyDevice>(background_GetInstanceProcAddr(instance, "vkDestroyDevice"));
    destroy_first(first, nullptr);
    assert(find(devices, first) == nullptr);
    auto recreated = make_device();
    assert(background_QueuePresentKHR(reinterpret_cast<VkQueue>(recreated), nullptr) == VK_SUCCESS);
    auto destroy_second = reinterpret_cast<PFN_vkDestroyDevice>(background_GetDeviceProcAddr(second, "vkDestroyDevice"));
    destroy_second(second, nullptr);
    background_DestroyDevice(recreated, nullptr);
    assert(destroyed == 3);
    background_DestroyInstance(instance, nullptr);
    assert(find(instances, instance) == nullptr);
}
}
int main(int argc, char **argv) {
    assert(instances[capacity - 1].key == reinterpret_cast<void *>(100));
    instances[capacity - 1].key.store(nullptr);
    if (argc == 2 && !strcmp(argv[1], "--guard")) {
        printf("%d %zu\n", eligible, strlen(token));
        return 0;
    }
    graphics_started();
    lifecycle_test();
    presented_one = 0; presented_two = 0;
    // Dispatch goes to the correct device without shared global next-present.
    void *key_one = reinterpret_cast<void *>(1), *key_two = reinterpret_cast<void *>(2);
    VkQueue queue_one = reinterpret_cast<VkQueue>(&key_one), queue_two = reinterpret_cast<VkQueue>(&key_two);
    devices[0].present = present_one; devices[0].key.store(key_one);
    devices[1].present = present_two; devices[1].key.store(key_two);
    assert(background_QueuePresentKHR(queue_one, nullptr) == VK_SUCCESS);
    assert(background_QueuePresentKHR(queue_two, nullptr) == VK_SUBOPTIMAL_KHR);
    assert(presented_one == 1 && presented_two == 1);
    assert(glXGetProcAddress(reinterpret_cast<const unsigned char *>("glXSwapBuffers")) == reinterpret_cast<Proc>(glXSwapBuffers));
    assert(glXGetProcAddressARB(reinterpret_cast<const unsigned char *>("glXSwapBuffers")) == reinterpret_cast<Proc>(glXSwapBuffers));
    assert(eglGetProcAddress("eglSwapBuffers") == reinterpret_cast<Proc>(eglSwapBuffers));
    assert(eglGetProcAddress("jesse_nonexistent_extension") == nullptr);
    const char *damage_names[] = {"eglSwapBuffersWithDamageKHR", "eglSwapBuffersWithDamageEXT"};
    for (auto name : damage_names) {
        auto downstream = gl_function<Proc (*)(const char *)>("eglGetProcAddress", "libEGL.so.1")(name);
        assert(eglGetProcAddress(name) == (downstream ? gl_hook(name) : nullptr));
    }
    // Holding the pacing lock proves focused calls don't acquire it.
    pthread_mutex_lock(&pace_mutex);
    int clocks_before = clock_calls.load();
    for (int i = 0; i < 1000000; ++i) wait_if_capped();
    assert(clock_calls == clocks_before);
    pthread_mutex_unlock(&pace_mutex);
    set_cap(true);
    int64_t start = nanos();
    wait_if_capped();
    assert(nanos() - start >= 95000000);
    start = nanos();
    for (int i = 0; i < 3; ++i) {
        timespec work{0, 30000000}; nanosleep(&work, nullptr);
        wait_if_capped();
    }
    assert(nanos() - start < 360000000);
    pthread_t thread;
    pthread_create(&thread, nullptr, wait_frame, nullptr);
    timespec delay{0, 10000000}; nanosleep(&delay, nullptr);
    start = nanos();
    set_cap(false);
    pthread_join(thread, nullptr);
    assert(nanos() - start < 50000000);
    // The fork child has no receiver and must bypass an inherited locked mutex.
    set_cap(true);
    pthread_mutex_lock(&pace_mutex);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) { wait_if_capped(); _exit(capped.load() ? 1 : 0); }
    pthread_mutex_unlock(&pace_mutex);
    int status;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    set_cap(false);
    puts("dispatch, GL proc-address, focused bypass, cap and interruptible release passed");
}
