-- selene: allow(incorrect_standard_library_use)
-- Contract for the 1.6.10 frame source: Scripts/ad_frames.lua answers the frame
-- query, the send hook feeds it, and the engine query survives only behind
-- frame_source = game. Also drives the model the way main.lua does.
local src = assert(io.open("Scripts/main.lua", "rb")):read("*a")
local menuSrc = assert(io.open("Scripts/menu_config.lua", "rb")):read("*a")
local F = dofile("Scripts/ad_frames.lua")
local n = 0
local function has(needle, why)
    assert(src:find(needle, 1, true), why)
    n = n + 1
end

has('frameSource = "hooks"', "the shipped default is the hook path")
has('if settings.frameSource == "game" or not FRAMES then', "the engine query is behind one branch")
has("GetNearestValidReceivedFrame(360.0, window, isDodge, -1, outFrame)", "the query keeps its five parameters")
has("return FRAMES:nearest(isDodge == true, window, os.clock()) or -1", "the model answers the query")
has("local FRAMES = loadFrames()", "the model is built once")
has('Scripts/ad_frames.lua"', "the module is loaded from Scripts/")
has("if settings.readFrames and settings.frameSource ~= \"game\" and FRAMES then", "the hook feeds the model")
has('FRAMES:add({ at = os.clock(), prehit = pre, isDodge = okD and red == true, src = actName })', "the hook's own record")
has("local function prehitOf(act)", "the ability is asked for its hit time")
has('for _, field in ipairs({ "PreHitPointDuration", "BulletDuration" })', "with a documented fallback")
has("tl.fxAdd = function(id, src, hit, typeName)", "the FX table is fed from the same frame")
has('if settings.frameSource ~= "game" then', "fxScan knows both modes")
has('if k == "frame_source" then', "the key is read from auto_defense.txt")
has('f:write("frame_source = "', "and written back")
assert(menuSrc:find('key = "frame_source", field = "frameSource", kind = "choice", default = "hooks"', 1, true), "the menu offers it")
n = n + 1

-- the model as main.lua uses it: a frame created now, due after its prehit
local t = 100.0
local m = F.new({ now = function() return t end })
local id = m:add({ at = t, prehit = 0.24, isDodge = false, src = "GA_X" })
assert(id, "the hook record becomes a frame")
assert(m:nearest(false, 0.2) == nil, "not yet inside a 0.2 s window")
assert(m:nearest(false, 0.3) == id, "inside a 0.3 s window")
assert(m:get(id).due == 100.24, "due = at + prehit")
t = 101.0
assert(m:nearest(false, 0.3) == nil, "a second later it is stale")
n = n + 4

print("FRAME_WIRING PASS " .. n .. " assertions")
