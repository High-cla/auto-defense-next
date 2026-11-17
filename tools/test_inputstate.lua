-- Regression test for Scripts/ad_inputstate.lua: the precedence rule between the
-- game's own hold answer and the key state, and the honest nil on every path where
-- the game cannot be asked (SDK 0.3.3 SGameInputComponent.IsHolding, reflection-
-- generated, so "unavailable" must be a normal answer, not an exception).
local IS = dofile("Scripts/ad_inputstate.lua")
local n = 0
local function ok(cond, why) assert(cond, why or "assertion failed"); n = n + 1 end
local function eq(a, b, why)
    assert(a == b, (why or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
    n = n + 1
end

-- 1. the precedence rule, pure
local held, why = IS.pick(false, true, false)
eq(held, false, "the game's 'up' wins over a held key")
eq(why, "game", "the source is recorded")
eq(IS.pick(true, true, false), true, "game and keys agree")
eq(IS.pick(true, false, false), true, "game 'held' wins when we are not injecting")
eq(IS.pick(true, false, true), false, "our own injection is not the player holding")
eq(IS.pick(nil, true, false), true, "no answer falls back to the keys")
eq(IS.pick(nil, false, false), false, "no answer and no key is not held")
eq(IS.pick(nil, nil, false), false, "no answer and no key answer is not held")
eq(IS.pick(nil, true, true), true, "a held key stays held while injecting")

-- 2. read(): every failure is nil plus a reason, and one log line per reason
local logs, opts
local function reset(over)
    logs = 0
    opts = {
        component = function() return { ok = true } end,
        prop = function(_, k) return k == "SGameInput" and { sgi = true } or nil end,
        isHolding = function() return true end,
        holdTime = function() return 0.42 end,
        log = function() logs = logs + 1 end,
    }
    for k, v in pairs(over or {}) do opts[k] = v end
    return IS.new(opts)
end
local pawn, action = { IsValid = function() return true end }, { act = "IA_Deflect" }

local o = reset()
local h, secs = o.read(nil, action)
eq(h, nil, "no pawn: unknown")
eq(o.why, "no pawn", "reason recorded")
eq(secs, nil, "no pawn: no duration")
h = o.read(pawn, nil)
eq(h, nil, "no input action: unknown")
eq(o.why, "no input action", "reason recorded")

o = reset({ component = function() error("no component") end })
eq(o.read(pawn, action), nil, "a throwing component read is unknown, not an error")
eq(logs, 1, "the first failure logs once")
o.read(pawn, action)
eq(logs, 1, "the same failure stays quiet afterwards")

o = reset({ component = function() return nil end })
eq(o.read(pawn, action), nil, "a missing component is unknown")
eq(o.why, "no input component", "reason recorded")

o = reset({ prop = function() return nil end })
eq(o.read(pawn, action), nil, "a missing SGameInput is unknown")
eq(o.why, "no SGameInput", "reason recorded")

o = reset({ isHolding = function() error("boom") end })
eq(o.read(pawn, action), nil, "a throwing IsHolding is unknown")
eq(o.why, "IsHolding failed", "reason recorded")

o = reset({ isHolding = function() return "yes" end })
eq(o.read(pawn, action), nil, "a non-boolean answer is unknown")
eq(o.why, "IsHolding is not a boolean", "reason recorded")

o = reset()
h, secs = o.read(pawn, action)
eq(h, true, "the game's answer comes through")
eq(secs, 0.42, "the hold duration comes through")
local asks, known, unknown = o.stats()
eq(asks, 1, "asks counted")
eq(known, 1, "a known answer counted")
eq(unknown, 0, "no miss counted")

o = reset({ holdTime = function() error("no hold time") end })
h, secs = o.read(pawn, action)
eq(h, true, "a missing hold duration does not lose the answer")
eq(secs, nil, "a missing hold duration stays nil")

o = reset({ isHolding = function() return false end, holdTime = function() return "x" end })
h, secs = o.read(pawn, action)
eq(h, false, "the game's 'up' comes through")
eq(secs, nil, "a non-numeric duration is dropped")

asks, known, unknown = o.stats()
eq(asks, 1, "asks are counted per object, not per module")
eq(known, 1, "an answered read is known even without a duration")
eq(unknown, 0, "an answered read is not a miss")

-- 3. the module refuses to be built without its readers
ok(not pcall(IS.new, {}), "no readers: refuses to build")
ok(not pcall(IS.new, { component = function() end }), "no IsHolding reader: refuses to build")
ok(pcall(IS.new, { component = function() end, isHolding = function() end }), "the documented minimum builds")

print("INPUTSTATE PASS " .. n .. " assertions")
