--[[ ad_frames — the deflect frames seen from the sender's side.

The engine can hand the mod the frames the player's component received, but
that call (DeflectComponent:GetNearestValidReceivedFrame) needs a table the
engine fills with a struct that holds UObjects; on some UE4SS builds that
write-back crashes the game. This model answers the same question from data
the mod already receives as plain numbers:

  * the send hook says when a frame was created,
  * the ability's PreHitPointDuration says how long until its hit point.

Nothing here touches the game: the clock is injected, so tools/test_frames.lua
runs it offline.
]]
local M = {}

local GRACE = 0.05 -- a frame stays answerable this long after its due time
local PREHIT_MAX = 5.0 -- anything longer is a misread, not a frame

local function number(v)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

function M.new(opts)
    opts = opts or {}
    local now = opts.now or os.clock
    local ttl = number(opts.ttl) or 2.0
    local cap = number(opts.cap) or 64
    if cap < 1 then cap = 1 end

    local o = { added = 0, dropped = 0, refused = 0, answered = 0, missing = 0 }
    local store, order, seq = {}, {}, 0

    local function drop(id)
        if store[id] then
            store[id] = nil
            o.dropped = o.dropped + 1
        end
    end

    local function trim()
        while #order > cap do
            drop(table.remove(order, 1))
        end
    end

    -- f = { at = clock, prehit = seconds, isDodge = boolean, radius, dist, src }
    function o:add(f)
        if type(f) ~= "table" then
            o.refused = o.refused + 1
            return nil
        end
        local at, pre = number(f.at), number(f.prehit)
        if not at or not pre or pre < 0 or pre > PREHIT_MAX then
            o.refused = o.refused + 1
            return nil
        end
        seq = seq + 1
        store[seq] = {
            id = seq,
            at = at,
            due = at + pre,
            prehit = pre,
            isDodge = f.isDodge == true,
            radius = number(f.radius),
            dist = number(f.dist),
            src = f.src,
        }
        order[#order + 1] = seq
        o.added = o.added + 1
        trim()
        return seq
    end

    function o:get(id)
        return store[id]
    end

    -- The frame that will reach the player first, or nil.
    function o:nearest(isDodge, window, t)
        if type(isDodge) ~= "boolean" then return nil end
        local w = number(window)
        if not w or w < 0 then return nil end
        t = number(t) or now()
        local lo, hi = t - GRACE, t + w
        local best, bestDue
        for i = 1, #order do
            local fr = store[order[i]]
            if fr and fr.due >= lo and fr.due <= hi and fr.isDodge == isDodge
                and not (fr.radius and fr.dist and fr.dist > fr.radius) then
                if not best or fr.due < bestDue then
                    best, bestDue = fr.id, fr.due
                end
            end
        end
        if best then o.answered = o.answered + 1 else o.missing = o.missing + 1 end
        return best
    end

    function o:prune(t)
        t = number(t) or now()
        local kept = {}
        for i = 1, #order do
            local fr = store[order[i]]
            if fr then
                if (t - fr.at) <= ttl or fr.due > t then
                    kept[#kept + 1] = fr.id
                else
                    drop(fr.id)
                end
            end
        end
        order = kept
        return #order
    end

    function o:count()
        return #order
    end

    function o:list()
        local out = {}
        for i = 1, #order do out[i] = store[order[i]] end
        return out
    end

    function o:clear()
        store, order = {}, {}
        return true
    end

    function o:stats()
        return {
            added = o.added, dropped = o.dropped, refused = o.refused,
            answered = o.answered, missing = o.missing, live = #order,
        }
    end

    return o
end

return M
