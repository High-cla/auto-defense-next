-- Version compatibility layer: the game runs Lua 5.4, the offline suites run
-- LuaJIT (5.1). The few calls that exist in only one of them live here, so the
-- rest of the mod can be written once and read the same on both versions.
-- Nothing here raises: a feature the runtime lacks is reported as false.
local M = {}

-- math.atan honours a quadrant argument (y, x) on 5.4 and silently drops it on
-- 5.1. Probe once at load: atan(1, 0) is pi/2 when the argument is used and
-- pi/4 when it is ignored.
-- The two-argument math.atan is the Lua 5.4 signature; selene checks the 5.1
-- standard library (ue4ss.yml), so both calls carry a local allow.
-- selene: allow(incorrect_standard_library_use)
local QUADRANT_ATAN = math.atan(1, 0) > 1

local function quadrant(y, x)
    if x > 0 then return math.atan(y / x) end
    if x < 0 then
        local a = math.atan(y / x)
        if y >= 0 then return a + math.pi end
        return a - math.pi
    end
    -- x == 0: the limit (and what 5.4 returns); y == 0 is 0 so a still target
    -- does not produce NaN
    if y > 0 then return math.pi / 2 end
    if y < 0 then return -math.pi / 2 end
    return 0
end

-- atan2 (or atan(y) when no x is given). Non-numeric input reads as 0 rather
-- than raising in the middle of a decision tick.
function M.atan(y, x)
    local ny = tonumber(y)
    if ny == nil then return 0 end
    if x == nil then return math.atan(ny) end
    local nx = tonumber(x)
    if nx == nil then return 0 end
    -- selene: allow(incorrect_standard_library_use)
    if QUADRANT_ATAN then return math.atan(ny, nx) end
    return quadrant(ny, nx)
end

-- collectgarbage(mode): a 5.4-only mode ("generational", "incremental") raises
-- '"collectgarbage" got an invalid option' on 5.1, so the failure is a
-- documented false instead of an error while a setting is being applied.
-- No argument means a full collection and reports true.
function M.gc(mode)
    if mode == nil then
        local ok = pcall(collectgarbage)
        return ok
    end
    local ok = pcall(collectgarbage, mode)
    return ok
end

-- "Lua 5.4" in game, "Lua 5.1" plus jit.version offline
function M.version() return _VERSION or "unknown" end

-- rawget keeps the probe working on a runtime without the jit library
function M.hasJit() return type(rawget(_G, "jit")) == "table" end

return M
