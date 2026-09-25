-- Geometry is measured from macOS 27's Apple menu at 1x, in logical px from the menu's top-left.
-- The panel pads its content by PADDING, the inset of Apple's row highlights, so the insets below
-- are Apple's less PADDING. Rows and separators have whole-px heights, so they simply stack.
local WIDTH = 284
local PADDING = 5
local CONTENT_WIDTH = WIDTH - 2 * PADDING
local ROW_HEIGHT = 24
-- A separator's 1 px line sits 5 px below the row above it and 5 px above the row below.
local SEPARATOR_HEIGHT = 11
local SEPARATOR_INSET = 16 - PADDING
local TEXT_INSET = 17 - PADDING
-- Rows with a symbol indent their text past it, and the symbol centers 24 px in.
local SYMBOL_CENTER = 24 - PADDING
local SYMBOL_WIDTH = 16
local SYMBOL_TEXT_INSET = 42 - PADDING
local HIGHLIGHT_RADIUS = 7
local FONT = "SF Pro Display"
local FONT_SIZE = 14.5
-- Shortcuts end 18 px from the menu's right edge: the key starts an 11 px cell and each modifier
-- centers in a 14 px one to its left.
local SHORTCUT_INSET = 18 - PADDING
local KEY_CELL = 11
local MODIFIER_CELL = 14
local CONFIRM_HEIGHT = 20
local CONFIRM_FONT_SIZE = 12
local CONFIRM_GAP = 6

local function color(name, alpha)
  return "#" .. nix.palette[name] .. (alpha and string.format("%02x", math.floor(alpha * 255 + 0.5)) or "")
end

local TEXT = color("text")
local SHORTCUT = color("overlay1")
local SEPARATOR = color("text", 0.12)
local ACCENT = color("peach")
local ON_ACCENT = color("crust")
local BUTTON = color("text", 0.14)
local BUTTON_HOVER = color("text", 0.22)
local ACCENT_HOVER = color("peach", 0.85)
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

local function gap(size)
  return ui.box({ width = size, flexGrow = 0, fill = CLEAR })
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

local function shortcut(keys, ink)
  local cells = {}
  for index, key in ipairs(keys) do
    local isKey = index == #keys
    table.insert(
      cells,
      cell(isKey and KEY_CELL or MODIFIER_CELL, label(key, { color = ink }), isKey and "start" or nil)
    )
  end
  return ui.row({ height = ROW_HEIGHT, align = "center" }, cells)
end

local function itemRow(item)
  local active = hovered == item.key
  local ink = active and ON_ACCENT or TEXT
  local children = {}
  if item.symbol ~= nil then
    table.insert(children, gap(SYMBOL_CENTER - SYMBOL_WIDTH / 2))
    table.insert(
      children,
      cell(SYMBOL_WIDTH, label(item.symbol[1], { fontSize = item.symbol[2], color = ink, baseline = "inkCentered" }))
    )
    table.insert(children, gap(SYMBOL_TEXT_INSET - SYMBOL_CENTER - SYMBOL_WIDTH / 2))
  else
    table.insert(children, gap(TEXT_INSET))
  end
  table.insert(children, label(item.text, { color = ink, flexGrow = 1 }))
  if item.shortcut ~= nil then
    table.insert(children, shortcut(item.shortcut, active and ON_ACCENT or SHORTCUT))
  end
  table.insert(children, gap(SHORTCUT_INSET))
  return ui.row({
    key = item.key,
    width = CONTENT_WIDTH,
    height = ROW_HEIGHT,
    radius = HIGHLIGHT_RADIUS,
    fill = active and ACCENT or CLEAR,
    align = "center",
    onClick = function()
      activate(item)
    end,
    onHover = "onRowHover",
  }, children)
end

local function confirmButton(key, text, primary, onClick)
  local active = hovered == key
  local fill
  if primary then
    fill = active and ACCENT_HOVER or ACCENT
  else
    fill = active and BUTTON_HOVER or BUTTON
  end
  return ui.row({
    key = key,
    height = CONFIRM_HEIGHT,
    radius = CONFIRM_HEIGHT / 2,
    paddingH = 10,
    fill = fill,
    align = "center",
    onClick = onClick,
    onHover = "onRowHover",
  }, {
    label(text, {
      fontSize = CONFIRM_FONT_SIZE,
      fontWeight = primary and "semibold" or nil,
      color = primary and ON_ACCENT or TEXT,
    }),
  })
end

local function confirmRow(item)
  return ui.row({ key = item.key .. ":confirm", width = CONTENT_WIDTH, height = ROW_HEIGHT, align = "center" }, {
    gap(TEXT_INSET),
    label(item.confirm.prompt, { flexGrow = 1 }),
    confirmButton(item.key .. ":cancel", "Cancel", false, function()
      confirming = nil
      hovered = nil
      render()
    end),
    gap(CONFIRM_GAP),
    confirmButton(item.key .. ":confirm-action", item.confirm.action, true, function()
      panel.close()
      run(item.run)
    end),
    gap((ROW_HEIGHT - CONFIRM_HEIGHT) / 2),
  })
end

local function separator()
  return ui.column({ width = CONTENT_WIDTH, height = SEPARATOR_HEIGHT }, {
    ui.box({ height = 5, fill = CLEAR }),
    ui.row({ height = 1, paddingH = SEPARATOR_INSET }, { ui.box({ height = 1, flexGrow = 1, fill = SEPARATOR }) }),
  })
end

function render()
  if not open then
    return
  end
  local rows = {}
  for index, group in ipairs(ITEMS) do
    if index > 1 then
      table.insert(rows, separator())
    end
    for _, item in ipairs(group) do
      table.insert(rows, confirming == item.key and confirmRow(item) or itemRow(item))
    end
  end
  panel.render(ui.column({ width = CONTENT_WIDTH, gap = 0 }, rows))
end

function onOpen()
  open = true
  hovered = nil
  confirming = nil
  render()
end

function onClose()
  open = false
end
