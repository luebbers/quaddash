-- QuadDash - Preflight- & Debug-Dashboard fuer ELRS + Betaflight Quads
-- EdgeTX 3.x, Farbdisplay (entwickelt fuer RadioMaster TX15)
--
-- Seiten: 1 Preflight | 2 Link | 3 Session
-- Normale Ansicht: Seite ueber Widget-Option "Page"
-- Vollbild: Wischen / Drehrad / PAGE = Seite wechseln, Kopfzeile antippen = naechste Seite,
--           ENTER lang oder Reset-Button (Seite 3) = Statistik zuruecksetzen

local options = {
  { "Page",     VALUE, 1,   1,   3   },
  { "Cells",    VALUE, 0,   0,   8   },   -- 0 = automatisch erkennen
  { "LowCell",  VALUE, 350, 300, 420 },   -- Warnschwelle in 1/100 V pro Zelle
  { "CritCell", VALUE, 330, 280, 400 },   -- kritische Schwelle in 1/100 V pro Zelle
  { "Voice",    BOOL,  1 },
}

local PAGES = { "Preflight", "Link", "Session" }
local HIST_N = 120          -- Verlauf: 120 Samples ...
local HIST_DT = 50          -- ... alle 0,5 s = 60 s
local NEW_BATT_GAP = 1000   -- 10 s ohne Link -> beim Wiederverbinden auf neuen Akku pruefen
local HEADER_H = 30
local C

local function initColors()
  C = {
    bg     = lcd.RGB(0x10, 0x14, 0x19),
    panel  = lcd.RGB(0x1B, 0x22, 0x2B),
    track  = lcd.RGB(0x2E, 0x38, 0x43),
    text   = lcd.RGB(0xF2, 0xF4, 0xF6),
    dim    = lcd.RGB(0x8A, 0x96, 0xA3),
    green  = lcd.RGB(0x2E, 0xCC, 0x71),
    yellow = lcd.RGB(0xF1, 0xC4, 0x0F),
    orange = lcd.RGB(0xE6, 0x7E, 0x22),
    red    = lcd.RGB(0xE7, 0x4C, 0x3C),
    blue   = lcd.RGB(0x3A, 0x9A, 0xE8),
    sky    = lcd.RGB(0x2C, 0x6E, 0xB5),
    ground = lcd.RGB(0x8B, 0x5A, 0x2B),
  }
end

------------------------------------------------------------------------
-- Sensoren
------------------------------------------------------------------------

local ids = {}

local function sensor(name)
  local id = ids[name]
  if id == nil then
    local fi = getFieldInfo(name)
    id = fi and fi.id or false
    ids[name] = id
  end
  if id == false then return nil end
  return getValue(id)
end

local function num(name)
  local v = sensor(name)
  if type(v) == "number" then return v end
  return nil
end

local function newStats()
  return { flight = 0, startCell = nil, minCell = nil, maxCurr = nil, mah = nil,
           minLQ = nil, minRSSI = nil, losses = 0, longestLoss = 0 }
end

local function cellsOf(wgt)
  if wgt.options.Cells > 0 then return wgt.options.Cells end
  return wgt.s.cells or 1
end

local function bestRssi(d)
  local b
  for _, r in ipairs({ d.r1, d.r2 }) do
    if r and r < 0 and (not b or r > b) then b = r end
  end
  return b
end

local function resetStats(wgt)
  local s = wgt.s
  s.stats = newStats()
  s.hist = {}
  if s.up and s.d.cell then s.stats.startCell = s.d.cell end
end

local function lowerOf(a, b) if a == nil or b < a then return b end return a end
local function higherOf(a, b) if a == nil or b > a then return b end return a end

------------------------------------------------------------------------
-- Logik (laeuft sichtbar und unsichtbar)
------------------------------------------------------------------------

local function readSensors(d)
  d.v, d.curr, d.capa, d.pct = num("RxBt"), num("Curr"), num("Capa"), num("Bat%")
  d.rq, d.r1, d.r2, d.rsnr, d.ant = num("RQly"), num("1RSS"), num("2RSS"), num("RSNR"), num("ANT")
  d.tq, d.trss, d.tsnr = num("TQly"), num("TRSS"), num("TSNR")
  d.tpwr, d.rfmd = num("TPWR"), num("RFMD")
  d.pitch, d.roll, d.yaw = num("Ptch"), num("Roll"), num("Yaw")
  local fm = sensor("FM")
  d.fm = (type(fm) == "string" and fm ~= "") and fm or nil
end

local function voice(wgt, now)
  local s, d, o = wgt.s, wgt.s.d, wgt.options
  if o.Voice ~= 1 or not s.up or not d.cell then return end
  local low, crit = o.LowCell / 100, o.CritCell / 100
  local level = 0
  if d.cell < crit then level = 2 elseif d.cell < low then level = 1 end
  if level == 0 then
    s.lowSince = nil
    if d.cell > low + 0.1 then s.warnLevel = 0 end
    return
  end
  s.lowSince = s.lowSince or now
  if now - s.lowSince < 300 then return end            -- 3 s anhaltend (Spannungseinbrueche filtern)
  local repeatTicks = (level == 2) and 1000 or 3000     -- kritisch alle 10 s, sonst alle 30 s
  if level > (s.warnLevel or 0) or now - (s.lastWarn or 0) > repeatTicks then
    playFile("SYSTEM/lowbatt.wav")
    playNumber(math.floor(d.cell * 100 + 0.5), UNIT_VOLTS, PREC2)
    s.lastWarn, s.warnLevel = now, level
  end
end

local function tick(wgt)
  local s, d = wgt.s, wgt.s.d
  local now = getTime()
  local dt = now - (s.lastTick or now)
  s.lastTick = now

  -- neu angelegte Sensoren (Discover) alle 5 s nachladen
  if now - (s.idsAt or 0) > 500 then
    for k, v in pairs(ids) do if v == false then ids[k] = nil end end
    s.idsAt = now
  end

  local up = (getRSSI() or 0) > 0
  if up then readSensors(d) end

  -- Link-Wechsel
  if up and not s.up then
    if s.downSince then
      local gap = now - s.downSince
      if s.lossCounted then s.stats.longestLoss = math.max(s.stats.longestLoss, gap) end
      if gap > NEW_BATT_GAP then s.checkBatt = true end
    else
      s.checkBatt = true                                   -- erste Verbindung
    end
    s.downSince, s.lossCounted, s.everUp = nil, false, true
  elseif not up and s.up then
    s.downSince = now
    s.lossCounted = s.armed
    if s.armed then s.stats.losses = s.stats.losses + 1 end
  end
  s.up = up

  -- Zellen erkennen / neuer Akku
  if up and s.checkBatt and d.v and d.v > 0.5 then
    local guess = math.max(1, math.ceil(d.v / 4.35))
    local cellNow = d.v / guess
    local st = s.stats
    -- Neuer Akku nur bei anderer Zellenzahl, ohne bisherigen Flug oder bei vollem Akku.
    -- (Nach Landung/Crash erholt sich die Spannung ohne Last - das ist kein neuer Akku.)
    local fresh = cellNow >= 4.0 and (not st.minCell or cellNow > st.minCell + 0.4)
    if s.cells ~= guess or st.flight == 0 or fresh then
      s.cells = guess
      s.stats = newStats()
      s.hist = {}
      s.stats.startCell = d.v / cellsOf(wgt)
    end
    s.checkBatt = false
  end

  d.cell = (d.v and d.v > 0.5) and d.v / cellsOf(wgt) or nil

  -- Arm-Status: CH5 (ELRS-Arm-Kanal) und Betaflight-Flugmodus ("*" = disarmed, "!ERR" = gesperrt)
  local armSwitch = getValue("ch5") > 0
  local fmBlocks = up and d.fm and (string.sub(d.fm, -1) == "*" or string.find(d.fm, "!ERR", 1, true) ~= nil)
  s.armSwitch = armSwitch
  s.armed = armSwitch and not fmBlocks and s.everUp

  -- Statistik
  local st = s.stats
  if s.armed then st.flight = st.flight + dt end
  if up then
    if d.capa then st.mah = d.capa end
    if s.armed then
      if d.cell then st.minCell = lowerOf(st.minCell, d.cell) end
      if d.curr then st.maxCurr = higherOf(st.maxCurr, d.curr) end
      if d.rq then st.minLQ = lowerOf(st.minLQ, d.rq) end
      local br = bestRssi(d)
      if br then st.minRSSI = lowerOf(st.minRSSI, br) end
    end
  end

  -- Verlauf
  if s.everUp and now - (s.histAt or 0) >= HIST_DT then
    s.histAt = now
    s.hist[#s.hist + 1] = { lq = up and (d.rq or 0) or -1, rssi = up and bestRssi(d) or nil }
    if #s.hist > HIST_N then table.remove(s.hist, 1) end
  end

  voice(wgt, now)
end

------------------------------------------------------------------------
-- Zeichen-Helfer
------------------------------------------------------------------------

local floor = math.floor

local function fmtTime(ticks)
  local sec = floor((ticks or 0) / 100)
  return string.format("%02d:%02d", floor(sec / 60), sec % 60)
end

local function fmt(v, pattern, fallback)
  if v == nil then return fallback or "--" end
  if string.find(pattern, "%d", 1, true) then v = floor(v + 0.5) end
  return string.format(pattern, v)
end

local function fitFont(txt, maxW, maxH)
  for _, f in ipairs({ XXLSIZE, DBLSIZE, MIDSIZE, 0 }) do
    local w, h = lcd.sizeText(txt, f)
    if w <= maxW and (not maxH or h <= maxH) then return f end
  end
  return SMLSIZE
end

local function textC(cx, cy, txt, font, color)
  local w, h = lcd.sizeText(txt, font)
  lcd.drawText(floor(cx - w / 2), floor(cy - h / 2), txt, font + color)
end

local function textR(rx, y, txt, font, color)
  local w = lcd.sizeText(txt, font)
  lcd.drawText(floor(rx - w), floor(y), txt, font + color)
end

local function cellColor(wgt, c)
  if not c then return C.dim end
  if c < wgt.options.CritCell / 100 then return C.red end
  if c < wgt.options.LowCell / 100 then return C.yellow end
  return C.green
end

local function lqColor(q)
  if not q then return C.dim end
  if q >= 80 then return C.green elseif q >= 50 then return C.yellow end
  return C.red
end

local function rssiColor(r)
  if not r or r >= 0 then return C.dim end
  if r > -85 then return C.green elseif r > -100 then return C.yellow end
  return C.red
end

local function snrColor(v)
  if not v then return C.dim end
  if v > 5 then return C.green elseif v > 0 then return C.yellow end
  return C.red
end

local function gauge(cx, cy, r, frac, color, value, label, sub)
  local th = math.max(5, floor(r * 0.16))
  lcd.drawAnnulus(cx, cy, r - th, r, -135, 135, C.track)
  if frac and frac > 0.005 then
    lcd.drawAnnulus(cx, cy, r - th, r, -135, floor(-135 + 270 * math.min(frac, 1)), color)
  end
  textC(cx, cy - r * 0.05, value, fitFont(value, (r - th) * 1.6, r), frac and C.text or C.dim)
  textC(cx, cy + r * 0.62, label, SMLSIZE, C.dim)
  if sub then textC(cx, cy + r + 9, sub, 0, C.dim) end
end

local function bar(x, y, w, h, frac, color)
  lcd.drawFilledRectangle(x, y, w, h, C.track)
  if frac and frac > 0 then
    lcd.drawFilledRectangle(x, y, math.max(1, floor(w * math.min(frac, 1))), h, color)
  end
end

local function dot(x, cy, color, label)
  lcd.drawFilledCircle(x + 6, cy, 6, color)
  local _, h = lcd.sizeText(label, 0)
  lcd.drawText(x + 17, floor(cy - h / 2), label, C.text)
end

------------------------------------------------------------------------
-- Kopfzeile
------------------------------------------------------------------------

local function statusInfo(wgt)
  local s = wgt.s
  if not s.up then
    if s.everUp then return "KEIN LINK", C.red end
    return "WARTE AUF QUAD", C.track
  end
  local fm = s.d.fm or ""
  if string.find(fm, "!FS!", 1, true) then return "FAILSAFE", C.red end
  if s.armed then return "ARMED", C.red end
  if string.find(fm, "!ERR", 1, true) then return "ARM GESPERRT", C.orange end
  return "DISARMED", C.green
end

-- Senderakku: Symbol + Spannung, rechtsbuendig bis rx. Gibt die linke Kante zurueck.
local function txBattery(rx, cy)
  local v = getValue("tx-voltage")
  if type(v) ~= "number" or v <= 0 then return rx end
  local gs = getGeneralSettings()
  local vMin, vMax, vWarn = gs.battMin or 6.0, gs.battMax or 8.4, gs.battWarn or 6.6
  local frac = math.max(0, math.min(1, (v - vMin) / (vMax - vMin)))
  local color = C.green
  if v <= vWarn then color = C.red elseif frac < 0.3 then color = C.yellow end

  local txt = string.format("%.1fV", v)
  local tw, th = lcd.sizeText(txt, SMLSIZE)
  lcd.drawText(floor(rx - tw), floor(cy - th / 2), txt, SMLSIZE + color)
  local bw, bh = 22, 12
  local bx, by = floor(rx - tw - 6 - bw - 3), floor(cy - bh / 2)
  lcd.drawRectangle(bx, by, bw, bh, C.dim)
  lcd.drawFilledRectangle(bx + bw, by + 3, 3, bh - 6, C.dim)
  if frac > 0 then
    lcd.drawFilledRectangle(bx + 2, by + 2, math.max(1, floor((bw - 4) * frac)), bh - 4, color)
  end
  return bx
end

local function header(wgt, x, y, w, full, page)
  local s = wgt.s
  local cy = y + HEADER_H / 2
  lcd.drawFilledRectangle(x, y, w, HEADER_H, C.panel)
  local txt, col = statusInfo(wgt)
  local tw, th = lcd.sizeText(txt, 0)
  lcd.drawFilledRectangle(x + 4, y + 4, tw + 16, HEADER_H - 8, col)
  lcd.drawText(x + 12, floor(cy - th / 2), txt, C.text)
  local leftEnd = x + tw + 20
  if s.up and s.d.fm then
    lcd.drawText(x + tw + 28, floor(cy - th / 2), s.d.fm, C.dim)
    leftEnd = x + tw + 28 + lcd.sizeText(s.d.fm, 0)
  end

  -- rechts: Senderakku, dann Zellen + Flugzeit
  local rightEnd = txBattery(x + w - 8, cy)
  local right = string.format("%dS  %s", cellsOf(wgt), fmtTime(s.stats.flight))
  if rightEnd < x + w - 8 then rightEnd = rightEnd - 12 end
  textR(rightEnd, floor(cy - th / 2), right, 0, s.armed and C.text or C.dim)
  rightEnd = rightEnd - lcd.sizeText(right, 0)

  -- Mitte: Seitentitel, gekuerzt oder weggelassen, wenn der Platz nicht reicht
  local room = rightEnd - leftEnd - 16
  local title = string.format("%d/%d %s", page, #PAGES, PAGES[page])
  if lcd.sizeText(title, 0) > room then title = PAGES[page] end
  local titleW = lcd.sizeText(title, 0)
  if titleW <= room then
    textC(leftEnd + 8 + room / 2, cy, title, 0, full and C.text or C.dim)
  end
end

local function noLinkBanner(wgt, x, y, w)
  local s, d = wgt.s, wgt.s.d
  if s.up or not s.everUp then return end
  local h = 54
  lcd.drawFilledRectangle(x, y, w, h, C.red)
  local secs = floor((getTime() - (s.downSince or getTime())) / 100)
  textC(x + w / 2, y + 16, string.format("KEINE TELEMETRIE  seit %d s", secs), MIDSIZE, C.text)
  local last = string.format("Zuletzt: %s/Zelle   LQ %s   RSSI %s",
    fmt(d.cell, "%.2fV"), fmt(d.rq, "%d%%"), fmt(bestRssi(d), "%ddBm"))
  textC(x + w / 2, y + 40, last, 0, C.text)
end

------------------------------------------------------------------------
-- Seite 1: Preflight
------------------------------------------------------------------------

local function pagePreflight(wgt, x, y, w, h)
  local s, d, st = wgt.s, wgt.s.d, wgt.s.stats
  local up = s.up
  local bottomH = 66
  local r = floor(math.min(w / 6 - 8, (h - bottomH - 24) / 2))
  local cy = y + floor((h - bottomH - 2 * r - 22) / 2) + r
  local cells = cellsOf(wgt)
  local function c(col) return up and col or C.dim end

  local cell = d.cell
  gauge(x + w / 6, cy, r, cell and (cell - 3.0) / (4.35 - 3.0), c(cellColor(wgt, cell)),
    fmt(cell, "%.2fV"), "pro Zelle", d.v and string.format("%.2fV  %dS", d.v, cells))

  gauge(x + w / 2, cy, r, d.rq and d.rq / 100, c(lqColor(d.rq)),
    fmt(d.rq, "%d%%"), "LQ", "RSSI " .. fmt(bestRssi(d), "%ddBm"))

  local currMax = (cells <= 1 and 20) or (cells <= 4 and 60) or 100
  gauge(x + w * 5 / 6, cy, r, d.curr and d.curr / currMax, c(C.blue),
    fmt(d.curr, "%.1fA"), "Strom", "max " .. fmt(st.maxCurr, "%.1fA"))

  -- Balken
  local by = y + h - bottomH
  local half = floor(w / 2) - 6
  local br = bestRssi(d)
  lcd.drawText(x, by, "RSSI", SMLSIZE + C.dim)
  bar(x + 40, by + 3, half - 110, 10, br and (br + 120) / 80, c(rssiColor(br)))
  textR(x + half, by, fmt(br, "%d dBm"), SMLSIZE, C.text)
  local ax = x + half + 12
  lcd.drawText(ax, by, "Akku", SMLSIZE + C.dim)
  bar(ax + 40, by + 3, half - 110, 10, d.pct and d.pct / 100, c(cellColor(wgt, cell)))
  textR(x + w, by, fmt(d.capa, "%d mAh"), SMLSIZE, C.text)

  -- Checkliste
  local ly = by + 44
  local colW = floor(w / 4)
  lcd.drawFilledRectangle(x, ly - 16, w, 32, C.panel)
  local linkCol = (not up and C.red) or (d.rq and d.rq >= 90 and C.green) or C.yellow
  local battCol = C.dim
  if up and cell then
    battCol = (cell >= 4.0 and C.green) or (cell >= wgt.options.LowCell / 100 and C.yellow) or C.red
  end
  local armCol = s.armed and C.orange or (s.armSwitch and C.red or C.green)
  local armLbl = s.armed and "Armed" or (s.armSwitch and "Arm-Sw AN" or "Arm-Sw aus")
  local fmCol = C.dim
  if up and d.fm then fmCol = string.find(d.fm, "!ERR", 1, true) and C.red or C.green end
  local lx = x + 8
  dot(lx, ly, linkCol, "Link")
  dot(lx + colW, ly, battCol, "Akku voll")
  dot(lx + colW * 2, ly, armCol, armLbl)
  dot(lx + colW * 3, ly, fmCol, "Arming frei")

  noLinkBanner(wgt, x, cy - 27, w)
end

------------------------------------------------------------------------
-- Seite 2: Link
------------------------------------------------------------------------

local function tile(x, y, w, h, label, value, color, highlight)
  lcd.drawFilledRectangle(x, y, w, h, C.panel)
  if highlight then lcd.drawRectangle(x, y, w, h, C.blue, 2) end
  lcd.drawText(x + 6, y + 3, label, SMLSIZE + C.dim)
  textC(x + w / 2, y + h * 0.62, value, fitFont(value, w - 10, h - 18), color)
end

local function graph(wgt, x, y, w, h)
  local s, st = wgt.s, wgt.s.stats
  lcd.drawFilledRectangle(x, y, w, h, C.panel)
  local gx, gy, gw, gh = x + 4, y + 20, w - 8, h - 24
  for i = 1, 3 do
    local ly = floor(gy + gh * i / 4)
    lcd.drawLine(gx, ly, gx + gw - 1, ly, DOTTED, C.track)
  end
  local n = #s.hist
  local step = gw / (HIST_N - 1)
  local off = HIST_N - n
  local plq, prs
  for i = 1, n do
    local smp = s.hist[i]
    local px = floor(gx + (off + i - 1) * step)
    if smp.lq < 0 then
      lcd.drawFilledRectangle(px, gy, math.max(2, floor(step + 1)), gh, C.red)
      plq, prs = nil, nil
    else
      local qy = floor(gy + gh - smp.lq / 100 * gh)
      if plq then lcd.drawLine(plq[1], plq[2], px, qy, SOLID, C.green) end
      plq = { px, qy }
      if smp.rssi then
        local ry = floor(gy + gh - math.max(0, math.min(1, (smp.rssi + 120) / 90)) * gh)
        if prs then lcd.drawLine(prs[1], prs[2], px, ry, SOLID, C.blue) end
        prs = { px, ry }
      else
        prs = nil
      end
    end
  end
  lcd.drawText(x + 6, y + 3, "LQ", SMLSIZE + C.green)
  lcd.drawText(x + 30, y + 3, "RSSI", SMLSIZE + C.blue)
  lcd.drawText(x + 70, y + 3, "60 s", SMLSIZE + C.dim)
  local info = string.format("min LQ %s   min RSSI %s   Verluste %d",
    fmt(st.minLQ, "%d%%"), fmt(st.minRSSI, "%d"), st.losses)
  textR(x + w - 6, y + 3, info, SMLSIZE, st.losses > 0 and C.red or C.dim)
end

local function pageLink(wgt, x, y, w, h)
  local s, d = wgt.s, wgt.s.d
  local function c(col) return s.up and col or C.dim end
  local gap = 6
  local tw = floor((w - 3 * gap) / 4)
  local th = math.min(58, floor((h * 0.5 - gap) / 2))
  local function col(i) return x + (i - 1) * (tw + gap) end
  local y2 = y + th + gap
  local two = d.r2 and d.r2 < 0

  tile(col(1), y, tw, th, "Up LQ", fmt(d.rq, "%d%%"), c(lqColor(d.rq)))
  tile(col(2), y, tw, th, "Up RSSI 1", fmt(d.r1, "%d"), c(rssiColor(d.r1)), two and d.ant == 0)
  tile(col(3), y, tw, th, "Up RSSI 2", two and fmt(d.r2, "%d") or "--", c(rssiColor(two and d.r2 or nil)), two and d.ant == 1)
  tile(col(4), y, tw, th, "Up SNR", fmt(d.rsnr, "%d dB"), c(snrColor(d.rsnr)))
  tile(col(1), y2, tw, th, "Down LQ", fmt(d.tq, "%d%%"), c(lqColor(d.tq)))
  tile(col(2), y2, tw, th, "Down RSSI", fmt(d.trss, "%d"), c(rssiColor(d.trss)))
  tile(col(3), y2, tw, th, "Down SNR", fmt(d.tsnr, "%d dB"), c(snrColor(d.tsnr)))
  tile(col(4), y2, tw, th, "TX " .. fmt(d.rfmd, "Mode %d", ""), fmt(d.tpwr, "%d mW"), c(C.text))

  local gy = y2 + th + gap
  graph(wgt, x, gy, w, y + h - gy)
  noLinkBanner(wgt, x, y + th - 21, w)
end

------------------------------------------------------------------------
-- Seite 3: Session
------------------------------------------------------------------------

local function horizon(cx, cy, r, roll, pitch)
  lcd.drawFilledCircle(cx, cy, r, C.sky)
  if roll and pitch then
    local sr, cr = math.sin(roll), math.cos(roll)
    local off = math.deg(pitch) * r / 45            -- 45 Grad Pitch = ein Radius
    for dy = -r, r do
      local halfW = math.sqrt(r * r - dy * dy)
      local x1, x2 = -halfW, halfW
      local rhs = off - dy * cr                      -- Boden: dx*sin + dy*cos > off
      if math.abs(sr) < 0.001 then
        if rhs >= 0 then x2 = x1 end
      elseif sr > 0 then
        x1 = math.max(x1, rhs / sr)
      else
        x2 = math.min(x2, rhs / sr)
      end
      if x2 > x1 then
        lcd.drawLine(floor(cx + x1), cy + dy, floor(cx + x2), cy + dy, SOLID, C.ground)
      end
    end
  end
  lcd.drawAnnulus(cx, cy, r - 2, r + 1, 0, 360, C.track)
  local wing = floor(r * 0.45)
  lcd.drawFilledRectangle(cx - wing, cy - 1, wing - 8, 3, C.yellow)
  lcd.drawFilledRectangle(cx + 8, cy - 1, wing - 8, 3, C.yellow)
  lcd.drawFilledCircle(cx, cy, 3, C.yellow)
end

local function pageSession(wgt, x, y, w, h, full)
  local s, d, st, o = wgt.s, wgt.s.d, wgt.s.stats, wgt.options
  local rows = {
    { "Flugzeit",      fmtTime(st.flight), C.text },
    { "Akku",          string.format("%dS%s", cellsOf(wgt), o.Cells == 0 and " (auto)" or ""), C.text },
    { "Zelle Start",   fmt(st.startCell, "%.2f V"), cellColor(wgt, st.startCell) },
    { "Zelle min",     fmt(st.minCell, "%.2f V"), cellColor(wgt, st.minCell) },
    { "Verbraucht",    fmt(st.mah, "%d mAh"), C.text },
    { "Strom max",     fmt(st.maxCurr, "%.1f A"), C.text },
    { "LQ min",        fmt(st.minLQ, "%d %%"), lqColor(st.minLQ) },
    { "RSSI min",      fmt(st.minRSSI, "%d dBm"), rssiColor(st.minRSSI) },
    { "Link-Verluste", tostring(st.losses), st.losses > 0 and C.red or C.green },
    { "Max. Ausfall",  string.format("%.1f s", st.longestLoss / 100), st.longestLoss > 0 and C.red or C.dim },
  }
  local lw = floor(w * 0.55)
  local rh = math.min(26, floor(h / #rows))
  lcd.drawFilledRectangle(x, y, lw, rh * #rows, C.panel)
  for i, row in ipairs(rows) do
    local ry = y + (i - 1) * rh
    if i > 1 then lcd.drawLine(x + 6, ry, x + lw - 6, ry, SOLID, C.bg) end
    local _, fh = lcd.sizeText(row[1], 0)
    local ty = floor(ry + (rh - fh) / 2)
    lcd.drawText(x + 8, ty, row[1], C.dim)
    textR(x + lw - 8, ty, row[2], 0, row[3])
  end

  -- Lage
  local rx = x + lw + 10
  local rw = x + w - rx
  local btnH = 34
  local r = floor(math.min(rw / 2 - 6, (h - btnH - 36) / 2))
  local hcx, hcy = rx + floor(rw / 2), y + r + 2
  horizon(hcx, hcy, r, s.up and d.roll, s.up and d.pitch)
  local function deg(rad) return rad and floor(math.deg(rad) + 0.5) end
  local att = string.format("R %s  P %s  Y %s",
    fmt(deg(d.roll), "%d"), fmt(deg(d.pitch), "%d"), fmt(deg(d.yaw), "%d"))
  textC(hcx, hcy + r + 13, att, SMLSIZE, s.up and C.text or C.dim)

  local by = y + h - btnH
  if full then
    lcd.drawFilledRectangle(rx, by, rw, btnH, C.track)
    textC(rx + rw / 2, by + btnH / 2, "Reset", 0, C.text)
    wgt.resetBtn = { x = rx, y = by, w = rw, h = btnH }
  else
    wgt.resetBtn = nil
    textC(rx + rw / 2, by + btnH / 2, "Reset: Vollbild", SMLSIZE, C.dim)
  end
end

------------------------------------------------------------------------
-- Kompakt (kleine Zonen)
------------------------------------------------------------------------

local function compact(wgt, x, y, w, h)
  local s, d = wgt.s, wgt.s.d
  local txt, col = statusInfo(wgt)
  lcd.drawText(x + 4, y + 2, txt, SMLSIZE + col)
  local line = string.format("%s  LQ %s", fmt(d.cell, "%.2fV"), fmt(d.rq, "%d%%"))
  lcd.drawText(x + 4, y + 18, line, fitFont(line, w - 8, h - 20) + (s.up and C.text or C.dim))
end

------------------------------------------------------------------------
-- Widget-API
------------------------------------------------------------------------

local function handleEvent(wgt, event, t)
  if not event or event == 0 then return end
  local n = #PAGES
  local function nextPage() wgt.page = wgt.page % n + 1 end
  local function prevPage() wgt.page = (wgt.page - 2) % n + 1 end
  if event == EVT_VIRTUAL_NEXT or event == EVT_VIRTUAL_NEXT_PAGE then
    nextPage()
  elseif event == EVT_VIRTUAL_PREV or event == EVT_VIRTUAL_PREV_PAGE then
    prevPage()
  elseif event == EVT_VIRTUAL_ENTER_LONG then
    resetStats(wgt)
    playTone(1500, 120, 0)
  elseif event == EVT_TOUCH_SLIDE and t then
    if t.swipeLeft then nextPage() elseif t.swipeRight then prevPage() end
  elseif event == EVT_TOUCH_TAP and t then
    local b = wgt.resetBtn
    if t.y < HEADER_H then
      nextPage()
    elseif wgt.page == 3 and b and t.x >= b.x and t.x <= b.x + b.w and t.y >= b.y and t.y <= b.y + b.h then
      resetStats(wgt)
      playTone(1500, 120, 0)
    end
  end
end

local function create(zone, opts)
  initColors()
  return {
    zone = zone, options = opts, page = opts.Page,
    s = { d = {}, stats = newStats(), hist = {}, up = false, everUp = false, armed = false },
  }
end

local function update(wgt, opts)
  wgt.options = opts
  wgt.page = opts.Page
end

local function background(wgt)
  tick(wgt)
end

local function refresh(wgt, event, touchState)
  tick(wgt)
  local full = event ~= nil
  local x, y, w, h
  if full then
    handleEvent(wgt, event, touchState)
    x, y, w, h = 0, 0, LCD_W, LCD_H
  else
    x, y, w, h = wgt.zone.x, wgt.zone.y, wgt.zone.w, wgt.zone.h
    wgt.page = wgt.options.Page
  end
  lcd.drawFilledRectangle(x, y, w, h, C.bg)
  if w < 300 or h < 170 then
    compact(wgt, x, y, w, h)
    return
  end
  local page = wgt.page
  header(wgt, x, y, w, full, page)
  local bx, by, bw, bh = x + 6, y + HEADER_H + 6, w - 12, h - HEADER_H - 12
  if page == 1 then
    pagePreflight(wgt, bx, by, bw, bh)
  elseif page == 2 then
    pageLink(wgt, bx, by, bw, bh)
  else
    pageSession(wgt, bx, by, bw, bh, full)
  end
end

return { name = "QuadDash", options = options, create = create, update = update,
         background = background, refresh = refresh }
