-- Scripts/ad_compat.lua: the 5.4/5.1 bridge must answer on either runtime and
-- must never raise, whatever mode or angle it is handed.
local C = dofile("Scripts/ad_compat.lua")
local n = 0
local function ok(cond, why) assert(cond, why or "assertion failed"); n = n + 1 end
local function eq(a, b, why) assert(a == b, why or (tostring(a) .. " ~= " .. tostring(b))); n = n + 1 end
local function near(a, b, what) assert(math.abs(a - b) < 1e-9, (what or "angle") .. ": " .. tostring(a) .. " ~= " .. tostring(b)); n = n + 1 end
local pi = math.pi

ok(type(C.version()) == "string", "version() returns a string")
eq(C.version(), _VERSION, "version() is the runtime's own _VERSION")
ok(C.version():find("Lua", 1, true) ~= nil, "version() names Lua")
eq(C.hasJit(), type(rawget(_G, "jit")) == "table", "hasJit() follows the jit global")

-- quadrant-aware atan: honoured natively on 5.4, emulated on 5.1
near(C.atan(1, 1), pi / 4, "atan(1, 1)")
near(C.atan(0, 1), 0, "atan(0, 1)")
near(C.atan(1, 0), pi / 2, "atan(1, 0) is the positive vertical")
near(C.atan(-1, 0), -pi / 2, "atan(-1, 0) is the negative vertical")
near(C.atan(0, 0), 0, "atan(0, 0) is 0, not NaN")
near(C.atan(1, -1), 3 * pi / 4, "atan(1, -1) lands in the second quadrant")
near(C.atan(-1, -1), -3 * pi / 4, "atan(-1, -1) lands in the third quadrant")
near(C.atan(2, 1), math.atan(2), "the quadrant form agrees with the plain angle")
near(C.atan(1), pi / 4, "a one-argument call is a plain atan")
ok(select("#", C.atan(1, 0)) == 1, "atan returns exactly one value")
local okAng, ang = pcall(C.atan, nil, 0)
ok(okAng, "a nil y does not raise")
eq(ang, 0, "a non-numeric y reads as 0")
ok(pcall(C.atan, {}, 1), "a table y does not raise")
ok(pcall(C.atan, "2", 0), "a numeric string is accepted")

-- collectgarbage: "generational" exists on 5.4 only, and an unknown mode must
-- come back as false instead of an error mid-apply
local majorMinor = tonumber((_VERSION or ""):match("(%d+%.%d+)")) or 5.1
eq(C.gc(), true, "a no-argument gc performs a full collection")
eq(C.gc("collect"), true, "a known mode succeeds")
eq(C.gc("generational"), majorMinor >= 5.4, "'generational' is true on 5.4 and false on 5.1")
eq(C.gc("no-such-mode"), false, "an unknown mode is a false, never an error")
local realGc = collectgarbage
local seen, exploded = nil, false
-- selene: allow(incorrect_standard_library_use)
collectgarbage = function(mode) seen = mode; if exploded then error("collector exploded") end return 0 end
eq(C.gc(), true, "gc() reports success")
eq(seen, nil, "gc() passes no mode to the collector")
eq(C.gc("step") == true and seen == "step", true, "gc(mode) forwards the mode")
exploded = true
ok(pcall(C.gc, "generational"), "a failing collector is swallowed")
eq(C.gc("generational"), false, "a failing collector is reported as false")
eq(C.gc(), false, "the no-argument form reports the failure too")
collectgarbage = realGc
eq(C.gc(), true, "the real collector is back")

print("COMPAT PASS " .. n .. " assertions")
