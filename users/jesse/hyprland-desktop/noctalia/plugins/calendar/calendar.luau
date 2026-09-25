-- Geometry is measured from macOS 27's small Calendar widget in the Clear style, in logical px from
-- the top-left of the content area. The panel is the tile's size, and Noctalia insets plugin
-- content 14 px from its edge, so these are the tile's offsets less 14. Noctalia snaps layout to
-- whole logical px, so every row and column is placed from its own center instead of accumulating
-- fractional sizes.
local WIDTH = 137
local HEIGHT = 136
local FONT_SIZE = 10.25
local HEADER_INSET = 5
local HEADER_CENTER = 10
local WEEKDAY_CENTER = 28
-- Five weeks span these centers. Six share the same span, and four keep the five-week pitch from
-- the top.
local FIRST_WEEK_CENTER = 48
local LAST_WEEK_CENTER = 124.5
-- Apple's own columns are snapped to its device pixels, so they are not evenly spaced.
local COLUMN_CENTERS = { 9, 28.75, 48.5, 68.25, 87.5, 107.75, 127 }
local LABEL_ROW_HEIGHT = 16
local WEEK_ROW_HEIGHT = 18
local CELL_WIDTH = 18
local TODAY_DIAMETER = 18

local function color(name, alpha)
  return "#" .. nix.palette[name] .. (alpha and string.format("%02x", math.floor(alpha * 255 + 0.5)) or "")
end

local MONTH = color("peach")
local WEEKDAY = color("subtext1")
local WEEKEND = color("sky", 0.65)
local TODAY = color("peach")
local TODAY_TEXT = color("crust")

local WEEKDAYS = { "S", "M", "T", "W", "T", "F", "S" }

local shownDate = nil
local outputScale = 1

-- The baseline mode decides whether a label's cap band centers on a whole or a half px: the header
-- and weekday initials sit on whole px like Apple's, and dates on half px, where today's digit is
-- also centered in its circle.
local function label(text, textColor, props)
  local defaults = {
    text = text,
    fontSize = FONT_SIZE,
    fontWeight = "bold",
    fontFamily = "SF Pro Display",
    color = textColor,
    baseline = "text",
    textAlign = "center",
  }
  for key, value in props or {} do
    defaults[key] = value
  end
  return ui.label(defaults)
end

local function gap(size, horizontal)
  return ui.box({ width = horizontal and size or nil, height = horizontal and nil or size, fill = "#00000000" })
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

-- A stretched label centers its text itself, to a fraction of a pixel, where a centered label box
-- would be floored to whole px.
local function cell(node)
  return ui.column({ width = CELL_WIDTH, justify = "center" }, { node })
end

-- The circle has an even diameter so it and the digit's cap band share a center. It may be larger
-- than its cell or row, which only cross-axis centering allows, and only in a container with an
-- explicit size, since a content-sized one is clamped to its parent.
local function todayCell(day)
  local text = tostring(day)
  -- Centered on its advance, a number's ink lands about a device pixel right of center at 2x, so
  -- it is centered in a box 1 px narrower, unless it ends in a digit whose ink already leans left.
  -- At 1x the same half px would overcorrect.
  local nudge = (outputScale < 2 or string.find(text, "[17]$")) and 0 or 1
  local circle = ui.row({
    width = TODAY_DIAMETER,
    height = TODAY_DIAMETER,
    radius = TODAY_DIAMETER / 2,
    fill = TODAY,
    align = "center",
  }, { label(text, TODAY_TEXT, { flexGrow = 1 }), gap(nudge, true) })
  return ui.row({ width = CELL_WIDTH, align = "center" }, {
    ui.column({ width = CELL_WIDTH, height = TODAY_DIAMETER, align = "center" }, { circle }),
  })
end

local function cells(nodes, height)
  local items = {}
  for column, node in ipairs(nodes) do
    items[column] = { COLUMN_CENTERS[column], CELL_WIDTH, node }
  end
  return ui.row({ height = height, gap = 0 }, track(items, true))
end

local function isWeekend(column)
  return column == 1 or column == 7
end

local function render(now)
  local first = os.time({ year = now.year, month = now.month, day = 1, hour = 12 })
  local lead = os.date("*t", first).wday - 1
  local monthDays = os.date("*t", os.time({ year = now.year, month = now.month + 1, day = 0, hour = 12 })).day
  local weeks = math.ceil((lead + monthDays) / 7)

  local pitch = (LAST_WEEK_CENTER - FIRST_WEEK_CENTER) / math.max(weeks - 1, 4)
  -- Even, like the circle, so both center on the same px.
  local weekHeight = 2 * math.floor(math.min(WEEK_ROW_HEIGHT, pitch) / 2)

  local initials = {}
  for column, name in ipairs(WEEKDAYS) do
    initials[column] = cell(label(name, isWeekend(column) and WEEKEND or WEEKDAY, { baseline = "textFixedHeight" }))
  end

  local rows = {
    {
      HEADER_CENTER,
      LABEL_ROW_HEIGHT,
      ui.row({ height = LABEL_ROW_HEIGHT, paddingH = HEADER_INSET, align = "center" }, {
        label(string.upper(os.date("%B", first)), MONTH, { baseline = "textFixedHeight", fontFamily = "SF Pro Text" }),
      }),
    },
    { WEEKDAY_CENTER, LABEL_ROW_HEIGHT, cells(initials, LABEL_ROW_HEIGHT) },
  }

  for week = 0, weeks - 1 do
    local days = {}
    for column = 1, 7 do
      local day = week * 7 + column - lead
      if day == now.day then
        days[column] = todayCell(day)
      elseif day >= 1 and day <= monthDays then
        days[column] = cell(label(tostring(day), isWeekend(column) and WEEKEND or WEEKDAY))
      else
        days[column] = gap(CELL_WIDTH, true)
      end
    end
    table.insert(rows, { FIRST_WEEK_CENTER + week * pitch, weekHeight, cells(days, weekHeight) })
  end

  panel.render(ui.column({ width = WIDTH, height = HEIGHT, gap = 0 }, track(rows, false)))
end

local function refresh(force)
  local now = os.date("*t")
  local key = string.format("%d-%d-%d", now.year, now.month, now.day)
  if force or key ~= shownDate then
    shownDate = key
    render(now)
  end
end

noctalia.setUpdateInterval(60 * 1000)

-- A panel isn't told its output, so this takes the focused one, or else the smallest scale, where
-- the worst case is a digit off by one device px.
local function panelScale()
  local scale = nil
  for _, output in noctalia.outputs() do
    if output.focused then
      return output.scale
    end
    scale = math.min(scale or output.scale, output.scale)
  end
  return scale or 1
end

function onOpen()
  outputScale = panelScale()
  refresh(true)
end

function update()
  refresh(false)
end
