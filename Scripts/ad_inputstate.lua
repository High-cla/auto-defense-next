-- The game's own answer to "is this input held": SDK 0.3.3 declares
-- SGameInputComponent.IsHolding(InputAction) and GetHoldTime(InputAction)
-- (sdk/types/generated/SGameInputSystem.d.ts:299-302), reached through the pawn's
-- "Ability Input Component" .SGameInput. Auto Defense read the physical keys
-- instead, which cannot see a hold the game turned into an action state and
-- cannot see a rebind.
--
-- Read only, and no UE4SS dependency: every game accessor is injected, so this
-- file runs offline in the test suite. read() answers nil - "no answer" - wherever
-- the game cannot be asked, which leaves the caller's key path in charge. Two
-- reasons never to trust an answer blindly:
--   * the fields are reflection-generated, not call-verified (docs/SDK-API-COVERAGE.md)
--   * this mod injects IA_Deflect itself, which makes the action look held
local M = {}

-- Precedence, pure. A definite answer wins; nil means "unknown, ask the keys".
-- A "held" answer the physical keys contradict while our own injection is still
-- in flight is our own press coming back, not the player holding the guard.
function M.pick(held, keyHeld, injecting)
    if held == false then return false, "game" end
    if held == true then
        if keyHeld == true then return true, "game+keys" end
        if injecting then return keyHeld == true, "keys (injecting)" end
        return true, "game"
    end
    return keyHeld == true, "keys"
end

-- opts.component(pawn, propName) -> component|nil   (ad_query.component)
-- opts.prop(obj, key)             -> value|nil      (ad_query.prop)
-- opts.isHolding(comp, action)    -> boolean, may throw
-- opts.holdTime(comp, action)     -> number|nil, may throw (optional)
-- opts.log(fmt, ...)              -> one line per distinct failure
function M.new(opts)
    assert(type(opts) == "table", "ad_inputstate: an options table is required")
    assert(type(opts.component) == "function", "ad_inputstate: component reader is required")
    assert(type(opts.isHolding) == "function", "ad_inputstate: IsHolding reader is required")
    local prop = opts.prop or function(o, k) return o[k] end
    local holdTime, logFn = opts.holdTime, opts.log or function() end
    local o = { asks = 0, known = 0, unknown = 0, faults = 0, why = "-",
        maxFaults = tonumber(opts.maxFaults) or 3 }
    local warned = {}
    local function warnOnce(key, fmt, ...)
        if warned[key] then return end
        warned[key] = true
        logFn(fmt, ...)
    end
    -- Revert is permanent and cheap: a field that stopped answering must not be
    -- re-read every frame for the rest of the session. Only failures that prove the
    -- API is wrong count (missing field, throwing call, wrong type); "no pawn yet"
    -- and "the action is not registered yet" are normal early-session states, and a
    -- good answer in between proves the API is there, so the streak restarts.
    -- colon call: o:disable("why"). Returns true only when it changed anything,
    -- so the caller can log a revert exactly once.
    function o.disable(self, why)
        if self.dead then return false end
        self.dead = true
        self.why = why or self.why or "disabled"
        logFn("input state: reverted to the key state (%s)", self.why)
        return true
    end
    local function miss(why, systemic)
        o.unknown, o.why = o.unknown + 1, why
        if systemic then
            o.faults = o.faults + 1
            if o.faults >= o.maxFaults then o:disable(why) end
        end
        return nil
    end
    -- held: true/false when the game answered, nil when it could not.
    -- secs: the game's own hold duration when it reports one.
    function o.read(pawn, action)
        o.asks = o.asks + 1
        if o.dead then return nil end
        if pawn == nil then return miss("no pawn") end
        if action == nil then return miss("no input action") end
        local okC, comp = pcall(opts.component, pawn, "Ability Input Component")
        if not okC or comp == nil then
            warnOnce("component", "input state: no Ability Input Component (%s), key state is used", tostring(comp))
            return miss("no input component", true)
        end
        local okP, sgi = pcall(prop, comp, "SGameInput")
        if not okP or sgi == nil then
            warnOnce("sgameinput", "input state: no SGameInput on the input component, key state is used")
            return miss("no SGameInput", true)
        end
        local okH, held = pcall(opts.isHolding, sgi, action)
        if not okH then
            warnOnce("isholding", "input state: IsHolding failed (%s), key state is used", tostring(held))
            return miss("IsHolding failed", true)
        end
        if held ~= true and held ~= false then
            warnOnce("isholdingtype", "input state: IsHolding returned %s, key state is used", type(held))
            return miss("IsHolding is not a boolean", true)
        end
        o.known, o.why, o.faults = o.known + 1, "game", 0
        local secs
        if holdTime then
            local okT, v = pcall(holdTime, sgi, action)
            if okT then secs = tonumber(v) end
        end
        return held, secs
    end
    function o.stats() return o.asks, o.known, o.unknown end
    -- the instance carries the rule too: callers hold one object, not two
    o.pick = M.pick
    return o
end

return M
