-- Pure contract test for Scripts/ad_counter.lua (no game API: the clock is injected).
--
-- Frozen API
--   local Counter = dofile("Scripts/ad_counter.lua")
--   local o = Counter.new(opts)   -- lead=0.35 minLead=0.22 stanceHold=0.15 confirm=0.10 now log
--   o:offer(kind, hitAt, ttl, ctx) -> "press" | "wait" | nil
--   o:nextPress(now) -> boolean       true exactly once per press
--   o:guardUp(now)   -> boolean       the guard-stance montage appeared
--   o:poll(now)      -> nil | "confirmed" | "failed" | "done"
--   o:pending()      -> nil | { kind, hitAt, stanceUntil, confirmBy, at }
--   o:stats()        -> { offers, presses, waits, confirmed, failed }
--
-- Behaviour mirrored from AutoPerfectDefense 1.1.4 (independently reimplemented): the
-- counter is only offered when the weapon is in hand, 杀气 is at least the configured
-- percent of max and the counter input action could be resolved, and it has to be
-- pressed 0.22 s .. 0.35 s before the hit.
-- Run from the mod directory: luajit tools/test_counter.lua
local loaded, Counter = pcall(dofile, "Scripts/ad_counter.lua")
if not loaded then
    -- ad_counter.lua is owned by a parallel task; until it lands this file is the RED half.
    print("COUNTER FAIL " .. tostring(Counter))
    os.exit(1)
end
if type(Counter) ~= "table" or type(Counter.new) ~= "function" then
    print("COUNTER FAIL the module must return { new }: Scripts/ad_counter.lua")
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

-- Virtual time: offer() reads the clock through opts.now, the rest is passed in.
local clock = 0
local function now() return clock end
local function T(x) clock = x; return x end

local OK = { held = true, shachiOk = true, action = true }

local function ctx(over)
    local c = { held = true, shachiOk = true, action = true }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

local logs = {}
local function counter(opts)
    local o = {
        now = now,
        log = function(fmt, x) logs[#logs + 1] = tostring(fmt) .. tostring(x or "") end,
    }
    for k, v in pairs(opts or {}) do o[k] = v end
    return Counter.new(o)
end

local function body()
    -- 1. the three gates: weapon in hand, 杀气 high enough, input action resolved.
    local c = counter()
    check(type(c) == "table", "new returns an instance")
    eq(c:offer("parry", 100, 0.30, ctx({ held = false })), nil, "not in hand: no counter")
    eq(c:offer("parry", 100, 0.30, ctx({ shachiOk = false })), nil, "not enough 杀气: no counter")
    eq(c:offer("parry", 100, 0.30, ctx({ action = false })), nil, "no input action: no counter")
    eq(c:offer("parry", 100, 0.30, { held = true, shachiOk = true }), nil, "a missing action is not true")
    eq(c:offer("parry", 100, 0.30, { held = true, action = true }), nil, "a missing 杀气 answer is not true")
    eq(c:offer("parry", 100, 0.30, nil), nil, "no context at all: no counter")
    eq(c:offer("parry", 100, 0.30, "nope"), nil, "a malformed context is not a counter")
    eq(c:pending(), nil, "a refused offer leaves nothing pending")
    eq(c:stats().presses, 0, "a refused offer is not a press")
    eq(c:stats().waits, 0, "a refused offer is not a wait")

    -- 2. the 0.22 s .. 0.35 s window before the hit.
    local w1 = counter()
    T(10)
    eq(w1:offer("parry", 12, 0.50, OK), "wait", "0.50 s before the hit is too early")
    eq(w1:pending(), nil, "a wait leaves nothing pending")
    eq(w1:nextPress(T(10)), false, "a wait is not a press")
    eq(w1:stats().waits, 1, "the wait is counted")
    eq(w1:offer("parry", 12, 0.30, OK), "press", "a later tick offers again and presses")
    eq(w1:stats().presses, 1, "the press is counted")

    local late = counter()
    eq(late:offer("parry", 12, 0.20, OK), nil, "0.20 s before the hit is too late")
    eq(late:pending(), nil, "a too-late offer leaves nothing pending")
    eq(late:nextPress(T(10)), false, "a too-late offer is not a press")
    eq(late:stats().offers, 0, "a refused offer is not a counter offer")

    local edge = counter()
    eq(edge:offer("parry", 12, 0.351, OK), "wait", "just above the lead still waits")
    eq(edge:offer("parry", 12, 0.219, OK), nil, "just below the minimum is refused")
    eq(edge:offer("parry", 12, 0.35, OK), "press", "the lead itself is inside the window")
    local lowEdge = counter()
    eq(lowEdge:offer("parry", 12, 0.22, OK), "press", "the minimum lead itself is inside the window")

    -- 3. pending() carries the arming data and the two derived deadlines.
    local p0 = counter()
    T(100)
    eq(p0:offer("counter", 105, 0.30, OK), "press")
    local p = p0:pending()
    check(type(p) == "table", "a press arms a pending counter")
    eq(p.kind, "counter", "the kind is carried")
    eq(p.hitAt, 105, "the hit time is carried")
    eq(p.at, 100, "at is the clock when the counter was offered")
    eq(p.stanceUntil, 105 + 0.15, "stanceHold defaults to 0.15 s after the hit")
    eq(p.confirmBy, 100 + 0.10, "confirm defaults to 0.10 s after the offer")
    p.kind = "mutated"; p.hitAt = -1; p.confirmBy = 0
    local p2 = p0:pending()
    check(type(p2) == "table", "the armed counter is still pending")
    check(p2 ~= p, "pending hands out a fresh table")
    eq(p2.kind, "counter", "mutating one pending answer cannot poison the state")
    eq(p2.hitAt, 105, "the armed hit time is intact")
    eq(p2.at, 100, "the arming time is intact")

    local custom = counter({ stanceHold = 0.4, confirm = 0.25 })
    T(200)
    eq(custom:offer("parry", 201, 0.30, OK), "press")
    local cp = custom:pending()
    check(type(cp) == "table", "a custom counter is pending")
    eq(cp.stanceUntil, 201 + 0.4, "a custom stanceHold is honoured")
    eq(cp.confirmBy, 200 + 0.25, "a custom confirm window is honoured")
    eq(cp.at, 200, "at follows the injected clock")

    local wide = counter({ lead = 0.5, minLead = 0.1 })
    T(250)
    eq(wide:offer("parry", 300, 0.45, OK), "press", "a custom lead widens the early edge")

    -- 4. nextPress() is true exactly once per press.
    local np = counter()
    T(300)
    eq(np:nextPress(T(300)), false, "nothing armed: no press")
    eq(np:offer("parry", 302, 0.50, OK), "wait")
    eq(np:nextPress(T(300)), false, "a wait never presses")
    eq(np:offer("parry", 302, 0.30, OK), "press")
    eq(np:offer("parry", 302, 0.30, OK), nil, "a pending counter refuses a second offer")
    eq(np:nextPress(T(300)), true, "the press is delivered once")
    eq(np:nextPress(T(300.05)), false, "the second ask is not pressed")
    eq(np:nextPress(T(300.2)), false, "the press does not come back")
    eq(np:stats().presses, 1, "one press counted")

    -- 5. the guard-stance montage confirms; the stance is done at stanceUntil.
    local cf = counter()
    T(500)
    eq(cf:offer("parry", 505, 0.30, OK), "press")
    local pend = cf:pending()
    check(type(pend) == "table", "the confirming counter is pending")
    eq(cf:nextPress(T(500)), true)
    eq(cf:poll(T(500.0)), nil, "no guard stance yet and still inside confirm")
    local up = cf:guardUp(T(500.05))
    check(type(up) == "boolean", "guardUp answers a boolean")
    eq(cf:poll(T(500.06)), "confirmed", "the guard stance confirms the counter")
    eq(cf:stats().confirmed, 1, "the confirmation is counted")
    eq(cf:poll(T(500.10)), nil, "confirmed is delivered once")
    eq(cf:poll(pend.stanceUntil - 0.01), nil, "still inside the guard stance")
    eq(cf:poll(pend.stanceUntil), "done", "the stance ends at stanceUntil")
    eq(cf:poll(pend.stanceUntil + 1), nil, "a finished counter polls nothing")
    eq(cf:pending(), nil, "a finished counter is not pending")
    eq(cf:stats().confirmed, 1, "confirmed counts once")
    eq(cf:stats().failed, 0, "a confirmed counter never fails")

    -- 6. no guard stance by confirmBy fails the counter and clears it.
    local ff = counter()
    T(600)
    eq(ff:offer("parry", 605, 0.30, OK), "press")
    local fp = ff:pending()
    check(type(fp) == "table", "the failing counter is pending")
    eq(ff:nextPress(T(600)), true)
    eq(ff:poll(T(600.05)), nil, "inside the confirm window nothing is decided")
    eq(ff:poll(fp.confirmBy - 0.001), nil, "just before confirmBy the counter is still open")
    eq(ff:poll(fp.confirmBy), "failed", "confirmBy without the guard stance fails")
    eq(ff:stats().failed, 1, "the failure is counted")
    eq(ff:pending(), nil, "a failed counter is cleared")
    eq(ff:poll(fp.confirmBy + 0.5), nil, "a cleared counter polls nothing")
    eq(ff:stats().failed, 1, "a cleared counter does not fail twice")
    eq(ff:stats().confirmed, 0, "a failed counter was never confirmed")
    eq(ff:nextPress(fp.confirmBy + 0.5), false, "a failed counter does not press later")

    -- 7. one counter at a time.
    local one = counter()
    T(700)
    eq(one:offer("parry", 705, 0.30, OK), "press")
    eq(one:offer("parry", 705.5, 0.30, OK), nil, "a pending counter refuses a second press")
    eq(one:offer("dodge", 705.5, 0.50, OK), nil, "a pending counter refuses a wait too")
    eq(one:stats().presses, 1, "the refused offers did not press")
    eq(one:stats().waits, 0, "the refused offers did not wait")
    local op = one:pending()
    check(type(op) == "table", "the armed counter is still pending")
    eq(op.hitAt, 705, "the armed counter is untouched")

    -- 8. stats(): only accepted offers are made, so offers is presses + waits.
    local fresh = counter()
    local fs = fresh:stats()
    eq(fs.offers, 0, "a fresh counter has no offers")
    eq(fs.presses, 0, "a fresh counter has no presses")
    eq(fs.waits, 0, "a fresh counter has no waits")
    eq(fs.confirmed, 0, "a fresh counter has no confirmations")
    eq(fs.failed, 0, "a fresh counter has no failures")
    eq(fresh:poll(T(1000)), nil, "a poll without a pending counter is silent")
    check(type(fresh:guardUp(T(1000))) == "boolean", "guardUp without a pending counter is still a boolean")
    eq(fresh:poll(T(1000.2)), nil, "a guard stance alone confirms nothing")
    eq(fresh:stats().confirmed, 0, "a guard stance alone is not a confirmation")

    local sc = counter()
    T(800)
    eq(sc:offer("parry", 805, 0.50, OK), "wait")
    T(800.1)
    eq(sc:offer("parry", 805, 0.30, OK), "press")
    local sp = sc:pending()
    check(type(sp) == "table", "the first counted counter is pending")
    eq(sc:nextPress(T(800.1)), true)
    sc:guardUp(T(800.15))
    eq(sc:poll(T(800.16)), "confirmed")
    eq(sc:poll(sp.stanceUntil), "done")
    T(900)
    eq(sc:offer("parry", 903, 0.30, OK), "press", "a new counter can be armed after done")
    local sp2 = sc:pending()
    check(type(sp2) == "table", "the second counted counter is pending")
    eq(sc:poll(sp2.confirmBy), "failed")
    local st = sc:stats()
    eq(st.presses, 2, "two counters pressed")
    eq(st.waits, 1, "one early tick waited")
    eq(st.confirmed, 1, "one counter confirmed")
    eq(st.failed, 1, "one counter failed")
    eq(st.offers, 3, "three offers were made: one wait and two presses")
    eq(st.offers, st.presses + st.waits, "every offer is either a press or a wait")
end

local ok, why = pcall(body)
if ok then
    print(("COUNTER PASS %d assertions"):format(n))
else
    print("COUNTER FAIL " .. tostring(why))
    os.exit(1)
end
