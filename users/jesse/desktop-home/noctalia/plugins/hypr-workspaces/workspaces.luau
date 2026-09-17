-- `nix` is the table of Nix-provided values that noctalia/default.nix prepends. nix.colors are the
-- snowflake's lambda colours, cycled by workspace id.

local PILL = 16
-- Odd width so the 7px-wide digits center on whole pixels; height stays even so the outline stays crisp.
local PILL_WIDTH = 17
local ACTIVE_WIDTH = 37
local GAP = 5

-- Events that can change which workspaces exist, are occupied, or are focused. Hyprland
-- sends each v2 event alongside its v1 twin, so only one of each pair is listened to.
local REFRESH_EVENTS = {
  workspacev2 = true,
  focusedmonv2 = true,
  createworkspacev2 = true,
  destroyworkspacev2 = true,
  moveworkspacev2 = true,
  renameworkspace = true,
  openwindow = true,
  closewindow = true,
  movewindowv2 = true,
  monitoraddedv2 = true,
  monitorremovedv2 = true,
}

local QUERY = `printf '\{"w":%s,"m":%s}' "$({nix.hyprctl} -j workspaces)" "$({nix.hyprctl} -j monitors)"`

-- Async callbacks run without the bar's context, where outputName() is nil, so read it at load.
local output = barWidget.outputName()
local workspaces = {}
local hovered = ""
local inFlight = false
local dirty = false

local function colorFor(id)
  return nix.colors[((id - 1) % #nix.colors) + 1]
end

local function render()
  local children = {}
  for _, ws in workspaces do
    local c = colorFor(ws.id)
    local hot = hovered == ws.name
    -- All outlined glass; tint and outline strength step up empty -> occupied -> focused.
    local fill, border
    if ws.focused then
      fill, border = c .. (hot and "59" or "40"), c
    elseif ws.windows > 0 then
      fill, border = c .. (hot and "40" or "29"), c .. "b3"
    else
      fill, border = c .. (hot and "33" or "14"), c .. "80"
    end
    local id = ws.id
    table.insert(
      children,
      ui.row({
        key = ws.name,
        width = ws.focused and ACTIVE_WIDTH or PILL_WIDTH,
        height = PILL,
        radius = PILL / 2,
        fill = fill,
        border = border,
        borderWidth = 1.5,
        align = "center",
        justify = "center",
        onClick = function()
          -- Hyprland's Lua config evaluates `hyprctl dispatch` input as hl.dispatch(...).
          noctalia.runAsync({ nix.hyprctl, "dispatch", `hl.dsp.focus(\{ workspace = {id} })` })
        end,
        onHover = function(state, key)
          hovered = state == "true" and key or ""
          render()
        end,
      }, {
        ui.label({ text = ws.name, fontSize = 11, fontWeight = "bold", color = c, baseline = "text" }),
      })
    )
  end
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = GAP, align = "center" }, children))
end

local function apply(stdout)
  local data = noctalia.json.decode(stdout)
  if type(data) ~= "table" then
    return
  end
  local active = nil
  for _, m in data.m do
    if m.name == output then
      active = m.activeWorkspace.id
    end
  end
  local list = {}
  for _, w in data.w do
    -- Negative ids are special/named workspaces (e.g. the DP-1 "side" one).
    if w.id > 0 and w.monitor == output then
      table.insert(list, { id = w.id, name = w.name, windows = w.windows, focused = w.id == active })
    end
  end
  table.sort(list, function(a, b)
    return a.id < b.id
  end)
  workspaces = list
  render()
end

local function refresh()
  if inFlight then
    dirty = true
    return
  end
  inFlight = true
  noctalia.runAsync(QUERY, function(result)
    inFlight = false
    if result.exitCode == 0 then
      apply(result.stdout)
    end
    if dirty then
      dirty = false
      refresh()
    end
  end, 2000)
end

-- Printed by the stream command once socat exits; not a Hyprland event name.
local STREAM_CLOSED = "hypr-workspaces:stream-closed"
local RECONNECT_SECONDS = 2
local reportedClosed = false

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

local sig = noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE")
local runtime = noctalia.getenv("XDG_RUNTIME_DIR")
if sig and runtime then
  watchEvents(`{runtime}/hypr/{sig}/.socket2.sock`)
else
  noctalia.log("HYPRLAND_INSTANCE_SIGNATURE or XDG_RUNTIME_DIR is unset; workspaces will not update")
end

function onScroll(axis, steps)
  local n = tonumber(steps) or 0
  if axis ~= "vertical" or n == 0 then
    return
  end
  local target = n > 0 and "m+1" or "m-1"
  noctalia.runAsync({ nix.hyprctl, "dispatch", `hl.dsp.focus(\{ workspace = "{target}" })` })
end

refresh()
