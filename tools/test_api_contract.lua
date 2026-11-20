-- Offline contract test: the game API surface AD calls must keep the shape the
-- PBZModLoader game-api SDK 0.3.3 declares. Parameter order and enum values are
-- the two things the game will not complain about when they are wrong - it just
-- decides on the wrong numbers - so they are pinned here instead.
-- Authority: sdk/types/generated/PBZDeflectSystem.d.ts; the SDK's verification levels
-- and what is still unproven are in docs/PBZ-GAME-API-REFERENCE.md (2.1, 9.3).
local function read(path)
    local f = io.open(path, "rb")
    if not f then error("cannot read " .. path) end
    local s = f:read("*a")
    f:close()
    return s
end
local src = read("Scripts/main.lua")
local n = 0
local function eq(actual, expected, why)
    n = n + 1
    if actual ~= expected then
        error(string.format("%s (assertion %d): expected %s, got %s", why, n,
            tostring(expected), tostring(actual)), 2)
    end
end

-- 1. onSendFrame takes the 11 arguments of DeflectComponent.SendDeflectFrame in
--    order: Action, Bullet, AttackRotation, DeflectRadius, DeflectAngle, Strength,
--    Direction, DeflectKnockback, HitPoint, IsDodge, CounterAbility.
local sig = src:match("local function onSendFrame%(([^)]*)%)")
assert(sig, "onSendFrame signature not found")
local params = {}
for p in sig:gmatch("[^,]+") do
    params[#params + 1] = (p:gsub("^%s+", ""):gsub("%s+$", ""))
end
eq(params[1], "ctx", "the first parameter is the hook's RemoteUnrealParam context")
local SDK_ORDER = { [1] = "action", [6] = "strength", [7] = "direction", [10] = "isDodge", [11] = "counter" }
for i = 1, 11 do
    local p = params[i + 1]
    eq(p ~= nil, true, "SendDeflectFrame parameter " .. i .. " exists")
    if SDK_ORDER[i] then
        eq(p, SDK_ORDER[i], "parameter " .. i .. " keeps its SDK position")
    else
        -- Bullet, AttackRotation and the three numbers the mod never reads are
        -- received and unused; an underscore prefix says so and keeps the linter
        -- quiet without changing the hook's shape
        eq(p:sub(1, 1) == "_", true, "parameter " .. i .. " is an unused placeholder")
    end
end
eq(params[13], nil, "SendDeflectFrame has 11 parameters, so nothing follows the last")
-- the instrumentation is gone on purpose: it answered what it could in two sessions
-- (2026-11-18) and a probe that outlives its question is just cost
for _, gone in ipairs({ "SENDARGS", "tl.probeSend", "tl.sendProbe", "tl.tmrProbe",
    "tl.tmrAction", "ACTN %s", "deflect hold:" }) do
    eq(src:find(gone, 1, true), nil, "the probe is gone: " .. gone)
end

-- 2. the bullet-type table matches EDeflectBulletType 0..5
local body = src:match('tl%.BULLET_TYPES%s*=%s*{(.-)}')
assert(body, "tl.BULLET_TYPES not found")
local named, positional = {}, 0
for idx, name in body:gmatch('%[(%d+)%]%s*=%s*"([^"]+)"') do named[tonumber(idx)] = name end
for name in body:gmatch(',%s*"([^"]+)"') do positional = positional + 1 named[positional] = name end
local SDK_ENUM = { [0] = "CantDeflect", "Normal", "BlueEye", "RedEye", "PowerAttack", "HoldDeflect" }
for value = 0, 5 do
    eq(named[value], SDK_ENUM[value], "bullet type " .. value .. " keeps the SDK name")
end
eq(named[6], nil, "the enum has six values, as declared")

-- 3. GetNearestValidReceivedFrame keeps its five-argument shape. The UFunction
-- declares five parameters and UE4SS refuses a call with four in game
-- ("UFunction expected 5 parameters, received 4"); dropping the OutFrame table in
-- 1.6.8 therefore broke the query instead of trimming a dead argument. Its
-- contents are still never read: the handle is only compared with >= 0.
local call = src:match("GetNearestValidReceivedFrame%(([^)]*)%)")
assert(call, "GetNearestValidReceivedFrame call not found")
local parts = {}
for piece in call:gmatch("[^,]+") do parts[#parts + 1] = (piece:match("^%s*(.-)%s*$")) end
eq(#parts, 5, "GetNearestValidReceivedFrame passes all five declared parameters")
eq(parts[1], "360.0", "the first argument is the deflect angle")
eq(parts[4], "-1", "the current-handle sentinel stays -1")
eq(parts[5]:find("{", 1, true) == nil, true, "the OutFrame table is passed by name, not built per call")
eq(src:find("local outFrame = {}", 1, true) ~= nil, true, "one OutFrame table serves every call")

-- 4. A real ReceiveFrame outranks a reference seed, and a seed action remains
-- visible in the decision reason. These source-order contracts prevent a later
-- refactor from restoring the duplicate press that the runtime pairing avoids.
local seedPair = src:find("elseif h.seed and not q.tapped[j]", 1, true)
local pairCall = seedPair and src:find("and tl.pairTimeline", seedPair, true)
local seedReason = src:find("if h.seed then what = what .. \" (reference seed)\" end", 1, true)
eq(seedPair ~= nil, true, "seed rows have a real-frame priority branch")
eq(pairCall ~= nil and pairCall > seedPair, true, "seed branch asks the existing frame pairing before pressing")
eq(seedReason ~= nil, true, "a seed-triggered action names its source")

-- 5. The 1.6.7 counter: the modules read the game through injected readers only,
-- the Triangle press is resolved by name (scanning EnhancedActionMappings from
-- Lua crashed UE4SS with a null FProperty), and a countered hit is neither
-- parried nor dodged. Both features ship off, so an untouched install behaves
-- exactly like 1.6.6.
eq(src:find("tl.installCounter", 1, true) ~= nil, true, "the counter layer is installed from main.lua")
eq(src:find("Scripts/ad_weapon.lua", 1, true) ~= nil, true, "the weapon reader is loaded by name")
eq(src:find("Scripts/ad_counter.lua", 1, true) ~= nil, true, "the counter timing module is loaded by name")
local code = src:gsub("%-%-[^\n]*", "") -- comments may name the table; code may not
eq(code:find("EnhancedActionMappings", 1, true) == nil, true, "no Lua scan of the action mappings")
eq(src:find("tl.COUNTER_ACTIONS", 1, true) ~= nil, true, "the Triangle press is looked up by name")
local counteredTry = src:find("tl.counterTry(kind, now + ttl, now, q.actor, q, j)", 1, true)
local blackBranch = src:find("if h.t == \"4\" and not countered", 1, true)
eq(counteredTry ~= nil and blackBranch ~= nil and counteredTry < blackBranch, true,
   "the counter decides before the black-flash branch")
eq(src:find("local dodgeIt = not countered and", 1, true) ~= nil, true, "a countered hit is not dodged")
eq(src:find('hookCounter = "off", hookCounterShachi = 37, shieldCounter = "off"', 1, true) ~= nil, true,
   "both counter features are off by default")
eq(src:find('if settings.hookCounter == "on" or settings.shieldCounter == "on" then', 1, true) ~= nil, true,
   "the counter ticks are only scheduled when a feature is on")
eq(src:find("hold.q.tapped[hold.j] = nil", 1, true) ~= nil, true,
   "a stance that never starts hands its hit back to the ordinary chain")

print("API_CONTRACT PASS " .. n .. " assertions")
