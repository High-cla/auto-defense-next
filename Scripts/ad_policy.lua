-- Shared rules: a defense intent is allowed or refused in one place.
-- Pure: it reads state through the injected providers and never touches the game,
-- so the same table can be exercised offline. Decisions that produced the intent
-- keep living where they were; only the "may this run" answer moved here.
local M = {}

-- release/stance_end stay permissive by default: today AD releases a stance even
-- while another mod holds the guard, and tightening that is a behaviour change,
-- not a refactor. Flip these two to the pd_guard rule to make it exclusive.
M.RULES = {
    guard_press = function(e)
        if not e.parryOn() then return false, "parry_off" end
        if e.pdOwns() then return false, "pd_guard" end
        return true
    end,
    perfect_tag = function(e)
        if e.pdOwns() then return false, "pd_guard" end
        return true
    end,
    guard_release = function() return true end,
    stance_end = function() return true end,
    dodge_press = function() return true end,
}

function M.new(env)
    local P = { env = env, denied = {}, deniedN = 0 }
    function P.ask(intent)
        local rule = M.RULES[intent]
        if not rule then return false, "unknown_intent" end
        local ok, why = rule(env)
        if not ok then
            P.denied[why] = (P.denied[why] or 0) + 1
            P.deniedN = P.deniedN + 1
        end
        return ok, why
    end
    function P.allows(intent) return (P.ask(intent)) and true or false end
    function P.who()
        if env.pdOwns() then return "pbzperfectdefense" end
        if env.selfStance() then return "self" end
        return "idle"
    end
    function P.stats() return P.denied, P.deniedN end
    return P
end

return M
