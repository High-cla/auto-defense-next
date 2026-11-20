-- Regression test for Scripts/ad_input.lua: every press, release, stance end and
-- key injection goes through one door that asks the shared rules first. The 1.6.11
-- session showed what a missing binding costs: tl.input.inject answered false 300
-- times, so no dodge key ever went out and only the direct ability activation was
-- left.
local Input = dofile("Scripts/ad_input.lua")
local Policy = dofile("Scripts/ad_policy.lua")
local n = 0
local function eq(a, b, why)
    assert(a == b, (why or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
    n = n + 1
end

local function policy(over)
    local env = { parryOn = function() return true end, pdOwns = function() return false end,
        selfStance = function() return false end }
    for k, v in pairs(over or {}) do env[k] = v end
    return Policy.new(env)
end

local calls, events
local function bind(over)
    calls, events = {}, {}
    local b = {
        policy = policy(),
        emit = function(...) events[#events + 1] = table.concat({ ... }, " ") end,
        pressRaw = function(h, _now) calls.press = h or true; return true end,
        release = function(why) calls.release = why or true; return true end,
        endStance = function(_pawn, why) calls.stanceEnd = why or true; return true end,
        inject = function(action) calls.inject = action; return true end,
    }
    -- false in the overrides means "leave this binding out": pairs() skips nil
    for k, v in pairs(over or {}) do b[k] = v ~= false and v or nil end
    return Input.attach(b)
end

-- 1. a bound injection reaches the mechanic
local IN = bind()
eq(IN.inject("dodge_press", "IA_Dodge"), true, "a bound injection answers true")
eq(calls.inject, "IA_Dodge", "the action reached the key path")

-- 2. the failure that cost the 1.6.11 session: no inject binding
IN = bind({ inject = false })
eq(IN.inject("dodge_press", "IA_Dodge"), false, "an unbound door answers false")
eq(calls.inject, nil, "nothing reached a mechanic")

-- 3. a refused intent never reaches the mechanic, and says why
IN = bind({ policy = policy({ pdOwns = function() return true end }) })
-- the counters live on the module, not on the binding: compare deltas
local a0, d0 = IN.stats()
eq(IN.inject("perfect_tag", "IA_Tag"), false, "a refused intent answers false")
eq(calls.inject, nil, "a refused intent does not press")
eq(events[1], "inject_denied 0 0 pd_guard", "the refusal is emitted with its reason")
local asked, denied = IN.stats()
eq(asked - a0, 1, "the door counts the question")
eq(denied - d0, 1, "the door counts the refusal")

-- 4. the guard press, release and stance end keep their own intents
IN = bind()
eq(IN.pressGuard(7, 1.5), true, "a guard press goes through")
eq(calls.press, 7, "the handle reached the press")
eq(IN.releaseGuard("over"), true, "a release goes through")
eq(calls.release, "over", "the reason reached the release")
eq(IN.endStance("pawn", "idle"), true, "a stance end goes through")
eq(calls.stanceEnd, "idle", "the reason reached the end")

-- 5. parry off refuses the guard press but not the release
IN = bind({ policy = policy({ parryOn = function() return false end }) })
eq(IN.pressGuard(1, 2), false, "parry off refuses the press")
eq(events[1], "parry_denied 1 2 parry_off", "the refusal names the reason")
eq(IN.releaseGuard("x"), true, "a release is still allowed")

-- 6. tag writes take the same door
IN = bind()
eq(IN.tag("perfect_tag", function() calls.tag = true return "ok" end), "ok", "an allowed tag runs")
eq(calls.tag, true, "the tag write happened")

-- 7. an unknown intent is refused, not guessed
IN = bind()
eq(IN.inject("no_such_intent", "IA_Dodge"), false, "an unknown intent is refused")
eq(calls.inject, nil, "an unknown intent presses nothing")

-- 8. the bindings are readable back
IN = bind()
eq(type(IN.bound().inject), "function", "the injection binding is part of the table")

print("INPUT PASS " .. n .. " assertions")
