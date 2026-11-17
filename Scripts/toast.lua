-- A line of text shown on screen for a few seconds (no input, drawn above the HUD).
-- Built from plain UMG objects: UserWidget -> CanvasPanel -> TextBlock, added to
-- the viewport. Rebuilt when a level load clears the viewport. Any failure only
-- disables the toast; the caller's own logging is unaffected.
--   local t = Toast.new(60, 220)   -- screen position (x, y)
--   t:show("text", 2.5)            -- game thread only
--
-- One scheduled hide per show, never a standing poll: the native debounce
-- (RetriggerableExecuteInGameThreadWithDelay on a saved handle) is preferred, a
-- one-shot ExecuteInGameThreadWithDelay is the fallback, and a build with
-- neither gets a 100 ms loop that saves its handle and cancels it when due
-- (docs/UE4SS-LUA-API-REFERENCE.md §4.2/§4.4; the "no handle, no cancel"
-- anti-pattern in §9 forbids the old always-running loop). A build with none of
-- those APIs still shows the text, but only the next show can hide it.
local Toast = {}
Toast.__index = Toast

local VIS_COLLAPSED, VIS_HIT_TEST_INVISIBLE = 1, 3
local LOOP_STEP_MS = 100
local DEFAULT_SECONDS = 2.5
local serial = 0

local function valid(v) return v ~= nil and v:IsValid() end

local function class(path)
    local c = StaticFindObject(path)
    if not valid(c) then error("not found: " .. path) end
    return c
end

local function unique(base)
    serial = serial + 1
    return FName(string.format("%s_%d_%d", base, os.time(), serial))
end

-- shared readers: pcall(fn, arg) instead of one closure per check
local function inviewport(w) return w:IsInViewport() end
local function setvis(w, v) w:SetVisibility(v) end

-- Delayed Actions are optional globals and a build may lack any of them, so a
-- name that is not declared reads as nil instead of raising. The lookup goes
-- through _G (not rawget) so an engine that installs these functions behind an
-- __index table is found too.
local G = _G
local function api(name)
    local f = G[name]
    if type(f) == "function" then return f end
    return nil
end

local function milliseconds(seconds)
    local s = tonumber(seconds) or DEFAULT_SECONDS
    if s < 0 then s = 0 end
    return math.floor(s * 1000 + 0.5)
end

function Toast.new(x, y)
    -- nothing is scheduled here on purpose: a toast that is never shown owns no
    -- timer, so a level load or a reload cannot leak an action
    return setmetatable({ x = x, y = y, gen = 0, handle = nil, kind = nil,
        widget = nil, text = nil, broken = false, schedule = nil }, Toast)
end

-- hands the current action back to the engine; the generation check below still
-- refuses its callback if the engine had already queued it
function Toast:cancel()
    local h = self.handle
    self.handle, self.kind = nil, nil
    if h == nil then return true end
    local cancel = api("CancelDelayedAction")
    if cancel == nil then return false end
    local ok = pcall(cancel, h)
    return ok
end

function Toast:hide()
    self:cancel()
    local w = self.widget
    if valid(w) then pcall(setvis, w, VIS_COLLAPSED) end
    return true
end

function Toast:build()
    local gi = FindFirstOf("GameInstance")
    if not valid(gi) then error("no GameInstance") end
    local w = StaticConstructObject(class("/Script/UMG.UserWidget"), gi, unique("PBZModToast"))
    w.WidgetTree = StaticConstructObject(class("/Script/UMG.WidgetTree"), w, unique("Tree"))
    local canvas = StaticConstructObject(class("/Script/UMG.CanvasPanel"), w.WidgetTree, unique("Canvas"))
    w.WidgetTree.RootWidget = canvas
    local text = StaticConstructObject(class("/Script/UMG.TextBlock"), w.WidgetTree, unique("Text"))
    local slot = canvas:AddChildToCanvas(text)
    pcall(function() slot:SetAutoSize(true) end)
    pcall(function() slot:SetPosition({ X = self.x, Y = self.y }) end)
    pcall(function() text:SetColorAndOpacity({ SpecifiedColor = { R = 1, G = 0.86, B = 0.55, A = 1 }, ColorUseRule = 0 }) end)
    pcall(function() text:SetShadowOffset({ X = 2, Y = 2 }) end)
    pcall(function() text:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.9 }) end)
    pcall(function() text.Font.Size = 22 end)
    w:SetVisibility(VIS_COLLAPSED)
    w:AddToViewport(10000)
    self.widget, self.text = w, text
end

-- the text and the visibility change together: a half-presented toast would
-- either show stale text or hide a valid one
local function present(self, msg)
    local alive = valid(self.widget) and valid(self.text)
    if alive then
        local okV, inVp = pcall(inviewport, self.widget)
        alive = okV and inVp
    end
    if not alive then self:build() end
    self.text:SetText(FText(msg))
    self.widget:SetVisibility(VIS_HIT_TEST_INVISIBLE)
end

-- one closure per show (the engine calls the callback with no arguments). It
-- hides once, and a newer show (or an earlier hide) makes it a no-op through the
-- generation counter. "steps" is how many 100 ms loop ticks the legacy path owes;
-- nil means the first call is the deadline.
local function hideLater(self, gen, steps)
    local left = steps
    return function()
        if gen ~= self.gen or self.kind == nil then return false end
        if left ~= nil then
            left = left - 1
            if left > 0 then return false end
        end
        self:hide()
        return false
    end
end

-- arms exactly one hide for this show and returns the scheduler that took it:
-- "retriggerable" | "once" | "loop" | "none"
function Toast:arm(ms, cb, loopCb)
    local retrig = api("RetriggerableExecuteInGameThreadWithDelay")
    local once = api("ExecuteInGameThreadWithDelay")
    local loop = api("LoopInGameThreadWithDelay")

    -- 1. native debounce: the saved handle is re-triggered, so two shows in a row
    --    restart one timer instead of queueing two actions
    if retrig ~= nil and self.kind == "retriggerable" and self.handle ~= nil then
        local ok = pcall(retrig, self.handle, ms, cb)
        if ok then return "retriggerable" end
        self:cancel()
    end
    if retrig ~= nil then
        self:cancel()
        local h
        local mk = api("MakeActionHandle")
        if mk ~= nil then
            local okh, made = pcall(mk)
            if okh then h = made end
        end
        if h ~= nil then
            local ok = pcall(retrig, h, ms, cb)
            if ok then
                self.handle, self.kind = h, "retriggerable"
                return "retriggerable"
            end
        end
    end

    -- 2. one-shot delay; the handle is kept so the next show can cancel it (a nil
    --    handle still means "scheduled": the generation check covers that case)
    self:cancel()
    if once ~= nil then
        local okOnce, h = pcall(once, ms, cb)
        if okOnce then
            self.handle, self.kind = h, "once"
            return "once"
        end
    end

    -- 3. legacy builds: one 100 ms loop whose handle is cancelled by the callback
    --    at the deadline and by the next show
    self:cancel()
    if loop ~= nil then
        local okLoop, h = pcall(loop, LOOP_STEP_MS, loopCb)
        if okLoop then
            self.handle, self.kind = h, "loop"
            return "loop"
        end
    end
    return "none"
end

-- returns true when shown; the first failure is returned as (false, err) and the
-- toast stays off afterwards
function Toast:show(msg, seconds)
    if self.broken then return false, "toast is disabled" end
    local ok, err = pcall(present, self, msg)
    if not ok then
        self.broken = true
        self:cancel()
        return false, err
    end
    local ms = milliseconds(seconds)
    self.gen = self.gen + 1
    -- the one-shot paths fire on their first call; the legacy loop needs its
    -- 100 ms steps counted, so it gets its own callback
    local cb = hideLater(self, self.gen, nil)
    local loopCb = hideLater(self, self.gen, math.ceil(ms / LOOP_STEP_MS))
    self.schedule = self:arm(ms, cb, loopCb)
    return true
end

return Toast
