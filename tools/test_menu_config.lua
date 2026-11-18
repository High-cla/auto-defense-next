-- Pure in-memory config tests: run from the mod directory with Lua 5.4 or LuaJIT.
local json = dofile("Scripts/ad_json.lua")
local config = dofile("Scripts/menu_config.lua")
local n = 0
local function check(ok, why) assert(ok, why); n = n + 1 end
local function eq(a, b, why) check(a == b, why or (tostring(a) .. " ~= " .. tostring(b))) end
local state = { perfect = false, perfectMode = "always", blackFlash = "dodge", dodge = "red", parry = true,
    parryMethod = "key", dodgeAttacks = "", debug = false, lang = "en", guardRelease = true,
    guardReleaseAfter = 1, guardReleaseCombatEnd = 1, hotkeyMessage = true, perf = false, parryReach = 3, learn = true,
    readFrames = true, parryLeadCfg = "auto", dodgeLead = .12, dodgeGap = .22, dodgeIframe = .24,
    pairFrames = true, receipt = true, receiptRetry = false, ledger = true, latency = true,
    data = true, dataOff = { GA_test = true }, dataTags = false, seedFallback = "record", minGap = .09, grabLeadMs = .35,
    dodgeCd = true, busySkip = true, flurryGuard = true, pbzpd = "auto",
    keys = { perfect = "F7", dodge = "F8", parry = "F9", snapshot = "F6" } }
local files, writes, logs, applied = {}, 0, {}, {}
local function read(path) return files[path], files[path] == nil and 2 or nil end
local function write(path, text, expected)
    if expected ~= files[path] then return nil, "conflict" end
    files[path], writes = text, writes + 1
    return true
end
local m = config.new(state, { dir = "test/", json = json, read = read, write = write,
    log = function(s) logs[#logs + 1] = s end,
    keyValid = function(k) return k == "none" or k:match("^F%d+$") or k:match("^CTRL%+F%d+$") end })
check(m:load(true), "initial migration")
local initial = assert(json.decode(files[m.path]))
eq(initial.perfect, false, "preserve legacy perfect off")
eq(initial.parry_reach, 3, "preserve legacy reach")
eq(initial.guard_release_after, 1)
eq(initial.guard_release_combat_end, 1)
eq(initial.dodge_lead_ms, 120)
eq(initial.grab_lead_ms, 350, "no milliseconds export rounding noise")
eq(initial.data_off, "GA_test")
eq(initial.seed_fallback, "record", "the safe record mode is migrated by default")
eq(writes, 1, "migration happens once")
check(m:load(true)); eq(writes, 1, "existing config not rewritten")
m.onApply = function(changes) applied[#applied + 1] = changes end
local function edit(values)
    local raw = assert(json.decode(files[m.path]))
    for k, v in pairs(values) do raw[k] = v end
    files[m.path] = assert(json.encode(raw))
end
edit({ parry_reach = 6, debug = true, min_gap_ms = 110, grab_lead_ms = 400, seed_fallback = "on",
    key_parry = "CTRL+F10", data = false, extra = "preserve me", extra_null = json.NULL })
check(m:load()); eq(state.parryReach, 6); eq(state.debug, true)
eq(state.minGap, .11); eq(state.grabLeadMs, .4); eq(state.seedFallback, "on", "seed mode hot-applies")
eq(state.keys.parry, "F9", "key binding needs restart")
eq(state.data, true, "data loader needs restart")
check(m.pending.key_parry and m.pending.data and not m.pending.seed_fallback, "only restart fields stay pending")
check(applied[#applied].min_gap_ms and applied[#applied].debug and applied[#applied].seed_fallback, "changed-field callback")
-- A hotkey reads latest menu values and writes only its key: pending restart values survive.
edit({ parry_reach = 7 })
check(m:toggle("parry")); eq(state.parry, false); eq(state.parryReach, 7)
local saved = assert(json.decode(files[m.path]))
eq(saved.key_parry, "CTRL+F10"); eq(saved.data, false); eq(saved.extra, "preserve me")
eq(saved.extra_null, json.NULL, "unknown null survives")
-- Invalid input is a transaction failure; neither state nor file is silently replaced.
local good = files[m.path]
files[m.path] = '{"parry":false,'
check(not m:load()); eq(state.parryReach, 7); eq(files[m.path], '{"parry":false,')
check(not m:toggle("parry"), "don't overwrite malformed JSON from a hotkey")
files[m.path] = good
edit({ min_gap_ms = -1 }); check(not m:load()); eq(state.minGap, .11)
files[m.path] = good
edit({ seed_fallback = "invalid" }); check(not m:load(), "unknown seed mode is rejected"); eq(state.seedFallback, "on")
files[m.path] = good
edit({ parry_lead = "manual", parry_lead_seconds = .14 }); check(m:load()); eq(state.parryLeadCfg, .14)
edit({ parry_lead = "auto" }); check(m:load()); eq(state.parryLeadCfg, "auto")
-- Strict JSON, escapes and non-BMP round trip; no arrays/objects or nonfinite numbers.
local parsed = assert(json.decode([=[{"s":"\u4e2d\ud83d\ude00","n":1.25e2,"b":false,"null":null}]=]))
eq(parsed.s, "中😀"); eq(parsed.n, 125); eq(parsed.b, false); eq(parsed.null, json.NULL)
eq(assert(json.decode(assert(json.encode(parsed)))).s, parsed.s)
for _, bad in ipairs({'{"x":01}', '{"x":1.}', '{"x":1e}', '{"x":[]}', '{"x":{}}', '{"x":1e999}', [=[{"x":"\ud800"}]=]}) do
    check(json.decode(bad) == nil, "strict JSON: " .. bad)
end
check(json.encode({x = math.huge}) == nil)
-- Complete event file only; duplicate notifications don't apply twice.
files[m.events] = "Changed=10\n"; check(m:poll(1), "incomplete event cannot block JSON polling"); eq(m.lastChange, 0, "partial event not acknowledged")
files[m.events] = "Changed=10\nEnd=1\n"; check(m:poll(2)); eq(m.lastChange, 10)
local count = #applied; check(m:poll(3)); eq(#applied, count, "duplicate event ignored")
edit({ parry_reach = 9 }); check(m:poll(4)); eq(state.parryReach, 9, "hand-edit fallback")
-- Persist failure must not toggle runtime to a value that was not saved.
local fail = config.new(state, { dir = "test/", json = json, read = read,
    write = function() return nil, "disk full" end, keyValid = function() return true end })
check(fail:load(true)); local before = state.parry
check(not fail:toggle("parry")); eq(state.parry, before)
-- cross-field invariants: a lead at or above the gap cannot hand a hit to the
-- previous dodge, and a 10 ms window protects nothing (audit P2-4)
edit({ dodge_gap_ms = 220, dodge_lead_ms = 300 }); check(not m:load(), "lead at or above the gap is rejected")
edit({ dodge_lead_ms = 120, dodge_iframe_ms = 10 }); check(not m:load(), "a 10 ms i-frame window is rejected")
edit({ dodge_iframe_ms = 240, grab_lead_ms = 50, min_gap_ms = 90 }); check(not m:load(), "grab lead below the tap gap is rejected")
edit({ grab_lead_ms = 350 }); check(m:load(), "the shipped values pass")
eq(state.dodgeLead, .12); eq(state.dodgeIframe, .24)
eq(math.abs(state.grabLeadMs - .35) < 1e-9, true, "grab lead round trip: " .. tostring(state.grabLeadMs))
local unknownWarn = 0
for _, line in ipairs(logs) do
    if line == "menu config: unknown key ignored: extra" then unknownWarn = unknownWarn + 1 end
end
eq(unknownWarn, 1, "an unknown key is named once, not on every poll")

-- The shipped PBZModsMenu descriptor must present the same hot three-state field.
eq(#config.schema, 42, "schema gains exactly one seed fallback field")
local df = assert(io.open("pbz-auto-defense.modsmenu.json", "rb"))
local descriptor = df:read("*a"); df:close()
local seedAt = assert(descriptor:find("\"key\": \"seed_fallback\"", 1, true), "seed descriptor missing")
local nextAt = descriptor:find("\"key\":", seedAt + 30, true) or (#descriptor + 1)
local seedBlock = descriptor:sub(seedAt, nextAt - 1)
check(seedBlock:find("\"type\": \"choice\"", 1, true) ~= nil, "descriptor uses a choice")
check(seedBlock:find("\"default\": \"record\"", 1, true) ~= nil, "descriptor defaults to record")
check(seedBlock:find("\"restart\": false", 1, true) ~= nil, "descriptor hot-applies")
local optionsAt = seedBlock:find("\"options\": [", 1, true)
check(optionsAt ~= nil and seedBlock:find("\"off\"", optionsAt, true) ~= nil
    and seedBlock:find("\"record\"", optionsAt, true) ~= nil
    and seedBlock:find("\"on\"", optionsAt, true) ~= nil, "descriptor exposes off/record/on")
print("PASS " .. n .. " assertions")
