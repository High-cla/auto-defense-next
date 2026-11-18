-- Pure contract test for Scripts/ad_weapon.lua (no game API: every reader is injected).
--
-- Frozen API
--   local Weapon = dofile("Scripts/ad_weapon.lua")
--   local o = Weapon.new(opts)   -- name/range/stale/now/log/vitals/weapon/enemies, all optional
--   o:held(now) / o:nextHeld(now) -> boolean    weapon substring, current hand / off hand
--   o:shachi(now)  -> nil | { value, max, percent }   杀气; percent only when max > 0
--   o:enough(percent, now) -> boolean          permissive while 杀气 is unknown
--   o:shield(now)  -> nil | { actor, class, shield, max, dist }
--   o:keep(now)    -> boolean                  blue shield and the hook at the same time
--   o:stats()      -> { reads, fails, why }
--
-- Everything is offline: the clock is a variable, the "game" is a plain table, and every
-- reader counts its own calls so the per-reader cache is measured from the outside.
-- Run from the mod directory: luajit tools/test_weapon.lua
local loaded, Weapon = pcall(dofile, "Scripts/ad_weapon.lua")
if not loaded then
    -- ad_weapon.lua is owned by a parallel task; until it lands this file is the RED half.
    print("WEAPON FAIL " .. tostring(Weapon))
    os.exit(1)
end
if type(Weapon) ~= "table" or type(Weapon.new) ~= "function" then
    print("WEAPON FAIL the module must return { new }: Scripts/ad_weapon.lua")
    os.exit(1)
end

local n = 0
local function check(cond, why)
    assert(cond, why or "assertion failed")
    n = n + 1
end
local function eq(a, b, why)
    assert(a == b, (why or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
    n = n + 1
end
local function near(a, b, eps, why)
    assert(type(a) == "number" and math.abs(a - b) <= eps,
        (why or "value") .. ": expected " .. tostring(b) .. " +- " .. tostring(eps) .. ", got " .. tostring(a))
    n = n + 1
end

-- Virtual time, and a virtual game that never touches the engine.
local clock = 0
local function now() return clock end
local function T(x) clock = x; return x end

-- Nearest first is not the rule: a closer enemy without a blue shield, with a dead or
-- nonsensical shield value, or without a usable distance must be skipped rather than
-- compared (a string against the radius is exactly the crash this contract forbids).
local function enemyList()
    return {
        { actor = "ghost",   dist = 50,   shield = nil,  class = "BP_Monster_Ghost_C" },
        { actor = "junk",    dist = 10,   shield = "lots" },
        { actor = "zero",    dist = 100,  shield = 0,    max = 300 },
        { actor = "drain",   dist = 120,  shield = -3,   max = 300 },
        { actor = "strdist", shield = 500, dist = "close" },
        { actor = "near",    dist = 300,  shield = 40,   max = 300, class = "BP_Monster_Near_C" },
        { actor = "edge",    dist = 1500, shield = 12,   max = 300, class = "BP_Monster_Edge_C" },
        { actor = "far",     dist = 1600, shield = 90,   max = 300, class = "BP_Monster_Far_C" },
    }
end

local function rowBy(list, actor)
    for _, e in ipairs(list) do
        if e.actor == actor then return e end
    end
end

local function make(over, opts)
    local w = {
        vitals = { shachi = 50, max = 100 },
        weapon = { current = "BP_Weapon_DualHook_C", next = "BP_Weapon_Dao_C" },
        enemies = enemyList(),
        calls = { vitals = 0, weapon = 0, enemies = 0 },
    }
    for k, v in pairs(over or {}) do w[k] = v end
    local o = {
        now = now,
        vitals = function() w.calls.vitals = w.calls.vitals + 1; return w.vitals end,
        weapon = function() w.calls.weapon = w.calls.weapon + 1; return w.weapon end,
        enemies = function() w.calls.enemies = w.calls.enemies + 1; return w.enemies end,
    }
    for k, v in pairs(opts or {}) do o[k] = v end
    return Weapon.new(o), w
end

local function body()
    -- 1. held / nextHeld: a plain substring of the weapon class, nothing else.
    local o, w = make()
    check(type(o) == "table", "new returns an instance")
    eq(o:held(T(0)), true, "BP_Weapon_DualHook_C holds DualHook")
    eq(o:nextHeld(T(0)), false, "the off hand is BP_Weapon_Dao_C")
    eq(w.calls.weapon, 1, "held and nextHeld share the one cached weapon read")
    eq(o:held(T(0.1)), true, "the hook is still in hand inside the stale window")

    local dao = make(nil, { name = "Dao" })
    eq(dao:held(T(1)), false, "a custom name replaces the default")
    eq(dao:nextHeld(T(1)), true, "the off hand matches the custom name")

    local short = make(nil, { name = "Dual" })
    eq(short:held(T(2)), true, "a shorter substring still matches")

    local sword = make(nil, { weapon = function() return { current = "BP_Weapon_Sword_C", next = "BP_Weapon_Sword_C" } end })
    eq(sword:held(T(3)), false, "another weapon is not the hook")
    eq(sword:nextHeld(T(3)), false, "and neither is its off hand")

    local none = make(nil, { weapon = function() return nil end })
    eq(none:held(T(4)), false, "no weapon table is not held")
    eq(none:nextHeld(T(4)), false, "no weapon table has no off hand either")

    local blank = make(nil, { weapon = function() return { current = nil, next = nil } end })
    eq(blank:held(T(5)), false, "a nil current class is not held")

    local both = make(nil, { weapon = function() return { current = "BP_Weapon_DualHook_C", next = "BP_Weapon_DualHook_C" } end })
    eq(both:nextHeld(T(6)), true, "both hands may hold the same weapon")

    local shaped = make(nil, { weapon = function() return "BP_Weapon_DualHook_C" end })
    eq(shaped:held(T(7)), false, "a reader answering the wrong shape is not held")

    -- 2. 杀气: percent is value/max*100 when max is positive, nil when it is not.
    local s, ws = make()
    local v = s:shachi(T(10))
    check(type(v) == "table", "a known 杀气 is a table")
    eq(v.value, 50, "the raw 杀气 value is carried")
    eq(v.max, 100, "the raw maximum is carried")
    eq(v.percent, 50, "50 of 100 is 50 percent")
    eq(s:enough(50, T(10)), true, "exactly at the gate is enough")
    eq(s:enough(50.1, T(10)), false, "a gate above the current percent is not met")
    eq(s:enough(nil, T(10)), true, "no threshold configured asks nothing")
    eq(s:enough(0, T(10)), true, "a zero gate is always met")

    ws.vitals = { shachi = 37, max = 100 }
    local v37 = s:shachi(T(11))
    check(type(v37) == "table", "37 of 100 is a known 杀气")
    eq(v37.value, 37, "37 is carried as value")
    eq(v37.percent, 37, "37 of 100 is exactly 37 percent")
    eq(s:enough(37, T(11)), true, "exactly 37 meets a 37 percent gate")
    eq(s:enough(37.1, T(11)), false, "37 does not meet a 37.1 percent gate")
    eq(s:enough(36.9, T(11)), true, "37 clears a 36.9 percent gate")

    ws.vitals = { shachi = 36.9, max = 100 }
    local v369 = s:shachi(T(12))
    check(type(v369) == "table", "36.9 of 100 is a known 杀气")
    near(v369.percent, 36.9, 1e-9, "36.9 of 100 is 36.9 percent")
    eq(s:enough(37, T(12)), false, "36.9 percent does not meet a 37 percent gate")
    eq(s:enough(36, T(12)), true, "36.9 percent clears a 36 percent gate")

    ws.vitals = { shachi = 5, max = 0 }
    local v0 = s:shachi(T(13))
    check(type(v0) == "table", "a zero maximum still reports a reading")
    eq(v0.value, 5, "the raw value survives a zero maximum")
    eq(v0.max, 0, "a zero maximum is carried")
    eq(v0.percent, nil, "a zero maximum has no percentage")
    eq(s:enough(50, T(13)), true, "an unknown percentage stays permissive")

    ws.vitals = { shachi = 5 }
    local vNoMax = s:shachi(T(14))
    check(type(vNoMax) == "table", "a missing maximum still reports a reading")
    eq(vNoMax.percent, nil, "a missing maximum has no percentage")
    eq(s:enough(99, T(14)), true, "a missing maximum stays permissive")

    local unk = make(nil, { vitals = function() return nil end })
    eq(unk:shachi(T(15)), nil, "no vitals means no 杀气 reading")
    eq(unk:enough(99, T(15)), true, "no vitals stays permissive")
    eq(unk:enough(nil, T(15)), true, "no vitals and no gate asks nothing")

    -- 3. shield(): in range, shield left, nearest wins, and never the caller's row.
    local sh = make()
    local target = sh:shield(T(20))
    check(type(target) == "table", "a qualifying enemy is reported")
    eq(target.actor, "near", "the nearest qualifying enemy wins")
    eq(target.class, "BP_Monster_Near_C", "its class is carried through")
    eq(target.shield, 40, "its shield value is carried through")
    eq(target.max, 300, "its shield maximum is carried through")
    eq(target.dist, 300, "its distance is carried through")

    local atGate = make({ enemies = { { actor = "edge", dist = 1500, shield = 9 } } })
    local atGateRow = atGate:shield(T(21))
    check(type(atGateRow) == "table", "distance exactly at the radius qualifies")
    eq(atGateRow.actor, "edge", "distance exactly at the radius qualifies")
    local overGate = make({ enemies = { { actor = "over", dist = 1500.01, shield = 9 } } })
    eq(overGate:shield(T(21)), nil, "distance beyond the radius does not qualify")
    local tight = make(nil, { range = 299 })
    eq(tight:shield(T(22)), nil, "a smaller radius excludes the 300 cm enemy")
    local wide = make(nil, { range = 1600 })
    local wideRow = wide:shield(T(22))
    check(type(wideRow) == "table", "a wider radius finds the enemy")
    eq(wideRow.actor, "near", "a wider radius still prefers the nearest")

    eq(make({ enemies = {} }):shield(T(23)), nil, "an empty enemy list has no shield")
    local noneRead = make(nil, { enemies = function() return nil end })
    eq(noneRead:shield(T(24)), nil, "a nil enemy sweep has no shield")

    local fresh = make()
    local a = fresh:shield(T(30))
    check(type(a) == "table", "the first answer is a table")
    eq(a.shield, 40, "the first answer is the near enemy")
    a.actor = "mutated"; a.shield = 0; a.dist = 1
    local b = fresh:shield(T(30))
    check(type(b) == "table", "the second answer is a table")
    check(b ~= a, "shield hands out a fresh table every call")
    eq(b.actor, "near", "mutating one answer cannot poison the next")
    eq(b.shield, 40, "the next answer carries the real shield again")
    eq(b.dist, 300, "the next answer carries the real distance again")

    local raw = enemyList()
    local seen = make({ enemies = raw }):shield(T(31))
    check(type(seen) == "table", "the aliasing probe found the enemy")
    check(seen ~= rowBy(raw, "near"), "the answer never aliases the reader's enemy row")
    seen.shield = -1
    eq(rowBy(raw, "near").shield, 40, "the reader's own row is left intact")

    local sfresh = make()
    local p1 = sfresh:shachi(T(32))
    check(type(p1) == "table", "the first 杀气 answer is a table")
    p1.value = 0; p1.percent = 0
    local p2 = sfresh:shachi(T(32))
    check(type(p2) == "table", "the second 杀气 answer is a table")
    check(p2 ~= p1, "shachi hands out a fresh table every call")
    eq(p2.value, 50, "mutating one 杀气 answer cannot poison the next")
    eq(p2.percent, 50, "the next 杀气 percentage is real again")

    -- 4. keep(): the blue shield and the hook in hand, both or nothing.
    eq(make():keep(T(40)), true, "a shielded enemy while holding the hook is kept")
    eq(make({ weapon = { current = "BP_Weapon_Dao_C" } }):keep(T(41)), false, "the hook out of hand keeps nothing")
    eq(make({ enemies = {} }):keep(T(42)), false, "no blue shield keeps nothing")
    eq(make({ enemies = { { actor = "far", dist = 5000, shield = 90 } } }):keep(T(43)), false,
        "an out-of-range shield keeps nothing")

    -- 5. the per-reader cache: one call per stale window, nil answers included.
    local c, wc = make()
    eq(c:held(T(50)), true)
    eq(c:held(T(50.4)), true, "a second read inside 0.5 s is served from the cache")
    eq(wc.calls.weapon, 1, "the weapon reader ran once in the window")
    eq(c:held(T(50.6)), true, "the default window has passed")
    eq(wc.calls.weapon, 2, "the weapon reader ran again after stale seconds")

    local nc, wnc = make()
    wnc.enemies = nil
    eq(nc:shield(T(60)), nil, "a nil sweep is not a shield")
    eq(nc:shield(T(60.3)), nil, "a cached nil stays nil inside the window")
    eq(wnc.calls.enemies, 1, "a nil answer is cached too")
    wnc.enemies = { { actor = "later", dist = 200, shield = 7 } }
    local later = nc:shield(T(60.6))
    check(type(later) == "table", "the next window sees the new sweep")
    eq(later.actor, "later", "the next window sees the new sweep")
    eq(wnc.calls.enemies, 2, "the refreshed window read once more")

    local ind, wi = make()
    check(ind:held(T(70)), "the hook answers")
    check(ind:shachi(T(70)) ~= nil, "杀气 answers")
    check(ind:shield(T(70)) ~= nil, "the shield answers")
    eq(wi.calls.weapon, 1, "the weapon reader keeps its own cache")
    eq(wi.calls.vitals, 1, "the vitals reader keeps its own cache")
    eq(wi.calls.enemies, 1, "the enemy reader keeps its own cache")
    check(ind:held(T(70.4)), "a later read is still cached")
    eq(wi.calls.weapon, 1, "another reader does not reset the weapon window")

    local sl, wl = make(nil, { stale = 2 })
    eq(sl:held(T(80)), true)
    eq(sl:held(T(81.9)), true)
    eq(wl.calls.weapon, 1, "an explicit stale of 2 s still caches at 1.9 s")
    eq(sl:held(T(82.1)), true)
    eq(wl.calls.weapon, 2, "the 2 s window expires after 2 s")

    -- 6. an exploding reader is nil, never an exception: reads and fails count it, and
    -- each distinct reason is logged exactly once.
    local logs = {}
    local mode = 1
    local vit = { shachi = 50, max = 100 }
    local boom = Weapon.new({
        now = now,
        stale = 0.5,
        weapon = function()
            if mode == 1 or mode == 2 then error("weapon reader exploded") end
            error("a different weapon failure")
        end,
        vitals = function() return vit end,
        enemies = function() return nil end,
        log = function(fmt, x, y)
            logs[#logs + 1] = tostring(fmt) .. tostring(x or "") .. tostring(y or "")
        end,
    })
    eq(boom:held(T(90)), false, "a throwing weapon reader is not held")
    eq(#logs, 1, "the first failure logs once")
    eq(boom:held(T(90.6)), false, "the next window throws again")
    eq(#logs, 1, "the same reason is not logged a second time")
    mode = 3
    eq(boom:held(T(91.2)), false, "the third window throws differently")
    eq(#logs, 2, "a new reason logs again")
    local bs = boom:stats()
    eq(bs.reads, 3, "every reader call counts as a read")
    eq(bs.fails, 3, "every thrown reader counts as a failure")
    check(type(bs.why) == "string" and #bs.why > 0, "a failure leaves a reason behind")

    local bad = Weapon.new({
        now = now,
        vitals = function() error("vitals reader exploded") end,
        weapon = function() return { current = "BP_Weapon_DualHook_C" } end,
        enemies = function() error("enemies reader exploded") end,
        log = function() end,
    })
    eq(bad:shachi(T(92)), nil, "a throwing vitals reader yields no 杀气")
    eq(bad:enough(99, T(92)), true, "an unknown 杀气 stays permissive")
    eq(bad:shield(T(92)), nil, "a throwing enemy sweep yields no shield")
    eq(bad:keep(T(93)), false, "keep survives a throwing enemy sweep")
    local badStats = bad:stats()
    check(badStats.fails >= 3, "each throwing reader is counted as a failure")
    check(badStats.reads >= 3, "each throwing reader is counted as a read")

    local weird = Weapon.new({ now = now, stale = 0 })
    check(type(weird) == "table", "new without readers still returns an instance")
    eq(weird:held(T(94)), false, "no readers means no weapon")
    eq(weird:shachi(T(94)), nil, "no readers means no 杀气")
    eq(weird:enough(80, T(94)), true, "no readers stays permissive")
    eq(weird:shield(T(94)), nil, "no readers means no shield")
    eq(weird:keep(T(94)), false, "no readers keeps nothing")

    -- 7. stats(): reads counts real reader calls, not accessor calls.
    local st = make(nil, { stale = 0.5 })
    local s0 = st:stats()
    check(type(s0) == "table", "stats returns a table")
    eq(s0.reads, 0, "nothing has been read yet")
    eq(s0.fails, 0, "nothing has failed yet")
    eq(type(s0.why), "string", "the reason is always a string")
    eq(st:held(T(100)), true)
    eq(st:stats().reads, 1, "one reader call is one read")
    eq(st:held(T(100.2)), true)
    eq(st:stats().reads, 1, "a cache hit is not a read")
    eq(st:held(T(100.7)), true)
    eq(st:stats().reads, 2, "a refreshed window is a read")
    check(st:shachi(T(100.7)) ~= nil, "杀气 answers")
    check(st:shield(T(100.7)) ~= nil, "the shield answers")
    eq(st:stats().reads, 4, "each reader contributes one read")
    eq(st:enough(50, T(100.7)), true, "the cached 杀气 is enough")
    eq(st:stats().reads, 4, "a cached 杀气 read is not counted again")
    eq(st:stats().fails, 0, "no failure so far")
end

local ok, why = pcall(body)
if ok then
    print(("WEAPON PASS %d assertions"):format(n))
else
    print("WEAPON FAIL " .. tostring(why))
    os.exit(1)
end
