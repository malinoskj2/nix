-- Geometry is measured from macOS 27's Apple menu at 1x, in logical px from the menu's top-left.
-- The panel pads its content by PADDING, the inset of Apple's row highlights, so every center below
-- is placed less PADDING. Noctalia snaps layout to whole logical px, so rows are placed from their
-- own centers instead of accumulating sizes. The Apple menu has no header or hem, so it takes the
-- network menu's: the header at the same height, with the uptime in its corner, and the hem 12 px
-- below the last row. A confirmation turns its row into a prompt like the network menu's password.
local WIDTH = 284
local PADDING = 5
local CONTENT_WIDTH = WIDTH - 2 * PADDING
local ROW_HEIGHT = 24
local HEADER_CENTER = 20.5
local HEADER_HEIGHT = 24
local PROMPT_HEIGHT = 36
-- A separator's 1 px line is centered 5.5 px below the row above it and 5.5 px above the row below.
local SEPARATOR_GAP = 5.5
local SEPARATOR_INSET = 16 - PADDING
local TEXT_INSET = 17 - PADDING
-- Rows with a symbol indent their text past it, and the symbol centers 24 px in.
local SYMBOL_CENTER = 24 - PADDING
local SYMBOL_WIDTH = 16
local SYMBOL_TEXT_INSET = 42 - PADDING
local HIGHLIGHT_RADIUS = 7
local FONT = "SF Pro Text"
local FONT_SIZE = 13
-- Shortcuts end 18 px from the menu's right edge: the key starts an 11 px cell and each modifier
-- centers in a 14 px one to its left.
local SHORTCUT_INSET = 18 - PADDING
local KEY_CELL = 11
local MODIFIER_CELL = 14
local BUTTON_HEIGHT = 26
local BUTTON_PADDING = 10
local BUTTON_GAP = 6
local UPTIME_WIDTH = 120
local UPTIME_HEIGHT = 20
local UPTIME_FONT_SIZE = 14.5
local HEM_COLORS = {
  "rosewater",
  "flamingo",
  "pink",
  "mauve",
  "red",
  "maroon",
  "peach",
  "yellow",
  "green",
  "teal",
  "sky",
  "sapphire",
  "blue",
  "lavender",
}
local HEM_STOP_WIDTH = 12
local HEM_HEIGHT = 3
local HEM_GAP = 12
local BOTTOM_GAP = 7

local function color(name, alpha)
  return "#" .. nix.palette[name] .. (alpha and string.format("%02x", math.floor(alpha * 255 + 0.5)) or "")
end

local TEXT = color("text")
local TERTIARY = color("overlay1")
local ACCENT = color("peach")
local ACCENT_HOVER = color("peach", 0.85)
local ON_ACCENT = color("crust")
local SEPARATOR = color("text", 0.12)
local HIGHLIGHT = color("text", 0.1)
local BUTTON = color("text", 0.14)
local BUTTON_HOVER = color("text", 0.22)
local CLEAR = "#00000000"

-- SF Symbols glyphs in SF Pro's private use area, with the size that gives each Apple's ink size.
local DESKTOP = { utf8.char(0x100657), 12 }
local GEAR = { utf8.char(0x10035F), 11 }
local SLIDERS = { utf8.char(0x100306), 11.5 }

local COMMAND = "⌘"
local ESCAPE = "⎋"

local function noctalia_msg(...)
  return { nix.noctalia, "msg", ... }
end

-- Shortcuts are the binds in hyprland.lua, with Super drawn as Command.
local ITEMS = {
  {
    {
      key = "about",
      text = "About This Computer",
      symbol = DESKTOP,
      run = noctalia_msg("panel-toggle", "jesse/about:about"),
    },
  },
  {
    {
      key = "settings",
      text = "System Settings…",
      symbol = GEAR,
      shortcut = { COMMAND, "," },
      run = noctalia_msg("settings-open"),
    },
    {
      key = "control-center",
      text = "Control Center",
      symbol = SLIDERS,
      shortcut = { COMMAND, "S" },
      run = noctalia_msg("panel-toggle", "control-center"),
    },
  },
  {
    { key = "force-quit", text = "Force Quit…", run = { nix.hyprctl, "kill" } },
  },
  {
    { key = "sleep", text = "Sleep", run = noctalia_msg("session", "suspend") },
    {
      key = "restart",
      text = "Restart…",
      confirm = { prompt = "Restart now?", action = "Restart" },
      run = noctalia_msg("session", "reboot"),
    },
    {
      key = "shutdown",
      text = "Shut Down…",
      confirm = { prompt = "Shut down now?", action = "Shut Down" },
      run = noctalia_msg("session", "shutdown"),
    },
  },
  {
    { key = "lock", text = "Lock Screen", shortcut = { COMMAND, ESCAPE }, run = noctalia_msg("session", "lock") },
    {
      key = "logout",
      text = "Log Out " .. nix.user .. "…",
      confirm = { prompt = "Log out now?", action = "Log Out" },
      run = noctalia_msg("session", "logout"),
    },
  },
}

local hovered = nil
local confirming = nil
local open = false
-- Until /proc/uptime has answered once, nothing renders, so the panel's first frame, which Noctalia
-- holds for it, already has the uptime.
local loaded = false
local uptime = nil

local render

local function label(text, props)
  local defaults = {
    text = text,
    fontSize = FONT_SIZE,
    fontFamily = FONT,
    color = TEXT,
    baseline = "text",
    maxLines = 1,
  }
  for key, value in props or {} do
    defaults[key] = value
  end
  return ui.label(defaults)
end

local function gap(size, horizontal)
  return ui.box({ width = horizontal and size or nil, height = horizontal and nil or size, flexGrow = 0, fill = CLEAR })
end

local function cell(width, node, justify)
  return ui.row({ width = width, height = ROW_HEIGHT, align = "center", justify = justify or "center" }, { node })
end

-- A named handler, so the leave Noctalia sends when a hovered row disappears still arrives.
function onRowHover(inside, key)
  local next = hovered
  if inside == "true" then
    next = key
  elseif hovered == key then
    next = nil
  end
  if next ~= hovered then
    hovered = next
    render()
  end
end

local function run(argv)
  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      noctalia.log(table.concat(argv, " ") .. " failed: " .. result.stderr)
    end
  end)
end

local function activate(item)
  if item.confirm ~= nil then
    confirming = item.key
    hovered = nil
    render()
    return
  end
  panel.close()
  run(item.run)
end

local function formatUptime(seconds)
  local minutes = math.floor(seconds / 60)
  if minutes < 60 then
    return string.format("%d min", math.max(minutes, 1))
  elseif minutes < 24 * 60 then
    return string.format("%d h %d min", minutes // 60, minutes % 60)
  end
  return string.format("%d d %d h", minutes // (24 * 60), minutes // 60 % 24)
end

local function refreshUptime()
  noctalia.readFileAsync("/proc/uptime", function(contents)
    local seconds = tonumber(string.match(contents or "", "^%d+"))
    local text = seconds and formatUptime(seconds) or nil
    if text ~= uptime or not loaded then
      loaded = true
      uptime = text
      render()
    end
  end)
end

-- Noctalia labels take one flat color, so the uptime is drawn as SVG text filled with the sunset
-- cloud's stripes, like the network menu's link speed, with the status dot as a glyph in the same run.
local UPTIME_SVG = [[<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">
<defs><linearGradient id="stripes" gradientUnits="userSpaceOnUse" x1="0" y1="4" x2="0" y2="16">%s</linearGradient></defs>
<text x="%d" y="15" text-anchor="end" font-family="SF Pro Rounded" font-weight="600" font-size="%s"><tspan fill="%s" font-size="9" baseline-shift="1.5">●</tspan><tspan dx="5" fill="url(#stripes)">%s</tspan></text>
</svg>]]
local uptimeImages = {}

local function uptimeImage(text)
  if uptimeImages[text] == nil then
    local stops = {}
    for i = #HEM_COLORS, 1, -1 do
      local index = #HEM_COLORS - i
      local fill = color(HEM_COLORS[i])
      table.insert(stops, string.format('<stop offset="%.4f" stop-color="%s"/>', index / #HEM_COLORS, fill))
      table.insert(stops, string.format('<stop offset="%.4f" stop-color="%s"/>', (index + 1) / #HEM_COLORS, fill))
    end
    local svg = string.format(
      UPTIME_SVG,
      UPTIME_WIDTH,
      UPTIME_HEIGHT,
      UPTIME_WIDTH,
      UPTIME_HEIGHT,
      table.concat(stops),
      UPTIME_WIDTH,
      UPTIME_FONT_SIZE,
      ACCENT,
      text
    )
    -- Noctalia caches images by path, so the name carries a hash of the content.
    local digest = 5381
    for i = 1, #svg do
      digest = (digest * 33 + string.byte(svg, i)) % 4294967296
    end
    local dir = noctalia.pluginDataDir()
    local path = dir and string.format("%s/uptime-%08x.svg", dir, digest) or nil
    if path == nil or not noctalia.writeFile(path, svg) then
      return nil
    end
    uptimeImages[text] = path
  end
  return uptimeImages[text]
end

local function openMonitor()
  panel.close()
  noctalia.runAsync(nix.monitor)
end

local function header()
  local path = uptime and uptimeImage(uptime)
  return ui.row({ width = CONTENT_WIDTH, height = HEADER_HEIGHT, align = "center" }, {
    gap(TEXT_INSET, true),
    label("NixOS", { fontWeight = "bold", color = ACCENT, flexGrow = 1 }),
    path and ui.row({ key = "uptime", onClick = openMonitor }, {
      ui.image({ path = path, width = UPTIME_WIDTH, height = UPTIME_HEIGHT, fit = "contain" }),
    }) or gap(0, true),
    gap(SHORTCUT_INSET, true),
  })
end

local function shortcut(keys)
  local cells = {}
  for index, key in ipairs(keys) do
    local isKey = index == #keys
    table.insert(
      cells,
      cell(isKey and KEY_CELL or MODIFIER_CELL, label(key, { color = TERTIARY }), isKey and "start" or nil)
    )
  end
  return ui.row({ height = ROW_HEIGHT, align = "center" }, cells)
end

local function itemRow(item)
  local children = {}
  if item.symbol ~= nil then
    table.insert(children, gap(SYMBOL_CENTER - SYMBOL_WIDTH / 2, true))
    table.insert(
      children,
      cell(SYMBOL_WIDTH, label(item.symbol[1], { fontSize = item.symbol[2], baseline = "inkCentered" }))
    )
    table.insert(children, gap(SYMBOL_TEXT_INSET - SYMBOL_CENTER - SYMBOL_WIDTH / 2, true))
  else
    table.insert(children, gap(TEXT_INSET, true))
  end
  table.insert(children, label(item.text, { flexGrow = 1 }))
  if item.shortcut ~= nil then
    table.insert(children, shortcut(item.shortcut))
  end
  table.insert(children, gap(SHORTCUT_INSET, true))
  return ui.row({
    key = item.key,
    width = CONTENT_WIDTH,
    height = ROW_HEIGHT,
    radius = HIGHLIGHT_RADIUS,
    fill = hovered == item.key and HIGHLIGHT or CLEAR,
    align = "center",
    onClick = function()
      activate(item)
    end,
    onHover = "onRowHover",
  }, children)
end

local function button(key, text, primary, onClick)
  local active = hovered == key
  local fill
  if primary then
    fill = active and ACCENT_HOVER or ACCENT
  else
    fill = active and BUTTON_HOVER or BUTTON
  end
  return ui.row({
    key = key,
    height = BUTTON_HEIGHT,
    radius = HIGHLIGHT_RADIUS,
    paddingH = BUTTON_PADDING,
    fill = fill,
    align = "center",
    onClick = onClick,
    onHover = "onRowHover",
  }, {
    label(text, { fontWeight = primary and "semibold" or nil, color = primary and ON_ACCENT or TEXT }),
  })
end

local function promptRow(item)
  return ui.row({ key = item.key .. ":confirm", width = CONTENT_WIDTH, height = PROMPT_HEIGHT, align = "center" }, {
    gap(TEXT_INSET, true),
    label(item.confirm.prompt, { flexGrow = 1 }),
    button(item.key .. ":cancel", "Cancel", false, function()
      confirming = nil
      hovered = nil
      render()
    end),
    gap(BUTTON_GAP, true),
    button(item.key .. ":confirm-action", item.confirm.action, true, function()
      panel.close()
      run(item.run)
    end),
    gap(SHORTCUT_INSET, true),
  })
end

local function hem()
  local stops = {}
  for _, name in ipairs(HEM_COLORS) do
    table.insert(stops, ui.box({ width = HEM_STOP_WIDTH, height = HEM_HEIGHT, flexGrow = 0, fill = color(name, 0.9) }))
  end
  return ui.row({ height = HEM_HEIGHT, justify = "center", gap = 0 }, stops)
end

-- Collects rows by center and turns them into a column of whole-px gaps and rows.
local function stack()
  local items = {}
  local self = {}
  local last = nil

  function self.add(center, height, node)
    table.insert(items, { center, height, node })
    last = { center = center, height = height }
    return self
  end

  function self.next(height, node, space)
    return self.add(last.center + last.height / 2 + (space or 0) + height / 2, height, node)
  end

  function self.separator()
    local center = last.center + last.height / 2 + SEPARATOR_GAP
    table.insert(items, {
      center,
      1,
      ui.row({ height = 1, paddingH = SEPARATOR_INSET }, { ui.box({ height = 1, flexGrow = 1, fill = SEPARATOR }) }),
    })
    last = { center = center, height = 0 }
    return self
  end

  function self.build()
    local children = {}
    local offset = 0
    for _, item in ipairs(items) do
      local center, size, node = item[1] - PADDING, item[2], item[3]
      local start = math.max(math.floor(center - size / 2 + 0.5), offset)
      if start > offset then
        table.insert(children, gap(start - offset))
      end
      table.insert(children, node)
      offset = start + size
    end
    local height = math.floor(last.center + last.height / 2 + BOTTOM_GAP + 0.5)
    return ui.column({ width = CONTENT_WIDTH, gap = 0 }, children), height
  end

  return self
end

function render()
  if not open or not loaded then
    return
  end
  local layout = stack()
  layout.add(HEADER_CENTER, HEADER_HEIGHT, header())
  for _, group in ipairs(ITEMS) do
    layout.separator()
    for index, item in ipairs(group) do
      local space = index == 1 and SEPARATOR_GAP or 0
      if confirming == item.key then
        layout.next(PROMPT_HEIGHT, promptRow(item), space)
      else
        layout.next(ROW_HEIGHT, itemRow(item), space)
      end
    end
  end
  layout.next(HEM_HEIGHT, hem(), HEM_GAP)

  local tree, height = layout.build()
  panel.setSize(WIDTH, height)
  panel.render(tree)
end

refreshUptime()

function onOpen()
  open = true
  hovered = nil
  confirming = nil
  panel.setWantsSecondTicks(true)
  render()
  refreshUptime()
end

function onClose()
  open = false
end

function update()
  if open then
    refreshUptime()
  end
end
