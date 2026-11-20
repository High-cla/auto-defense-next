--# selene: allow(incorrect_standard_library_use)
-- Run only in an instrumented TEMP copy, never against the installed mod.
assert(os.getenv("AD_MENU_TEST") == "1", "requires an isolated test copy")
local marker = assert(io.open(".ad-menu-test-only", "r"), "refusing to run outside test directory")
marker:close()

-- The shipped mod targets Windows, where backslashes are path separators.
-- Normalize file paths only in this isolated POSIX integration-test process.
local PATH_SEP = package.config and package.config:sub(1, 1) or "\\"
if PATH_SEP == "/" then
    local function normalize(path)
        if type(path) == "string" then return (path:gsub("\\", "/")) end
        return path
    end
    local nativeDofile, nativeLoadfile = dofile, loadfile
    local nativeOpen, nativeLines = io.open, io.lines
    local nativeRemove, nativeRename = os.remove, os.rename
    dofile = function(path) return nativeDofile(normalize(path)) end
    loadfile = function(path, ...) return nativeLoadfile(normalize(path), ...) end
    io.open = function(path, ...) return nativeOpen(normalize(path), ...) end
    io.lines = function(path, ...) return nativeLines(normalize(path), ...) end
    os.remove = function(path) return nativeRemove(normalize(path)) end
    os.rename = function(old, new) return nativeRename(normalize(old), normalize(new)) end
end
Key = setmetatable({}, { __index = function() return 1 end })
ModifierKey = setmetatable({}, { __index = function() return 2 end })
FName = function(s) return { s = s } end
StaticFindObject = function() return nil end
FindObject = function() return nil end
FindAllOf = function() return {} end
ForEachUObject = function() end
RegisterKeyBind = function() end
ExecuteInGameThread = function(fn) fn() end
local nextActionHandle = 100
LoopInGameThreadWithDelay = function(delay, fn)
    nextActionHandle = nextActionHandle + 1
    _G.__LOOP, _G.__LOOP_MODE, _G.__LOOP_DELAY_MS = fn, "timer", delay
    _G.__LOOP_HANDLE = nextActionHandle
    return nextActionHandle
end
EngineTickAvailable = true
LoopInGameThreadAfterFrames = function(frames, fn)
    nextActionHandle = nextActionHandle + 1
    _G.__LOOP, _G.__LOOP_MODE, _G.__LOOP_FRAMES = fn, "frame", frames
    _G.__LOOP_HANDLE = nextActionHandle
    return nextActionHandle
end
CancelDelayedAction = function(handle)
    _G.__CANCELLED_HANDLE = handle
    return true
end
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
eq(S.keys.parry, "F9"); eq(S.seedFallback, "record", "reference seeds default to observation only")
eq(_G.__LOOP_MODE, "frame", "frame scheduler preferred when EngineTick is available")
eq(_G.__LOOP_FRAMES, 1, "defense loop runs once per engine frame")
assert(_G.__LOOP() == false, "tick without a player is safe")
local firstHandle = _G.__LOOP_HANDLE
T.start()
eq(_G.__CANCELLED_HANDLE, firstHandle, "watchdog restart cancels the previous loop")
eq(_G.__LOOP_MODE, "frame"); eq(_G.__LOOP_FRAMES, 1)
local secondHandle = _G.__LOOP_HANDLE
EngineTickAvailable = false
T.start()
eq(_G.__CANCELLED_HANDLE, secondHandle, "fallback restart also cancels the previous loop")
eq(_G.__LOOP_MODE, "timer", "10 ms timer is the compatibility fallback")
eq(_G.__LOOP_DELAY_MS, 10)
local fallbackHandle = _G.__LOOP_HANDLE
EngineTickAvailable = true
T.start()
eq(_G.__CANCELLED_HANDLE, fallbackHandle)
eq(_G.__LOOP_MODE, "frame")

-- Scheduler hardening (review F1/F2/F3): the happy-path stubs above always
-- return a handle and always cancel, so none of these cases could fail before.
local realTimerApi, realCancelApi = LoopInGameThreadWithDelay, CancelDelayedAction
-- F1: a build that schedules the loop but reports no handle is still scheduled.
-- The old code logged "timer unavailable" and returned, leaving no loop at all.
EngineTickAvailable = false
LoopInGameThreadWithDelay = function(delay, fn)
    _G.__LOOP, _G.__LOOP_MODE, _G.__LOOP_DELAY_MS = fn, "timer", delay
    return nil
end
T.loopHandle = nil
T.start()
eq(type(_G.__LOOP), "function", "a nil handle still schedules the loop")
eq(T.loopSchedule, "timer", "the schedule record stays honest after a nil handle")
LoopInGameThreadWithDelay = realTimerApi
-- F1b: no delayed-action API at all is a recorded failure, not a silent ignore.
EngineTickAvailable = false
LoopInGameThreadWithDelay = nil
T.loopHandle = nil
T.start()
eq(T.loopSchedule, "failed", "missing scheduler APIs are recorded as failed")
LoopInGameThreadWithDelay = realTimerApi
EngineTickAvailable = true
-- F2: a handle that throws on cancel is remembered and retried, not forgotten.
local cancelCalls, cancelFails = 0, true
CancelDelayedAction = function(h)
    cancelCalls = cancelCalls + 1; _G.__CANCELLED_HANDLE = h
    if cancelFails then error("cancel failed") end
    return true
end
T.loopHandle, T.loopStale = 4242, nil
T.start()
eq(cancelCalls >= 1, true, "the previous handle is offered for cancellation")
eq((T.loopStale or {})[1], 4242, "a handle that could not be cancelled is kept for retry")
cancelFails = false
T.loopHandle = _G.__LOOP_HANDLE
T.start()
eq(T.loopStale, nil, "the retry list clears once cancelling works")
-- a false answer means the engine no longer knows the handle: that is success
CancelDelayedAction = function(h) _G.__CANCELLED_HANDLE = h return false end
T.loopHandle, T.loopStale = 4243, nil
T.start()
eq(T.loopStale, nil, "a handle the engine no longer knows counts as cancelled")
CancelDelayedAction = realCancelApi
-- F3: the watchdog says "press a hotkey to retry" - that retry must work.
T.loopId, T.loopDead, T.tickAt = 25, true, os.clock() - 60
T.check()
eq(T.loopId, 25, "the watchdog refuses once the start budget is spent")
T.check(true)
eq(T.loopId, 1, "a manual retry resets the budget and restarts the loop")
eq(T.loopDead, nil, "a manual retry clears the dead flag")

-- 1.6.10: the send hook is the producer now (frame_source = hooks by default),
-- so the entry is written by tl.fxAdd instead of by enumerating ReceiveFrames
assert(pcall(T.fxAdd, 7, "GA_X", 100.5, "BP_Bullet"))
eq(T.fxDue(7, 100), .5, "a frame the hook announced answers with its own hit time")
eq(T.fxType(7), "BP_Bullet", "and with the bullet type the hook saw")
-- 1.6.10: frame_source = hooks (the default) answers from the model, not the component
if T.frames then
    S.frameSource = "hooks"
    T.frames:clear()
    local fid = T.frames:add({ at = os.clock(), prehit = 0.2, isDodge = false, src = "GA_HOOK" })
    eq(T.frames:nearest(false, 0.3, os.clock()), fid, "the hook-fed model answers the frame query")
    eq(T.frames:nearest(true, 0.3, os.clock()), nil, "and keeps dodge and parry frames apart")
    S.frameSource = "game"
end
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
eq(T.VERSION, "1.6.10", "the version is stated once")

-- 1.6.5 test surface (audit P0-2, P0-3, P1-1): the runtime row, the per-frame
-- decision chain and the release check are named seams now, so this suite drives
-- the real code with a fake Deflect / Ability Input Component instead of only
-- asserting that the loop exists. Everything stays behind the marker file.
local gaps = {}
local RT = _G.__RUNTIME
if type(RT) ~= "table" then gaps[#gaps + 1] = "__RUNTIME" end
if type(_G.__DECIDE) ~= "function" then gaps[#gaps + 1] = "__DECIDE" end
if type(_G.__CHECK_RELEASE) ~= "function" then gaps[#gaps + 1] = "__CHECK_RELEASE" end
if type(_G.__QUEUE_TIMELINE) ~= "function" then gaps[#gaps + 1] = "__QUEUE_TIMELINE" end
if type(_G.__QUEUE_TEST) ~= "table" then gaps[#gaps + 1] = "__QUEUE_TEST" end
if type(T.ledOnce) ~= "function" then gaps[#gaps + 1] = "tl.ledOnce" end

-- B (P0-2): the runtime row states what the chunk runs on, so a 5.4-only call
-- that silently does nothing on 5.1 is visible instead of guessed from a game log.
if type(RT) == "table" then
    eq(type(RT.version), "string", "runtime version is a string")
    eq((RT.version or ""):sub(1, 3), "Lua", "runtime version is the interpreter's _VERSION")
    eq(type(RT.compat), "boolean", "runtime compat is a capability flag")
    eq(RT.jit == nil or type(RT.jit) == "string", true, "runtime jit is a name or absent")
end
-- E (P1-5): the documented surface is pinned, not grown by accident
eq(#T.api, 32, "the public surface stays at the 32 documented names")
eq(type(T.VERSION) == "string" and T.VERSION:match("^%d+%.%d+%.%d+$") ~= nil, true,
    "VERSION is semantic: " .. tostring(T.VERSION))

-- Reference no-frame fallback: record reports exact matches but never returns an
-- actionable row; on adopts a copy; off hides both rows and diagnostics.
do
    eq(type(T.seed), "table", "reference seed merger installed with data on")
    eq(type(T.seedRows), "function", "seed mode seam is public")
    local oldMode = S.seedFallback
    S.seedFallback = "record"
    local recordRows, recordAdded, recordCandidates = T.seedRows(
        "GA_BombMan_Skill_01_C", "BP_Monster_BombManRespawn_C", 300, {})
    eq(#recordRows, 0, "record cannot hand an actionable row to the caller")
    eq(recordAdded, 2, "record reports the two BombMan seed times")
    eq(#recordCandidates, 2, "record keeps provenance candidates visible")
    local class = { IsValid = function() return true end, GetAddress = function() return 710 end,
        GetFName = function() return { ToString = function() return "BP_Monster_BombManRespawn_C" end } end }
    local actor = { GetDistanceTo = function() return 300 end, GetClass = function() return class end }
    local pawn = { IsValid = function() return true end, GetAddress = function() return 711 end }
    local ab = { GetAddress = function() error("record mode must return before queuing") end }
    local okRecord, queued = pcall(_G.__QUEUE_TIMELINE, ab, "GA_BombMan_Skill_01_C", actor, pawn, "test")
    eq(okRecord, true, "record mode never enters the actionable queue path")
    eq(queued, nil, "record mode leaves a missing timeline missing")
    S.seedFallback = "on"
    local onRows, onAdded = T.seedRows("GA_BombMan_Skill_01_C", "BP_Monster_BombManRespawn_C", 300, {})
    eq(onAdded, 2); eq(#onRows, 2, "on adopts both actor-qualified rows")
    eq(onRows[1].seed, true); eq(onRows[1].source, "seed"); eq(onRows[1][3], true, "seed rows are dodge-only")
    local replayRows, replayAdded = T.seedRows(
        "GA_BombMan_Skill_01_C", "BP_Monster_BombManRespawn_C", 300, onRows)
    eq(replayAdded, 0, "on merge is idempotent"); eq(#replayRows, 2)
    S.seedFallback = "off"
    local offRows, offAdded, offCandidates = T.seedRows(
        "GA_BombMan_Skill_01_C", "BP_Monster_BombManRespawn_C", 300, {})
    eq(#offRows, 0); eq(offAdded, 0); eq(#offCandidates, 0, "off disables the overlay")
    S.seedFallback = oldMode
end

-- 1.6.10: the queue is bounded even with parry off - its reaper used to be a side
-- effect of a stage that `parry` gates
do
    local QT = _G.__QUEUE_TEST
    eq(type(QT), "table", "the queue test seam is public")
    if type(QT) == "table" then
        QT.clear()
        for _ = 1, 64 do QT.push({ t0 = os.clock(), life = 15 }) end
        QT.reap()
        eq(QT.len() <= 32, true, "an idle queue is capped")
        QT.clear()
        for _ = 1, 40 do QT.push({ t0 = os.clock(), life = 15, pendingHit = true }) end
        QT.reap()
        eq(QT.len(), 40, "a hit that is still pending is never dropped")
        QT.clear()
    end
end

-- B (SDK 0.3.3): the game's own "is the deflect input held" answer replaces the key
-- inference where it exists, and the key answer stands where it does not. Both
-- halves run against the real module with a fake input component.
do
    eq(type(T.holdAsk), "function", "the hold question is part of the runtime surface")
    eq(T.holdAsk(false), false, "no character: the key answer is unchanged")
    eq(T.holdAsk(true), true, "no character: a held key stays held")
    local realStatic, realIS, realInject = StaticFindObject, T.inputState, T.injectAt
    StaticFindObject = function(path)
        if type(path) == "string" and path:find("IA_Deflect", 1, true) then
            return { IsValid = function() return true end, GetFullName = function() return path end }
        end
        return nil
    end
    local Q = dofile("Scripts/ad_query.lua")
    local sgi = { IsHolding = function() return true end, GetHoldTime = function() return 0.42 end }
    local pawn = { IsValid = function() return true end, GetAddress = function() return 903 end }
    pawn["Ability Input Component"] = { IsValid = function() return true end, SGameInput = sgi }
    local module = dofile("Scripts/ad_inputstate.lua")
    T.inputState = module.new({
        component = Q.component, prop = Q.prop,
        isHolding = function(s, a) return Q.unwrap(s:IsHolding(a)) end,
        holdTime = function(s, a) return Q.unwrap(s:GetHoldTime(a)) end,
        log = function() end,
    })
    T.injectAt = -1e9
    eq(T.holdAsk(false, pawn), true, "the game's answer wins over a released key")
    T.injectAt = os.clock()
    eq(T.holdAsk(false, pawn), false, "our own injection is not the player holding the guard")
    local asks = select(1, T.inputState.stats())
    eq(asks, 2, "each question reaches the game reader once")
    T.injectAt = realInject
    T.inputState, StaticFindObject = realIS, realStatic
end

-- B: the hold source reverts. The game's own answer is a borrowed fact: when it
-- stops being usable the adapter must go away on its own, keep its hands off the
-- game, and leave the key state in charge - and installing it twice must not
-- replace the instance that is already counting.
do
    local realStatic, realIS = StaticFindObject, T.inputState
    -- a live character on purpose: with no pawn the key path returns before the
    -- adapter is consulted at all, so the assertion would hold even with no dead
    -- gate in holdAsk and would prove nothing
    StaticFindObject = function(path)
        if type(path) == "string" and path:find("IA_Deflect", 1, true) then
            return { IsValid = function() return true end, GetFullName = function() return path end }
        end
        return nil
    end
    local pawn = { IsValid = function() return true end, GetAddress = function() return 904 end }
    local reads = 0
    T.inputState = { dead = true, read = function() reads = reads + 1 return true end,
        -- answers like a live adapter would, so a holdAsk that ignores the dead flag
        -- fails on the value it returns instead of on a missing method
        pick = function(held) return held end,
        stats = function() return 0, 0, 0, 0 end }
    eq(T.holdAsk(false, pawn), false, "a reverted adapter leaves the key answer alone")
    eq(T.holdAsk(true, pawn), true, "a reverted adapter leaves a held key held")
    eq(reads, 0, "a reverted adapter does not touch the game")
    T.inputState, StaticFindObject = realIS, realStatic
    -- installing again returns the instance that is already installed
    local first = T.inputState
    eq(T.installInputState(), first, "a second install keeps the live adapter")
    eq(T.installInputState() == first, true, "install is idempotent")
end

-- 1.6.7: the backpack stores weapon IDs as plain strings (MainWeapons is a
-- TArray<string>, CurrentMainWeaponID a string). Reading them as objects used to
-- throw inside the reader's pcall and silence both counter features with no log,
-- so the shape is asserted through the real reader and the real module.
do
    local realFindAll = FindAllOf
    local bp = { MainWeapons = { "BP_Weapon_Sword_C", "BP_Weapon_DualHook_C" },
        CurrentWeaponIndex = 1, CurrentMainWeaponID = "BP_Weapon_DualHook_C" }
    FindAllOf = function(name)
        if name ~= "PBZBackPackSubsystem" then return {} end
        return { { IsValid = function() return true end, GetName = function() return name end,
            MainWeapons = bp.MainWeapons, CurrentWeaponIndex = bp.CurrentWeaponIndex,
            CurrentMainWeaponID = bp.CurrentMainWeaponID } }
    end
    local w = T.weaponNow()
    eq(type(w), "table", "the backpack answers the weapon reader")
    eq(w and w.current, "BP_Weapon_DualHook_C", "the weapon in hand comes from the index and the string list")
    eq(w and w.next, "BP_Weapon_Sword_C", "the next weapon wraps around the list")
    local A = dofile("Scripts/ad_weapon.lua")
    local o = A.new({ weapon = T.weaponNow, vitals = function() return { shachi = 50, max = 100 } end,
        enemies = function() return {} end, log = function() end })
    eq(o:held(), true, "the counter recognises the weapon in hand")
    eq(o:enough(37), true, "50 % of the bar clears the 37 % floor")
    eq(o:enough(60), false, "50 % of the bar does not clear a 60 % floor")
    FindAllOf = realFindAll
end

-- 1.6.7: the counter layer. The two state machines are covered offline
-- (tools/test_counter.lua, tools/test_weapon.lua); here the wiring is asserted:
-- both features off change nothing, the kind decides from the row, and a stance
-- that never starts hands the hit back to the ordinary chain.
do
    eq(type(T.counterKind), "function", "the counter kind is part of the runtime")
    eq(type(T.counterTry), "function", "the counter seam is public")
    eq(type(T.installCounter), "function", "the counter layer is installable")
    local oldHook, oldShield = S.hookCounter, S.shieldCounter
    local black = { t = "4", [1] = 1.0, [2] = 0.3 }
    local normal = { [1] = 1.0, [2] = 0.3 }
    local seedRow = { seed = true, [1] = 1.0, [2] = 0.3, [3] = true }
    eq(T.counterKind(black), nil, "both features off: a black flash keeps its rule")
    eq(T.counterKind(normal), nil, "both features off: a normal hit keeps its rule")
    S.hookCounter = "on"
    eq(T.counterKind(black), "black", "hook_counter on: a black flash asks for the counter")
    eq(T.counterKind(normal), nil, "hook_counter on: a normal hit stays a parry")
    S.hookCounter = "off"
    S.shieldCounter = "on"
    eq(T.counterKind(normal), "shield", "shield_counter on: a blockable hit asks for the counter")
    eq(T.counterKind(seedRow), nil, "a dodge-only reference row is never countered")
    eq(T.counterKind(black), nil, "shield_counter alone does not take a black flash")
    S.shieldCounter = "off"
    -- The state machines are the real modules; the weapon reader is replaced so the
    -- gate can be opened without a backpack (its own cache would hide the change).
    local realWeapon, realCounter, realStatic = T.weapon, T.counter, StaticFindObject
    -- the Triangle action and the stance action resolve by name; nothing else does
    StaticFindObject = function(path)
        if type(path) == "string" and path:find("/Input/", 1, true) then
            return { IsValid = function() return true end, GetFullName = function() return path end }
        end
        return nil
    end
    T.installCounter()
    eq(type(T.counter), "table", "the timing module is installed")
    T.weapon = { on = false,
        held = function(self) return self.on end,
        nextHeld = function() return false end,
        enough = function() return true end,
        shield = function() return nil end }
    local now = os.clock()
    eq(T.counterTry("black", now + 0.30, now, nil), nil, "wrong weapon: no counter")
    T.weapon.on = true
    eq(T.counterTry("black", now + 0.60, now, nil), "wait", "far from the hit: the counter waits")
    eq(T.counterTry("black", now + 0.30, now, nil), "press", "inside the lead window: the counter presses")
    local hold = T.counterHold
    eq(type(hold), "table", "the press holds a stance")
    eq(hold and hold.pressed, false, "the Triangle press waits one frame")
    eq(T.counter:pending() ~= nil, true, "the state machine remembers the hit")
    T.tickCounter(now)
    eq(hold and hold.pressed, true, "the press happens one frame later")
    eq(T.counter:pending() ~= nil, true, "the stance is still inside its hold time")
    T.tickCounter(now + 0.2)
    eq(T.counterHold, nil, "a stance that never starts is not held forever")
    local st = T.counter:stats()
    eq(st.presses, 1, "one press per offered hit")
    eq(st.failed, 1, "the missing stance is recorded as a failure")
    T.weapon, T.counter, StaticFindObject = realWeapon, realCounter, realStatic
    S.hookCounter, S.shieldCounter = oldHook, oldShield
end

-- A (P0-3): the decision chain's early exits. The fake Deflect Component answers
-- the queries with fixed handles, the fake Ability Input Component counts the
-- activations, so "no press because ..." is asserted where the code decides it.
do
    local decide = _G.__DECIDE
    local realStatic, realGuardOwned = StaticFindObject, T.guardOwned
    local activations = 0
    local pawn = { IsValid = function() return true end, GetAddress = function() return 902 end,
        GetActorForwardVector = function() return { X = 1, Y = 0, Z = 0 } end }
    -- only IA_Deflect resolves: the parry tries then activate through the fake input
    StaticFindObject = function(path)
        if type(path) == "string" and path:find("IA_Deflect", 1, true) then
            return { IsValid = function() return true end, GetFullName = function() return path end }
        end
        return nil
    end
    local function fakeDeflect(red, normal)
        return {
            IsValid = function() return true end,
            GetAddress = function() return 900 end,
            ReceiveFrames = { ForEach = function() end },
            -- red is the IsDodge (undeflectable) handle, normal the deflectable one;
            -- a window below PARRY_WINDOW is the narrow 1.4.2 re-query
            GetNearestValidReceivedFrame = function(_, _, window, isDodge, _, _)
                local h
                if isDodge == true then h = red else h = normal end
                if h == nil or (window or 0) < 0.07 then return -1 end
                return h
            end,
        }
    end
    local function fakeInput()
        return {
            IsValid = function() return true end,
            GetAddress = function() return 901 end,
            TryActivateExternalActionAbilityInterruptLowerByTag = function(_, _, _, _)
                activations = activations + 1
                return true
            end,
        }
    end
    -- 1.6.10: this block's fakes answer the engine query, so ask the engine here;
    -- frame_source = hooks (the shipped default) is covered by the model block above
    S.frameSource = "game"
    if type(decide) == "function" then
        T.tapEndAt = -100 -- no tap in flight: a due press goes out at once
        S.parry = false
        decide(pawn, fakeDeflect(nil, 91), fakeInput(), 100)
        eq(activations, 0, "parry off: no ability activation")
        S.parry = true
        T.guardOwned = function() return true end
        activations = 0
        decide(pawn, fakeDeflect(nil, 92), fakeInput(), 100)
        eq(activations, 0, "PBZPerfectDefense owns the guard: no activation")
        T.guardOwned = realGuardOwned
        -- red first: the dodge branch takes the handle, the parry never sees it
        activations = 0
        decide(pawn, fakeDeflect(771, nil), fakeInput(), 100)
        eq(activations, 0, "red hit: never deflected")
        eq(T.done(771), true, "red hit: the dodge branch took the handle")
        -- nothing announced inside any window
        activations = 0
        decide(pawn, fakeDeflect(nil, nil), fakeInput(), 100)
        eq(activations, 0, "no announced hit: no activation")
        -- the normal case: parry on, the guard is ours, a deflectable hit due
        activations = 0
        decide(pawn, fakeDeflect(nil, 95), fakeInput(), 100)
        eq(activations >= 1, true, "a due deflectable hit activates the ability")
    end
    StaticFindObject, T.guardOwned, S.parry = realStatic, realGuardOwned, true
end

-- A (P0-3), second half: the release check must never let a guard
-- PBZPerfectDefense holds go, and must do nothing while no release is pending.
-- releaseCheck is a block-local, so what the seam can reach is asserted: the two
-- early exits neither throw nor write the line the normal path would add.
do
    local check = _G.__CHECK_RELEASE
    local realGuardOwned = T.guardOwned
    if type(check) == "function" then
        local pawn = { IsValid = function() return true end, GetAddress = function() return 902 end }
        local lines0 = T.logState.lines
        T.guardOwned = function() return true end
        eq(pcall(check, pawn), true, "checkRelease: guard owned by PBZPerfectDefense, no throw")
        T.guardOwned = realGuardOwned
        eq(pcall(check, pawn), true, "checkRelease: no release pending, no throw")
        eq(T.logState.lines, lines0, "checkRelease records nothing without a pending release")
    end
    T.guardOwned = realGuardOwned
end

-- D (P1-8): a once-a-session notice: one ledger line per key, however often the
-- condition repeats (the invulnerable-player line fired every tick of a frame).
do
    if type(T.ledOnce) == "function" then
        local a, b = "ledonce-probe-71", "ledonce-probe-72"
        eq(T.ledOnce("probe71", "once-a %s", a), true, "the first ledOnce for a key writes")
        eq(T.ledOnce("probe71", "once-b %s", a), false, "a repeated ledOnce key is refused")
        eq(T.ledOnce("probe72", "once-c %s", b), true, "another key still writes")
        if T.ledFlush then T.ledFlush() end
        local seenA, seenB = 0, 0
        for line in read("auto_defense_ledger.txt"):gmatch("[^\n]+") do
            if line:find(a, 1, true) then seenA = seenA + 1 end
            if line:find(b, 1, true) then seenB = seenB + 1 end
        end
        eq(seenA, 1, "one ledger line for the repeated key")
        eq(seenB, 1, "the other key has its own line")
    end
end

-- C (P1-1): one success rule for both scheduler APIs (the call did not throw
-- means scheduled, even with no handle), and a scheduled-but-silent loop is
-- switched to the other API once instead of being reported as healthy.
do
    local realFrame, realTimer, realCancel = LoopInGameThreadAfterFrames, LoopInGameThreadWithDelay, CancelDelayedAction
    local function stub(kind, name)
        return function(_, fn)
            _G.__LOOP = fn
            if kind == "throw" then error("stub " .. name .. " throws") end
            if kind == "nil" then return nil end
            return 4242
        end
    end
    CancelDelayedAction = function() return true end
    local matrix = {
        { frame = "nil", timer = "nil", want = "frame" },
        { frame = "nil", timer = "int", want = "frame" },
        { frame = "int", timer = "nil", want = "frame" },
        { frame = "int", timer = "int", want = "frame" },
        { frame = "throw", timer = "nil", want = "timer" },
        { frame = "throw", timer = "int", want = "timer" },
    }
    for _, c in ipairs(matrix) do
        EngineTickAvailable = true
        LoopInGameThreadAfterFrames = stub(c.frame, "frame")
        LoopInGameThreadWithDelay = stub(c.timer, "timer")
        T.loopHandle, T.loopStale = nil, nil
        local ok, err = pcall(T.start)
        eq(ok, true, "start never throws (frame=" .. c.frame .. " timer=" .. c.timer .. "): " .. tostring(err))
        eq(T.loopSchedule, c.want, "scheduled as " .. c.want .. " (frame=" .. c.frame .. " timer=" .. c.timer .. ")")
    end
    eq(type(T.loopVerifyAt), "number", "a scheduled start arms the tick deadline")
    -- both apis absent: a recorded failure, not a silent ignore
    LoopInGameThreadAfterFrames, LoopInGameThreadWithDelay = nil, nil
    T.loopHandle, T.loopStale = nil, nil
    local okF = pcall(T.start)
    eq(okF, true, "start never throws without any scheduler api")
    eq(T.loopSchedule, "failed", "no scheduler api is recorded as failed")
    -- the preferred path is honoured (the verification retry asks for the other one)
    LoopInGameThreadAfterFrames = stub("int", "frame")
    LoopInGameThreadWithDelay = stub("int", "timer")
    T.loopHandle, T.loopStale = nil, nil
    eq(pcall(T.start, "timer"), true, "start(prefer) never throws")
    eq(T.loopSchedule, "timer", "start(prefer) tries the requested path first")
    -- a scheduler call that returned but never ticks is switched once, not trusted
    T.loopHandle, T.loopStale, T.loopId = nil, nil, 1
    T.tickAt, T.ticks = os.clock() - 30, 0
    T.start()
    eq(T.loopSchedule, "frame", "the frame scheduler is preferred for a real start")
    eq(type(T.loopVerifyAt), "number", "start arms the verification deadline")
    T.loopVerifyAt, T.tickAt, T.ticks = os.clock() - 0.01, os.clock() - 30, 0
    T.check()
    eq(T.loopSchedule, "timer", "no tick after the deadline: the other path is tried")
    eq(T.loopVerifyAt ~= nil and T.loopVerifyAt > os.clock(), true, "the new path gets its own deadline")
    LoopInGameThreadAfterFrames, LoopInGameThreadWithDelay = realFrame, realTimer
    CancelDelayedAction = realCancel
    EngineTickAvailable = true
    T.loopHandle, T.loopStale, T.loopId = nil, nil, 1
    T.tickAt, T.ticks = os.clock(), 0
    T.start()
end

-- 1.6.5 (audit P1-4): a hook keeps both ids, one teardown removes everything, and
-- the install record - not a separate flag - decides whether a hook is already in
local seenUnreg, hookCalls = {}, 0
local realReg, realUnreg = RegisterHook, UnregisterHook
RegisterHook = function(path)
    hookCalls = hookCalls + 1
    return path .. "#pre", path .. "#post"
end
UnregisterHook = function(a, b, c)
    seenUnreg[#seenUnreg + 1] = { a, b, c }
end
T.hookIds, T.stopped = nil, false
T.hookBullets()
local firstCalls = hookCalls
eq(firstCalls > 0, true, "the first install registers the bullet hooks")
T.hookBullets()
eq(hookCalls, firstCalls, "a second install call adds nothing: the record is the flag")
eq(type(T.hookIds), "table", "an installed hook is remembered")
local record, records = nil, 0
for _, v in pairs(T.hookIds) do record, records = v, records + 1 end
eq(records > 0, true, "at least one hook record exists")
eq(type(record), "table", "the record is a table, not a bare id")
eq(record.post ~= nil, true, "the post id is kept too, not only the pre id")
eq(type(record.path), "string", "the record keeps the UFunction path")
eq(T.teardown("test"), true, "teardown runs once and reports success")
eq(T.stopped, true, "a torn-down mod is marked stopped")
eq(#seenUnreg > 0 and type(seenUnreg[1][1]) == "string", true,
    "UnregisterHook is called with the documented path form")
eq(#seenUnreg > 0 and seenUnreg[1][3] ~= nil, true, "the post id reaches UnregisterHook")
eq(_G.__LOOP() == false, true, "a tick after teardown decides nothing")
eq(T.teardown("test"), false, "a second teardown is a no-op")
T.check(true)
eq(T.stopped, false, "a human restart re-arms the mod after teardown")
T.hookBullets()
eq(hookCalls > firstCalls, true, "a re-armed mod installs the hooks again")
-- a failed unregister keeps the record: an id thrown away cannot be retried
UnregisterHook = function() error("no UFunction with the specified name was found") end
T.teardown("test2")
eq(next(T.hookIds or {}) ~= nil, true, "a failed unregister keeps the record for a retry")
T.check(true)
eq(T.stopped, false, "the mod is armed again after the second teardown")
T.hookIds = nil
RegisterHook, UnregisterHook = realReg, realUnreg

-- 1.6.10: the reaper is wired into the per-frame decision chain itself, not into a
-- stage that `parry` gates - the old cleanup only ran with parry on, so a
-- parry-off session kept every queued attack. Driven through the real chain.
do
    local QT = _G.__QUEUE_TEST
    if type(QT) == "table" and type(_G.__DECIDE) == "function" then
        local qpawn = { IsValid = function() return true end, GetAddress = function() return 930 end,
            GetActorForwardVector = function() return { X = 1, Y = 0, Z = 0 } end }
        local qdeflect = { IsValid = function() return true end, GetAddress = function() return 931 end,
            ReceiveFrames = { ForEach = function() end },
            GetNearestValidReceivedFrame = function() return -1 end }
        local qinput = { IsValid = function() return true end, GetAddress = function() return 932 end }
        local oldParry = S.parry
        S.parry = false
        QT.clear()
        for _ = 1, 64 do QT.push({ t0 = os.clock(), life = 15 }) end
        _G.__DECIDE(qpawn, qdeflect, qinput, 100)
        eq(QT.len() <= 32, true, "parry off: the decision chain still bounds the queue")
        S.parry = oldParry
        QT.clear()
    end
end

eq(#gaps, 0, "the whole test surface is present: " .. table.concat(gaps, ","))

if T.ledFlush then T.ledFlush() end
local led = read("auto_defense_ledger.txt")
assert(led:find("v1.6.10", 1, true), "the ledger states the running version: " .. led:sub(1, 200))
n = n + 1
print("INTEGRATION PASS " .. n .. " assertions")