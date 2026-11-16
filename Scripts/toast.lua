-- A line of text shown on screen for a few seconds (no input, drawn above the HUD).
-- Built from plain UMG objects: UserWidget -> CanvasPanel -> TextBlock, added to
-- the viewport. Rebuilt when a level load clears the viewport. Any failure only
-- disables the toast; the caller's own logging is unaffected.
--   local t = Toast.new(60, 220)   -- screen position (x, y)
--   t:show("text", 2.5)            -- game thread only
local Toast = {}
Toast.__index = Toast

local VIS_COLLAPSED, VIS_HIT_TEST_INVISIBLE = 1, 3
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

function Toast.new(x, y)
    local self = setmetatable({ x = x, y = y, hideAt = nil, broken = false }, Toast)
    LoopInGameThreadWithDelay(100, function()
        if self.hideAt and os.clock() >= self.hideAt then
            self.hideAt = nil
            pcall(function() if valid(self.widget) then self.widget:SetVisibility(VIS_COLLAPSED) end end)
        end
        return false
    end)
    return self
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

-- returns true when shown; the first failure is returned as (false, err) and the
-- toast stays off afterwards
function Toast:show(msg, seconds)
    if self.broken then return false end
    local ok, err = pcall(function()
        local alive = valid(self.widget) and valid(self.text)
        if alive then
            local okV, inVp = pcall(function() return self.widget:IsInViewport() end)
            alive = okV and inVp
        end
        if not alive then self:build() end
        self.text:SetText(FText(msg))
        self.widget:SetVisibility(VIS_HIT_TEST_INVISIBLE)
        self.hideAt = os.clock() + (seconds or 2.5)
    end)
    if not ok then
        self.broken = true
        return false, err
    end
    return true
end

return Toast
