-- Simulation: runs the widget against a mocked EdgeTX API through several scenarios
-- (no link, 1S disarmed, armed, link loss, !ERR, battery swap to 4S, events).
-- The string metatable is removed because EdgeTX has no string methods (s:find).
-- Run from the repo root: lua tools/sim.lua
debug.setmetatable("", nil)
-- Mock EdgeTX API
VALUE, BOOL, SOURCE, COLOR, CHOICE = 1, 2, 3, 4, 5
SMLSIZE, MIDSIZE, DBLSIZE, XXLSIZE = 0x100, 0x200, 0x300, 0x400
SOLID, DOTTED = 0, 1
UNIT_VOLTS, PREC2 = 1, 0x20
EVT_VIRTUAL_NEXT, EVT_VIRTUAL_PREV, EVT_VIRTUAL_ENTER_LONG, EVT_TOUCH_SLIDE, EVT_TOUCH_TAP = 1,2,3,4,5
LCD_W, LCD_H = 480, 320
local T = 0
local calls = 0
local function chk(...) for i,v in ipairs({...}) do if type(v) ~= "number" then error("non-number arg "..i..": "..tostring(v), 2) end end calls = calls + 1 end
lcd = {
  RGB = function(r,g,b) return r*65536+g*256+b end,
  sizeText = function(t, f) assert(type(t)=="string","sizeText non-string") local sz = ({[0]=8,[0x100]=6,[0x200]=11,[0x300]=16,[0x400]=30})[f or 0] or 8; return #t*sz, sz*2 end,
  drawText = function(x,y,t,f) chk(x,y) assert(type(t)=="string") end,
  drawFilledRectangle = function(x,y,w,h,f) chk(x,y,w,h,f) end,
  drawRectangle = function(x,y,w,h,f,t) chk(x,y,w,h,f) end,
  drawLine = function(a,b,c,d,p,f) chk(a,b,c,d,p,f) end,
  drawAnnulus = function(x,y,r1,r2,s,e,f) chk(x,y,r1,r2,s,e,f) end,
  drawFilledCircle = function(x,y,r,f) chk(x,y,r,f) end,
}
local S = {}
local names = {"RxBt","Curr","Capa","Bat%","RQly","1RSS","2RSS","RSNR","ANT","TQly","TRSS","TSNR","TPWR","RFMD","Ptch","Roll","Yaw","FM"}
function getFieldInfo(n) for i,v in ipairs(names) do if v==n then return {id=i, name=n} end end return nil end
function getGeneralSettings() return { battMin = 6.0, battMax = 8.4, battWarn = 6.6 } end
function getValue(id) if id == "ch5" then return S.ch5 or -1024 end
  if id == 999 then return S.mute and 1024 or -1024 end
  if id == "tx-voltage" then return S.txv or 7.9 end return S[names[id]] or 0 end
function getRSSI() return S.link and (S.RQly or 0) or 0 end
function getTime() return T end
local played = {}
function playFile(f) played[#played+1] = f end
function playNumber(v,u,p) played[#played+1] = "num "..v end
function playTone() played[#played+1]="tone" end

local W = dofile("WIDGETS/QuadDash/main.lua")
local opts = {} for _,o in ipairs(W.options) do opts[o[1]] = o[3] end
local wgt = W.create({x=0,y=45,w=480,h=275}, opts)
local function frame(n, ev, touch, full)
  for i=1,(n or 1) do T = T + 5; W.background(wgt); W.refresh(wgt, full and (ev or 0) or nil, touch) end
end
local function allPages(tag)
  for p=1,3 do opts.Page=p; W.update(wgt, opts); frame(1); frame(1,0,nil,true) end
  local s = wgt.s
  print(string.format("%-18s up=%s armed=%s cells=%s cell=%s flight=%.1fs losses=%d minCell=%s hist=%d", tag,
    tostring(s.up), tostring(s.armed), tostring(s.cells), s.d.cell and string.format("%.2f",s.d.cell) or "nil",
    s.stats.flight/100, s.stats.losses, tostring(s.stats.minCell), #s.hist))
end
-- 1: no quad
frame(20); allPages("no link")
-- 2: 1S link up, disarmed
S = {link=true, RxBt=4.2, Curr=0.3, Capa=5, ["Bat%"]=100, RQly=100, ["1RSS"]=-45, ["2RSS"]=0, RSNR=10, ANT=0, TQly=100, TRSS=-50, TSNR=9, TPWR=100, RFMD=7, Ptch=0.1, Roll=-0.3, Yaw=1.5, FM="ACRO*", ch5=-1024}
frame(50); allPages("1S disarmed")
-- 3: armed flying 30s, voltage sags to 3.4
S.ch5 = 1024; S.FM = "AIR"
for i=1,600 do S.RxBt = 4.2 - i*0.0015; S.Curr = 8 + (i%10); S.Capa = 5+i//4; frame(1) end
allPages("armed 30s")
-- 4: link lost 5s while armed, then back
S.link = false; frame(1000); allPages("link lost")
S.link = true; frame(20); allPages("link back")
-- 5: disarm, arming blocked
S.ch5 = -1024; S.FM = "!ERR*"; frame(20); allPages("!ERR")
-- 6: battery swap to 4S (link gone 15s)
S.link = false; frame(3000); S.link = true; S.RxBt = 16.8; S.Curr=0.5; frame(50); allPages("4S new battery")
-- events in full screen
frame(1, EVT_VIRTUAL_NEXT, nil, true); frame(1, EVT_TOUCH_SLIDE, {swipeLeft=true}, true)
frame(1, EVT_TOUCH_TAP, {x=400, y=300}, true); frame(1, EVT_VIRTUAL_ENTER_LONG, nil, true)
print("page after events:", wgt.page, "played:", string.sub(table.concat(played, ", "), 1, 300))
print("draw calls:", calls)

-- mute switch & USB power
local function voiceCount() local n = 0 for _, f in ipairs(played) do if f == "SYSTEM/lowbatt.wav" then n = n + 1 end end return n end
local function scenario(tag, setup, frames)
  local before = voiceCount()
  setup(); frame(frames or 800)
  print(string.format("%-28s usb=%s muted=%s armed=%s cell=%s callouts=%d", tag, tostring(wgt.s.d.usb),
    tostring(wgt.s.muted), tostring(wgt.s.armed), tostring(wgt.s.d.cell), voiceCount() - before))
  allPages(tag)
end
opts.MuteSw = 999; W.update(wgt, opts)
scenario("USB power 0.7V", function() S.link = true; S.RxBt = 0.7; S.ch5 = -1024; S.FM = "ACRO*"; S.mute = false end)
scenario("Batt empty, disarmed, loud", function() S.RxBt = 3.2 end)
scenario("Batt empty, disarmed, MUTED", function() S.mute = true end)
scenario("Batt empty, ARMED, mute on", function() S.ch5 = 1024; S.FM = "AIR" end)
scenario("Sag 1.9V, ARMED, loud", function() S.mute = false; S.ch5 = 1024; S.FM = "AIR"; S.RxBt = 1.9 end)
scenario("1.9V disarmed = USB", function() S.ch5 = -1024; S.FM = "ACRO*" end)
scenario("2.2V disarmed = battery", function() S.RxBt = 2.2 end)

-- language: draw all pages in German
opts.Language = 2; W.update(wgt, opts)
assert(wgt.L.noLink == "KEIN LINK")
S.link = false; frame(200); allPages("German")
opts.Language = 1; W.update(wgt, opts)
assert(wgt.L.noLink == "NO LINK")
