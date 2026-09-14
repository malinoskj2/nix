local actions = require("actions")

local terminal = "alacritty"
local browser = "firefox"
local dbclient = "datagrip"
local editor = "zeditor"
local main_mod = "SUPER"

hl.monitor({
    output = "DP-1",
    mode = "1920x1080@144",
    position = "0x0",
    scale = 1,
    transform = 1,
    disabled = false,
})

hl.monitor({
    output = "DP-2",
    mode = "1920x1080@360",
    position = "1080x0",
    scale = 1,
    disabled = false,
})

hl.env("XCURSOR_SIZE", "24")
hl.env("LIBVA_DRIVER_NAME", "nvidia")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("GBM_BACKEND", "nvidia-drm")
hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
hl.env("NVD_BACKEND", "direct")

hl.config({
    general = {
        gaps_in = 5,
        gaps_out = 20,
        border_size = 2,
        col = {
            active_border = {
                colors = { "rgba(fab387fc)", "rgba(89dcebfc)" },
                angle = 150,
            },
            inactive_border = "rgba(595959aa)",
        },
        resize_on_border = true,
        allow_tearing = true,
        layout = "master",
    },
    cursor = {
        sync_gsettings_theme = true,
        enable_hyprcursor = false,
    },
    decoration = {
        rounding = 10,
        active_opacity = 1.0,
        inactive_opacity = 1.0,
        blur = {
            enabled = true,
            size = 8,
            passes = 3,
            noise = 0.02,
            vibrancy = 0.2,
        },
        shadow = {
            enabled = true,
            range = 32,
            render_power = 3,
            color = "rgba(00000059)",
        },
    },
    render = {
        expand_undersized_textures = false,
    },
    animations = {
        enabled = true,
    },
    master = {
        new_status = "slave",
    },
    misc = {
        force_default_wallpaper = 0,
        disable_hyprland_logo = true,
    },
    input = {
        kb_layout = "us",
        kb_variant = "",
        kb_model = "",
        kb_options = "",
        kb_rules = "",
        follow_mouse = 0,
        accel_profile = "flat",
        sensitivity = 0,
        touchpad = {
            natural_scroll = false,
        },
        repeat_delay = 260,
        repeat_rate = 24,
    },
    xwayland = {
        enabled = true,
    },
})

local noctalia_layers = "^noctalia-(bar-.+|notification|dock|panel|attached-panel|osd|window-switcher)$"
local translucent_noctalia_layers = "^noctalia-(notification|dock|osd|window-switcher)$"
local glass_noctalia_layers = "^noctalia-(bar-.+|panel|attached-panel)$"

hl.layer_rule({
    match = { namespace = noctalia_layers },
    blur = true,
    blur_popups = true,
    no_anim = true,
})
hl.layer_rule({
    match = { namespace = translucent_noctalia_layers },
    ignore_alpha = 0.5,
})
hl.layer_rule({
    match = { namespace = glass_noctalia_layers },
    ignore_alpha = 0.02,
})
hl.layer_rule({
    match = { namespace = "^noctalia-bar-.+$" },
    xray = true,
})
hl.layer_rule({
    match = { namespace = "^noctalia-desktop-widget-jesse/control-button:.+$" },
    blur = true,
    ignore_alpha = 0.05,
})

hl.curve("myBezier", {
    type = "bezier",
    points = { { 0.05, 0.9 }, { 0.1, 1.05 } },
})
hl.animation({ leaf = "windows", enabled = true, speed = 7, bezier = "myBezier" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 7, bezier = "default", style = "popin 80%" })
hl.animation({ leaf = "border", enabled = true, speed = 10, bezier = "default" })
hl.animation({ leaf = "borderangle", enabled = true, speed = 8, bezier = "default" })
hl.animation({ leaf = "fadeOut", enabled = false, speed = 1, bezier = "default" })
hl.animation({ leaf = "fadeSwitch", enabled = true, speed = 3, bezier = "linear" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 6, bezier = "default" })

hl.plugin.load("@hyprfocus@")
hl.config({
    plugin = {
        hyprfocus = {
            class = "^.*$",
            keyboard_focus_animation = "shrink",
            mouse_focus_animation = "shrink",
            shrink_percentage = 0.99,
        },
    },
})
hl.curve("hyprfocusDip", {
    type = "bezier",
    points = { { 0.25, 1 }, { 0.5, 1 } },
})
hl.animation({ leaf = "hyprfocusIn", enabled = true, speed = 1.5, bezier = "hyprfocusDip" })
hl.animation({ leaf = "hyprfocusOut", enabled = true, speed = 4, bezier = "hyprfocusDip" })

hl.plugin.load("@hyprbars@")
hl.config({
    plugin = {
        hyprbars = {
            bar_color = "rgba(11111b8c)",
            bar_blur = false,
            bar_height = 12,
            col = { text = "rgb(d7dae0)" },
            bar_title_enabled = false,
            bar_text_size = 15,
            bar_text_weight = 600,
            bar_text_font = "SF Pro Display",
            bar_text_align = "center",
            bar_part_of_window = true,
            bar_precedence_over_border = true,
            -- `hyprctl dispatch` takes hl.dsp syntax under a Lua config.
            on_double_click = [[hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "maximized" })']],
        },
    },
})

hl.on("hyprland.start", function()
    -- Keep randomization ahead of Noctalia: its mpvpaper plugin reads the
    -- assignment file once during startup.
    hl.exec_cmd("@wallpaperRandomize@/bin/wallpaper-randomize; exec @noctalia@")
    -- The service remains supervised by systemd. Starting it here also works
    -- for the non-UWSM session, where graphical-session.target is not raised.
    hl.exec_cmd("systemctl --user start wallpaper-autopause.service")
end)

hl.bind(main_mod .. " + Return", hl.dsp.exec_cmd(terminal))
hl.bind(main_mod .. " + F", hl.dsp.exec_cmd(browser))
hl.bind(main_mod .. " + C", hl.dsp.exec_cmd("google-chrome-stable"))
hl.bind(main_mod .. " + SHIFT + C", hl.dsp.exec_cmd("google-chrome-stable --class=chrome-webgpu --user-data-dir=$HOME/.cache/chrome-webgpu --ozone-platform=x11 --enable-unsafe-webgpu --enable-features=Vulkan --ignore-gpu-blocklist --disable-gpu-sandbox"))
hl.bind(main_mod .. " + D", hl.dsp.exec_cmd(dbclient))
hl.bind(main_mod .. " + E", hl.dsp.exec_cmd(editor))
hl.bind(main_mod .. " + P", hl.dsp.exec_cmd("@noctalia@ msg screenshot-region"))
hl.bind(main_mod .. " + Escape", hl.dsp.exec_cmd("@noctalia@ msg session lock"))
hl.bind(main_mod .. " + Q", hl.dsp.window.close())
hl.bind(main_mod .. " + V", actions.toggle_floating)

hl.bind(main_mod .. " + Space", hl.dsp.exec_cmd("@noctalia@ msg panel-toggle launcher"))
hl.bind(main_mod .. " + S", hl.dsp.exec_cmd("@noctalia@ msg panel-toggle control-center"))
hl.bind(main_mod .. " + comma", hl.dsp.exec_cmd("@noctalia@ msg settings-toggle"))
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("@noctalia@ msg volume-up"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("@noctalia@ msg volume-down"), { locked = true, repeating = true })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("@noctalia@ msg volume-mute"), { locked = true })

hl.bind(main_mod .. " + H", hl.dsp.focus({ direction = "left" }))
hl.bind(main_mod .. " + L", hl.dsp.focus({ direction = "right" }))
hl.bind(main_mod .. " + K", hl.dsp.focus({ direction = "up" }))
hl.bind(main_mod .. " + J", hl.dsp.focus({ direction = "down" }))

hl.bind(main_mod .. " + SHIFT + H", hl.dsp.window.swap({ direction = "left" }))
hl.bind(main_mod .. " + SHIFT + L", hl.dsp.window.swap({ direction = "right" }))
hl.bind(main_mod .. " + SHIFT + K", hl.dsp.window.swap({ direction = "up" }))
hl.bind(main_mod .. " + SHIFT + J", hl.dsp.window.swap({ direction = "down" }))

hl.bind(main_mod .. " + ALT + H", hl.dsp.window.resize({ x = 10, y = 0, relative = true }))
hl.bind(main_mod .. " + ALT + L", hl.dsp.window.resize({ x = 10, y = 0, relative = true }))
hl.bind(main_mod .. " + ALT + K", hl.dsp.window.resize({ x = 0, y = 10, relative = true }))
hl.bind(main_mod .. " + ALT + J", hl.dsp.window.resize({ x = 0, y = 10, relative = true }))

hl.bind(main_mod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(main_mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

hl.bind(main_mod .. " + O", function()
    actions.focus_workspace(1)
end)
hl.bind(main_mod .. " + Y", function()
    actions.focus_workspace(-1)
end)
hl.bind(main_mod .. " + SHIFT + O", function()
    actions.move_to_workspace(1)
end)
hl.bind(main_mod .. " + SHIFT + Y", function()
    actions.move_to_workspace(-1)
end)

hl.window_rule({
    name = "suppress-maximize-events",
    match = { class = ".*" },
    suppress_event = "maximize",
})
hl.window_rule({ match = { class = "^(Alacritty)$" }, immediate = true })
hl.window_rule({ match = { class = "^(Alacritty)$" }, opacity = "1.0 override 0.85 override" })
hl.window_rule({ match = { class = "^(Alacritty)$" }, border_size = 0 })
hl.window_rule({ match = { class = "^(firefox)$" }, immediate = true })
hl.window_rule({ match = { class = "^(firefox)$" }, border_size = 0 })
hl.window_rule({ match = { class = "^(dev\\.zed\\.Zed)$" }, border_size = 0 })
hl.window_rule({ match = { class = "^(org\\.kde\\.dolphin)$" }, border_size = 0 })
hl.window_rule({ match = { class = "^(jetbrains-datagrip)$" }, immediate = true })
hl.window_rule({ match = { class = "^(jetbrains-datagrip)$" }, border_size = 0 })
hl.window_rule({ match = { class = "^(xdg-desktop-portal-gtk)$" }, float = true })
hl.window_rule({ match = { class = "^(dev\\.noctalia\\.Noctalia)$" }, float = true })
hl.window_rule({ match = { class = "^(dev\\.noctalia\\.Noctalia)$" }, size = { 1080, 920 } })
hl.window_rule({
    name = "hide-hyprbars-outside-alacritty",
    match = { class = "negative:^(Alacritty)$" },
    ["hyprbars:no_bar"] = true,
})

hl.workspace_rule({
    workspace = "name:side",
    monitor = "DP-1",
    default = true,
    persistent = true,
    layout_opts = { orientation = "top" },
})

for id = 1, 5 do
    hl.workspace_rule({
        workspace = tostring(id),
        monitor = "DP-2",
        default = id == 1,
        persistent = true,
    })
end
