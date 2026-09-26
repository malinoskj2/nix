#define WLR_USE_UNSTABLE

#include <algorithm>
#include <any>
#include <cmath>
#include <optional>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

#include <hyprland/src/includes.hpp>

#define private public
#define protected public
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/animation/AnimationManager.hpp>
#include <hyprland/src/config/shared/animation/AnimationTree.hpp>
#include <hyprland/src/config/values/types/FloatValue.hpp>
#include <hyprland/src/config/values/types/StringValue.hpp>
#include <hyprland/src/config/values/types/Vec2Value.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/WindowFadeout.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/output/MonitorResources.hpp>
#include <hyprland/src/protocols/XDGShell.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/ClearPassElement.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
#include <hyprland/src/render/transformer/Transformer.hpp>
#undef protected
#undef private

#include <hyprland/src/plugins/PluginAPI.hpp>

using Desktop::View::IGeometric;

inline HANDLE PHANDLE = nullptr;

static struct {
    SP<Config::Values::CStringValue> windowClass;
    SP<Config::Values::CFloatValue>  parentShare;
    SP<Config::Values::CVec2Value>   minSize;
} configValues;

class CSheetTransformer;

// A window from its creation until it maps, in case it turns out to be a chooser. The parent is only a
// guess from focus, for clients that don't name one through xdg-foreign.
struct SPendingChooser {
    PHLWINDOWREF        chooser;
    PHLWINDOWREF        focusedParent;
    CHyprSignalListener commit;
    bool                committed = false;
    bool                isChooser = false;
};

// An open chooser and the window drawn scaled into it. `progress` runs from 0, the parent in its own
// box, to 1, the parent inside `into`, the chooser's box. While it opens and closes, both windows are
// drawn in the same box between the two, the parent fading out as the chooser fades in. In between,
// the parent is hidden.
struct SSheet {
    PHLWINDOWREF        chooser;
    PHLWINDOWREF        parent;
    CBox                into;
    PHLANIMVAR<float>   progress;
    CSheetTransformer*  parentTransformer  = nullptr;
    CSheetTransformer*  chooserTransformer = nullptr;
    bool                closing            = false;
    bool                parentHidden       = false;
    std::optional<bool> savedNoBlur;
};

static std::vector<UP<SPendingChooser>> pendingChoosers;
static std::vector<UP<SSheet>>          sheets;
static std::vector<CHyprSignalListener> listeners;
static CFunctionHook*                   fadeoutCreateHook = nullptr;

static bool                             isChooserClass(const std::string& cls) {
    const auto PATTERN = configValues.windowClass->value();
    if (PATTERN.empty())
        return false;

    // an invalid regex must not throw inside the compositor
    try {
        return std::regex_match(cls, std::regex(PATTERN));
    } catch (const std::regex_error&) { return false; }
}

static SSheet* sheetFor(const PHLWINDOW& w, bool asParent) {
    const auto IT = std::ranges::find_if(sheets, [&](const auto& s) { return (asParent ? s->parent : s->chooser).get() == w.get(); });
    return IT == sheets.end() ? nullptr : IT->get();
}

static bool alive(SSheet* sheet) {
    return std::ranges::any_of(sheets, [sheet](const auto& s) { return s.get() == sheet; });
}

static CBox lerpBox(const CBox& a, const CBox& b, float t) {
    return {a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.w + (b.w - a.w) * t, a.h + (b.h - a.h) * t};
}

static CBox currentBox(const PHLWINDOW& w) {
    return {w->position(IGeometric::GEOMETRIC_CURRENT), w->size(IGeometric::GEOMETRIC_CURRENT)};
}

// Draws a window's already rendered frame again, scaled from its own box into the sheet's current box
// and faded. Borders, shadows, subsurfaces and the blur matte are all in that frame, so they scale
// with it, and neither window is ever resized.
class CSheetTransformer : public Render::IWindowTransformer {
  public:
    CSheetTransformer(SSheet* sheet, PHLWINDOWREF window, bool isParent) : m_sheet(sheet), m_window(window), m_isParent(isParent) {}

    virtual SP<Render::IFramebuffer> transform(SP<Render::IFramebuffer> in) override {
        const auto WINDOW  = m_window.lock();
        const auto PARENT  = m_sheet->parent.lock();
        const auto MONITOR = g_pHyprRenderer->m_renderData.pMonitor.lock();
        if (!WINDOW || !PARENT || !MONITOR || !in || !in->getTexture())
            return in;

        const auto OWN = currentBox(WINDOW);
        if (OWN.w <= 0 || OWN.h <= 0)
            return in;

        const auto OUT = MONITOR->resources()->getUnusedWorkBuffer();
        if (!OUT)
            return in;

        const auto    GUARD = g_pHyprRenderer->bindTempFB(OUT);
        const CRegion FULL  = CBox{Vector2D{}, MONITOR->m_transformedSize};
        g_pHyprRenderer->draw(CClearPassElement::SClearData{CHyprColor(0, 0, 0, 0)}, FULL);

        const float PROGRESS = m_sheet->progress->value();
        const float ALPHA    = std::clamp(m_isParent ? 1.F - PROGRESS : PROGRESS, 0.F, 1.F);
        if (ALPHA <= 0.F)
            return OUT;

        const auto WORKSPACE = WINDOW->m_workspace;
        const auto OFFSET    = (WINDOW->m_pinned || !WORKSPACE ? Vector2D{} : WORKSPACE->m_renderOffset->value()) + WINDOW->m_floatingOffset - MONITOR->m_position;
        const auto FROM      = OWN.copy().translate(OFFSET).scale(MONITOR->m_scale);
        const auto TO        = lerpBox(currentBox(PARENT), m_sheet->into, PROGRESS).translate(OFFSET).scale(MONITOR->m_scale);
        const auto SCALE     = Vector2D{TO.w / FROM.w, TO.h / FROM.h};

        // Hyprland renders the window into `in` only within its full bounding box, so nothing outside
        // that box's scaled copy needs drawing. `out` is a reused buffer, so all of it is cleared.
        const auto BOUNDS = WINDOW->getFullWindowBoundingBox().translate(OFFSET).scale(MONITOR->m_scale).round().expand(2);
        const auto DRAWN  = CBox{TO.x + (BOUNDS.x - FROM.x) * SCALE.x, TO.y + (BOUNDS.y - FROM.y) * SCALE.y, BOUNDS.w * SCALE.x, BOUNDS.h * SCALE.y}.expand(2).round();

        CTexPassElement::SRenderData data;
        data.tex = in->getTexture();
        data.box = {TO.x - FROM.x * SCALE.x, TO.y - FROM.y * SCALE.y, MONITOR->m_transformedSize.x * SCALE.x, MONITOR->m_transformedSize.y * SCALE.y};
        data.a   = ALPHA;
        g_pHyprRenderer->draw(data, CRegion{DRAWN}.intersect(FULL));

        return OUT;
    }

  private:
    SSheet*      m_sheet;
    PHLWINDOWREF m_window;
    bool         m_isParent;
};

static void attach(SSheet* sheet, const PHLWINDOW& w, CSheetTransformer*& slot, bool isParent) {
    auto transformer = makeUnique<CSheetTransformer>(sheet, w, isParent);
    slot             = transformer.get();
    w->m_transformers.emplace_back(std::move(transformer));
}

static void detach(const PHLWINDOWREF& w, CSheetTransformer*& slot) {
    if (const auto WINDOW = w.lock(); WINDOW && slot)
        std::erase_if(WINDOW->m_transformers, [slot](const auto& t) { return t.get() == slot; });
    slot = nullptr;
}

// Hyprland skips a window at alpha 0 entirely: it isn't drawn, and its surfaces get no frame callbacks,
// so a busy parent stops drawing too. Of the alphas always part of the drawn one, only the
// move-from-workspace alpha is left alone while the window stays mapped on one workspace; groups and
// monocle layouts set the layout alpha themselves.
static void hideParent(SSheet* sheet) {
    const auto PARENT = sheet->parent.lock();
    if (!PARENT || sheet->parentHidden)
        return;

    detach(sheet->parent, sheet->parentTransformer);
    PARENT->alpha(Desktop::View::WINDOW_ALPHA_MOVE_FROM_WORKSPACE)->setValueAndWarp(0.F);
    sheet->parentHidden = true;
}

static void showParent(SSheet* sheet) {
    if (!sheet->parentHidden)
        return;

    sheet->parentHidden = false;
    if (const auto PARENT = sheet->parent.lock())
        PARENT->alpha(Desktop::View::WINDOW_ALPHA_MOVE_FROM_WORKSPACE)->setValueAndWarp(1.F);
}

static void damageSheet(SSheet* sheet) {
    if (const auto PARENT = sheet->parent.lock())
        g_pHyprRenderer->damageWindow(PARENT, true);

    g_pHyprRenderer->damageBox(sheet->into.copy().expand(4));
}

static void removeSheet(SSheet* sheet) {
    damageSheet(sheet);
    detach(sheet->chooser, sheet->chooserTransformer);
    detach(sheet->parent, sheet->parentTransformer);
    showParent(sheet);

    if (const auto PARENT = sheet->parent.lock()) {
        auto& noBlur = PARENT->m_ruleApplicator->noBlur();
        if (sheet->savedNoBlur)
            noBlur.set(*sheet->savedNoBlur, Desktop::Types::PRIORITY_SET_PROP);
        else
            noBlur.unset(Desktop::Types::PRIORITY_SET_PROP);
    }

    std::erase_if(sheets, [sheet](const auto& s) { return s.get() == sheet; });
}

// Once the chooser has opened it draws itself again and the parent is hidden; once it has closed the
// sheet is done. Animation callbacks can't free the variable that runs them, so this waits for the
// event loop.
static void onProgressEnd(SSheet* sheet) {
    g_pEventLoopManager->doLater([sheet] {
        if (!alive(sheet))
            return;

        if (sheet->closing)
            removeSheet(sheet);
        else {
            damageSheet(sheet);
            detach(sheet->chooser, sheet->chooserTransformer);
            hideParent(sheet);
        }
    });
}

static std::optional<Vector2D> chooserSizeFor(const PHLWINDOW& parent) {
    const auto SIZE = parent->size(IGeometric::GEOMETRIC_GOAL);
    if (SIZE.x <= 0 || SIZE.y <= 0)
        return std::nullopt;

    const auto SHARE = configValues.parentShare->value();
    const auto MIN   = configValues.minSize->value();
    return Vector2D{std::floor(std::max<double>(SIZE.x * SHARE, MIN.x)), std::floor(std::max<double>(SIZE.y * SHARE, MIN.y))};
}

// The size goes out in the chooser's first configure, so GTK draws its very first frame at it.
static void onInitialCommit(SPendingChooser* pending) {
    pending->committed = true;

    const auto CHOOSER = pending->chooser.lock();
    if (!CHOOSER || !CHOOSER->m_xdgSurface || !CHOOSER->m_xdgSurface->m_toplevel)
        return;

    const auto TOPLEVEL = CHOOSER->m_xdgSurface->m_toplevel.lock();
    if (!isChooserClass(TOPLEVEL->m_state.appid))
        return;

    pending->isChooser = true;

    auto parent = CHOOSER->parent();
    if (!parent) {
        const auto FOCUSED = Desktop::focusState()->window();
        if (Desktop::View::validMapped(FOCUSED) && FOCUSED != CHOOSER && !FOCUSED->isX11OverrideRedirect() && !isChooserClass(FOCUSED->m_class))
            parent = FOCUSED;
        pending->focusedParent = parent;
    }

    if (!parent)
        return;

    if (const auto SIZE = chooserSizeFor(parent))
        TOPLEVEL->setSize(*SIZE);
}

static SPendingChooser* pendingFor(const PHLWINDOW& w) {
    const auto IT = std::ranges::find_if(pendingChoosers, [&](const auto& p) { return p->chooser.get() == w.get(); });
    return IT == pendingChoosers.end() ? nullptr : IT->get();
}

static void onWindowCreate(PHLWINDOW w) {
    if (w->m_isX11 || !w->m_xdgSurface)
        return;

    auto pending     = makeUnique<SPendingChooser>();
    pending->chooser = w;
    auto* raw        = pending.get();
    pending->commit  = w->m_xdgSurface->m_events.commit.listen([raw] {
        if (!raw->committed)
            onInitialCommit(raw);
    });
    pendingChoosers.emplace_back(std::move(pending));
}

static PHLWINDOW parentFor(const PHLWINDOW& chooser) {
    if (const auto PARENT = chooser->parent())
        return PARENT;

    if (const auto PENDING = pendingFor(chooser))
        return PENDING->focusedParent.lock();

    return nullptr;
}

static bool sheetable(const PHLWINDOW& chooser, const PHLWINDOW& parent) {
    return Desktop::View::validMapped(parent) && parent != chooser && chooser->m_isFloating && parent->m_workspace && parent->m_workspace == chooser->m_workspace &&
        !sheetFor(parent, true) && !sheetFor(parent, false);
}

// Hyprland centres a chooser only on a parent named through xdg-foreign, and not within the monitor:
// GTK won't shrink the chooser below its own minimum, which can be wider than a narrow parent.
static void onWindowOpen(PHLWINDOW w) {
    const auto PENDING = pendingFor(w);
    if (!PENDING || !PENDING->isChooser)
        return;

    const auto PARENT  = parentFor(w);
    const auto MONITOR = w->m_monitor.lock();
    if (!PARENT || !MONITOR || !sheetable(w, PARENT))
        return;

    const auto AREA   = MONITOR->logicalBoxMinusReserved();
    const auto SIZE   = w->size(IGeometric::GEOMETRIC_GOAL);
    const auto CENTER = PARENT->position(IGeometric::GEOMETRIC_GOAL) + PARENT->size(IGeometric::GEOMETRIC_GOAL) / 2.F;
    const auto POS    = (CENTER - SIZE / 2.F).round();
    const auto CLAMPED =
        Vector2D{std::max(AREA.x, std::min(POS.x, AREA.x + AREA.w - SIZE.x)), std::max(AREA.y, std::min(POS.y, AREA.y + AREA.h - SIZE.y))};

    g_layoutManager->moveTarget(CLAMPED - w->position(IGeometric::GEOMETRIC_GOAL), w->layoutTarget());
}

// Runs after Hyprland has started the chooser's own open animation, which this replaces: both windows
// stay where they are, and only their drawing moves.
static void onWindowOpenLate(PHLWINDOW w) {
    const auto PENDING = pendingFor(w);
    if (!PENDING)
        return;

    const auto PARENT = PENDING->isChooser ? parentFor(w) : nullptr;
    std::erase_if(pendingChoosers, [&w](const auto& p) { return p->chooser.get() == w.get() || !p->chooser; });

    if (!PARENT || !sheetable(w, PARENT))
        return;

    auto  sheet    = makeUnique<SSheet>();
    auto* raw      = sheet.get();
    sheet->chooser = w;
    sheet->parent  = PARENT;
    sheet->into    = {w->position(IGeometric::GEOMETRIC_GOAL), w->size(IGeometric::GEOMETRIC_GOAL)};

    Animation::mgr()->createAnimation(0.F, sheet->progress, Config::animationTree()->getAnimationPropertyConfig("hyprsheetIn"), AVARDAMAGE_NONE);
    sheet->progress->setUpdateCallback([raw](auto) { damageSheet(raw); });

    // Hyprland draws a translucent window's blur at full strength whatever its alpha, so the fading
    // parent's blur would stay behind it.
    auto& noBlur       = PARENT->m_ruleApplicator->noBlur();
    sheet->savedNoBlur = noBlur.m_values[Desktop::Types::PRIORITY_SET_PROP];
    noBlur.set(true, Desktop::Types::PRIORITY_SET_PROP);

    attach(raw, PARENT, sheet->parentTransformer, true);
    attach(raw, w, sheet->chooserTransformer, false);

    w->positionAnimation()->warp();
    w->sizeAnimation()->warp();
    w->alpha(Desktop::View::WINDOW_ALPHA_FADE)->warp();

    // An end callback set on a variable at rest runs straight away, so it goes on once this has started.
    *sheet->progress = 1.F;
    sheet->progress->setCallbackOnEnd([raw](auto) { onProgressEnd(raw); }, false);
    sheets.emplace_back(std::move(sheet));
}

static void onWindowClose(PHLWINDOW w) {
    if (auto* sheet = sheetFor(w, true)) {
        // Hyprland snapshots the parent after this, still hidden or through its transformer, so a
        // hidden parent also closes hidden.
        sheet->closing = true;
        onProgressEnd(sheet);
        return;
    }

    auto* sheet = sheetFor(w, false);
    if (!sheet || sheet->closing)
        return;

    detach(sheet->chooser, sheet->chooserTransformer);
    if (sheet->parentHidden) {
        if (const auto PARENT = sheet->parent.lock())
            attach(sheet, PARENT, sheet->parentTransformer, true);
        showParent(sheet);
    }

    sheet->closing = true;
    sheet->into    = currentBox(w);
    sheet->progress->setConfig(Config::animationTree()->getAnimationPropertyConfig("hyprsheetOut"));
    *sheet->progress = 0.F;
}

typedef SP<Desktop::CWindowFadeout> (*origFadeoutCreate)(PHLWINDOW, SP<Render::IFramebuffer>, float);

// The closing chooser's snapshot grows back out into the parent's box on the curve the parent grows
// back on, and fades out as the parent fades in.
static SP<Desktop::CWindowFadeout> hkFadeoutCreate(PHLWINDOW window, SP<Render::IFramebuffer> snapshot, float sourceAlpha) {
    auto fadeout = ((origFadeoutCreate)fadeoutCreateHook->m_original)(window, snapshot, sourceAlpha);

    const auto* SHEET = window ? sheetFor(window, false) : nullptr;
    if (!fadeout || !SHEET || !SHEET->closing)
        return fadeout;

    const auto PARENT = SHEET->parent.lock();
    if (!PARENT)
        return fadeout;

    const auto POUT = Config::animationTree()->getAnimationPropertyConfig("hyprsheetOut");
    const auto TO   = currentBox(PARENT);

    auto       retarget = [&POUT](auto& var, const auto& goal) {
        var->setConfig(POUT);
        var->setValueAndWarp(var->value());
        *var = goal;
    };

    retarget(fadeout->m_realPosition, TO.pos());
    retarget(fadeout->m_realSize, TO.size());
    retarget(fadeout->m_alpha, 0.F);

    return fadeout;
}

// A chooser that is gone without closing would leave its parent hidden.
static void onWindowDestroy() {
    std::erase_if(pendingChoosers, [](const auto& p) { return !p->chooser; });

    std::vector<SSheet*> orphaned;
    for (const auto& s : sheets) {
        if (!s->parent || (!s->chooser && !s->closing))
            orphaned.emplace_back(s.get());
    }

    for (auto* sheet : orphaned)
        removeSheet(sheet);
}

// Either window leaving the workspace the two share ends the sheet at once.
static void onWindowMoveToWorkspace(PHLWINDOW w) {
    auto* sheet = sheetFor(w, true);
    if (!sheet)
        sheet = sheetFor(w, false);

    if (sheet)
        removeSheet(sheet);
}

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    if (std::string{__hyprland_api_get_hash()} != __hyprland_api_get_client_hash()) {
        HyprlandAPI::addNotification(PHANDLE, "[hyprsheet] Version mismatch (headers ver is not equal to running hyprland ver)", CHyprColor{1.0, 0.2, 0.2, 1.0}, 5000);
        throw std::runtime_error("[hyprsheet] Version mismatch");
    }

    // Hyprland pairs matches with demangled names by a line count that drifts past any symbol dlsym
    // can't resolve, so this matches the mangled name.
    for (auto& fn : HyprlandAPI::findFunctionsByName(PHANDLE, "_ZN7Desktop14CWindowFadeout6createE")) {
        fadeoutCreateHook = HyprlandAPI::createFunctionHook(PHANDLE, fn.address, (void*)&hkFadeoutCreate);
        break;
    }

    if (!fadeoutCreateHook || !fadeoutCreateHook->hook()) {
        fadeoutCreateHook = nullptr;
        HyprlandAPI::addNotification(PHANDLE, "[hyprsheet] Failed to hook CWindowFadeout::create", CHyprColor{1.0, 0.2, 0.2, 1.0}, 5000);
        throw std::runtime_error("[hyprsheet] hook failed");
    }

    configValues.windowClass = makeShared<Config::Values::CStringValue>("plugin:hyprsheet:class", "regex for the class of chooser windows", "^(xdg-desktop-portal-gtk)$");
    configValues.parentShare =
        makeShared<Config::Values::CFloatValue>("plugin:hyprsheet:parent_share", "share of the parent's size a chooser takes", 0.75F, Config::Values::SFloatValueOptions{.min = 0.1F, .max = 1.F});
    configValues.minSize = makeShared<Config::Values::CVec2Value>("plugin:hyprsheet:min_size", "smallest size a chooser takes", Config::VEC2{700, 450});

    HyprlandAPI::addConfigValueV2(PHANDLE, configValues.windowClass);
    HyprlandAPI::addConfigValueV2(PHANDLE, configValues.parentShare);
    HyprlandAPI::addConfigValueV2(PHANDLE, configValues.minSize);

    // Like hyprfocus's, these nodes outlive an unload, and a reload just recreates them.
    Config::animationTree()->m_animationTree.createNode("hyprsheetIn", "windowsIn");
    Config::animationTree()->m_animationTree.createNode("hyprsheetOut", "windowsOut");

    listeners.emplace_back(Event::bus()->m_events.window.create.listen([](PHLWINDOW w) { onWindowCreate(w); }));
    listeners.emplace_back(Event::bus()->m_events.window.open.listen([](PHLWINDOW w) { onWindowOpen(w); }));
    listeners.emplace_back(Event::bus()->m_events.window.openLate.listen([](PHLWINDOW w) { onWindowOpenLate(w); }));
    listeners.emplace_back(Event::bus()->m_events.window.close.listen([](PHLWINDOW w) { onWindowClose(w); }));
    listeners.emplace_back(Event::bus()->m_events.window.destroy.listen([](PHLWINDOWREF) { onWindowDestroy(); }));
    listeners.emplace_back(Event::bus()->m_events.window.moveToWorkspace.listen([](PHLWINDOW w, PHLWORKSPACE) { onWindowMoveToWorkspace(w); }));

    return {"hyprsheet", "Draws a file chooser's parent scaled into it", "jesse", "1.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    listeners.clear();
    pendingChoosers.clear();

    while (!sheets.empty())
        removeSheet(sheets.back().get());
}
