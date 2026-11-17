-- Read-only game queries: object lookup, names, tags, components, game clock.
-- No policy, no input, no writes. Callers get the same functions they had before,
-- so this file only takes ownership of where the queries live.
local M = {}

-- vararg placeholder: attach() swaps in the real logger; a zero-arg stub would
-- silently drop every message and made the call sites look wrong to a linter
-- selene: allow(unused_variable)
local logFn = function(...) end
function M.attach(fn)
    if type(fn) == "function" then logFn = fn end
    return M
end

function M.valid(v) return v ~= nil and v:IsValid() end

-- A throwing probe and an invalid object are different states. Treating the
-- first as the second silently disabled every tag read with no log line at all
-- (review F4/F6), so each reason is reported once and the object is kept.
local warned = {}
local function warnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    logFn(fmt, ...)
end

-- shared readers: pcall(getv, v) instead of pcall(function() return v:get() end)
-- keeps the protection and drops one closure per call on the per-frame paths
local function str(v) return v:ToString() end
local function getv(v) return v:get() end
local function idx(o, k) return o[k] end

function M.name(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local ok, s = pcall(str, v)
    return ok and s or nil
end

function M.unwrap(v)
    if v == nil then return nil end
    local ok, inner = pcall(getv, v)
    if ok and inner ~= nil then return inner end
    return v
end

-- a number out of a wrapper (or a plain number); nil when it cannot be read
function M.num(v)
    if v == nil then return nil end
    if type(v) == "number" then return v end
    local ok, inner = pcall(getv, v)
    if not ok then return nil end
    return tonumber(inner) or tonumber(v)
end

-- one property of an object, safe against a missing field
function M.prop(o, k)
    if o == nil then return nil end
    local ok, v = pcall(idx, o, k)
    if not ok then return nil end
    return v
end

-- ability names arrive as "GA_X_C" / "GA_X_C_C" / with a path: one rule for all
function M.baseName(s)
    if type(s) ~= "string" or s == "" then return nil end
    local n = s:match("([^%./]+)$") or s
    n = n:gsub("_C$", "")
    return n
end

-- object lookup is cached: StaticFindObject is expensive and the path is stable
local objects = {}
function M.obj(path)
    local o = objects[path]
    if M.valid(o) then return o end
    o = StaticFindObject(path)
    if not M.valid(o) then return nil end
    objects[path] = o
    return o
end

function M.tag(s) return { TagName = FName(s) } end

-- PBZAbilityBlueprintLibrary's module is not known for sure: try the likely
-- StaticFindObject paths, then use one global object walk as a fallback. UE4SS
-- documents ForEachUObject/FindAllOf as full object-array scans; a failed lookup
-- must not repeat that scan from a hot decision path.
local tagLib, tagLibRetryAt = nil, 0
local TAG_LIB_RETRY_SEC = 5
function M.tagLibrary()
    if M.valid(tagLib) then return tagLib end
    local now = os.clock()
    if now < tagLibRetryAt then return nil end
    tagLibRetryAt = now + TAG_LIB_RETRY_SEC
    for _, m in ipairs({ "ProjectPBZ", "PBZAbility", "PBZAbilitySystem", "PBZCombat", "PBZGameplay" }) do
        tagLib = M.obj("/Script/" .. m .. ".Default__PBZAbilityBlueprintLibrary")
        if tagLib then return tagLib end
    end
    if type(ForEachUObject) == "function" then
        ForEachUObject(function(o)
            if not tagLib and M.name(o:GetFName()) == "Default__PBZAbilityBlueprintLibrary" then tagLib = o end
        end)
    end
    -- The walk can find an object the engine no longer accepts; returning it
    -- handed an invalid CDO to setPerfect, which then looked like a tag bug.
    if M.valid(tagLib) then
        logFn("PBZAbilityBlueprintLibrary found at %s", tagLib:GetFullName())
        return tagLib
    end
    return nil
end

-- Blueprint property names have spaces ("Deflect Component").
function M.component(pawn, propName)
    if pawn == nil then return nil end
    local ok, c = pcall(idx, pawn, propName)
    if ok and M.valid(c) then return c end
    return nil
end

function M.ascOf(pawn)
    if pawn == nil then return nil end
    -- The CDO can be absent during early startup or after a build change.
    -- Treat it as an unavailable query, not an exception in the defense tick.
    local okLib, lib = pcall(M.obj, "/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
    if not okLib or lib == nil then return nil end
    local ok, asc = pcall(function() return lib:GetAbilitySystemComponent(pawn) end)
    if not ok then
        warnOnce("ascOf.component", "ascOf: GetAbilitySystemComponent failed (%s)", tostring(asc))
        return nil
    end
    if asc == nil then return nil end
    local okValid, alive = pcall(function() return asc:IsValid() end)
    if not okValid then
        warnOnce("ascOf.valid", "ascOf: IsValid probe failed (%s); using the wrapper", tostring(alive))
        return asc
    end
    if alive then return asc end
    return nil
end

function M.nowOf(pawn)
    if pawn == nil then return 0 end
    local okLib, statics = pcall(M.obj, "/Script/Engine.Default__GameplayStatics")
    if not okLib or statics == nil then return 0 end
    local ok, now = pcall(function() return statics:GetTimeSeconds(pawn) end)
    if not ok then
        warnOnce("nowOf.time", "nowOf: GetTimeSeconds failed (%s); time decisions read 0", tostring(now))
        return 0
    end
    return now or 0
end

return M
