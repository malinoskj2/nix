-- Geometry is measured from macOS 27's menu bar Wi-Fi menu at 1x, in logical px from the menu's
-- top-left. The panel pads its content by PADDING, the inset of Apple's row highlights, so every
-- center below is placed less PADDING. Noctalia snaps layout to whole logical px, so rows are
-- placed from their own centers instead of accumulating sizes.
local WIDTH = 308
local PADDING = 5
local CONTENT_WIDTH = WIDTH - 2 * PADDING
-- Text and separators sit 14 px in from the menu edge.
local INSET = 14 - PADDING
local FONT_SIZE = 13
local DETAIL_FONT_SIZE = 11
local FONT = "SF Pro Text"

local HEADER_CENTER = 20.5
local HEADER_HEIGHT = 24
-- The status line under the header ("Ethernet: …") sits lower than the rows' own spacing would put it.
local STATUS_CENTER = 46
local STATUS_HEIGHT = 18
local ROW_HEIGHT = 22
local NETWORK_ROW_HEIGHT = 32
local DETAIL_ROW_HEIGHT = 16
local PROMPT_HEIGHT = 36
-- A separator is a 1 px line centered 5.5 px below the row above it and 5.5 px above the row below.
local SEPARATOR_GAP = 5.5
local BOTTOM_GAP = 7

local ICON_DIAMETER = 26
local NAME_OFFSET = 34
local HIGHLIGHT_RADIUS = 7
local ERROR_WIDTH = CONTENT_WIDTH - 2 * INSET - NAME_OFFSET
local SPEED_WIDTH = 96
local SPEED_HEIGHT = 20
local SPEED_FONT_SIZE = 14.5
-- The file chooser's selvedge hem: the 14 accents as hard stops, each 12 px wide.
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

local function color(name, alpha)
  return "#" .. nix.palette[name] .. (alpha and string.format("%02x", math.floor(alpha * 255 + 0.5)) or "")
end

local TEXT = color("text")
local SECONDARY = color("subtext1")
-- Like the calendar's weekends: a sky tint for section headers and the names beside values.
local KEY = color("sky", 0.65)
local TERTIARY = color("overlay1")
local ACCENT = color("peach")
local ON_ACCENT = color("crust")
local SEPARATOR = color("text", 0.12)
local HIGHLIGHT = color("text", 0.1)
local ICON_FILL = color("text", 0.16)
local FIELD = color("crust", 0.35)
local ERROR = color("red")
local CLEAR = "#00000000"

local state = {
  nm = nil, -- nil until the first answer, then true or false
  wifiDevice = nil,
  wifiEnabled = false,
  ethernet = nil, -- { device, connection } of a connected wired device
  networks = {},
  known = {},
  route = nil, -- { device, gateway }
  address = nil,
  linkSpeed = nil, -- Mb/s the kernel reports for the route's device
  rates = nil, -- { rx, tx } in bytes per second
}

local hovered = nil
local showOther = false
local prompt = nil -- { ssid, error } while a password is asked for
local password = ""
local joining = {} -- ssid -> true while nmcli connects
local failures = {} -- ssid -> message
local counters = nil
local tick = 0
local open = false
-- Until the first round of queries has answered, nothing renders, so the panel's first frame,
-- which Noctalia holds for it, already has its final size.
local loaded = false
local loading = 0

local render

local function tracked(callback)
  if loaded then
    return callback
  end
  loading += 1
  return function(...)
    callback(...)
    loading -= 1
    if loading == 0 and not loaded then
      loaded = true
      render()
    end
  end
end

-- `nmcli -t` separates fields with `:` and escapes `:` and `\` inside values.
local function splitTerse(line)
  local fields = {}
  local current = {}
  local i = 1
  while i <= #line do
    local c = string.sub(line, i, i)
    if c == "\\" and i < #line then
      table.insert(current, string.sub(line, i + 1, i + 1))
      i += 2
    else
      if c == ":" then
        table.insert(fields, table.concat(current))
        current = {}
      else
        table.insert(current, c)
      end
      i += 1
    end
  end
  table.insert(fields, table.concat(current))
  return fields
end

local function lines(text)
  local result = {}
  for line in string.gmatch(text or "", "[^\n]+") do
    table.insert(result, line)
  end
  return result
end

local function run(argv, callback)
  if not noctalia.runAsync(argv, callback) then
    callback({ exitCode = 127, stdout = "", stderr = "" })
  end
end

-- nmcli comes from PATH so it always matches the running NetworkManager daemon.
local function nmcli(args, callback)
  local argv = { "nmcli" }
  for _, arg in ipairs(args) do
    table.insert(argv, arg)
  end
  run(argv, callback)
end

local function refreshDevices()
  nmcli(
    { "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device" },
    tracked(function(result)
      if result.exitCode ~= 0 then
        state.nm = false
        state.wifiDevice = nil
        state.ethernet = nil
        render()
        return
      end
      state.nm = true
      state.wifiDevice = nil
      state.ethernet = nil
      for _, line in ipairs(lines(result.stdout)) do
        local fields = splitTerse(line)
        local device, kind, status, connection = fields[1], fields[2], fields[3], fields[4]
        if kind == "wifi" and state.wifiDevice == nil then
          state.wifiDevice = device
        elseif kind == "ethernet" and status == "connected" and state.ethernet == nil then
          state.ethernet = { device = device, connection = connection }
        end
      end
      render()
    end)
  )
  nmcli(
    { "-t", "-f", "WIFI", "radio" },
    tracked(function(result)
      if result.exitCode == 0 then
        state.wifiEnabled = noctalia.string.trim(result.stdout) == "enabled"
        render()
      end
    end)
  )
  nmcli(
    { "-t", "-f", "NAME,TYPE", "connection", "show" },
    tracked(function(result)
      if result.exitCode ~= 0 then
        return
      end
      state.known = {}
      for _, line in ipairs(lines(result.stdout)) do
        local fields = splitTerse(line)
        if fields[2] == "802-11-wireless" then
          state.known[fields[1]] = true
        end
      end
      render()
    end)
  )
end

local function refreshNetworks(rescan)
  -- A rescan takes seconds, so it never holds the first render back.
  local wrap = rescan and function(callback)
    return callback
  end or tracked
  nmcli(
    { "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY,RATE", "device", "wifi", "list", "--rescan", rescan and "yes" or "no" },
    wrap(function(result)
      if result.exitCode ~= 0 then
        return
      end
      local bySsid = {}
      local networks = {}
      for _, line in ipairs(lines(result.stdout)) do
        local fields = splitTerse(line)
        local ssid = fields[2]
        if ssid ~= nil and ssid ~= "" then
          local network = {
            ssid = ssid,
            inUse = fields[1] == "*",
            signal = tonumber(fields[3]) or 0,
            secure = fields[4] ~= nil and fields[4] ~= "" and fields[4] ~= "--",
            rate = tonumber(string.match(fields[5] or "", "%d+")),
          }
          local existing = bySsid[ssid]
          if existing == nil then
            bySsid[ssid] = network
            table.insert(networks, network)
          else
            existing.inUse = existing.inUse or network.inUse
            existing.signal = math.max(existing.signal, network.signal)
          end
        end
      end
      table.sort(networks, function(a, b)
        if a.inUse ~= b.inUse then
          return a.inUse
        end
        return a.signal > b.signal
      end)
      state.networks = networks
      render()
    end)
  )
end

local function refreshAddress()
  run(
    { nix.ip, "-j", "route", "show", "default" },
    tracked(function(result)
      local routes = result.exitCode == 0 and noctalia.json.decode(result.stdout) or nil
      local best = nil
      for _, route in ipairs(routes or {}) do
        if best == nil or (route.metric or 0) < (best.metric or 0) then
          best = route
        end
      end
      state.route = best and { device = best.dev, gateway = best.gateway } or nil
      if state.route == nil then
        state.address = nil
        state.linkSpeed = nil
        render()
        return
      end
      -- The speed only fills the header's corner, so it doesn't hold the first render back.
      noctalia.readFileAsync("/sys/class/net/" .. state.route.device .. "/speed", function(contents)
        local speed = tonumber(noctalia.string.trim(contents or ""))
        state.linkSpeed = speed ~= nil and speed > 0 and speed or nil
        render()
      end)
      run(
        { nix.ip, "-j", "-4", "address", "show", "dev", state.route.device },
        tracked(function(address)
          local interfaces = address.exitCode == 0 and noctalia.json.decode(address.stdout) or nil
          local info = interfaces and interfaces[1] and interfaces[1].addr_info
          state.address = info and info[1] and info[1]["local"] or nil
          render()
        end)
      )
    end)
  )
end

local function sampleTraffic()
  if state.route == nil then
    return
  end
  local device = state.route.device
  noctalia.readFileAsync("/proc/net/dev", function(contents)
    if contents == nil then
      return
    end
    for line in string.gmatch(contents, "[^\n]+") do
      local name, rest = string.match(line, "^%s*([^:%s]+):%s*(.*)$")
      if name == device then
        local values = {}
        for value in string.gmatch(rest, "%d+") do
          table.insert(values, tonumber(value))
        end
        local now = noctalia.nowMs()
        local sample = { device = device, at = now, rx = values[1], tx = values[9] }
        if counters ~= nil and counters.device == device and now > counters.at then
          local seconds = (now - counters.at) / 1000
          state.rates = {
            rx = math.max(0, (sample.rx - counters.rx) / seconds),
            tx = math.max(0, (sample.tx - counters.tx) / seconds),
          }
          render()
        end
        counters = sample
        return
      end
    end
  end)
end

local function refreshAll(rescan)
  refreshDevices()
  refreshNetworks(rescan)
  refreshAddress()
end

local function formatRate(bytes)
  if bytes == nil then
    return "—"
  elseif bytes < 1000 then
    return string.format("%d B/s", math.floor(bytes + 0.5))
  elseif bytes < 1e6 then
    return string.format(bytes < 1e4 and "%.1f KB/s" or "%.0f KB/s", bytes / 1e3)
  elseif bytes < 1e9 then
    return string.format(bytes < 1e7 and "%.1f MB/s" or "%.0f MB/s", bytes / 1e6)
  end
  return string.format("%.1f GB/s", bytes / 1e9)
end

local function join(ssid, secret)
  joining[ssid] = true
  failures[ssid] = nil
  local args = { "--wait", "30", "device", "wifi", "connect", ssid }
  if secret ~= nil then
    table.insert(args, "password")
    table.insert(args, secret)
  end
  nmcli(args, function(result)
    joining[ssid] = nil
    if result.exitCode == 0 then
      prompt = nil
      password = ""
    else
      local message = noctalia.string.trim(result.stderr ~= "" and result.stderr or result.stdout)
      message = string.gsub(message, "^Error: ", "")
      if secret ~= nil or string.find(message, "[Ss]ecrets") then
        prompt =
          { ssid = ssid, error = secret ~= nil and "The password may be incorrect." or nil, key = noctalia.nowMs() }
      else
        failures[ssid] = message
      end
    end
    refreshAll(false)
    render()
  end)
  render()
end

local function choose(network)
  if network.inUse or joining[network.ssid] then
    return
  end
  if prompt ~= nil and prompt.ssid == network.ssid then
    prompt = nil
  elseif network.secure and not state.known[network.ssid] then
    prompt = { ssid = network.ssid, key = noctalia.nowMs() }
    password = ""
  else
    prompt = nil
    join(network.ssid, nil)
  end
  render()
end

local function submitPassword()
  if prompt ~= nil and password ~= "" then
    join(prompt.ssid, password)
  end
end

local function openSettings()
  noctalia.runAsync({ nix.noctalia, "msg", "panel-open", "control-center", "network" })
end

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

-- A full-width row whose highlight spans the content box, with its content inset like Apple's.
local function row(key, height, children, props)
  props = props or {}
  local active = props.onClick ~= nil and hovered == key
  return ui.row({
    key = key,
    height = height,
    radius = HIGHLIGHT_RADIUS,
    fill = active and HIGHLIGHT or CLEAR,
    paddingH = INSET,
    gap = 0,
    align = "center",
    onClick = props.onClick,
    onHover = props.onClick and "onRowHover" or nil,
  }, children)
end

-- Tabler's Wi-Fi glyphs drop the arcs a weak signal lacks, where Apple's keeps them dimmed, so the
-- icon is drawn as SVG instead: a wedge and two arcs around the bottom center, like SF Symbols' wifi.
local WIFI_SVG = [[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 18">
<path d="M12 17.2 L8.1 13.3 A5.5 5.5 0 0 1 15.9 13.3 Z" fill="%s" stroke="%s" stroke-width="1.2" stroke-linejoin="round"/>
<path d="M5.2 10.4 A9.6 9.6 0 0 1 18.8 10.4" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="2.5" stroke-linecap="round"/>
<path d="M2.2 7.4 A13.8 13.8 0 0 1 21.8 7.4" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="2.5" stroke-linecap="round"/>
</svg>]]
local WIFI_ICON_WIDTH = 16
local WIFI_ICON_HEIGHT = 12
local DIM_ARC = 0.3
local wifiIcons = {}

local function wifiIcon(signal, fill)
  local bars = signal >= 67 and 3 or signal >= 34 and 2 or 1
  local key = fill .. bars
  if wifiIcons[key] == nil then
    local dir = noctalia.pluginDataDir()
    local path = dir and string.format("%s/wifi-%s-%d.svg", dir, string.sub(fill, 2), bars) or nil
    local svg = string.format(WIFI_SVG, fill, fill, fill, bars >= 2 and 1 or DIM_ARC, fill, bars >= 3 and 1 or DIM_ARC)
    if path == nil or not noctalia.writeFile(path, svg) then
      return nil
    end
    wifiIcons[key] = path
  end
  return wifiIcons[key]
end

-- Noctalia labels take one flat color, so the speed is drawn as SVG text filled with the sunset
-- cloud's stripes, lavender at the top down to rosewater, with the status dot as a glyph in the
-- same run so the pair stays right-aligned whatever the text's width.
local SPEED_SVG = [[<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">
<defs><linearGradient id="stripes" gradientUnits="userSpaceOnUse" x1="0" y1="4" x2="0" y2="16">%s</linearGradient></defs>
<text x="%d" y="15" text-anchor="end" font-family="SF Pro Rounded" font-weight="600" font-size="%s"><tspan fill="%s" font-size="9" baseline-shift="1.5">●</tspan><tspan dx="5" fill="url(#stripes)">%s</tspan></text>
</svg>]]
local speedImages = {}

local function formatSpeed(mbps)
  if mbps >= 1000 then
    return string.format("%g Gb/s", mbps / 1000)
  end
  return string.format("%d Mb/s", mbps)
end

local function speedImage(text)
  if speedImages[text] == nil then
    local stops = {}
    for i = #HEM_COLORS, 1, -1 do
      local index = #HEM_COLORS - i
      local fill = color(HEM_COLORS[i])
      table.insert(stops, string.format('<stop offset="%.4f" stop-color="%s"/>', index / #HEM_COLORS, fill))
      table.insert(stops, string.format('<stop offset="%.4f" stop-color="%s"/>', (index + 1) / #HEM_COLORS, fill))
    end
    local svg = string.format(
      SPEED_SVG,
      SPEED_WIDTH,
      SPEED_HEIGHT,
      SPEED_WIDTH,
      SPEED_HEIGHT,
      table.concat(stops),
      SPEED_WIDTH,
      SPEED_FONT_SIZE,
      ACCENT,
      text
    )
    -- Noctalia caches images by path, so the name carries a hash of the content.
    local digest = 5381
    for i = 1, #svg do
      digest = (digest * 33 + string.byte(svg, i)) % 4294967296
    end
    local dir = noctalia.pluginDataDir()
    local path = dir and string.format("%s/speed-%08x.svg", dir, digest) or nil
    if path == nil or not noctalia.writeFile(path, svg) then
      return nil
    end
    speedImages[text] = path
  end
  return speedImages[text]
end

local function currentSpeed()
  if state.route == nil then
    return nil
  elseif state.linkSpeed ~= nil then
    return state.linkSpeed
  end
  for _, network in ipairs(state.networks) do
    if network.inUse then
      return network.rate
    end
  end
  return nil
end

local function hem()
  local stops = {}
  for _, name in ipairs(HEM_COLORS) do
    table.insert(stops, ui.box({ width = HEM_STOP_WIDTH, height = HEM_HEIGHT, flexGrow = 0, fill = color(name, 0.9) }))
  end
  return ui.row({ height = HEM_HEIGHT, justify = "center", gap = 0 }, stops)
end

local function networkRow(network)
  local connected = network.inUse
  local circle = ui.row({
    width = ICON_DIAMETER,
    height = ICON_DIAMETER,
    radius = ICON_DIAMETER / 2,
    fill = connected and ACCENT or ICON_FILL,
    align = "center",
    justify = "center",
  }, {
    ui.image({
      path = wifiIcon(network.signal, connected and ON_ACCENT or TEXT),
      width = WIFI_ICON_WIDTH,
      height = WIFI_ICON_HEIGHT,
      fit = "contain",
    }),
  })
  local trailing
  if joining[network.ssid] then
    trailing = label("Joining…", { color = SECONDARY })
  elseif network.secure then
    trailing = ui.glyph({ name = "lock-filled", size = 12, color = TERTIARY })
  else
    trailing = gap(0, true)
  end
  return row("net:" .. network.ssid, NETWORK_ROW_HEIGHT, {
    circle,
    gap(NAME_OFFSET - ICON_DIAMETER, true),
    label(network.ssid, { flexGrow = 1, maxWidth = CONTENT_WIDTH - 2 * INSET - NAME_OFFSET - 60 }),
    trailing,
  }, {
    onClick = not connected and function()
      choose(network)
    end or nil,
  })
end

local function passwordRow(ssid)
  return ui.row({ key = "prompt:" .. ssid, height = PROMPT_HEIGHT, paddingH = INSET, gap = 8, align = "center" }, {
    gap(NAME_OFFSET - 8, true),
    ui.row({ height = 26, radius = 7, fill = FIELD, paddingH = 0, align = "center", flexGrow = 1 }, {
      ui.input({
        key = "password:" .. ssid .. ":" .. tostring(prompt.key),
        password = true,
        focus = true,
        frameVisible = false,
        placeholder = "Password",
        fontSize = FONT_SIZE,
        height = 26,
        flexGrow = 1,
        onChange = function(value)
          password = value
        end,
        onSubmit = submitPassword,
      }),
    }),
    ui.row({
      key = "join:" .. ssid,
      height = 26,
      radius = 7,
      paddingH = 12,
      align = "center",
      fill = hovered == "join:" .. ssid and color("peach", 0.85) or ACCENT,
      onClick = submitPassword,
      onHover = "onRowHover",
    }, { label("Join", { color = ON_ACCENT, fontWeight = "semibold" }) }),
  })
end

local function detailRow(name, value)
  return ui.row({ height = DETAIL_ROW_HEIGHT, paddingH = INSET, align = "center", justify = "space_between" }, {
    label(name, { fontSize = DETAIL_FONT_SIZE, color = KEY }),
    label(value, { fontSize = DETAIL_FONT_SIZE, color = TEXT }),
  })
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
    local center = last and (last.center + last.height / 2 + (space or 0) + height / 2) or height / 2
    return self.add(center, height, node)
  end

  function self.separator()
    local center = last.center + last.height / 2 + SEPARATOR_GAP
    table.insert(items, {
      center,
      1,
      ui.row({ height = 1, paddingH = INSET }, { ui.box({ height = 1, flexGrow = 1, fill = SEPARATOR }) }),
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

local function sectionHeader(text, props)
  return row("section:" .. text, ROW_HEIGHT, {
    label(text, { color = KEY, fontWeight = "bold", flexGrow = 1 }),
    props and props.trailing or gap(0, true),
  }, props)
end

function render()
  if not open or not loaded then
    return
  end
  local layout = stack()
  local hasWifi = state.wifiDevice ~= nil

  local speed = currentSpeed()
  local speedPath = speed and speedImage(formatSpeed(speed))
  layout.add(
    HEADER_CENTER,
    HEADER_HEIGHT,
    ui.row({ height = HEADER_HEIGHT, paddingH = INSET, align = "center" }, {
      label("Network", { fontWeight = "bold", color = ACCENT, flexGrow = 1 }),
      speedPath and ui.row({ key = "speed", onClick = openSettings }, {
        ui.image({ path = speedPath, width = SPEED_WIDTH, height = SPEED_HEIGHT, fit = "contain" }),
      }) or gap(0, true),
    })
  )

  -- Like Apple's "Ethernet: <adapter>", the key is bold and the value regular.
  local status = nil
  if state.nm == false then
    status = { value = "NetworkManager isn't running" }
  elseif state.ethernet ~= nil then
    status = {
      key = hasWifi and "Ethernet:" or "Connected:",
      value = state.ethernet.connection ~= "" and state.ethernet.connection or state.ethernet.device,
    }
  elseif not hasWifi and state.nm == true then
    status = { value = "Not Connected" }
  end
  if status ~= nil then
    local parts = { label(status.value, { color = SECONDARY, flexGrow = 1 }) }
    if status.key then
      table.insert(parts, 1, label(status.key, { color = KEY, fontWeight = "semibold" }))
    end
    layout.add(
      STATUS_CENTER,
      STATUS_HEIGHT,
      ui.row({ height = STATUS_HEIGHT, paddingH = INSET, gap = 4, align = "center" }, parts)
    )
  end

  if hasWifi and state.wifiEnabled then
    local known, other = {}, {}
    for _, network in ipairs(state.networks) do
      if network.inUse or state.known[network.ssid] then
        table.insert(known, network)
      else
        table.insert(other, network)
      end
    end

    local function addNetworks(list)
      for _, network in ipairs(list) do
        layout.next(NETWORK_ROW_HEIGHT, networkRow(network))
        if prompt ~= nil and prompt.ssid == network.ssid then
          layout.next(PROMPT_HEIGHT, passwordRow(network.ssid))
          if prompt.error then
            layout.next(
              DETAIL_ROW_HEIGHT,
              ui.row({ height = DETAIL_ROW_HEIGHT, paddingH = INSET, align = "center" }, {
                gap(NAME_OFFSET, true),
                label(prompt.error, { fontSize = DETAIL_FONT_SIZE, color = ERROR, maxWidth = ERROR_WIDTH }),
              })
            )
          end
        elseif failures[network.ssid] then
          layout.next(
            DETAIL_ROW_HEIGHT,
            ui.row({ height = DETAIL_ROW_HEIGHT, paddingH = INSET, align = "center" }, {
              gap(NAME_OFFSET, true),
              label(failures[network.ssid], { fontSize = DETAIL_FONT_SIZE, color = ERROR, maxWidth = ERROR_WIDTH }),
            })
          )
        end
      end
    end

    if #known > 0 then
      layout.separator()
      layout.next(ROW_HEIGHT, sectionHeader(#known == 1 and "Known Network" or "Known Networks"), SEPARATOR_GAP)
      addNetworks(known)
    end
    layout.separator()
    layout.next(
      ROW_HEIGHT,
      sectionHeader("Other Networks", {
        trailing = ui.glyph({ name = showOther and "chevron-down" or "chevron-right", size = 14, color = SECONDARY }),
        onClick = function()
          showOther = not showOther
          if showOther then
            refreshNetworks(true)
          end
          render()
        end,
      }),
      SEPARATOR_GAP
    )
    if showOther then
      if #other == 0 then
        layout.next(
          ROW_HEIGHT,
          ui.row({ height = ROW_HEIGHT, paddingH = INSET, align = "center" }, {
            label("No networks found", { color = TERTIARY }),
          })
        )
      end
      addNetworks(other)
    end
  end

  if state.route ~= nil then
    layout.separator()
    layout.next(ROW_HEIGHT, sectionHeader("Details"), SEPARATOR_GAP)
    local rates = state.rates or {}
    layout.next(DETAIL_ROW_HEIGHT, detailRow("IP Address", state.address or "—"))
    layout.next(DETAIL_ROW_HEIGHT, detailRow("Router", state.route.gateway or "—"))
    layout.next(DETAIL_ROW_HEIGHT, detailRow("Download", formatRate(rates.rx)))
    layout.next(DETAIL_ROW_HEIGHT, detailRow("Upload", formatRate(rates.tx)))
  end

  layout.next(HEM_HEIGHT, hem(), HEM_GAP)

  local tree, height = layout.build()
  panel.setSize(WIDTH, height)
  panel.render(tree)
end

function onOpen()
  open = true
  hovered = nil
  showOther = false
  prompt = nil
  failures = {}
  counters = nil
  state.rates = nil
  tick = 0
  panel.setWantsSecondTicks(true)
  render()
  refreshAll(false)
  -- A rescan takes a few seconds, so the cached list shows first.
  refreshNetworks(true)
end

function onClose()
  open = false
end

function update()
  if not open then
    return
  end
  tick += 1
  sampleTraffic()
  if tick % 5 == 0 then
    refreshAll(false)
  end
end
