-- Geometry is measured from macOS 27's About This Mac at 1x, in logical px from the window's
-- top-left. Text is placed by the center of its cap height, since Noctalia snaps layout to whole px.
-- It's a panel rather than a window, so it closes like the others and has no traffic lights, and
-- there's no picture, so the title sits at the top and everything under it moves up with it. There
-- are also two more rows than Apple's five and one footer line fewer, so everything below the rows
-- moves down by the extra rows' pitch. The menus' hem ends it, 12 px below the footer.
local WIDTH = 280
local FONT = "SF Pro Text"
local FONT_SIZE = 11
local BUTTON_FONT_SIZE = 13
local TITLE_FONT_SIZE = 22

local TITLE_TOP = 24
local TITLE_CAP_TOP = 236.5
local RAISE = TITLE_CAP_TOP - TITLE_TOP
local TITLE_CENTER = 245
local TITLE_HEIGHT = 28
local FIRST_ROW_CENTER = 285
local ROW_PITCH = 16
local APPLE_ROWS = 5
local COLUMN_GAP = 11
local BUTTON_CENTER = 388
local BUTTON_WIDTH = 92
local BUTTON_HEIGHT = 24
local BUTTON_RADIUS = 7
local FOOTER_CENTER = 420.5
local FOOTER_PITCH = 14.5
local FOOTER_HEIGHT = 15
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
local BOTTOM_GAP = 6
-- Apple's underline runs 1 px below the baseline, through the descenders, so the link's label is
-- cut short to put its underline there.
local LINK_HEIGHT = 12

local function color(name, alpha)
  return "#" .. nix.palette[name] .. (alpha and string.format("%02x", math.floor(alpha * 255 + 0.5)) or "")
end

local TEXT = color("text")
local TITLE = color("peach")
local SECONDARY = color("subtext1")
-- The sky tint the menus use for the names beside values.
local KEY = color("sky", 0.65)
local TERTIARY = color("overlay1")
local BUTTON = color("text", 0.14)
local BUTTON_HOVER = color("text", 0.22)
local CLEAR = "#00000000"

local state = nil
local isOpen = false
local hovered = nil
local shownRows = nil

local function label(text, props)
  local defaults = {
    text = text,
    fontSize = FONT_SIZE,
    fontFamily = FONT,
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

local function centered(height, children)
  return ui.row({ height = height, align = "center", justify = "center" }, children)
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

local function rows()
  local result = {
    { "Name", nix.hostname },
    { "Processor", state.cpu },
    { "Graphics", state.gpu },
    { "Memory", state.memory },
    { "Startup disk", state.disk },
    { "Configuration", nix.revision },
    { "NixOS", nix.nixos },
  }
  local present = {}
  for _, row in result do
    if row[2] ~= nil and row[2] ~= "" then
      table.insert(present, row)
    end
  end
  return present
end

-- Right-aligned labels and left-aligned values, the pair of columns centered as a block.
local function specs(list)
  local labels = {}
  local values = {}
  for _, row in list do
    table.insert(labels, ui.row({ height = ROW_PITCH, align = "center" }, { label(row[1], { color = KEY }) }))
    table.insert(values, ui.row({ height = ROW_PITCH, align = "center" }, { label(row[2]) }))
  end
  return ui.row({ height = #list * ROW_PITCH, justify = "center" }, {
    ui.column({ align = "end", gap = 0 }, labels),
    gap(COLUMN_GAP, true),
    ui.column({ align = "start", gap = 0 }, values),
  })
end

local function moreInfo()
  return centered(BUTTON_HEIGHT, {
    ui.row({
      key = "more",
      width = BUTTON_WIDTH,
      height = BUTTON_HEIGHT,
      radius = BUTTON_RADIUS,
      fill = hovered == "more" and BUTTON_HOVER or BUTTON,
      align = "center",
      justify = "center",
      onClick = function()
        noctalia.runAsync(nix.monitor)
        panel.close()
      end,
      onHover = hover("more"),
    }, { label("More Info…", { fontSize = BUTTON_FONT_SIZE }) }),
  })
end

local function repository()
  local active = hovered == "repo"
  local ink = active and SECONDARY or TERTIARY
  return centered(FOOTER_HEIGHT, {
    ui.column({
      key = "repo",
      align = "stretch",
      gap = 0,
      onClick = function()
        noctalia.runAsync({ nix.open, nix.repository.url })
        panel.close()
      end,
      onHover = hover("repo"),
    }, {
      ui.row({ height = LINK_HEIGHT, align = "start" }, { label(nix.repository.name, { color = ink }) }),
      ui.box({ height = 1, fill = ink }),
    }),
  })
end

local function hem()
  local stops = {}
  for _, name in ipairs(HEM_COLORS) do
    table.insert(stops, ui.box({ width = HEM_STOP_WIDTH, height = HEM_HEIGHT, fill = color(name, 0.9) }))
  end
  return ui.row({ width = WIDTH, height = HEM_HEIGHT, justify = "center", gap = 0 }, stops)
end

function render()
  if state == nil then
    return
  end
  local list = rows()
  local shift = (#list - APPLE_ROWS) * ROW_PITCH - RAISE
  local footer = FOOTER_CENTER + shift
  local hemCenter = footer + FOOTER_PITCH + FOOTER_HEIGHT / 2 + HEM_GAP + HEM_HEIGHT / 2
  local height = math.floor(hemCenter + HEM_HEIGHT / 2 + BOTTOM_GAP + 0.5)
  if #list ~= shownRows then
    shownRows = #list
    panel.setSize(0, height)
  end

  local items = {
    {
      TITLE_CENTER - RAISE,
      TITLE_HEIGHT,
      centered(TITLE_HEIGHT, {
        label(
          nix.title,
          { fontSize = TITLE_FONT_SIZE, fontFamily = "SF Pro Display", fontWeight = "bold", color = TITLE }
        ),
      }),
    },
    { FIRST_ROW_CENTER - RAISE + (#list - 1) * ROW_PITCH / 2, #list * ROW_PITCH, specs(list) },
    { BUTTON_CENTER + shift, BUTTON_HEIGHT, moreInfo() },
    { footer, FOOTER_HEIGHT, repository() },
    { footer + FOOTER_PITCH, FOOTER_HEIGHT, centered(FOOTER_HEIGHT, { label(nix.built, { color = TERTIARY }) }) },
    { hemCenter, HEM_HEIGHT, hem() },
  }
  panel.render(ui.column({ width = WIDTH, height = height, gap = 0 }, track(items, false)))
end

local function refresh()
  noctalia.runAsync({ nix.state }, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("about state failed: " .. result.stderr)
      return
    end
    local decoded = noctalia.json.decode(result.stdout)
    if decoded == nil then
      return
    end
    state = decoded
    if isOpen then
      render()
    end
  end)
end

-- The hardware doesn't change while the shell runs, so the first open can use what loading found.
refresh()

function onOpen()
  isOpen = true
  hovered = nil
  if state == nil then
    refresh()
  else
    render()
  end
end

function onClose()
  isOpen = false
end
