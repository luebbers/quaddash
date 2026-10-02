-- JoyView - live view of what a sim / game sees over USB joystick
-- EdgeTX 3.x, color screen (developed on a RadioMaster TX15)
--
-- Assumes the USB joystick in "Classic" mode: CH1-8 = axes, CH9-32 = buttons
-- (a button is pressed while its channel is > 0). Labels come from the mixer
-- names, so the widget adapts to whatever is mapped in the model.
-- Sticks are drawn for mode 2: left = CH4 (yaw) / CH3 (throttle), right = CH1 / CH2.

local options = {}

local AXIS_NAMES = { "X", "Y", "Z", "rX", "rY", "rZ", "Sl", "Dl" }
local MAX_CH = 32
local C

local floor = math.floor

local function initColors()
  C = {
    bg     = lcd.RGB(0x10, 0x14, 0x19),
    panel  = lcd.RGB(0x1B, 0x22, 0x2B),
    track  = lcd.RGB(0x2E, 0x38, 0x43),
    text   = lcd.RGB(0xF2, 0xF4, 0xF6),
    dim    = lcd.RGB(0x8A, 0x96, 0xA3),
    accent = lcd.RGB(0x22, 0xD3, 0xEE),
    accentDark = lcd.RGB(0x0B, 0x3A, 0x45),
    stick  = lcd.RGB(0xF5, 0x9E, 0x0B),
  }
end

------------------------------------------------------------------------
-- Channel mapping (re-read every few seconds, so mixer edits show up)
------------------------------------------------------------------------

local function mixName(ch)
  local n = model.getMixesCount(ch - 1)
  if not n or n == 0 then return nil end
  for i = 0, n - 1 do
    local m = model.getMix(ch - 1, i)
    if m and m.name and m.name ~= "" then return m.name end
  end
  return "CH" .. ch
end

local function scanChannels(wgt)
  wgt.axes, wgt.buttons = {}, {}
  for ch = 1, 8 do
    wgt.axes[ch] = mixName(ch)
  end
  for ch = 9, MAX_CH do
    local name = mixName(ch)
    if name then
      wgt.buttons[#wgt.buttons + 1] = { ch = ch, name = name, btn = ch - 8 }
    end
  end
  wgt.scannedAt = getTime()
end

local function chVal(ch)
  return (getValue("ch" .. ch) or 0) / 1024     -- -1 .. 1
end

------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------

local function textC(cx, cy, txt, font, color)
  local w, h = lcd.sizeText(txt, font)
  lcd.drawText(floor(cx - w / 2), floor(cy - h / 2), txt, font + color)
end

local function pct(v)
  return string.format("%d", floor(v * 100 + (v >= 0 and 0.5 or -0.5)))
end

local function stickBox(x, y, size, chX, chY)
  local vx, vy = chVal(chX), chVal(chY)
  local cx, cy = x + floor(size / 2), y + floor(size / 2)
  local r = floor(size / 2) - 6
  lcd.drawFilledRectangle(x, y, size, size, C.panel)
  lcd.drawLine(x + 6, cy, x + size - 7, cy, DOTTED, C.track)
  lcd.drawLine(cx, y + 6, cx, y + size - 7, DOTTED, C.track)
  lcd.drawAnnulus(cx, cy, r - 1, r, 0, 360, C.track)
  local px = cx + floor(vx * r)
  local py = cy - floor(vy * r)
  lcd.drawLine(cx, cy, px, py, SOLID, C.accentDark)
  lcd.drawFilledCircle(px, py, 8, C.stick)
  lcd.drawFilledCircle(px, py, 3, C.bg)
  local label = string.format("%s %s   %s %s", AXIS_NAMES[chX], pct(vx), AXIS_NAMES[chY], pct(vy))
  textC(cx, y + size + 11, label, SMLSIZE, C.dim)
end

local function slider(x, y, w, h, ch, name)
  local v = chVal(ch)
  lcd.drawFilledRectangle(x, y, w, h, C.panel)
  local inner = h - 4
  local fill = floor(inner * (v + 1) / 2)
  if fill > 0 then
    lcd.drawFilledRectangle(x + 2, y + 2 + inner - fill, w - 4, fill, C.accent)
  end
  lcd.drawLine(x, y + floor(h / 2), x + w - 1, y + floor(h / 2), DOTTED, C.track)
  textC(x + w / 2, y - 9, name, SMLSIZE, C.text)
  textC(x + w / 2, y + h + 9, AXIS_NAMES[ch], SMLSIZE, C.dim)
end

local function buttonGrid(wgt, x, y, w, h)
  local n = #wgt.buttons
  if n == 0 then
    textC(x + w / 2, y + h / 2, "No buttons mapped (CH9-32)", 0, C.dim)
    return
  end
  local cols = math.min(8, n)
  local rows = math.ceil(n / cols)
  local gap = 5
  local bw = floor((w - (cols - 1) * gap) / cols)
  local bh = math.min(40, floor((h - (rows - 1) * gap) / rows))
  for i, b in ipairs(wgt.buttons) do
    local col = (i - 1) % cols
    local row = floor((i - 1) / cols)
    local bx = x + col * (bw + gap)
    local by = y + row * (bh + gap)
    local on = chVal(b.ch) > 0
    lcd.drawFilledRectangle(bx, by, bw, bh, on and C.accent or C.panel)
    lcd.drawText(bx + 3, by + 1, "B" .. b.btn, SMLSIZE + (on and C.bg or C.dim))
    textC(bx + bw / 2, by + bh * 0.62, b.name, SMLSIZE, on and C.bg or C.text)
  end
end

------------------------------------------------------------------------
-- Widget API
------------------------------------------------------------------------

local function create(zone, opts)
  initColors()
  local wgt = { zone = zone, options = opts }
  scanChannels(wgt)
  return wgt
end

local function update(wgt, opts)
  wgt.options = opts
  scanChannels(wgt)
end

local function background(wgt)
end

local function refresh(wgt, event, touchState)
  if getTime() - (wgt.scannedAt or 0) > 300 then scanChannels(wgt) end
  local x, y, w, h
  if event ~= nil then
    x, y, w, h = 0, 0, LCD_W, LCD_H
  else
    x, y, w, h = wgt.zone.x, wgt.zone.y, wgt.zone.w, wgt.zone.h
  end
  lcd.drawFilledRectangle(x, y, w, h, C.bg)

  -- header
  local info = model.getInfo()
  lcd.drawText(x + 8, y + 5, "USB JOYSTICK", SMLSIZE + C.accent)
  local name = info and info.name or ""
  local nw = lcd.sizeText(name, SMLSIZE)
  lcd.drawText(x + w - 8 - nw, y + 5, name, SMLSIZE + C.dim)

  -- sticks + sliders
  local top = y + 26
  local nb = #wgt.buttons
  local gridH = (nb > 8) and 85 or 42
  local size = math.min(floor(w * 0.30), h - 26 - gridH - 40)
  stickBox(x + 8, top, size, 4, 3)
  stickBox(x + w - 8 - size, top, size, 1, 2)

  local sliders = {}
  for ch = 5, 8 do
    if wgt.axes[ch] then sliders[#sliders + 1] = ch end
  end
  if #sliders > 0 then
    local midL, midR = x + 8 + size, x + w - 8 - size
    local sw, sgap = 26, 18
    local total = #sliders * sw + (#sliders - 1) * sgap
    local sx = floor((midL + midR - total) / 2)
    for i, ch in ipairs(sliders) do
      slider(sx + (i - 1) * (sw + sgap), top + 14, sw, size - 28, ch, wgt.axes[ch])
    end
  end

  buttonGrid(wgt, x + 8, y + h - gridH - 6, w - 16, gridH)
end

return { name = "JoyView", options = options, create = create, update = update,
         background = background, refresh = refresh }
