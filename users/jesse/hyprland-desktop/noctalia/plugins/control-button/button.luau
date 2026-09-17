-- `nix` is prepended by users/jesse/hyprland-desktop/noctalia/default.nix.
-- The frames are prerendered because Noctalia's UI can't draw gradients; see render.py.

-- Hover and clicks are event-driven, so the host's default 1s update tick is pure overhead.
local UPDATE_INTERVAL_MS = 60 * 60 * 1000

local hovered = false
local elapsedMs = 0
local shown = nil

local function framePath()
  if not hovered then
    return "frames/rest.png"
  end

  return string.format("frames/hover-%02d.png", math.floor(elapsedMs * nix.fps / 1000) % nix.frame_count)
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
      noctalia.runAsync({ nix.noctalia, "msg", "panel-toggle", "control-center" })
    end,
    onHover = function(state)
      hovered = state == "true"
      elapsedMs = 0
      desktopWidget.setNeedsFrameTick(hovered)
      render()
    end,
  }, {
    ui.image({ path = path, width = nix.width, height = nix.height, fit = "stretch" }),
  }))
end

noctalia.setUpdateInterval(UPDATE_INTERVAL_MS)

function update()
  desktopWidget.setNeedsFrameTick(hovered)
  render()
end

function onFrameTick(deltaMs)
  elapsedMs = elapsedMs + (tonumber(deltaMs) or 0)
  render()
end
