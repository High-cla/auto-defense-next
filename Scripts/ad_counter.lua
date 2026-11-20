-- Pure timing state machine for the hook counter. It owns no game state: it only
-- decides whether a counter is worth offering, hands the press out once, and reports
-- what the guard-stance montage did. Time arrives through opts.now, so every tick can
-- be replayed deterministically. Mirrors the 1.1.4 behaviour (press 0.22 .. 0.35 s
-- before the hit) without copying any code.
local M = {}

local function num(v)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

function M.new(opts)
    opts = type(opts) == "table" and opts or {}

    local lead = num(opts.lead)
    if not lead or lead <= 0 then lead = 0.35 end
    local minLead = num(opts.minLead)
    if not minLead or minLead < 0 then minLead = 0.22 end
    if minLead > lead then minLead = lead end
    local stanceHold = num(opts.stanceHold)
    if not stanceHold or stanceHold < 0 then stanceHold = 0.15 end
    local confirm = num(opts.confirm)
    if not confirm or confirm < 0 then confirm = 0.10 end
    local clock = type(opts.now) == "function" and opts.now or os.clock
    local vlog = type(opts.log) == "function" and opts.log or nil

    local pending = nil      -- { kind, hitAt, stanceUntil, confirmBy, at }
    local guardSeen = false  -- stance montage seen for the current cycle
    local counted = false    -- confirmed already counted for the current cycle
    local pressOwed = false  -- nextPress() still owes one true
    local stats = { offers = 0, presses = 0, waits = 0, confirmed = 0, failed = 0 }

    local function say(fmt, ...)
        if vlog then pcall(vlog, fmt, ...) end
    end

    local function clockNow()
        local ok, t = pcall(clock)
        if not ok then return nil end
        return num(t)
    end

    local function at(now)
        local n = num(now)
        if n then return n end
        return clockNow()
    end

    local function clear()
        pending = nil
        guardSeen = false
        counted = false
    end

    local o = { lead = lead, minLead = minLead, stanceHold = stanceHold, confirm = confirm }

    function o:offer(kind, hitAt, ttl, ctx)
        local c = type(ctx) == "table" and ctx or {}
        -- the counter only exists with the weapon in hand and the counter input
        -- action resolved; anything else keeps the normal defence
        if c.held ~= true or c.action ~= true then return nil end
        if pending then return nil end -- one counter at a time
        local timeToHit, hit = num(ttl), num(hitAt)
        if not timeToHit or not hit then return nil end
        if timeToHit > lead then
            stats.offers = stats.offers + 1
            stats.waits = stats.waits + 1
            return "wait" -- too early: a later tick offers again
        end
        if timeToHit < minLead then return nil end -- too late: keep dodge/parry
        local t = clockNow() or 0
        local label = type(kind) == "string" and kind ~= "" and kind or "counter"
        pending = {
            kind = label, hitAt = hit,
            stanceUntil = hit + stanceHold, confirmBy = t + confirm, at = t,
        }
        pressOwed = true
        stats.offers = stats.offers + 1
        stats.presses = stats.presses + 1
        say("counter press %s ttl=%.3f", label, timeToHit)
        return "press"
    end

    -- the press is owed by the offer, not by the clock, so the tick is only there
    -- to keep the signature the callers already use
    function o:nextPress(_now)
        if not pressOwed then return false end
        pressOwed = false
        return true
    end

    function o:guardUp(_now)
        if not pending or guardSeen then return false end
        guardSeen = true
        return true
    end

    function o:poll(now)
        if not pending then return nil end
        local t = at(now)
        if not t then return nil end
        if guardSeen then
            if not counted then
                counted = true
                stats.confirmed = stats.confirmed + 1
                say("counter confirmed %s", pending.kind)
                return "confirmed"
            end
            if t >= pending.stanceUntil then
                say("counter done %s", pending.kind)
                clear()
                return "done"
            end
            return nil
        end
        if t >= pending.confirmBy then
            stats.failed = stats.failed + 1
            say("counter failed %s", pending.kind)
            clear()
            return "failed"
        end
        return nil
    end

    function o:pending()
        if not pending then return nil end
        return {
            kind = pending.kind, hitAt = pending.hitAt,
            stanceUntil = pending.stanceUntil, confirmBy = pending.confirmBy, at = pending.at,
        }
    end

    function o:stats()
        return {
            offers = stats.offers, presses = stats.presses, waits = stats.waits,
            confirmed = stats.confirmed, failed = stats.failed,
        }
    end

    return o
end

return M
