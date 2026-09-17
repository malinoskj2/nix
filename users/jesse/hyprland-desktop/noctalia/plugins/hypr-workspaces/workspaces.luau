-- `nix` is prepended by users/jesse/hyprland-desktop/noctalia/default.nix.
-- `nix.colors` holds the snowflake's lambda colors, which workspace ids cycle through.

-- Odd pill widths center the 7px-wide digits on whole pixels; an even height keeps outlines crisp.
local PILL_WIDTH = 17
local PILL_HEIGHT = 16
local ACTIVE_PILL_WIDTH = 37
local PILL_GAP = 5
local PILL_BORDER_WIDTH = 1.5
local LABEL_FONT_SIZE = 11
local LABEL_FONT_WEIGHT = "bold"

-- Events that can change which workspaces exist, are occupied, or are focused. Hyprland sends
-- each v2 event alongside its v1 twin, so only one of each pair is listened to.
local REFRESH_EVENTS = {
  createworkspacev2 = true,
  destroyworkspacev2 = true,
  moveworkspacev2 = true,
  renameworkspace = true,
  workspacev2 = true,

  focusedmonv2 = true,
  monitoraddedv2 = true,
  monitorremovedv2 = true,

  closewindow = true,
  movewindowv2 = true,
  openwindow = true,
}

-- Refreshes queue behind an in-flight query, so a hung hyprctl holds them back only this long.
local QUERY_TIMEOUT_MS = 2000

-- The stream command prints this once socat exits, so it must not look like a Hyprland event.
local STREAM_CLOSED = "hypr-workspaces:stream-closed"

-- Reconnects wait between attempts so a stopped Hyprland doesn't respawn the stream in a loop.
local RECONNECT_SECONDS = 2

-- Async callbacks run outside the bar's context, where `outputName()` is nil, so it's read at load.
local output = barWidget.outputName()
local workspaces = {}
local hovered = ""
local inFlight = false
local dirty = false
local reportedClosed = false

local function colorFor(id)
  return nix.colors[((id - 1) % #nix.colors) + 1]
end

-- Under a Lua config, `hyprctl dispatch` takes an `hl.dsp` expression.
local function dispatch(expression)
  noctalia.runAsync({ nix.hyprctl, "dispatch", expression })
end

local function render()
  local children = {}
  for _, workspace in workspaces do
    local id = workspace.id
    local color = colorFor(id)
    local isHovered = hovered == workspace.name

    -- Tint and outline strengthen from empty to occupied to focused. These alphas stay outside the
    -- palette's glass levels because they grade workspace states, not surfaces.
    local fill, border
    if workspace.focused then
      fill, border = color .. (isHovered and "59" or "40"), color
    elseif workspace.windows > 0 then
      fill, border = color .. (isHovered and "40" or "29"), color .. "b3"
    else
      fill, border = color .. (isHovered and "33" or "14"), color .. "80"
    end

    table.insert(
      children,
      ui.row({
        key = workspace.name,
        width = workspace.focused and ACTIVE_PILL_WIDTH or PILL_WIDTH,
        height = PILL_HEIGHT,
        radius = PILL_HEIGHT / 2,
        fill = fill,
        border = border,
        borderWidth = PILL_BORDER_WIDTH,
        align = "center",
        justify = "center",
        onClick = function()
          dispatch(`hl.dsp.focus(\{ workspace = {id} })`)
        end,
        onHover = function(state, key)
          hovered = state == "true" and key or ""
          render()
        end,
      }, {
        ui.label({
          text = workspace.name,
          fontSize = LABEL_FONT_SIZE,
          fontWeight = LABEL_FONT_WEIGHT,
          color = color,
          baseline = "text",
        }),
      })
    )
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = PILL_GAP, align = "center" }, children))
end

local function apply(stdout)
  local data = noctalia.json.decode(stdout)
  if type(data) ~= "table" then
    return
  end

  local active = nil
  for _, monitor in data.monitors do
    if monitor.name == output then
      active = monitor.activeWorkspace.id
      break
    end
  end

  local outputWorkspaces = {}
  for _, workspace in data.workspaces do
    -- Negative ids are special and named workspaces, such as the side monitor's.
    if workspace.id > 0 and workspace.monitor == output then
      table.insert(outputWorkspaces, {
        id = workspace.id,
        name = workspace.name,
        windows = workspace.windows,
        focused = workspace.id == active,
      })
    end
  end

  table.sort(outputWorkspaces, function(a, b)
    return a.id < b.id
  end)

  workspaces = outputWorkspaces
  render()
end

local function refresh()
  if inFlight then
    dirty = true
    return
  end

  inFlight = true
  noctalia.runAsync(
    `printf '\{"workspaces":%s,"monitors":%s}' "$({nix.hyprctl} -j workspaces)" "$({nix.hyprctl} -j monitors)"`,
    function(result)
      inFlight = false
      if result.exitCode == 0 then
        apply(result.stdout)
      end
      if dirty then
        dirty = false
        refresh()
      end
    end,
    QUERY_TIMEOUT_MS
  )
end

local function watchEvents(socket)
  local started = noctalia.runStream(
    `{nix.stdbuf} -oL {nix.socat} -u UNIX-CONNECT:{socket} -; echo {STREAM_CLOSED}`,
    function(line)
      if line == STREAM_CLOSED then
        if not reportedClosed then
          noctalia.log(`Hyprland event socket closed; reconnecting every {RECONNECT_SECONDS}s`)
          reportedClosed = true
        end
        noctalia.runAsync({ nix.sleep, tostring(RECONNECT_SECONDS) }, function()
          watchEvents(socket)
          refresh()
        end)
        return
      end

      reportedClosed = false
      local event = line:match("^(%w+)>>")
      if event and REFRESH_EVENTS[event] then
        refresh()
      end
    end
  )
  if not started then
    noctalia.log("failed to start the Hyprland event stream; workspaces will not update")
  end
end

local signature = noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE")
local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR")
if signature and runtimeDir then
  watchEvents(`{runtimeDir}/hypr/{signature}/.socket2.sock`)
else
  noctalia.log("HYPRLAND_INSTANCE_SIGNATURE or XDG_RUNTIME_DIR is unset; workspaces will not update")
end

refresh()

function onScroll(axis, steps)
  local count = tonumber(steps) or 0
  if axis ~= "vertical" or count == 0 then
    return
  end

  local target = count > 0 and "m+1" or "m-1"
  dispatch(`hl.dsp.focus(\{ workspace = "{target}" })`)
end
