-- Pure merger for provenance-bearing no-frame timing seeds. It never reads game
-- objects and never owns an attack lifecycle; main.lua keeps q.tapped/pairTimeline.
local M = {}

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function name(v)
    if type(v) ~= "string" or v == "" then return nil end
    local n = v:gsub("^.*[/%.]", ""):gsub(":.*$", "")
    return (n:gsub("_C$", ""):gsub("_C$", ""))
end

local function rowsOf(v)
    if type(v) ~= "table" then return {} end
    return type(v.rows) == "table" and v.rows or v
end

local function cloneRows(v)
    local out = {}
    if type(v) ~= "table" then return out end
    for _, row in ipairs(v) do
        if type(row) == "table" then
            local copy = {}
            for k, value in pairs(row) do copy[k] = value end
            out[#out + 1] = copy
        end
    end
    return out
end

function M.new(raw, opts)
    opts = type(opts) == "table" and opts or {}
    local meta = type(raw) == "table" and raw or {}
    local gap = tonumber(opts.dedupe) or tonumber(meta.cluster_gap) or 0.15
    if not finite(gap) or gap < 0 then gap = 0.15 end
    local maxDistance = tonumber(opts.maxDistance) or tonumber(meta.max_distance) or 800
    if not finite(maxDistance) or maxDistance < 0 then maxDistance = 800 end
    local margin = tonumber(opts.distanceMargin) or tonumber(meta.distance_margin) or 0
    if not finite(margin) or margin < 0 then margin = 0 end
    local provenance = type(meta.source) == "string" and meta.source or nil
    local index, valid, invalid = {}, 0, 0

    for _, row in ipairs(rowsOf(raw)) do
        local actor = type(row) == "table" and name(row.actor) or nil
        local ability = type(row) == "table" and name(row.ability) or nil
        local frame = type(row) == "table" and tonumber(row.frame) or nil
        local duration = type(row) == "table" and tonumber(row.duration) or nil
        local id = type(row) == "table" and row.id or nil
        local cancel
        if type(row) == "table" then cancel = row.cancel end
        if actor and ability and finite(frame) and frame >= 0 and type(id) == "string" and id ~= ""
            and cancel == false and (duration == nil or (finite(duration) and duration >= 0)) then
            local observed = tonumber(row.distance)
            local limit = tonumber(row.maxDistance)
            if not finite(limit) or limit < 0 then
                limit = finite(observed) and observed + margin or maxDistance
            end
            if finite(limit) and limit >= 0 then
                local key = ability .. "|" .. actor
                index[key] = index[key] or {}
                index[key][#index[key] + 1] = {
                    id = id, actor = actor, ability = ability, montage = row.montage,
                    frame = frame, duration = duration or 0.05, cancel = false,
                    maxDistance = limit, provenance = row.provenance or provenance,
                }
                valid = valid + 1
            else invalid = invalid + 1 end
        else invalid = invalid + 1 end
    end

    local o = { valid = valid, invalid = invalid, gap = gap, maxDistance = maxDistance }
    function o:merge(ability, actorClass, distance, existing)
        local out = cloneRows(existing)
        local a, actor, dist = name(ability), name(actorClass), tonumber(distance)
        local candidates = {}
        if not a or not actor or not finite(dist) or dist < 0 then return out, 0, candidates end
        local found = index[a .. "|" .. actor]
        if not found then return out, 0, candidates end
        local added = 0
        for _, seed in ipairs(found) do
            if dist <= seed.maxDistance then
                candidates[#candidates + 1] = seed
                local duplicate = false
                for _, hit in ipairs(out) do
                    local at = type(hit) == "table" and tonumber(hit[1]) or nil
                    if finite(at) and math.abs(at - seed.frame) <= gap then duplicate = true break end
                end
                if not duplicate then
                    out[#out + 1] = {
                        seed.frame, seed.duration, true, false, false,
                        t = "0", id = seed.id, source = "seed", seed = true,
                        frame = seed.frame, cancel = seed.cancel, provenance = seed.provenance,
                    }
                    added = added + 1
                end
            end
        end
        return out, added, candidates
    end
    return o
end

return M
