-- selene: allow(incorrect_standard_library_use)
-- Pure contract test for Scripts/ad_frames.lua (the hook-fed frame model that
-- replaces the per-frame ReceiveFrames query). Run from the mod folder.
local F = dofile("Scripts/ad_frames.lua")
local n = 0
local function check(ok, why) assert(ok, why); n = n + 1 end
local function eq(a, b, why) check(a == b, why or (tostring(a) .. " ~= " .. tostring(b))) end

local t = 0
local m = F.new({ now = function() return t end })
check(type(m) == "table", "new returns a model")

-- identity and timing: a frame is due at at + prehit
local a = m:add({ at = 10, prehit = 0.30, isDodge = false, radius = 600, dist = 300, src = "GA_A" })
check(type(a) == "number" and a > 0, "add returns a positive id")
t = 10.0
eq(m:nearest(false, 0.4), a, "a frame inside the window is found")
eq(m:nearest(false, 0.2), nil, "a frame outside the window is not")
eq(m:nearest(true, 0.4), nil, "the dodge flag must match")
eq(m:get(a).due, 10.30, "due is at + prehit")
local d = m:add({ at = 10.5, prehit = 0.1, isDodge = true, radius = 600, dist = 300 })
local p2 = m:add({ at = 10.5, prehit = 0.2, isDodge = false, radius = 600, dist = 300 })
t = 10.5
eq(m:nearest(true, 0.4), d, "a dodge frame answers a dodge query")
eq(m:nearest(false, 0.4), p2, "parry answers ignore dodge frames")

-- the nearest of several: earliest due wins
local early = m:add({ at = 11.0, prehit = 0.05, isDodge = false, radius = 600, dist = 100 })
local late = m:add({ at = 11.0, prehit = 0.25, isDodge = false, radius = 600, dist = 100 })
t = 11.0
eq(m:nearest(false, 0.4), early, "the earliest due wins")
check(early ~= late, "two frames get distinct ids")

-- reach: a frame whose radius cannot cover the distance is ignored
local far = m:add({ at = 12.0, prehit = 0.1, isDodge = false, radius = 200, dist = 500 })
t = 12.0
eq(m:nearest(false, 0.4), nil, "out-of-radius frames do not answer")
local near = m:add({ at = 12.0, prehit = 0.1, isDodge = false, radius = 900, dist = 500 })
eq(m:nearest(false, 0.4), near, "a wide enough radius does")
eq(far, m:list()[6].id, "the refused-by-reach frame is still kept")

-- a frame already past its due time by more than the grace is not offered
t = 13.5
eq(m:nearest(false, 0.4), nil, "stale frames are not offered")

-- pruning keeps the model bounded
local big = F.new({ now = function() return t end, ttl = 1.0, cap = 4 })
for i = 1, 10 do big:add({ at = 20 + i * 0.01, prehit = 0.1, isDodge = false, radius = 900, dist = 10 }) end
big:prune(20.2)
eq(big:count() <= 4, true, "the cap bounds the model")
t = 30
big:prune(30)
eq(big:count(), 0, "an idle model empties itself")

-- malformed input never throws and never creates a frame
local before = m:count()
eq(m:add(nil), nil, "nil is refused")
eq(m:add({}), nil, "a frame without timing is refused")
eq(m:add({ at = 0, prehit = -1 }), nil, "a negative prehit is refused")
eq(m:add({ at = 0, prehit = 99 }), nil, "an absurd prehit is refused")
eq(m:add({ at = "x", prehit = 0.1 }), nil, "a non-number at is refused")
eq(m:count(), before, "refused frames change nothing")
eq(m:nearest(nil, nil), nil, "a query without arguments is nil")
eq(#m:list(), m:count(), "list matches count")
local st = m:stats()
eq(st.refused, 5, "refusals are counted")
eq(st.live, m:count(), "stats report the live count")
m:clear()
eq(m:count(), 0, "clear empties the model")

print("FRAMES PASS " .. n .. " assertions")
