-- PBZ Auto Defense (standalone UE4SS mod).
--   Perfect deflect: adds the game's own debug tag
--     CharacterState.EditorDebug.Deflect.AlwaysPerfect to the player, so every
--     deflect the game accepts counts as perfect.
--   Auto parry: every frame asks the player's Deflect Component for the nearest
--     deflectable hit (GetNearestValidReceivedFrame, IsDodge false: normal and
--     blue hits) and, once it lands within PARRY_WINDOW seconds, activates the
--     equipped weapon's deflect (Ability.Action.Stance) through the Ability Input
--     Component.
--   Auto dodge: same query with IsDodge true (red hits, which cannot be deflected);
--     once one lands within DODGE_WINDOW seconds it activates
--     Ability.Action.Hun.PerfectDodge with the real IA_Dodge input action.
--     Mode "red" dodges only red hits; "all" also dodges hits the parry would take.
--   When the perfect-dodge ability refuses a hit, the dodge key press is
--   injected through Enhanced Input.
--   Sát Khí: the perfect tag keeps the character in a deflect stance, where Sát
--   Khí does not recover; the mod gives the normal recovery back (tickShachi).
--   With the tag on, black flashes are perfect-deflected too (no guard break).
--   Guard release: after the mod's deflect key tap the game keeps the key "held"
--   and the guard stays up. Pressing sprint (the dodge key) with no hit coming
--   releases it through the deflect passive (On Stance Key Release, like the
--   player letting go of the key); guard_release_after > 0 also releases it after
--   that many quiet seconds (off by default: unannounced boss attacks then land
--   on a lowered guard). guard_release_combat_end (8 s) lowers it once the fight
--   is over: no nearby enemy attack, hit taken or parry for that long.
--   Timeline defense (1.3): many enemy attacks are announced too late or not at
--     all. hit_times.txt lists, for every enemy ability, when its hits land
--     (from the game's own ability timelines). When an enemy starts one, the
--     mod follows its animation montage and parries or dodges each listed hit
--     on time: dodged types (0, 3), area attacks (5: rolls away, again while
--     it keeps hitting), flying bursts (6: dodged when they land), grabs
--     (GA_X_C:ExecutionTimeline).
--   debug = on (auto_defense.txt): attacks_log.txt timeline of announced hits,
--   reactions, health drops and enemy abilities, F6 snapshot, and the
--   dodge_attacks / learned-dodge experiments (they did not work in game).
-- Approach taken from GlossTrainer's PBZ native adapter (GPL, GlossMod/GlossTrainer).
-- Keys: F7 perfect deflect, F8 dodge off -> red -> all, F9 auto parry
-- (changeable: key_* in auto_defense.txt).
-- Settings migrate from auto_defense.txt to pbz-auto-defense.config.json (native Mods Menu).
-- Events go to auto_defense_log.txt; text-only fields and restart-only settings are documented.
-- If a Cheat Engine table with Auto Guard / Auto Parry is also used, turn those off:
-- Auto Guard forces normal (non-perfect) results.
local UEHelpers = require("UEHelpers")
-- UEHelpers.GetPlayerController runs FindAllOf("PlayerController") on every call,
-- a walk over every object in the game. The key checks call it every loop tick,
-- which cost frame rate (1.2). Keep the controller until it becomes invalid
-- (level change); this module table belongs to this mod's Lua state only.
do
    local findController, cached = UEHelpers.GetPlayerController, nil
    UEHelpers.GetPlayerController = function()
        local ok, alive = pcall(function() return cached ~= nil and cached:IsValid() end)
        if ok and alive then return cached end
        cached = findController()
        return cached
    end
end
local Toast = require("toast")
local toast = Toast.new(60, 200)

local MOD_DIR = (debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[\\/])") or "") .. "..\\"
local PERFECT_TAG = "CharacterState.EditorDebug.Deflect.AlwaysPerfect"
local DODGE_MODES = { "off", "red", "all" }
local PARRY_WINDOW = 0.08

-- queries live in Scripts/ad_query.lua; the aliases keep every call site unchanged
local Q = dofile(MOD_DIR .. "Scripts/ad_query.lua")
local valid, name, unwrap = Q.valid, Q.name, Q.unwrap

-- the log starts empty each game session and stops growing after LOG_MAX lines
do
    local f = io.open(MOD_DIR .. "auto_defense_log.txt", "w")
    if f then f:close() end
end
-- one state table: the main chunk is at the LuaJIT 200-local ceiling, so the log
-- keeps its counter, cap and cached timestamp as fields (audit P2-12)
local logState = { lines = 0, max = 3000, stamp = nil, at = 0 }
local function log(fmt, ...)
    local line = string.format(fmt, ...)
    logState.lines = logState.lines + 1
    -- the cap covers the console too: print used to run before the check
    if logState.lines > logState.max then
        if logState.lines == logState.max + 1 then
            print("[AutoDefense] log cap reached (" .. logState.max .. " lines)\n")
        end
        return
    end
    print("[AutoDefense] " .. line .. "\n")
    local t = os.clock()
    if t - logState.at >= 1 then logState.stamp, logState.at = os.date("%H:%M:%S"), t end
    local f = io.open(MOD_DIR .. "auto_defense_log.txt", "a")
    if f then f:write((logState.stamp or "--:--:--") .. " " .. line .. "\n") f:close() end
end

Q.attach(log)

-- 1.6.5 (audit P0-2): the offline tests run LuaJIT (Lua 5.1) while the game runs
-- Lua 5.4, so the two calls that only exist in 5.4 go through one layer
-- (Scripts/ad_compat.lua when present, an inline fallback that cannot throw when
-- not). The version is logged once, so "the game is 5.4" is evidence, not a guess.
-- One table, not four locals: the main chunk is at the 200-active-locals ceiling.
local RT = {}
do
    local ok, m = pcall(dofile, MOD_DIR .. "Scripts/ad_compat.lua")
    if ok and type(m) == "table" then RT.compat = m end
end
function RT.gc(mode)
    if RT.compat and RT.compat.gc then return RT.compat.gc(mode) end
    if pcall(collectgarbage, mode) then return true end
    return pcall(collectgarbage, "collect")
end
-- atan2 for the yaw: 5.4 takes (y, x), 5.1 only takes (y / x)
function RT.atan(y, x)
    if RT.compat and RT.compat.atan then return RT.compat.atan(y, x) end
    if x == 0 then return y >= 0 and math.pi / 2 or -math.pi / 2 end
    local a = math.atan(y / x)
    if x < 0 then a = a + (y >= 0 and math.pi or -math.pi) end
    return a
end
-- yaw of the pawn, or the controller's when the pawn has no forward vector;
-- hoisted out of the dodge path so the frame does not build a closure (audit P1-2)
function RT.yawOf(p)
    local fw = p:GetActorForwardVector()
    if fw and (math.abs(fw.X) + math.abs(fw.Y)) > 0.1 then return RT.atan(fw.Y, fw.X) end
    return math.rad(UEHelpers.GetPlayerController():GetControlRotation().Yaw)
end
-- read probes that ran as pcall(function() ... end) on every tick: a named
-- function costs one call and no allocation (audit P1-2). unwrap is the module
-- local from ad_query, so nothing here captures a variable.
-- 1.6.5 (audit P1-9): four slightly different name rules wrote and read the same
-- timeline (path strip, ":ExecutionTimeline", "_C"). ad_query.M.baseName is the one
-- definition; this delegates to it and keeps the old behaviour if an older module
-- copy is on disk, so a half-updated install still matches its own keys.
function RT.bname(s)
    if Q.baseName then return Q.baseName(s) end
    if type(s) ~= "string" or s == "" then return nil end
    local k = s:gsub("^.*[/%.]", "")
    return (k:gsub(":.*$", ""):gsub("_C$", ""):gsub("_C$", ""))
end
function RT.pawnOf(ctrl) return ctrl.Pawn end
function RT.curOf(set) return set.CurrentValue end
function RT.hitTimeOf(d) return tonumber(unwrap(d.HitGameTime)) end
function RT.isDodgeOf(d) return unwrap(d.IsDodge) end
function RT.sourceOf(d) return unwrap(d.SourceAction) end
function RT.bulletOf(s) return tonumber(unwrap(s.DeflectBulletType)) end
function RT.classOf(s) return s:GetClass() end
function RT.fnameOf(o) return o:GetFName():ToString() end
function RT.tagStr(t) return t.TagName:ToString() end
function RT.endAbility(ab) ab:K2_EndAbility() end
function RT.cancelAbility(ab) ab:K2_CancelAbility() end
function RT.setShachi(set, v) set.Shachi.BaseValue = v set.Shachi.CurrentValue = v end
function RT.resetPerfect(ps)
    ps["Reset Perfect Window Punishment"](ps)
    ps["Last Deflect Click"] = -100
    ps["Current Perfect Window Counter"] = 0
end
-- the same rule for "invulnerable right now": a per-tick ledger line for one
-- condition fills the budget, so each key writes once a session (audit P1-8)
RT.kindsAll, RT.kindsRed, RT.kindsDodge = { true, false }, { true }, { false, true }
do
    local jitv = rawget(_G, "jit")
    log("runtime: %s%s%s", _VERSION or "?", jitv and (" / " .. tostring(jitv.version)) or " / no JIT",
        RT.compat and " / ad_compat" or " / inline compat")
end

-- attacks_log.txt: diagnostic timeline of incoming hits, our reactions and the
-- player's health drops (to find attacks the mod does not handle)
local ATTACK_LOG_MAX = 30000
local attackLines = 0
local DEBUG = false -- settings.debug, set once the settings are read
do
    -- the previous session is kept as attacks_log.prev.txt
    os.remove(MOD_DIR .. "attacks_log.prev.txt")
    os.rename(MOD_DIR .. "attacks_log.txt", MOD_DIR .. "attacks_log.prev.txt")
    local f = io.open(MOD_DIR .. "attacks_log.txt", "w")
    if f then f:close() end
end
local function attackLog(fmt, ...)
    if not DEBUG then return end
    attackLines = attackLines + 1
    if attackLines > ATTACK_LOG_MAX then return end
    local f = io.open(MOD_DIR .. "attacks_log.txt", "a")
    if f then f:write(os.date("%H:%M:%S ") .. string.format("[%7.2f] ", os.clock()) .. string.format(fmt, ...) .. "\n") f:close() end
end

-- ---------------------------------------------------------------- settings
-- dodge_attacks: words that mark an enemy attack as one to dodge even though it
-- is not red (black flash: cannot be blocked or parried). Matched, ignoring case,
-- against the enemy's active ability names (see "ENEMY" lines in attacks_log.txt)
-- and the tags of the attacks the hook sees.
local DEFAULT_DODGE_ATTACKS = ""
-- parry_method: "key" taps the deflect key (no held guard after it), "ability"
-- activates the deflect ability directly (leaves the character in a held guard)
-- perfect_mode: the always-perfect debug tag works by holding the character in
-- a deflect stance (the game puts it back as soon as it ends), which stops Sát
-- Khí from recovering. "always" (default) keeps it on, except while a special
-- attack (dodge_attacks) is coming; "window" (lost the perfect result in game)
-- adds it only while a normal hit is announced within PERFECT_LEAD seconds.
-- "give" (test): no tag; each injected deflect press opens the game's own
-- perfect window unpunished (see tl.unpunish), and the tag only goes on around
-- a black flash hit (type 4 in hit_times.txt), which a plain parry cannot take.
-- lang: on-screen text language, "en" or "vi"
-- hotkey_message: "off" keeps the hotkey changes off the screen (log only)
-- guard_release_combat_end: seconds without a nearby enemy attack, a hit taken or
-- a parry after which the fight counts as over and the guard is lowered (0 = off)
-- key_perfect / key_dodge / key_parry / key_snapshot: the hotkeys, a UE4SS key
-- name (F8, K, NUM_ONE, PAGE_UP...) with optional CTRL+ / SHIFT+ / ALT+, or none
-- 1.6.4: the shipped defaults are the values this build is tuned with in game; they
-- mirror pbz-auto-defense.config.json and the menu descriptor's per-row defaults
local settings = { perfect = false, perfectMode = "give", blackFlash = "dodge", dodge = "red", parry = true, parryMethod = "key",
    dodgeAttacks = DEFAULT_DODGE_ATTACKS, debug = false, lang = "en", guardRelease = true,
    guardReleaseAfter = 0.5, guardReleaseCombatEnd = 0.5, hotkeyMessage = true, perf = false, events = true, parryReach = 0.5, learn = true,
    -- 1.4.3, from PBZAssist (timing.*): read every incoming hit's own time and
    -- type (read_frames), time the press inside the game's window (parry_lead),
    -- press the dodge dodge_lead before the hit, leave a hit that lands inside
    -- the last dodge's i-frames to it (dodge_gap / dodge_iframe), pair timeline
    -- hits the game announces (pair_frames), check the game saw the press
    -- (receipt / receipt_retry) and count everything in the ledger
    readFrames = true, parryLeadCfg = "auto", dodgeLead = 0.08, dodgeGap = 0.12, dodgeIframe = 0.26,
    pairFrames = true, receipt = false, receiptRetry = false, ledger = true, latency = true, data = true, dataOff = {}, dataTags = false,
    seedFallback = "record",
    -- 1.6.7: the 别离残钩 counter (black flash answered with hold guard + Triangle
    -- while the weapon is in hand and Sha-chi is high enough) and the blue-shield
    -- counter (bring the weapon out when a shielded enemy is near, counter its
    -- blockable hits). Both off: an install that enables nothing runs 1.6.6.
    hookCounter = "off", hookCounterShachi = 37, shieldCounter = "off", shieldCounterRange = 1500,
    -- 1.4.4, from PBZAssist 1.3.3: min_gap_ms between two deflect presses, the
    -- grab's own lead, dodging again while the last dodge still runs (dodge_cd),
    -- pressing into an action lock (busy_skip), holding the guard through a
    -- flurry instead of one tap per hit (flurry_guard); the shipped numbers are the
    -- tuned ones: min_gap 120 ms, grab 240 ms, dodge_cd off, busy_skip off
    minGap = 0.12, grabLeadMs = 0.24, dodgeCd = false, busySkip = false, flurryGuard = true,
    -- 1.5.1: PBZPerfectDefense 1.8.0 AutoGuard presses and holds the guard itself;
    -- auto = stop guarding while that mod has it on, yield = whenever that mod runs,
    -- off = keep guarding (pbzpd)
    pbzpd = "auto",
    keys = { perfect = "F7", dodge = "F8", parry = "F9", snapshot = "F6" } }
-- hotkeys: names in settings order, modifier names, parse, and (at the end) the actions
local hk = { order = { "perfect", "dodge", "parry", "snapshot" },
    mods = { CTRL = "CONTROL", CONTROL = "CONTROL", SHIFT = "SHIFT", ALT = "ALT" } }
-- "ctrl+f8" -> "CTRL+F8", key, { modifiers }; "none" -> "none"; a bad name -> nil
hk.parse = function(s)
    s = s:upper():gsub("%s", "")
    if s == "NONE" or s == "OFF" then return "none" end
    local parts = {}
    for p in s:gmatch("[^%+]+") do parts[#parts + 1] = p end
    if #parts == 0 or Key[parts[#parts]] == nil then return nil end
    local mods = {}
    for i = 1, #parts - 1 do
        local m = hk.mods[parts[i]]
        if not m or ModifierKey[m] == nil then return nil end
        mods[#mods + 1] = ModifierKey[m]
    end
    return s, Key[parts[#parts]], mods
end
do
    local f = io.open(MOD_DIR .. "auto_defense.txt", "r")
    if f then
        for line in f:lines() do
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(%w+)")
            local list = line:match("^%s*dodge_attacks%s*=%s*(.-)%s*$")
            if list then settings.dodgeAttacks = list end
            if k == "perfect" then settings.perfect = v == "on" end
            if k == "parry" then settings.parry = v == "on" end
            if k == "parry_method" and (v == "key" or v == "ability") then settings.parryMethod = v end
            if k == "perfect_mode" and (v == "window" or v == "always" or v == "give") then settings.perfectMode = v end
            if k == "black_flash" and (v == "dodge" or v == "parry") then settings.blackFlash, settings.blackLine = v, true end
            if k == "debug" then settings.debug = v == "on" end
            if k == "perf" then settings.perf = v == "on" end
            if k == "learn" then settings.learn, settings.learnLine = v ~= "off", true end
            local reach = line:match("^%s*parry_reach%s*=%s*([%d%.]+)")
            if reach and tonumber(reach) then settings.parryReach, settings.reachLine = tonumber(reach), true end
            if k == "guard_release" then settings.guardRelease = v ~= "off" end
            local after = line:match("^%s*guard_release_after%s*=%s*([%d%.]+)")
            if after and tonumber(after) then settings.guardReleaseAfter = tonumber(after) end
            local over = line:match("^%s*guard_release_combat_end%s*=%s*([%d%.]+)")
            if over and tonumber(over) then settings.guardReleaseCombatEnd = tonumber(over) end
            if k == "lang" and (v == "en" or v == "vi") then settings.lang = v end
            if k == "hotkey_message" then settings.hotkeyMessage = v ~= "off" end
            local which, key = line:match("^%s*key_(%a+)%s*=%s*([%w_%+%s]-)%s*$")
            if which and settings.keys[which] then
                settings.keyLines = true
                local name = hk.parse(key)
                if name then settings.keys[which] = name
                else settings.badKeys = (settings.badKeys or "") .. " key_" .. which .. "=" .. key end
            end
            if k == "dodge" then
                for _, m in ipairs(DODGE_MODES) do if m == v then settings.dodge = v end end
            end
            if k == "read_frames" then settings.readFrames, settings.timingLine = v == "on", true end
            if k == "pair_frames" then settings.pairFrames = v == "on" end
            if k == "receipt" then settings.receipt = v ~= "off" end
            if k == "receipt_retry" then settings.receiptRetry = v == "on" end
            if k == "ledger" then settings.ledger = v ~= "off" end
            if k == "latency" then settings.latency = v ~= "off" end
            local pl = line:match("^%s*parry_lead%s*=%s*([%w%.]+)")
            if pl then settings.timingLine, settings.parryLeadCfg = true, tonumber(pl) or pl end
            local dl = line:match("^%s*dodge_lead_ms%s*=%s*([%d%.]+)")
            if dl and tonumber(dl) then settings.timingLine, settings.dodgeLead = true, tonumber(dl) / 1000 end
            local dg = line:match("^%s*dodge_gap_ms%s*=%s*([%d%.]+)")
            if dg and tonumber(dg) then settings.timingLine, settings.dodgeGap = true, tonumber(dg) / 1000 end
            local di = line:match("^%s*dodge_iframe_ms%s*=%s*([%d%.]+)")
            if di and tonumber(di) then settings.dodgeIframe = tonumber(di) / 1000 end
            local mg = line:match("^%s*min_gap_ms%s*=%s*([%d%.]+)")
            if mg and tonumber(mg) then settings.minGap, settings.timing2Line = tonumber(mg) / 1000, true end
            local gl = line:match("^%s*grab_lead_ms%s*=%s*([%d%.]+)")
            if gl and tonumber(gl) then settings.grabLeadMs, settings.timing2Line = tonumber(gl) / 1000, true end
            if k == "dodge_cd" then settings.dodgeCd, settings.timing2Line = v ~= "off", true end
            if k == "busy_skip" then settings.busySkip, settings.timing2Line = v ~= "off", true end
            if k == "flurry_guard" then settings.flurryGuard, settings.timing2Line = v ~= "off", true end
            if k == "data" then settings.data, settings.dataLine = v ~= "off", true end
            if k == "data_tags" then settings.dataTags, settings.dataLine = v ~= "off", true end
            if k == "seed_fallback" and (v == "off" or v == "record" or v == "on") then settings.seedFallback = v end
            if k == "hook_counter" and (v == "off" or v == "on") then settings.hookCounter = v end
            if k == "shield_counter" and (v == "off" or v == "on") then settings.shieldCounter = v end
            local hs = line:match("^%s*hook_counter_shachi%s*=%s*([%d%.]+)")
            if hs and tonumber(hs) then settings.hookCounterShachi = tonumber(hs) end
            local sr = line:match("^%s*shield_counter_range%s*=%s*([%d%.]+)")
            if sr and tonumber(sr) then settings.shieldCounterRange = tonumber(sr) end
            if k == "data_off" then
                settings.dataOff = {}
                local value = line:match("^%s*data_off%s*=%s*(.-)%s*$") or ""
                for w in value:gmatch("[^,%s]+") do settings.dataOff[w] = true end
                settings.dataLine = true
            end
            if k == "pbzpd" and (v == "auto" or v == "yield" or v == "off") then settings.pbzpd, settings.pbzpdLine = v, true end
        end
        f:close()
    end
end
-- 1.6.0: native Mods Menu JSON + descriptor, not a JavaScript port.
-- The old text file is imported only when JSON is absent; it is never written again.
-- 1.6.4: the menu drops the '%' bytes from its save file names on this build, so
-- the shim hands the bridge the name the bridge watches (see ad_menu_bridge.lua).
do
    local ok, result, shim = pcall(function()
        local json = dofile(MOD_DIR .. "Scripts/ad_json.lua")
        local logFn = function(msg) log("%s", msg) end
        local okShim, bridge = pcall(function()
            local B = dofile(MOD_DIR .. "Scripts/ad_menu_bridge.lua")
            return B.new({ modDir = MOD_DIR, log = logFn })
        end)
        if okShim then shim = bridge else log("menu bridge shim unavailable: %s", tostring(bridge)) end
        local menu = dofile(MOD_DIR .. "Scripts/menu_config.lua")
        return menu.new(settings, { dir = MOD_DIR, json = json,
            eventsAlt = shim and shim.eventsAlt or nil,
            keyValid = function(k) return hk.parse(k) ~= nil end,
            log = logFn }), shim
    end)
    if ok then
        hk.menu = result
        hk.bridge = shim
        hk.menu:load(true)
        if shim and shim.mirror then
            log("menu bridge shim: pending-%s.json -> pending-%s.json", shim.loose, shim.exact)
        end
    else
        log("menu adapter unavailable: %s (legacy settings retained)", tostring(result))
    end
end
DEBUG = settings.debug
local function saveSettings()
    if hk.menu then return end -- JSON is authoritative, including restart-only values
    local f = io.open(MOD_DIR .. "auto_defense.txt", "w")
    if not f then return end
    local K = settings.keys
    f:write(string.format("# %s perfect (on/off), %s dodge (off / red / all), %s parry (on/off)\n", K.perfect, K.dodge, K.parry))
    f:write("perfect = " .. (settings.perfect and "on" or "off") .. "\n")
    f:write("# perfect_mode: always (recommended), give (experimental: the guard is not held, Sha-chi\n")
    f:write("# recovers; perfect tag only for black flashes and bullets) or window (do not use)\n")
    f:write("perfect_mode = " .. settings.perfectMode .. "\n")
    f:write("# black_flash (perfect_mode = give only): dodge, or parry with the perfect tag (no guard break,\n")
    f:write("# but Sha-chi drops and the character staggers)\n")
    f:write("black_flash = " .. settings.blackFlash .. "\n")
    f:write("dodge = " .. settings.dodge .. "\n")
    f:write("parry = " .. (settings.parry and "on" or "off") .. "\n")
    f:write("# parry_method: key (taps the deflect key) or ability (older way, leaves a held guard)\n")
    f:write("parry_method = " .. settings.parryMethod .. "\n")
    f:write("# parry_reach: meters; a timeline parry is skipped while the attacker is farther away than this\n")
    f:write("# and the game announced no hit (an attack started from afar that has not reached you). 0 = off\n")
    f:write("parry_reach = " .. tostring(settings.parryReach) .. "\n")
    f:write("# guard_release: sprint (dodge key) lowers the guard the mod's parry left up (on/off)\n")
    f:write("guard_release = " .. (settings.guardRelease and "on" or "off") .. "\n")
    f:write("# guard_release_after: also lower it after this many quiet seconds (0 = only on sprint, recommended for bosses)\n")
    f:write("guard_release_after = " .. tostring(settings.guardReleaseAfter) .. "\n")
    f:write("# guard_release_combat_end: lower it when the fight is over: no nearby enemy attack, hit or parry for this many seconds (0 = off)\n")
    f:write("guard_release_combat_end = " .. tostring(settings.guardReleaseCombatEnd) .. "\n")
    f:write("# on-screen text: en or vi\n")
    f:write("lang = " .. settings.lang .. "\n")
    f:write("# hotkey_message: show the on-screen message when a hotkey is pressed (on/off)\n")
    f:write("hotkey_message = " .. (settings.hotkeyMessage and "on" or "off") .. "\n")
    f:write("# learn: learn from hits taken (learned_hits.txt): a new dodge where an unlisted hit landed, and\n")
    f:write("# parry -> dodge -> area after 2 failures of the same hit. off = no new lessons (on/off)\n")
    f:write("learn = " .. (settings.learn and "on" or "off") .. "\n")
    f:write("# hotkeys (restart the game after a change): a key name such as F8, K, NUM_ONE, PAGE_UP, INS,\n")
    f:write("# optionally with CTRL+ / SHIFT+ / ALT+ (CTRL+F8), or none to turn the hotkey off.\n")
    f:write("# Key names: ue4ss\\Mods\\Keybinds\\Scripts\\main.lua, list at the bottom\n")
    for _, w in ipairs(hk.order) do f:write("key_" .. w .. " = " .. K[w] .. "\n") end
    f:write("# debug: on writes attacks_log.txt and enables the snapshot key (costs some performance)\n")
    f:write("debug = " .. (settings.debug and "on" or "off") .. "\n")
    f:write("# perf: on writes perf_log.txt every 10 s: the mod's time per frame and every frame hitch (for frame drop reports)\n")
    f:write("perf = " .. (settings.perf and "on" or "off") .. "\n")
    f:write("# experimental, leave empty: attacks to dodge instead of parry (enemy ability names)\n")
    f:write("dodge_attacks = " .. settings.dodgeAttacks .. "\n")
    f:write("# read_frames: read every incoming hit's own time and type (DeflectComponent ReceiveFrames) so a\n")
    f:write("# press is timed to the hit; off = ask GetNearestValidReceivedFrame only (1.4.2 behaviour)\n")
    f:write("read_frames = " .. (settings.readFrames and "on" or "off") .. "\n")
    f:write("data = " .. (settings.data and "on" or "off") .. "\n")
    f:write("data_tags = " .. (settings.dataTags and "on" or "off") .. "\n")
    f:write("# seed_fallback: off, record (log exact matches only), or on (dodge from reference no-frame seeds)\n")
    f:write("seed_fallback = " .. (settings.seedFallback or "record") .. "\n")
    f:write("# hook_counter: on = with 别离残钩 (DualHook) in hand and Sha-chi at hook_counter_shachi % of\n")
    f:write("# its maximum, a black flash is answered with the counter (hold guard + Triangle) instead of\n")
    f:write("# the dodge. Nothing is pressed with any other weapon, and off leaves the chain untouched\n")
    f:write("hook_counter = " .. (settings.hookCounter or "off") .. "\n")
    f:write(string.format("hook_counter_shachi = %.0f\n", tonumber(settings.hookCounterShachi) or 37))
    f:write("# shield_counter (being tested): on = an enemy with a blue shield inside shield_counter_range\n")
    f:write("# centimetres makes the mod bring 别离残钩 out and counter that enemy's blockable hits\n")
    f:write("shield_counter = " .. (settings.shieldCounter or "off") .. "\n")
    f:write(string.format("shield_counter_range = %.0f\n", tonumber(settings.shieldCounterRange) or 1500))
    local dataOff = {}
    for k in pairs(settings.dataOff or {}) do dataOff[#dataOff + 1] = k end
    table.sort(dataOff)
    f:write("data_off = " .. table.concat(dataOff, ",") .. "\n")
    f:write("# pbzpd: auto (stop guarding while PBZPerfectDefense has AutoGuard=On and presses the guard\n")
    f:write("# itself), yield (stop while that mod runs at all) or off (guard anyway). Red attacks, grabs,\n")
    f:write("# unannounced hits and the dodge stay with this mod in every case\n")
    f:write("pbzpd = " .. (settings.pbzpd or "auto") .. "\n")
    f:write("# parry_lead: auto (45 % of the game's perfect window, PBZAssist measured 0.2667 s) or seconds\n")
    f:write("parry_lead = " .. tostring(settings.parryLeadCfg) .. "\n")
    f:write("# dodge_lead_ms: the dodge is pressed this long before the hit (PBZAssist: 120 ms, 81 of 81 dodged)\n")
    f:write(string.format("dodge_lead_ms = %.0f\n", (settings.dodgeLead or 0) * 1000))
    f:write("# dodge_gap_ms / dodge_iframe_ms: a hit landing inside the last dodge's i-frames is left to that dodge\n")
    f:write("# instead of a second press (the game drops a dodge pressed while the last one plays)\n")
    f:write(string.format("dodge_gap_ms = %.0f\n", (settings.dodgeGap or 0) * 1000))
    f:write(string.format("dodge_iframe_ms = %.0f\n", (settings.dodgeIframe or 0) * 1000))
    f:write("# pair_frames: a listed timeline hit the game announces too is pressed once, not twice\n")
    f:write("pair_frames = " .. (settings.pairFrames and "on" or "off") .. "\n")
    f:write("# receipt: check that the game saw the press (Last Deflect Click on the deflect passive);\n")
    f:write("# receipt_retry = on presses again when it did not (off until the check is confirmed in game)\n")
    f:write("receipt = " .. (settings.receipt and "on" or "off") .. "\n")
    f:write("receipt_retry = " .. (settings.receiptRetry and "on" or "off") .. "\n")
    f:write("# latency: take half the measured input delay off the parry lead (on/off)\n")
    f:write("latency = " .. (settings.latency and "on" or "off") .. "\n")
    f:write("# ledger: auto_defense_ledger.txt, one line per hit: announced -> pressed -> result (on/off)\n")
    f:write("ledger = " .. (settings.ledger and "on" or "off") .. "\n")
    f:write("# min_gap_ms: two deflect presses are kept this far apart (a press while the last one is still\n")
    f:write("# down is no new press for the game: PBZAssist uses 90 ms; 40 ms left 31 of 192 perfects hit)\n")
    f:write(string.format("min_gap_ms = %.0f\n", (settings.minGap or 0) * 1000))
    f:write("# grab_lead_ms: a grab is dodged this long before its frame (PBZAssist 350: 100 ms late = grabbed)\n")
    f:write(string.format("grab_lead_ms = %.0f\n", (settings.grabLeadMs or 0) * 1000))
    f:write("# dodge_cd: do not press a dodge while the last one still runs; a parriable hit is deflected instead\n")
    f:write("dodge_cd = " .. (settings.dodgeCd and "on" or "off") .. "\n")
    f:write("# busy_skip: while the player is locked in his own move, wait instead of pressing into the buffer\n")
    f:write("busy_skip = " .. (settings.busySkip and "on" or "off") .. "\n")
    f:write("# flurry_guard: three listed hits within 0.25 s are taken behind a held guard, not one tap each\n")
    f:write("flurry_guard = " .. (settings.flurryGuard and "on" or "off") .. "\n")
    f:close()
end

-- ---------------------------------------------------------------- lookups
local obj, tag = Q.obj, Q.tag
local tagLibrary, component, ascOf, nowOf = Q.tagLibrary, Q.component, Q.ascOf, Q.nowOf

-- Handle of the nearest incoming hit landing within `window` seconds, or -1.
-- IsDodge true returns only the red hits (its handles never match the deflect
-- query's). The trailing OutFrame table is not passed: it never comes back
-- readable through UE4SS and the handle is only compared with >= 0, so the
-- query's own MaxPreimpactTime does the timing.
local function nearest(deflect, isDodge, window)
    local handle = deflect:GetNearestValidReceivedFrame(360.0, window, isDodge, -1)
    return tonumber(unwrap(handle)) or -1
end

-- ---------------------------------------------------------------- special attacks
-- Set by the attack log when an enemy starts an attack named in dodge_attacks:
-- its hit is dodged instead of parried.
local special = nil -- { untilT, what }
local dodged = {} -- hit handle -> os.clock() it was dodged (never parried too)
-- black flash: Attack_01_B, or the last hit of the Skill_04_Hard combo (~4 s
-- after it starts). Every hit while it is active is dodged, not only the first.
local SPECIAL_SECONDS = 6
local SPECIAL_TAIL = 1.5 -- after the marked ability ends: the black hit can come in the next one
-- set once enemies attack: the enemy ability scan (object walk) runs only then
local enemyScanWanted = false

local BLIND_LOOKBACK, BLIND_LEAD, BLIND_BURST = 4.0, 0.15, 0.6
local LEARN = false -- learn / use learned_dodges.txt (off: dodges into the guard failed)
local recentStart = nil -- { name, t } of the last enemy attack ability that started
local learned = {} -- ability name -> when to dodge (s after it starts)
local lastWarnClock, lastHitClock = 0, 0 -- os.clock() of the last announced hit / health drop
local timedDodge = nil -- { at, name } dodge scheduled from a learned delay
local lastBlindHit = 0

-- Timeline guard (test): hit_times.txt lists, per enemy ability, when its hits
-- start and how long they last (seconds after the ability starts), taken from
-- the game's own ability timelines. When an enemy near the player starts one,
-- the guard is raised just before each hit, whether the game announces it or not.

-- hit times: MOD_DIR .. "hit_times.txt" (inlined: one reader)
local TL_NEAR = 6000 -- cm: enemies farther away are ignored (lunges start 10+ m away, Scavenger Skill_07 42 m)
-- the timeline table and its count are owned by Scripts/ad_timeline.lua
local TL = dofile(MOD_DIR .. "Scripts/ad_timeline.lua")
local hitTimes = TL.table()
local tlQueue = {} -- { actor, name, t0, hits, m0, m } of attacks started near the player
-- timeline state shared with the loop (one table: the main chunk is at Lua's 200-locals limit)
-- info: "ability@montage position" of the newest queued attack, for the HIT log
-- tl.activationWorks: the activation hook has fired, no object walks needed
-- hitSoon: a queued attack has a hit due within redDefer s; an announced red hit is
-- then dodged by the timeline at that hit, not at the announcement (LengTu
-- Skill_11 announces 0.45 s early; the dodge at the announcement ran out)
-- redAt: os.clock() of the last announced red hit left to the timeline
local tl = { BLACK_LEAD = 0.5, GIVE_RELEASE = 0.6, BULLET_HOLD = 1.2, TORNADO_MOVE = 4.0, TORNADO_FAR = 700, keyDownAt = 0, info = "", activationWorks = false, hitSoon = false, redDefer = 0.6, redAt = -10, grabAt = -10,
    grabName = "", grabDone = -10, grabWindow = 2.5, grabDodgeAt = nil,
    -- dodges at fixed seconds after the start (hit minus the dodge lead), for
    -- attacks whose montage is replaced before the listed hit: MengHua CA_01
    -- (listed 5.29) hit at +6.68 and +6.69 real seconds in two fights; when
    -- that one is dodged an execution follows at +9.74 (test 1.3.2: -2476 from
    -- full health)
    -- HuaShan JianOu CriticalArt: its area hits the player from +4.7 to +6.5 s
    -- (2026-11-03, twice: 8x -225 each time), dodged through it
    realHits = { GA_MengHua_CA_01_C = { 6.55, 9.61 }, GA_HuaShan_JianOu_CriticalArt_C = { 4.45, 5.1, 5.45, 5.8, 6.15 } },
    -- attacks timed in real seconds, not by their montage position: JianOu
    -- CriticalArt's 10 s montage starts at 1.00 and jumps sections, its area
    -- dodge (listed 4.95) came at +2.07 real
    realClock = { GA_HuaShan_JianOu_CriticalArt = true },
    -- seconds from a grab's start to its frame: seeded from logs, learned from
    -- each frame seen (the late frame comes ~0.01 s before the grab lands, too
    -- late: test10e P2_GEx_01 dodged at the frame and still grabbed)
    -- 1.4.4 (PBZAssist defense.grab_lead_ms = 350, "100 ms late = grabbed"): the
    -- grab's own lead; 0.15 s was the frame-only value and too late for the dodge
    grabTimes = { GA_Scavenger_P2_GEx_01_C = 0.48 }, grabLead = settings.grabLeadMs or 0.24 }

-- 1.6.2: one error channel. Every hook install/callback failure lands here with a
-- traceback the first time it is seen, so a broken hook is visible with debug = off
-- (until 1.6.2 those three went to attackLog, which returns at once unless DEBUG).
do
    tl.VERSION = "1.6.8"
    tl.errs = {}
    function tl.err(what, err)
        local n = (tl.errs[what] or 0) + 1
        tl.errs[what] = n
        if n <= 3 then
            local msg = tostring(err)
            log("%s error: %s%s", what, msg, n == 1 and ("\n" .. tostring(debug.traceback("", 2))) or "")
        end
        if tl.emit then tl.emit("error", what, n, 0) end
    end
    -- 1.6.5 (audit P0-4): 27 call sites used a bare pcall and lost the reason a
    -- press, a hook or a query failed. tl.try keeps pcall's shape and reports the
    -- failure through the one channel above (first 3 per what, traceback on the first)
    function tl.try(what, fn, ...)
        local ok, a, b = pcall(fn, ...)
        if ok then return a, b end
        tl.err(what, a)
        return nil
    end
    -- 1.6.5 (audit P1-4): a RegisterHook id was thrown away, so a hook could never
    -- be removed. UE4SS hands back TWO ids per hook (pre and post), and the
    -- documented unregister form is UnregisterHook(path, preId, postId) - keeping
    -- only the first id leaves the post half installed (docs/UE4SS-LUA-API-REFERENCE.md
    -- §5.1, §8). Both ids and the path are kept per logical hook; nil is legal
    -- (nothing is documented about the return), it just cannot be removed later.
    -- Declared here, not with the other RT helpers: they run before "tl" exists.
    function RT.rememberHook(key, path, pre, post)
        local ids = tl.hookIds
        if not ids then ids = {} tl.hookIds = ids end
        if pre ~= nil or post ~= nil then
            ids[key] = { path = path, pre = pre, post = post }
        end
        return pre, post
    end
    -- the installed record is the only "is this hook in place" answer: a teardown
    -- deletes it, so a re-armed mod installs again instead of believing it is done
    function RT.installed(key)
        return tl.hookIds ~= nil and tl.hookIds[key] ~= nil
    end
    function RT.unhook(key)
        local ids = tl.hookIds
        local h = ids and ids[key]
        if h == nil then return false end
        -- one documented form: UnregisterHook(functionPath, preId, postId). It
        -- returns nothing, so pcall is the only success signal; a wrong signature
        -- throws here and the engine's own text is what makes that visible.
        local ok, e = pcall(UnregisterHook, h.path, h.pre, h.post)
        if not ok then
            -- the record stays: an id thrown away now can never be removed later
            tl.err("unhook " .. tostring(key), e)
            return false
        end
        ids[key] = nil
        return true
    end
    function RT.unhookAll()
        local ids = tl.hookIds
        if not ids then return 0 end
        local n = 0
        for key in pairs(ids) do if RT.unhook(key) then n = n + 1 end end
        return n
    end
end

-- 1.6.1: in-process, asynchronous, read-only observability bus + budgeted warm-up.
-- Nothing here touches the game API or a decision path: emit only writes a fixed
-- ring slot, drain delivers a bounded number per tick, and a subscriber that throws
-- is dropped instead of costing every tick. events = off makes emit a no-op.
do
    local function install()
        tl.DRAIN_N = 16
        local A = dofile(MOD_DIR .. "Scripts/ad_async.lua")
        tl.bus, tl.warm = A.events(512), A.warm()
        tl.emit = function(...)
            if not settings.events then return end
            local b = tl.bus
            if b then b.emit(...) end
        end
        local path, cap = MOD_DIR .. "ad_events.txt", 4000
        local f, lines, buf, flushAt = nil, 0, {}, os.clock()
        local function open()
            f, lines, buf = io.open(path, "w"), 0, {}
            if f then
                f:write(os.date("%H:%M:%S") .. " ad_events: read-only observability, cap " .. cap .. " lines\n")
                lines = 1
            end
        end
        local function flush()
            if not f or #buf == 0 then return end
            if lines >= cap then f:close() f = nil open() end
            if f then f:write(table.concat(buf)) f:flush() lines = lines + #buf end
            buf = {}
        end
        tl.eventsFlush = flush -- teardown flushes what is still buffered before it stops
        local realEmit = tl.emit
        -- teardown seals the sink, so a late callback cannot append a line after the
        -- last flush; re-opening is explicit, which lets a re-armed mod log again
        tl.eventsClose = function()
            if f then f:close() f = nil end
            tl.emit = function() end
        end
        tl.eventsOpen = function()
            tl.emit = realEmit
            if not f then open() end
        end
        -- the sink copies each event inside the callback: a ring slot is only
        -- valid there, so nothing retains it
        tl.bus.subscribe(function(e)
            if not f then open() if not f then return end end
            buf[#buf + 1] = string.format("%s %-14s %s %s %s\n", os.date("%H:%M:%S"),
                tostring(e.kind), tostring(e.a), tostring(e.b), tostring(e.c))
            if #buf >= 8 or os.clock() - flushAt > 2 then flushAt = os.clock() flush() end
        end)
        log("event bus ready: %d slots, cap %d lines", 512, cap)
    end
    local okI, errI = pcall(install)
    if not okI then
        log("event bus unavailable: %s", tostring(errI))
        tl.emit = function() end
    end
end

-- ---------------------------------------------------------------- game data (1.5.0)
-- ad_data.lua: PBZAssist's enemy_data / special_hazards cut down to the tables a
-- defence mod needs (tools/make_ad_data.lua, build in data/ad_data_meta.txt).
-- Optional: no file, a pcall failure, or "data = off" leaves 1.4.x untouched.
do
    local D = { ready = false, why = "not loaded" }
    local idx, M, mont, amt = {}, {}, {}, {}
    local function base(n) return RT.bname(n) end -- one rule, see RT.bname (audit P1-9)
    local function rec(n)
        local b = base(n)
        if not b then return nil end
        local r = idx[b]
        if not r then r = {} idx[b] = r end
        return r, b
    end
    local function mrec(n)
        local b = base(n)
        if not b then return nil end
        local r = M[b]
        if not r then r = {} M[b] = r end
        return r
    end
    local function segs(v)
        local out = {}
        if type(v) ~= "string" then return out end
        for seg in v:gmatch("[^,;]+") do
            local t = {}
            for f in seg:gmatch("[^:]+") do t[#t + 1] = tonumber(f) or f end
            if #t > 0 then out[#out + 1] = t end
        end
        return out
    end
    local function cnt(v)
        local n = 0
        if type(v) == "table" then for _ in pairs(v) do n = n + 1 end end
        return n
    end
    local function load()
        local okF, d = pcall(dofile, MOD_DIR .. "data\\ad_data.lua")
        if not (okF and type(d) == "table") then D.why = "no data file" return end
        local b = tonumber(d.build)
        D.build = b
        D.referenceNoFrame = type(d.reference_noframe) == "table" and d.reference_noframe or nil
        for k, v in pairs(d.montage or {}) do
            local mb, ab = base(k), base(v)
            if mb and ab then mont[mb] = ab amt[ab] = amt[ab] or mb end
        end
        for k, v in pairs(d.hit or {}) do
            local r = rec(k) local hits = {}
            for _, s in ipairs(segs(v)) do
                if type(s[1]) == "number" then
                    local kind = tostring(s[2] or "P")
                    hits[#hits + 1] = { s[1], 0.05, kind:sub(1, 1) == "D", false, false, t = kind }
                end
            end
            r.hit = hits
        end
        for k, v in pairs(d.dhit or {}) do
            local m = mrec(k) local hits = {}
            for _, s in ipairs(segs(v)) do
                if type(s[1]) == "number" then hits[#hits + 1] = { s[1], tonumber(s[3]) or 0.05, tostring(s[2] or "D") } end
            end
            m.dhit = hits
        end
        for k, v in pairs(d.mhit or {}) do
            local m = mrec(k) local hits = {}
            for _, s in ipairs(segs(v)) do
                if type(s[1]) == "number" then hits[#hits + 1] = { s[1], tonumber(s[3]) or 0.05, tostring(s[2] or "D") } end
            end
            m.mhit = hits
        end
        for k, v in pairs(d.grab or {}) do if v == true then rec(k).grab = true end end
        for k, v in pairs(d.parent or {}) do rec(k).parent = base(v) end
        for k, v in pairs(d.proj or {}) do
            local r = rec(k) local list = {}
            for _, s in ipairs(segs(v)) do
                local sp = tostring(s[6] or ""):match("^([%d%.]+)")
                list[#list + 1] = { t = tonumber(s[1]), speed = tonumber(sp) }
            end
            r.proj = list
        end
        for k, v in pairs(d.bfx or {}) do
            local r = rec(k) local list = {}
            if type(v) == "string" then
                for seg in v:gmatch("[^,;]+") do
                    local kind, a, b2 = seg:match("^(%a+):([%d%.]+):?([%d%.]*)")
                    if kind then list[#list + 1] = { kind = kind, a = tonumber(a), b = tonumber(b2) } end
                end
            end
            if #list > 0 then r.bfx = list end
        end
        for k, v in pairs(d.winv or {}) do
            local r = rec(k) local list = {}
            for _, s in ipairs(segs(v)) do
                if type(s[1]) == "number" and type(s[2]) == "number" then
                    list[#list + 1] = { s[1], s[2], tostring(s[3] or "") }
                end
            end
            if #list > 0 then r.winv = list end
        end
        for k, v in pairs(d.multi or {}) do if tonumber(v) then rec(k).multi = tonumber(v) end end
        for k, v in pairs(d.ns or {}) do
            local r = rec(k) local list = {}
            for _, s in ipairs(segs(v)) do if type(s[1]) == "number" then list[#list + 1] = s[1] end end
            if #list > 0 then r.ns = list end
        end
        for k, v in pairs(d.ts0 or {}) do if tonumber(v) then rec(k).ts0 = tonumber(v) end end
        for k, v in pairs(d.zone_r or {}) do
            local rad = tonumber(v)
            if rad then
                local r = rec(k)
                r.zone = rad
                if not r.blast or rad > r.blast then r.blast = rad end
            end
        end
        -- a bullet class is named after its ability (BD_<Ability>_..._<n>): fold the
        -- blast radius onto that ability, which is what the timeline knows
        local function foldBullet(k, rad)
            if not rad then return end
            local x = k:gsub("^BD_", ""):gsub("_Overlap$", ""):gsub("_%d+$", "")
            local y = x:gsub("_%a+$", "")
            local tries = { x, "GA_" .. x }
            if y ~= x then tries[#tries + 1] = y tries[#tries + 1] = "GA_" .. y end
            for _, t in ipairs(tries) do
                local r = idx[t]
                if r then
                    if not r.blast or rad > r.blast then r.blast = rad end
                    return
                end
            end
        end
        for k, r in pairs(idx) do
            for _, e in ipairs(r.bfx or {}) do
                foldBullet(k, (e.kind == "b" and e.b) or e.a)
            end
        end
        for k, v in pairs(d.dreach or {}) do
            local s = segs(v)[1]
            if s and type(s[1]) == "number" and type(s[2]) == "number" then mrec(k).reach = s[2] end
        end
        for k, v in pairs(d.hit_aim or {}) do
            local s = segs(v)[1]
            if s and type(s[2]) == "number" then mrec(k).aim = s[2] end
        end
        for k, v in pairs(d.stun or {}) do if tonumber(v) then mrec(k).stun = tonumber(v) end end
        for k, v in pairs(d.mhit_req or {}) do if type(v) == "string" then mrec(k).req = v end end
        for k, v in pairs(d.mspd or {}) do
            local lo, hi = nil, nil
            for _, mult in tostring(v):gmatch("(%d+)=([%d%.]+)") do
                local x = tonumber(mult)
                if x then lo = math.min(lo or x, x) hi = math.max(hi or x, x) end
            end
            if lo and hi and hi > 0 then mrec(k).spdLo, mrec(k).spdHi = lo / hi, hi end
        end
        for k, v in pairs(d.precise_defense or {}) do
            if type(v) == "table" then
                local r = rec(k)
                r.precise = cnt(v.byBullet)
                if tonumber(v.reach) then r.preciseReach = tonumber(v.reach) end
            end
        end
        D.ready = true
        D.why = "ok"
        D.count = cnt(idx)
    end
    -- record of an ability, following parent links (subclasses have no row)
    local function R(name)
        local b = base(name)
        if not b then return nil end
        local r = idx[b]
        -- enemy_data writes the class as GA_X_C and UE adds another _C: an ability
        -- the game names GA_X_C is stored under GA_X_C, the timeline says GA_X
        if not r then local b2 = b .. "_C" if idx[b2] then r = idx[b2] b = b2 end end
        if not r then
            local b2 = b:gsub("_C$", "")
            if b2 ~= b then r = idx[b2] end
            if r then b = b2 end
        end
        local hop = 0
        while r and r.parent and hop < 3 do
            hop = hop + 1
            local p = idx[r.parent]
            if not p then break end
            r = p
        end
        return r or nil, b
    end
    D.R = R
    D.base = base
    D.rec = function(n) return (R(n)) end
    D.abilityOf = function(m) local b = base(m) return b and mont[b] or nil end
    D.montageOf = function(a) local b = base(a) return b and amt[b] or nil end
    -- true = a grab, false = the data knows this ability and it is not one, nil = unknown
    D.isGrab = function(n) local r = R(n) if not r then return nil end return r.grab == true end
    D.reach = function(n)
        local b = base(n)
        if not b then return nil end
        -- a montage key answers directly; an ability key goes through its montage
        local mr = M[b] or M[b .. "_C"] or M[b:gsub("_C$", "")]
        if mr and mr.reach then return mr.reach end
        local r = idx[b]
        if r and r.preciseReach then return r.preciseReach end
        local m = amt[b] or amt[b:gsub("_C$", "")]
        mr = m and (M[m] or M[m .. "_C"])
        if mr and mr.reach then return mr.reach end
        -- no montage link for this ability: its montage is usually the same name
        local bare = b:gsub("^GA_", "")
        mr = M[bare .. "_Montage"] or M[bare]
        if mr and mr.reach then return mr.reach end
        return nil
    end
    D.multi = function(n) local r = R(n) return r and r.multi or nil end
    D.ns = function(n) local r = R(n) return r and r.ns or nil end
    D.ts0 = function(n) local r = R(n) return r and r.ts0 or nil end
    D.precise = function(n) local r = R(n) return r and r.precise or nil end
    D.radius = function(n)
        local r = R(n)
        if not r then return nil end
        local rad = r.zone or r.blast
        for _, e in ipairs(r.bfx or {}) do
            local v = e.a
            if e.kind == "z" or e.kind == "c" or e.kind == "m" then
                if v and (not rad or v > rad) then rad = v end
            elseif e.kind == "b" and e.b and (not rad or e.b > rad) then
                rad = e.b
            end
        end
        return rad
    end
    D.speedVar = function(n)
        local b = base(n)
        local m = b and amt[b]
        local mr = m and M[m]
        if mr and mr.spdHi then return mr.spdLo or 1, mr.spdHi end
        return nil
    end
    D.stunOf = function(m)
        local b = base(m)
        local mr = b and M[b]
        return mr and mr.stun or nil
    end
    D.reqTag = function(m)
        local b = base(m)
        local mr = b and M[b]
        return mr and mr.req or nil
    end
    D.winv = function(n)
        local r = R(n)
        return r and r.winv or nil
    end
    -- the player's own move right now, if the data says it is invulnerable
    D.invuln = function(pawn)
        if not D.ready then return false end
        local st = tl.montageState and tl.montageState(pawn)
        local ab = st and st.name and (mont[base(st.name)])
        if not ab then return false end
        local w = D.winv(ab)
        if not w then return false end
        local pos = st.pos or 0
        for _, seg in ipairs(w) do
            if pos >= seg[1] and pos <= seg[2] then return true, seg[3] end
        end
        return false
    end
    -- hits for abilities hit_times.txt has no row for (the game's own timelines)
    -- put(b, hits) writes into the timeline store; the store then owns the count
    -- (audit P0-4: this used to write the table itself and the caller patched n)
    D.addMissingHits = function(put)
        if not D.ready then return 0 end
        local added = 0
        for b, r in pairs(idx) do
            if r.hit and #r.hit > 0 then
                local hits = {}
                for i, h in ipairs(r.hit) do
                    hits[i] = { h[1], h[2], h[3] == true, false, false, t = h[3] and "0" or "1" }
                end
                if put(b, hits) then added = added + 1 end
            end
        end
        return added
    end
    if settings.data then
        D.t0 = os.clock()
        local okL, errL = pcall(load)
        if not okL then D.why = "load failed: " .. tostring(errL) end
    end
    tl.dat = D
    if D.ready then
        log("data: build %s, %d abilities (%s), read in %.1f ms", tostring(D.build), D.count or 0, D.why,
            (os.clock() - (D.t0 or os.clock())) * 1000)
    else
        log("data: not used (%s)", D.why)
    end
end
-- AutoPerfectDefense 1.1.4 supplied three semantic no-frame timing facts. They
-- stay in a pure, actor-qualified overlay: the PBZAssist snapshot and global
-- hitTimes remain authoritative and unmodified. record is the shipped mode.
do
    local raw = settings.data and tl.dat and tl.dat.ready and tl.dat.referenceNoFrame or nil
    if raw then
        local okM, mod = pcall(dofile, MOD_DIR .. "Scripts/ad_seed.lua")
        local okS, seed = false, mod
        if okM and type(mod) == "table" and type(mod.new) == "function" then
            okS, seed = pcall(mod.new, raw)
        end
        if okS and type(seed) == "table" then
            tl.seed = seed
            log("reference seeds: %d ready, %d rejected (%s, mode %s)", seed.valid or 0, seed.invalid or 0,
                tostring(raw.source or "unknown"), settings.seedFallback)
        else
            log("reference seeds: not used (%s)", tostring(okM and seed or mod))
        end
    end
end
tl.seedRows = function(ability, actorClass, distance, existing)
    if settings.seedFallback == "off" or not settings.data or not tl.seed then return existing or {}, 0, {} end
    local merged, added, candidates = tl.seed:merge(ability, actorClass, distance, existing)
    if settings.seedFallback == "on" then return merged, added, candidates end
    return existing or {}, added, candidates -- record observes, but cannot activate a row
end
-- 1.6.7: the counter layer. ad_weapon reads the game (injected readers only) and
-- ad_counter holds the timing; main.lua presses. Installed once, and a module
-- that does not load leaves both features off without touching the key chain.
tl.installCounter = function()
    if tl.weapon or tl.weaponErr then return tl.weapon, tl.counter end
    local okW, weaponMod = pcall(dofile, MOD_DIR .. "Scripts/ad_weapon.lua")
    local okC, counterMod = pcall(dofile, MOD_DIR .. "Scripts/ad_counter.lua")
    if not (okW and type(weaponMod) == "table" and type(weaponMod.new) == "function") then
        tl.weaponErr = okW and "ad_weapon.lua returned no module" or weaponMod
        log("counter: the weapon reader is not used (%s)", tostring(tl.weaponErr))
        return nil, nil
    end
    if not (okC and type(counterMod) == "table" and type(counterMod.new) == "function") then
        tl.counterErr = okC and "ad_counter.lua returned no module" or counterMod
        log("counter: the timing module is not used (%s)", tostring(tl.counterErr))
        return nil, nil
    end
    local okI, weapon, counter = pcall(function()
        local w = weaponMod.new{
            name = "DualHook",
            range = tonumber(settings.shieldCounterRange) or 1500,
            log = log,
            -- Sha-chi as a share of its maximum: tl.shachiShare is the one reader
            -- (tickShachi already uses it), handed to the module as 0-100 so the
            -- menu percentage compares directly
            vitals = function()
                if not tl.shachiShare then return nil end
                local ok, share = pcall(tl.shachiShare)
                if not (ok and tonumber(share)) then return nil end
                return { shachi = share * 100, max = 100 }
            end,
            weapon = function() return tl.weaponNow() end,
            enemies = function() return tl.attackersNow() end,
        }
        return w, counterMod.new{ log = log }
    end)
    if not okI then
        tl.weaponErr = weapon
        log("counter: not installed (%s)", tostring(tl.weaponErr))
        return nil, nil
    end
    tl.weapon, tl.counter = weapon, counter
    log("counter: ready (hook %s, Sha-chi %s%%, blue shield %s within %s cm)", tostring(settings.hookCounter),
        tostring(settings.hookCounterShachi), tostring(settings.shieldCounter), tostring(settings.shieldCounterRange))
    return weapon, counter
end
-- a grab (GA_*_GEx*: grab, then the execution) cannot be parried; its frame
-- comes tl.grabWindow at most after the start and is dodged (test10d: Scavenger
-- P2_GEx_01, frame 0.48 s after the start, guard held, executed)
local currentPawn -- set by the loop

-- ---------------------------------------------------------------- ledger
-- 1.4.3: one line per hit with the decision and how it ended, on by default
-- (auto_defense_ledger.txt). attacks_log.txt (debug = on) keeps the deep detail;
-- this is the counter an A/B needs: announced -> pressed -> confirmed -> result,
-- and why a hit was not pressed (PBZAssist 的 combat.log / Rec() 思路).
-- In a block on purpose: the main chunk is at Lua's 200-locals limit.
do
    local FILE, MAXLINES, FLUSH_EVERY = MOD_DIR .. "auto_defense_ledger.txt", 6000, 2.0
    local buf, at, count, started = {}, os.clock(), 0, false
    local function flush()
        local n = #buf
        if n == 0 then return end
        local f = io.open(FILE, "a")
        if f then f:write(table.concat(buf)) f:close() end
        for i = n, 1, -1 do buf[i] = nil end
        at = os.clock()
    end
    tl.led = function(fmt, ...)
        if settings.ledger == false then return end
        if not started then -- the file starts empty each session (attacks_log.txt keeps the last)
            started = true
            local f = io.open(FILE, "w")
            if f then f:close() end
        end
        count = count + 1
        if count == MAXLINES then -- a silent stop made an A/B look complete (audit P1-6)
            buf[#buf + 1] = string.format("%s [%7.2f] TRUNCATED at %d lines; restart to continue\n", os.date("%H:%M:%S"), os.clock(), MAXLINES)
            flush()
            return
        end
        if count > MAXLINES then return end
        buf[#buf + 1] = string.format("%s [%7.2f] %s\n", os.date("%H:%M:%S"), os.clock(), string.format(fmt, ...))
        -- the session line and a lone hit go out at once; the rest in batches
        if count <= 1 or #buf >= 8 or os.clock() - at >= FLUSH_EVERY then flush() end
    end
    tl.ledFlush = flush -- a state change that matters (PBZPerfectDefense taking the guard) goes out at once
    -- 1.6.5 (audit P1-8): the invulnerable-player notice fired every tick of every
    -- invulnerable frame inside a 6000-line budget; a key writes once a session
    local seen = {}
    tl.ledOnce = function(key, fmt, ...)
        if seen[key] then return false end
        seen[key] = true
        tl.led(fmt, ...)
        return true
    end
    tl.led("session: v%s read_frames=%s parry_lead=%s dodge_lead=%.0fms dodge_gap=%.0fms pair_frames=%s receipt=%s%s",
        tl.VERSION, settings.readFrames and "on" or "off", tostring(settings.parryLeadCfg), (settings.dodgeLead or 0) * 1000,
        (settings.dodgeGap or 0) * 1000, settings.pairFrames and "on" or "off", settings.receipt and "on" or "off",
        settings.receiptRetry and " retry=on" or "")
end

-- ---------------------------------------------------------------- PBZPerfectDefense (1.5.1)
-- PBZPerfectDefense 1.8.0 (ProjectPBZ/Content/JavaScript/PBZModsMenu/Mods/
-- PBZPerfectDefense/main.js, the same settings in Paks/~mods/PBZPerfectDefense.txt)
-- added AutoGuard: on a blockable attack's own frame it presses and holds the
-- guard itself. Two mods driving the same guard key fight over it: a press
-- inside the game's quick-click window (RepeatGuard, 0.4 s stock) is no new
-- press, and one mod's release undoes the other's hold. So while AutoGuard is
-- on this mod stops guarding (no tap, no flurry hold, no perfect tag, no guard
-- release of its own); red attacks, grabs, unannounced hits and the dodge stay
-- here, blue hits and bullet deflections are that mod's. The file is re-read
-- every 2 s, so a change in the mods menu needs no restart.
do
    local MENU_REL = "ProjectPBZ\\Content\\JavaScript\\PBZModsMenu\\"
    local CFG_REL = "ProjectPBZ\\Content\\Paks\\~mods\\PBZPerfectDefense.txt"
    local PD = { found = nil, autoGuard = false, deflect = "", dodge = "", repeatGuard = "",
        slow = false, root = nil, cfg = nil, nextAt = 0, state = "" }
    PD.ownsGuard = function()
        if settings.pbzpd == "off" then return false end
        if settings.pbzpd == "yield" then return PD.found == true end
        return PD.found == true and PD.autoGuard == true
    end
    PD.describe = function()
        local d = PD.deflect ~= "" and PD.deflect or "?"
        local g = PD.dodge ~= "" and PD.dodge or "?"
        if not PD.cfg or PD.found == nil then
            return "PBZPerfectDefense: not installed, this mod guards as usual"
        end
        if PD.found == false then return "PBZPerfectDefense: off in the mods menu, this mod guards as usual" end
        if PD.ownsGuard() then
            return string.format("PBZPerfectDefense takes the guard (AutoGuard=%s, Deflect=%s, Dodge=%s%s): red attacks, grabs and the dodge stay here, unannounced hits are left unguarded",
                PD.autoGuard and "on" or "off", d, g, PD.slow and ", slow motion on" or "")
        end
        return string.format("PBZPerfectDefense found (AutoGuard=%s, Deflect=%s): this mod keeps guarding (pbzpd=%s)",
            PD.autoGuard and "on" or "off", d, settings.pbzpd or "auto")
    end
    local function readCfg(path)
        local f = io.open(path, "r")
        if not f then return false end
        local text = f:read("*a") or ""
        f:close()
        -- the file changes only when the player edits it (audit P2-11)
        if text == PD.cfgText then return true end
        PD.cfgText = text
        PD.autoGuard, PD.deflect, PD.dodge, PD.repeatGuard, PD.slow = false, "", "", "", false
        for line in text:gmatch("[^\r\n]+") do
            local k, v = line:match("^%s*([%w_]+)%s*=%s*([%w%._%-]+)")
            if k then
                k = k:upper()
                local low = v:lower()
                if k == "AUTOGUARD" then PD.autoGuard = low ~= "off" and low ~= "false" and low ~= "no"
                elseif k == "DEFLECT" then PD.deflect = v
                elseif k == "DODGE" then PD.dodge = v
                elseif k == "REPEATGUARD" then PD.repeatGuard = v
                elseif k == "SLOWBLUE" or k == "SLOWRED" or k == "SLOWBLACK" or k == "SLOWPROJECTILE" then
                    if low ~= "off" and low ~= "false" and low ~= "no" then PD.slow = true end
                end
            end
        end
        return true
    end
    -- the mods menu lists every entry of the loader with its enabled flag; no list
    -- at all (an older menu) means the settings file decides on its own
    local function modEnabled(root)
        local f = io.open(root .. MENU_REL .. "discovered.txt", "r")
        if not f then return nil end
        local text = f:read("*a") or ""
        f:close()
        local at = text:find('"id":"PBZPerfectDefense"', 1, true)
        if not at then return false end
        -- search to the end of this entry's object: a fixed 400-character window
        -- missed a flag that sits further in (audit P2-3)
        local stop = text:find("}", at, true) or #text
        return text:sub(at, stop):find('"enabled":true', 1, true) ~= nil
    end
    PD.refresh = function()
        if settings.pbzpd == "off" then
            PD.found, PD.root, PD.cfg, PD.state = nil, nil, nil, "off"
            return false
        end
        if not PD.cfg then
            -- MOD_DIR is <game>\PBZ\platform\steam\ue4ss\Mods\pbz-auto-defense\, so
            -- the game root is five directories up; a repack may sit deeper: try 4..7
            for n = 4, 7 do
                local root = MOD_DIR .. string.rep("..\\", n)
                local f = io.open(root .. CFG_REL, "r")
                if f then f:close() PD.root, PD.cfg = root, root .. CFG_REL break end
            end
        end
        if not PD.cfg then
            PD.found = false
            if PD.state ~= "no file" then
                PD.state = "no file"
                log("%s", PD.describe())
            end
            return false
        end
        readCfg(PD.cfg)
        local en = modEnabled(PD.root)
        PD.found = en == nil and true or en
        local st = PD.describe()
        if st ~= PD.state then
            PD.state = st
            log("%s", st)
            tl.led("%s", st)
            if tl.ledFlush then pcall(tl.ledFlush) end
        end
        return true
    end
    PD.tick = function()
        local now = os.clock()
        if now < PD.nextAt then return end
        PD.nextAt = now + 2
        tl.try("PD refresh", PD.refresh)
    end
    tl.guardOwned = function() return PD.ownsGuard() end
    tl.pd = PD
    tl.try("PD refresh", PD.refresh)
    if settings.pbzpd == "off" then log("pbzpd: off, this mod guards as it always did") end
end

do
    -- ---------------------------------------------------------------- read-ahead
    -- 1.4.3, from PBZAssist (its Frames table and timing.* settings). The queries
    -- above only answer "is a hit within N seconds". The component also keeps every
    -- incoming hit with its own hit time and type (ReceiveFrames, what the debug
    -- probe below reads), so it is read once per tick into tl.FX[handle] and the
    -- presses are timed to the hit itself:
    --   parry    - press 45 % of the game's perfect window before the hit (PBZAssist
    --              measured 0.2667 s), not in its last PARRY_WINDOW seconds;
    --   dodge    - press dodge_lead_ms before the hit, and leave a hit that lands
    --              inside the previous dodge's i-frames to that dodge;
    --   timeline - a listed hit the game announces too is pressed once (pairing);
    --   receipt  - Last Deflect Click says whether the game saw the press at all.
    -- read_frames = off: the queries alone (the 1.4.2 behaviour).
    local FX, FX_SEEN, fxTicks = {}, {}, 0
    local function rawName(o) return o:GetFName():ToString() end
    local function fxName(o)
        if not valid(o) then return nil end
        local ok, n = pcall(rawName, o)
        return ok and n or nil
    end
    -- This pass runs every frame, so its tables and closures are kept (1.4.3: the
    -- debug probe below builds them per tick, but it only runs with debug = on)
    local fxPresent, fxDeflect, fxCur, fxRun = {}, nil, nil, nil
    local function fxOne(key, value)
        local h = tonumber(unwrap(key:get()))
        if not h then return end
        fxPresent[h] = true
        local data = value:get()
        local e = FX[h]
        if not e then
            e = {}
            FX[h] = e
            local okd, isDodge = pcall(RT.isDodgeOf, data)
            if okd then e.dodge = isDodge == true end
            local oks, src = pcall(RT.sourceOf, data)
            if oks and valid(src) then
                local okb, bt = pcall(RT.bulletOf, src)
                if okb then e.type = bt end
                local okc, cls = pcall(RT.classOf, src)
                if okc then e.src = fxName(cls) end
            end
        end
        -- the hit time can be set a tick late, and a reused handle starts a new hit
        local okh, hit = pcall(RT.hitTimeOf, data)
        if okh and hit and (not e.hit or math.abs(e.hit - hit) > 0.02) then e.hit = hit end
        FX_SEEN[h] = fxTicks
    end
    fxRun = function() fxCur.ReceiveFrames:ForEach(fxOne) end
    -- Reads the frames of the player's Deflect Component: the source ability and
    -- the type once per hit, the hit time while it changes.
    local function fxScan(deflect, _gameNow)
        if not settings.readFrames or not valid(deflect) then return end
        -- a new Deflect Component (death, map change) counts its handles from 0 again
        local addr = deflect:GetAddress()
        if fxDeflect ~= addr then
            if fxDeflect then tl.fxClear() end
            fxDeflect = addr
        end
        fxTicks = fxTicks + 1
        for h in pairs(fxPresent) do fxPresent[h] = nil end
        fxCur = deflect
        if not pcall(fxRun) then return end
        for h, at in pairs(FX_SEEN) do
            if not fxPresent[h] and fxTicks - at > 2 then FX[h], FX_SEEN[h] = nil, nil end
        end
    end
    tl.fxScan = fxScan
    tl.fxClear = function()
        for h in pairs(FX) do FX[h] = nil end
        for h in pairs(FX_SEEN) do FX_SEEN[h] = nil end
        fxDeflect = nil
    end
    -- seconds until the hit of a handle, nil when the game did not set its time (or
    -- it is stale: a reused handle keeps the old number for a tick)
    tl.fxDue = function(h, gameNow)
        local e = FX[h]
        if not e or not e.hit or not gameNow then return nil end
        local due = e.hit - gameNow
        if due < -0.5 or due > 5 then return nil end
        return due
    end
    tl.fxType = function(h)
        local e = FX[h]
        return e and e.type or nil
    end

    -- The game's perfect window: Perfect Window - Last Deflect Click on the deflect
    -- passive, read right after a press (PBZAssist: 0.2667 s). A press less than
    -- ~0.6 s after the last one gets a shortened window (the chain-press punishment,
    -- 0.2667 -> ~0.08 s), so the two cases are learned apart (PBZAssist WinLearn
    -- bins them by the time since the last press; one median mixed them up)
    local parryW, parryWs, parryShort, parryShorts = 0.2667, {}, 0.09, {}
    tl.parryW = function() return parryW end
    tl.parryWShort = function() return parryShort end
    local function median(t)
        local n = #t
        if n == 0 then return nil end
        local c = {}
        for i = 1, n do c[i] = t[i] end
        table.sort(c)
        return c[math.floor((n + 1) / 2)]
    end
    tl.noteWindow = function(pawn)
        local ps = tl.passiveOf and valid(pawn) and tl.passiveOf(pawn)
        if not ps then return end
        local okw, w = pcall(function() return tonumber(unwrap(ps["Perfect Window"])) end)
        local okl, l = pcall(function() return tonumber(unwrap(ps["Last Deflect Click"])) end)
        if not (okw and w and okl and l) then return end
        local W = w - l
        if W <= 0.02 or W >= 0.6 then return end
        if (tl.sincePress or 9) < 0.6 then
            parryShorts[#parryShorts % 10 + 1] = W
            parryShort = median(parryShorts) or parryShort
        else
            parryWs[#parryWs % 12 + 1] = W
            parryW = median(parryWs) or parryW
        end
    end
    -- input delay the game took to see a press (median, clamped to 0..0.1 s)
    local lats, latency = {}, 0
    tl.latency = function() return latency end
    tl.noteLatency = function(d)
        if not settings.latency or type(d) ~= "number" then return end
        lats[#lats % 15 + 1] = d
        latency = math.max(0, math.min(0.1, median(lats) or 0))
    end
    -- the parry lead: parry_lead = auto | seconds. A press that the game sees late by
    -- latency opens the window late as well, so only half of it is taken off.
    tl.parryLead = function()
        local cfg = settings.parryLeadCfg
        local lead
        if type(cfg) == "number" then
            lead = cfg
        elseif os.clock() - (tl.lastTapClock or -100) < 0.6 then
            -- the next press comes less than 0.6 s after the last one: the game will
            -- shorten the window, so a 0.12 s lead would open it too early
            lead = math.max(0.05, math.min(0.10, 0.45 * parryShort))
        else
            -- 45 % of the window (PBZAssist DeflectLead), never below the ~60 ms the
            -- press itself needs to be seen
            lead = math.max(0.06, math.min(0.20, 0.45 * parryW))
        end
        if settings.latency and latency > 0 then lead = math.max(0.05, lead - latency * 0.5) end
        return lead
    end
    tl.dodgeLead = function() return math.max(0.04, settings.dodgeLead or 0.08) end
    -- A dodge does not come out while the last one plays (log: "dodge did not come
    -- out"), but a hit landing inside that dodge's i-frames is already avoided, so
    -- it is left to it instead of a second press (PBZAssist timing.dodge_gap_ms 220)
    tl.dodgeCovered = function(now, due)
        local gap = settings.dodgeGap or 0
        if gap <= 0 or not tl.lastDodgePress or not due then return false end
        -- a dodge that did not come out has no i-frames (the 1.4.2 log has
        -- "dodge did not come out" 49 times): never leave a hit to one
        if (tl.dodgeFailAt or 0) > tl.lastDodgePress then return false end
        local since = now - tl.lastDodgePress
        if since <= 0 or since >= gap then return false end
        -- the i-frames start 0.04 s after the press (AutoPerfectDefense 1.0.8), and
        -- the game sees the press `latency` late
        local iframe = settings.dodgeIframe or 0.26
        return since + due >= 0.04 + (settings.latency and latency or 0) and since + due <= iframe
    end
    -- timeline pairing: the game announces these hits too, so the frame handler
    -- presses at the hit and the listed tap would be a second press (a press inside
    -- TAP_GAP of the last one just keeps the key down: 1.4.1, 31 of 192)
    tl.pairTimeline = function(name, due, gameNow)
        if not settings.pairFrames or not settings.readFrames or not name or not due or not gameNow then return false end
        local base = RT.bname(name) or name
        for _, e in pairs(FX) do
            if e.hit and e.src then
                local src = RT.bname(e.src) or e.src
                if src == base or src:find(base, 1, true) then
                    local d = e.hit - gameNow
                    if d > -0.05 and math.abs(d - due) <= 0.25 then return true end
                end
            end
        end
        return false
    end
    -- press receipt: the game's own count of presses moved = it saw this one
    tl.receipt0 = function(pawn)
        local ps = tl.passiveOf and valid(pawn) and tl.passiveOf(pawn)
        if not ps then return nil end
        local okl, l = pcall(function() return tonumber(unwrap(ps["Last Deflect Click"])) end)
        return okl and l or nil
    end
    -- the player is locked in his own move (attack / dodge / dash / being hit): a
    -- press now goes into the game's input buffer and is played when the move can
    -- be cancelled, not at the time it was needed (PBZAssist InActionLock /
    -- BarrageBusy). The raised guard is not a lock: parrying out of it is normal.
    local BUSY_PATTERNS = { "Attack", "Dash", "Dodge", "_Hit_" }
    tl.playerBusy = function(pawn)
        if not valid(pawn) then return false end
        local st = tl.montageState and tl.montageState(pawn)
        local n = st and st.name
        if not n then return false end
        for _, pat in ipairs(BUSY_PATTERNS) do
            if n:find(pat, 1, true) then return true end
        end
        return false
    end
    -- the last dodge is still running: the game drops a second press (PBZAssist
    -- 1.3.3 C1 reads the dodge cooldown; the dodge itself takes about 0.35 s)
    tl.DODGE_LOCK = 0.35
    tl.dodgeReady = function(now)
        if not settings.dodgeCd or not tl.lastDodgePress then return true end
        -- a dodge that never came out has no cooldown and no i-frames
        if (tl.dodgeFailAt or 0) > tl.lastDodgePress then return true end
        if (tl.stunUntil or -10) > now then return true end    -- 1.5.0: wake dodge out of hitstun
        return now - tl.lastDodgePress >= tl.DODGE_LOCK
    end
    tl.tickReceipt = function(pawn)
        local r = tl.receipt
        if not r then return end
        if os.clock() - r.at < 0.03 then return end
        tl.receipt = nil
        local ps = tl.passiveOf and valid(pawn) and tl.passiveOf(pawn)
        -- two signals (PBZAssist BarrageCheck): the game's press counter moved, or
        -- the passive took the key down by itself (Stance Key Down)
        local skd = false
        if ps then
            local okS, kd = pcall(function() return unwrap(ps["Stance Key Down"]) end)
            skd = okS and kd == true
        end
        local l = tl.receipt0(pawn)
        local moved = (l and r.click0) and (l - r.click0) or 0
        if skd or moved > 0.0005 then
            if moved > 0.0005 and l then
                local lat = l - r.game
                if lat >= -0.02 and lat <= 0.3 then tl.noteLatency(lat) end
            end
            tl.led("receipt h=%d: seen (%s, latency %.0fms, window %.3f/%.3f s, lead %.0fms)", r.h,
                moved > 0.0005 and string.format("+%.3f s", moved) or "key down", latency * 1000, parryW,
                parryShort, tl.parryLead() * 1000)
            return
        end
        tl.recMiss = (tl.recMiss or 0) + 1
        local busy = tl.playerBusy(pawn)
        tl.led("receipt h=%d: NOT seen%s (#%d of %d presses)", r.h,
            busy and ", the player is locked in his own move (press went into the input buffer)" or "",
            tl.recMiss, (tl.recSeen or 0) + tl.recMiss)
        if settings.receiptRetry and os.clock() - (tl.retryAt or 0) > 0.25 and tl.pressTap then
            tl.retryAt = os.clock()
            if busy and tl.releaseHeldKey then pcall(tl.releaseHeldKey) end
            tl.led("receipt h=%d: pressing again", r.h)
            tl.try("pressTap", tl.pressTap, r.h, r.game)
        end
    end
end

do
    local f = io.open(MOD_DIR .. "hit_times.txt", "r")
    if f then
        for raw in f:lines() do
            local k, v = raw:match("^%s*([%w_]+)%s*=%s*(.+)$")
            if k then
                local hits = {}
                -- start:duration[:type]; type 0 hits (parry often failed) and type 3
                -- (red: LengTu Skill_06 / Skill_11, sometimes not announced) are dodged
                for s, d, t in v:gmatch("([%d%.]+):([%d%.]+):?(%d*)") do
                    -- { start, duration, dodged, area, flying }
                    hits[#hits + 1] = { tonumber(s), tonumber(d), t == "0" or t == "3" or t == "5" or t == "6", t == "5",
                        t == "6", t = t }
                end
                -- YanQianSui lists every hit twice, type 0 (dodge) and type 1 (parry)
                -- at the same time: its attacks come red (cannot be parried) or blue
                -- (parried, and that breaks the Sha-chi that keeps it immune), picked
                -- in game. It was always dodged, so it was never parried. Now _Red
                -- is dodged, _Blue and the plain ones are parried; the game announces
                -- a red one and that tap then turns into a dodge ("announced red").
                local paired = false
                for _, a in ipairs(hits) do
                    for _, b in ipairs(hits) do
                        if a.t == "0" and b.t == "1" and math.abs(a[1] - b[1]) <= 0.05 then
                            a.pair, b.pair, paired = true, true, true
                        end
                    end
                end
                if paired then
                    local red, kept = k:find("_Red$") ~= nil, {}
                    for _, h in ipairs(hits) do
                        if not h.pair or (h[3] == red) then kept[#kept + 1] = h end
                    end
                    hits, tl.colorPairs = kept, (tl.colorPairs or 0) + 1
                end
                -- an ability named _Red or _OnlyDodge cannot be parried, whatever
                -- its hit type (2026-11-03: HuaShan SpecialAttack_05_Red's
                -- BP_HuaShan_Red_Wave came with IsDodge false, parried, -297 twice)
                if not paired and (k:find("_Red$") or k:find("_OnlyDodge$")) then
                    for _, h in ipairs(hits) do
                        if h.t ~= "4" and h.t ~= "5" and h.t ~= "6" then h[3] = true end
                    end
                end
                -- 12 of the 2,507 shipped keys still carried "_C" and were
                -- unreachable from every lookup, which all strip it (audit P1-9)
                if #hits > 0 then TL.put(RT.bname(k) or k, hits) end
            end
        end
        f:close()
    end
    -- 1.5.0: abilities the game data lists and hit_times.txt has no row for
    if settings.data and tl.dat and tl.dat.ready then
        local added = tl.dat.addMissingHits(function(b, hits)
            if hitTimes[b] then return false end
            TL.put(b, hits)
            return true
        end)
        if added > 0 then log("data: hit times taken from the game data for %d more abilities", added) end
    end
end
-- ---------------------------------------------------------------- learned hits (1.4.2)
-- learned_hits.txt, written by the mod (delete a line, or the file, to forget):
--   add GA_X = start:duration:type   a hit hit_times.txt does not list (A)
--   set GA_X@start = type            a listed hit handled another way (B)
--   fail GA_X@start = n              hits taken through that hit's handling
-- A: a hit (> LEARN_MIN HP) at montage position t of a nearby attack with no
--    listed hit there is learned as a dodge at t; LEARN_AREA_N such hits within
--    LEARN_AREA_IN s in one attack become one area hit (run away, roll again).
-- B: LEARN_FAILS hits through the same listed hit: parry -> dodge -> area -> kept.
tl.LEARN_FILE, tl.LEARN_MIN, tl.LEARN_NEAR, tl.LEARN_FAILS = MOD_DIR .. "learned_hits.txt", 15, 800, 2
tl.LEARN_AREA_N, tl.LEARN_AREA_IN, tl.LEARN_MAX, tl.dodgeFailAt = 3, 1.0, 300, -10
-- area hits this long (montage s): rolls on a beat AREA_RHYTHM s apart, up to AREA_MAX_LONG
tl.AREA_LONG, tl.AREA_MAX_LONG, tl.AREA_RHYTHM, tl.AREA_LONG_KEEP = 0.5, 20, 0.3, 1.0
tl.learnAdds, tl.learnSets, tl.learnFails, tl.learnStop = {}, {}, {}, {}
tl.setType = function(h, t)
    h.t, h[3], h[4], h[5] = t, t == "0" or t == "3" or t == "5" or t == "6", t == "5", t == "6"
end
tl.hitKey = function(name, h) return string.format("%s@%.3f", name, h[1]) end
tl.saveLearnedHits = function()
    local f = io.open(tl.LEARN_FILE, "w")
    if not f then return end
    f:write("# learned by Auto Defense from hits taken; delete a line (or this file) to forget it\n")
    for _, a in ipairs(tl.learnAdds) do f:write(string.format("add %s = %.3f:%.3f:%s\n", a.name, a.h[1], a.h[2], a.h.t)) end
    local keys = {}
    for k in pairs(tl.learnSets) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do f:write(string.format("set %s = %s\n", k, tl.learnSets[k])) end
    keys = {}
    for k, n in pairs(tl.learnFails) do if n > 0 then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do f:write(string.format("fail %s = %d\n", k, tl.learnFails[k])) end
    f:close()
end
tl.addHit = function(name, s, d, t, cast)
    -- TL.add returns the store's own list: writing to a fresh table here lost the
    -- first learned hit of an unlisted ability and counted the key anyway (audit P0-4)
    name = RT.bname(name) or name -- a learned "GA_X_C" used to open a second key (audit P1-9)
    local h = { s, d, false, false, false, t = "0", learned = true, learnedQ = cast }
    tl.setType(h, t)
    TL.addRow(name, h)
    tl.learnAdds[#tl.learnAdds + 1] = { name = name, h = h }
    if cast then
        tl.learnRecent[#tl.learnRecent + 1] = { name = name, h = h, c = os.clock() }
        if #tl.learnRecent > 20 then table.remove(tl.learnRecent, 1) end
    end
    return h
end
-- 1.4.2 test: a boss grab (player montage ZuoShang_LongTi_Skill_20_Hun_Montage)
-- ticked -32 HP every 0.2 s for 10 s and taught a 6 s area, a dodge for the
-- player's own GA_Hun_BEd_* and more. No lesson while grabbed, from a steady
-- tick, or from a GA_Hun_* (player) ability; a learned area is at most LEARN_AREA_MAXD
tl.LEARN_AREA_MAXD, tl.learnHist, tl.learnRecent = 2.0, {}, {}
tl.grabbedNow = function()
    local st = tl.montageState and tl.montageState(currentPawn)
    local n = st and st.name
    if not n then return false end
    -- also a broken guard: the hits after it could not be parried or dodged
    return (n:find("_Hun_Montage", 1, true) and not n:find("^Hun_")) or n:find("BEd", 1, true) ~= nil
        or n:find("Deflect_Break", 1, true) ~= nil
end
tl.tickSeries = function(amt, c)
    local hs = tl.learnHist
    hs[#hs + 1] = { c = c, amt = amt }
    while #hs > 6 do table.remove(hs, 1) end
    if #hs < 3 then return false end
    local a, b, z = hs[#hs - 2], hs[#hs - 1], hs[#hs]
    local d1, d2 = b.c - a.c, z.c - b.c
    if math.abs(a.amt - z.amt) > 1 or math.abs(b.amt - z.amt) > 1 then return false end
    if d1 < 0.12 or d1 > 0.35 or math.abs(d1 - d2) > 0.05 then return false end
    -- a steady tick: forget what its first hits taught
    local undone = 0
    for i = #tl.learnRecent, 1, -1 do
        local r = tl.learnRecent[i]
        if r.c >= a.c - 0.05 then tl.removeHit(r.name, r.h) undone = undone + 1 table.remove(tl.learnRecent, i) end
    end
    if undone > 0 then
        tl.saveLearnedHits()
        log("learn: steady -%.0f HP tick every %.2f s: %d lesson(s) from it undone", amt, d2, undone)
    end
    return true
end
tl.removeHit = function(name, h)
    TL.removeRow(name, h) -- forgets an emptied key and its count (audit P0-4)
    for i = #tl.learnAdds, 1, -1 do if tl.learnAdds[i].h == h then table.remove(tl.learnAdds, i) end end
end
do
    local f = io.open(tl.LEARN_FILE, "r")
    local adds, sets = 0, 0
    if f then
        for raw in f:lines() do
            local n, s, d, t = raw:match("^add%s+([%w_]+)%s*=%s*([%d%.]+):([%d%.]+):(%d)")
            if n then
                -- already in hit_times.txt (1.4.2 ships the author's lessons there): not twice
                local dup = false
                for _, h in ipairs(hitTimes[n] or {}) do
                    if math.abs(h[1] - tonumber(s)) < 0.0015 then dup = true end
                end
                if not dup then tl.addHit(n, tonumber(s), tonumber(d), t, nil) adds = adds + 1 end
            end
            local k, t2 = raw:match("^set%s+([%w_]+@[%d%.]+)%s*=%s*(%d)")
            if k then tl.learnSets[k] = t2 sets = sets + 1 end
            local k3, c = raw:match("^fail%s+([%w_]+@[%d%.]+)%s*=%s*(%d+)")
            if k3 then tl.learnFails[k3] = tonumber(c) end
        end
        f:close()
        for k, t in pairs(tl.learnSets) do
            local n, s = k:match("^([%w_]+)@([%d%.]+)$")
            for _, h in ipairs(hitTimes[n] or {}) do
                if math.abs(h[1] - tonumber(s)) < 0.0015 then tl.setType(h, t) end
            end
        end
        log("learned hits: %d added, %d changed (learned_hits.txt)", adds, sets)
    end
end

-- B: one more failure of hit j of attack q (once per hit per attack); at
-- LEARN_FAILS: parry -> dodge, black flash -> plain dodge, dodge -> area, area kept
tl.learnFail = function(q, j, how, why)
    local h = q.hits[j]
    q.failed = q.failed or {}
    if q.failed[j] then return end
    q.failed[j] = true
    local key = tl.hitKey(q.name, h)
    if tl.learnStop[key] then return end
    local was = h.t == "4" and "black flash" or (h[4] and "area" or (h[3] and "dodge" or "parry"))
    local n = (tl.learnFails[key] or 0) + 1
    tl.learnFails[key] = n
    local msg = string.format("learn: %s %s its %s (%d/%d, %s)", key, how, was, n, tl.LEARN_FAILS, why)
    if n >= tl.LEARN_FAILS then
        if h[4] then
            tl.learnStop[key] = true
            msg = msg .. ": area already, kept"
        else
            local to = (h[3] and h.t ~= "4") and "5" or "0"
            tl.setType(h, to)
            tl.learnSets[key], tl.learnFails[key] = to, 0
            msg = msg .. (to == "5" and ": now an area hit (run away, roll again)" or ": now dodged")
        end
    end
    tl.saveLearnedHits()
    log("%s", msg)
    attackLog("  %s", msg)
end

-- Guard break (user: a black flash not parried on time breaks the guard even
-- with the perfect tag, and then the player can neither parry nor dodge; 1.4.1
-- log: AM_Hun_Deflect_Break_L after a parry of Skill_20@2.47). No HP is lost, so
-- the break itself is the lesson: the hit the mod handled last counts as failed.
tl.BREAK_PAT, tl.breakOn, tl.breakCheckAt = "Deflect_Break", false, 0
tl.tickGuardBreak = function(pawn, now)
    if now < tl.breakCheckAt then return end
    tl.breakCheckAt = now + 0.05
    local st = tl.montageState and tl.montageState(pawn)
    local on = st and st.name and st.name:find(tl.BREAK_PAT, 1, true) ~= nil or false
    if not on or tl.breakOn then tl.breakOn = on return end
    tl.breakOn = true
    local bq, bj, bt
    for _, q in ipairs(tlQueue) do
        if q.tNow and q.tapped then
            for j, h in ipairs(q.hits) do
                if q.tapped[j] and h.t ~= "6" and not (q.far and q.far[j]) and h[1] <= q.tNow + 0.05 and h[1] >= q.tNow - 0.6
                    and (not bt or h[1] > bt) then bq, bj, bt = q, j, h[1] end
            end
        end
    end
    local what = bq and string.format("%s@%.2f", bq.name, bq.tNow) or "no handled hit"
    log("guard broken (%s): %s", st.name, what)
    attackLog("  -> guard broken (%s): %s", st.name, what)
    if bq and settings.learn and (settings.parry or settings.dodge ~= "off") then
        tl.try("learnFail", tl.learnFail, bq, bj, "broke the guard through", "guard break")
    end
end

-- called for each health drop over LEARN_MIN (not damage over time)
tl.learnFromHit = function(amt, warn)
    if not settings.learn or not valid(currentPawn) or #tl.learnAdds >= tl.LEARN_MAX then return end
    local c = os.clock()
    if tl.tickSeries(amt, c) or tl.grabbedNow() then return end
    -- the dodge could not come out (the player's own attack, a guard break): no lesson
    if c - tl.dodgeFailAt < 1.0 then return end
    local function near(actor)
        local ok, d = pcall(function() return tonumber(unwrap(actor:GetDistanceTo(currentPawn))) end)
        return ok and d and d <= tl.LEARN_NEAR and d or nil
    end
    -- the attack this hit belongs to: one with a listed hit here, else the nearest
    local best, bestJ, matchD, nearQ, nearD
    for _, q in ipairs(tlQueue) do
        if q.tNow and valid(q.actor) then
            local d = near(q.actor)
            if d then
                for j, h in ipairs(q.hits) do
                    if h.learnedQ ~= q and q.tNow >= h[1] - 0.15 and q.tNow <= h[1] + h[2] + 0.15
                        and (not matchD or d < matchD) then best, bestJ, matchD = q, j, d end
                end
                if not nearD or d < nearD then nearQ, nearD = q, d end
            end
        end
    end
    -- B: a listed hit the mod handled still hit
    if bestJ then
        local q, h = best, best.hits[bestJ]
        if not q.tapped or not q.tapped[bestJ] or h.t == "6" then return end
        if q.far and q.far[bestJ] then return end -- left alone as out of reach
        if (h[3] and settings.dodge == "off") or (not h[3] and (not settings.parry or tl.guardOwned())) then return end
        tl.learnFail(q, bestJ, "hit through", string.format("-%.0f HP, %s", amt, warn))
        return
    end
    if settings.dodge == "off" then return end
    -- A: no listed hit here
    local q, name, t, cast = nearQ, nil, nil, nil
    if q then
        name, t, cast = q.name, q.tNow, q
    elseif tl.lastEnemy and c - (tl.lastEnemyAt or -10) < 3 and tl.lastEnemyActor and valid(tl.lastEnemyActor)
        and not hitTimes[tl.lastEnemy] and near(tl.lastEnemyActor) then
        -- an attack hit_times.txt does not know at all: its montage position
        local st = tl.montageState and tl.montageState(tl.lastEnemyActor)
        if not st or not st.pos then return end
        name, t = tl.lastEnemy, st.pos
        tl.noQ = (tl.noQ and tl.noQ.name == name and tl.noQ.at == tl.lastEnemyAt) and tl.noQ
            or { name = name, at = tl.lastEnemyAt }
        cast = tl.noQ
    else
        return
    end
    if name:find("^GA_Hun_") then return end -- the player's own (grabbed / executed) ability
    cast.unl = cast.unl or {}
    cast.unl[#cast.unl + 1] = { t = t, c = c }
    local recent, first = 0, nil
    for _, u in ipairs(cast.unl) do
        if c - u.c <= tl.LEARN_AREA_IN then recent = recent + 1 first = first or u end
    end
    local msg
    if cast.area then
        local d = math.min(tl.LEARN_AREA_MAXD, t + 0.2 - cast.area[1])
        if d > cast.area[2] then
            cast.area[2] = d
            tl.saveLearnedHits()
        end
        return
    elseif recent >= tl.LEARN_AREA_N then
        -- a burst: the single dodges learned in this attack become one area hit
        for _, h in ipairs(hitTimes[name] or {}) do
            if h.learnedQ == cast and h.t == "0" then cast.drop = cast.drop or {} cast.drop[#cast.drop + 1] = h end
        end
        for _, h in ipairs(cast.drop or {}) do tl.removeHit(name, h) end
        local s = math.max(0, first.t - 0.05)
        cast.area = tl.addHit(name, s, math.min(tl.LEARN_AREA_MAXD, math.max(0.3, t - s + 0.2)), "5", cast)
        msg = string.format("learn: %s hits %d times in %.1f s at %.2f-%.2f: area hit added", name, recent, tl.LEARN_AREA_IN, s, t)
        -- the rest of this burst: run away now
        if q and q.tapped then local j = #q.hits q.tapped[j], q.moved[j], q.again[j] = nil, nil, nil end
    else
        for _, h in ipairs(hitTimes[name] or {}) do
            if math.abs(h[1] - t) <= 0.15 then return end -- learned already
        end
        local h = tl.addHit(name, math.max(0, t - 0.03), 0.1, "0", cast)
        msg = string.format("learn: %s hit at %.2f (-%.0f HP, %s): dodge added", name, h[1], amt, warn)
    end
    tl.saveLearnedHits()
    log("%s", msg)
    attackLog("  %s", msg)
end

if TL.count() > 0 then enemyScanWanted = true end -- the boss may already be there

-- Every call into the game makes Lua garbage (perf test 1.3.2: ~2 KB per call,
-- ~9 MB per 10 s); collecting it every few seconds cost frames (120 -> 60 fps
-- for a moment). Held keys are read at most every KEYS_EVERY s, and the
-- collector runs in small young-object passes instead of big sweeps.
RT.gc("generational") -- 5.4 only: RT falls back to a full collect on 5.1
tl.KEYS_EVERY, tl.keyState = 0.03, {}
tl.keysCached = function(slot)
    local s = tl.keyState[slot]
    if s and os.clock() - s.at < tl.KEYS_EVERY then return s.down end
    return nil
end
tl.keysDown = function(ctrl, keys, slot)
    local down = false
    for _, k in ipairs(keys) do
        local ok, d = pcall(ctrl.IsInputKeyDown, ctrl, k)
        if ok and unwrap(d) == true then down = true break end
    end
    tl.keyState[slot] = { at = os.clock(), down = down }
    return down
end

local LEARN_FILE = MOD_DIR .. "learned_dodges.txt"
local function loadLearned()
    local f = io.open(LEARN_FILE, "r")
    if not f then return end
    for raw in f:lines() do
        local line = raw:gsub("\r", "")
        local k, v = line:match("^%s*([%w_]+)%s*=%s*([%d%.]+)")
        if k and tonumber(v) then learned[k] = tonumber(v) end
    end
    f:close()
end
local function saveLearned()
    local f = io.open(LEARN_FILE, "w")
    if not f then return end
    f:write("# enemy ability = seconds after it starts to dodge a hit that sends no warning (black flash)\n")
    f:write("# learned by the mod; delete a line (or the file) to forget it\n")
    local names = {}
    for k in pairs(learned) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do f:write(string.format("%s = %.2f\n", k, learned[k])) end
    f:close()
end
loadLearned()

local function specialActive()
    if special and os.clock() > special.untilT then special = nil end
    return special ~= nil
end

-- ---------------------------------------------------------------- perfect deflect
local perfectPawn -- pawn address our tag was added to
local function hasPerfectTag(pawn)
    local asc = ascOf(pawn)
    if not valid(asc) then return nil end
    local ok, n = pcall(function() return asc:GetGameplayTagCount(tag(PERFECT_TAG)) end)
    if ok and type(n) == "number" then return n > 0 end
    ok, n = pcall(function() return asc:HasMatchingGameplayTag(tag(PERFECT_TAG)) end)
    if ok and type(n) == "boolean" then return n end
    return nil
end

local function setPerfect(pawn, on, quiet)
    local lib = tagLibrary()
    if not lib then log("perfect: PBZAbilityBlueprintLibrary not found") return false end
    local fnName = on and "AddLooseGameplayTag" or "RemoveLooseGameplayTag"
    local ok, res = pcall(function() return lib[fnName](lib, pawn, tag(PERFECT_TAG), false) end)
    if not quiet or not ok then
        log("perfect: %s -> %s, tag present now: %s", fnName, ok and tostring(res) or ("error " .. tostring(res)),
            tostring(hasPerfectTag(pawn)))
    end
    return ok
end

-- window mode: the tag is on while a normal hit is announced within PERFECT_LEAD
-- seconds (and for PERFECT_HOLD after), never while a special attack is coming
local PERFECT_LEAD, PERFECT_HOLD = 0.6, 0.3
local windowUntil = 0
local endStance -- set in the stance section: ends the player's deflect stance
local perfectFailed, recheckAt = false, 0
local perfectQuiet = false -- after the first release: tag on/off happens often, keep the log short

local PERFECT_SUSPEND = 0.4
local perfectSuspendUntil = 0
local function perfectWanted(deflect)
    if not settings.perfect then return false end
    -- the perfect result is PBZPerfectDefense's to give; one rule, one door
    if tl.policy then
        if not tl.policy.allows("perfect_tag") then return false end
    elseif tl.guardOwned() then
        return false
    end
    if specialActive() then windowUntil = 0 return false end
    if settings.perfectMode == "give" then
        return (settings.blackFlash ~= "dodge" and os.clock() < (tl.blackUntil or 0)) or os.clock() < (tl.bulletUntil or 0)
            -- not while a black flash is to be rolled out of: the tag holds the guard
            or (os.clock() < tl.tagUntil and not (tl.blackDodge() and os.clock() < (tl.blackUntil or 0)))
    end
    if os.clock() < perfectSuspendUntil then
        if not (deflect and nearest(deflect, false, PERFECT_LEAD) >= 0) then return false end
        perfectSuspendUntil = 0
    end
    if settings.perfectMode == "always" then return true end
    if deflect and nearest(deflect, false, PERFECT_LEAD) >= 0 then windowUntil = os.clock() + PERFECT_HOLD end
    return os.clock() < windowUntil
end

-- BP_RenewalPlayer.TryReapplyForcePerfectDeflect: raises the forced perfect
-- stance at once (the game itself calls it only when a stance ends)
local reapplyLogged = 0
local function reapplyStance(pawn)
    local ok, err = pcall(function() pawn:TryReapplyForcePerfectDeflect() end)
    if reapplyLogged < 5 then
        reapplyLogged = reapplyLogged + 1
        local asc = ascOf(pawn)
        local okT, on = pcall(function() return asc:HasMatchingGameplayTag(tag("Ability.Action.Stance")) end)
        log("perfect window: TryReapplyForcePerfectDeflect %s, stance %s", ok and "ok" or ("error " .. tostring(err)),
            okT and tostring(unwrap(on)) or "?")
    end
end

local function tickPerfect(pawn, deflect)
    if perfectFailed then return end
    local addr = pawn:GetAddress()
    local quiet = settings.perfectMode ~= "always" or perfectQuiet
    if perfectWanted(deflect) then
        -- the game may clear loose tags (death, cutscene): look again now and then
        if perfectPawn == addr and os.clock() < recheckAt then return end
        recheckAt = os.clock() + (quiet and 0.2 or 1)
        if hasPerfectTag(pawn) == true then perfectPawn = addr return end
        if setPerfect(pawn, true, quiet) then
            perfectPawn = addr
            if quiet then reapplyStance(pawn) end
        else
            perfectFailed = true
        end
    elseif perfectPawn == addr then
        setPerfect(pawn, false, quiet)
        perfectPawn = nil
        if endStance then endStance(pawn, "perfect window over") end
    end
end

-- the give-mode tag window changed: put the tag on / take it off now, not next tick
tl.tickPerfectNow = function(pawn) tickPerfect(pawn, nil) end

-- ---------------------------------------------------------------- activation
local loggedHits = 0
local function activate(_input, kind, handle, now, how)
    local ok, res = pcall(how)
    local accepted = ok and unwrap(res) == true
    attackLog("  -> %s handle=%d at %.2f: %s", kind, handle, now, ok and tostring(unwrap(res)) or ("error " .. tostring(res)))
    if loggedHits < 300 then
        loggedHits = loggedHits + 1
        log("%s handle=%d at %.2f: %s", kind, handle, now, ok and tostring(unwrap(res)) or ("error " .. tostring(res)))
    end
    return accepted
end

-- ---------------------------------------------------------------- key taps
-- One press of an input action injected through Enhanced Input: it lasts one
-- frame, so the game sees a tap (press, then release) exactly like a real key.
local function injectKey(action)
    local ctrl = UEHelpers.GetPlayerController()
    local lib = obj("/Script/Engine.Default__SubsystemBlueprintLibrary")
    local cls = obj("/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem")
    if not valid(ctrl) or not lib or not cls then return false end
    local sub = lib:GetLocalPlayerSubSystemFromPlayerController(ctrl, cls)
    if not valid(sub) then return false end
    sub:InjectInputVectorForAction(action, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {})
    -- stamped at the one injection point: the game then reports IA_Deflect as
    -- held, which must not be read back as "the player holds the guard"
    tl.injectAt = os.clock()
    return true
end

-- ---------------------------------------------------------------- auto parry
-- The deflect is the equipped weapon's GA_Hun_<Weapon>_Stance_C (derives
-- BP_StanceAction_Base_Player_C, which holds "Get Deflect Result"), tagged
-- Ability.Action.Stance, so one tag covers every weapon. Do not scan
-- ActivatableAbilities / EnhancedActionMappings from Lua to find it: doing that
-- every few seconds crashed inside UE4SS (null FProperty).
-- Stance + IA_Deflect is what the game accepts; the others are fallbacks in
-- case a game update changes it. The first one accepted is kept.
local PARRY_TRIES = {
    { tag = "Ability.Action.Stance", action = "IA_Deflect" },
    { tag = "Ability.Action.Stance", action = "IA_Stance" },
    { tag = "Ability.Action.HoldDeflect", action = "IA_Deflect" },
}
local parried, parryWorks, parryFailed = {}, nil, false
-- Hit handles count up per Deflect Component and start again with a new
-- character (death, map change), so a handle is "done" for tl.HANDLE_TTL s only:
-- kept forever, every hit of the new character up to the old count was skipped.
tl.HANDLE_TTL, tl.handlesPruneAt = 10, 0
tl.done = function(h)
    local since = os.clock() - tl.HANDLE_TTL
    return (parried[h] or -1e9) > since or (dodged[h] or -1e9) > since
end
tl.prunable = { parried, dodged } -- every per-handle table registers here (audit P2-10)
tl.pruneHandles = function()
    local t = os.clock()
    if t < tl.handlesPruneAt then return end
    tl.handlesPruneAt = t + 30
    for _, tab in ipairs(tl.prunable) do
        for h, at in pairs(tab) do if at <= t - tl.HANDLE_TTL then tab[h] = nil end end
    end
end

-- FindObject walks the whole object table: a name that is not there is not
-- searched again for tl.MISS_RETRY s (1.3.4 report: a frame drop every few
-- seconds on some setups; IA_Sprint is not found even here)
tl.MISS_RETRY, tl.actionMiss = 60, {}
-- wait before search number n for something not found: 2, 4, 8 ... 60 s, and
-- after tl.SEARCH_MAX searches no more (until a new character)
tl.SEARCH_MAX = 10
tl.searchWait = function(n) return n >= tl.SEARCH_MAX and 1e9 or math.min(60, 2 ^ n) end
local actions = {}
local function inputAction(n)
    local a = actions[n]
    if valid(a) then return a end
    a = obj("/PBZDeflectSystem/Input/" .. n .. "." .. n)
    if not a and os.clock() >= (tl.actionMiss[n] or 0) then
        local ok, found = pcall(FindObject, "InputAction", nil, n, false)
        if ok and valid(found) then a = found else tl.actionMiss[n] = os.clock() + tl.MISS_RETRY end
    end
    if a then
        actions[n] = a
        log("input action %s: %s", n, a:GetFullName())
    end
    return a
end

local function tryParry(input, try, h, now)
    local action = inputAction(try.action)
    if not action then return false end
    return activate(input, "parry " .. try.tag .. "/" .. try.action, h, now, function()
        return input:TryActivateExternalActionAbilityInterruptLowerByTag(tag(try.tag), action, -5)
    end)
end

-- A tap of the deflect key: the game runs its own deflect and sees the key
-- released. Activating the ability directly (PARRY_TRIES) works too, but the
-- game then never sees a release and the character stays in a held guard; it is
-- only used when the tap cannot be injected.
local tapWorks = nil
local lastTap = nil -- os.clock() of the last deflect tap, for the held-guard release
local lastTapAt = nil -- same, kept for the stance log
local releaseFrom = nil -- the mod's last tap, until its deflect key is released
local TAP_HOLD = 0.25 -- seconds the injected deflect press lasts (one frame left the stance waiting)
local tapHold = nil -- { action, untilT }
-- perfect_mode = give: a click within 0.4 s of the last one gets a shorter
-- perfect window (0.2 s, then 0.06 s, then none), and the injected press counts
-- as a click every frame it lasts (probe 2026-11-03: one tap = 8 clicks, the
-- window closed after the first frame). Before each injected frame the last
-- click is moved back, so every frame opens the full window again.
tl.blackDodge = function() return settings.perfectMode == "give" and settings.blackFlash == "dodge" end
-- give mode: perfect tag after a non-perfect mod deflect (TAG_AFTER_NORMAL s) and
-- for a press while Sha-chi is below LOW_SHACHI of its maximum (LOW_TAG s)
tl.tagUntil, tl.tagLogs, tl.TAG_AFTER_NORMAL, tl.LOW_SHACHI, tl.LOW_TAG = 0, 0, 1.5, 0.30, 0.4
-- after the roll out of a black flash: no parry press for this long (s)
tl.noTapUntil, tl.NO_TAP_AFTER_BLACK = 0, 0.35
tl.unpunish = function()
    if settings.perfectMode ~= "give" or not tl.passiveOf or not valid(currentPawn) then return end
    local ps = tl.passiveOf(currentPawn)
    if not ps then return end
    tl.try("reset perfect window", RT.resetPerfect, ps)
end
-- the window the game opened, read once the press is over (first taps only)
tl.giveLog = function()
    tl.giveLogged = (tl.giveLogged or 0) + 1
    if tl.giveLogged > 20 or not tl.passiveOf or not valid(currentPawn) then return end
    local ps = tl.passiveOf(currentPawn)
    local gs = obj("/Script/Engine.Default__GameplayStatics")
    if not ps or not gs then return end
    local now = unwrap(gs:GetTimeSeconds(currentPawn))
    local pw, lc, n = unwrap(ps["Perfect Window"]), unwrap(ps["Last Deflect Click"]), unwrap(ps["Current Perfect Window Counter"])
    log("perfect give: game %.2f, last click %.2f, perfect window until %.2f (%+.2f s), counter %s",
        now, lc, pw, pw - now, tostring(n))
end
-- 1.4.2: a new tap while the last press is still injected (or let go less
-- than TAP_GAP ago) is no new press for Enhanced Input: the key just stays
-- down, and the game shows a perfect deflect but still takes the damage
-- (1.4.1 log 2026-11-04: 31 of 192 perfects with an overlapping press lost HP,
-- 17 of 346 after a fresh press, 0 of 46 of the player's own). The press is
-- let go first and made TAP_GAP later, from tickTapHold.
-- 1.4.4 (PBZAssist timing.min_gap_ms = 90): a press less than this after the last
-- one is no new press for the game, the key just stays down, and the deflect is
-- perfect but takes the damage (1.4.1: 31 of 192). 40 ms was too short.
tl.TAP_GAP, tl.tapEndAt, tl.tapPending, tl.gapTaps = settings.minGap or 0.12, -10, nil, 0
local function tickTapHold()
    if tapHold and tl.guardOwned() then tapHold = nil tl.tapEndAt = os.clock() return end
    local p = tl.tapPending
    if p and os.clock() >= p.at then
        tl.tapPending = nil
        if not tapHold then pcall(tl.pressTap, p.h, p.now) end
    end
    if not tapHold then return end
    if os.clock() >= tapHold.untilT then
        tapHold = nil
        tl.tapEndAt = os.clock()
        if settings.perfectMode == "give" then pcall(tl.giveLog) end
        return
    end
    tl.try("unpunish", tl.unpunish)
    tl.try("injectKey", injectKey, tapHold.action)
end

-- 1.4.4 (PBZAssist defense.flurry_guard): three listed hits inside 0.25 s are taken
-- behind a held guard instead of one tap per hit (each tap inside TAP_GAP is no new
-- press, and the fast chain shortens the perfect window). tapHold re-injects the
-- key every frame until untilT, so holding is just a longer tap.
tl.holdGuard = function(untilT, why)
    if not untilT then return false end
    if not tapHold and not (valid(currentPawn) and tl.pressTap(-1, nowOf(currentPawn))) then return false end
    if not tapHold then return false end -- the tap was refused by the rules
    tapHold.untilT = math.max(tapHold.untilT, untilT)
    tl.led("flurry: guard held for %.0fms (%s)", (untilT - os.clock()) * 1000, why or "-")
    return true
end

-- ---------------------------------------------------------------- counter
-- 1.6.7, off by default: 别离残钩 answers a black flash with the game's own
-- counter (hold the guard stance, press Triangle 0.22-0.35 s before the hit),
-- and an enemy carrying a blue shield makes the mod bring that weapon out first
-- and counter its blockable hits. The counter is a dodge replacement, not a
-- second press: the hit it takes is marked in q.countered and the timeline skips
-- both its parry and its dodge.
do
    local said = {}
    local function once(key, fmt, ...)
        if said[key] then return end
        said[key] = true
        log(fmt, ...)
    end
    tl.counterHold = nil -- { stance, untilT, action, pressed }
    -- The class name as written on disk, for log lines only (short() is defined
    -- much later in the chunk and nothing here may call forward).
    local function brief(v)
        if not valid(v) then return nil end
        local ok, s = pcall(function() return v:GetName() end)
        return ok and type(s) == "string" and s or nil
    end
    -- The Triangle press. EnhancedActionMappings is not scanned for it: doing that
    -- from Lua crashed inside UE4SS (null FProperty, 1.3.x), so the names the game
    -- uses for that key are tried in order and the first that resolves is kept.
    tl.COUNTER_ACTIONS = { "IA_AttackH_Press", "IA_AttackH_Hold", "IA_AttackH_PressLong", "IA_AttackH" }
    tl.counterAction = function()
        if valid(tl.counterAct) then return tl.counterAct end
        local t = os.clock()
        if t < (tl.counterActAt or 0) then return nil end
        tl.counterActAt = t + 5
        for _, name in ipairs(tl.COUNTER_ACTIONS) do
            local a = inputAction(name)
            if valid(a) then
                tl.counterAct = a
                log("counter: %s is the press for the 别离残钩 counter", name)
                return a
            end
        end
        once("noact", "counter: no Triangle input action resolved (%s), a black flash keeps the dodge",
            table.concat(tl.COUNTER_ACTIONS, ", "))
        return nil
    end
    -- the main weapon in hand and the one a weapon switch brings out (backpack
    -- subsystem; 0.5 s cache so a tick never reads it twice)
    local cacheAt, cache, bag, bagAt = -1e9, nil, nil, -1e9
    local function backpack()
        if valid(bag) then return bag end
        if os.clock() < bagAt then return nil end
        bagAt = os.clock() + 5
        local ok, list = pcall(FindAllOf, "PBZBackPackSubsystem")
        if not ok then return nil end
        for _, one in ipairs(list or {}) do
            if valid(one) and not tostring(brief(one)):find("^Default__") then bag = one return bag end
        end
        return nil
    end
    -- The backpack keeps weapon IDs as plain strings (MainWeapons is a
    -- TArray<string>, CurrentMainWeaponID a string): asking valid() or GetFullName
    -- of them throws, and a throw here used to silence both counter features.
    local function textOf(v)
        if type(v) == "string" then return v end
        if v == nil or type(v) == "number" or type(v) == "boolean" then return nil end
        local ok, s = pcall(function() return v:GetFullName() end)
        if ok and type(s) == "string" then return s end
        local okg, raw = pcall(function() return v:get() end)
        return okg and type(raw) == "string" and raw or nil
    end
    -- the same weapon may be named by its class or by its display name; the module
    -- matches one substring, so both spellings are normalized to it
    local function hookName(s)
        if type(s) ~= "string" then return s end
        return (s:gsub("別離殘鉤", "DualHook"):gsub("别离残钩", "DualHook"))
    end
    tl.weaponNow = function()
        local t = os.clock()
        if t - cacheAt < 0.5 then return cache end
        cacheAt = t
        local out = nil
        local bp = backpack()
        if bp then
            pcall(function()
                local names, n = {}, 0
                local list = bp.MainWeapons
                if list ~= nil then
                    local okn, len = pcall(function() return #list end)
                    len = okn and tonumber(len) or nil
                    if len and len > 0 then
                        n = len
                        for i = 1, n do names[i] = textOf(list[i]) end
                    else
                        pcall(function() list:ForEach(function(_, v) names[#names + 1] = textOf(v) end) end)
                        n = #names
                    end
                end
                local idx = tonumber(bp.CurrentWeaponIndex)
                local cur = idx and names[idx + 1] or nil
                cur = hookName(cur or textOf(bp.CurrentMainWeaponID))
                local nxt = nil
                if idx and n > 1 then nxt = hookName(names[(idx + 1) % n + 1]) end
                out = { current = cur, next = nxt }
            end)
        end
        cache = out
        return out
    end
    -- enemies that announced an attack in the last 20 s: the blue-shield scan needs
    -- nobody else, and this mod enumerates no actors (FindAllOf stays out of ticks)
    do
        local recent = {}
        tl.recentAttackers = recent
        -- never throws: it runs on the queue path of every announced attack, and a
        -- stranger object must not be able to stop that path
        local noted = 0
        tl.noteAttacker = function(actor, dist)
            if actor == nil then return end
            pcall(function()
                if not valid(actor) then return end
                local ok, addr = pcall(function() return actor:GetAddress() end)
                if not (ok and addr) then return end
                recent[addr] = { actor = actor, at = os.clock(), dist = dist }
                -- the scan that reads this table only runs with shield_counter on, so
                -- the sweep cannot wait for it (a leak on every install with it off)
                noted = noted + 1
                if noted % 64 == 0 then
                    local now = os.clock()
                    for a, rec in pairs(recent) do
                        if now - rec.at > 20 then recent[a] = nil end
                    end
                end
            end)
        end
        tl.attackersNow = function()
            local out, now = {}, os.clock()
            for addr, rec in pairs(recent) do
                if now - rec.at > 20 or not valid(rec.actor) then
                    recent[addr] = nil
                else
                    local one = { actor = rec.actor, dist = rec.dist }
                    pcall(function()
                        local okc, cls = pcall(function() return rec.actor:GetClass() end)
                        if okc and valid(cls) then one.class = brief(cls) end
                        local set = rec.actor.AttributeSetBase
                        if valid(set) then
                            local oks, sv = pcall(RT.curOf, set.Shield)
                            if oks then one.shield = tonumber(sv) end
                            local okm, mv = pcall(RT.curOf, set.Shield_Max)
                            if okm then one.max = tonumber(mv) end
                        end
                        if valid(currentPawn) then
                            local okd, d = pcall(function() return rec.actor:GetDistanceTo(currentPawn) end)
                            d = okd and tonumber(unwrap(d)) or nil
                            if d then one.dist = d end
                        end
                    end)
                    out[#out + 1] = one
                end
            end
            return out
        end
    end
    local function blueShield(actor)
        local okv, usable = pcall(valid, actor) -- a stranger object must not throw
        if not (okv and usable) then return nil end
        local ok, set = pcall(function() return actor.AttributeSetBase end)
        if not (ok and valid(set)) then return nil end
        local oks, sv = pcall(RT.curOf, set.Shield)
        local v = oks and tonumber(sv) or nil
        return v ~= nil and v > 0 and v or nil
    end
    tl.counterShieldOf = blueShield
    -- which counter, if any, this timeline row asks for
    tl.counterKind = function(h)
        -- a black flash belongs to the hook counter or to no counter at all: the
        -- blue-shield counter answers the blockable hits of a shielded enemy
        if h.t == "4" then return settings.hookCounter == "on" and "black" or nil end
        if settings.shieldCounter == "on" and not h[3] then return "shield" end
        return nil
    end
    -- "press" starts the hold, "wait" means a later tick offers again, nil leaves
    -- the row to the dodge/parry chain exactly as before
    tl.counterTry = function(kind, hitAt, now, actor, q, j)
        if not (tl.weapon or tl.weaponErr) then tl.installCounter() end
        local W, C = tl.weapon, tl.counter
        if not (W and C) then return nil end
        if kind == "shield" then
            if not blueShield(actor) then return nil end
            local ok, dist = pcall(function() return actor:GetDistanceTo(currentPawn) end)
            dist = ok and tonumber(unwrap(dist)) or nil
            if not dist or dist > (tonumber(settings.shieldCounterRange) or 1500) then return nil end
        end
        local action = tl.counterAction()
        local verdict = C:offer(kind, hitAt, hitAt - now, {
            held = W:held(now),
            shachiOk = W:enough(tonumber(settings.hookCounterShachi) or 37, now),
            action = action ~= nil,
        })
        if verdict == "press" then
            if tl.releaseHeldKey then pcall(tl.releaseHeldKey) end
            tapHold = nil -- the counter holds the stance, not the deflect key
            local stance = inputAction("IA_Stance") or inputAction("IA_Deflect")
            tl.counterHold = { kind = kind, stance = stance, action = action, pressed = false,
                untilT = hitAt + 0.15, q = q, j = j }
            tl.led("counter %s: hold guard + %s, %.3f s before the hit", kind, tostring(action and action:GetFullName() or "-"),
                hitAt - now)
            log("counter: %s %.3f s before the hit (guard held, Triangle pressed next frame)", kind, hitAt - now)
        end
        return verdict
    end
    -- called every frame: re-inject the stance while it must hold, press the
    -- counter action once, and close the bookkeeping
    tl.tickCounter = function(now)
        local hold = tl.counterHold
        if hold then
            if now >= hold.untilT then
                tl.counterHold = nil
            else
                if valid(hold.stance) then tl.try("counter stance", injectKey, hold.stance) end
                if not hold.pressed then
                    hold.pressed = true
                    local okp, sent = pcall(injectKey, hold.action)
                    if okp and sent then
                        -- the press went out: the stance has until confirmBy to show
                        if tl.counter then pcall(tl.counter.guardUp, tl.counter, now) end
                    else
                        once("pressfail", "counter: the Triangle press could not be injected (%s)",
                            okp and "no input subsystem" or tostring(sent))
                    end
                end
            end
        end
        local C = tl.counter
        if not C then return end
        local res = C:poll(now)
        if res == "confirmed" then tl.led("counter: the press was injected (the stance itself is not read)") end
        if res == "failed" then
            -- the stance never started: give the hit back to the ordinary chain so
            -- the dodge (or, for a black flash, the black rule) can still take it
            local hold = tl.counterHold
            if hold and hold.q and hold.j then
                pcall(function()
                    hold.q.countered[hold.j] = nil
                    hold.q.tapped[hold.j] = nil
                end)
            end
            tl.counterHold = nil
            once("fail", "counter: the stance did not start in time, the next hit takes the normal defence")
            tl.led("counter: the stance did not start in time")
        end
    end
    -- bring 别离残钩 out for a blue-shielded enemy, at most every 2 s, and never
    -- while a counter is being played out
    tl.tickShieldSwitch = function(now)
        if settings.shieldCounter ~= "on" or tl.counterHold then return end
        if not tl.weapon then tl.installCounter() end
        local W = tl.weapon
        if not (W and valid(currentPawn)) then return end
        if W:held(now) then
            if tl.shieldSwitchAt and not tl.shieldHeldLogged then
                tl.shieldHeldLogged = true
                log("blue shield: 别离残钩 is in hand and a shielded enemy is near, it stays out")
            end
            return
        end
        local near = W:shield(now)
        if not near then return end
        if now < (tl.shieldSwitchAt or -1e9) + 2 then return end
        if not W:nextHeld(now) then
            once("noalt", "blue shield: %s is near, but a weapon switch would not bring 别离残钩 out (holding %s)",
                tostring(near.class), tostring((tl.weaponNow() or {}).current))
            return
        end
        local change = inputAction("IA_ChangeWeapon")
        if not change then
            once("nochange", "blue shield: IA_ChangeWeapon does not resolve, the weapon cannot be switched")
            return
        end
        if injectKey(change) then
            tl.shieldSwitchAt, tl.shieldHeldLogged = now, nil
            log("blue shield: %s (%.0f/%.0f, %.0f cm away): switching to 别离残钩", tostring(near.class), near.shield,
                near.max or 0, near.dist)
        end
    end
end

local function tapParry(h, now)
    if tapWorks == false or settings.parryMethod ~= "key" then return false end
    if tl.guardOwned() then return false end
    if tl.TAP_GAP > 0 and (tapHold or os.clock() - tl.tapEndAt < tl.TAP_GAP) then
        if not inputAction("IA_Deflect") then return false end
        if tapHold then tapHold = nil tl.tapEndAt = os.clock() end
        if tl.releaseHeldKey then pcall(tl.releaseHeldKey) end
        tl.tapPending = { h = h, now = now, at = tl.tapEndAt + tl.TAP_GAP }
        tl.gapTaps = tl.gapTaps + 1
        attackLog("  -> parry key handle=%d: key let go first, pressed in %.2fs", h, tl.tapPending.at - os.clock())
        if tl.gapTaps <= 5 then log("parry: key let go %.2fs before a new press (overlapping tap #%d)", tl.TAP_GAP, tl.gapTaps) end
        return true
    end
    return tl.pressTap(h, now)
end

tl.pressTap = function(h, now)
    if not settings.parry then return false end -- queued presses/retries must respect the off switch
    -- the single choke point for every guard key press: PBZPerfectDefense's AutoGuard
    -- holds the guard itself, a second press inside RepeatGuard is no new press
    -- ownership is answered by the shared rules (tl.policy) through the controlled
    -- entry tl.input; this function is only the mechanics of the press

    local action = inputAction("IA_Deflect")
    if not action then tl.emit("parry_noaction", h, now, 0) return false end
    -- give mode, Sha-chi low: this press gets the perfect tag (a non-perfect
    -- deflect would drain the rest and break the guard)
    if settings.perfectMode == "give" and settings.perfect and tl.shachiShare then
        local okS, share = pcall(tl.shachiShare)
        if okS and share and share < tl.LOW_SHACHI then
            if os.clock() >= tl.tagUntil then
                tl.tagLogs = tl.tagLogs + 1
                if tl.tagLogs <= 200 then log("give: Sha-chi %.0f %%, perfect tag on for this press", share * 100) end
            end
            tl.tagUntil = math.max(tl.tagUntil, os.clock() + tl.LOW_TAG)
            -- on before the press (test 01:33:18: the tag came 0.15 s after it,
            -- the deflect was Normal)
            if tl.tickPerfectNow and valid(currentPawn) then pcall(tl.tickPerfectNow, currentPawn) end
        end
    end
    tl.try("unpunish", tl.unpunish)
    -- 1.4.3: the game's own count of presses, read before the press (after it, a
    -- press the game already handled in this frame reads as not seen)
    local click0 = settings.receipt and valid(currentPawn) and tl.receipt0(currentPawn) or nil
    local ok, res = pcall(injectKey, action)
    attackLog("  -> parry key handle=%d at %.2f: %s", h, now, ok and tostring(res) or ("error " .. tostring(res)))
    if not (ok and res) then tl.emit("parry_fail", h, now, 0) end
    if ok and res then
        tl.sincePress = os.clock() - (lastTapAt or -100)
        tapHold = { action = action, untilT = os.clock() + TAP_HOLD }
        releaseFrom = os.clock()
        lastTap = os.clock()
        lastTapAt = lastTap
        tl.lastTapClock = lastTap
        -- 1.4.3: Last Deflect Click says whether the game saw this press at all and
        -- how late (PBZAssist 的输入回执 / timing.latency_frames); the window it
        -- opened sizes the next lead. Its time is the game's clock, so `now`
        -- (os.clock() when the timeline called) is not used here.
        if click0 then
            tl.receipt = { h = h, game = nowOf(currentPawn), at = os.clock(), click0 = click0 }
            tl.recSeen = (tl.recSeen or 0) + 1
        end
        tl.emit("parry", h, now, 1)
        tl.try("noteWindow", tl.noteWindow, currentPawn)
        if tapWorks == nil then tapWorks = true log("parry: tapping IA_Deflect") end
        return true
    end
    tapWorks = false
    log("parry: deflect key cannot be tapped (%s), using the ability", ok and "no input subsystem" or tostring(res))
    return false
end

-- tl.grabDodge is set after dodge()
tl.grabFrame = function()
    return settings.dodge ~= "off" and os.clock() - tl.grabAt < tl.grabWindow and tl.grabDone ~= tl.grabAt
end

local function tickParry(deflect, input, now)
    if not settings.parry or (parryFailed and os.clock() < parryFailed) then return end
    if tl.guardOwned() then return end -- PBZPerfectDefense AutoGuard presses and holds the guard
    if settings.dodge ~= "off" and specialActive() then return end -- dodged instead
    -- black flash: dodged. A dodge at a hit announced meanwhile was tried
    -- (give #5) and broke the black flash dodge: JumpOut announces its own hit
    -- 0.13 s before the timeline dodge, and the second dodge took the hit
    if tl.blackDodge() and os.clock() < (tl.blackUntil or 0) then return end
    -- 1.4.3 (PBZAssist DeflectLead): ask for the hit within the lead the press
    -- needs and press only once the frame's own hit time is that close. 0.08 s
    -- before the hit was the whole margin; the game's window is ~0.27 s.
    -- 1.5.0: the player's own move may be invulnerable right now (game data winv)
    if settings.data and tl.dat and tl.dat.ready then
        local inv, invTag = tl.dat.invuln(currentPawn)
        if inv then
            tl.ledOnce("invuln", "parry: player invulnerable (%s), not pressed", invTag ~= "" and invTag or "-")
            return
        end
    end
    local lead = tl.parryLead()
    local wide = math.max(PARRY_WINDOW, lead + 0.06)
    local h = nearest(deflect, false, wide)
    if h < 0 or tl.done(h) then return end
    local due = tl.fxDue(h, now)
    -- a grab frame keeps the 1.4.2 timing: rolled out of as soon as it is inside
    -- PARRY_WINDOW (its frame comes ~0.01 s before the grab; grabLead 0.15 s does
    -- not survive a later press)
    if tl.grabFrame() and (not due or due <= PARRY_WINDOW) then
        dodged[h] = os.clock()
        tl.grabDodge(input, h, now, "announced")
        return
    end
    if due then
        if due > lead then return end -- too early: a later tick presses
    elseif wide > PARRY_WINDOW and nearest(deflect, false, PARRY_WINDOW) < 0 then
        -- the game did not set this hit's time: never press earlier than 1.4.2 did
        return
    end
    if due and settings.busySkip and due > 0.12 and os.clock() >= (tl.stunUntil or 0)
        and tl.playerBusy(currentPawn) then
        tl.led("parry h=%d: waiting %.0fms (the player is locked in his own move)", h, due * 1000)
        return
    end
    parried[h] = os.clock()
    if os.clock() < tl.noTapUntil then
        attackLog("  -> parry handle=%d skipped: rolling out of a black flash", h)
        return
    end
    -- the late-attack hook may have just held the deflect key: the tap would be
    -- no new press (test10j: 4 of 10 such taps hit vs 11 of 73 others)
    if tl.releaseHeldKey then tl.releaseHeldKey() end
    -- 1.6.7: while a counter holds its stance a guard tap may go out for the same
    -- announced hit. It is not suppressed here (that would change the 1.6.6 path
    -- without evidence), but it is recorded: the next play test can tell whether
    -- the counter still comes out with a tap in the way.
    if tl.counterHold then
        tl.counterTaps = (tl.counterTaps or 0) + 1
        if tl.counterTaps <= 5 then tl.led("counter: a guard tap went out inside the counter window (h=%d)", h) end
    end
    if tapParry(h, now) then return end
    if parryWorks then
        tryParry(input, parryWorks, h, now)
        return
    end
    for _, try in ipairs(PARRY_TRIES) do
        if tryParry(input, try, h, now) then
            parryWorks = try
            log("parry: using %s with %s", try.tag, try.action)
            return
        end
    end
end

-- ---------------------------------------------------------------- auto dodge
local dodgeFailed = false


-- A dodge pressed while the character is still in the previous dodge, a dash
-- or its own attack is dropped by the game (AutoPerfectDefense 1.0.8: a dodge
-- avoids hits 0.04-0.24 s after the press). DODGE_CHECK s after a press the
-- player's montage is read: still the one from before the press (same name,
-- position going on) means no dodge came out, and it is pressed again, every
-- DODGE_CHECK s, up to DODGE_RETRIES times while DODGE_WITHIN s since the
-- first press have not passed.
tl.DODGE_CHECK, tl.DODGE_RETRIES, tl.DODGE_WITHIN = 0.06, 2, 0.25
-- A dodge does not come out of a raised guard, and give mode keeps the guard
-- up 0.6 s after each tap (1.4.1 test 19:05: all 7 red-orb dodges pressed
-- with the stance on, none came out; 18:36, stance off: 5 of 5 did). The
-- guard is dropped first (as for black flashes) and the dodge pressed
-- DODGE_AFTER_GUARD s later, from tickGuardRelease.
tl.DODGE_AFTER_GUARD = 0.03
tl.ROLL, tl.ROLL_LEAD, tl.ROLL_HOLD, tl.rollSide = true, 0.1, 0.35, 1
-- the dodge key sends IA_Dodge and IA_PerfectDodge (pressed) and holds
-- IA_DodgeHold (AutoPerfectDefense 1.0.8); 1.4.1 sent IA_Dodge alone
tl.DODGE_HOLD, tl.dodgeHoldUntil = 0.05, 0
local function dodge(input, kind, h, now, retry)
    local action = obj("/PBZDeflectSystem/Input/IA_Dodge.IA_Dodge")
    if not action then return end
    -- a parry press still waiting for its key gap would raise the guard again
    if tl.tapPending then tl.tapPending = nil attackLog("  -> waiting parry press dropped: %s", kind) end
    -- a black flash rolled out of: no parry press right after it. YuCong
    -- Wuli_Skill_04_Hard lists a parried hit at the same 2.341 as its black
    -- flash; that press 0.03 s after the roll turned it into a deflect
    -- (AM_Hun_Tang_DF_L) every cast (1.4.2 test 01:40-01:41)
    if type(kind) == "string" and kind:find("black flash", 1, true) then tl.noTapUntil = os.clock() + tl.NO_TAP_AFTER_BLACK end
    -- the give-mode tag holds the guard, and a dodge does not come out of it
    -- (1.4.2 test 01:33:25: low Sha-chi tag, then "guard still up" at the
    -- learned Attack_08 dodge, -341): a dodge ends the tag window
    if os.clock() < tl.tagUntil then
        tl.tagUntil = 0
        attackLog("  -> give perfect tag window ended: %s", kind)
        if tl.tickPerfectNow and valid(currentPawn) then pcall(tl.tickPerfectNow, currentPawn) end
    end
    -- roll sideways: with no move input the dodge is a step back (1.4.1 test:
    -- AM_Hun_Long_Dodge_B, "the character does not roll"). The stick is pushed
    -- left or right of the camera (alternating) ROLL_LEAD s before the press.
    if not retry and tl.ROLL and tl.moveDir and valid(currentPawn) and not (tl.moveBusy and tl.moveBusy()) then
        local okY, yaw = pcall(RT.yawOf, currentPawn)
        if okY and yaw then
            tl.rollSide = -tl.rollSide
            tl.moveDir(currentPawn, { -math.sin(yaw) * tl.rollSide, math.cos(yaw) * tl.rollSide }, os.clock() + tl.ROLL_LEAD + tl.ROLL_HOLD)
            if tl.stanceUp and tl.stanceUp(currentPawn) then
                if tl.releaseHeldKey then pcall(tl.releaseHeldKey) end
                if endStance then pcall(endStance, currentPawn, "dodge coming") end
            end
            tl.dodgeDefer = { input = input, kind = kind, h = h, at = os.clock() + tl.ROLL_LEAD,
                note = tl.rollSide > 0 and " (roll right)" or " (roll left)" }
            tl.lastDodge, tl.lastDodgeAt = kind, os.clock()
            return
        end
    end
    if not retry and tl.stanceUp and valid(currentPawn) and tl.stanceUp(currentPawn) then
        if tl.releaseHeldKey then pcall(tl.releaseHeldKey) end
        if endStance then pcall(endStance, currentPawn, "dodge coming") end
        tl.dodgeDefer = { input = input, kind = kind, h = h, at = os.clock() + tl.DODGE_AFTER_GUARD }
        tl.emit("dodge_defer", kind, h, 1)
        tl.lastDodge, tl.lastDodgeAt = kind, os.clock()
        return
    end
    tl.lastDodge, tl.lastDodgeAt = kind, os.clock()
    tl.lastDodgePress = os.clock() -- 1.4.3: dodge_gap / i-frames of this press
    local st = retry ~= true and tl.montageState and valid(currentPawn) and tl.montageState(currentPawn) or nil
    local ok = activate(input, kind, h, now, function()
        return input:TryActivateExternalActionAbilityInterruptLowerByTag(tag("Ability.Action.Hun.PerfectDodge"), action, -5)
    end)
    if not ok then
        activate(input, kind .. " key", h, now, function()
            -- the dodge injection asks the same rules as the guard (audit P1-4)
            local okK = tl.input.inject("dodge_press", action)
            local pd = inputAction("IA_PerfectDodge")
            if pd then pcall(tl.input.inject, "dodge_press", pd) end
            tl.dodgeHoldUntil = os.clock() + tl.DODGE_HOLD
            return okK
        end)
    end
    tl.emit("dodge", kind, h, ok and 1 or 0)
    if DEBUG and tl.sprintHeld then
        local okS, held = pcall(tl.sprintHeld)
        if okS and held then attackLog("  (the player holds the dodge/sprint key: an injected dodge may not count as a new press)") end
    end
    if retry == true or not tl.montageState or not valid(currentPawn) then return end
    tl.dodgeWatch = { input = input, kind = kind, h = h, first = os.clock(), at = os.clock(), tries = 0,
        name = st and st.name, pos = st and st.pos }
end
tl.dodgeFn = dodge
-- montages a retry cannot help with: already dashing / dodging (the press
-- came out, or a dodge is under way), or knocked back by a hit (1.4.1 test:
-- 3 retries each on Hun_TangBlade_Dash_* and Hun_LongBlade_Hit_*)
tl.NO_RETRY = { "Dash", "Dodge", "_Hit_" }
tl.tickDodgeWatch = function(pawn)
    local w = tl.dodgeWatch
    local t = os.clock()
    if not w or t - w.at < tl.DODGE_CHECK then return end
    local st = tl.montageState(pawn)
    local name, pos = st and st.name, st and st.pos
    local same = name == w.name and (not pos or not w.pos or pos >= w.pos - 0.05)
    if same and name then
        for _, pat in ipairs(tl.NO_RETRY) do
            if name:find(pat, 1, true) then same = false break end
        end
    end
    if not same then
        tl.dodgeWatch = nil
        if w.tries > 0 then attackLog("  -> dodge came out after %d retr%s (%s)", w.tries, w.tries == 1 and "y" or "ies", w.kind) end
        -- what the press played (user, 1.4.1 test: "the character does not roll")
        if DEBUG then attackLog("  -> after the dodge press: montage %s (before: %s)", tostring(name), tostring(w.name)) end
        return
    end
    if w.tries >= tl.DODGE_RETRIES or t - w.first >= tl.DODGE_WITHIN or not valid(w.input) then
        tl.dodgeWatch = nil
        tl.dodgeFailAt = t
        attackLog("  -> dodge did not come out (%s, montage %s), %d retr%s", w.kind, tostring(name), w.tries,
            w.tries == 1 and "y" or "ies")
        return
    end
    w.tries, w.at = w.tries + 1, t
    tl.dodgeRetries = (tl.dodgeRetries or 0) + 1
    if tl.dodgeRetries <= 100 then
        log("dodge did not come out (montage %s): pressed again (#%d, %s)", tostring(name), w.tries, w.kind)
    end
    dodge(w.input, string.format("%s retry #%d", w.kind, w.tries), w.h, t, true)
end

tl.grabDodge = function(input, h, now, how)
    tl.grabDone = tl.grabAt
    -- learn when this grab's frame comes (the earliest seen)
    local d = os.clock() - tl.grabAt
    if how ~= "timed" and (not tl.grabTimes[tl.grabName] or d < tl.grabTimes[tl.grabName]) then
        tl.grabTimes[tl.grabName] = d
    end
    dodge(input, string.format("dodge(grab %s, %s, +%.2fs)", (tl.grabName:gsub("^GA_", ""):gsub("_C$", "")), how,
        os.clock() - tl.grabAt), h, now)
end

local function tickDodge(deflect, input, now)
    if settings.dodge == "off" or (dodgeFailed and os.clock() < dodgeFailed) then return end
    -- a special (black flash) attack is a normal-query hit that must be dodged
    local kinds = (settings.dodge == "all" or specialActive()) and RT.kindsAll or RT.kindsRed
    -- 1.4.3 (PBZAssist timing.dodge_lead_ms): the window is the lead the press
    -- needs plus the roll lead dodge() defers by, so the press lands dodge_lead
    -- before the hit (0.16 with a 0.1 s roll left 0.06 s of margin, and the roll
    -- and the guard drop eat into it)
    local window = tl.dodgeLead() + (tl.ROLL_LEAD or 0)
    for _, isDodge in ipairs(kinds) do
        local h = nearest(deflect, isDodge, window)
        if h >= 0 and not tl.done(h) and isDodge and tl.hitSoon then
            dodged[h] = os.clock()
            tl.redAt = os.clock()
            tl.led("dodge h=%d red: left to the timeline dodge", h)
            attackLog("  -> red handle=%d at %.2f: left to the timeline dodge", h, now)
        elseif h >= 0 and not tl.done(h) then
            local due = tl.fxDue(h, now)
            if tl.dodgeCovered(os.clock(), due) then
                -- the last dodge's i-frames take this hit: a press now would be
                -- dropped by the game (it is already avoided)
                dodged[h] = os.clock()
                tl.led("dodge h=%d: left to the dodge pressed %.0fms ago (hit in %.0fms)",
                    h, (os.clock() - tl.lastDodgePress) * 1000, (due or -1) * 1000)
            elseif not tl.dodgeReady(os.clock()) then
                -- 1.4.4 (PBZAssist 1.3.3 C1 / DashFallback): the last dodge still runs
                -- and its i-frames do not cover this hit. A parriable hit is left to
                -- tickParry (it runs after this); a red one cannot be parried and a
                -- press now would be dropped, so nothing is pressed.
                if isDodge then
                    dodged[h] = os.clock()
                    tl.led("dodge h=%d red: last dodge still running (%.0fms), not pressed", h,
                        (os.clock() - tl.lastDodgePress) * 1000)
                else
                    tl.led("dodge h=%d: last dodge still running, left to the parry", h)
                end
            else
                dodged[h] = os.clock()
                local kind = isDodge and "dodge(red)" or (special and ("dodge(" .. special.what .. ")") or "dodge(normal)")
                tl.led("dodge h=%d %s: pressing, hit in %.0fms (type %s)", h, isDodge and "red" or "normal",
                    (due or -1) * 1000, tostring(tl.fxType(h)))
                dodge(input, kind, h, now)
            end
        end
    end
end

local function tickTimedDodge(input, now)
    if not timedDodge or os.clock() < timedDodge.at then return end
    local name = timedDodge.name
    timedDodge = nil
    if settings.dodge == "off" then return end
    dodge(input, "dodge(timed " .. name:gsub("^GA_", ""):gsub("_C$", "") .. ")", -1, now)
end

-- ---------------------------------------------------------------- attack timeline
-- Every incoming hit the game announces (both queries, as soon as it is within
-- WARN_WINDOW seconds) and every health drop go to attacks_log.txt. A drop with
-- no warning before it is an attack the deflect queries do not report (black
-- flash candidates).
local WARN_WINDOW = 1.5
local warned, lastWarn = {}, nil
tl.prunable[#tl.prunable + 1] = warned -- same TTL as the handle tables (audit P2-10)
-- object name without its path
local function short(o)
    if not valid(o) then return "-" end
    local ok, n = pcall(RT.fnameOf, o)
    return ok and n or "?"
end
local function trackFrames(deflect, now)
    for _, isDodge in ipairs(RT.kindsDodge) do
        local h = nearest(deflect, isDodge, WARN_WINDOW)
        if h >= 0 and (warned[h] or -1e9) <= os.clock() - tl.HANDLE_TTL then
            warned[h] = os.clock()
            lastWarn = { h = h, t = now, red = isDodge }
            lastWarnClock = os.clock()
            enemyScanWanted = true
            attackLog("incoming %s hit handle=%d at %.2f", isDodge and "RED" or "normal", h, now)
        end
    end
end

-- Frames probe (debug only, read only): every incoming hit the game keeps in
-- DeflectComponent.ReceiveFrames, with its hit time and its type at run time
-- (DeflectBulletType: Normal / BlueEye / RedEye / CantDeflect...), to see how
-- many hits it would announce, and how early, if the mod read it instead of
-- the GetNearestValidReceivedFrame queries (most hits log NO WARNING there).
-- Only numbers and strings are kept between ticks; the component and its
-- frames are read again each tick.
tl.BULLET_TYPES = { [0] = "CantDeflect", "Normal", "BlueEye", "RedEye", "PowerAttack", "HoldDeflect" }
tl.PROBE_MAX_LINES = 4000
tl.probe = { seen = {}, pawn = nil, lines = 0, errors = 0, off = false }
tl.probeAttacker = function(src)
    local cur = src
    for _ = 1, 10 do
        local ok, outer = pcall(function() return cur:GetOuter() end)
        if not ok or not valid(outer) then return "?" end
        local okC, cn = pcall(function() return short(outer:GetClass()) end)
        if okC and cn == "Level" then
            local okN, nm = pcall(function() return short(cur) end)
            return okN and nm or "?"
        end
        cur = outer
    end
    return "?"
end
tl.probeLog = function(fmt, ...)
    local pr = tl.probe
    pr.lines = pr.lines + 1
    if pr.lines <= tl.PROBE_MAX_LINES then attackLog(fmt, ...) end
    if pr.lines == tl.PROBE_MAX_LINES then attackLog("FRAME probe: %d lines, no more this session", pr.lines) end
end
tl.probeFrames = function(pawn, deflect, now)
    local pr = tl.probe
    if pr.off then return end
    local addr = pawn:GetAddress()
    if pr.pawn ~= addr then pr.pawn, pr.seen = addr, {} end
    local present = {}
    local ok, err = pcall(function()
        deflect.ReceiveFrames:ForEach(function(key, value)
            local handle = tonumber(unwrap(key:get()))
            if not handle then return end
            present[handle] = true
            local data = value:get()
            local hit = tonumber(data.HitGameTime)
            local known = hit and hit > -1e30
            local e = pr.seen[handle]
            if e and e.gone then e = nil end -- a reused handle: a new hit
            if not e then
                local okS, src = pcall(function()
                    local w = data.SourceAction
                    local okG, o = pcall(function() return w:Get() end)
                    if okG and valid(o) then return o end
                    return valid(w) and w or nil
                end)
                src = okS and src or nil
                local srcName, btype, by = "-", "-", "-"
                if src then
                    local okN, n = pcall(function() return short(src:GetClass()) end)
                    srcName = okN and n or "?"
                    for _, f in ipairs({ "DeflectBulletType", "Deflect Bullet Type" }) do
                        local okB, b = pcall(function() return src[f] end)
                        if okB and type(b) == "number" then btype = tl.BULLET_TYPES[b] or tostring(b) break end
                    end
                    by = tl.probeAttacker(src)
                end
                local okT, st = pcall(function() return data.DeflectStrength.TagName:ToString() end)
                e = { hit = known and hit or nil, first = now }
                pr.seen[handle] = e
                tl.probeLog("FRAME+ h=%d %s dodge=%s isHit=%s type=%s strength=%s src=%s by %s", handle,
                    known and string.format("hit at %.2f (in %+.2fs)", hit, hit - now) or "hit time not set",
                    tostring(data.IsDodge), tostring(data.IsHit), btype, okT and st or "?", srcName, by)
            elseif known and (not e.hit or math.abs(e.hit - hit) > 0.02) then
                tl.probeLog("FRAME~ h=%d hit at %.2f (in %+.2fs)%s", handle, hit, hit - now,
                    e.hit and string.format(", was %.2f", e.hit) or ", time now set")
                e.hit = hit
            end
        end)
    end)
    if not ok then
        pr.errors = pr.errors + 1
        tl.probeLog("FRAME probe error %d: %s", pr.errors, tostring(err))
        if pr.errors >= 5 then pr.off = true tl.probeLog("FRAME probe off after 5 errors") end
        return
    end
    for handle, e in pairs(pr.seen) do
        if not present[handle] and not e.gone then
            e.gone = true
            tl.probeLog("FRAME- h=%d gone at %.2f%s (seen %.2fs)", handle, now,
                e.hit and string.format(", hit was %.2f (%+.2fs)", e.hit, e.hit - now) or ", hit time never set", now - e.first)
        end
    end
    -- forget long-gone handles (the game reuses numbers)
    for handle, e in pairs(pr.seen) do
        if e.gone and now - e.first > 30 then pr.seen[handle] = nil end
    end
end

local hpSet, hpPawn, hpLast, hpMaxLast
local function trackHealth(pawn, now)
    local addr = pawn:GetAddress()
    if hpPawn ~= addr or not valid(hpSet) then
        -- FindAllOf walks the object table: not found, it waits 2, 4 ... 60 s
        -- before the next search (it ran every tick), tl.SEARCH_MAX searches at most
        if tl.hpAddr == addr and os.clock() < (tl.hpAt or 0) then return end
        tl.hpTries = tl.hpAddr == addr and (tl.hpTries or 0) + 1 or 1
        tl.hpAddr, tl.hpAt = addr, os.clock() + tl.searchWait(tl.hpTries)
        hpSet, hpPawn, hpLast, hpMaxLast = nil, addr, nil, nil
        local okF, all = pcall(FindAllOf, "BasicAttributeSet")
        for _, s in ipairs(okF and type(all) == "table" and all or {}) do
            local okO, outer = pcall(function() return s:GetOuter() end)
            if okO and valid(outer) and outer:GetAddress() == addr then hpSet = s break end
        end
        if not hpSet then hpPawn = nil return end
        tl.hpTries = 0
    end
    local okH, hp = pcall(RT.curOf, hpSet.Health)
    local okM, max = pcall(RT.curOf, hpSet.Health_Max)
    if not okH or type(hp) ~= "number" then return end
    max = okM and type(max) == "number" and max or nil
    if hpLast and hp < hpLast - 0.5 and not (max and hpMaxLast and max < hpMaxLast - 0.5) then
        local warn = lastWarn and now - lastWarn.t < 3
            and string.format("after %s handle=%d (%.2fs)", lastWarn.red and "RED" or "normal", lastWarn.h, now - lastWarn.t)
            or "NO WARNING"
        if hpLast - hp >= 5 then attackLog("HIT -%.0f HP at %.2f  [%s]%s%s", hpLast - hp, now, warn, tl.info ~= "" and ("  {" .. tl.info .. "}") or "", tl.tornadoNote()) end
        -- damage over time (a burn: -6 HP every 0.2 s for 3 s, 1.3.5 test WuXuan)
        -- is the same small drop again and again: one line for the streak, and
        -- it teaches no flight time (it taught WuXuan Skill_03 0.43 s)
        local amt, c = hpLast - hp, os.clock()
        local dot = amt < 30 and tl.dotAmt and math.abs(amt - tl.dotAmt) <= 1 and c - tl.dotAt < 0.5
        if dot then tl.dotN = (tl.dotN or 0) + 1
        elseif (tl.dotN or 0) > 0 then
            log("  ... and %d more drops of -%.0f HP (damage over time)", tl.dotN, tl.dotAmt)
            tl.dotN = 0
        end
        tl.dotAmt, tl.dotAt = amt, c
        if amt >= 20 and not dot then tl.learnHit = c end
        if amt > tl.LEARN_MIN and not dot and (settings.parry or settings.dodge ~= "off") then
            local okL, errL = pcall(tl.learnFromHit, amt, warn)
            if not okL then log("learn error: %s", tostring(errL)) end
        end
        -- always in auto_defense_log.txt: a named boss cannot be fought again
        -- with debug on, so every hit says which attack, the last dodge and tap
        if amt >= 5 and not dot then
            tl.hitLines = (tl.hitLines or 0) + 1
            if tl.hitLines <= 400 then
                log("hit -%.0f HP%s%s, last dodge %s, last parry %s", amt, warn == "NO WARNING" and "" or (" (" .. warn .. ")"),
                    tl.info ~= "" and (" during " .. tl.info)
                        or (tl.lastEnemy and c - tl.lastEnemyAt < 6 and string.format(" (no listed attack; last enemy ability %s %.1fs ago, %.1f m)",
                            tl.lastEnemy, c - tl.lastEnemyAt, (tl.lastEnemyDist or 0) / 100)) or " (no enemy ability in 6 s)",
                    tl.lastDodge and string.format("%.2fs ago: %s", c - tl.lastDodgeAt, tl.lastDodge) or "none",
                    lastTapAt and string.format("%.2fs ago", c - lastTapAt) or "none")
            end
        end
        local t = os.clock()
        if LEARN and warn == "NO WARNING" and t - lastBlindHit > BLIND_BURST and recentStart
            and t - recentStart.t <= BLIND_LOOKBACK then
            local delay = t - recentStart.t
            local old = learned[recentStart.name]
            if not old or delay - BLIND_LEAD < old then
                learned[recentStart.name] = math.max(0, delay - BLIND_LEAD)
                saveLearned()
            end
            attackLog("  LEARN %s: blind hit %.2fs after it started (dodge at %.2fs)", recentStart.name, delay,
                learned[recentStart.name])
        end
        -- 1.5.0: a hit that lands may leave the player stunned (game data stun, from
        -- his own hit montage): a dodge pressed inside that window does not come out
        if hpLast - hp >= 5 then
            local pm = tl.montageState and tl.montageState(currentPawn)
            local sm = tl.dat and tl.dat.stunOf and tl.dat.stunOf(pm and pm.name)
            tl.stunUntil = t + math.max(0.15, math.min(1.0, sm or 0.35))
            if tl.led then tl.led("hit taken: stun %.2fs (%s)", tl.stunUntil - t, sm and "data" or "0.35 default") end
        end
        if warn == "NO WARNING" and hpLast - hp >= 20 then lastBlindHit = t end
        lastHitClock = t
    end
    hpLast, hpMaxLast = hp, max
end

-- ---------------------------------------------------------------- abilities
-- UGameplayAbility.IsActive is not callable from Lua; the bIsActive flag is
-- read instead (nil when it cannot be read).
local function abilityActive(ab)
    local ok, v = pcall(function() return ab.bIsActive end)
    if ok and type(v) == "boolean" then return v end
    return nil
end

local gaClass
local function gameplayAbilityClass()
    if not valid(gaClass) then gaClass = StaticFindObject("/Script/GameplayAbilities.GameplayAbility") end
    return valid(gaClass) and gaClass or nil
end

local function avatarOf(ab)
    local ok, actor = pcall(function() return ab:GetAvatarActorFromActorInfo() end)
    return ok and valid(actor) and actor or nil
end

-- the montage an enemy is playing now: its name, position (s) and play rate.
-- The hit times in hit_times.txt are timeline seconds, and the ability's
-- timeline plays its montage from 0 at the same pace, so the montage position
-- says where the attack is, whatever the play rate, the detection delay, or a
-- shortened variant (GA_X_Short) that starts the montage further in.
local function montageState(actor)
    local ok, r = pcall(function()
        local anim = actor.Mesh:GetAnimInstance()
        if not valid(anim) then return nil end
        local m = anim:GetCurrentActiveMontage()
        if not valid(m) then return nil end
        return { name = short(m), pos = tonumber(unwrap(anim:Montage_GetPosition(m))),
            rate = tonumber(unwrap(anim:Montage_GetPlayRate(m))) }
    end)
    return ok and r or nil
end
tl.montageState = montageState

-- An attack on someone else is left alone (1.3.1 report: Mount Soulrend, Last
-- Mandate Encampment bell: a friendly NPC fighting mobs kept the player's guard
-- up from afar, no bell, no jump). Within tl.close everything counts; farther
-- away only an attacker facing the player within acos(tl.facing).
tl.close, tl.facing = 600, 0.34
tl.towardPlayer = function(actor, pawn, dist)
    if dist <= tl.close then return true end
    local ok, r = pcall(function()
        local f = actor:GetActorForwardVector()
        local a, b = actor:K2_GetActorLocation(), pawn:K2_GetActorLocation()
        local dx, dy = b.X - a.X, b.Y - a.Y
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 1 then return true end
        return (f.X * dx + f.Y * dy) / len >= tl.facing
    end)
    return not ok or r == true
end

-- The distance is checked when an attack starts (up to TL_NEAR, 60 m: lunges);
-- a melee attack started from afar that never closes in was still parried at
-- its listed hit (1.3.5 report: guard up before the enemy was in reach). At
-- the tap the attacker must be within settings.parryReach, unless the game
-- announced a hit (a bullet or a long reach: the game knows it will land).
-- Attackers whose hits come from afar with no frame the mod can see: their
-- orbs fly 10-17 m and their dashes close 16 m inside the hit (2026-11-03,
-- 1.4 give: YanQianSui Skill_08 / Skill_08_Short skipped at 10-17 m, 5 hits)
tl.NO_REACH = { "^GA_YanQianSui_" }
tl.outOfReach = function(q, pawn, deflect, quiet)
    local reach = (settings.parryReach or 0) * 100
    -- 1.5.0: the game data knows how far this ability really reaches (dreach)
    if settings.data and tl.dat and tl.dat.ready then
        local dr = tl.dat.reach(q.name)
        if dr and dr > 0 then reach = dr end
    end
    if reach <= 0 or not valid(q.actor) then return false end
    for _, pat in ipairs(tl.NO_REACH) do
        if q.name and q.name:find(pat) then return false end
    end
    local ok, d = pcall(function() return tonumber(unwrap(q.actor:GetDistanceTo(pawn))) end)
    if not ok or not d or d <= reach then return false end
    if deflect and nearest(deflect, false, 1.0) >= 0 then return false end
    -- a bullet frame was sent: the shot comes whatever the shooter's distance
    -- (2026-11-03: HuaShan SpecialAttack_05's wave from 10.5 m, tap skipped, -274)
    if os.clock() < (tl.bulletUntil or 0) then return false end
    if quiet then return true end
    tl.reachSkips = (tl.reachSkips or 0) + 1
    if tl.reachSkips <= 200 then
        log("parry skipped: %s is %.1f m away (parry_reach %g m)", q.name, d / 100, settings.parryReach)
    end
    return true
end

local tlStarted = {} -- ability address -> os.clock() it was last queued (hook and poll both see it)
local function queueTimeline(ab, name, actor, pawn, via)
    local base = RT.bname(name) or name
    local hits = hitTimes[base]
    if not actor or not valid(pawn) then return nil end
    local okD, dist = pcall(function() return actor:GetDistanceTo(pawn) end)
    dist = okD and tonumber(unwrap(dist)) or nil
    if not dist or dist > TL_NEAR then
        return string.format("  (timeline: too far, %s cm)", dist and string.format("%.0f", dist) or "?")
    end
    -- the blue-shield scan only looks at attackers that got this far: this mod
    -- enumerates no actors of its own outside the hook's own walk
    if tl.noteAttacker then tl.noteAttacker(actor, dist) end
    -- The reference overlay is exact actor + ability and copy-on-write. record
    -- observes candidates but cannot hand a row to the decision path; on adopts
    -- only this activation's merged list. Global hitTimes is never changed.
    local okClass, actorClass = pcall(RT.classOf, actor)
    actorClass = okClass and short(actorClass) or nil
    local merged, added, candidates = tl.seedRows(base, actorClass, dist, hits)
    if settings.seedFallback == "record" and #candidates > 0 then
        local ids = {}
        for i = 1, #candidates do ids[i] = tostring(candidates[i].id) end
        local recordKey = tostring(actorClass) .. "|" .. tostring(base) .. "|" .. table.concat(ids, ",") .. "|" .. tostring(added)
        tl.seedRecorded = tl.seedRecorded or {}
        if not tl.seedRecorded[recordKey] then
            tl.seedRecorded[recordKey] = true
            log("reference seed record: %s %s at %.0f cm, candidates %s, new %d (no action)",
                tostring(actorClass), tostring(base), dist, table.concat(ids, ","), added)
            tl.led("reference seed record: %s %s candidates %s new %d, no action",
                tostring(actorClass), tostring(base), table.concat(ids, ","), added)
        end
    elseif settings.seedFallback == "on" then
        hits = merged
    end
    if not hits or #hits == 0 then return nil end
    local a = ab:GetAddress()
    if tlStarted[a] and os.clock() - tlStarted[a] < 0.3 then return "" end
    -- the memo moves below the checks: a "too far"/"not facing" miss used to
    -- swallow the next 0.3 s of announcements (audit P2-6)
    -- an attack with a black flash is followed whichever way the enemy faces:
    -- YouLong Skill_02_JumpOut starts under water facing away and turns in
    -- the leap (2026-11-03: skipped at 11 m, -298)
    local black = false
    for _, h in ipairs(hits) do if h.t == "4" then black = true end end
    if not black and not tl.towardPlayer(actor, pawn, dist) then
        return string.format("  (timeline: not facing the player, %.0f cm)", dist)
    end
    -- the memo table is aged as a whole: one entry per ability address would
    -- otherwise accumulate for the whole session (audit P2-10)
    if os.clock() - (tl.tlStartedAt or 0) > 60 then tlStarted, tl.tlStartedAt = {}, os.clock() end
    tlStarted[a] = os.clock()
    tl.enemyAt = os.clock() -- a nearby enemy attack: the fight is still on

    local st = montageState(actor)
    -- 1.5.0: blast radius, no-signal hits and conditional unblockables from the
    -- game data (nil when the file is off or the ability is not listed)
    local D = (settings.data and tl.dat and tl.dat.ready) and tl.dat or nil
    local nsAt, radius
    if D then
        radius = D.radius(base)
        local nsList = D.ns(base)
        if nsList then
            nsAt = {}
            for j, h in ipairs(hits) do
                for _, ht in ipairs(nsList) do
                    if math.abs(ht - h[1]) <= 0.12 then nsAt[j] = true break end
                end
            end
        end
        local rb = tl.reqBlocked and tl.reqBlocked(actor, st and st.name)
        if rb and (rb == "unknown" or type(rb) == "string") then
            local copy = {}
            for j, h in ipairs(hits) do
                local c = { h[1], h[2], h[3], h[4], h[5], t = h.t }
                if rb ~= "unknown" and h.t ~= "4" and h.t ~= "5" and h.t ~= "6" then c[3] = true end
                copy[j] = c
            end
            hits = copy
            if tl.led then
                tl.led("timeline %s: %s - those hits are dodged, not parried", base,
                    rb == "unknown" and "unblockable condition unknown" or ("unblockable while " .. rb))
            end
        end
    end
    -- followed until its last listed hit is over (x1.5 for a slowed montage,
    -- +2 s), 15 s at least (a fixed 15 s cut YuZan CA_P1_Hard's last volley at
    -- 15.05 s: 1.3.5 test, hit by that bullet)
    local last = 0
    for _, h in ipairs(hits) do last = math.max(last, h[1] + h[2]) end
    -- 1.4.4 (PBZAssist defense.flurry_guard): the third and later parried hits of a
    -- chain (each within 0.25 s of two before it) are taken behind a held guard
    local flurry
    if settings.flurryGuard then
        for j, h in ipairs(hits) do
            local n = 0
            for k = 1, j - 1 do
                if hits[k][1] >= h[1] - 0.25 then n = n + 1 end
            end
            if n >= 2 and not h[3] and h.t ~= "4" then
                flurry = flurry or {}
                flurry[j] = true
            end
        end
    end
    -- 1.5.0: the game data counts the announced hits of the chain (multi): three
    -- or more parried hits are taken behind a held guard even when the listed
    -- times are further apart than the 0.25 s the signal rule wants
    if not flurry and D then
        local m = D.multi(base)
        if m and m >= 3 then
            flurry = {}
            for j, h in ipairs(hits) do
                if not h[3] and h.t ~= "4" and h.t ~= "5" and h.t ~= "6" then flurry[j] = true end
            end
        end
    end
    -- 1.5.0: an area hit whose blast radius the data knows is left alone when the
    -- player stands well outside it (still dodged when the blast covers him)
    local far
    if radius and dist and dist > radius + 150 then
        far = {}
        for j, h in ipairs(hits) do if h[4] or h[5] then far[j] = true end end
        if tl.led then
            tl.led("timeline %s: %.0f cm away, outside the %.0f cm blast - those hits left alone", base, dist, radius)
        end
    end
    tlQueue[#tlQueue + 1] = { actor = actor, name = base, t0 = os.clock(), hits = hits, m0 = st and st.name,
        flurry = flurry, far = far, nsAt = nsAt, radius = radius, life = math.max(15, last * 1.5 + 2) }
    local at = {}
    for _, h in ipairs(hits) do at[#at + 1] = string.format("%.2f", h[1]) end
    return string.format("  << timeline guard at %s (%.0f cm, %s)", table.concat(at, " "), dist, via)
end

-- ---------------------------------------------------------------- held guard
-- A deflect started by the mod never sees its key released, so the deflect
-- ability (tag Ability.Action.Stance) stays active as a held guard, which stops
-- Sát Khí from recovering. RELEASE_AFTER seconds after a tap by the mod, if the
-- player still has the Stance tag, the player's stance ability is ended. A guard
-- the player holds later (more than RELEASE_UNTIL after the tap) is left alone.
local RELEASE_AFTER, RELEASE_UNTIL = 0.3, 3.0
local stanceCache, stancePawn = nil, nil
local releasedLogged = 0

-- the player's stance ability instances (class name contains "Stance"); found
-- once per pawn by walking the object table
local function stanceAbilities(pawn)
    local addr = pawn:GetAddress()
    if stancePawn == addr and stanceCache then return stanceCache end
    local cls = gameplayAbilityClass()
    if not cls then return {} end
    local list = {}
    ForEachUObject(function(o)
        local okI, isGa = pcall(function() return o:IsA(cls) end)
        if not (okI and isGa) then return end
        local actor = avatarOf(o)
        if actor and actor:GetAddress() == addr then
            local n = short(o:GetClass())
            if n:find("Stance", 1, true) then list[#list + 1] = o end
        end
    end)
    local names = {}
    for _, o in ipairs(list) do names[#names + 1] = short(o:GetClass()) end
    log("stance abilities of the player: %s", #names > 0 and table.concat(names, ", ") or "none found")
    stanceCache, stancePawn = list, addr
    return list
end

local function hasTag(asc, t)
    local ok, has = pcall(function() return asc:HasMatchingGameplayTag(tag(t)) end)
    return ok and unwrap(has) == true
end

-- 1.5.0 (data_tags): an ability that is only unblockable while an enemy tag is up
-- (enemy_data mhit_req): while the tag is there those hits are dodged, not parried.
-- Returns the tag name, false (tag not up) or "unknown" (no tag reader / no asc).
tl.reqBlocked = function(actor, montName)
    if not (settings.data and settings.dataTags and tl.dat and tl.dat.ready) then return nil end
    local tagName = tl.dat.reqTag(montName)
    if not tagName then return nil end
    local ok, asc = pcall(function()
        local lib = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
        return lib and lib:GetAbilitySystemComponent(actor)
    end)
    if not (ok and asc and valid(asc)) then return "unknown" end
    return hasTag(asc, tagName) and tagName or false
end

local deflectKeyHeld -- defined in the stance watcher
local releaseCheck = nil -- { at, why }: look at the stance shortly after a release
local lastReleaseAt = 0
local taskFns = nil -- task class name -> { release function names }
-- 未接线 (audit P2-1): diagnostic only, no caller; kept for a task-class investigation
local function discoverTasks(abs)
    taskFns = {}
    local addrs = {}
    for _, ab in ipairs(abs) do addrs[ab:GetAddress()] = true end
    local seen = {}
    ForEachUObject(function(o)
        local okO, outer = pcall(function() return o:GetOuter() end)
        if not (okO and valid(outer) and addrs[outer:GetAddress()]) then return end
        local cls = o:GetClass()
        local cn = short(cls)
        if seen[cn] then return end
        seen[cn] = true
        local fns, all = {}, {}
        tl.try("stance functions", function()
            cls:ForEachFunction(function(fn)
                local n = fn:GetFName():ToString()
                all[#all + 1] = n
                if n:lower():find("release", 1, true) then fns[#fns + 1] = n end
            end)
        end)
        log("stance sub-object %s: functions %s", cn, #all > 0 and table.concat(all, ", ") or "(none)")
        if #fns > 0 then taskFns[cn] = fns end
    end)
    local names = {}
    for cn, fns in pairs(taskFns) do names[#names + 1] = cn .. "{" .. table.concat(fns, ",") .. "}" end
    log("release callbacks: %s", #names > 0 and table.concat(names, " ") or "none found")
end

local dumpedStance = true -- set false to dump the stance / player classes again
local function classChainDump(o, stopAt, fnFilter, label)
    local okC, cls = pcall(function() return o:GetClass() end)
    local guard = 0
    while okC and valid(cls) and guard < 15 do
        guard = guard + 1
        local cn = short(cls)
        if stopAt and cn == stopAt then break end
        local fns, props = {}, {}
        tl.try("class functions filtered", function()
            cls:ForEachFunction(function(fn)
                local n = fn:GetFName():ToString()
                if not fnFilter or fnFilter(n:lower()) then fns[#fns + 1] = n end
            end)
        end)
        tl.try("class properties", function()
            cls:ForEachProperty(function(prop)
                local n = prop:GetFName():ToString()
                local okV, v = pcall(function() return unwrap(o[n]) end)
                local t = okV and type(v) or "?"
                if t == "boolean" or t == "number" or t == "string" then
                    props[#props + 1] = n .. "=" .. tostring(v)
                elseif not fnFilter then
                    props[#props + 1] = n
                end
            end)
        end)
        log("%s class %s: functions [%s] fields [%s]", label, cn, table.concat(fns, ", "),
            fnFilter and "" or table.concat(props, ", "))
        local okS, sup = pcall(function() return cls:GetSuperStruct() end)
        if not okS then break end
        cls = sup
    end
end

-- 未接线 (audit P2-1): diagnostic only, no caller
local function dumpStance(pawn, abs)
    if dumpedStance then return end
    dumpedStance = true
    for _, ab in ipairs(abs) do classChainDump(ab, "Object", nil, "stance") end
    classChainDump(pawn, "Actor", function(n)
        return n:find("stance", 1, true) or n:find("deflect", 1, true) or n:find("guard", 1, true)
            or n:find("release", 1, true) or n:find("input", 1, true) or n:find("block", 1, true)
    end, "player")
end

local function releaseStance(pawn, why)
    if deflectKeyHeld() then return end
    local asc = ascOf(pawn)
    if not hasTag(asc, "Ability.Action.Stance") then return end
    lastReleaseAt = os.clock()
    if perfectPawn then
        perfectQuiet = true
        setPerfect(pawn, false, true)
        perfectPawn = nil
        perfectSuspendUntil = os.clock() + PERFECT_SUSPEND
    end
    local sent = {}
    for _, ab in ipairs(stanceAbilities(pawn)) do
        if valid(ab) and abilityActive(ab) ~= false then
            local okD, down = pcall(function() return unwrap(ab["Stance Key Down"]) end)
            if okD and down == true then
                local ok, err = pcall(function() ab["On Stance Key Up"](ab) end)
                sent[#sent + 1] = short(ab:GetClass()) .. (ok and "" or (" error " .. tostring(err)))
            end
        end
    end
    if #sent == 0 then stanceCache = nil end -- look again next time
    releaseCheck = { at = os.clock() + 0.15, why = why }
    attackLog("  -> key up sent (%s): %s", why, #sent > 0 and table.concat(sent, ", ") or "no stance with the key down")
end

local function checkRelease(pawn)
    if tl.guardOwned() then return end -- never let a guard PBZPerfectDefense holds go
    if not releaseCheck or os.clock() < releaseCheck.at then return end
    local still = hasTag(ascOf(pawn), "Ability.Action.Stance")
    attackLog("  -> after release (%s): stance %s, perfect tag %s", releaseCheck.why, still and "STILL ON" or "off",
        tostring(hasPerfectTag(pawn)))
    if releasedLogged < 20 then
        releasedLogged = releasedLogged + 1
        log("stance release (%s): stance %s", releaseCheck.why, still and "still on" or "off")
    end
    releaseCheck = nil
end
tl.checkRelease = checkRelease -- test seam: exposed as __CHECK_RELEASE under the marker

local RELEASE_FROM_OUTSIDE = false -- never set: releaseHeldGuard's own release path is dormant (audit P2-1)
local function releaseHeldGuard(pawn, deflect)
    checkRelease(pawn)
    if not RELEASE_FROM_OUTSIDE then lastTap = nil return end
    if not lastTap then return end
    local since = os.clock() - lastTap
    if since < RELEASE_AFTER then return end
    if since > RELEASE_UNTIL then lastTap = nil return end
    -- another hit of the combo coming: keep the stance (the next tap needs it)
    if nearest(deflect, false, 0.6) >= 0 or nearest(deflect, true, 0.6) >= 0 then return end
    lastTap = nil
    releaseStance(pawn, "after mod tap")
end

-- ---------------------------------------------------------------- guard release
-- After the mod's IA_Deflect tap the game keeps the deflect key "held" (the
-- deflect passive BP_PlayerDeflectPassive_C has Stance Key Down true), so the
-- character goes back to the guard after every action. The passive's On Stance
-- Key Release is what a real release of the key does. It is called once no new
-- tap and no announced hit for QUIET seconds, or when sprint (the dodge key) is
-- held down for SPRINT_HOLD seconds (running, not a quick dodge tap) with no hit
-- coming. Never while the player holds the deflect key.
local tickGuardRelease, tickTimelineGuard
do
    local SPRINT_QUIET = 0.6
    -- a quick tap of the sprint/dodge key is a dodge in a fight: the guard stays up.
    -- Only holding it this long (running) lowers the guard.
    local SPRINT_HOLD = 0.4
    local LOG_MAX = 20
    local logged = 0
    local passive, passivePawn = nil, nil
    local sprintKeys, sprintWasDown, sprintRetryAt = nil, false, 0
    local sprintDownAt, pressCheckedFor, blindSeen = 0, nil, 0
    local nextHookTry = 0

    local function rlog(fmt, ...)
        if logged >= LOG_MAX then return end
        logged = logged + 1
        log("guard release: " .. fmt, ...)
    end

    local function deflectPassive(pawn)
        local addr = pawn:GetAddress()
        if passivePawn == addr and valid(passive) then return passive end
        -- not found: wait longer before each new search (2, 4, 8 ... 60 s), each one
        -- walks the object table; after tl.SEARCH_MAX searches, none until a new character
        if passivePawn == addr and os.clock() < (tl.passiveAt or 0) then return nil end
        tl.passiveTries = passivePawn == addr and (tl.passiveTries or 0) + 1 or 1
        tl.passiveAt = os.clock() + tl.searchWait(tl.passiveTries)
        passive, passivePawn = nil, addr
        local okF, all = pcall(FindAllOf, "BP_PlayerDeflectPassive_C")
        for _, o in ipairs(okF and type(all) == "table" and all or {}) do
            local actor = valid(o) and avatarOf(o)
            if actor and actor:GetAddress() == addr then passive = o break end
        end
        if passive then tl.passiveTries = 0 end
        rlog("deflect passive %s", passive and "found" or "not found")
        return passive
    end
    tl.passiveOf = deflectPassive

    local function keyDown(ps)
        local ok, kd = pcall(function() return unwrap(ps["Stance Key Down"]) end)
        return ok and kd == true
    end

    local function release(pawn, why)
        local ps = deflectPassive(pawn)
        if not ps then return end
        -- a press still being injected (TAP_HOLD) would hold the key down again
        local held = tapHold ~= nil
        tapHold = nil
        if not keyDown(ps) and not held then return end
        local ok, err = pcall(function() ps["On Stance Key Release"](ps) end)
        rlog("%s: %s", why, ok and (keyDown(ps) and "key still down" or "released") or ("error " .. tostring(err)))
        attackLog("  -> guard release (%s): %s", why, ok and "ok" or tostring(err))
    end

    local function hitComing(deflect, window)
        return deflect ~= nil and (nearest(deflect, false, window) >= 0 or nearest(deflect, true, window) >= 0)
    end

    -- sprint is the dodge key held: the keys of IA_Sprint and IA_Dodge
    local function findAction(n)
        local a = inputAction(n)
        if a then return a end
        if os.clock() < (tl.actionMiss["all " .. n] or 0) then return nil end
        tl.actionMiss["all " .. n] = os.clock() + tl.MISS_RETRY
        local okF, all = pcall(FindAllOf, "InputAction")
        for _, o in ipairs(okF and type(all) == "table" and all or {}) do
            if short(o) == n then return o end
        end
        return nil
    end
    local sprintHeld
    tl.sprintHeld = function() return sprintHeld() end
    function sprintHeld()
        local cached = tl.keysCached("sprint")
        if cached ~= nil then return cached end
        local ctrl = UEHelpers.GetPlayerController()
        if not valid(ctrl) then return false end
        if sprintKeys == nil then
            if os.clock() < sprintRetryAt then return false end
            sprintKeys = {}
            local okS, sub = pcall(function()
                return obj("/Script/Engine.Default__SubsystemBlueprintLibrary"):GetLocalPlayerSubSystemFromPlayerController(ctrl,
                    obj("/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem"))
            end)
            for _, n in ipairs({ "IA_Sprint", "IA_Dodge" }) do
                local a = findAction(n)
                if a and okS and valid(sub) then
                    tl.try("sprint keys", function()
                        local keys = unwrap(sub:QueryKeysMappedToAction(a))
                        for _, k in pairs(type(keys) == "table" and keys or {}) do sprintKeys[#sprintKeys + 1] = unwrap(k) end
                    end)
                end
            end
            -- no key found: 3 tries, then sprint never lowers the guard (each try may walk the object table)
            tl.sprintTries = (tl.sprintTries or 0) + 1
            if #sprintKeys == 0 and tl.sprintTries < 3 then sprintKeys, sprintRetryAt = nil, os.clock() + 5 return false end
        end
        return tl.keysDown(ctrl, sprintKeys, "sprint")
    end

    -- Some melee attacks (LengTu scavengers and others) reach the player's deflect
    -- passive only ~0.01 s before they land, too late for the per-frame poll (the
    -- log shows them as NO WARNING). The passive then runs Try Activate Stance
    -- Ability On Frame, which raises the guard when the deflect key is held; that is
    -- why the key 1.1 left "held" blocked them. This pre-hook holds the key right
    -- there (On Stance Key Down), so the game raises the guard in the same call.
    local STANCE_FRAME_FN = "/PBZDeflectSystem/Abilities/BP_PlayerDeflectPassive.BP_PlayerDeflectPassive_C"
        .. ":Try Activate Stance Ability On Frame"
    local function onStanceFrame(ctx, _handleP, frameP)
        -- also while running: holding sprint must not let the hit through
        if not settings.parry or tl.cutWhy or deflectKeyHeld() then return end
        if tl.blackDodge() and os.clock() < (tl.blackUntil or 0) then return end
        local ps = ctx:get()
        if not valid(ps) or (valid(passive) and ps:GetAddress() ~= passive:GetAddress()) then return end
        local okD, isDodge = pcall(function() return unwrap(frameP:get().IsDodge) end)
        if okD and isDodge == true then return end -- red: dodged, not parried
        if tl.grabFrame() and valid(currentPawn) then
            local input = component(currentPawn, "Ability Input Component")
            if input then
                tl.grabDodge(input, -1, os.clock(), "late frame")
                attackLog("  -> late attack: grab, dodged")
                return
            end
        end
        if keyDown(ps) then return end
        local ok, err = pcall(function() ps["On Stance Key Down"](ps) end)
        tl.keyDownAt = os.clock()
        rlog("late attack, On Stance Key Down: %s",
            ok and (keyDown(ps) and "key down" or "key still up") or ("error " .. tostring(err)))
        attackLog("  -> late attack: stance key down %s", ok and "ok" or tostring(err))
    end
    local function hookStanceFrame()
        if RT.installed("stance frame") or os.clock() < nextHookTry then return end
        nextHookTry = os.clock() + 5
        local ok, pre, post = pcall(RegisterHook, STANCE_FRAME_FN, function(...)
            if tl.stopped then return end -- a torn-down mod must not inject input
            local t0 = settings.perf and os.clock()
            local okH, e = pcall(onStanceFrame, ...)
            if t0 then tl.perfAdd(tl.perf.hooks, os.clock() - t0) end
            if not okH then rlog("late attack hook error: %s", tostring(e)) end
        end)
        if ok then RT.rememberHook("stance frame", STANCE_FRAME_FN, pre, post) end
        rlog("late attack hook: %s", ok and "hooked" or ("not yet: " .. tostring(pre)))
    end

    -- timeline parry: a held guard does not stop these hits (test5: stance on,
    -- hit landed anyway), a deflect press at the hit does. The deflect key is
    -- tapped TL_TAP_LEAD before each listed hit start, by the attacker's montage
    -- position, unless the game announced that hit (then the normal parry has it).
    -- dodge lead 0.10 -> 0.13: test10f Scavenger P2_Skill_03 red dodged 0.08 s early, still hit
    local TL_TAP_LEAD, TL_DODGE_LEAD = 0.08, 0.23

    -- Area attacks (type 5: ground fire and other bullets that stay on the
    -- ground) cannot be parried and one dodge does not leave them: the move stick
    -- is pushed away from the attacker from AREA_MOVE_LEAD before the hit, the
    -- dodge goes that way, and while the area keeps hitting (a health drop within
    -- AREA_LINGER) the player is dodged away again, up to AREA_MAX times.
    -- A dodged hit longer than LONG_HIT (MengHua Skill_11) is dodged again every
    -- LONG_STEP seconds while it lasts.
    local AREA_MOVE_LEAD, AREA_MOVE_HOLD, AREA_LINGER, AREA_STEP, AREA_MAX = 0.20, 0.45, 2.0, 0.35, 4
    local LONG_HIT, LONG_STEP = 0.5, 0.42
    local area = nil -- { actor, name, untilT, nextAt, count, hitSeen, dodgeAt }
    local moveHold = nil -- { actor, untilT }
    local moveAction, moveLogged = nil, false

    -- the move stick pointing from the attacker to the player (Y forward, X
    -- right of the camera), and the same direction in the world
    local function awayFrom(pawn, actor)
        local ok, v = pcall(function()
            local pl, al = pawn:K2_GetActorLocation(), actor:K2_GetActorLocation()
            local dx, dy = pl.X - al.X, pl.Y - al.Y
            local len = math.sqrt(dx * dx + dy * dy)
            if len < 1 then return nil end
            dx, dy = dx / len, dy / len
            local yaw = math.rad(UEHelpers.GetPlayerController():GetControlRotation().Yaw)
            local fx, fy = math.cos(yaw), math.sin(yaw)
            return { X = dy * fx - dx * fy, Y = dx * fx + dy * fy, wx = dx, wy = dy }
        end)
        return ok and v or nil
    end

    local function pushAway(pawn)
        if not moveHold then return end
        if os.clock() >= moveHold.untilT or not valid(moveHold.actor) then moveHold = nil return end
        if moveHold.far then
            local okD, d = pcall(function() return tonumber(unwrap(moveHold.actor:GetDistanceTo(pawn))) end)
            if okD and d and d > moveHold.far then return end
        end
        local v
        if moveHold.dir then
            local wx, wy = moveHold.dir[1], moveHold.dir[2]
            local okY, yaw = pcall(function() return math.rad(UEHelpers.GetPlayerController():GetControlRotation().Yaw) end)
            if okY and yaw then
                local fx, fy = math.cos(yaw), math.sin(yaw)
                v = { X = wy * fx - wx * fy, Y = wx * fx + wy * fy, wx = wx, wy = wy }
            end
        else
            v = awayFrom(pawn, moveHold.actor)
        end
        if not v then return end
        moveAction = moveAction or findAction("IA_MoveInput") or findAction("IA_Move")
        local okI, errI = false, "no move action"
        if moveAction then
            okI, errI = pcall(function()
                local ctrl = UEHelpers.GetPlayerController()
                local sub = obj("/Script/Engine.Default__SubsystemBlueprintLibrary"):GetLocalPlayerSubSystemFromPlayerController(
                    ctrl, obj("/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem"))
                sub:InjectInputVectorForAction(moveAction, { X = v.X, Y = v.Y, Z = 0.0 }, {}, {})
            end)
        end
        local okM = pcall(function() pawn:AddMovementInput({ X = v.wx, Y = v.wy, Z = 0.0 }, 1.0, true) end)
        if not moveLogged then
            moveLogged = true
            rlog("area: move away via %s: %s, AddMovementInput: %s", moveAction and short(moveAction) or "-",
                okI and "ok" or tostring(errI), tostring(okM))
        end
    end

    tl.pushNow = function(pawn) pushAway(pawn) end
    local function moveAway(actor, untilT)
        if valid(actor) then moveHold = { actor = actor, untilT = untilT } end
    end
    -- far: no push while the player is farther than this (cm) from the actor
    tl.moveAway = function(actor, untilT, far)
        if valid(actor) then moveHold = { actor = actor, untilT = untilT, far = far } end
    end
    -- push the stick along a world direction { x, y } while actor lives
    tl.moveDir = function(actor, dir, untilT)
        if valid(actor) then moveHold = { actor = actor, untilT = untilT, dir = dir } end
    end
    -- an area / tornado walk-away is on: a dodge keeps its direction
    tl.moveBusy = function() return moveHold ~= nil and not moveHold.dir and os.clock() < moveHold.untilT end

    -- YanQianSui's bullets come blue (parried) or red (dodge only). A red one
    -- sends no deflect frame and calls no hooked function (2026-11-03: only
    -- SlowOrb_Blue was seen; Skill_06 / Skill_08 hit at 10-19 m with nothing
    -- announced). For RED_SCAN s after a YanQianSui / YuZan ability starts the
    -- bullets are looked up (tl.tickRedBullets, below).
    -- YouLong Skill_04_Hard: the tornado is on YouLong itself (0.0 m from it to
    -- its owner), so walking out does not always get away (1192 HP lost); within
    -- TORNADO_NEAR cm the player is dodged, every TORNADO_GAP s while it lasts
    tl.TORNADO_NEAR, tl.TORNADO_GAP, tl.tornadoDodgeAt = 350, 0.7, -10
    tl.tickTornado = function(pawn, now)
        local tn = tl.tornado
        if not tn or settings.dodge == "off" or now - (tl.tornadoAt or 0) > tl.TORNADO_MOVE then return end
        if now - tl.tornadoDodgeAt < tl.TORNADO_GAP then return end
        local ok, d = pcall(function() return valid(tn) and tonumber(unwrap(tn:GetDistanceTo(pawn))) or nil end)
        if not ok or not d or d > tl.TORNADO_NEAR then return end
        tl.tornadoDodgeAt = now
        local input = component(pawn, "Ability Input Component")
        if input then dodge(input, string.format("dodge(tornado %.1f m)", d / 100), -1, now) end
    end
    -- bullets are looked up every RED_EVERY s; a "Red" one that flies at the
    -- player (closing faster than RED_SPEED cm/s) is dodged within RED_NEAR cm,
    -- once per RED_GAP s (a volley is one dodge). Not when it sits on the
    -- player (closer than RED_MIN: 1.4 test, YanQianSui's SlowOrb_Red stayed at
    -- 0.0 m for seconds and never hit; one dodge per orb made the character
    -- roll nonstop and its melee hits landed in the dodges), and not while a
    -- listed hit is coming (tl.soon: the timeline parries or dodges that one).
    tl.RED_SCAN, tl.RED_EVERY, tl.RED_NEAR, tl.RED_MIN, tl.RED_SPEED, tl.RED_GAP = 4.5, 0.1, 400, 50, 100, 0.5
    -- the dodge is pressed when the orb is about RED_TTI s from the player
    -- (a dodge avoids hits 0.04-0.24 s after the press). 1.4.1 test: dodged at
    -- 2.4 m, the slow orb landed 0.9 s later, -237.
    tl.RED_TTI = 0.2
    -- off: red orbs are dodged only through the enemy skill's listed hits
    -- (hit_times.txt), not when one comes near (user, 2026-11-03)
    tl.RED_DODGE = true
    -- only a red orb within RED_CLOSE cm (and RED_TTI s) is dodged; the player
    -- handles the rest (user, 2026-11-03)
    tl.RED_CLOSE, tl.BLUE_STEER = 200, false
    tl.redScanUntil, tl.redScanAt, tl.redSeen, tl.redDodgeAt = 0, 0, {}, -10
    -- a blue orb coming in the same volley (within BLUE_NEAR cm, closing): the
    -- dodge goes sideways toward it (the part of red -> blue across the red
    -- one's path), so the red one misses and the blue one is parried when it
    -- lands (that breaks YanQianSui's Sha-chi). The stick is pushed first and
    -- the dodge pressed BLUE_LEAD s later, as for area dodges.
    tl.BLUE_NEAR, tl.BLUE_LEAD, tl.BLUE_SIDE = 800, 0.08, 0.3
    tl.MOVE_KEYS = { "W", "A", "S", "D" }
    tl.moveNote = function(pawn, dir)
        local parts = {}
        local okV, v = pcall(function() return pawn:GetVelocity() end)
        if okV and v then
            local sp = math.sqrt(v.X * v.X + v.Y * v.Y)
            if sp > 10 then
                local c = (v.X * dir[1] + v.Y * dir[2]) / sp
                parts[#parts + 1] = string.format("running %.1f m/s, %.0f deg off", sp / 100, math.deg(math.acos(math.max(-1, math.min(1, c)))))
            else
                parts[#parts + 1] = "standing"
            end
        end
        local held = {}
        tl.try("move keys", function()
            local ctrl = UEHelpers.GetPlayerController()
            for _, k in ipairs(tl.MOVE_KEYS) do
                if ctrl:IsInputKeyDown({ KeyName = FName(k) }) then held[#held + 1] = k end
            end
            local lx = ctrl:GetInputAnalogKeyState({ KeyName = FName("Gamepad_LeftX") })
            local ly = ctrl:GetInputAnalogKeyState({ KeyName = FName("Gamepad_LeftY") })
            if math.abs(lx or 0) > 0.2 or math.abs(ly or 0) > 0.2 then held[#held + 1] = string.format("stick %.1f,%.1f", lx, ly) end
        end)
        parts[#parts + 1] = #held > 0 and ("player holds " .. table.concat(held, "+")) or "no move key held"
        return table.concat(parts, ", ")
    end
    tl.blueDir = function(pawn, red, blue)
        local ok, r = pcall(function()
            local pl, rl, bl = pawn:K2_GetActorLocation(), red:K2_GetActorLocation(), blue:K2_GetActorLocation()
            local px, py = pl.X - rl.X, pl.Y - rl.Y -- the red one's path
            local pn = math.sqrt(px * px + py * py)
            if pn < 1 then return nil end
            px, py = px / pn, py / pn
            local bx, by = bl.X - rl.X, bl.Y - rl.Y
            local along = bx * px + by * py
            local sx, sy = bx - along * px, by - along * py -- across the path
            local sn = math.sqrt(sx * sx + sy * sy)
            if sn < 1 then return nil end
            -- the blue one about in line with the red one: no side to go to
            if sn / math.max(math.sqrt(bx * bx + by * by), 1) < tl.BLUE_SIDE then return nil end
            return { sx / sn, sy / sn }
        end)
        return ok and r or nil
    end
    tl.tickRedBullets = function(pawn, now)
        local pend = tl.redPending
        if pend and now >= pend.at then
            tl.redPending = nil
            local input = component(pawn, "Ability Input Component")
            if input then dodge(input, pend.what, -1, now) end
            if pend.dir and DEBUG then
                local okL, l = pcall(function() return pawn:K2_GetActorLocation() end)
                if okL and l then tl.dirCheck = { at = now + 0.4, x = l.X, y = l.Y, dir = pend.dir, before = tl.moveNote(pawn, pend.dir) } end
            end
        end
        local dc = tl.dirCheck
        if dc and now >= dc.at then
            tl.dirCheck = nil
            local okL, l = pcall(function() return pawn:K2_GetActorLocation() end)
            if okL and l then
                local dx, dy = l.X - dc.x, l.Y - dc.y
                local m = math.sqrt(dx * dx + dy * dy)
                local ang = m > 1 and math.deg(math.acos(math.max(-1, math.min(1, (dx * dc.dir[1] + dy * dc.dir[2]) / m)))) or -1
                attackLog("  toward-blue dodge: moved %.1f m, %s (at the press: %s)", m / 100,
                    ang >= 0 and string.format("%.0f deg off the blue side", ang) or "no move", dc.before or "?")
            end
        end
        if now >= tl.redScanUntil or now < tl.redScanAt or settings.dodge == "off" then return end
        tl.redScanAt = now + tl.RED_EVERY
        local okF, all = pcall(FindAllOf, "BP_PBZ_ProjectileBullet_C")
        if not okF or not all then return end
        for _, b in ipairs(all) do
            local ok, name, d = pcall(function() return short(b), tonumber(unwrap(b:GetDistanceTo(pawn))) end)
            if ok and name and d then
                local a = b:GetAddress()
                local e = tl.redSeen[a]
                if not e then
                    e = { name = name, red = name:find("Red", 1, true) ~= nil, blue = name:find("Blue", 1, true) ~= nil,
                        at = now, d = d, b = b }
                    tl.redSeen[a] = e
                    if DEBUG then attackLog("  bullet seen: %s %.1f m%s", name, d / 100, e.red and " (red: dodge)" or "") end
                end
                if e.blue then
                    e.v = (now > e.at) and (e.d - d) / (now - e.at) or 0
                    e.at, e.d, e.b = now, d, b
                end
                if e.red and not e.dodged then
                    local v = (now > e.at) and (e.d - d) / (now - e.at) or 0
                    e.at, e.d = now, d
                    if tl.RED_DODGE and d >= tl.RED_MIN and d <= tl.RED_NEAR and v >= tl.RED_SPEED and not tl.soon
                        and (d - tl.RED_MIN) / v <= tl.RED_TTI + tl.BLUE_LEAD and d <= tl.RED_CLOSE
                        and now - tl.redDodgeAt >= tl.RED_GAP then
                        e.dodged, tl.redDodgeAt = true, now
                        local blue, dir
                        for _, o in pairs(tl.redSeen) do
                            if o.blue and (o.v or 0) > 0 and o.d >= tl.RED_MIN and o.d <= tl.BLUE_NEAR and valid(o.b)
                                and (not blue or o.d < blue.d) then blue = o end
                        end
                        if blue and tl.BLUE_STEER then dir = tl.blueDir(pawn, b, blue.b) end
                        local what = string.format("dodge(red bullet %s, %.1f m%s)", name, d / 100,
                            dir and string.format(", toward blue %.1f m", blue.d / 100) or "")
                        if dir and tl.moveDir then
                            tl.moveDir(blue.b, dir, now + tl.BLUE_LEAD + 0.4)
                            tl.redPending = { at = now + tl.BLUE_LEAD, what = what, dir = dir }
                        else
                            local input = component(pawn, "Ability Input Component")
                            if input then dodge(input, what, -1, now) end
                        end
                    end
                end
            end
        end
    end

    -- Flying bursts (type 6: projectiles, e.g. Scavenger P2_CA_01) hit when they
    -- land, not at the listed spawn: the player moves away from the spawn on and
    -- is dodged after the flight time. The flight time starts at TRAVEL_DEFAULT
    -- (test10b log: spawn 2.355 -> hit +0.48) and is learned per ability from
    -- the first health drop after a spawn.
    -- Flight times differ a lot (test10h: P2_CA_01 0.62 s, P2_CA_04 2.07 s), so
    -- each spawn gets two dodges, TRAVEL_SECOND apart, around the expected hit;
    -- the stick is pushed away from the attacker just before the first.
    local TRAVEL_DEFAULT, TRAVEL_MOVE, TRAVEL_MERGE, TRAVEL_SECOND, TRAVEL_MAX = 0.5, 0.6, 0.35, 0.3, 3.0
    -- FemaleThug's molotov flies in an arc: 1.43 s learned in game (1.3.5 test,
    -- the default 0.5 s dodge was hit by the first bottle every session)
    local travelDelay = { GA_Scavenger_P2_CA_01 = 0.6, GA_Scavenger_P2_CA_04 = 2.07, -- spawn to hit, s
        GA_FemaleThug_Throw_Molotov_RangeAttack_01 = 1.43, GA_FemaleThug_Throw_Molotov_RangeAttack_01_Story = 1.43 }
    -- what the mod learns is kept in learned_flight.txt for the next sessions
    -- (a named boss comes back only in the next playthrough). Not in the zip:
    -- an update keeps it; delete a line or the file to forget.
    tl.FLIGHT_FILE = MOD_DIR .. "learned_flight.txt"
    do
        local f = io.open(tl.FLIGHT_FILE, "r")
        if f then
            local n = 0
            for raw in f:lines() do
                local k, v = raw:gsub("\r", ""):match("^%s*([%w_]+)%s*=%s*([%d%.]+)")
                v = tonumber(v)
                if k and v and v >= 0.25 and v < TRAVEL_MAX then travelDelay[k], n = v, n + 1 end
            end
            f:close()
            log("learned flight times: %d read from learned_flight.txt", n)
        end
    end
    tl.saveFlight = function(name)
        tl.flightLearned = tl.flightLearned or {}
        tl.flightLearned[name] = true
        -- the file keeps every learned name: read it back, then write it with this one
        local keep = {}
        local f = io.open(tl.FLIGHT_FILE, "r")
        if f then
            for raw in f:lines() do
                local k = raw:gsub("\r", ""):match("^%s*([%w_]+)%s*=")
                if k then keep[k] = true end
            end
            f:close()
        end
        for k in pairs(tl.flightLearned) do keep[k] = true end
        f = io.open(tl.FLIGHT_FILE, "w")
        if not f then return end
        f:write("# enemy ability = seconds from the projectile's listed spawn to the hit\n")
        f:write("# learned by the mod from the health drop after a spawn; delete a line (or the file) to forget it\n")
        local names = {}
        for k in pairs(keep) do if travelDelay[k] then names[#names + 1] = k end end
        table.sort(names)
        for _, k in ipairs(names) do f:write(string.format("%s = %.2f\n", k, travelDelay[k])) end
        f:close()
    end
    local travels = {} -- { name, actor, spawn, at, dodged, moved, learned }
    local function travelAdd(name, actor, now, len)
        local first = now + (travelDelay[name] or TRAVEL_DEFAULT) - TL_DODGE_LEAD
        local ats = { first, first + TRAVEL_SECOND }
        -- a burst listed with a duration of about a second (GuiChai Red P2_CA_01:
        -- 1.0 s, a hit landed 1.4 s after the spawn) also gets a dodge at its end
        if len and len >= 0.5 and len <= 1.2 and now + len - TL_DODGE_LEAD > ats[2] + 0.15 then
            ats[3] = now + len - TL_DODGE_LEAD
        end
        for _, at in ipairs(ats) do
            -- a volley (AHua Skill_01 spawns 7 in 0.4 s) is one dodge; the two
            -- dodges of one spawn were merged too (TRAVEL_MERGE > TRAVEL_SECOND)
            local dup = false
            for _, e in ipairs(travels) do if e.spawn ~= now and math.abs(e.at - at) < TRAVEL_MERGE then dup = true end end
            if not dup then travels[#travels + 1] = { name = name, actor = actor, spawn = now, at = at } end
        end
    end
    local function tickTravel(pawn, now)
        -- the oldest spawn not yet learned takes the health drop (the next
        -- spawn of a burst can come before the previous one lands)
        -- one hit teaches one spawn (1.3.5 test: one -57 HP hit taught Qishu_Lei
        -- three times, a tick each), and none when a listed hit of a queued attack
        -- (not a flying one) was landing then: that one hit (Lei MoveAttack_F)
        local hitAt = tl.learnHit or 0
        if hitAt == tl.learnUsed then hitAt = -1e9 end
        if hitAt > 0 then
            for _, q in ipairs(tlQueue) do
                local t = hitAt - q.t0
                for _, h in ipairs(q.hits) do
                    if not h[5] and t >= h[1] - 0.35 and t <= h[1] + h[2] + 0.35 then hitAt, tl.learnUsed = -1e9, tl.learnHit end
                end
            end
        end
        for _, e in ipairs(travels) do
            -- a real hit only (20 HP or more, not damage over time)
            local got = hitAt - e.spawn
            if not e.learned and got >= 0.25 and got < TRAVEL_MAX and not (area and tl.learnHit < area.untilT) then
                for _, o in ipairs(travels) do if o.spawn == e.spawn and o.name == e.name then o.learned = true end end
                local old = travelDelay[e.name]
                travelDelay[e.name] = old and (old * 0.5 + got * 0.5) or got
                attackLog("  -> flying %s: hit %.2fs after spawn, flight time now %.2f", e.name, got, travelDelay[e.name])
                log("learned: %s flies %.2f s (hit %.2f s after the spawn), saved", e.name, travelDelay[e.name], got)
                tl.try("saveFlight", tl.saveFlight, e.name)
                tl.learnUsed = tl.learnHit
                break
            end
        end
        for i = #travels, 1, -1 do
            local e = travels[i]
            if not e.moved and now >= e.at - 0.2 then
                e.moved = true
                moveAway(e.actor, now + TRAVEL_MOVE)
            end
            if not e.dodged and now >= e.at then
                e.dodged = true
                local input = settings.dodge ~= "off" and component(pawn, "Ability Input Component")
                if input then dodge(input, string.format("flying dodge %s (+%.2fs)", e.name, now - e.spawn), -1, now) end
            end
            if now - e.spawn > TRAVEL_MAX + 0.5 then table.remove(travels, i) end
        end
    end

    -- after an area dodge: dodge away again while the area keeps hitting
    local function tickArea(pawn, now)
        pushAway(pawn)
        -- a grab whose frame time is known: dodged before the frame; the frame
        -- itself still gets its own dodge
        if tl.grabDodgeAt and tl.grabDodgeAt[1] and now >= tl.grabDodgeAt[1] then
            table.remove(tl.grabDodgeAt, 1)
            local input = settings.dodge ~= "off" and component(pawn, "Ability Input Component")
            if input then
                dodge(input, string.format("dodge(grab %s, timed, +%.2fs)", (tl.grabName:gsub("^GA_", ""):gsub("_C$", "")),
                    now - tl.grabAt), -1, now)
            end
        end
        tickTravel(pawn, now)
        if not area then return end
        if now >= area.untilT or settings.dodge == "off" then area = nil return end
        -- 1.4.2: a long area (final boss Skill_19, a ~5 s sword rain) kept hitting
        -- after the 4 rolls of its first 1.4 s (32 hits). Running away all along
        -- did not help (still hit at 12 m: the swords follow the player); the
        -- hits fell between rolls (~0.2 s safe each, the next roll only after a
        -- hit + AREA_STEP). So: roll on a beat, AREA_RHYTHM apart, while the
        -- area lasts and for AREA_LONG_KEEP s after each hit, no waiting for a hit
        if area.long and not area.dodgeAt and area.count < tl.AREA_MAX_LONG and now >= area.nextAt
            and (now < (area.hitEnd or 0) or now - lastHitClock < tl.AREA_LONG_KEEP) then
            area.count, area.nextAt, area.hitSeen = area.count + 1, now + tl.AREA_RHYTHM, lastHitClock
            area.untilT = math.max(area.untilT, now + AREA_LINGER)
            moveAway(area.actor, now + AREA_MOVE_HOLD)
            area.dodgeAt = now + 0.05
            return
        end
        if area.dodgeAt then
            if now < area.dodgeAt then return end
            area.dodgeAt = nil
            local input = component(pawn, "Ability Input Component")
            if input then dodge(input, string.format("area dodge again %s (%d)", area.name, area.count), -1, now) end
            return
        end
        if lastHitClock > area.hitSeen and now >= area.nextAt and area.count < (area.long and tl.AREA_MAX_LONG or AREA_MAX) then
            area.hitSeen, area.count, area.nextAt = lastHitClock, area.count + 1, now + AREA_STEP
            area.untilT = math.max(area.untilT, now + AREA_LINGER)
            -- the stick first, the dodge a moment later so it goes that way
            moveAway(area.actor, now + AREA_MOVE_HOLD)
            area.dodgeAt = now + 0.05
        end
    end

    tickTimelineGuard = function(pawn, deflect)
        local now = os.clock()
        tickArea(pawn, now)
        tl.try("tickGuardBreak", tl.tickGuardBreak, pawn, now)
        tl.tickRedBullets(pawn, now)
        tl.tickTornado(pawn, now)
        if #tlQueue == 0 then tl.hitSoon, tl.soon = false, false return end
        local tapFor, dodgeFor, areaFor = nil, nil, nil
        local soon = false
        for i = #tlQueue, 1, -1 do
            local q = tlQueue[i]
            local st = valid(q.actor) and montageState(q.actor) or nil
            -- the attack's own montage: the first one that is not the montage
            -- playing when it started (the previous attack), or that one after 0.15 s
            if not q.m and st and (st.name ~= q.m0 or now - q.t0 > 0.15) then
                q.m = st.name
                attackLog("  %s: montage %s at %.2f, rate %.2f, %.2fs after start", q.name, st.name, st.pos or -1,
                    st.rate or -1, now - q.t0)
            end
            local t, rate, done = now - q.t0, 1, false
            if q.m and not tl.realClock[q.name] then
                if not st or st.name ~= q.m then done = true -- montage ended or replaced: attack over
                else
                    t, rate = st.pos or t, (st.rate and st.rate > 0) and st.rate or 1
                    -- how fast the position really moves (montage s per real s): the
                    -- play rate leaves out time dilation and holds (MengHua's counter
                    -- stance crawls 0.1 s of montage in 0.9 s)
                    if st.pos and q.lastPos and now > q.lastClock then
                        local v = (st.pos - q.lastPos) / (now - q.lastClock)
                        if v >= 0 and v < 5 then q.speed = q.speed and (q.speed * 0.6 + v * 0.4) or v end
                    end
                    q.lastPos, q.lastClock = st.pos, now
                    if q.speed then rate = math.max(q.speed, 0.05) end
                end
            end
            q.tapped, q.moved, q.again = q.tapped or {}, q.moved or {}, q.again or {}
            q.tNow, q.rateNow = not done and t or nil, rate -- for tl.learnFromHit
            local pending = false
            for j, h in ipairs(q.hits) do
                -- 1.6.7, off by default: a counter takes this hit instead of the
                -- dodge or the parry. The modules answer, main.lua presses: the
                -- stance is held and Triangle goes out 0.22-0.35 s before the hit,
                -- which is what the game reads as its own counter
                local countered = q.countered and q.countered[j]
                if not countered and (settings.hookCounter == "on" or settings.shieldCounter == "on") then
                    local kind = tl.counterKind(h)
                    local ttl = (h[1] - t) / rate
                    if kind and ttl > -0.05 and tl.counterTry(kind, now + ttl, now, q.actor, q, j) == "press" then
                        q.countered, q.tapped = q.countered or {}, q.tapped or {}
                        q.countered[j], q.tapped[j] = true, true
                        countered = true
                        tl.led("timeline %s@%.2f: %s counter, not dodged", q.name, h[1], kind)
                    end
                end
                if t < h[1] + h[2] then pending = true end
                if not q.tapped[j] and h[1] - t <= tl.redDefer * rate then soon = true end
                -- perfect_mode = give: a black flash (type 4) breaks a plain parry;
                -- the perfect tag goes on from BLACK_LEAD before it until it is over
                if h.t == "4" and not countered and settings.perfectMode == "give" and h[1] - t <= tl.BLACK_LEAD * rate
                    and t < h[1] + h[2] + 0.1 then
                    q.black = q.black or {}
                    if not q.black[j] then
                        q.black[j] = true
                        tl.blackLogged = (tl.blackLogged or 0) + 1
                        if tl.blackLogged <= 200 then
                            log("black flash: %s hit %.2f, %s", q.name, h[1], tl.blackDodge() and "dodge" or "perfect tag on")
                        end
                    end
                    -- capped: a hit taken slows the montage (rate near 0), and the
                    -- window then ran on and blocked every parry after it (CA_01_Mad,
                    -- 2026-11-03: 4 hits of -149 announced, none parried)
                    tl.blackUntil = math.max(tl.blackUntil or 0,
                        now + math.min((h[1] + h[2] - t) / rate, tl.BLACK_LEAD + h[2] + 0.2) + 0.3)
                    -- black_flash = dodge: no guard up until the hit. The key held
                    -- since an earlier bullet let the game raise the guard again
                    -- 0.24 s before the dodge, which then did not come out (YouLong
                    -- Skill_02_Hard out of the water, 2026-11-03, -298 and a combo)
                    -- Not while a parried hit of the same attack still comes first:
                    -- YuDing Skill_06 has one at 2.925, 0.41 s before its black
                    -- flash, and ending the stance there let it through (-274)
                    local parryFirst = false
                    for _, h2 in ipairs(q.hits) do
                        if not h2[3] and h2.t ~= "4" and h2[1] < h[1] and t < h2[1] + h2[2] + 0.05 then parryFirst = true end
                    end
                    if tl.blackDodge() and t < h[1] and not parryFirst and os.clock() >= (tl.blackEndAt or 0) then
                        tl.blackEndAt = os.clock() + 0.05
                        if tl.releaseHeldKey then pcall(tl.releaseHeldKey) end
                        if endStance then pcall(endStance, pawn, "black flash coming") end
                    end
                end
                local dodgeIt = not countered and (h[3] or (q.forced and q.forced[j]) or (h.t == "4" and tl.blackDodge()))
                    and settings.dodge ~= "off"
                if dodgeIt and h[4] and not q.moved[j] and t >= h[1] - AREA_MOVE_LEAD * rate and t < h[1] + 0.05 then
                    q.moved[j] = true
                    moveAway(q.actor, now + AREA_MOVE_HOLD)
                end
                -- a long dodged hit outlasts the dodge: dodge again into it every
                -- LONG_STEP (1.3.6 test: YouLong CA_01_Mad, 1.1 s long, hit 0.6 s
                -- after the first dodge; one second dodge came 0.67 s after it, late).
                -- Counted in real seconds: the montage clock ran unevenly there and
                -- a step of LONG_STEP * rate came 0.71 s late, after the hit
                if dodgeIt and not h[4] and not h[5] and h[2] >= LONG_HIT and q.again[j]
                    and os.clock() >= q.again[j] and t < h[1] + h[2] then
                    q.again[j] = os.clock() + LONG_STEP
                    dodgeFor = dodgeFor or string.format("%s@%.2f for %.2f+%.2f (long hit, again)", q.name, t, h[1], h[2])
                end
                -- 1.4.3: a parried hit the game announces too is pressed once, by
                -- the frame handler at the hit's own time (a second press here was
                -- inside TAP_GAP: dropped, or a re-press)
                -- paired only when tickParry would really press: a black flash
                -- (no press until blackUntil) or a paused parry would otherwise
                -- leave this hit to nobody
                -- 1.4.4: a flurry's third and later hits are taken behind a held
                -- guard instead of a tap each (PBZAssist defense.flurry_guard): every
                -- tap inside TAP_GAP is no new press, and the chain shortens the window
                if not dodgeIt and not q.tapped[j] and t >= h[1] - TL_TAP_LEAD * rate
                    and q.flurry and q.flurry[j] then
                    q.tapped[j] = true
                    tl.try("holdGuard", tl.holdGuard, now + (h[1] + h[2] - t) / rate + 0.15, q.name)
                elseif not dodgeIt and not q.tapped[j] and t >= h[1] - TL_TAP_LEAD * rate
                    and settings.parry and not (parryFailed and os.clock() < parryFailed)
                    and not (settings.dodge ~= "off" and specialActive())
                    and not (tl.blackDodge() and os.clock() < (tl.blackUntil or 0))
                    and not (q.nsAt and q.nsAt[j])
                    and tl.pairTimeline(q.name, (h[1] - t) / rate, nowOf(pawn)) then
                    q.tapped[j] = true
                    tl.led("timeline %s@%.2f: paired with the announced frame, not pressed", q.name, h[1])
                elseif h.seed and not q.tapped[j]
                    and t >= h[1] - TL_DODGE_LEAD * math.min(rate, 1)
                    and tl.pairTimeline(q.name, (h[1] - t) / rate, nowOf(pawn)) then
                    -- A real ReceiveFrame is stronger evidence than a reference seed.
                    -- Let the normal frame path own this hit instead of pressing twice.
                    q.tapped[j] = true
                    tl.led("timeline %s@%.2f (reference seed): paired with the announced frame, not pressed", q.name, h[1])
                elseif dodgeIt and h[5] then
                    if not q.tapped[j] and t >= h[1] then
                        q.tapped[j] = true
                        if t < h[1] + 0.3 then travelAdd(q.name, q.actor, now, h[2] / rate) end
                    end
                -- 1.4.2: the dodge lead counts the montage speed at most 1. A montage
                -- that jumps ahead reads as fast and the dodge came early: ZuoShang
                -- Skill_18 (final boss) after its black flash, pressed at 1.98 /
                -- 2.04 for 2.385, 0.6 real s before the hit (the montage then
                -- slowed to ~0.65), -1152 twice. A real fast montage dodges ~0.05 s later.
                elseif not q.tapped[j] and t >= h[1] - (dodgeIt and TL_DODGE_LEAD * math.min(rate, 1) or TL_TAP_LEAD * rate) then
                    q.tapped[j] = true
                    if dodgeIt and h[2] >= LONG_HIT then q.again[j] = os.clock() + LONG_STEP end
                    -- already past this hit (detected late): nothing
                    if t < h[1] + math.max(h[2], 0.05) then
                        local what = string.format("%s@%.2f for %.2f", q.name, t, h[1])
                        if h.seed then what = what .. " (reference seed)" end
                        if dodgeIt and h.t == "4" then
                            -- the key the passive still holds keeps the guard up, and a
                            -- dodge does not come out of a raised guard
                            what = what .. " (black flash)"
                            if tl.releaseHeldKey then pcall(tl.releaseHeldKey) end
                        end
                        if dodgeIt then dodgeFor = dodgeFor or what
                        elseif not tl.outOfReach(q, pawn, deflect) then tapFor = tapFor or what
                        else q.far = q.far or {} q.far[j] = true end
                        if dodgeIt and h[4] and not areaFor then
                            areaFor = { actor = q.actor, name = q.name, untilT = now + h[2] / rate + AREA_LINGER,
                                long = h[2] >= tl.AREA_LONG, hitEnd = now + h[2] / rate }
                        end
                    end
                end
            end
            -- a hit skipped as out of reach is parried after all if the attacker
            -- comes into reach while it lasts (1.3.5 test: YanQianSui
            -- SpecialAttack_03, 0.5 s long, skipped at 11 m, then hit)
            if q.far then
                for j, h in ipairs(q.hits) do
                    if q.far[j] and (t >= h[1] + h[2] or not tl.outOfReach(q, pawn, deflect, true)) then
                        q.far[j] = nil
                        if t < h[1] + h[2] then
                            tapFor = tapFor or string.format("%s@%.2f for %.2f (came into reach)", q.name, t, h[1])
                            log("parry after all: %s came into reach at %.2f (hit %.2f+%.2f)", q.name, t, h[1], h[2])
                        end
                    end
                end
            end
            if i == #tlQueue then tl.info = string.format("%s@%.2f", q.name, t) end
            if done or not pending or now - q.t0 > q.life then
                table.remove(tlQueue, i)
                if #tlQueue == 0 then tl.info = "" end
            end
        end
        tl.soon = soon
        tl.hitSoon = soon and settings.dodge ~= "off"
        -- a red hit the game announced is dodged here, at the listed hit
        -- (the announced frame is gone from the queries once its own time passed)
        if tapFor and settings.dodge ~= "off" and (now - tl.redAt < 1.0
            or (deflect and nearest(deflect, true, 1.0) >= 0)) then
            tl.redAt = -10
            dodgeFor, tapFor = tapFor .. " (announced red)", nil
        end
        if dodgeFor then
            local input = component(pawn, "Ability Input Component")
            if input then dodge(input, "timeline dodge " .. dodgeFor .. (areaFor and " (area)" or ""), -1, now) end
            if areaFor then
                -- one roll did not leave LengTu's ground fire (test10j: 5 ticks
                -- after it): a second roll away follows AREA_STEP later
                areaFor.count, areaFor.hitSeen = 2, lastHitClock
                areaFor.dodgeAt, areaFor.nextAt = now + AREA_STEP, now + 2 * AREA_STEP
                area = areaFor
                moveAway(areaFor.actor, now + AREA_STEP + AREA_MOVE_HOLD)
            end
            return
        end
        if tl.guardOwned() then return end -- the guard is PBZPerfectDefense's (its AutoGuard holds it)
        if not tapFor or deflectKeyHeld() then return end
        -- an announced hit was tapped when announced, which can be 0.2-0.3 s
        -- before it lands (test10j: YuDing Skill_03, MengHua HeavyAttack_02,
        -- GuiChai Skill_01 hit through it): tap again at the listed hit unless
        -- that tap was just now
        if lastTapAt and now - lastTapAt < 0.15 then return end
        if os.clock() < tl.noTapUntil then
            if tl.noTapLogged ~= tapFor then
                tl.noTapLogged = tapFor
                attackLog("  -> timeline parry %s skipped: rolling out of a black flash", tapFor)
            end
            return
        end
        if hitComing(deflect, 0.15) then
            attackLog("  -> timeline %s: announced, tapped %.2fs ago, again", tapFor, lastTapAt and now - lastTapAt or -1)
        end
        -- a key the passive still holds would make the tap no new press
        local ps = deflectPassive(pawn)
        if ps and keyDown(ps) then pcall(function() ps["On Stance Key Release"](ps) end) end
        local ok = tapParry(-1, now)
        attackLog("  -> timeline parry %s: %s", tapFor, tostring(ok))
    end

    tl.releaseHeldKey = function()
        local ps = valid(currentPawn) and deflectPassive(currentPawn)
        if ps and keyDown(ps) then pcall(function() ps["On Stance Key Release"](ps) end) end
    end

    tickGuardRelease = function(pawn, deflect)
        if os.clock() < tl.dodgeHoldUntil then
            local dh = inputAction("IA_DodgeHold")
            if dh then pcall(tl.input.inject, "dodge_press", dh) end
        end
        local df = tl.dodgeDefer
        if df and os.clock() >= df.at then
            tl.dodgeDefer = nil
            if valid(df.input) then
                -- still up: pressed anyway (the watch below presses again if it did not come out)
                if tl.stanceUp(pawn) then attackLog("  -> guard still up %.2fs after dropping it (%s)", tl.DODGE_AFTER_GUARD, df.kind) end
                tl.dodgeWatch = nil
                if df.note and tl.pushNow then
                    tl.try("pushNow", tl.pushNow, pawn)
                    if DEBUG then
                        local okI, iv = pcall(function() return pawn:GetLastMovementInputVector() end)
                        local okR, fw = pcall(function() return pawn:GetActorForwardVector() end)
                        attackLog("  -> roll: last move input %s, facing %s", okI and iv and string.format("(%.2f, %.2f)", iv.X, iv.Y) or "?",
                            okR and fw and string.format("(%.2f, %.2f)", fw.X, fw.Y) or "?")
                    end
                end
                dodge(df.input, df.kind .. (df.note or " (guard dropped)"), df.h, os.clock(), "deferred")
            end
        end
        if tl.dodgeWatch then pcall(tl.tickDodgeWatch, pawn) end
        if settings.parry then hookStanceFrame() end
        -- also while sprint is held (test9: running into a listed hit took it)
        if settings.parry then tickTimelineGuard(pawn, deflect) end
        if not settings.guardRelease then return end
        local down = sprintHeld()
        if down and not sprintWasDown then sprintDownAt = os.clock() end
        sprintWasDown = down
        -- The injected tap is never seen going up, so once the guard was released
        -- the next injected tap is not a new press and the guard does not rise.
        -- A frame after each tap the passive must hold the key; if not, press it
        -- there (On Stance Key Down, what a real press does).
        if tapHold and tapHold ~= pressCheckedFor and os.clock() - (tapHold.untilT - TAP_HOLD) >= 0.02 then
            pressCheckedFor = tapHold
            local ps = deflectPassive(pawn)
            if ps and not keyDown(ps) then
                local ok, err = pcall(function() ps["On Stance Key Down"](ps) end)
                rlog("tap not seen, On Stance Key Down: %s",
                    ok and (keyDown(ps) and "key down" or "key still up") or ("error " .. tostring(err)))
                attackLog("  -> stance key down (tap not seen): %s", ok and "ok" or tostring(err))
            end
        end
        -- An unannounced hit landed (no deflect frame, the mod could not tap):
        -- raise the guard the way a held key does, so the rest of the combo meets
        -- a raised guard. In 1.1 the guard the first tap left up did this.
        if lastBlindHit ~= blindSeen then
            blindSeen = lastBlindHit
            local ps = not down and deflectPassive(pawn)
            if ps and not keyDown(ps) then
                local ok, err = pcall(function() ps["On Stance Key Down"](ps) end)
                tl.keyDownAt = os.clock()
                rlog("unannounced hit, On Stance Key Down: %s",
                    ok and (keyDown(ps) and "key down" or "key still up") or ("error " .. tostring(err)))
                attackLog("  -> guard up after unannounced hit: %s", ok and "ok" or tostring(err))
            end
        end
        if deflectKeyHeld() then return end
        -- perfect_mode = give: no tag holds the guard, but the injected press is
        -- never seen going up: the passive keeps the key down until the next tap
        -- (probe 2026-11-03), so the guard stays. Let the key go GIVE_RELEASE
        -- after the mod's last press, unless a hit is coming, a black flash
        -- has the tag on or a bullet is on its way (tl.bulletUntil).
        if settings.perfectMode == "give" and not tapHold and not tl.soon
            and (tl.blackDodge() or os.clock() >= (tl.blackUntil or 0)) and os.clock() >= (tl.bulletUntil or 0)
            and os.clock() >= tl.tagUntil
            and os.clock() - math.max(lastTapAt or 0, tl.keyDownAt) >= tl.GIVE_RELEASE
            and not hitComing(deflect, 0.3) then
            local ps = deflectPassive(pawn)
            if ps and keyDown(ps) then
                releaseFrom = nil
                release(pawn, "give: press over")
                return
            end
        end
        -- fight over: no nearby enemy attack, hit taken or parry for
        -- guard_release_combat_end seconds; lowered once per fight
        local over = settings.guardReleaseCombatEnd
        -- an announced hit (projectiles too) keeps it on; lastWarnClock is only
        -- kept with debug on, so the deflect queries are asked here, every 0.1 s
        if over > 0 and os.clock() - (tl.warnCheckAt or 0) >= 0.1 then
            tl.warnCheckAt = os.clock()
            -- also while an attack is still followed or a timed dodge is due
            -- (test 1.3.2: MengHua CA_01 ended the fight 1.5 s before its hit)
            if tl.soon or #tlQueue > 0 or (tl.grabDodgeAt and #tl.grabDodgeAt > 0)
                or hitComing(deflect, 1.5) then tl.enemyAt = os.clock() end
        end
        local last = math.max(tl.enemyAt or 0, lastTapAt or 0, lastHitClock, lastWarnClock)
        if over > 0 and last > 0 and tl.combatOver ~= last and os.clock() - last >= over then
            tl.combatOver = last
            releaseFrom = nil
            release(pawn, "combat over")
            return
        end
        local quiet = settings.guardReleaseAfter
        if releaseFrom and quiet > 0 then
            local since = os.clock() - releaseFrom
            if since >= quiet and not hitComing(deflect, quiet) then
                releaseFrom = nil
                release(pawn, "quiet")
                return
            end
        end
        -- every time the guard came back up while running (a parry mid-run), once
        -- no hit is coming and the last tap is SPRINT_QUIET old
        if down and os.clock() - sprintDownAt >= SPRINT_HOLD and not tl.soon
            -- lastTapAt: lastTap is cleared every tick by releaseHeldGuard
            and not (lastTapAt and os.clock() - lastTapAt < SPRINT_QUIET)
            and not hitComing(deflect, SPRINT_QUIET) then
            releaseFrom = nil
            release(pawn, "sprint held")
        end
    end
end

-- ---------------------------------------------------------------- stance watcher
-- Logs every change of the player's deflect stance (tag Ability.Action.Stance)
-- with how long ago the mod last tapped. A stance that stays on STANCE_IDLE
-- seconds while no deflect key is physically down and no hit is announced
-- within STANCE_QUIET seconds is ended, whatever started it (it blocks Sát Khí).
local STANCE_IDLE, STANCE_QUIET = 1.0, 0.6
local STANCE_END_IDLE = false -- releasing from outside looped in game (stance out, in, out)
local STANCE_RETRY = 1.5
local stanceOn, stanceSince, stanceCheckAt = false, 0, 0
local deflectKeys = nil

-- SDK 0.3.3: ask the game whether the deflect input is held instead of inferring
-- it from the physical keys alone (SGameInputComponent.IsHolding/GetHoldTime,
-- SGameInputSystem.d.ts:299-302). Read only. Every path where the game cannot
-- answer - no component, no field, a throwing call, or an answer this mod's own
-- injection explains - returns nil and leaves the key state in charge, so a game
-- update cannot stop the guard from being released.
-- The install is idempotent and latches its own failure: a module that cannot load
-- once in this build will not load on the next tick either, so it is never retried
-- and the key state stays in charge for the rest of the session.
tl.installInputState = function()
    if tl.inputState or tl.inputStateErr then return tl.inputState end
    local okI, res = pcall(function()
        return dofile(MOD_DIR .. "Scripts/ad_inputstate.lua").new({
            component = component,
            prop = Q.prop,
            isHolding = function(sgi, act) return unwrap(sgi:IsHolding(act)) end,
            holdTime = function(sgi, act) return unwrap(sgi:GetHoldTime(act)) end,
            log = log,
        })
    end)
    if okI and res then
        tl.inputState = res
    else
        tl.inputStateErr = tostring(res)
        log("input state unavailable: %s", tl.inputStateErr)
    end
    return tl.inputState
end
tl.installInputState()
-- keyHeld is what the key path answered; the game's answer overrides it where it
-- exists. The pawn is a parameter so a test can ask without a live character.
tl.holdAsk = function(keyHeld, pawn)
    local IS = tl.inputState
    -- a reverted adapter answers nothing and must not cost a call either
    if not IS or IS.dead then return keyHeld end
    local p = pawn or currentPawn
    if not valid(p) then return keyHeld end
    -- an injected press makes the action look held for TAP_HOLD: never read that
    -- back as the player holding the guard
    local injecting = tapHold ~= nil or os.clock() - (tl.injectAt or -1e9) < TAP_HOLD
    local held = IS.read(p, inputAction("IA_Deflect"))
    if held == nil then return keyHeld end
    return IS.pick(held, keyHeld, injecting)
end

deflectKeyHeld = function()
    local cached = tl.keysCached("deflect")
    if cached ~= nil then return cached end
    local ctrl = UEHelpers.GetPlayerController()
    if not valid(ctrl) then return false end
    -- none found: asked again every 5 s, 5 times (the key mapping may not be in
    -- place yet when the character first appears; 1.3.4 log: "unknown")
    if deflectKeys and #deflectKeys == 0 and (tl.deflectKeyTries or 0) < 5 and os.clock() >= (tl.deflectKeyAt or 0) then
        deflectKeys = nil
    end
    if deflectKeys == nil then
        tl.deflectKeyTries, tl.deflectKeyAt = (tl.deflectKeyTries or 0) + 1, os.clock() + 5
        deflectKeys = {}
        tl.try("deflect keys", function()
            local lib = obj("/Script/Engine.Default__SubsystemBlueprintLibrary")
            local sub = lib:GetLocalPlayerSubSystemFromPlayerController(ctrl,
                obj("/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem"))
            local keys = unwrap(sub:QueryKeysMappedToAction(inputAction("IA_Deflect")))
            for _, k in pairs(type(keys) == "table" and keys or {}) do deflectKeys[#deflectKeys + 1] = unwrap(k) end
        end)
        local names = {}
        for _, k in ipairs(deflectKeys) do
            local okN, n = pcall(function() return name(k.KeyName) end)
            names[#names + 1] = okN and n or "?"
        end
        if #names > 0 or tl.deflectKeyTries >= 5 then
            log("deflect keys: %s", #names > 0 and table.concat(names, ", ") or "unknown (manual hold not detected)")
        end
    end
    local keyHeld = tl.keysDown(ctrl, deflectKeys, "deflect")
    local held = tl.holdAsk(keyHeld)
    -- keysDown cached the key answer; the cache has to hold what callers receive
    if held ~= keyHeld then tl.keyState["deflect"] = { at = os.clock(), down = held } end
    return held
end

local stanceFields, stanceFieldsLast = nil, nil
local function stanceFieldValues(pawn)
    if not stanceFields then
        stanceFields = {}
        local okC, cls = pcall(function() return pawn:GetClass() end)
        local guard = 0
        while okC and valid(cls) and guard < 12 do
            guard = guard + 1
            tl.try("force properties", function()
                cls:ForEachProperty(function(prop)
                    local n = prop:GetFName():ToString()
                    local l = n:lower()
                    if l:find("force", 1, true) or l:find("perfect", 1, true) or l:find("deflect", 1, true)
                        or l:find("stance", 1, true) or l:find("guard", 1, true) then
                        stanceFields[#stanceFields + 1] = n
                    end
                end)
            end)
            local okS, sup = pcall(function() return cls:GetSuperStruct() end)
            if not okS then break end
            cls = sup
        end
        log("stance fields on the player: %s", #stanceFields > 0 and table.concat(stanceFields, ", ") or "none")
    end
    local parts = {}
    for _, n in ipairs(stanceFields) do
        local ok, v = pcall(function() return pawn[n] end)
        if ok then
            v = unwrap(v)
            local t = type(v)
            if t == "boolean" or t == "number" or t == "string" then parts[#parts + 1] = n .. "=" .. tostring(v) end
        end
    end
    return table.concat(parts, " ")
end

local MANUAL_CONFIRM = 0.8
local STANCE_FIELDS = false -- diagnostic: the pawn's deflect / stance fields on every stance change
local dodgeKeys, dodgeWasDown, manualPending = nil, false, nil
local function watchManualDodge()
    local ctrl = UEHelpers.GetPlayerController()
    if not valid(ctrl) then return end
    if dodgeKeys == nil then
        dodgeKeys = {}
        tl.try("dodge keys", function()
            local lib = obj("/Script/Engine.Default__SubsystemBlueprintLibrary")
            local sub = lib:GetLocalPlayerSubSystemFromPlayerController(ctrl,
                obj("/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem"))
            local keys = unwrap(sub:QueryKeysMappedToAction(inputAction("IA_Dodge")))
            for _, k in pairs(type(keys) == "table" and keys or {}) do dodgeKeys[#dodgeKeys + 1] = unwrap(k) end
        end)
        local names = {}
        for _, k in ipairs(dodgeKeys) do
            local okN, n = pcall(function() return name(k.KeyName) end)
            names[#names + 1] = okN and n or "?"
        end
        log("dodge keys: %s", #names > 0 and table.concat(names, ", ") or "unknown (manual dodges not learned)")
    end
    local down = false
    for _, k in ipairs(dodgeKeys) do
        local ok, d = pcall(function() return ctrl:IsInputKeyDown(k) end)
        if ok and unwrap(d) == true then down = true break end
    end
    local t = os.clock()
    if down and not dodgeWasDown then
        local rs = recentStart
        local since = rs and t - rs.t or nil
        local announced = lastWarnClock > (rs and rs.t or 0) and t - lastWarnClock < 1.5
        attackLog("MANUAL DODGE %s%s", rs and string.format("%.2fs after %s starts", since, rs.name) or "",
            announced and " (a hit was announced)" or " (nothing announced)")
        if LEARN and rs and since <= BLIND_LOOKBACK and not announced then
            manualPending = { name = rs.name, delay = since, t = t }
        end
    end
    dodgeWasDown = down
    if manualPending and t - manualPending.t >= MANUAL_CONFIRM then
        local m = manualPending
        manualPending = nil
        if lastHitClock >= m.t then
            attackLog("  manual dodge at %.2fs after %s: hit anyway, not learned", m.delay, m.name)
        else
            learned[m.name] = m.delay
            saveLearned()
            attackLog("  LEARN %s: your dodge %.2fs after it started worked -> mod dodges there", m.name, m.delay)
        end
    end
end

local function watchStance(pawn, deflect)
    if os.clock() < stanceCheckAt then return end
    stanceCheckAt = os.clock() + 0.05
    local asc = ascOf(pawn)
    local on = hasTag(asc, "Ability.Action.Stance")
    if on ~= stanceOn then
        stanceOn, stanceSince = on, os.clock()
        local okF, fields = false, nil
        -- reading the pawn's fields on every stance change (diagnostic) is off: a
        -- crash inside UE4SS came right after it (2026-11-01)
        if DEBUG and STANCE_FIELDS then okF, fields = pcall(stanceFieldValues, pawn) end
        if okF and fields ~= stanceFieldsLast then
            stanceFieldsLast = fields
            attackLog("  fields: %s", fields)
        end
        attackLog("STANCE %s  (mod tap %s, deflect key %s, perfect tag %s)", on and "ON" or "off",
            lastTapAt and string.format("%.2fs ago", os.clock() - lastTapAt) or "never",
            deflectKeyHeld() and "HELD" or "up", tostring(hasPerfectTag(pawn)))
        return
    end
    if not STANCE_END_IDLE then return end
    if not on or os.clock() - stanceSince < STANCE_IDLE then return end
    if os.clock() - lastReleaseAt < STANCE_RETRY then return end
    if deflectKeyHeld() then return end
    if nearest(deflect, false, STANCE_QUIET) >= 0 or nearest(deflect, true, STANCE_QUIET) >= 0 then return end
    releaseStance(pawn, "idle stance")
end

tl.stanceUp = function(pawn) return hasTag(ascOf(pawn), "Ability.Action.Stance") end
endStance = function(pawn, why)
    if deflectKeyHeld() then return end
    local asc = ascOf(pawn)
    if not hasTag(asc, "Ability.Action.Stance") then return end
    local ended = {}
    for _, ab in ipairs(stanceAbilities(pawn)) do
        if valid(ab) and abilityActive(ab) ~= false then
            tl.try("stance end", RT.endAbility, ab)
            if hasTag(asc, "Ability.Action.Stance") then tl.try("stance cancel", RT.cancelAbility, ab) end
            ended[#ended + 1] = short(ab:GetClass())
        end
    end
    attackLog("  -> stance ended (%s): %s", why, #ended > 0 and table.concat(ended, ", ") or "nothing to end")
end

-- (removed 1.6.3: keepStanceDown and its three counters were dead code - no caller
-- The enemies' gameplay ability instances are collected by walking the object
-- table every ENEMY_SCAN seconds (only while enemies attack: see enemyScanWanted);
-- their bIsActive flag is then read every tick. Each ability that starts is
-- written to attacks_log.txt ("ENEMY ..."); one whose name contains a word of
-- dodge_attacks marks the next hit as one to dodge.
local ENEMY_SCAN = 20
local enemyAbilities, enemyScanAt, enemyWasActive = {}, 0, {}

local function matchDodgeWord(text)
    local hay = text:lower()
    for w in settings.dodgeAttacks:gmatch("[^,%s]+") do
        if hay:find(w:lower(), 1, true) then return w end
    end
    return nil
end

local function scanEnemyAbilities(pawn)
    local cls = gameplayAbilityClass()
    if not cls then return end
    local paddr = pawn:GetAddress()
    local list = {}
    ForEachUObject(function(o)
        local okI, isGa = pcall(function() return o:IsA(cls) end)
        if not (okI and isGa) then return end
        local actor = avatarOf(o)
        if actor and actor:GetAddress() ~= paddr then
            local n = short(o:GetClass())
            -- passives and movement never matter
            if not (n:find("Passive", 1, true) or n:find("Locomotion", 1, true) or n == "GA_SpaceState") then
                list[#list + 1] = { ab = o, name = n, who = short(actor), actor = actor }
            end
        end
    end)
    enemyAbilities, enemyWasActive = list, {}
end

local function watchEnemies(pawn)
    local freshScan = false
    -- the object walk is the fallback for when the activation hook never fires;
    -- the first one waits 10 s for it (perf test: the walk at load made 83 MB of
    -- garbage and a 0.8 s freeze, and the hook fired 1 s later)
    -- (1.3.3 report: a frame drop every 15-20 s anywhere, even on the map: until
    -- an ability started the walk ran every ENEMY_SCAN s; now only while the hook
    -- is not in place)
    if enemyScanAt == 0 then enemyScanAt = os.clock() + 10 end
    if enemyScanWanted and not tl.activationWorks and not tl.activationHooked and os.clock() >= enemyScanAt then
        enemyScanAt = os.clock() + ENEMY_SCAN
        freshScan = #enemyAbilities > 0 -- the first scan may see real starts
        scanEnemyAbilities(pawn)
    end
    for i, e in ipairs(enemyAbilities) do
        local active = valid(e.ab) and abilityActive(e.ab) == true
        if not active and enemyWasActive[i] and special and special.ab == e.ab then
            special.untilT = math.min(special.untilT, os.clock() + SPECIAL_TAIL)
        end
        if active and not enemyWasActive[i] and not freshScan then
            if not (e.name:find("Dodge", 1, true) or e.name:find("Teleport", 1, true)) then
                recentStart = { name = e.name, t = os.clock() }
            end
            local delay = learned[e.name]
            if LEARN and delay and settings.dodge ~= "off" then
                timedDodge = { at = os.clock() + delay, name = e.name }
                special = { untilT = os.clock() + delay + 1.2, what = "learned", ab = e.ab }
                attackLog("ENEMY %s starts %s  << timed dodge in %.2fs (learned)", e.who, e.name, delay)
            end
            local word = matchDodgeWord(e.name)
            local tlNote = queueTimeline(e.ab, e.name, e.actor, pawn, "poll") or ""
            attackLog("ENEMY %s starts %s%s%s", e.who, e.name, word and ("  << dodge (" .. word .. ")") or "", tlNote)
            if word and not delay then
                special = { untilT = os.clock() + SPECIAL_SECONDS, what = word, ab = e.ab }
            end
        end
        enemyWasActive[i] = active
    end
end

-- Ability starts seen by a hook on the abilities' activation event: the exact
-- start, and also abilities made new for each use, which the object scan misses.
local ACTIVATE_FNS = {
    "/MagCombatAbilities/Abilities/BP_AbilityBase.BP_AbilityBase_C:K2_ActivateAbility",
    "/MagCombatAbilities/Abilities/BP_ActionAbilityBase.BP_ActionAbilityBase_C:K2_ActivateAbility",
    "/MagCombatAbilities/Abilities/BP_ActionAbilityBase_Simple.BP_ActionAbilityBase_Simple_C:K2_ActivateAbility",
}
local activationTry, activationTries = 0, 0
local function onActivate(ctx)
    local ab = ctx:get()
    if not valid(ab) or not valid(currentPawn) then return end
    if not tl.activationWorks then
        tl.activationWorks = true
        enemyAbilities, enemyWasActive = {}, {}
        log("activation hook fires: enemy object scan off")
    end
    local actor = avatarOf(ab)
    if not actor or actor:GetAddress() == currentPawn:GetAddress() then return end
    local n = short(ab:GetClass())
    local tlNote = queueTimeline(ab, n, actor, currentPawn, "hook")
    -- a grab with its ExecutionTimeline in hit_times.txt is handled there (its
    -- red grab hit comes seconds in, after hits that are parried: test10h
    -- P2_GEx_01 grab at 4.80, the early dodges below only wasted the dodge)
    local okG, gdist = pcall(function() return tonumber(unwrap(actor:GetDistanceTo(currentPawn))) end)
    local mine = okG and gdist and gdist <= TL_NEAR and tl.towardPlayer(actor, currentPawn, gdist)
    if mine and n:find("GEx", 1, true) and not hitTimes[RT.bname(n) or n] and os.clock() - tl.grabAt > 0.3 then
        tl.grabAt, tl.grabName = os.clock(), n
        -- test10f: a dodge at +0.34 and at the frame (+0.49) were both refused
        -- (perfect dodge false) and the player was grabbed: also dodge right at
        -- the start, before the grab's lunge closes in
        local d = tl.grabTimes[n]
        tl.grabDodgeAt = { tl.grabAt + 0.05 }
        -- 1.5.0: the long grab lead only for what the game data calls a grab
        local glead = tl.grabLead
        if settings.data and tl.dat and tl.dat.ready and tl.dat.isGrab(n) == false then
            glead = settings.dodgeLead or 0.08
        end
        if d and d - glead > 0.2 then tl.grabDodgeAt[2] = tl.grabAt + d - glead end
        tlNote = (tlNote or "") .. "  << grab: dodge its frame"
    end
    local real = tl.realHits[n]
    if real and tlNote and tlNote:find("<<", 1, true) then -- near enough to be queued
        tl.grabAt, tl.grabName, tl.grabDodgeAt = os.clock(), n, {}
        for _, d in ipairs(real) do tl.grabDodgeAt[#tl.grabDodgeAt + 1] = tl.grabAt + d end
        tlNote = tlNote .. "  << timed dodge"
    end
    -- any nearby enemy ability keeps the fight on, not only the listed attacks
    -- (test: LengTu's projectile skills, not in hit_times.txt, let it end mid-fight)
    -- (a fight between others nearby does not)
    if mine and (n:find("YanQianSui", 1, true) or n:find("YuZan", 1, true)) then
        if os.clock() >= tl.redScanUntil then tl.redSeen = {} end
        tl.redScanUntil = os.clock() + tl.RED_SCAN
    end
    if mine then
        tl.enemyAt = os.clock()
        tl.lastEnemy, tl.lastEnemyAt, tl.lastEnemyDist = RT.bname(n) or n, os.clock(), gdist
        tl.lastEnemyActor = actor
    end
    if DEBUG then attackLog("ENEMY %s activates %s%s", short(actor), n, tlNote or "") end
end
-- debug = on: what the game does with bullets (YanQianSui's come red: dodge,
-- or blue: parry, it reflects them; its hits came with no announced frame).
-- Each bullet's deflect frame carries IsDodge (red) and a radius; if these
-- hooks fire, the mod can follow every bullet and pick parry or dodge.
tl.BULLET_FNS = {
    "/Script/PBZDeflectSystem.DeflectComponent:SendDeflectFrame",
    "/Script/PBZDeflectSystem.DeflectComponent:SetFrameHitActorByBullet",
    "/Script/PBZDeflectSystem.DeflectComponent:StopSendDeflectFrameForBullet",
    "/PBZCombatAsset/Prototypes/Bullet/Bullets/BP_PBZ_ProjectileBullet.BP_PBZ_ProjectileBullet_C:OnDodge",
}
-- for the HIT line: where the last tornado is, while it lives (is the player
-- still in it, or did the hits come from elsewhere?)
tl.tornadoNote = function()
    local tn = tl.tornado
    if not tn or os.clock() - (tl.tornadoAt or 0) > 10 then return "" end
    local ok, s = pcall(function()
        if not valid(tn) then return "  (tornado gone)" end
        local d = unwrap(tn:GetDistanceTo(currentPawn)) / 100
        local okB, ds = pcall(function() return string.format(", %.1f m from it to its owner", unwrap(tn:GetDistanceTo(tn:GetOwner())) / 100) end)
        return string.format("  (tornado %.1f m away%s)", d, okB and ds or "")
    end)
    return ok and s or ""
end
tl.bulletInfo = function(fn, ctx, a, b, _c, d, _e, _f, _g, _h, _i, j)
    local function nm(o)
        o = unwrap(o)
        local ok, r = pcall(function() return valid(o) and short(o) or tostring(o) end)
        return ok and r or "?"
    end
    local function dist(o)
        o = unwrap(o)
        local ok, r = pcall(function() return string.format("%.1f m", unwrap(o:GetDistanceTo(currentPawn)) / 100) end)
        return ok and r or "-"
    end
    local self = unwrap(ctx)
    local okO, owner = pcall(function() return self:GetOwner() end)
    owner = okO and owner or self
    local what = fn:match("([%w_]+)$")
    -- perfect_mode = give: a bullet hits 0.4 to 1.1 s after its frame is sent
    -- and announced (YouLong Skill_04_Hard / CA_01_Mad, 2026-11-03: 7 hits
    -- through taps 0.4 to 0.7 s early, the press window is 0.2 s). Until it can
    -- have landed, the guard stays up with the perfect tag, as in always mode.
    local okBN, bulletName = pcall(function() return short(unwrap(b)) end)
    local playerOrb = okBN and bulletName and (bulletName:find("SlowOrb", 1, true) or bulletName:find("CounterOrb", 1, true))
    if what == "SendDeflectFrame" and unwrap(j) ~= true and not playerOrb then
        tl.bulletUntil = math.max(tl.bulletUntil or 0, os.clock() + tl.BULLET_HOLD)
    end
    -- YouLong Skill_04_Hard's tornado: standing in it, its storm bullets hit
    -- with no frame, through a raised perfect guard (2026-11-03: 4x -298).
    -- Walk out of it while it lasts.
    if what == "SendDeflectFrame" and tl.moveAway and settings.dodge ~= "off" then
        local bullet = unwrap(b)
        local okN, bn = pcall(function() return short(bullet) end)
        if okN and bn and bn:find("Tornado", 1, true) then
            tl.tornado, tl.tornadoAt = bullet, os.clock()
            tl.moveAway(bullet, os.clock() + tl.TORNADO_MOVE, tl.TORNADO_FAR)
            log("tornado %s: walking out (%s)", bn, dist(bullet))
        end
    end
    if what == "SendDeflectFrame" and DEBUG then
        attackLog("BULLET %s by %s: bullet %s (%s), radius %s, IsDodge(red) %s, action %s", what, nm(owner), nm(b), dist(b),
            tostring(unwrap(d)), tostring(unwrap(j)), nm(a))
    elseif DEBUG then
        attackLog("BULLET %s on %s (%s), owner %s: %s (%s) %s", what, nm(self), dist(self), nm(owner), nm(a), dist(a),
            tostring(unwrap(b)))
    end
end
tl.hookBullets = function()
    for i, fn in ipairs(tl.BULLET_FNS) do
        -- debug off: only SendDeflectFrame, for tl.bulletUntil (a far shot is
        -- still parried) and the tornado
        if not RT.installed(fn) and (DEBUG or i == 1) then
            local ok, pre, post = pcall(RegisterHook, fn, function(ctx, ...)
                if tl.stopped then return end
                local okB, e = pcall(tl.bulletInfo, fn, ctx, ...)
                if not okB then tl.err("bullet hook", e) end
            end)
            if ok then RT.rememberHook(fn, fn, pre, post) end
            if ok or activationTries == 1 or activationTries == 12 then
                log("bullet probe %s: %s", fn:match("([%w_]+:[%w_]+)$") or fn, ok and "hooked" or tostring(pre))
            end
        end
    end
end

-- What the game made of each defense, from its own effect calls (found in
-- AutoPerfectDefense 1.0.8): Play Deflect Effect carries the defender and the
-- result (perfect or normal deflect), OnEvadeDamage a hit avoided by a dodge
-- (perfect or not). Counted for the player only, split into the mod's presses
-- (RESULT_MOD s after one) and the player's own; a "results:" line every
-- RESULT_EVERY s when the counts changed, each one in attacks_log with debug.
tl.RESULT_MOD, tl.RESULT_EVERY, tl.results, tl.resultsAt, tl.resultsDirty = 0.4, 60, {}, 0, false
tl.countResult = function(what, modAt)
    local mine = modAt and os.clock() - modAt <= tl.RESULT_MOD
    local key = (mine and "mod " or "you ") .. what
    -- give mode: a Normal / Great deflect costs Sha-chi (a Perfect gives it), and
    -- an empty bar breaks the guard (user, 2026-11-05). After one by the mod, the
    -- perfect tag goes on for TAG_AFTER_NORMAL s: the rest of the volley is Perfect
    -- (final boss SpecialAttack_09_Gun_Ending: 24 Normal in a row, tag off).
    -- The guard is held while the tag is on, then let go as after a bullet.
    if mine and settings.perfectMode == "give" and (what == "deflect Normal" or what == "deflect Great") then
        local was = os.clock() < tl.tagUntil
        tl.tagUntil = math.max(tl.tagUntil, os.clock() + tl.TAG_AFTER_NORMAL)
        if not was then
            tl.tagLogs = tl.tagLogs + 1
            if tl.tagLogs <= 200 then log("give: mod %s, perfect tag on for %.1f s", what, tl.TAG_AFTER_NORMAL) end
        end
    end
    tl.results[key] = (tl.results[key] or 0) + 1
    tl.resultsDirty = true
    if DEBUG then attackLog("RESULT %s%s", key, modAt and string.format(" (mod press %.2fs ago)", os.clock() - modAt) or "") end
end
tl.resultsLine = function()
    local keys = {}
    for k in pairs(tl.results) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = string.format("%s %d", k, tl.results[k]) end
    return table.concat(parts, ", ")
end
tl.tickResults = function(t)
    if tl.resultsDirty and t >= tl.resultsAt then
        tl.resultsDirty, tl.resultsAt = false, t + tl.RESULT_EVERY
        log("results: %s", tl.resultsLine())
    end
end
tl.onDeflectEffect = function(_ctx, ...)
    local n = select("#", ...)
    for i = 1, n do
        local p = select(i, ...)
        local okD, data = pcall(function() return p:get() end)
        local okR, res, who = false, nil, nil
        if okD and data then okR, res, who = pcall(function() return data.DeflectResult, data.DefenderAvatar end) end
        local okT0, tn = false, nil
        if okR and res ~= nil then okT0, tn = pcall(RT.tagStr, res) end
        if okT0 and type(tn) == "string" and tn ~= "" then
            local mine = valid(currentPawn) and valid(who) and who:GetAddress() == currentPawn:GetAddress()
            tl.effectSeen = (tl.effectSeen or 0) + 1
            if DEBUG and tl.effectSeen <= 40 then
                local okW, wn = pcall(function() return short(who) end)
                attackLog("EFFECT %s defender %s%s", okT0 and tn or "?", okW and wn or "?", mine and " [player]" or "")
            end
            if not mine then return end
            local okT, txt = pcall(RT.tagStr, res)
            txt = okT and txt or "?"
            tl.countResult("deflect " .. (txt:match("([^%.]+)$") or txt), math.max(lastTapAt or -10, tl.keyDownAt or -10))
            return
        end
    end
    tl.effectBad = (tl.effectBad or 0) + 1
    if DEBUG and tl.effectBad <= 5 then
        local kinds = {}
        for i = 1, n do kinds[#kinds + 1] = type(select(i, ...)) end
        attackLog("EFFECT call with no result data (%d args: %s)", n, table.concat(kinds, " "))
    end
end
tl.onEvade = function(_ctx, _source, _x, perfect)
    local okP, pf = pcall(function() return perfect:get() end)
    tl.countResult((okP and pf == true) and "dodge perfect" or "dodge", tl.lastDodgeAt)
end
tl.RESULT_FNS = {
    { "/PBZDeflectSystem/BPL_DeflectUtils.BPL_DeflectUtils_C:Play Deflect Effect", "onDeflectEffect" },
    { "/PBZDeflectSystem/Abilities/BP_PlayerDodge_Base.BP_PlayerDodge_Base_C:OnEvadeDamage", "onEvade" },
}
tl.hookResults = function()
    for _, e in ipairs(tl.RESULT_FNS) do
        if not RT.installed(e[1]) then
            local ok, pre, post = pcall(RegisterHook, e[1], function(ctx, ...)
                if tl.stopped then return end
                local okH, er = pcall(tl[e[2]], ctx, ...)
                if not okH then tl.err("result hook", er) end
            end)
            if ok then RT.rememberHook(e[1], e[1], pre, post) end
            if ok or activationTries == 1 or activationTries == 12 then
                log("result hook %s: %s", e[1]:match("([%w_ ]+:[%w_ ]+)$") or e[1], ok and "hooked" or tostring(pre))
            end
        end
    end
end

local function hookActivation()
    if activationTries >= 12 or os.clock() < activationTry then return end
    activationTry, activationTries = os.clock() + 5, activationTries + 1
    tl.try("bullet hook", tl.hookBullets)
    tl.try("result hook", tl.hookResults)
    for _, fn in ipairs(ACTIVATE_FNS) do
        if not RT.installed(fn) then
            local ok, pre, post = pcall(RegisterHook, fn, function(ctx)
                if tl.stopped then return end
                local t0 = settings.perf and os.clock()
                local okH, e = pcall(onActivate, ctx)
                if t0 then tl.perfAdd(tl.perf.hooks, os.clock() - t0) end
                if not okH then tl.err("activation hook", e) end
            end)
            if ok then tl.activationHooked = true RT.rememberHook(fn, fn, pre, post) end
            if ok or activationTries == 1 or activationTries == 12 then
                log("activation hook %s: %s", fn:match("([%w_]+_C:)") or fn, ok and "hooked" or tostring(pre))
            end
        end
    end
end

-- ---------------------------------------------------------------- F6 snapshot
-- Diagnostic: every active gameplay ability in the world (player's and enemies')
-- plus a few player state tags, written to attacks_log.txt and the log. Walks
-- the whole object table once, so the game may hitch for a moment.
local SNAP_TAGS = { "Ability.Action.Stance", "Ability.Action.HoldDeflect", "Ability.Action.Hun.PerfectDodge",
    "CharacterState.Deflect", "CharacterState.HoldDeflect", "CharacterState.Stance", "CharacterState.Guard" }
local snapCount = 0
local function snapshot(pawn)
    snapCount = snapCount + 1
    local gaCls = gameplayAbilityClass()
    if not gaCls then log("snapshot: GameplayAbility class not found") return end
    local paddr = pawn and pawn:GetAddress()
    local mine, others = {}, {}
    ForEachUObject(function(o)
        local okI, isGa = pcall(function() return o:IsA(gaCls) end)
        if not (okI and isGa) then return end
        local active = abilityActive(o)
        if active == false then return end
        local who = avatarOf(o)
        if not who then return end
        local cls = short(o:GetClass()) .. (active == nil and " (?)" or "")
        if who and paddr and who:GetAddress() == paddr then mine[#mine + 1] = cls
        else others[#others + 1] = (who and short(who) or "?") .. ": " .. cls end
    end)
    local tags = {}
    local asc = pawn and ascOf(pawn)
    for _, t in ipairs(SNAP_TAGS) do
        local ok, has = pcall(function() return asc:HasMatchingGameplayTag(tag(t)) end)
        if ok and unwrap(has) == true then tags[#tags + 1] = t end
    end
    local head = string.format("SNAPSHOT %d (%s)", snapCount, settings.keys.snapshot)
    attackLog("%s player abilities: %s", head, #mine > 0 and table.concat(mine, ", ") or "-")
    attackLog("%s player tags: %s", head, #tags > 0 and table.concat(tags, ", ") or "-")
    for _, line in ipairs(others) do attackLog("%s other: %s", head, line) end
    log("%s: player %s | tags %s | %d other abilities (attacks_log.txt)", head,
        #mine > 0 and table.concat(mine, ", ") or "-", #tags > 0 and table.concat(tags, ", ") or "-", #others)
    toast:show(string.format("%s: snapshot saved (%d of yours, %d others)", settings.keys.snapshot, #mine, #others), 2.5)
end

-- ---------------------------------------------------------------- attack hook
-- DeflectComponent:SendDeflectFrame is seen only when a Blueprint ability calls
-- it (most attacks call it from C++ and are not seen). The calls seen are logged
-- with the ability and tags; one whose ability name or tags contain a word of
-- dodge_attacks (auto_defense.txt) marks the next normal hit as one to dodge.
local function tagName(param)
    local ok, s = pcall(function() return name(unwrap(param).TagName) end)
    return ok and s or "?"
end

-- Bullet and AttackRotation (SDK positions 2 and 3) are received and unused: the
-- underscore prefix says so without pretending the hook has a different shape.
local function onSendFrame(ctx, action, _bullet, _rotation, _, _, strength, direction, _, _, isDodge, counter)
    local comp = unwrap(ctx)
    local okO, owner = pcall(function() return comp:GetOwner() end)
    owner = okO and valid(owner) and owner or nil
    if owner and valid(currentPawn) and owner:GetAddress() == currentPawn:GetAddress() then
        return -- our own
    end
    local okA, act = pcall(function() return unwrap(action) end)
    local actName = okA and valid(act) and short(act:GetClass()) or "-"
    local okD, red = pcall(function() return unwrap(isDodge) end)
    local okK, ctr = pcall(function() return unwrap(counter) end)
    local st, dir = tagName(strength), tagName(direction)
    local word = matchDodgeWord(actName .. " " .. st .. " " .. dir)
    enemyScanWanted = true
    attackLog("SEND %s | %s | strength=%s direction=%s isDodge=%s counter=%s%s",
        short(owner), actName, st, dir, okD and tostring(red) or "?", okK and short(ctr) or "?",
        word and ("  << dodge (" .. word .. ")") or "")
    log("attack seen: %s %s strength=%s isDodge=%s%s", short(owner), actName, st,
        okD and tostring(red) or "?", word and (" -> will dodge (" .. word .. ")") or "")
    if word and not (okD and red == true) then
        special = { untilT = os.clock() + SPECIAL_SECONDS, what = word }
    end
end

local function hookAttacks(deflect)
    -- the installed record comes first: without this check every tick added a new
    -- pair of ids and the previous pair could never be removed (audit 2026-11-17 P0)
    if RT.installed("attack") then return end
    -- a failed attempt retries after 10 s: this used to be a one-way door (audit P0-3)
    if tl.attackHookAt and os.clock() < tl.attackHookAt then return end
    local okC, full = pcall(function() return deflect:GetClass():GetFullName() end)
    local path = okC and full and full:match("^%S+%s+(.+)$")
    if not path then
        tl.attackHookAt = os.clock() + 10
        log("attack hook: class of Deflect Component unknown, retrying in 10 s")
        return
    end
    local hookPath = path .. ":SendDeflectFrame"
    local ok, pre, post = pcall(RegisterHook, hookPath, function(...)
        if tl.stopped then return end
        local okR, e = pcall(onSendFrame, ...)
        if not okR then log("attack hook error: %s", tostring(e)) end
    end)
    if ok then RT.rememberHook("attack", hookPath, pre, post) tl.attackHookAt = nil end
    log("attack hook: %s", ok and ("hooked " .. hookPath) or ("not hooked: " .. tostring(pre)))
end

-- ---------------------------------------------------------------- gameplay cues
local CUE_FUNCS = {
    "/Script/GameplayAbilities.GameplayCueNotify_Static:K2_HandleGameplayCue",
    "/Script/GameplayAbilities.GameplayCueNotify_Actor:K2_HandleGameplayCue",
}
local CUE_EVENTS = { [0] = "active", [1] = "while", [2] = "exec", [3] = "remove" }
local cueLast = {}
local function onCue(self, target, eventType)
    local cue = short(self:get():GetClass())
    local who = target and target:get() or nil
    local mine = valid(who) and valid(currentPawn) and who:GetAddress() == currentPawn:GetAddress()
    local okE, ev = pcall(function() return unwrap(eventType:get()) end)
    local key = cue .. (mine and "@me" or "@enemy")
    local t = os.clock()
    if cueLast[key] and t - cueLast[key] < 0.3 then return end
    cueLast[key] = t
    attackLog("CUE %s on %s (%s)", cue, mine and "ME" or short(who),
        okE and (CUE_EVENTS[ev] or tostring(ev)) or "?")
end

-- 未接线 (audit P2-1): no caller anywhere; kept for the day the cue path is fixed
local function hookCues()
    for _, fn in ipairs(CUE_FUNCS) do
        if not RT.installed("cue " .. fn) then
        local ok, pre, post = pcall(RegisterHook, fn, function(...)
            if tl.stopped then return end
            local okR, e = pcall(onCue, ...)
            if not okR then log("cue hook error: %s", tostring(e)) end
        end)
        if ok then RT.rememberHook("cue " .. fn, fn, pre, post) end
        log("cue hook %s: %s", fn:match(":(.+)$") .. " (" .. (fn:match("GameplayCueNotify_(%w+)") or "?") .. ")",
            ok and "ok" or ("failed: " .. tostring(pre)))
        end
    end
end

-- ---------------------------------------------------------------- Sát Khí regen
-- The perfect tag keeps the character in a deflect stance, and in a stance Sát
-- Khí (BasicAttributeSet.Shachi) does not recover: it drains ~20/s. Measured in
-- game without a stance: it recovers ~1/3 of Shachi_Max per second, starting
-- ~1 s after it was last spent. While the mod's tag holds the stance (and the
-- deflect key is not held by the player), the mod gives that recovery back.
local REGEN_PER_SEC = 0.33 -- share of Shachi_Max per second
local REGEN_COOLDOWN = 1.0 -- s after Sát Khí was spent
local REGEN_TICK = 0.05 -- 20 Hz: same regen rate, 1/20 of the closures per tick (audit P1-2)
local SPEND_DROP = 8 -- a drop bigger than this in one tick is a spend, not the stance drain
local REFILL_BELOW = 0.90 -- the stance drain is let run down to this share of Shachi_Max
local refilling = false
local shachiAt, shachiLast, shachiSpentAt, shachiChecked = 0, nil, 0, false
-- Sha-chi as a share of its maximum (nil when unknown), for the give-mode low-bar tag
tl.shachiShare = function()
    if not valid(hpSet) then return nil end
    local cur, max = hpSet.Shachi.CurrentValue, hpSet.Shachi_Max.CurrentValue
    if type(cur) ~= "number" or type(max) ~= "number" or max <= 0 then return nil end
    return cur / max
end

local function tickShachi(pawn)
    local t = os.clock()
    if t < shachiAt then return end
    local dt = t - (shachiAt - REGEN_TICK)
    shachiAt = t + REGEN_TICK
    if not valid(hpSet) or hpPawn ~= pawn:GetAddress() then return end
    local okC, cur = pcall(RT.curOf, hpSet.Shachi)
    local okM, max = pcall(RT.curOf, hpSet.Shachi_Max)
    if not okC or type(cur) ~= "number" or not okM or type(max) ~= "number" then return end
    if shachiLast and cur < shachiLast - SPEND_DROP then shachiSpentAt = t refilling = true end
    shachiLast = cur
    if cur < max * REFILL_BELOW then refilling = true end
    if cur >= max then refilling = false end
    if not refilling or not (settings.perfect and perfectPawn) then return end
    if t - shachiSpentAt < REGEN_COOLDOWN then return end
    if not hasTag(ascOf(pawn), "Ability.Action.Stance") or deflectKeyHeld() then return end
    local new = math.min(max, cur + max * REGEN_PER_SEC * math.min(dt, 0.05))
    tl.try("shachi regen", RT.setShachi, hpSet, new)
    shachiLast = new
    if not shachiChecked then
        shachiChecked = true
        local okR, back = pcall(RT.curOf, hpSet.Shachi)
        log("sat khi regen: %.1f -> %.1f, read back %s", cur, new, okR and tostring(back) or "error")
        local okL, list = pcall(function()
            local lib = obj("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
            local handles = unwrap(ascOf(pawn):GetActiveEffects({}))
            local names = {}
            for _, h in pairs(type(handles) == "table" and handles or {}) do
                local okG, ge = pcall(function() return lib:GetGameplayEffectFromActiveEffectHandle(unwrap(h)) end)
                names[#names + 1] = okG and valid(ge) and short(ge:GetClass()) or "?"
            end
            return table.concat(names, ", ")
        end)
        log("active effects in the stance: %s", okL and list or ("error " .. tostring(list)))
    end
end

-- ---------------------------------------------------------------- loop + keys
local controller, lastErr = nil, {}
local function player()
    -- no controller (menus, loading): GetPlayerController walks the object
    -- table, so it is asked at most every 0.5 s, not every tick
    if not valid(controller) then
        if os.clock() < (tl.ctrlAt or 0) then return nil end
        tl.ctrlAt = os.clock() + 0.5
        controller = UEHelpers.GetPlayerController()
    end
    if not valid(controller) then return nil end
    local ok, p = pcall(RT.pawnOf, controller)
    return ok and valid(p) and p or nil
end

-- An error in the dodge or parry pauses it for 2, 4, 8 ... 60 s, then it tries
-- again (until 1.3.4 one error, e.g. while the character was being rebuilt,
-- stopped it until its hotkey was pressed). The hotkey retries at once.
-- (the count is forgotten after 60 s without an error: a paused tick also
-- returns fine, so it cannot be cleared on the next good call)
tl.fails, tl.failAt, tl.errN, tl.pauseAt = {}, {}, {}, {}
local function guarded(what, fn, ...)
    -- a stage that threw three times in a row is paused (2, 4 ... 60 s) instead of
    -- paying a throw every frame; dodge and parry keep their own longer pause below
    local pause = tl.pauseAt[what]
    if pause and os.clock() < pause then return false end
    local ok, a
    if settings.perf then -- per-stage p50/p95, so "which stage is expensive" has an answer
        local t0 = os.clock()
        ok, a = pcall(fn, ...)
        tl.perfLabel(what, os.clock() - t0)
    else
        ok, a = pcall(fn, ...)
    end
    if ok then
        tl.errN[what] = nil
        if tl.fails[what] and os.clock() - tl.failAt[what] > 60 then tl.fails[what] = nil end
        return true, a
    end
    local err = a
    tl.failAt[what] = os.clock()
    local n = (tl.errN[what] or 0) + 1
    tl.errN[what] = n
    if n >= 3 then tl.pauseAt[what] = os.clock() + math.min(60, 2 ^ (n - 2)) end
    local first = tostring(err) ~= lastErr[what]
    if first then
        lastErr[what] = tostring(err)
        tl.err(what, err)
    end
    if what == "dodge" or what == "parry" then
        tl.fails[what] = (tl.fails[what] or 0) + 1
        local wait = math.min(60, 2 ^ tl.fails[what])
        if what == "dodge" then dodgeFailed = os.clock() + wait else parryFailed = os.clock() + wait end
        tl.failAt[what] = os.clock() + wait -- quiet time counts from the end of the pause
        if first or tl.fails[what] <= 3 then
            log("auto %s paused for %d s (press %s to retry now)", what, wait, settings.keys[what])
        end
    end
end

-- cutscenes (report 1.3.2: crash in the carriage dialogue on the way into Pang
-- Town, fine with the mod off): the mod does nothing while dialogue controls the
-- character, while a sequence that hides the player or takes its input plays,
-- while move and look input are both off, and for a moment after a new
-- character appears; then for tl.RESUME s more. The perfect tag is taken off
-- when it starts, or the game keeps raising the deflect stance by itself.
-- (1.3.4 test: with a NotifyOnNewObject watch on LevelSequenceActor the main
-- loop never ran, no error anywhere, and the mod did nothing; that callback
-- runs while the game builds objects, maybe off the game thread. A sequence
-- that takes the controls shows as "input off" anyway.)
tl.CUT_EVERY, tl.RESUME, tl.cutAt, tl.cutWhy, tl.resumeAt = 0.1, 1.5, 0, nil, 0
tl.cutscene = function(p)
    local okD, d = pcall(function() return unwrap(p.IsControlByDialogue) end)
    if okD and d == true then return "dialogue" end
    local okM, m = pcall(function() return unwrap(controller:IsMoveInputIgnored()) end)
    local okL, l = pcall(function() return unwrap(controller:IsLookInputIgnored()) end)
    if okM and okL and m == true and l == true then return "input off" end
    return nil
end
tl.paused = function(p)
    local t = os.clock()
    if t >= tl.cutAt then
        tl.cutAt = t + tl.CUT_EVERY
        local addr = p:GetAddress()
        local why = addr ~= tl.pawnAddr and "new character" or tl.cutscene(p)
        tl.pawnAddr = addr
        if why then
            if not tl.cutWhy then
                log("paused: %s", why)
                if why == "new character" then pcall(tl.fxClear) end
                if perfectPawn == addr then setPerfect(p, false, true) perfectPawn = nil end
            end
            tl.cutWhy, tl.resumeAt = why, t + tl.RESUME
        end
    end
    if tl.cutWhy and t >= tl.resumeAt then
        log("resumed after: %s", tl.cutWhy)
        tl.cutWhy = nil
    end
    return tl.cutWhy ~= nil
end

-- 1.6.2: modular seams. Queries (ad_query), the timeline store (ad_timeline),
-- the shared rules (ad_policy) and the controlled input entry (ad_input) are their
-- own files. Decisions and their order are untouched: the same functions run, but
-- a press, a release, an end-stance and a tag write now pass one door that asks
-- the rules first. A failure here leaves the plain functions in place.
do
    local function install()
        local pol = dofile(MOD_DIR .. "Scripts/ad_policy.lua").new({
            parryOn = function() return settings.parry end,
            pdOwns = function() return tl.guardOwned() end,
            selfStance = function()
                if not valid(currentPawn) or not tl.stanceUp then return false end
                return tl.stanceUp(currentPawn) and true or false
            end,
            log = log, emit = tl.emit,
        })
        local IN = dofile(MOD_DIR .. "Scripts/ad_input.lua").attach({
            policy = pol, emit = tl.emit, log = log,
            pressRaw = tl.pressTap, release = tl.releaseHeldKey, endStance = endStance,
        })
        tl.policy, tl.input = pol, IN
        tl.pressTap = IN.pressGuard
        tl.releaseHeldKey = IN.releaseGuard
        endStance = IN.endStance
        log("input choke: rules %s", pol.who())
    end
    local okI, errI = pcall(install)
    if not okI then
        log("input choke unavailable: %s", tostring(errI))
        -- keep callers simple: no rules, an honest pass-through (audit P1-4)
        tl.input = {
            inject = function(_, action) return injectKey(action) end,
            stats = function() return 0, 0 end,
        }
    end
end

-- The main loop logs when it first runs, when it first sees the player and every
-- tl.ALIVE_EVERY s, so a log shows whether it runs. Each start has an id; an
-- older copy still running stops itself. tl.check (on every hotkey) starts it
-- again when it has been silent for tl.SILENT s.
-- perf = on: the mod's own time per tick and per hook call, and the gaps
-- between ticks (the loop runs once a frame, so a gap is a frame hitch, whatever
-- caused it), summed up in perf_log.txt every tl.PERF_EVERY s
tl.PERF_EVERY, tl.PERF_GAP, tl.PERF_RING = 10, 0.04, 256
tl.perf = { at = os.clock(), n = 0, sum = 0, max = 0, hooks = { n = 0, sum = 0, max = 0 }, gaps = {} }
tl.perfSamples, tl.gapN = {}, 0
if settings.perf then
    local f = io.open(MOD_DIR .. "perf_log.txt", "w")
    if f then
        f:write(os.date("%H:%M:%S") .. " perf log, every " .. tl.PERF_EVERY
            .. " s (p50/p95/p99 from a " .. tl.PERF_RING .. "-sample ring per stage)\n")
        f:close()
    end
end
tl.perfAdd = function(r, dt)
    r.n, r.sum = r.n + 1, r.sum + dt
    if dt > r.max then r.max = dt end
end
-- one small ring per stage: an average hides the tail, and the tail is the budget
tl.perfLabel = function(what, dt)
    local s = tl.perfSamples[what]
    if not s then s = { n = 0, sum = 0, max = 0, at = 0, fill = 0, ring = {} } tl.perfSamples[what] = s end
    tl.perfAdd(s, dt)
    s.at = s.at % tl.PERF_RING + 1
    s.ring[s.at] = dt
    if s.fill < tl.PERF_RING then s.fill = s.fill + 1 end
end
tl.perfPct = function(s, p)
    if s.fill == 0 then return 0 end
    local t = {}
    for i = 1, s.fill do t[i] = s.ring[i] end
    table.sort(t)
    return t[math.min(s.fill, math.max(1, math.ceil(s.fill * p)))]
end
tl.perfTick = function(t0, t1)
    local P = tl.perf
    if P.last and t0 - P.last > tl.PERF_GAP then
        tl.gapN = tl.gapN + 1 -- counted, not dropped after 20 samples (audit P0-1)
        if #P.gaps < 3 then P.gaps[#P.gaps + 1] = string.format("%s %.0fms", os.date("%H:%M:%S"), (t0 - P.last) * 1000) end
    end
    P.last = t1
    tl.perfAdd(P, t1 - t0)
    tl.perfLabel("tick", t1 - t0)
    if t1 - P.at < tl.PERF_EVERY then return end
    local f = io.open(MOD_DIR .. "perf_log.txt", "a")
    if f then
        local h, tk = P.hooks, tl.perfSamples.tick
        f:write(string.format("%s %.0fs: mod per tick avg %.2fms p50 %.2f p95 %.2f p99 %.2f max %.1fms (%d ticks) | hooks %d calls, sum %.1fms, max %.1fms | lua %.0fKB | hitches>%dms: %d %s\n",
            os.date("%H:%M:%S"), t1 - P.at, P.n > 0 and P.sum / P.n * 1000 or 0,
            tk and tl.perfPct(tk, 0.5) * 1000 or 0, tk and tl.perfPct(tk, 0.95) * 1000 or 0,
            tk and tl.perfPct(tk, 0.99) * 1000 or 0, P.max * 1000, P.n, h.n, h.sum * 1000,
            h.max * 1000, collectgarbage("count"), tl.PERF_GAP * 1000, tl.gapN,
            #P.gaps > 0 and table.concat(P.gaps, ", ") or "none"))
        local names = {}
        for name in pairs(tl.perfSamples) do if name ~= "tick" then names[#names + 1] = name end end
        table.sort(names)
        for _, name in ipairs(names) do
            local s = tl.perfSamples[name]
            f:write(string.format("  stage %-14s n=%-6d avg %.3fms p50 %.3f p95 %.3f p99 %.3f max %.3fms\n",
                name, s.n, s.sum / s.n * 1000, tl.perfPct(s, 0.5) * 1000, tl.perfPct(s, 0.95) * 1000,
                tl.perfPct(s, 0.99) * 1000, s.max * 1000))
        end
        f:close()
    end
    tl.perf = { at = t1, last = t1, n = 0, sum = 0, max = 0, hooks = { n = 0, sum = 0, max = 0 }, gaps = {} }
    tl.perfSamples, tl.gapN = {}, 0
end
tl.ALIVE_EVERY, tl.SILENT, tl.loopId, tl.ticks, tl.tickAt, tl.aliveAt = 5, 10, 0, 0, os.clock(), 0
-- Warm-up task, run one per tick from the loop: a read-only index of the learned
-- timeline (hits, first/last, known grab). Built after the load path, so the 69-77 ms
-- load stays put and the index is ready before the first fight. A failure is
-- recorded by the queue and never reaches the game loop.
if tl.warm then
    tl.warm.task("timeline index", function()
        local idx, n, grabs = {}, 0, 0
        for name, hits in pairs(hitTimes) do
            local base = RT.bname(name) or name
            local first, last
            for i = 1, #hits do
                local v = hits[i]
                if type(v) == "number" then
                    if not first or v < first then first = v end
                    if not last or v > last then last = v end
                end
            end
            local grab = (tl.dat and tl.dat.isGrab and tl.dat.isGrab(base) == true) or false
            idx[base] = { n = #hits, first = first, last = last, grab = grab }
            n = n + 1
            if grab then grabs = grabs + 1 end
        end
        tl.busIdx = idx
        log("warm: timeline index %d abilities (%d grabs)", n, grabs)
    end)
end
tl.main = function(id)
    -- after teardown nothing may decide, even if a hook or timer fires one last time
    if tl.stopped then return false end
    if id ~= tl.loopId then return true end
    local t = os.clock()
    tl.tickAt, tl.ticks = t, tl.ticks + 1
    if tl.ticks == 1 then log("main loop running (start %d)", id) tl.aliveAt = t + tl.ALIVE_EVERY end
    if t >= tl.aliveAt then
        tl.aliveAt = t + tl.ALIVE_EVERY
        log("alive: %d ticks, player %s, loop %s", tl.ticks,
            currentPawn and "on" or (tl.cutWhy and ("paused: " .. tl.cutWhy) or "none"),
            tl.loopSchedule or "none")
        -- 5 s metrics line: the bus drop counter and the policy denials had no
        -- periodic reader, so the "budget alarm" was never observed (audit P1-7)
        if tl.led then
            local asked, denied, drop = 0, 0, 0
            if tl.input and tl.input.stats then asked = select(1, tl.input.stats()) or 0 end
            if tl.policy and tl.policy.stats then denied = select(2, tl.policy.stats()) or 0 end
            if tl.bus and tl.bus.stats then drop = tl.bus.stats().dropped or 0 end
            local asks, known = 0, 0
            if tl.inputState then asks, known = tl.inputState.stats() end
            tl.led("metrics: drop=%d asked=%d denied=%d lua=%.0fKB hold=%d/%d", drop, asked, denied,
                collectgarbage("count"), known, asks)
        end
    end
    if hk.menu then guarded("menu config", hk.menu.poll, hk.menu, t) end
    -- the shim is throttled inside: a tick beyond its 0.5 s window costs two compares
    if hk.bridge then guarded("menu bridge", hk.bridge.poll, hk.bridge) end
    guarded("watchdog", tl.check) -- the watchdog no longer waits for a hotkey (audit P0-3)
    -- observability only: bounded delivery, one warm-up task per tick
    if tl.bus then tl.bus.drain(tl.DRAIN_N) end
    if tl.warm and not tl.warm.done() then
        tl.warm.step(1)
        if tl.warm.done() then tl.emit("warm_done", tl.warm.failed(), tl.bus and tl.bus.stats().dropped or 0, 0) end
    end
    tl.tickResults(t)
    local p = player()
    if not p then return false end
    if not tl.sawPlayer then tl.sawPlayer = true log("player found: %s", short(p)) end
    -- hooks see no player while paused (they check currentPawn)
    if tl.paused(p) then currentPawn = nil return false end
    tl.pruneHandles()
    -- guard ownership is refreshed whether or not both components resolve: a stale
    -- state used to outlive a character rebuild (audit P2-3)
    guarded("pbzpd", tl.pd.tick)
    local deflect = component(p, "Deflect Component")
    guarded("perfect", tickPerfect, p, deflect)
    local input = component(p, "Ability Input Component")
    currentPawn = p
    local experiments = settings.dodgeAttacks ~= "" or LEARN
    if deflect and not RT.installed("attack") and (DEBUG or experiments) then hookAttacks(deflect) end
    if deflect and input then tl.decide(p, deflect, input, nowOf(p)) end
    return false
end
-- 1.6.5 (audit P0-3): the per-frame decision chain is a named function, so the
-- offline gate can drive it with fake deflect/input instead of only asserting that
-- the loop exists. Same order, same guards as before; the test marker exposes it.
tl.decide = function(p, deflect, input, now)
    local experiments = settings.dodgeAttacks ~= "" or LEARN
    if DEBUG or experiments then guarded("timeline", trackFrames, deflect, now) end
    guarded("read frames", tl.fxScan, deflect, now) -- 1.4.3: hit times for the presses
    if DEBUG then guarded("frames probe", tl.probeFrames, p, deflect, now) end
    guarded("health", trackHealth, p, now)
    guarded("release", releaseHeldGuard, p, deflect)
    if DEBUG or experiments or TL.count() > 0 then guarded("enemies", watchEnemies, p) end
    -- also with parry off: without the hook the object walk above takes over
    if TL.count() > 0 then guarded("activation hook", hookActivation) end
    if DEBUG then guarded("stance", watchStance, p, deflect) end
    if LEARN then guarded("manual dodge", watchManualDodge) end
    guarded("sat khi", tickShachi, p)
    guarded("guard release", tickGuardRelease, p, deflect)
    -- red first: a dodge must not be swallowed by a parry attempt
    guarded("dodge", tickDodge, deflect, input, now)
    guarded("timed dodge", tickTimedDodge, input, now)
    guarded("tap hold", tickTapHold)
    -- 1.6.7: both features are off by default and cost one boolean check a frame
    if settings.hookCounter == "on" or settings.shieldCounter == "on" then
        guarded("counter", tl.tickCounter, now)
        guarded("shield switch", tl.tickShieldSwitch, now)
    elseif tl.counterHold then
        tl.counterHold = nil -- switched off while a counter was in flight
    end
    if settings.receipt then guarded("receipt", tl.tickReceipt, p) end
    guarded("parry", tickParry, deflect, input, now)
    return false
end
-- One cancel path: never throws, reports once, and tells the caller whether the
-- handle is really gone (a false answer must be remembered, review F2).
tl.cancelLoop = function(handle)
    if handle == nil then return true end
    if type(CancelDelayedAction) ~= "function" then
        if not tl.loopCancelWarned then
            tl.loopCancelWarned = true
            log("main loop: CancelDelayedAction unavailable; stale callback is generation-guarded")
        end
        return false
    end
    local ok = pcall(CancelDelayedAction, handle)
    -- a false answer means the engine no longer knows the handle (it already ran or
    -- was cleared), which is exactly the outcome wanted; only a throw is a failure
    if ok then return true end
    if not tl.loopCancelWarned then
        tl.loopCancelWarned = true
        log("main loop: could not cancel previous scheduler handle %s", tostring(handle))
    end
    return false
end
tl.start = function(prefer)
    tl.loopId, tl.ticks, tl.tickAt = tl.loopId + 1, 0, os.clock()
    tl.loopVerifyAt = nil
    local id = tl.loopId
    -- The UE4SS delayed-action API returns an owned handle. Cancel the previous
    -- watchdog loop before replacing it; otherwise a restart leaves a stale timer
    -- waking up forever even though tl.main rejects its old generation id.
    -- A handle is only forgotten once the cancel is known to have worked: an
    -- uncancellable loop keeps waking for the rest of the session, so it is kept
    -- and retried on the next start instead of leaking (review F2).
    if tl.loopHandle ~= nil then
        local previous = tl.loopHandle
        tl.loopHandle = nil
        if not tl.cancelLoop(previous) then
            local stale = tl.loopStale or {}
            if #stale < 8 then stale[#stale + 1] = previous end
            tl.loopStale = stale
        end
    end
    if tl.loopStale then
        local keep, kept = {}, 0
        for i = 1, #tl.loopStale do
            local handle = tl.loopStale[i]
            if not tl.cancelLoop(handle) and kept < 8 then
                kept = kept + 1
                keep[kept] = handle
            end
        end
        tl.loopStale = kept > 0 and keep or nil
    end
    -- An error in a tick is logged (once per message) and the loop goes on: an
    -- error thrown out of the callback could end the loop for good.
    local function tick()
        local t0 = settings.perf and os.clock()
        local ok, r = pcall(tl.main, id)
        if t0 then tl.perfTick(t0, os.clock()) end
        if ok then return r end
        if tostring(r) ~= tl.mainErr then
            tl.mainErr = tostring(r)
            log("main loop error: %s", tl.mainErr)
        end
        return false
    end

    -- Defense decisions sample frame-owned combat state, so prefer the UE4SS
    -- EngineTick scheduler: one callback per rendered/game frame, no 10 ms timer
    -- wakeups between frames. Older UE4SS builds retain the timer fallback.
    -- 1.6.5 (audit P1-1): both paths use one rule - the call did not throw means the
    -- loop is scheduled, and the handle may be nil (a handle-less but working API was
    -- reported as "no loop at all"). Whether it actually ticks is checked separately:
    -- tl.loopVerifyAt makes tl.check try the other path once.
    local function schedule(kind)
        if kind == "frame" then
            if not (EngineTickAvailable and type(LoopInGameThreadAfterFrames) == "function") then
                return false, "no EngineTick scheduler"
            end
            local ok, handle = pcall(LoopInGameThreadAfterFrames, 1, tick)
            if not ok then return false, tostring(handle) end
            tl.loopHandle, tl.loopSchedule, tl.loopPath = handle, "frame", "frame"
            return true
        end
        if type(LoopInGameThreadWithDelay) ~= "function" then return false, "no timer API" end
        local ok, handle = pcall(LoopInGameThreadWithDelay, 10, tick)
        if not ok then return false, tostring(handle) end
        tl.loopHandle, tl.loopSchedule, tl.loopPath = handle, "timer", "timer"
        return true
    end
    local order = (prefer == "timer") and { "timer", "frame" } or { "frame", "timer" }
    local okA, whyA = schedule(order[1])
    if okA then
        tl.loopVerifyAt = os.clock() + 2
        if tl.loopScheduleLogged ~= order[1] then
            tl.loopScheduleLogged = order[1]
            log("main loop scheduler: %s", order[1] == "frame" and "EngineTick, every 1 frame" or "10 ms compatibility timer")
        end
        return
    end
    local okB, whyB = schedule(order[2])
    if okB then
        tl.loopVerifyAt = os.clock() + 2
        log("main loop scheduler: %s unavailable (%s), using %s", order[1], tostring(whyA), order[2])
        if tl.loopScheduleLogged ~= order[2] then
            tl.loopScheduleLogged = order[2]
            log("main loop scheduler: %s", order[2] == "frame" and "EngineTick, every 1 frame" or "10 ms compatibility timer")
        end
        return
    end
    tl.loopSchedule = "failed"
    log("main loop scheduler failed: %s (%s); %s (%s)", order[1], tostring(whyA), order[2], tostring(whyB))
end
-- force = a human asked for it (hotkey). It restarts even after the automatic
-- budget is spent, and resets that budget so the watchdog works again (review F3).
tl.check = function(force)
    if tl.stopped then
        if not force then return end
        -- teardown put everything down; a human asking for a restart re-arms it
        tl.stopped, tl.loopDead = false, nil
        if tl.eventsOpen then pcall(tl.eventsOpen) end
        log("main loop: re-armed after teardown")
    end
    local quiet = os.clock() - tl.tickAt
    -- 1.6.5 (audit P1-1): a scheduler call that returned without throwing may still
    -- never tick. Two seconds after such a start, with no tick at all, the other
    -- path is tried once. Only a hotkey or an already-live loop reaches this: the
    -- watchdog itself runs inside the loop it watches, so automatic recovery from a
    -- totally silent loop is impossible and is logged instead.
    if tl.loopVerifyAt and tl.ticks == 0 and os.clock() > tl.loopVerifyAt then
        local was = tl.loopPath
        tl.loopVerifyAt = nil
        log("main loop scheduler: %s scheduled but no tick in %.0f s, forcing the other path",
            tostring(was), os.clock() - tl.tickAt)
        tl.start(was == "frame" and "timer" or "frame")
        return
    end
    -- A healthy loop must not be restarted by a hotkey press: every restart bumps
    -- the generation and writes a "main loop running" line (review F3).
    if quiet <= tl.SILENT then return end
    if force then
        tl.loopId, tl.loopDead = 0, nil
        log("main loop: manual restart requested after %.0f s since the last tick", quiet)
        tl.start()
        return
    end
    if tl.loopId < 20 then
        log("main loop silent for %.0f s (%d ticks), starting it again", quiet, tl.ticks)
        tl.start()
        return
    end
    if not tl.loopDead then
        tl.loopDead = true
        log("main loop dead after %d starts: automatic restarts stopped (a hotkey re-arms it)", tl.loopId)
        -- 1.6.5: a loop that cannot be restarted cannot decide, so put the hooks,
        -- the timer and the buffered sinks down instead of leaving them firing.
        tl.teardown("main loop dead after " .. tostring(tl.loopId) .. " starts")
    end
end
-- One place that undoes everything the mod installed (audit P1-4). Order matters:
-- stop scheduling first (no new tick may start while the hooks come down), then
-- remove the hooks, then the timer, then flush what is still buffered. Idempotent;
-- tl.check(true) re-arms the whole thing, so a dead loop is recoverable by hand.
tl.teardown = function(reason)
    if tl.stopped then return false end
    -- the gate goes up first: an unregistering hook can fire once more, and a
    -- decision taken inside teardown's own call stack would otherwise escape it
    tl.stopped = true
    local why = tostring(reason or "requested")
    local loops = 0
    if tl.loopHandle ~= nil then
        if tl.cancelLoop(tl.loopHandle) then loops = loops + 1 end
        tl.loopHandle = nil
    end
    if tl.loopStale then
        for i = 1, #tl.loopStale do
            if tl.cancelLoop(tl.loopStale[i]) then loops = loops + 1 end
        end
        tl.loopStale = nil
    end
    tl.loopVerifyAt = nil
    -- backstop for anything not remembered above: one call clears every delayed
    -- action this mod owns (upstream ClearAllDelayedActions)
    if type(ClearAllDelayedActions) == "function" then
        local okC, e = pcall(ClearAllDelayedActions)
        if not okC then tl.err("delayed clear", e) end
    end
    local hooks = RT.unhookAll()
    local toastStopped = 0
    if toast and pcall(toast.hide, toast) then toastStopped = 1 end
    if tl.ledFlush then pcall(tl.ledFlush) end
    if tl.eventsFlush then pcall(tl.eventsFlush) end
    if tl.eventsClose then pcall(tl.eventsClose) end
    -- drop the state a late callback could still act on, plus the install
    -- bookkeeping a re-armed mod needs back (activationTries is a 12-attempt budget)
    tl.activationHooked, tl.attackHookAt = false, nil
    activationTry, activationTries = 0, 0
    tl.tapPending, tl.receipt = nil, nil
    tl.busIdx = nil
    log("teardown (%s): %d loop(s) cancelled, %d hook(s) removed, %d toast stopped",
        why, loops, hooks, toastStopped)
    return true
end
-- Configuration changes run before any input decisions, including while in menus.
-- State with startup captures or shared guard ownership is deliberately restart-only.
do
    if hk.menu then
        tl.menu = hk.menu
        hk.menu.onApply = function(changed)
            DEBUG = settings.debug
            tl.TAP_GAP, tl.grabLead = settings.minGap, settings.grabLeadMs
            if changed.read_frames then pcall(tl.fxClear) end
            if changed.receipt then tl.receipt = nil end
            if changed.perfect then perfectFailed, recheckAt = false, 0 end
            if changed.parry then
                parryFailed, parryWorks, lastErr.parry, tl.fails.parry = false, nil, nil, nil
                if not settings.parry then
                    -- Stop our pending/repeated injections, not a human/PBZPD-held guard.
                    tl.tapPending, tapHold, tl.receipt = nil, nil, nil
                    tl.tapEndAt = os.clock()
                end
            end
            if changed.ledger and not settings.ledger and tl.ledFlush then tl.ledFlush() end
            if changed.perf then
                tl.perf = { at = os.clock(), n = 0, sum = 0, max = 0,
                    hooks = { n = 0, sum = 0, max = 0 }, gaps = {} }
            end
        end
        if hk.menu.lastText then
            log("native menu config active; restart-only fields remain pending until the next game start")
        else
            log("native menu config pending: last legacy values kept, hotkeys fail closed until valid JSON is available")
        end
    end
end
tl.start()

-- the key's new state, in the log and on screen
local function notify(fmt, ...)
    local msg = string.format(fmt, ...)
    log("%s", msg)
    if not settings.hotkeyMessage then return end
    local ok, err = toast:show(msg, 2.5)
    if not ok and err then log("on-screen text off: %s", tostring(err)) end
end
local TEXT = {
    en = { on = "ON", off = "OFF", perfect = "%s: Perfect deflect %s", dodge = "%s: Auto dodge: %s",
        parry = "%s: Auto parry %s", modes = { off = "OFF", red = "red attacks only", all = "all attacks" } },
    vi = { on = "BẬT", off = "TẮT", perfect = "%s: Đỡ hoàn hảo %s", dodge = "%s: Tự né: %s",
        parry = "%s: Tự đỡ %s", modes = { off = "TẮT", red = "chỉ đòn đỏ", all = "tất cả đòn" } },
}
local function text() return TEXT[settings.lang] or TEXT.en end

hk.actions = {
    snapshot = function()
        if not DEBUG then return end
        local ok, err = pcall(snapshot, player())
        if not ok then log("snapshot error: %s", tostring(err)) end
    end,
    perfect = function()
        if tl.guardOwned() then
            log("perfect hotkey: left to PBZPerfectDefense (AutoGuard=On), pbzpd=off turns that off")
            tl.led("hotkey: perfect deflect left to PBZPerfectDefense")
            return
        end
        if hk.menu then
            if not hk.menu:toggle("perfect") then return end
        else settings.perfect = not settings.perfect end
        perfectFailed = false
        saveSettings()
        notify(text().perfect, settings.keys.perfect, settings.perfect and text().on or text().off)
    end,
    dodge = function()
        if hk.menu then
            if not hk.menu:toggle("dodge") then return end
        else
            local i = 1
            for k, m in ipairs(DODGE_MODES) do if m == settings.dodge then i = k end end
            settings.dodge = DODGE_MODES[i % #DODGE_MODES + 1]
        end
        dodgeFailed, lastErr.dodge, tl.fails.dodge = false, nil, nil
        saveSettings()
        notify(text().dodge, settings.keys.dodge, text().modes[settings.dodge] or settings.dodge)
    end,
    parry = function()
        if tl.guardOwned() then
            log("parry hotkey: left to PBZPerfectDefense (AutoGuard=On), pbzpd=off turns that off")
            tl.led("hotkey: auto parry left to PBZPerfectDefense")
            return
        end
        if hk.menu then
            if not hk.menu:toggle("parry") then return end
        else settings.parry = not settings.parry end
        parryFailed, lastErr.parry, parryWorks, tl.fails.parry = false, nil, nil, nil
        saveSettings()
        notify(text().parry, settings.keys.parry, settings.parry and text().on or text().off)
    end,
}
if settings.badKeys then log("unknown key name, default kept:%s", settings.badKeys) end
hk.register = function()
    for _, w in ipairs(hk.order) do
        local _, key, mods = hk.parse(settings.keys[w])
        if key then
            local fn = function() ExecuteInGameThread(function() tl.check(true) hk.actions[w]() end) end
            if #mods > 0 then RegisterKeyBind(key, mods, fn) else RegisterKeyBind(key, fn) end
        end
    end
end
hk.register()
-- older settings files have no key_* / parry_reach / black_flash lines: write them so they can be changed
if not settings.keyLines or not settings.reachLine or not settings.blackLine or not settings.learnLine
    or not settings.timingLine or not settings.timing2Line or not settings.dataLine or not settings.pbzpdLine then saveSettings() end

log("loaded v" .. tl.VERSION .. ":perfect=%s%s dodge=%s parry=%s debug=%s%s (%s perfect, %s dodge, %s parry)",
    settings.perfect and "on" or "off", settings.perfectMode ~= "always" and (" (" .. settings.perfectMode
        .. (settings.perfectMode == "give" and (", black flash " .. settings.blackFlash) or "") .. ")") or "",
    settings.dodge, settings.parry and "on" or "off", settings.debug and "on" or "off",
    settings.perf and " perf=on" or "",
    settings.keys.perfect, settings.keys.dodge, settings.keys.parry)
log("timeline guard: %d enemy abilities in hit_times.txt (%d red/blue: blue parried, red dodged)", TL.count(), tl.colorPairs or 0)
-- 1.6.2: the public surface in one place. Everything else on tl is internal and may
-- be renamed; the count is logged so a growing API is visible (audit P1-quality).
do
    tl.log, tl.logState = log, logState -- the cap and the stamp are testable
    tl.api = {
        "tickReceipt", "fxScan", "fxDue", "fxClear", "pressTap", "releaseHeldKey",
        "menu", "input", "policy", "bus", "warm", "led", "ledFlush", "emit", "err", "logState",
        "dat", "seed", "seedRows", "pd", "guardOwned", "pruneHandles", "VERSION", "busIdx", "api", "log", "teardown",
        "holdAsk", "installInputState", "installCounter", "counterTry",
    }
    local fields = 0
    for _ in pairs(tl) do fields = fields + 1 end
    log("tl api: %d public names of %d fields", #tl.api, fields)
end

-- Test-only surface: active only inside an isolated copy that carries the marker
-- file (tools/run_integration.sh creates it). A normal install exposes no globals.
;(function() -- locals live in this closure: the chunk is at its 200-local ceiling
    local marker = io.open(MOD_DIR .. ".ad-menu-test-only", "r")
    if not marker then return end
    marker:close()
    _G.__TL, _G.__HK, _G.__S = tl, hk, settings
    -- audit P0-3: the decision chain had no offline coverage at all
    _G.__DECIDE, _G.__CHECK_RELEASE = tl.decide, tl.checkRelease
    _G.__QUEUE_TIMELINE, _G.__TEARDOWN = queueTimeline, tl.teardown
    _G.__RUNTIME = {
        version = _VERSION, jit = rawget(_G, "jit") and rawget(_G, "jit").version or nil,
        compat = RT.compat ~= nil,
    }
end)()
