-- Offline tests for Scripts/ad_menu_bridge.lua: the pending/saved file mirror that lets the
-- Mods Menu hand this mod its settings without the mod writing anything itself. Every read,
-- write and remove goes through an injected in-memory io (path -> text), so no real file is
-- touched and the mod's own config is never written.
-- Run from the mod directory: luajit tools/test_menu_bridge.lua
local here = (debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\][^/\\]*$")) or "."
local modPath = here .. "/../Scripts/ad_menu_bridge.lua"
local loaded, M = pcall(dofile, modPath)
if not loaded then
    local why = tostring(M)
    if why:find("No such file", 1, true) or why:find("cannot open", 1, true) then
        print("MENU_BRIDGE FAIL module not present yet: " .. modPath)
        return os.exit(1)
    end
    error(why, 0)
end
if type(M) ~= "table" or type(M.encode) ~= "function" or type(M.new) ~= "function" then
    print("MENU_BRIDGE FAIL the module must return { encode, new }: " .. modPath)
    return os.exit(1)
end

local DIR = "D:/fake/Mods/"
local BRIDGE = DIR .. "PBZModsMenuBridge/"
local CONFIG = DIR .. "pbz-auto-defense/pbz-auto-defense.config.json"
local PE = BRIDGE .. "pending-pbz%2dauto%2ddefense.json"
local PL = BRIDGE .. "pending-pbz2dauto2ddefense.json"
local SE = BRIDGE .. "saved-pbz%2dauto%2ddefense.txt"
local SL = BRIDGE .. "saved-pbz2dauto2ddefense.txt"
local BP = BRIDGE .. "pending-BossAI.json" -- name with nothing to encode: exact == loose
local BS = BRIDGE .. "saved-BossAI.txt"

local n = 0
local function check(ok, why)
    if not ok then error(why or "check failed", 2) end
    n = n + 1
end
local function eq(a, b, why)
    if a ~= b then error((why or "values differ") .. ": " .. tostring(a) .. " ~= " .. tostring(b), 2) end
    n = n + 1
end

-- the fake io: files holds the whole "disk", and writes/removes record what the module did
local function ctx(name, modDir)
    local c = { name = name, modDir = modDir or (DIR .. "pbz-auto-defense/"), files = {}, writes = {}, removes = {},
        logs = {}, clock = 100, allowWrite = true, allowRemove = true, store = true,
        writeWhy = "disk full", removeWhy = "sharing violation" }
    c.read = function(path) return c.files[path] end
    c.write = function(path, text)
        if not c.allowWrite then return nil, c.writeWhy end
        c.writes[#c.writes + 1] = path
        if c.store then c.files[path] = text end -- store = false: claims success, lands nothing
        if c.onWrite then c.onWrite(path, text) end -- lets a case race the module mid-mirror
        return true
    end
    c.remove = function(path)
        if not c.allowRemove then return nil, c.removeWhy end
        c.removes[#c.removes + 1] = path
        c.files[path] = nil
        return true
    end
    c.log = function(msg) c.logs[#c.logs + 1] = tostring(msg) end
    c.now = function() return c.clock end
    return c
end
local function bridge(c)
    return M.new({ modDir = c.modDir, name = c.name, read = c.read, write = c.write, remove = c.remove,
        log = c.log, now = c.now })
end
-- the first write or remove the module made outside the paths this poll may create
local function unexpected(c, ...)
    local allowed = {}
    for i = 1, select("#", ...) do allowed[(select(i, ...))] = true end
    for _, list in ipairs({ c.writes, c.removes }) do
        for _, path in ipairs(list) do
            if not allowed[path] then return path end
        end
    end
    return nil
end

local function body()
    -- 1. encode: the menu's encodeName, byte for byte, lowercase hex
    eq(M.encode("pbz-auto-defense"), "pbz%2dauto%2ddefense", "encode matches the menu for this mod")
    eq(M.encode("BossAI"), "BossAI", "letters and digits pass through untouched")
    eq(M.encode("a b"), "a%20b")
    eq(M.encode("100%"), "100%25", "the escape byte itself is escaped")
    eq(M.encode("_X9"), "_X9", "underscore is safe")
    eq(M.encode("\0"), "%00")
    eq(M.encode("\200"), "%c8", "hex is lowercase")
    eq(M.encode("\255"), "%ff")
    local all, unsafe = {}, 0
    for i = 0, 255 do
        all[#all + 1] = string.char(i)
        if not string.char(i):match("^[A-Za-z0-9_]$") then unsafe = unsafe + 1 end
    end
    all = table.concat(all)
    local enc = M.encode(all)
    eq(#enc, 256 + 2 * unsafe, "only bytes outside [A-Za-z0-9_] are escaped")
    local _, escapes = enc:gsub("%%", "")
    eq(escapes, unsafe, "every escaped byte costs exactly one %xx")
    eq((enc:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)), all, "encode round-trips every byte")
    local lower = true
    for hex in enc:gmatch("%%([0-9a-fA-F][0-9a-fA-F])") do
        if hex ~= hex:lower() then lower = false end
    end
    check(lower, "every escape uses lowercase hex")

    -- 2. a complete loose pending is mirrored to the encoded name, then claimed
    local c = ctx()
    c.files[PL] = '{"parry":true}\r\n'
    local o = bridge(c)
    eq(o.stats.pending, 0, "no pending before the first poll")
    eq(o.stats.saved, 0); eq(o.stats.failed, 0)
    eq(o:poll(), true, "the first poll runs")
    eq(c.files[PE], '{"parry":true}\r\n', "the encoded copy is byte-identical")
    eq(c.files[PL], nil, "the loose file is claimed by removing it")
    eq(#c.writes, 1, "only pending-exact is created")
    eq(c.writes[1], PE)
    eq(#c.removes, 1); eq(c.removes[1], PL, "only the loose pending is removed")
    eq(o.stats.pending, 1)
    eq(o.stats.saved, 0); eq(o.stats.failed, 0)
    eq(#c.logs, 1, "a completed mirror is logged once")
    eq(unexpected(c, PE, PL), nil, "only pending-exact is written and only pending-loose removed")

    -- 3. a half-written loose pending waits for the rest of the text
    c = ctx()
    c.files[PL] = '{"parry":true}'
    o = bridge(c)
    eq(o:poll(), true, "an incomplete pending does not stall polling")
    eq(c.files[PE], nil, "no mirror for an incomplete text")
    eq(c.files[PL], '{"parry":true}', "the half-written text is left for the next save")
    eq(#c.writes, 0); eq(#c.removes, 0)
    eq(o.stats.pending, 0, "stats unchanged"); eq(o.stats.saved, 0); eq(o.stats.failed, 0)
    eq(#c.logs, 0)
    c = ctx()
    c.files[PL] = ""
    o = bridge(c)
    o:poll()
    eq(#c.writes, 0, "an empty pending is incomplete")
    eq(#c.removes, 0)

    -- 4. an exact pending already in place wins: no overwrite, no removal
    c = ctx()
    c.files[PL] = '{"v":1}\r\n'
    c.files[PE] = '{"v":0}\r\n'
    o = bridge(c)
    eq(o:poll(), true)
    eq(c.files[PE], '{"v":0}\r\n', "pending-exact is never overwritten")
    eq(c.files[PL], '{"v":1}\r\n', "the loose file is left untouched")
    eq(#c.writes, 0); eq(#c.removes, 0); eq(o.stats.pending, 0)
    c = ctx()
    c.files[PL] = '{"v":1}\r\n'
    c.files[PE] = ""
    o = bridge(c)
    o:poll()
    eq(c.files[PL], '{"v":1}\r\n', "an empty exact file is a claim in place, not a missing file")
    eq(#c.removes, 0)

    -- 5. a mirror that fails keeps the loose text and says why only once
    c = ctx()
    c.files[PL] = '{"x":1}\r\n'
    c.allowWrite = false
    o = bridge(c)
    eq(o:poll(), true)
    eq(c.files[PL], '{"x":1}\r\n', "a failed mirror keeps the pending text")
    eq(c.files[PE], nil)
    eq(o.stats.failed, 1, "a failed mirror is counted")
    eq(o.stats.pending, 0, "a failed mirror is not counted as pending")
    local said = #c.logs
    check(said >= 1, "a failed mirror is reported")
    c.clock = c.clock + 1
    eq(o:poll(), true, "the next poll retries")
    eq(c.files[PL], '{"x":1}\r\n', "the pending text is still there")
    eq(#c.logs, said, "the same reason is not logged twice")
    -- write claims success but the text did not land: the read-back check catches it
    c = ctx()
    c.files[PL] = '{"x":1}\r\n'
    c.store = false
    o = bridge(c)
    eq(o:poll(), true)
    eq(c.files[PL], '{"x":1}\r\n', "a claim that did not land keeps the loose text")
    eq(o.stats.failed, 1)
    -- the loose file cannot be removed: the text stays and the failure is counted
    c = ctx()
    c.files[PL] = '{"x":1}\r\n'
    c.allowRemove = false
    o = bridge(c)
    eq(o:poll(), true)
    eq(c.files[PE], '{"x":1}\r\n', "the encoded copy still lands")
    eq(c.files[PL], '{"x":1}\r\n', "a loose file that cannot be removed is kept")
    eq(o.stats.failed, 1, "a loose file that cannot be removed is a failed step (spec step 2)")

    -- 6. the menu's saved report is mirrored to the loose name, once
    c = ctx()
    c.files[SE] = "Save=3\r\nEnd=1\r\n"
    o = bridge(c)
    eq(o:poll(), true)
    eq(c.files[SL], "Save=3\r\nEnd=1\r\n", "the loose report is byte-identical")
    eq(#c.writes, 1); eq(c.writes[1], SL, "only saved-loose is written")
    eq(o.stats.saved, 1)
    c.clock = c.clock + 1
    eq(o:poll(), true)
    eq(#c.writes, 1, "an equal saved-loose is not rewritten")
    eq(o.stats.saved, 1, "stats.saved stays at one")
    eq(unexpected(c, SL), nil, "nothing but saved-loose is written")

    -- 7. the mirror and the saved report happen in the same poll
    c = ctx()
    c.files[PL] = '{"a":1}\r\n'
    c.files[SE] = "Save=1\r\nEnd=1\r\n"
    o = bridge(c)
    eq(o:poll(), true)
    eq(c.files[PE], '{"a":1}\r\n'); eq(c.files[PL], nil)
    eq(c.files[SL], "Save=1\r\nEnd=1\r\n")
    eq(o.stats.pending, 1); eq(o.stats.saved, 1); eq(o.stats.failed, 0)
    eq(#c.writes, 2)
    eq(unexpected(c, PE, SL, PL), nil, "only those two bridge files are created")

    -- 8. throttle: one round per half second, in either clock
    c = ctx()
    c.files[SE] = "Save=1\r\nEnd=1\r\n"
    o = bridge(c)
    eq(o:poll(), true, "the first poll runs")
    eq(o:poll(), false, "a second poll in the same second is refused")
    eq(#c.writes, 1, "a refused poll touches nothing")
    c.clock = c.clock + 0.4
    eq(o:poll(), false, "0.4 s apart is still too soon")
    eq(#c.writes, 1)
    c.clock = c.clock + 0.6
    eq(o:poll(), true, "past half a second the poll runs again")
    eq(#c.writes, 1, "the second round finds nothing to write")
    c = ctx()
    o = M.new({ modDir = c.modDir, name = c.name, read = c.read, write = c.write, remove = c.remove, log = c.log })
    eq(o:poll(), true, "poll works without opts.now")
    eq(o:poll(), false, "the os.clock default throttles too")

    -- 9. a name with nothing to encode: exact == loose, so nothing is mirrored
    c = ctx("BossAI")
    c.files[BP] = '{"boss":1}\r\n'
    c.files[BS] = "Save=2\r\n"
    o = bridge(c)
    eq(o:poll(), true, "the poll runs")
    eq(#c.writes, 0, "exact == loose: no self-mirror")
    eq(#c.removes, 0, "nothing is removed")
    eq(c.files[BP], '{"boss":1}\r\n', "the pending file is left alone")
    eq(c.files[BS], "Save=2\r\n", "a report whose loose name is itself is not rewritten")
    eq(o.stats.pending, 0); eq(o.stats.saved, 0); eq(o.stats.failed, 0)
    eq(#c.logs, 0, "nothing to report")
    eq(c.files[CONFIG], nil, "the mod's own config is never touched")

    -- 10. main.lua's MOD_DIR shape "<mod>\Scripts\..\" folds to the mod folder, and the
    -- separator style of the input path is kept in every path the shim touches
    local bslash = "D:\\x\\Mods\\pbz-auto-defense\\Scripts\\..\\"
    local bdir = "D:\\x\\Mods\\PBZModsMenuBridge\\"
    c = ctx(nil, bslash)
    c.files[bdir .. "pending-pbz2dauto2ddefense.json"] = '{"z":1}\r\n'
    o = bridge(c)
    eq(o:poll(), true, "a folded modDir polls")
    eq(c.files[bdir .. "pending-pbz%2dauto%2ddefense.json"], '{"z":1}\r\n',
        "Scripts\\..\\ folds away: the derived name is pbz-auto-defense")
    eq(#c.writes, 1); eq(c.writes[1], bdir .. "pending-pbz%2dauto%2ddefense.json", "backslash paths stay backslash")
    eq(#c.removes, 1); eq(c.removes[1], bdir .. "pending-pbz2dauto2ddefense.json")
    c = ctx(nil, "D:/x/Mods/pbz-auto-defense/Scripts/../")
    c.files["D:/x/Mods/PBZModsMenuBridge/saved-pbz%2dauto%2ddefense.txt"] = "Save=4\r\nEnd=1\r\n"
    o = bridge(c)
    eq(o:poll(), true, "the forward-slash fold polls")
    eq(#c.writes, 1); eq(c.writes[1], "D:/x/Mods/PBZModsMenuBridge/saved-pbz2dauto2ddefense.txt",
        "forward-slash paths stay forward slash")

    -- 11. the menu saves again while the mirror is being queued: the newer text wins, so
    -- the loose file is left for the next poll and no failure is counted
    c = ctx()
    c.files[PL] = 'Save=11\r\n{"x":1}\r\n'
    local newer = 'Save=12\r\n{}\r\n'
    c.onWrite = function(path)
        if path == PE then c.files[PL] = newer end -- the menu saves during our write
    end
    o = bridge(c)
    eq(o:poll(), true, "the poll runs")
    eq(c.files[PE], 'Save=11\r\n{"x":1}\r\n', "the text read at the start is the one queued")
    eq(c.files[PL], newer, "a save that arrived meanwhile is not claimed")
    eq(#c.removes, 0, "the newer loose file is not removed")
    eq(o.stats.failed, 0, "a replaced loose file is not a failure")
    eq(o.stats.pending, 1, "the queued copy still counts as pending")
    local newerSaid = false
    for _, line in ipairs(c.logs) do
        if line:lower():find("newer save", 1, true) then newerSaid = true end
    end
    check(newerSaid, "the newer save is named in the log")
end

local ok, why = pcall(body)
if ok then
    print("MENU_BRIDGE PASS " .. n)
else
    print("MENU_BRIDGE FAIL " .. tostring(why))
    os.exit(1)
end
