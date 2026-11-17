-- Regression test for the expensive ForEachUObject fallback in ad_query.
local oldClock, oldFind, oldEach = os.clock, StaticFindObject, ForEachUObject
local now, scans, lookups, discover = 1, 0, 0, false
os.clock = function() return now end
StaticFindObject = function()
    lookups = lookups + 1
    return nil
end
ForEachUObject = function(fn)
    scans = scans + 1
    if discover then fn({
        IsValid = function() return true end,
        GetFName = function() return { ToString = function() return "Default__PBZAbilityBlueprintLibrary" end } end,
        GetFullName = function() return "/Script/PBZCombat.Default__PBZAbilityBlueprintLibrary" end,
    }) end
end

local Q = dofile("Scripts/ad_query.lua")
Q.attach(function() end)
assert(Q.tagLibrary() == nil)
assert(scans == 1, "first miss performs one fallback scan")
assert(lookups == 5, "first miss tries five known StaticFindObject paths")
assert(Q.tagLibrary() == nil)
assert(scans == 1 and lookups == 5, "same-window miss performs no repeated lookup")
now = now + 4.9
assert(Q.tagLibrary() == nil)
assert(scans == 1, "retry is throttled before five seconds")
now = now + 0.2
assert(Q.tagLibrary() == nil)
assert(scans == 2 and lookups == 10, "lookup retries after the cooldown")
discover = true
now = now + 5.1
local found = Q.tagLibrary()
assert(found ~= nil, "late-loaded CDO is found on the next retry")
assert(Q.tagLibrary() == found, "successful object is cached")
assert(scans == 3, "cached success avoids further global scans")

os.clock, StaticFindObject, ForEachUObject = oldClock, oldFind, oldEach
print("QUERY PASS 9 assertions")
