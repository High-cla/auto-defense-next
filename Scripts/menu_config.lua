-- Native UE4SS Mods Menu adapter. JSON is the single source after first migration.
local M = {}
M.schema = {
    { key = "perfect", field = "perfect", kind = "toggle", default = false, limits = nil, restart = false, scale = 1 },
    { key = "perfect_mode", field = "perfectMode", kind = "choice", default = "give", limits = {"always", "give", "window"}, restart = true, scale = 1 },
    { key = "black_flash", field = "blackFlash", kind = "choice", default = "dodge", limits = {"dodge", "parry"}, restart = true, scale = 1 },
    { key = "hook_counter", field = "hookCounter", kind = "choice", default = "off", limits = {"off", "on"}, restart = false, scale = 1 },
    { key = "shield_counter", field = "shieldCounter", kind = "choice", default = "off", limits = {"off", "on"}, restart = false, scale = 1 },
    { key = "shield_counter_range", field = "shieldCounterRange", kind = "number", default = 1500, limits = {0, 3000, 50}, restart = false, scale = 1 },
    { key = "dodge", field = "dodge", kind = "choice", default = "red", limits = {"off", "red", "all"}, restart = true, scale = 1 },
    { key = "parry", field = "parry", kind = "toggle", default = true, limits = nil, restart = false, scale = 1 },
    { key = "parry_method", field = "parryMethod", kind = "choice", default = "key", limits = {"key", "ability"}, restart = true, scale = 1 },
    { key = "parry_reach", field = "parryReach", kind = "number", default = 0.5, limits = {0, 100, 0.5}, restart = false, scale = 1 },
    { key = "guard_release", field = "guardRelease", kind = "toggle", default = true, limits = nil, restart = false, scale = 1 },
    { key = "guard_release_after", field = "guardReleaseAfter", kind = "number", default = 0.5, limits = {0, 120, 0.5}, restart = false, scale = 1 },
    { key = "guard_release_combat_end", field = "guardReleaseCombatEnd", kind = "number", default = 0.5, limits = {0, 120, 0.5}, restart = false, scale = 1 },
    { key = "lang", field = "lang", kind = "choice", default = "en", limits = {"en", "vi"}, restart = false, scale = 1 },
    { key = "hotkey_message", field = "hotkeyMessage", kind = "toggle", default = true, limits = nil, restart = false, scale = 1 },
    { key = "learn", field = "learn", kind = "toggle", default = true, limits = nil, restart = false, scale = 1 },
    { key = "debug", field = "debug", kind = "toggle", default = false, limits = nil, restart = false, scale = 1 },
    { key = "perf", field = "perf", kind = "toggle", default = false, limits = nil, restart = false, scale = 1 },
    { key = "events", field = "events", kind = "toggle", default = true, limits = nil, restart = false, scale = 1 },
    { key = "read_frames", field = "readFrames", kind = "toggle", default = true, limits = nil, restart = false, scale = 1 },
    { key = "frame_source", field = "frameSource", kind = "choice", default = "hooks", limits = {"hooks", "game"}, restart = false, scale = 1 },
    { key = "parry_lead", field = "parryLeadCfg", kind = "choice", default = "auto", limits = {"auto", "manual"}, restart = false, scale = 1 },
    { key = "parry_lead_seconds", field = "parryLeadCfg", kind = "number", default = 0.08, limits = {0, 1, 0.01}, restart = false, scale = 1 },
    { key = "dodge_lead_ms", field = "dodgeLead", kind = "number", default = 80, limits = {0, 1000, 10}, restart = false, scale = 0.001 },
    { key = "dodge_gap_ms", field = "dodgeGap", kind = "number", default = 120, limits = {0, 2000, 10}, restart = false, scale = 0.001 },
    { key = "dodge_iframe_ms", field = "dodgeIframe", kind = "number", default = 260, limits = {0, 2000, 10}, restart = false, scale = 0.001 },
    { key = "pair_frames", field = "pairFrames", kind = "toggle", default = true, limits = nil, restart = false, scale = 1 },
    { key = "receipt", field = "receipt", kind = "toggle", default = false, limits = nil, restart = false, scale = 1 },
    { key = "receipt_retry", field = "receiptRetry", kind = "toggle", default = false, limits = nil, restart = false, scale = 1 },
    { key = "latency", field = "latency", kind = "toggle", default = true, limits = nil, restart = false, scale = 1 },
    { key = "ledger", field = "ledger", kind = "toggle", default = true, limits = nil, restart = false, scale = 1 },
    { key = "min_gap_ms", field = "minGap", kind = "number", default = 120, limits = {0, 1000, 10}, restart = false, scale = 0.001 },
    { key = "grab_lead_ms", field = "grabLeadMs", kind = "number", default = 240, limits = {0, 2000, 10}, restart = false, scale = 0.001 },
    { key = "dodge_cd", field = "dodgeCd", kind = "toggle", default = false, limits = nil, restart = false, scale = 1 },
    { key = "busy_skip", field = "busySkip", kind = "toggle", default = false, limits = nil, restart = false, scale = 1 },
    { key = "flurry_guard", field = "flurryGuard", kind = "toggle", default = true, limits = nil, restart = true, scale = 1 },
    { key = "pbzpd", field = "pbzpd", kind = "choice", default = "auto", limits = {"auto", "yield", "off"}, restart = true, scale = 1 },
    { key = "data", field = "data", kind = "toggle", default = true, limits = nil, restart = true, scale = 1 },
    { key = "seed_fallback", field = "seedFallback", kind = "choice", default = "record", limits = {"off", "record", "on"}, restart = false, scale = 1 },
    { key = "data_tags", field = "dataTags", kind = "toggle", default = false, limits = nil, restart = true, scale = 1 },
    { key = "dodge_attacks", field = "dodgeAttacks", kind = "readonly", default = "", limits = nil, restart = true, scale = 1 },
    { key = "data_off", field = "dataOff", kind = "readonly", default = "", limits = nil, restart = true, scale = 1 },
    { key = "key_perfect", field = "keys.perfect", kind = "choice", default = "F7", limits = {"none", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "CTRL+F6", "CTRL+F7", "CTRL+F8", "CTRL+F9", "CTRL+F10", "CTRL+F11", "CTRL+F12"}, restart = true, scale = 1 },
    { key = "key_dodge", field = "keys.dodge", kind = "choice", default = "F8", limits = {"none", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "CTRL+F6", "CTRL+F7", "CTRL+F8", "CTRL+F9", "CTRL+F10", "CTRL+F11", "CTRL+F12"}, restart = true, scale = 1 },
    { key = "key_parry", field = "keys.parry", kind = "choice", default = "F9", limits = {"none", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "CTRL+F6", "CTRL+F7", "CTRL+F8", "CTRL+F9", "CTRL+F10", "CTRL+F11", "CTRL+F12"}, restart = true, scale = 1 },
    { key = "key_snapshot", field = "keys.snapshot", kind = "choice", default = "F6", limits = {"none", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "CTRL+F6", "CTRL+F7", "CTRL+F8", "CTRL+F9", "CTRL+F10", "CTRL+F11", "CTRL+F12"}, restart = true, scale = 1 },
}

-- keys an older config may still carry: read as "do nothing", never reported as unknown
M.retired = { hook_counter_shachi = true }

local function readFile(path)
    local f, _, code = io.open(path, "rb")
    if not f then return nil, code end
    local text = f:read(65537)
    f:close()
    return text or ""
end
-- Windows CRT rename cannot replace an existing file. Stage first, then a short
-- rollback-capable swap on the game thread. This is NOT a cross-process lock.
local function writeFile(path, text, expected)
    local tmp, backup = path .. ".ad-tmp", path .. ".ad-backup"
    local f, why = io.open(tmp, "wb")
    if not f then return nil, why end
    local ok, err = f:write(text)
    local closed, closeErr = f:close()
    if not ok or not closed then os.remove(tmp) return nil, err or closeErr end
    local current, code = readFile(path)
    if current ~= expected or (current == nil and code ~= 2) then
        os.remove(tmp) return nil, "config changed while saving or could not be read"
    end
    if expected ~= nil then
        os.remove(backup) -- only this adapter's previous-config backup
        local moved, moveErr = os.rename(path, backup)
        if not moved then os.remove(tmp) return nil, moveErr end
    end
    local moved, moveErr = os.rename(tmp, path)
    if not moved then
        if expected ~= nil then
            local restored, restoreErr = os.rename(backup, path)
            if not restored then return nil, "save and rollback failed: " .. tostring(restoreErr) end
        end
        os.remove(tmp)
        return nil, moveErr
    end
    -- read back: the compare above is not a lock, a writer in between would be lost
    -- silently; restore the previous file when the swap did not survive (audit P2-5)
    local after = readFile(path)
    if after ~= text then
        if expected ~= nil then os.rename(backup, path) end
        return nil, "config changed while saving (read-back mismatch)"
    end
    return true
end
local function get(settings, row)
    if row.field:sub(1, 5) == "keys." then return settings.keys[row.field:sub(6)] end
    if row.key == "parry_lead" then return type(settings.parryLeadCfg) == "number" and "manual" or "auto" end
    if row.key == "parry_lead_seconds" then return type(settings.parryLeadCfg) == "number" and settings.parryLeadCfg or row.default end
    if row.key == "data_off" then
        local keys = {}
        for k, v in pairs(settings.dataOff or {}) do if v then keys[#keys + 1] = k end end
        table.sort(keys)
        return table.concat(keys, ",")
    end
    local v = settings[row.field]
    if v == nil then return row.default end
    return row.kind == "number" and (row.scale == .001 and v * 1000 or v / row.scale) or v
end
local function put(settings, row, raw)
    local value = raw[row.key]
    if row.field:sub(1, 5) == "keys." then settings.keys[row.field:sub(6)] = value
    elseif row.key == "parry_lead" or row.key == "parry_lead_seconds" then
        settings.parryLeadCfg = raw.parry_lead == "manual" and raw.parry_lead_seconds or "auto"
    elseif row.key == "data_off" then
        settings.dataOff = {}
        for k in value:gmatch("[^,%s]+") do settings.dataOff[k] = true end
    else settings[row.field] = row.kind == "number" and value * row.scale or value end
end
function M.new(settings, opts)
    local self = { path = opts.dir .. "pbz-auto-defense.config.json",
        events = opts.dir .. "../PBZModsMenuBridge/events-pbz%2dauto%2ddefense.txt",
        -- the menu folds '%' out of file names on this build (1.6.4), so the bridge
        -- shim hands us the second spelling to watch as well
        eventsAlt = opts.eventsAlt,
        pending = {}, lastChange = 0, nextAt = 0, unknown = {} }
    local json, read, write = opts.json, opts.read or readFile, opts.write or writeFile
    local function report(why)
        if why ~= self.error then self.error = why; if opts.log then opts.log("menu config: " .. why) end end
        return nil, why
    end
    local function validate(raw)
        for _, row in ipairs(M.schema) do
            local v = raw[row.key]
            if v == nil then v = row.default end
            if row.kind == "toggle" then
                if type(v) ~= "boolean" then return nil, row.key .. " must be boolean" end
            elseif row.kind == "number" then
                if type(v) ~= "number" or v ~= v or v < row.limits[1] or v > row.limits[2] then return nil, row.key .. " out of range" end
            elseif row.field:sub(1, 5) == "keys." then
                if type(v) ~= "string" or (opts.keyValid and not opts.keyValid(v)) then return nil, row.key .. " invalid key" end
                v = v:lower() == "none" and "none" or v:upper():gsub("%s", "")
            elseif row.kind == "choice" then
                local found = false
                for _, option in ipairs(row.limits) do if v == option then found = true break end end
                if not found then return nil, row.key .. " invalid option" end
            elseif type(v) ~= "string" or #v > 4096 or v:find("[\r\n]") then return nil, row.key .. " invalid text" end
            raw[row.key] = v
        end
        -- cross-field invariants: a lead at or above the gap can never hand a hit to
        -- the previous dodge, and a zero i-frame window is no window (audit P2-4)
        local dl, dg, di = raw.dodge_lead_ms, raw.dodge_gap_ms, raw.dodge_iframe_ms
        if type(dl) == "number" and type(dg) == "number" and dl >= dg then
            return nil, "dodge_lead_ms must stay below dodge_gap_ms"
        end
        if type(di) == "number" and di < 40 then return nil, "dodge_iframe_ms must be at least 40" end
        if type(raw.grab_lead_ms) == "number" and type(raw.min_gap_ms) == "number"
            and raw.grab_lead_ms < raw.min_gap_ms then
            return nil, "grab_lead_ms must be at least min_gap_ms"
        end
        -- an unknown (misspelled) key used to pass silently and do nothing: name it once
        local known = {}
        for _, row in ipairs(M.schema) do known[row.key] = true end
        for k in pairs(raw) do
            if not known[k] and not M.retired[k] and not self.unknown[k] then
                self.unknown[k] = true
                if opts.log then opts.log("menu config: unknown key ignored: " .. tostring(k)) end
            end
        end
        return raw
    end
    local function fetch(initial, unchangedOK)
        local text, code = read(self.path)
        if text == nil then
            if not initial or code ~= 2 then return report("config unreadable; last good settings kept") end
            local raw = {}
            for _, row in ipairs(M.schema) do raw[row.key] = get(settings, row) end
            local valid, why = validate(raw)
            if not valid then return report("legacy migration: " .. why) end
            text, why = json.encode(raw)
            if not text then return report(why) end
            local ok, err = write(self.path, text, nil)
            if not ok then return report("migration save failed: " .. tostring(err)) end
        end
        if unchangedOK and text == self.lastText then return self.raw, text end
        local raw, why = json.decode(text)
        if not raw then return report("invalid JSON: " .. tostring(why)) end
        local valid, err = validate(raw)
        if not valid then return report(err) end
        return raw, text
    end
    local function apply(raw, text, initial)
        local changed, pending = {}, {}
        for _, row in ipairs(M.schema) do
            local different = get(settings, row) ~= raw[row.key]
            if row.restart and not initial then
                if different then pending[row.key] = true end
            elseif different then changed[row.key] = true end
        end
        -- Both lead rows have one runtime target; apply even if only the inactive numeric row changed.
        for _, row in ipairs(M.schema) do if initial or not row.restart then put(settings, row, raw) end end
        self.raw, self.lastText, self.pending, self.error = raw, text, pending, nil
        if self.onApply and next(changed) then self.onApply(changed) end
        local names = {}
        for k in pairs(pending) do names[#names + 1] = k end
        table.sort(names)
        local pendingText = table.concat(names, ", ")
        if pendingText ~= self.pendingText then
            self.pendingText = pendingText
            if opts.log and pendingText ~= "" then opts.log("menu config: restart required for " .. pendingText) end
        end
        return true
    end
    function self:load(initial)
        local raw, text = fetch(initial or self.lastText == nil, true)
        if not raw then return nil, text end
        if not initial and text == self.lastText then self.error = nil return true end
        return apply(raw, text, initial)
    end
    function self:toggle(key)
        if key ~= "perfect" and key ~= "parry" and key ~= "dodge" then return report("unsupported hotkey setting") end
        -- Read immediately before the write, so other menu changes (including restart-only values) survive.
        local raw, text = fetch(false)
        if not raw then return nil, text end
        if key == "dodge" then raw.dodge = raw.dodge == "off" and "red" or (raw.dodge == "red" and "all" or "off")
        else raw[key] = not raw[key] end
        local out, why = json.encode(raw)
        if not out then return report(why) end
        local ok, err = write(self.path, out, text)
        if not ok then return report("save failed: " .. tostring(err)) end
        -- A hotkey's deliberate mode change is immediate; restart-only menu changes stay pending.
        if key == "dodge" then settings.dodge = raw.dodge end
        return apply(raw, out, false)
    end
    function self:poll(now)
        if now < self.nextAt then return true end
        -- 1 s stays: a 2 s interval breaks the "a menu change is applied within a
        -- second" contract (and the suite encodes a poll(1) then poll(2) sequence).
        -- Two ~900-byte reads per second are not a budget item (audit P2-11).
        self.nextAt = now + 1
        local event = read(self.events)
        if not event and self.eventsAlt then event = read(self.eventsAlt) end
        -- A partial event is ignored, but cannot permanently block validated JSON hand edits.
        local complete = event and ("\n" .. event):match("\nEnd=1\r?\n?$")
        local seq = complete and tonumber(("\n" .. event):match("\nChanged=(%d+)"))
        local ok = self:load(false) -- cheap text comparison also covers manual edits / missing bridge
        if ok and seq and seq > self.lastChange then self.lastChange = seq end
        return ok
    end
    return self
end
return M
