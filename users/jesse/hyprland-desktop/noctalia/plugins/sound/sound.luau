-- Geometry is measured from macOS 27's menu bar Wi-Fi menu in the dark appearance, which shares its
-- layout with the Sound menu, and the slider from Control Center's Sound module. Values are
-- logical px from the top-left of the content area, which the manifest insets 5 px so hover
-- highlights can sit where Apple's do; the menu's own offsets are therefore these plus 5. Rows are
-- placed from their centers, since Noctalia snaps layout to whole px.
local WIDTH = 298
local FONT_SIZE = 13
local SYMBOL_SIZE = 15.5
local TEXT_INSET = 10
local SEPARATOR_INSET = 9
local HEADER_CENTER = 15.5
local SLIDER_CENTER = 41
local SLIDER_INSET = 8
local SLIDER_ICON_GAP = 4
local SLIDER_WAVE_GAP = 5
local TOP_SEPARATOR = 55
local SECTION_CENTER = 72
local FIRST_OUTPUT_CENTER = 98.5
local OUTPUT_PITCH = 32
local OUTPUT_TO_SEPARATOR = 21.5
local SEPARATOR_TO_SETTINGS = 16.5
local SETTINGS_TO_BOTTOM = 12.5
local ROW_HEIGHT = 22
local CIRCLE_DIAMETER = 26
local CIRCLE_INSET = 9
local NAME_INSET = 42
local HIGHLIGHT_RADIUS = 7
local TRACK_HEIGHT = 4
local POLL_MS = 1000
-- A poll that lands mid-drag or just after would snap the slider back to a stale volume.
local LOCAL_CHANGE_HOLD_MS = 1500

local function color(name, alpha)
  return "#" .. nix.palette[name] .. (alpha and string.format("%02x", math.floor(alpha * 255 + 0.5)) or "")
end

local TEXT = color("text")
local SECONDARY = color("overlay2")
local SEPARATOR = color("text", 0.1)
local TRACK = color("text", 0.18)
local FILL = color("peach")
local CIRCLE = color("text", 0.14)
local SELECTED_CIRCLE = color("peach")
local SELECTED_GLYPH = color("crust")
local HOVER = color("text", 0.1)
local ACTION_HOVER = color("sky")
local ACTION_HOVER_TEXT = color("crust")
local CLEAR = "#00000000"

-- SF Symbols glyphs in SF Pro's private use area, with the size that gives each Apple's ink size.
local SPEAKER = utf8.char(0x1002A1)
local SPEAKER_SLASH = utf8.char(0x1002A3)
local SPEAKER_WAVE_3 = utf8.char(0x1002A9)
local OUTPUT_SYMBOLS = {
  speaker = { utf8.char(0x1002A7), 12 },
  headphones = { utf8.char(0x100448), 13 },
  airpods = { utf8.char(0x1007E5), 13 },
  display = { utf8.char(0x1003B2), 12 },
}

local state = nil
local isOpen = false
local hovered = nil
local lastLocalChange = 0
local pendingVolume = nil
local volumeBusy = false
local shownOutputs = -1
local shownVolume = nil

local function label(text, props)
  local defaults = {
    text = text,
    fontSize = FONT_SIZE,
    fontFamily = "SF Pro Text",
    color = TEXT,
    baseline = "textFixedHeight",
  }
  for key, value in props or {} do
    defaults[key] = value
  end
  return ui.label(defaults)
end

local function gap(size, horizontal)
  return ui.box({ width = horizontal and size or nil, height = horizontal and nil or size, fill = CLEAR })
end

-- Lays `items` ({ center, size, node }) out along one axis, each centered on its `center`.
local function track(items, horizontal)
  local children = {}
  local offset = 0
  for _, item in ipairs(items) do
    local center, size, node = item[1], item[2], item[3]
    local start = math.max(math.floor(center - size / 2 + 0.5), offset)
    table.insert(children, gap(start - offset, horizontal))
    table.insert(children, node)
    offset = start + size
  end
  return children
end

local function separator()
  return ui.row({ height = 1, paddingH = SEPARATOR_INSET }, { ui.box({ height = 1, flexGrow = 1, fill = SEPARATOR }) })
end

local function textRow(text, props)
  return ui.row({ height = ROW_HEIGHT, paddingH = TEXT_INSET, align = "center" }, { label(text, props) })
end

local function refresh()
  noctalia.runAsync({ nix.state }, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("sound state failed: " .. result.stderr)
      return
    end
    local decoded = noctalia.json.decode(result.stdout)
    if decoded == nil then
      return
    end
    if state ~= nil and noctalia.nowMs() - lastLocalChange < LOCAL_CHANGE_HOLD_MS then
      decoded.volume = state.volume
      decoded.muted = state.muted
    end
    state = decoded
    if isOpen then
      render()
    end
  end)
end

local function run(argv)
  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      noctalia.log(table.concat(argv, " ") .. " failed: " .. result.stderr)
    end
    refresh()
  end)
end

-- Drags report every step, so at most one wpctl runs at a time and the latest value wins.
local function flushVolume()
  if volumeBusy or pendingVolume == nil then
    return
  end
  local volume = pendingVolume
  pendingVolume = nil
  volumeBusy = true
  local target = string.format("%.2f", volume)
  noctalia.runAsync({ nix.wpctl, "set-volume", "@DEFAULT_AUDIO_SINK@", target }, function()
    noctalia.runAsync({ nix.wpctl, "set-mute", "@DEFAULT_AUDIO_SINK@", "0" }, function()
      volumeBusy = false
      flushVolume()
    end)
  end)
end

-- The slider also reports values the script itself set, which must not be written back.
local function setVolume(value)
  local percent = tonumber(value)
  if percent == shownVolume then
    return
  end
  shownVolume = percent
  local volume = percent / 100
  lastLocalChange = noctalia.nowMs()
  state.volume = volume
  pendingVolume = volume
  flushVolume()
  if state.muted then
    state.muted = false
    render()
  end
end

local function toggleMute()
  lastLocalChange = noctalia.nowMs()
  state.muted = not state.muted
  render()
  run({ nix.wpctl, "set-mute", "@DEFAULT_AUDIO_SINK@", state.muted and "1" or "0" })
end

local function selectOutput(output)
  for _, other in state.outputs do
    other.default = other.id == output.id
  end
  render()
  run({ nix.wpctl, "set-default", tostring(output.id) })
end

local function openSettings()
  noctalia.runAsync({ nix.settings })
  panel.close()
end

local function hover(key)
  return function(entered)
    if entered == "true" then
      hovered = key
    elseif hovered == key then
      hovered = nil
    end
    render()
  end
end

local function volumeRow()
  local muted = state.muted
  shownVolume = muted and 0 or math.floor(state.volume * 100 + 0.5)
  return ui.row({ height = ROW_HEIGHT, paddingH = SLIDER_INSET, align = "center" }, {
    ui.row({ align = "center", onClick = toggleMute }, {
      label(muted and SPEAKER_SLASH or SPEAKER, { fontSize = SYMBOL_SIZE }),
    }),
    gap(SLIDER_ICON_GAP, true),
    ui.slider({
      key = "volume",
      min = 0,
      max = 100,
      step = 1,
      value = shownVolume,
      height = ROW_HEIGHT,
      trackHeight = TRACK_HEIGHT,
      thumbSize = 0,
      fill = FILL,
      track = TRACK,
      flexGrow = 1,
      onChange = setVolume,
    }),
    gap(SLIDER_WAVE_GAP, true),
    label(SPEAKER_WAVE_3, { fontSize = SYMBOL_SIZE }),
  })
end

local function outputRow(output)
  local key = "output-" .. tostring(output.id)
  local symbol = OUTPUT_SYMBOLS[output.kind] or OUTPUT_SYMBOLS.speaker
  local circle = ui.row({
    width = CIRCLE_DIAMETER,
    height = CIRCLE_DIAMETER,
    radius = CIRCLE_DIAMETER / 2,
    fill = output.default and SELECTED_CIRCLE or CIRCLE,
    align = "center",
    justify = "center",
  }, {
    label(symbol[1], { fontSize = symbol[2], color = output.default and SELECTED_GLYPH or TEXT }),
  })
  return ui.row({
    key = key,
    height = OUTPUT_PITCH,
    radius = HIGHLIGHT_RADIUS,
    fill = hovered == key and HOVER or CLEAR,
    align = "center",
    onClick = function()
      selectOutput(output)
    end,
    onHover = hover(key),
  }, {
    gap(CIRCLE_INSET, true),
    circle,
    gap(NAME_INSET - CIRCLE_INSET - CIRCLE_DIAMETER, true),
    label(output.name, { maxLines = 1, flexGrow = 1 }),
    gap(TEXT_INSET, true),
  })
end

local function settingsRow()
  local active = hovered == "settings"
  return ui.row({
    key = "settings",
    height = ROW_HEIGHT,
    paddingH = TEXT_INSET,
    radius = HIGHLIGHT_RADIUS,
    fill = active and ACTION_HOVER or CLEAR,
    align = "center",
    onClick = openSettings,
    onHover = hover("settings"),
  }, { label("Sound Settings…", { color = active and ACTION_HOVER_TEXT or TEXT }) })
end

local function contentHeight(count)
  local separatorCenter = FIRST_OUTPUT_CENTER + (math.max(count, 1) - 1) * OUTPUT_PITCH + OUTPUT_TO_SEPARATOR
  return separatorCenter + SEPARATOR_TO_SETTINGS + SETTINGS_TO_BOTTOM
end

function render()
  if state == nil then
    return
  end
  local count = #state.outputs
  local height = contentHeight(count)
  if count ~= shownOutputs then
    shownOutputs = count
    panel.setSize(0, height + 10)
  end

  local rows = {
    { HEADER_CENTER, ROW_HEIGHT, textRow("Sound", { fontWeight = "bold" }) },
    { SLIDER_CENTER, ROW_HEIGHT, volumeRow() },
    { TOP_SEPARATOR, 1, separator() },
    { SECTION_CENTER, ROW_HEIGHT, textRow("Output", { fontWeight = "bold", color = SECONDARY }) },
  }
  for index, output in ipairs(state.outputs) do
    table.insert(rows, { FIRST_OUTPUT_CENTER + (index - 1) * OUTPUT_PITCH, OUTPUT_PITCH, outputRow(output) })
  end
  local separatorCenter = height - SETTINGS_TO_BOTTOM - SEPARATOR_TO_SETTINGS
  table.insert(rows, { separatorCenter, 1, separator() })
  table.insert(rows, { separatorCenter + SEPARATOR_TO_SETTINGS, ROW_HEIGHT, settingsRow() })

  panel.render(ui.column({ width = WIDTH, height = height, gap = 0 }, track(rows, false)))
end

noctalia.setUpdateInterval(POLL_MS)

function onOpen()
  isOpen = true
  hovered = nil
  render()
  refresh()
end

function onClose()
  isOpen = false
end

function update()
  if isOpen then
    refresh()
  end
end
