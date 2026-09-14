-- Snowflake palette (control-button/snowflake.svg), assigned by workspace id.
local COLORS = { "#fab387", "#f9e2af", "#94e2d5", "#b4befe", "#cba6f7", "#f5c2e7" }

local PILL = 16
-- Odd width so the 7px-wide digits center on whole pixels; height stays even so the outline stays crisp.
local PILL_WIDTH = 17
local ACTIVE_WIDTH = 37
local GAP = 5

-- Event names that can change which workspaces exist, are occupied, or are focused.
local REFRESH_EVENTS = {
  workspace = true, workspacev2 = true, focusedmon = true, focusedmonv2 = true,
  createworkspace = true, createworkspacev2 = true, destroyworkspace = true, destroyworkspacev2 = true,
  moveworkspace = true, moveworkspacev2 = true, renameworkspace = true,
  openwindow = true, closewindow = true, movewindow = true, movewindowv2 = true,
  monitoradded = true, monitorremoved = true,
}

local QUERY = [[printf '{"w":%s,"m":%s}' "$(hyprctl -j workspaces)" "$(hyprctl -j monitors)"]]

local workspaces = {}
local hovered = ""
local inFlight = false
local dirty = false

local function colorFor(id)
  return COLORS[((id - 1) % #COLORS) + 1]
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
    table.insert(children, ui.row({
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
        noctalia.runAsync({ "hyprctl", "dispatch", `hl.dsp.focus(\{ workspace = {id} })` })
      end,
      onHover = function(state, key)
        hovered = state == "true" and key or ""
        render()
      end,
    }, {
      ui.label({ text = ws.name, fontSize = 11, fontWeight = "bold", color = c, baseline = "text" }),
    }))
  end
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = GAP, align = "center" }, children))
end

local function apply(stdout)
  local data = noctalia.json.decode(stdout)
  if type(data) ~= "table" then
    return
  end
  -- outputName() is nil on this host; fall back to the monitor owning the lowest workspace.
  local output = barWidget.outputName()
  if output == nil then
    local lowest = math.huge
    for _, w in data.w do
      if w.id > 0 and w.id < lowest then
        lowest, output = w.id, w.monitor
      end
    end
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
  table.sort(list, function(a, b) return a.id < b.id end)
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

local sig = noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE")
local runtime = noctalia.getenv("XDG_RUNTIME_DIR")
if sig and runtime then
  noctalia.runStream(`stdbuf -oL socat -u UNIX-CONNECT:{runtime}/hypr/{sig}/.socket2.sock -`, function(line)
    local event = line:match("^(%w+)>>")
    if event and REFRESH_EVENTS[event] then
      refresh()
    end
  end)
end

function onScroll(axis, steps)
  local n = tonumber(steps) or 0
  if axis ~= "vertical" or n == 0 then
    return
  end
  local target = n > 0 and "m+1" or "m-1"
  noctalia.runAsync({ "hyprctl", "dispatch", `hl.dsp.focus(\{ workspace = "{target}" })` })
end

refresh()
