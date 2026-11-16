-- In-process, asynchronous, read-only observability bus + budgeted warm-up.
-- No game API, no decision logic, no writes: callers emit, one drain per tick
-- hands events to subscribers, so the consumer never runs inside a press path.
local M = {}

-- Fixed ring of reusable slots: emit is O(1) and allocates nothing. A full ring
-- drops the new event instead of overwriting undelivered ones (never lose a
-- record that a subscriber has not seen; the drop counter is the budget alarm).
function M.events(cap)
    cap = math.max(8, math.floor(cap or 512))
    local slots, subs = {}, {}
    for i = 1, cap do slots[i] = {} end
    local head, tail, count = 0, 0, 0
    local emitted, dropped, delivered, failures = 0, 0, 0, 0
    local bus = {}

    function bus.emit(kind, a, b, c)
        emitted = emitted + 1
        if count >= cap then dropped = dropped + 1 return false end
        tail = tail % cap + 1
        local s = slots[tail]
        s.kind, s.a, s.b, s.c = kind, a, b, c
        count = count + 1
        return true
    end

    function bus.subscribe(fn)
        if type(fn) ~= "function" then return nil end
        subs[#subs + 1] = fn
        return fn
    end

    -- max = events per drain: the caller passes a small number so one bad
    -- consumer cannot stretch a frame.
    function bus.drain(max)
        if type(max) == "table" then max = 32 end -- a colon call must not become the budget
        max = math.floor(max or 32)
        local n, broken = 0, nil
        while count > 0 and n < max do
            head = head % cap + 1
            local s = slots[head]
            count, n = count - 1, n + 1
            for i = 1, #subs do
                local fn = subs[i]
                if fn then
                    local ok = pcall(fn, s)
                    if not ok then failures = failures + 1 broken = broken or {} broken[#broken + 1] = i end
                end
            end
            -- cleared on delivery: a consumer that keeps the table gets nil
            -- instead of the next event's fields
            s.kind, s.a, s.b, s.c = nil, nil, nil, nil
        end
        -- a subscriber that threw is dropped, so it cannot repeat the cost every tick
        if broken then
            for i = #broken, 1, -1 do table.remove(subs, broken[i]) end
        end
        delivered = delivered + n
        return n
    end

    function bus.stats()
        return { emitted = emitted, dropped = dropped, delivered = delivered,
            pending = count, subs = #subs, failures = failures, cap = cap }
    end
    return bus
end

-- Warm-up queue: each task runs once, a fixed small number per tick, so derived
-- indexes are built without a load-time spike. A failing task is recorded and
-- skipped; it can never stop the game loop.
function M.warm()
    local queue, at, failed = {}, 0, 0
    local w = {}
    function w.task(name, fn)
        queue[#queue + 1] = { name = name, fn = fn }
        return #queue
    end
    function w.step(items)
        if type(items) == "table" then items = 1 end -- ditto for a colon call
        items = math.floor(items or 1)
        local ran = 0
        while at < #queue and ran < items do
            at = at + 1
            local t = queue[at]
            local ok, err = pcall(t.fn)
            ran = ran + 1
            if not ok then
                failed = failed + 1
                w.lastError = tostring(err)
            else
                t.done = true
            end
            t.fn = nil -- drop the closure: built already, or failed and skipped
        end
        return ran
    end
    function w.pending() return #queue - at end
    function w.done() return at >= #queue end
    function w.failed() return failed end
    function w.names() local t = {} for i = 1, #queue do t[i] = queue[i].name end return t end
    return w
end

return M