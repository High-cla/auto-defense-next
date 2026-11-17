-- Regression test for the expensive ForEachUObject fallback in ad_query.
local oldClock, oldFind, oldEach = os.clock, StaticFindObject, ForEachUObject
local now, scans, lookups, discover = 1, 0, 0, false
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

-- Optional CDOs may be unavailable during startup/build transitions.
assert(Q.ascOf({}) == nil, "missing AbilitySystemBlueprintLibrary is a safe nil result")
assert(Q.nowOf({}) == 0, "missing GameplayStatics is a safe zero-time result")

-- Probe failures must not masquerade as "object invalid" (review F4/F5/F6).
-- A fresh module instance has its own object cache and tag-library retry window.
local Q2 = dofile("Scripts/ad_query.lua")
local msgs = {}
Q2.attach(function(fmt) msgs[#msgs + 1] = fmt end)
discover, walkValid = true, false
now = now + 10
assert(Q2.tagLibrary() == nil, "a walked object that fails validation is not handed out")
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
assert(Q2.ascOf({}) ~= nil, "a failed IsValid probe must not disable every tag read")
assert(msgs[1] ~= nil, "a failed probe is reported instead of silently disabling tags")
local reported = #msgs
assert(Q2.ascOf({}) ~= nil and #msgs >= reported, "repeated failures stay safe")
StaticFindObject = function() return clockLib end
assert(Q2.nowOf({}) == 0, "a failed game-clock read degrades to zero, not to a Lua error")
assert(#msgs > reported, "the game-clock failure is reported once")
StaticFindObject = realLookup

os.clock, StaticFindObject, ForEachUObject = oldClock, oldFind, oldEach
print("QUERY PASS 19 assertions")
