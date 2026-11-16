-- Pure test for Scripts/ad_async.lua: run from the mod folder with luajit.
local A = dofile("Scripts/ad_async.lua")
local n = 0
local function eq(a, b, why) assert(a == b, why or (tostring(a) .. " ~= " .. tostring(b))); n = n + 1 end

-- ring: capacity is floored at 8; a full ring drops new events, never undelivered ones
local b = A.events(4)
eq(b.stats().cap, 8, "capacity floor")
local seen = {}
b.subscribe(function(e) seen[#seen + 1] = e.kind end)
for i = 1, 8 do eq(b.emit("k" .. i), true) end
eq(b.emit("k9"), false, "full ring refuses")
local s = b.stats()
eq(s.dropped, 1); eq(s.pending, 8); eq(s.emitted, 9)
eq(b.drain(2), 2); eq(#seen, 2); eq(seen[1], "k1"); eq(seen[2], "k2")
eq(b.stats().pending, 6)
eq(b.emit("k10"), true, "room after drain")
eq(b.drain(20), 7); eq(#seen, 9); eq(seen[9], "k10", "FIFO order kept")

-- slots are reused (no growth) and cleared after delivery
eq(b.stats().pending, 0)
eq(b.stats().delivered, 9)

-- a throwing subscriber is dropped; the others keep working
local bb = A.events(8)
local good = 0
bb.subscribe(function() error("boom") end)
bb.subscribe(function(e) if e.kind == "x" then good = good + 1 end end)
bb.emit("x"); bb.drain(8)
eq(good, 1, "second subscriber still runs")
eq(bb.stats().subs, 1, "broken subscriber removed")
eq(bb.stats().failures, 1)
bb.emit("x"); bb.drain(8); eq(good, 2, "bus survives")
eq(bb.stats().failures, 1, "no repeated failure")

-- drain budget stops early and leaves the rest queued
local bc = A.events(16)
for i = 1, 10 do bc.emit("k" .. i) end
eq(bc.drain(3), 3); eq(bc.stats().pending, 7)

-- the slot table is only valid inside the callback: reuse is the allocation-free
-- contract, and clearing on delivery makes a retained reference fail loudly (nil)
-- instead of silently turning into a later event's fields
local bd = A.events(2)
local first, at
bd.subscribe(function(e) if e.kind == "z" then first, at = e, { e.a, e.b, e.c } end end)
bd.emit("z", 1, "two", 3); bd.drain(1)
eq(at[1], 1); eq(at[2], "two"); eq(at[3], 3)
eq(first.a == nil, true, "delivered slot is cleared")
bd.emit("z", 9); bd.drain(1)
eq(at[1], 9, "same slot reused for the next event")

-- warm queue: fixed tasks per step, failures recorded and skipped
local w = A.warm()
local order = {}
w.task("one", function() order[#order + 1] = 1 end)
w.task("bad", function() error("nope") end)
w.task("three", function() order[#order + 1] = 3 end)
eq(w.pending(), 3)
eq(w.step(1), 1); eq(order[1], 1)
eq(w.step(1), 1); eq(w.failed(), 1, "failure recorded")
eq(w.step(5), 1, "remaining task runs")
eq(w.done(), true); eq(w.pending(), 0)
eq(#order, 2, "failed task produced nothing")
eq(w.step(1), 0, "idle step is free")

print("ASYNC PASS " .. n .. " assertions")