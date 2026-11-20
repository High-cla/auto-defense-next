-- Which way a counter key reaches the game. The counter presses through the
-- game's own ability input dispatch (SGameInputSystem.AbilityInputComponent:
-- HandleInputAction) first, the same round trip a real key press takes, and keeps
-- the Enhanced Input vector injection as the fallback: injection is one frame per
-- call, so a dispatch that the game does not take must not cost the counter its
-- window. Three dispatch failures on a row revert the adapter for the session, and
-- every reader is injected, so the rules are testable without a game.
local M = {}

local function fn(v)
    if type(v) == "function" then return v end
    return nil
end

function M.new(opts)
    if type(opts) ~= "table" then error("ad_abiinput.new: an options table is required") end
    local asc, activate, inject = fn(opts.asc), fn(opts.activate), fn(opts.inject)
    if not (asc and activate and inject) then
        error("ad_abiinput.new: asc, activate and inject are required")
    end
    local stance = fn(opts.stance)
    local logf = fn(opts.log)
    local maxFaults = tonumber(opts.maxFaults) or 3
    if maxFaults < 1 then maxFaults = 1 end

    local o = { faults = 0, dead = false, why = nil,
        stats = { handled = 0, injected = 0, failed = 0, presses = 0 } }
    local announced = {}
    local function say(key, fmt, ...)
        if announced[key] then return end
        announced[key] = true
        if logf then pcall(logf, fmt, ...) end
    end

    function o:disable(why)
        if self.dead then return false end
        self.dead, self.why = true, tostring(why or "unspecified")
        say("revert", "counter input: the game dispatch did not take the key %d times (%s), the vector injection takes over",
            self.faults, self.why)
        return true
    end

    local function fault(why)
        if o.dead then return end
        o.faults = o.faults + 1
        if o.faults >= maxFaults then o:disable(why) end
    end

    local function injectPath(action)
        local okI, sent = pcall(inject, action)
        if okI and sent then
            o.stats.injected = o.stats.injected + 1
            return "injected"
        end
        o.stats.failed = o.stats.failed + 1
        return "failed"
    end

    -- "handled": the game took the key through its own dispatch
    -- "injected": the vector fallback pressed it, "failed": neither path reached the game
    function o:press(action)
        self.stats.presses = self.stats.presses + 1
        if action == nil then
            self.stats.failed = self.stats.failed + 1
            return "failed"
        end
        if self.dead then return injectPath(action) end
        local okA, a = pcall(asc)
        if not (okA and a ~= nil) then return injectPath(action) end
        local okD, took, why = pcall(activate, a, action)
        if okD and took then
            self.stats.handled = self.stats.handled + 1
            return "handled"
        end
        local reason = okD and tostring(why or "refused") or tostring(took)
        say("fallback", "counter input: the game dispatch did not take %s (%s), the vector injection takes over",
            tostring(action), reason)
        fault(reason)
        return injectPath(action)
    end

    -- after a press: did an ability of the stance family actually start?
    -- true/false when the game answers, nil when it cannot be read
    function o:landed()
        if self.dead or not stance then return nil end
        local okA, a = pcall(asc)
        if not (okA and a ~= nil) then return nil end
        local okS, up = pcall(stance, a)
        if not (okS and up ~= nil) then return nil end
        if up then return true end
        fault("the stance never started")
        return false
    end

    return o
end

return M
