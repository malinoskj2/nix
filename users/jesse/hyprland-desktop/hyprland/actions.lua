-- `nix` is passed in by users/jesse/hyprland-desktop/hyprland/hyprland.lua, which binds these.
-- Each action returns a dispatcher to bind, as `hl.dsp.*` does.

-- A window toggled to floating takes this share of its monitor's logical size.
local FLOATING_WIDTH_SHARE = 0.70
local FLOATING_HEIGHT_SHARE = 0.65

return function(nix)
  local actions = {}

  -- Only the main monitor has numbered workspaces, so this is nil anywhere else.
  local function wrapped_workspace(delta)
    local monitor = hl.get_active_monitor()
    if monitor == nil or monitor.name ~= nix.monitors.main then
      return nil
    end

    local workspace = monitor.active_workspace
    if workspace == nil or workspace.id < nix.workspaces.first or workspace.id > nix.workspaces.last then
      return nil
    end

    local count = nix.workspaces.last - nix.workspaces.first + 1
    return ((workspace.id - nix.workspaces.first + delta) % count) + nix.workspaces.first
  end

  function actions.focus_workspace(delta)
    return function()
      local target = wrapped_workspace(delta)
      if target == nil then
        return
      end

      hl.dispatch(hl.dsp.focus({ workspace = target, on_current_monitor = true }))
    end
  end

  function actions.move_to_workspace(delta)
    return function()
      local target = wrapped_workspace(delta)
      if target == nil or hl.get_active_window() == nil then
        return
      end

      hl.dispatch(hl.dsp.window.move({ workspace = target }))
    end
  end

  function actions.toggle_floating()
    return function()
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

      -- The monitor's width and height are its unrotated mode size; resize takes logical pixels.
      local width, height = monitor.width, monitor.height
      if monitor.transform % 2 == 1 then
        width, height = height, width
      end

      hl.dispatch(hl.dsp.window.float({ action = "on", window = window }))
      hl.dispatch(hl.dsp.window.resize({
        x = math.floor(width / monitor.scale * FLOATING_WIDTH_SHARE),
        y = math.floor(height / monitor.scale * FLOATING_HEIGHT_SHARE),
        relative = false,
        window = window,
      }))
      hl.dispatch(hl.dsp.window.center({ window = window }))
    end
  end

  return actions
end
