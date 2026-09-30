-- Vorschau: rendert alle Seiten als SVG nach preview/ (Schriften nur angenaehert).
-- Aufruf aus dem Repo-Root: lua tools/render.lua
os.execute("mkdir -p preview")
VALUE, BOOL = 1, 2
SOLID, DOTTED = 0, 1
UNIT_VOLTS, PREC2 = 1, 0x20
LCD_W, LCD_H = 480, 320
SMLSIZE, MIDSIZE, DBLSIZE, XXLSIZE = 1*0x1000000, 2*0x1000000, 3*0x1000000, 4*0x1000000
local FONT = {[0]=13, [1]=10, [2]=18, [3]=28, [4]=52}
local out
local function fsize(f) return FONT[math.floor((f or 0)/0x1000000)] end
local function color(f) return string.format("#%06x", math.floor(f or 0) % 0x1000000) end
local function add(s) out[#out+1] = s end
local function arc(cx,cy,r,a1,a2)
  local function p(a) local t = math.rad(a-90); return cx + r*math.cos(t), cy + r*math.sin(t) end
  local x1,y1 = p(a1); local x2,y2 = p(a2)
  return x1,y1,x2,y2, (a2-a1) > 180 and 1 or 0
end
lcd = {
  RGB = function(r,g,b) return r*65536+g*256+b end,
  sizeText = function(t, f) local s = fsize(f); return math.floor(#t*s*0.55), s + 4 end,
  drawText = function(x,y,t,f) local s = fsize(f); add(string.format('<text x="%d" y="%d" font-size="%d" fill="%s" font-family="Arial">%s</text>', x, y + s, s, color(f), (t:gsub("&","&amp;"):gsub("<","&lt;")))) end,
  drawFilledRectangle = function(x,y,w,h,f) add(string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>',x,y,w,h,color(f))) end,
  drawRectangle = function(x,y,w,h,f,t) add(string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="%s" stroke-width="%d"/>',x,y,w,h,color(f),t or 1)) end,
  drawLine = function(a,b,c,d,p,f) add(string.format('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="%s" %s/>',a,b,c,d,color(f), p==DOTTED and 'stroke-dasharray="2,3"' or '')) end,
  drawFilledCircle = function(x,y,r,f) add(string.format('<circle cx="%d" cy="%d" r="%d" fill="%s"/>',x,y,r,color(f))) end,
  drawAnnulus = function(cx,cy,r1,r2,a1,a2,f)
    if a2 - a1 >= 360 then add(string.format('<circle cx="%d" cy="%d" r="%.1f" fill="none" stroke="%s" stroke-width="%d"/>',cx,cy,(r1+r2)/2,color(f),r2-r1)) return end
    local rm = (r1+r2)/2; local x1,y1,x2,y2,large = arc(cx,cy,rm,a1,a2)
    add(string.format('<path d="M %.1f %.1f A %.1f %.1f 0 %d 1 %.1f %.1f" fill="none" stroke="%s" stroke-width="%d"/>',x1,y1,rm,rm,large,x2,y2,color(f),r2-r1)) end,
}
local T = 0
local S
local names = {"RxBt","Curr","Capa","Bat%","RQly","1RSS","2RSS","RSNR","ANT","TQly","TRSS","TSNR","TPWR","RFMD","Ptch","Roll","Yaw","FM"}
function getFieldInfo(n) for i,v in ipairs(names) do if v==n then return {id=i} end end end
function getGeneralSettings() return { battMin = 6.0, battMax = 8.4, battWarn = 6.6 } end
function getValue(id) if id=="ch5" then return S.ch5 end if id=="tx-voltage" then return S.txv or 7.6 end return S[names[id]] or 0 end
function getRSSI() return S.link and S.RQly or 0 end
function getTime() return T end
function playFile() end function playNumber() end function playTone() end
local W = dofile("WIDGETS/QuadDash/main.lua")
local opts = {} for _,o in ipairs(W.options) do opts[o[1]] = o[3] end
local wgt = W.create({x=0,y=0,w=480,h=320}, opts)
S = {link=true, RxBt=4.2, Curr=0.3, Capa=0, ["Bat%"]=100, RQly=100, ["1RSS"]=-45, ["2RSS"]=0, RSNR=10, ANT=0, TQly=100, TRSS=-50, TSNR=9, TPWR=100, RFMD=7, Ptch=0, Roll=0, Yaw=0, FM="ACRO*", ch5=-1024}
for i=1,20 do T=T+5; W.background(wgt) end
S.ch5 = 1024; S.FM = "AIR"
for i=1,700 do T=T+5; S.RxBt = 4.2 - i*0.0011; S.Curr = 6+(i%13); S.Capa = i//3; S.RQly = 100 - (i%97==0 and 40 or 0) - ((i>400 and i<450) and 25 or 0); S["1RSS"] = -45 - (i%50)/2 - (i>400 and 30 or 0); W.background(wgt) end
S.link=false; for i=1,300 do T=T+5; W.background(wgt) end
S.link=true; S.RQly = 96; S.ch5=-1024; S.FM="ACRO*"; S["1RSS"]=-62; S.RxBt=3.62; S.Curr=0.4; S.Ptch=0.2; S.Roll=0.35; S.Yaw=1.2
for i=1,30 do T=T+5; W.background(wgt) end
local function save(name)
  local f = io.open("preview/"..name..".svg","w")
  f:write('<svg xmlns="http://www.w3.org/2000/svg" width="480" height="320" viewBox="0 0 480 320">'..table.concat(out,"\n")..'</svg>'); f:close()
end
for p=1,3 do wgt.page = p; out = {}; W.refresh(wgt, 0, nil); save("page"..p) end
S.link=false; for i=1,400 do T=T+5; W.background(wgt) end
wgt.page=1; out={}; W.refresh(wgt,0,nil); save("page1_nolink")
print("ok")
