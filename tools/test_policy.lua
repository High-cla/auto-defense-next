-- Pure test for Scripts/ad_policy.lua and Scripts/ad_input.lua (no game API).
local P = dofile("Scripts/ad_policy.lua")
local IN = dofile("Scripts/ad_input.lua")
local n = 0
local function eq(a, b, why) assert(a == b, why or (tostring(a) .. " ~= " .. tostring(b))); n = n + 1 end

local parryOn, pdOwns, stance = true, false, false
local calls = { press = 0, release = 0, endStance = 0, tag = 0 }
local pol = P.new({
    parryOn = function() return parryOn end,
    pdOwns = function() return pdOwns end,
    selfStance = function() return stance end,
})
IN.attach({ policy = pol,
    pressRaw = function(h, now) calls.press = calls.press + 1 return true end,
    release = function() calls.release = calls.release + 1 return true end,
    endStance = function() calls.endStance = calls.endStance + 1 return true end })

eq(select(1, pol.ask("guard_press")), true, "free to press")
eq(IN.pressGuard(7, 1), true); eq(calls.press, 1)
parryOn = false
local ok, why = pol.ask("guard_press")
eq(ok, false); eq(why, "parry_off")
eq(IN.pressGuard(7, 2), false); eq(calls.press, 1, "the choke refuses before the press")
parryOn = true; pdOwns = true
eq(select(2, pol.ask("guard_press")), "pd_guard")
eq(IN.pressGuard(7, 3), false); eq(calls.press, 1, "other mod owns the guard")
eq(select(1, pol.ask("perfect_tag")), false, "perfect tag belongs to the other mod")
eq(IN.tag("perfect_tag", function() calls.tag = calls.tag + 1 return true end), false)
eq(calls.tag, 0)

-- release and end-stance stay permissive by default (today's behaviour, unchanged);
-- they only become exclusive when the rule table is edited
eq(IN.releaseGuard("sprint"), true); eq(calls.release, 1)
eq(IN.endStance({}, "dodge coming"), true); eq(calls.endStance, 1)
pdOwns = false; stance = true
eq(pol.who(), "self"); stance = false; eq(pol.who(), "idle")
pdOwns = true; eq(pol.who(), "pbzperfectdefense")
pdOwns = false

eq(select(1, pol.ask("nonsense")), false); eq(select(2, pol.ask("nonsense")), "unknown_intent")
local denied, total = pol.stats()
eq(denied.pd_guard, 4, "counters per reason: two asks + two chokepoint refusals")
eq(denied.parry_off, 2)
eq(total, 6)
eq(denied.unknown_intent, nil, "an unknown intent is refused but not counted as a rule denial")
eq(IN.tag("perfect_tag", function() calls.tag = calls.tag + 1 return true end), true)
eq(calls.tag, 1, "tag write goes through the same door when allowed")
-- the injection door (audit P1-4): a denied intent never reaches the mechanic
local injected, denials = {}, 0
local d0 = select(2, IN.stats()) -- earlier refusals already went through the door
IN.attach({ policy = { ask = function(intent) return intent ~= "dodge_press", "test rule" end },
    inject = function(action) injected[#injected + 1] = action return true end,
    emit = function(kind) if kind == "inject_denied" then denials = denials + 1 end end })
eq(IN.inject("dodge_press", "IA_Dodge"), false, "denied injection returns false")
eq(#injected, 0, "denied injection never reaches the mechanic")
eq(denials, 1, "the denial is emitted, not silent")
IN.attach({ policy = { ask = function() return true end },
    inject = function(a) injected[#injected + 1] = a return true end })
eq(IN.inject("dodge_press", "IA_Dodge"), true, "allowed injection runs")
eq(injected[1], "IA_Dodge", "the mechanic gets the action")
eq(IN.stats() >= 2, true, "stats counts every ask")
eq(select(2, IN.stats()) - d0, 1, "stats counts the denial")
print("POLICY PASS " .. n .. " assertions")
