-- Regression test for Scripts/ad_abiinput.lua: the counter presses through the
-- game's own ability input dispatch first and falls back to the vector injection
-- when that does not take the key. Every reader is injected, so the rules are
-- testable without a game.
local AB = dofile("Scripts/ad_abiinput.lua")
local n = 0
local function eq(a, b, why)
    assert(a == b, (why or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
    n = n + 1
end

-- 1. the constructor refuses an adapter it cannot drive
local bad = { pcall(function() AB.new({}) end), pcall(function() AB.new({ asc = function() end }) end) }
eq(bad[1], false, "no readers is rejected")
eq(bad[2], false, "a missing activate is rejected")

-- 2. the game dispatch wins when it takes the key
local calls, lines, t
local function reset(over)
    calls, lines, t = { activate = 0, inject = 0 }, {}, {}
    local o = {
        asc = function() return "asc" end,
        stance = function() return true end,
        activate = function(_, action) calls.activate = calls.activate + 1; t.last = action; return true end,
        inject = function(action) calls.inject = calls.inject + 1; t.injected = action; return true end,
        log = function(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end,
    }
    for k, v in pairs(over or {}) do o[k] = v end
    return AB.new(o)
end

local o = reset()
eq(o:press("IA_Stance"), "handled", "the dispatch answers first")
eq(calls.activate, 1, "the dispatch was called once")
eq(calls.inject, 0, "the vector path stayed out")
eq(t.last, "IA_Stance", "the action went through the dispatch")
eq(o.stats.handled, 1, "the press is counted")
eq(o.dead, false, "a working dispatch never reverts")

-- 3. a dispatch that says no, or raises, falls back to the injection
o = reset({ activate = function() calls.activate = calls.activate + 1; return false, "refused" end })
eq(o:press("IA_AttackH_Press"), "injected", "a refused dispatch falls back")
eq(calls.inject, 1, "the fallback ran")
eq(o.faults, 1, "the refusal is a fault")
eq(#lines, 1, "the first fallback is announced once")
eq(o:press("IA_AttackH_Press"), "injected", "the fallback keeps working")
eq(#lines, 1, "the same fault is not announced again")

o = reset({ activate = function() calls.activate = calls.activate + 1; error("boom") end })
eq(o:press("x"), "injected", "a raising dispatch falls back too")
eq(o.stats.injected, 1, "the injection is counted")

-- 4. no asc is transient: fall back but do not count a fault
o = reset({ asc = function() return nil end })
eq(o:press("x"), "injected", "without an asc the fallback takes over")
eq(o.faults, 0, "a missing asc is not a fault")
eq(calls.activate, 0, "nothing was dispatched")

-- 5. three faults revert the adapter for the rest of the session
o = reset({ activate = function() calls.activate = calls.activate + 1; return false, "refused" end, maxFaults = 3 })
o:press("a"); o:press("b"); o:press("c")
eq(o.dead, true, "the third fault reverts")
eq(o.why, "refused", "the reason is kept")
eq(#lines, 2, "the revert is announced once on top of the first fallback")
local before = calls.activate
eq(o:press("d"), "injected", "a reverted adapter still presses")
eq(calls.activate, before, "a reverted adapter does not dispatch any more")

-- 6. both paths failing is reported, not hidden
o = reset({ activate = function() return false, "no" end, inject = function() calls.inject = calls.inject + 1; return false, "no subsystem" end })
eq(o:press("x"), "failed", "both paths failing is a failure")
eq(o.stats.failed, 1, "the failure is counted")

-- 7. landed() reads the stance back, and three misses revert
o = reset({ stance = function() return true end })
eq(o:landed(), true, "a stance that is up confirms the press")
eq(o.faults, 0, "a confirmed press is no fault")
o = reset({ stance = function() return nil end })
eq(o:landed(), nil, "an unreadable stance answers nothing")
eq(o.faults, 0, "an unreadable stance is not a fault")
o = reset({ stance = function() return false end, maxFaults = 3 })
eq(o:landed(), false, "a stance that never went up is reported")
eq(o.faults, 1, "the miss is a fault")
o:landed(); o:landed()
eq(o.dead, true, "three misses revert the adapter")
eq(o:landed(), nil, "a reverted adapter stops reading the stance")

-- 8. disabling by hand is idempotent and announced once
o = reset()
eq(o:disable("manual"), true, "the first disable changes state")
eq(o:disable("manual"), false, "the second disable is a no-op")
eq(#lines, 1, "the revert is announced once")
eq(o.dead, true, "a manual revert sticks")

print("ABIINPUT PASS " .. n .. " assertions")
