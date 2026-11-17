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

-- 3. GetNearestValidReceivedFrame keeps its five-argument shape
local call = src:match("GetNearestValidReceivedFrame%(([^)]*)%)")
assert(call, "GetNearestValidReceivedFrame call not found")
local args = 0
for _ in call:gmatch("[^,]+") do args = args + 1 end
eq(args, 5, "GetNearestValidReceivedFrame takes the five SDK arguments")
eq(call:match("^%s*360%.0") ~= nil, true, "the first argument is the deflect angle")
eq(call:match(",%s*%-1%s*,") ~= nil, true, "the current-handle sentinel stays -1")

print("API_CONTRACT PASS " .. n .. " assertions")
