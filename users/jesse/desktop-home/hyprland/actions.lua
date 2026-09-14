local actions = {}

local MAIN_MONITOR = "DP-2"
local FIRST_WORKSPACE = 1
local LAST_WORKSPACE = 5

local function wrapped_workspace(delta)
    local monitor = hl.get_active_monitor()
    if monitor == nil or monitor.name ~= MAIN_MONITOR then
        return nil
    end

    local workspace = monitor.active_workspace
    if workspace == nil or workspace.id < FIRST_WORKSPACE or workspace.id > LAST_WORKSPACE then
        return nil
    end

    local count = LAST_WORKSPACE - FIRST_WORKSPACE + 1
    return ((workspace.id - FIRST_WORKSPACE + delta) % count) + FIRST_WORKSPACE
end

function actions.focus_workspace(delta)
    local target = wrapped_workspace(delta)
    if target ~= nil then
        hl.dispatch(hl.dsp.focus({
            workspace = target,
            on_current_monitor = true,
        }))
    end
end

function actions.move_to_workspace(delta)
    local target = wrapped_workspace(delta)
    if target ~= nil and hl.get_active_window() ~= nil then
        hl.dispatch(hl.dsp.window.move({ workspace = target }))
    end
end

function actions.toggle_floating()
    local window = hl.get_active_window()
    if window == nil then
        return
    end

    if window.floating then
        hl.dispatch(hl.dsp.window.float({ action = "off", window = window }))
        return
    end

    local monitor = window.monitor or hl.get_active_monitor()
    if monitor == nil then
        return
    end

    -- width/height are the unrotated mode size; resize takes logical pixels.
    local width, height = monitor.width, monitor.height
    if monitor.transform % 2 == 1 then
        width, height = height, width
    end

    hl.dispatch(hl.dsp.window.float({ action = "on", window = window }))
    hl.dispatch(hl.dsp.window.resize({
        x = math.floor(width / monitor.scale * 0.70),
        y = math.floor(height / monitor.scale * 0.65),
        relative = false,
        window = window,
    }))
    hl.dispatch(hl.dsp.window.center({ window = window }))
end

return actions
