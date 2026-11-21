-- selene: allow(incorrect_standard_library_use)
-- Contract for the 1.6.10 frame source: Scripts/ad_frames.lua answers the frame
-- query, the send hook feeds it, and the engine query survives only behind
-- frame_source = game. Also drives the model the way main.lua does.
local src = assert(io.open("Scripts/main.lua", "rb")):read("*a")
local menuSrc = assert(io.open("Scripts/menu_config.lua", "rb")):read("*a")
local F = dofile("Scripts/ad_frames.lua")
local n = 0
local function hasnt(needle, why)
    assert(not src:find(needle, 1, true), why)
    n = n + 1
end
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
has('for _, get in ipairs(PREHIT_GET) do', "with a documented fallback")
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

has("tl.hookSeen = (tl.hookSeen or 0) + 1", "the hook counts every enemy frame it sees")
has('frames: hook=%d notime=%d added=%d live=%d', "the ledger reports what the hook produced")
has('dofile(MOD_DIR .. "Scripts/ad_abiinput.lua")', "the counter input dispatcher is installed")
has("local ABI = tl.abiInput", "the counter presses through the dispatcher when it is there")
has("inject = injectKey", "the injection door is bound to the key path")
has("tl.listInputActions", "a counter with no Triangle action can list what the game has")
hasnt('[FName(', "an FName is never a table index: UE4SS dies in get_string, pcall cannot see it")
has("local PREHIT_GET = {", "the hit time is read through dot access")
has("shield_counter_range is %s cm", "an unusable shield range says so")
has('tl.ACTION_DIRS = { "/PBZDeflectSystem/Input/", "/PBZInput/InputActions/",', "the press is searched in both input folders")
has("if idx then a = idx[n] end", "and in the object table by short name")
has('log("input actions: %d indexed by name", count)', "the short-name index says how big it is")
hasnt("local function indexedAction", "the helper is inline: Lua 5.4 counts every local a chunk ever declares")
has("weapon probe: backpack=%s", "a counter that never arms prints what the backpack holds")
has("if not tl.inputListed then", "the 60-line action dump is written once a session")
has("the counter needs a name with DualHook", "a resolved press that never fires names the weapon in hand")
hasnt("local RELEASE_FROM_OUTSIDE = false", "the dormant guard-release path stays deleted")
print("FRAME_WIRING PASS " .. n .. " assertions")
