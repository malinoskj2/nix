-- Frames are baked by render.py; the host can't draw gradients.
local FRAMES = 48
local FPS = 30
-- true = shimmer continuously at AMBIENT_FPS instead of only on hover.
local AMBIENT = false
local AMBIENT_FPS = 12

local hovered = false
local elapsed = 0
local shown = nil

local function framePath()
  if not hovered and not AMBIENT then
    return "frames/rest.png"
  end
  local fps = hovered and FPS or AMBIENT_FPS
  return string.format("frames/hover-%02d.png", math.floor(elapsed * fps / 1000) % FRAMES)
end

local function render()
  local path = framePath()
  if path == shown then
    return
  end
  shown = path
  desktopWidget.render(ui.row({
    width = 52,
    height = 24,
    onClick = "onClick",
    onHover = "onHover",
  }, {
    ui.image({ path = path, width = 52, height = 24, fit = "stretch" }),
  }))
end

function update()
  -- Hover and clicks are event-driven; the host's default 1s update tick is pure overhead.
  noctalia.setUpdateInterval(3600000)
  desktopWidget.setNeedsFrameTick(hovered or AMBIENT)
  render()
end

function onHover(state)
  hovered = state == "true"
  elapsed = 0
  desktopWidget.setNeedsFrameTick(hovered or AMBIENT)
  render()
end

function onFrameTick(deltaMs)
  elapsed = elapsed + (tonumber(deltaMs) or 0)
  render()
end

function onClick()
  noctalia.runAsync("noctalia msg panel-toggle control-center")
end
