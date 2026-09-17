-- Frames are baked by render.py; the host can't draw gradients.
-- `nix` is the table of Nix-provided values that noctalia/default.nix prepends.

local hovered = false
local elapsed = 0
local shown = nil

-- Hover and clicks are event-driven; the host's default 1s update tick is pure overhead.
noctalia.setUpdateInterval(3600000)

local function framePath()
  if not hovered then
    return "frames/rest.png"
  end
  return string.format("frames/hover-%02d.png", math.floor(elapsed * nix.fps / 1000) % nix.frame_count)
end

local function render()
  local path = framePath()
  if path == shown then
    return
  end
  shown = path
  desktopWidget.render(ui.row({
    width = nix.width,
    height = nix.height,
    onClick = function()
      noctalia.runAsync(nix.noctalia .. " msg panel-toggle control-center")
    end,
    onHover = function(state)
      hovered = state == "true"
      elapsed = 0
      desktopWidget.setNeedsFrameTick(hovered)
      render()
    end,
  }, {
    ui.image({ path = path, width = nix.width, height = nix.height, fit = "stretch" }),
  }))
end

function update()
  desktopWidget.setNeedsFrameTick(hovered)
  render()
end

function onFrameTick(deltaMs)
  elapsed = elapsed + (tonumber(deltaMs) or 0)
  render()
end
