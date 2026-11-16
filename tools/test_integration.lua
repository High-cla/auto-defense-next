-- Run only in an instrumented TEMP copy, never against the installed mod.
assert(os.getenv("AD_MENU_TEST") == "1", "requires an isolated test copy")
local marker = assert(io.open(".ad-menu-test-only", "r"), "refusing to run outside test directory")
marker:close()
Key = setmetatable({}, { __index = function() return 1 end })
ModifierKey = setmetatable({}, { __index = function() return 2 end })
FName = function(s) return { s = s } end
StaticFindObject = function() return nil end
FindObject = function() return nil end
FindAllOf = function() return {} end
ForEachUObject = function() end
RegisterKeyBind = function() end
ExecuteInGameThread = function(fn) fn() end
LoopInGameThreadWithDelay = function(_, fn) _G.__LOOP = fn end
package.preload.UEHelpers = function() return { GetPlayerController = function() return nil end } end
package.preload.toast = function() return { new = function() return { show = function() return true end } end } end
local gc = collectgarbage
collectgarbage = function(mode, ...) if mode == "generational" then return 0 end return gc(mode, ...) end
local loaded, loadErr = pcall(dofile, "Scripts/main.lua")
assert(loaded, "complete chunk: " .. tostring(loadErr))
local T, H, S = assert(_G.__TL), assert(_G.__HK), assert(_G.__S)
local json = dofile("Scripts/ad_json.lua")
local n = 0
local function eq(a, b, why) assert(a == b, why or (tostring(a) .. " ~= " .. tostring(b))); n = n + 1 end
local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s end
local function write(path, text) local f = assert(io.open(path, "wb")); assert(f:write(text)); assert(f:close()) end
local original = read("auto_defense.txt")
local initial = read(H.menu.path)
write("initial-menu.config.json", initial)
-- the shipped config is the shipped defaults (1.6.4); keep in sync with the descriptor
eq(S.perfect, false); eq(S.parryReach, 0.5); eq(S.guardReleaseAfter, 0.5); eq(S.guardReleaseCombatEnd, 0.5)
eq(S.keys.parry, "F9")
assert(_G.__LOOP() == false, "tick without a player is safe")
local fake = { GetAddress = function() return 77 end, IsValid = function() return true end,
    ReceiveFrames = { ForEach = function(_, fn)
        fn({ get = function() return 7 end }, { get = function() return { HitGameTime = 100.5, IsDodge = false } end })
    end } }
assert(pcall(T.fxScan, fake, 100)); eq(T.fxDue(7, 100), .5)
T.tapPending, T.receipt = {h=7, at=0}, {h=7, click0=0, game=0}
local raw = assert(json.decode(initial))
raw.read_frames, raw.receipt, raw.parry = false, false, false
raw.debug, raw.perf, raw.min_gap_ms, raw.grab_lead_ms = true, true, 110, 450
raw.parry_lead, raw.parry_lead_seconds, raw.latency = "manual", .14, false
raw.key_parry, raw.data = "CTRL+F10", false
write(H.menu.path, assert(json.encode(raw)))
H.menu.nextAt = 0
assert(_G.__LOOP() == false)
eq(S.parry, false); eq(T.tapPending, nil); eq(T.receipt, nil); eq(T.fxDue(7, 100), nil)
eq(T.TAP_GAP, .11); eq(T.grabLead, .45); eq(S.keys.parry, "F9"); eq(S.data, true)
eq(T.parryLead(), .14, "latency off must not subtract old samples")
T.noteLatency(.08); eq(T.parryLead(), .14)
eq(T.pressTap(7, 100), false, "parry off choke point")
assert(T.menu.pending.key_parry and T.menu.pending.data)
-- The registered action merges a just-saved menu value and writes no legacy TXT.
raw.parry_reach, raw.extra = 6, "keep"
write(H.menu.path, assert(json.encode(raw)))
H.actions.parry()
eq(S.parry, true); eq(S.parryReach, 6)
local saved = assert(json.decode(read(H.menu.path)))
eq(saved.key_parry, "CTRL+F10"); eq(saved.data, false); eq(saved.extra, "keep")
eq(read("auto_defense.txt"), original, "TXT is immutable after migration")
-- Write failure and malformed JSON leave the last-good runtime state untouched.
write(H.menu.path, "{bad JSON")
H.actions.parry(); eq(S.parry, true)
eq(read(H.menu.path), "{bad JSON")
write(H.menu.path, initial)
-- 1.6.1 observability: bounded bus, read-only sink, warm queue drains safely
eq(type(T.bus), "table"); eq(type(T.warm), "table")
eq(type(T.policy), "table"); eq(type(T.input), "table", "input choke installed")
-- the choke asks the shared rules: with the other mod owning the guard, a press
-- is refused before the mechanic runs
local rawPress, savedPd = T.input.bound().pressRaw, T.policy.env.pdOwns
local pressed = 0
T.input.bound().pressRaw = function() pressed = pressed + 1 return true end
T.policy.env.pdOwns = function() return true end
eq(T.input.pressGuard(5, 5), false); eq(pressed, 0, "refused before the press")
T.policy.env.pdOwns = savedPd
T.input.bound().pressRaw = rawPress
T.bus.drain(64) -- drop whatever the choke emitted earlier in this run
local got = 0
T.bus.subscribe(function() got = got + 1 end)
for i = 1, 8 do T.emit("test", i, "x", 3) end
T.bus.drain(16)
eq(got, 8, "every emitted event delivered")
eq(T.bus.stats().pending, 0)
local ev = read("ad_events.txt")
assert(ev:find("test", 1, true), "sink flushed 8 lines: " .. ev)
eq(T.warm.done(), true, "the loop drained one warm task per tick")
eq(T.warm.failed(), 0, "timeline index: " .. tostring(T.warm.lastError))
eq(type(T.busIdx), "table", "warm index exposed read-only")
eq(T.warm.step(5), 0, "a finished queue costs nothing")
-- the log cap, the version and the documented surface (audit P0-2, P1-6, P1-7)
eq(type(T.logState), "table", "log state is reachable")
eq(T.logState.max, 3000, "log cap")
local capAt = T.logState.lines
T.logState.lines = T.logState.max
T.log("cap probe") -- one past the cap: counted, printed as the marker, not written
eq(T.logState.lines, T.logState.max + 1, "a refused line is still counted")
T.logState.lines = capAt
eq(type(T.api), "table", "the public surface is listed")
local missing = {}
for _, name in ipairs(T.api) do if T[name] == nil then missing[#missing + 1] = name end end
eq(#missing, 0, "documented api names exist: " .. table.concat(missing, ","))
eq(T.VERSION, "1.6.4", "the version is stated once")
if T.ledFlush then T.ledFlush() end
local led = read("auto_defense_ledger.txt")
assert(led:find("v1.6.4", 1, true), "the ledger states the running version: " .. led:sub(1, 200))
n = n + 1
print("INTEGRATION PASS " .. n .. " assertions")