-- Pure readers for the hook counter: which weapon is held, how much 杀气 is
-- there, and where the nearest blue shield stands. No game API is touched here:
-- every reader is injected, every call sits behind pcall, and every result is
-- cached per reader so a busy tick cannot hammer the game.
local M = {}

-- tonumber() accepts the numeric strings the game API sometimes hands out; NaN and
-- both infinities are never a usable reading.
local function num(v)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

local function text(v)
    local ok, s = pcall(tostring, v)
    if ok and type(s) == "string" then return s end
    return "unprintable error"
end

local function contains(hay, needle)
    if type(hay) ~= "string" then return false end
    return string.find(hay, needle, 1, true) ~= nil
end

function M.new(opts)
    opts = type(opts) == "table" and opts or {}

    local name = type(opts.name) == "string" and opts.name or ""
    if name == "" then name = "DualHook" end
    local range = num(opts.range)
    if not range or range < 0 then range = 1500 end
    local stale = num(opts.stale)
    if not stale or stale < 0 then stale = 0.5 end
    local clock = type(opts.now) == "function" and opts.now or os.clock
    local vlog = type(opts.log) == "function" and opts.log or nil

    local readers = {
        vitals = type(opts.vitals) == "function" and opts.vitals or nil,
        weapon = type(opts.weapon) == "function" and opts.weapon or nil,
        enemies = type(opts.enemies) == "function" and opts.enemies or nil,
    }

    local cache = {}       -- reader key -> { value = table|nil, at = number|nil }
    local reasons, seen = {}, {}
    local reads, fails = 0, 0

    local function note(reason)
        reason = text(reason)
        if seen[reason] then return end
        seen[reason] = true
        reasons[#reasons + 1] = reason
        if vlog then pcall(vlog, "%s", reason) end
    end

    local function stamp()
        local ok, t = pcall(clock)
        if not ok then return nil end
        return num(t)
    end

    -- A caller supplied now wins; otherwise the injected clock is asked once.
    local function at(now)
        local n = num(now)
        if n then return n end
        return stamp()
    end

    -- One reader call per stale seconds of at(). nil results are cached too, and so
    -- is a failed reader, so a broken API cannot be retried every single tick.
    local function read(key, t)
        local entry = cache[key]
        if entry and t and entry.at then
            local age = t - entry.at
            if age >= 0 and age < stale then return entry.value end
        end
        local reader = readers[key]
        local value = nil
        if reader then
            reads = reads + 1
            local ok, result = pcall(reader)
            if ok then
                if type(result) == "table" then value = result end
            else
                fails = fails + 1
                note(key .. " reader failed: " .. text(result))
            end
        end
        cache[key] = { value = value, at = t }
        return value
    end

    local o = { name = name, range = range, stale = stale }

    function o:held(now)
        local w = read("weapon", at(now))
        return w ~= nil and contains(w.current, name)
    end

    function o:nextHeld(now)
        local w = read("weapon", at(now))
        return w ~= nil and contains(w.next, name)
    end

    function o:shachi(now)
        local v = read("vitals", at(now))
        if not v then return nil end
        local value = num(v.shachi)
        if not value then return nil end
        local max = num(v.max)
        local out = { value = value, max = max, percent = nil }
        if max and max > 0 then out.percent = value / max * 100 end
        return out
    end

    function o:enough(percent, now)
        local p = num(percent)
        if not p then return true end
        local s = o:shachi(now)
        if not s or not s.percent then return true end
        return s.percent >= p
    end

    function o:shield(now)
        local list = read("enemies", at(now))
        if not list then return nil end
        local best = nil
        for _, e in ipairs(list) do
            if type(e) == "table" then
                local dist, shield = num(e.dist), num(e.shield)
                -- a shield needs a positive amount and a sane distance inside the gate
                if dist and shield and dist >= 0 and dist <= range and shield > 0 then
                    if not best or dist < best.dist then
                        best = {
                            actor = e.actor,
                            class = type(e.class) == "string" and e.class or nil,
                            shield = shield,
                            max = num(e.max),
                            dist = dist,
                        }
                    end
                end
            end
        end
        return best
    end

    function o:keep(now)
        return o:shield(now) ~= nil and o:held(now)
    end

    function o:stats()
        return { reads = reads, fails = fails, why = table.concat(reasons, "; ") }
    end

    return o
end

return M
