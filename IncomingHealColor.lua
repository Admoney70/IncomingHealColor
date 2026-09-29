-- Incoming Heal Color
-- Recolors Blizzard heal prediction bars: player/target/focus/party/pet frames
-- and compact party/raid frames. /ihc for options.

local ADDON = ...
local DEFAULTS = {
    enabled = true,
    my    = { r = 0.00, g = 1.00, b = 0.45, a = 0.80 }, -- your heals
    other = { r = 1.00, g = 0.80, b = 0.00, a = 0.80 }, -- everyone else's heals
}

local db
local painted = setmetatable({}, { __mode = "k" }) -- texture -> "my"/"other"

local function copyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = type(dst[k]) == "table" and dst[k] or {}
            copyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

-- Applies a color to whatever kind of heal-prediction object this client uses:
--   * plain Texture (older frames)
--   * StatusBarOverlaySegment Frame with .Fill texture + .fillColor (modern frames)
--   * StatusBar
local function applyColor(obj, r, g, b, a)
    if obj.SetVertexColor then
        obj:SetVertexColor(r, g, b, a)
    elseif obj.Fill then
        if obj.SetFillColor then
            obj:SetFillColor(CreateColor(r, g, b, a))
        else
            obj.fillColor = CreateColor(r, g, b, a)
        end
        obj.Fill:SetVertexColor(r, g, b, a)
    elseif obj.SetStatusBarColor then
        obj:SetStatusBarColor(r, g, b, a)
    end
end

local function paint(obj, key)
    if not obj or not db or not db.enabled then return end
    if obj.IsForbidden and obj:IsForbidden() then return end -- nameplates etc.
    local c = db[key]
    applyColor(obj, c.r, c.g, c.b, c.a)
    painted[obj] = key
end

local function onUnitFrame(frame)       -- PlayerFrame, TargetFrame, PartyMemberFrameN, etc.
    if not frame then return end
    paint(frame.myHealPredictionBar, "my")
    paint(frame.otherHealPredictionBar, "other")
end

local function onCompactFrame(frame)    -- CompactPartyFrame / CompactRaidFrame members
    if not frame or (frame.IsForbidden and frame:IsForbidden()) then return end
    -- Nameplates share this code path; leave them alone.
    if frame.unit and frame.unit:find("^nameplate") then return end
    paint(frame.myHealPrediction, "my")
    paint(frame.otherHealPrediction, "other")
end

local function repaintAll()
    if not db.enabled then
        -- Restore white so Blizzard's gradient/defaults show again after next setup.
        for obj in pairs(painted) do applyColor(obj, 1, 1, 1, 1) end
        return
    end
    for obj, key in pairs(painted) do paint(obj, key) end
    local frames = { PlayerFrame, TargetFrame, FocusFrame, PetFrame, TargetFrameToT }
    for i = 1, 4 do frames[#frames + 1] = _G["PartyMemberFrame" .. i] end
    for _, f in pairs(frames) do onUnitFrame(f) end
end

-- Hooks ----------------------------------------------------------------------
local hookedUF, hookedCUF
local function installHooks()
    if not hookedUF and UnitFrameHealPredictionBars_Update then
        hooksecurefunc("UnitFrameHealPredictionBars_Update", onUnitFrame)
        hookedUF = true
    end
    if not hookedCUF and CompactUnitFrame_UpdateHealPrediction then
        hooksecurefunc("CompactUnitFrame_UpdateHealPrediction", onCompactFrame)
        hookedCUF = true
    end
end

-- Color picker (handles both the new and legacy ColorPickerFrame APIs) --------
local function pickColor(key)
    local c = db[key]
    local prev = { r = c.r, g = c.g, b = c.b, a = c.a }

    local function getAlpha()
        if ColorPickerFrame.GetColorAlpha then return ColorPickerFrame:GetColorAlpha() end
        return 1 - (OpacitySliderFrame and OpacitySliderFrame:GetValue() or 0)
    end
    local function apply()
        c.r, c.g, c.b = ColorPickerFrame:GetColorRGB()
        c.a = getAlpha()
        repaintAll()
    end
    local function cancel()
        c.r, c.g, c.b, c.a = prev.r, prev.g, prev.b, prev.a
        repaintAll()
    end

    if ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow({
            r = c.r, g = c.g, b = c.b, opacity = c.a, hasOpacity = true,
            swatchFunc = apply, opacityFunc = apply, cancelFunc = cancel,
        })
    else
        ColorPickerFrame:Hide()
        ColorPickerFrame.hasOpacity = true
        ColorPickerFrame.opacity = 1 - c.a
        ColorPickerFrame.previousValues = prev
        ColorPickerFrame.func, ColorPickerFrame.opacityFunc, ColorPickerFrame.cancelFunc = apply, apply, cancel
        ColorPickerFrame:SetColorRGB(c.r, c.g, c.b)
        ColorPickerFrame:Show()
    end
end

-- Slash commands -------------------------------------------------------------
local function msg(s) print("|cff33ff99IHC|r: " .. s) end
local function fmt(c) return ("r=%.2f g=%.2f b=%.2f a=%.2f"):format(c.r, c.g, c.b, c.a) end

SLASH_INCOMINGHEALCOLOR1 = "/ihc"
SlashCmdList.INCOMINGHEALCOLOR = function(input)
    local cmd = strlower(strtrim(input or ""))
    if cmd == "my" or cmd == "other" then
        pickColor(cmd)
    elseif cmd == "reset" then
        IncomingHealColorDB = copyDefaults(DEFAULTS, {})
        db = IncomingHealColorDB
        repaintAll(); msg("reset to defaults.")
    elseif cmd == "toggle" then
        db.enabled = not db.enabled
        repaintAll(); msg(db.enabled and "enabled." or "disabled (fully reverts after /reload).")
    else
        msg("enabled: " .. tostring(db.enabled))
        msg("my: " .. fmt(db.my) .. "   other: " .. fmt(db.other))
        msg("/ihc my | other | toggle | reset")
    end
end

-- Init -----------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name == ADDON then
            IncomingHealColorDB = copyDefaults(DEFAULTS, IncomingHealColorDB or {})
            db = IncomingHealColorDB
        end
        installHooks() -- catches load-on-demand Blizzard raid frame modules too
    elseif event == "PLAYER_LOGIN" then
        installHooks()
        repaintAll()
        if not (hookedUF or hookedCUF) then
            msg("no heal prediction functions found on this client.")
        end
    end
end)
