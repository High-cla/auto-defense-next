-- Regression test for Scripts/ad_query.lua: the expensive ForEachUObject fallback,
-- the memoised tag table, the single name-normalisation rule and the
-- closure-free probes.
local oldClock, oldFind, oldEach = os.clock, StaticFindObject, ForEachUObject
local oldFName = FName
local now, scans, lookups, discover = 1, 0, 0, false
local n = 0
local function ok(cond, why) assert(cond, why or "assertion failed"); n = n + 1 end
local function eq(a, b, why) assert(a == b, why or (tostring(a) .. " ~= " .. tostring(b))); n = n + 1 end

FName = function(s) return "F:" .. tostring(s) end
-- selene: allow(incorrect_standard_library_use)
os.clock = function() return now end
StaticFindObject = function()
    lookups = lookups + 1
    return nil
end
local walkValid = true
ForEachUObject = function(fn)
    scans = scans + 1
    if discover then fn({
        IsValid = function() return walkValid end,
        GetFName = function() return { ToString = function() return "Default__PBZAbilityBlueprintLibrary" end } end,
        GetFullName = function() return "/Script/PBZCombat.Default__PBZAbilityBlueprintLibrary" end,
    }) end
end

local Q = dofile("Scripts/ad_query.lua")
Q.attach(function() end)
ok(Q.tagLibrary() == nil, "the first lookup misses")
eq(scans, 1, "first miss performs one fallback scan")
eq(lookups, 5, "first miss tries five known StaticFindObject paths")
ok(Q.tagLibrary() == nil, "the same-window miss returns nil again")
eq(scans, 1, "same-window miss performs no repeated lookup")
eq(lookups, 5, "same-window miss performs no repeated lookup")
now = now + 4.9
ok(Q.tagLibrary() == nil, "the miss is still throttled at 4.9 s")
eq(scans, 1, "retry is throttled before five seconds")
now = now + 0.2
ok(Q.tagLibrary() == nil, "the miss is still nil after the cooldown")
eq(scans, 2, "lookup retries after the cooldown")
eq(lookups, 10, "the retry walks all five paths again")
discover = true
now = now + 5.1
local found = Q.tagLibrary()
ok(found ~= nil, "late-loaded CDO is found on the next retry")
ok(Q.tagLibrary() == found, "successful object is cached")
eq(scans, 3, "cached success avoids further global scans")

-- Optional CDOs may be unavailable during startup/build transitions.
ok(Q.ascOf({}) == nil, "missing AbilitySystemBlueprintLibrary is a safe nil result")
eq(Q.nowOf({}), 0, "missing GameplayStatics is a safe zero-time result")

-- Probe failures must not masquerade as "object invalid" (review F4/F5/F6).
-- A fresh module instance has its own object cache and tag-library retry window.
local Q2 = dofile("Scripts/ad_query.lua")
local msgs = {}
Q2.attach(function(fmt) msgs[#msgs + 1] = fmt end)
discover, walkValid = true, false
now = now + 10
ok(Q2.tagLibrary() == nil, "a walked object that fails validation is not handed out")
walkValid = true
local realLookup = StaticFindObject
local boomLib = { IsValid = function() return true end,
    GetAbilitySystemComponent = function() return { IsValid = function() error("probe exploded") end } end }
local clockLib = { IsValid = function() return true end,
    GetTimeSeconds = function() error("clock exploded") end }
StaticFindObject = function(path)
    if path:find("AbilitySystemBlueprintLibrary", 1, true) then return boomLib end
    if path:find("GameplayStatics", 1, true) then return clockLib end
    return nil
end
ok(Q2.ascOf({}) ~= nil, "a failed IsValid probe must not disable every tag read")
ok(msgs[1] ~= nil, "a failed probe is reported instead of silently disabling tags")
-- the report is once per reason, not once per tick
local reported = #msgs
ok(Q2.ascOf({}) ~= nil, "repeated failures stay safe")
eq(#msgs, reported, "the same probe failure is reported once, not per call")
StaticFindObject = function() return clockLib end
eq(Q2.nowOf({}), 0, "a failed game-clock read degrades to zero, not to a Lua error")
eq(#msgs, reported + 1, "the game-clock failure is reported once")
eq(Q2.nowOf({}), 0, "the degraded clock read stays safe")
eq(#msgs, reported + 1, "the game-clock failure is not repeated")
StaticFindObject = realLookup

-- P1-9: one normalisation for paths, ":suffix" and repeated "_C"
local names = {
    { "/Game/Abilities/GA_Foo_C", "GA_Foo" },
    { "/Game/Abilities/Foo.GA_Foo_C", "GA_Foo" },
    { "GA_Foo_C_C", "GA_Foo" },
    { "GA_Foo_C_C_C", "GA_Foo" },
    { "GA_Foo:ExecutionTimeline", "GA_Foo" },
    { "GA_Foo_C:ExecutionTimeline", "GA_Foo" },
    { "GA_Foo", "GA_Foo" },
    { "GA_Foo_C1", "GA_Foo_C1" },
}
for _, c in ipairs(names) do
    eq(Q.baseName(c[1]), c[2], "baseName(" .. c[1] .. ")")
end
ok(Q.baseName(nil) == nil, "baseName(nil) is nil")
ok(Q.baseName("") == nil, "baseName('') is nil")
ok(Q.baseName(42) == nil, "baseName(a number) is nil")

-- P1-3: the same tag name hands out the same table
local a, b = Q.tag("GA_Foo"), Q.tag("GA_Foo")
ok(rawequal(a, b), "the same tag name returns the same table")
eq(a.TagName, "F:GA_Foo", "the tag carries the FName it was built from")
ok(not rawequal(a, Q.tag("GA_Bar")), "a different name gets its own table")
eq(Q.tag("GA_Foo").TagName, a.TagName, "the cached table keeps its name")
local odd = Q.tag(nil)
ok(type(odd) == "table" and odd.TagName == nil, "a nil tag name is a safe empty tag")
eq(Q.tag(7).TagName, 7, "a non-string tag name is passed through untouched")

-- selene: allow(incorrect_standard_library_use)
os.clock, StaticFindObject, ForEachUObject, FName = oldClock, oldFind, oldEach, oldFName
print("QUERY PASS " .. n .. " assertions")
