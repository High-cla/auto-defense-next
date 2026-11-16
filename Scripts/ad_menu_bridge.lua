-- Name compatibility shim for the Mods Menu bridge folder (1.6.4).
--
-- The menu (PBZModsMenu main.js:1553) names a UE4SS mod's save file by turning
-- every byte outside [A-Za-z0-9_] into %xx, so "pbz-auto-defense" becomes
-- "pbz%2dauto%2ddefense", and the bridge (PBZModsMenuBridge 0.3.1,
-- Scripts/main.lua:81-89) watches exactly that name. On this game build the menu
-- writes the file as "pending-pbz2dauto2ddefense.json" instead: the '%' bytes are
-- gone (observed 2026-11-16, three saves, menu log "settings not saved"). The
-- bridge therefore never matches it, never replaces <ModName>.config.json and
-- never confirms saved-<enc>.txt.
--
-- This shim only folds the spelling. It hands a complete pending text to the
-- bridge under the name the bridge watches, and copies the bridge's confirmation
-- to the spelling the menu is likely to read back. It never writes the mod's own
-- config (the bridge owns that swap) and never edits the menu or the bridge.
local M = {}
M.VERSION = 1
local INTERVAL = 0.5 -- s: the bridge itself checks its folder four times a second

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read(65537)
    f:close()
    return text or ""
end

local function writeFile(path, text)
    local f, why = io.open(path, "wb")
    if not f then return nil, why end
    local ok, err = f:write(text)
    local closed, closeErr = f:close()
    if not ok or not closed then return nil, err or closeErr end
    return true
end

-- the menu's and the bridge's encoding: letters, digits and _ stay, every other
-- byte becomes '%' plus two lowercase hex digits
function M.encode(name)
    return (name:gsub("[^A-Za-z0-9_]", function(c) return string.format("%%%02x", c:byte()) end))
end

-- "D:/Mods/x/" -> "/", "D:\\Mods\\x\\" -> "\\", no trailing separator -> "\\" when the
-- path uses them, else "/"
local function lastSep(path)
    local slash = path:sub(-1)
    if slash == "/" or slash == "\\" then return slash end
    if path:find("\\", 1, true) then return "\\" end
    return "/"
end

-- Resolve "." and ".." textually. MOD_DIR is "<mod>\\Scripts\\..\\", so without this fold
-- the folder name would read as ".." and the encoded name as "%2e%2e".
local function fold(path, sep)
    local drive, rest = path:match("^(%a:)(.*)$")
    if not drive then drive, rest = "", path end
    local parts = {}
    for seg in rest:gmatch("[^\\/]+") do
        if seg == ".." then
            parts[#parts] = nil
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    local body = table.concat(parts, sep)
    if drive == "" then return body end
    return drive .. sep .. body
end

function M.new(opts)
    local raw = opts.modDir
    if not raw or raw == "" then error("ad_menu_bridge: modDir is required") end
    local sep = lastSep(raw)
    local full = fold(raw, sep)
    local name = opts.name or full:match("([^\\/]+)$") or full
    local parent = full:match("^(.*)[\\/][^\\/]+$") or "."
    local bridge = parent .. sep .. "PBZModsMenuBridge" .. sep
    local exact = M.encode(name)
    local loose = exact:gsub("%%", "")
    local o = {
        name = name, exact = exact, loose = loose, interval = INTERVAL,
        pendingExact = bridge .. "pending-" .. exact .. ".json",
        pendingLoose = bridge .. "pending-" .. loose .. ".json",
        savedExact = bridge .. "saved-" .. exact .. ".txt",
        savedLoose = bridge .. "saved-" .. loose .. ".txt",
        eventsAlt = bridge .. "events-" .. loose .. ".txt",
        stats = { pending = 0, saved = 0, failed = 0 },
        readFn = opts.read or readFile,
        writeFn = opts.write or writeFile,
        removeFn = opts.remove or os.remove,
        nowFn = opts.now or os.clock,
        log = opts.log,
        mirror = exact ~= loose, -- no '%' in the name: the two spellings are one file
        nextAt = 0,
    }
    local function say(msg)
        if o.log then o.log("menu bridge shim: " .. msg) end
    end
    local function fail(why)
        o.stats.failed = o.stats.failed + 1
        if o.lastError ~= why then
            o.lastError = why
            say("failed: " .. why)
        end
    end
    -- the menu ends every text with one CRLF: without it the text is still being
    -- written, or was cut short, and the bridge would refuse it too
    local function complete(text)
        return type(text) == "string" and text:sub(-2) == "\r\n"
    end
    local function queuePending()
        local text = o.readFn(o.pendingLoose)
        if not complete(text) then return end
        -- the bridge handles a correctly spelled file itself; never overwrite one
        if o.readFn(o.pendingExact) ~= nil then return end
        local ok, why = o.writeFn(o.pendingExact, text)
        if not ok then return fail("could not queue pending-" .. exact .. ".json: " .. tostring(why)) end
        if o.readFn(o.pendingExact) ~= text then return fail("queued pending file did not read back") end
        o.stats.pending = o.stats.pending + 1
        o.lastError = nil
        say("queued pending-" .. exact .. ".json for the bridge (" .. #text .. " bytes)")
        -- the menu may have saved again while we were queuing: that newer text is the
        -- one still waiting, so it must not be deleted with the copy we just made
        if o.readFn(o.pendingLoose) ~= text then
            say("a newer save arrived while queuing; pending-" .. loose .. ".json kept for the next pass")
            return
        end
        -- the bridge claims its copy, so a leftover loose file is harmless (the next
        -- poll skips on the existing exact file) - but a silent failure here would let
        -- the log claim a clean step, so it is counted and reported
        local removed, why2 = o.removeFn(o.pendingLoose)
        if not removed then
            fail("queued, but could not remove pending-" .. loose .. ".json: " .. tostring(why2))
        end
    end
    local function mirrorSaved()
        local text = o.readFn(o.savedExact)
        if not text or text == "" then return end
        if o.readFn(o.savedLoose) == text then return end
        local ok, why = o.writeFn(o.savedLoose, text)
        if not ok then return fail("could not copy saved-" .. exact .. ".txt: " .. tostring(why)) end
        o.stats.saved = o.stats.saved + 1
        o.lastError = nil
        say("copied the bridge's confirmation to saved-" .. loose .. ".txt")
    end
    function o:poll()
        local now = o.nowFn()
        if now < o.nextAt then return false end
        o.nextAt = now + INTERVAL
        if o.mirror then
            queuePending()
            mirrorSaved()
        end
        return true
    end
    return o
end
return M
