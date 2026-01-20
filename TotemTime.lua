-- TotemTime - simple totem timers for WoW 1.12.x (Vanilla/Turtle)
-- Robust totem detection + saved settings + QoL clears and movement.
-- /ttlock toggles locked; /ttdebug toggles debug; /totemtime reset recenters.

-- SavedVariables: TotemTimeDB (declared in .toc)
TotemTimeDB = TotemTimeDB or {}

local TotemTime = CreateFrame("Frame", "TotemTimeFrame", UIParent)
TotemTime:SetWidth(240)
TotemTime:SetHeight(92)
TotemTime:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
TotemTime:SetMovable(true)
TotemTime:EnableMouse(true)
TotemTime:RegisterForDrag("LeftButton")

-- 1.12 handlers (use global 'this')
TotemTime:SetScript("OnDragStart", function()
    if this:IsMovable() then this:StartMoving() end
end)
TotemTime:SetScript("OnDragStop", function()
    this:StopMovingOrSizing()
    -- Save position
    local p, _, rp, x, y = this:GetPoint()
    TotemTimeDB.point, TotemTimeDB.relPoint, TotemTimeDB.x, TotemTimeDB.y = p, rp, x, y
end)

TotemTime:Hide()

-- Background
TotemTime.bg = TotemTime:CreateTexture(nil, "BACKGROUND")
TotemTime.bg:SetAllPoints(TotemTime)
TotemTime.bg:SetTexture(0, 0, 0, 0.6)

-- Title
TotemTime.title = TotemTime:CreateFontString(nil, "OVERLAY", "GameFontNormal")
TotemTime.title:SetPoint("TOP", TotemTime, "TOP", 0, -6)
TotemTime.title:SetText("Totems")

-- Element colors (slightly tinted)
local ELEMENT_COLORS = {
    [1] = { 0.6, 0.4, 0.2 }, -- Earth (brown)
    [2] = { 0.9, 0.3, 0.1 }, -- Fire  (orange/red)
    [3] = { 0.2, 0.6, 1.0 }, -- Water (blue)
    [4] = { 0.8, 0.9, 1.0 }, -- Air   (light)
}

-- Lines
TotemTime.lines = {}
for i = 1, 4 do
    local fs = TotemTime:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", TotemTime, "TOPLEFT", 10, -22 - (i - 1) * 17)
    fs:SetText("")
    local r, g, b = unpack(ELEMENT_COLORS[i])
    fs:SetTextColor(r, g, b)
    TotemTime.lines[i] = fs
end

-- Debug (can be toggled and saved)
local TOTEMTIME_DEBUG = false
local function dprint(msg)
    if TOTEMTIME_DEBUG then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[TotemTime]|r " .. msg)
    end
end

local ELEMENT_NAMES = {
    [1] = "Earth",
    [2] = "Fire",
    [3] = "Water",
    [4] = "Air",
}

-- Totem durations (seconds) - adjust per server if needed
local TOTEM_DATA = {
    -- Earth
    ["Strength of Earth Totem"] = { element = 1, duration = 120 },
    ["Stoneskin Totem"]         = { element = 1, duration = 120 },
    ["Stoneclaw Totem"]         = { element = 1, duration = 15  },
    ["Earthbind Totem"]         = { element = 1, duration = 45  },
    ["Tremor Totem"]            = { element = 1, duration = 120 },

    -- Fire
    ["Searing Totem"]           = { element = 2, duration = 55  },
    ["Magma Totem"]             = { element = 2, duration = 20  },
    ["Fire Nova Totem"]         = { element = 2, duration = 5   },
    ["Flametongue Totem"]       = { element = 2, duration = 120 },
    ["Fire Resistance Totem"]   = { element = 2, duration = 120 },

    -- Water
    ["Healing Stream Totem"]    = { element = 3, duration = 60  },
    ["Mana Spring Totem"]       = { element = 3, duration = 60  },
    ["Disease Cleansing Totem"] = { element = 3, duration = 120 },
    ["Poison Cleansing Totem"]  = { element = 3, duration = 120 },
    ["Frost Resistance Totem"]  = { element = 3, duration = 120 },

    -- Air
    ["Windfury Totem"]          = { element = 4, duration = 120 },
    ["Grace of Air Totem"]      = { element = 4, duration = 120 },
    ["Nature Resistance Totem"] = { element = 4, duration = 120 },
    ["Grounding Totem"]         = { element = 4, duration = 45  },
    ["Sentry Totem"]            = { element = 4, duration = 300 },
    ["Tranquil Air Totem"]      = { element = 4, duration = 120 },
    ["Windwall Totem"]          = { element = 4, duration = 120 },
}

-- Clear-spell names
local TOTEMIC_CLEAR_SPELLS = {
    ["Totemic Call"]   = true,  -- Classic
    ["Totemic Recall"] = true,  -- TurtleWoW
}

-- State
local activeTotems = {}
local pendingSpell = nil
local pendingStart = nil

-- Hidden tooltip for action scanning (fallback, may not work on Turtle)
local ScanTT = CreateFrame("GameTooltip", "TotemTimeScanTooltip", UIParent, "GameTooltipTemplate")
ScanTT:SetOwner(UIParent, "ANCHOR_NONE")

-- Helpers
local function trim(s)
    if not s then return s end
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function StripRank(name)
    if not name then return nil end
    local base = name
    base = string.gsub(base, "%s*%b()", "")             -- " (Rank 3)"
    base = string.gsub(base, "%s+[Rr]ank%s*%d+$", "")   -- " Rank 3"
    base = string.gsub(base, "%s+[IVXLCM]+$", "")       -- " IV"
    base = string.gsub(base, "%s+%d+$", "")             -- trailing number
    base = string.gsub(base, "%s+$", "")
    return base
end

local function IsTrackedTotem(base)
    return base and (TOTEM_DATA[base] ~= nil or TOTEMIC_CLEAR_SPELLS[base])
end

local function ClearAllTotems(reason)
    for i = 1, 4 do
        activeTotems[i] = nil
        TotemTime.lines[i]:SetText("")
    end
    dprint("Cleared all totems" .. (reason and (" (" .. reason .. ")") or ""))
    TotemTime:Hide()
end

local function ExtractSpellFromMacro(body)
    if not body then return nil end
    for line in string.gfind(body, "[^\r\n]+") do
        local cmd, rest = string.match(line, "^%s*/(%a+)%s+(.*)$")
        if cmd then
            cmd = string.lower(cmd)
            if cmd == "cast" or cmd == "use" then
                rest = string.gsub(rest, "%b[]", "")   -- [mod] etc
                rest = string.gsub(rest, "!", "")
                rest = trim(rest)
                if rest and rest ~= "" then
                    local base = StripRank(rest)
                    if IsTrackedTotem(base) then return base end
                    for name,_ in pairs(TOTEM_DATA) do
                        if string.find(rest, name, 1, true) then return name end
                    end
                    for clearName,_ in pairs(TOTEMIC_CLEAR_SPELLS) do
                        if string.find(rest, clearName, 1, true) then return clearName end
                    end
                end
            end
        end
    end
    return nil
end

local function ActivateTotem(spellName)
    if TOTEMIC_CLEAR_SPELLS[spellName] then
        ClearAllTotems(spellName)
        return
    end
    local data = TOTEM_DATA[spellName]
    if not data then
        dprint("ActivateTotem called for unknown spell: " .. tostring(spellName))
        return
    end
    activeTotems[data.element] = { start = GetTime(), duration = data.duration, name = spellName }
    dprint(string.format("Timer started: %s (%s) for %ds", spellName, ELEMENT_NAMES[data.element], data.duration))
    TotemTime:Show()
end

-- Primary hooks (may not fire on Turtle; keep for macros/spellbook casting)
local Orig_CastSpellByName = CastSpellByName
CastSpellByName = function(name, onSelf)
    if name then
        local base = StripRank(name)
        if IsTrackedTotem(base) then
            pendingSpell = base
            pendingStart = GetTime()
            dprint(string.format("Detected CastSpellByName: '%s' -> '%s' (tracking)", name, base))
        end
    end
    return Orig_CastSpellByName(name, onSelf)
end

local Orig_CastSpell = CastSpell
CastSpell = function(spellId, bookType)
    local name,_ = GetSpellName(spellId, bookType)
    if name then
        local base = StripRank(name)
        if IsTrackedTotem(base) then
            pendingSpell = base
            pendingStart = GetTime()
            dprint(string.format("Detected CastSpell: id=%s book=%s -> '%s' (tracking)", tostring(spellId), tostring(bookType), base))
        end
    end
    return Orig_CastSpell(spellId, bookType)
end

local Orig_UseAction = UseAction
UseAction = function(slot, checkCursor, onSelf)
    local detected = nil

    if GetActionInfo then
        local aType, id, subType = GetActionInfo(slot)
        dprint(string.format("UseAction slot %d GetActionInfo: type=%s id=%s sub=%s", slot, tostring(aType), tostring(id), tostring(subType)))
        if aType == "spell" and id then
            local name,_ = GetSpellName(id, BOOKTYPE_SPELL)
            if name then
                local base = StripRank(name)
                if IsTrackedTotem(base) then
                    detected = base
                    dprint("UseAction resolved spellbook: " .. name .. " -> " .. base)
                end
            end
        elseif aType == "macro" and id and GetMacroInfo then
            local mName, mIcon, mBody = GetMacroInfo(id)
            local base = ExtractSpellFromMacro(mBody)
            dprint(string.format("UseAction macro id=%s name='%s' -> base=%s", tostring(id), tostring(mName), tostring(base)))
            if IsTrackedTotem(base) then detected = base end
        end
    else
        dprint("GetActionInfo not available; skipping action info path.")
    end

    -- Tooltip fallback (often doesn’t work on Turtle, but harmless)
    if not detected and ScanTT and ScanTT.SetAction then
        ScanTT:ClearLines()
        ScanTT:SetAction(slot)
        local text = _G["TotemTimeScanTooltipTextLeft1"] and _G["TotemTimeScanTooltipTextLeft1"]:GetText() or nil
        if text and text ~= "" then
            local base = StripRank(text)
            dprint(string.format("UseAction slot %d tooltip L1='%s' -> base='%s'", slot, text, tostring(base)))
            if IsTrackedTotem(base) then detected = base end
        else
            dprint(string.format("UseAction slot %d: no tooltip text", slot))
        end
        ScanTT:Hide()
    end

    if detected then
        pendingSpell = detected
        pendingStart = GetTime()
        dprint("Detected UseAction totem: " .. detected .. " (tracking)")
    end

    return Orig_UseAction(slot, checkCursor, onSelf)
end

-- Events
TotemTime:RegisterEvent("VARIABLES_LOADED")
TotemTime:RegisterEvent("PLAYER_ENTERING_WORLD") -- clear on zoning/load screens
TotemTime:RegisterEvent("PLAYER_DEAD")           -- clear on death
TotemTime:RegisterEvent("SPELLCAST_SENT")        -- may not fire on Turtle
TotemTime:RegisterEvent("SPELLCAST_STOP")
TotemTime:RegisterEvent("SPELLCAST_FAILED")
TotemTime:RegisterEvent("SPELLCAST_INTERRUPTED")

-- Combat log parsing (Vanilla)
TotemTime:RegisterEvent("CHAT_MSG_SPELL_SELF_BUFF")
TotemTime:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
TotemTime:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_BUFF")

-- Chat detection helpers
local function ActivateFromChatDetected(base, eventName, rawName)
    dprint(string.format("TRACK from combat log (%s): %s (raw '%s')", eventName, base, tostring(rawName)))
    ActivateTotem(base)
    pendingSpell = nil
    pendingStart = nil
end

local function TryDetectFromChat(msg, eventName)
    if not msg or msg == "" then return false end

    -- Turtle: Totemic Recall mana refund
    local recallMana = string.match(msg, "^You gain [%d,]+%s+[Mm]ana from Totemic Recall%.?$")
    if recallMana then
        dprint("Detected Totemic Recall (mana gain) from combat log; clearing timers.")
        ClearAllTotems("Totemic Recall")
        return true
    end

    -- Any mention of Totemic Recall in self-buff lines -> clear
    if string.find(msg, "Totemic Recall", 1, true) then
        dprint("Detected Totemic Recall mention in combat log; clearing timers.")
        ClearAllTotems("Totemic Recall")
        return true
    end

    -- Classic patterns
    local casted = string.match(msg, "^You cast (.+)%.$")
    local created = string.match(msg, "^You create (.+)%.$")
    local placed  = string.match(msg, "^You place (.+)%.$")
    local name = casted or created or placed

    if name then
        local base = StripRank(name)
        dprint(string.format("%s: '%s' -> base '%s'", eventName, name, tostring(base)))
        if IsTrackedTotem(base) then
            ActivateFromChatDetected(base, eventName, name)
            return true
        else
            for totem,_ in pairs(TOTEM_DATA) do
                if string.find(name, totem, 1, true) then
                    ActivateFromChatDetected(totem, eventName, name)
                    return true
                end
            end
            for clearName,_ in pairs(TOTEMIC_CLEAR_SPELLS) do
                if string.find(name, clearName, 1, true) then
                    ClearAllTotems(clearName)
                    return true
                end
            end
        end
    else
        dprint(eventName .. " raw: " .. msg)
    end
    return false
end

TotemTime:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        -- Apply saved position
        if TotemTimeDB.point and TotemTimeDB.relPoint and TotemTimeDB.x and TotemTimeDB.y then
            TotemTime:ClearAllPoints()
            TotemTime:SetPoint(TotemTimeDB.point, UIParent, TotemTimeDB.relPoint, TotemTimeDB.x, TotemTimeDB.y)
        end
        -- Apply lock/debug from DB (defaults)
        if TotemTimeDB.locked == nil then TotemTimeDB.locked = false end
        if TotemTimeDB.debug  == nil then TotemTimeDB.debug  = false end
        TOTEMTIME_DEBUG = TotemTimeDB.debug

        TotemTime:SetMovable(not TotemTimeDB.locked)
        TotemTime:EnableMouse(not TotemTimeDB.locked)

        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00TotemTime loaded|r - /ttlock to lock/unlock, /ttdebug to toggle debug.")
        if TOTEMTIME_DEBUG then dprint("Debug logging is ON") end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        -- Clear on load screens/zone changes to avoid stale timers
        ClearAllTotems("Entering World")
        return
    end

    if event == "PLAYER_DEAD" then
        ClearAllTotems("Player Dead")
        return
    end

    if event == "SPELLCAST_SENT" then
        dprint("EVENT: SPELLCAST_SENT arg1=" .. tostring(arg1) .. " arg2=" .. tostring(arg2))
        local base = StripRank(arg1)
        if IsTrackedTotem(base) then
            pendingSpell = base
            pendingStart = GetTime()
            dprint("TRACK from SENT: " .. base)
        end
        return
    end

    if event == "CHAT_MSG_SPELL_SELF_BUFF" or event == "CHAT_MSG_SPELL_SELF_DAMAGE" or event == "CHAT_MSG_SPELL_PERIODIC_SELF_BUFF" then
        TryDetectFromChat(arg1, event)
        return
    end

    if event == "SPELLCAST_STOP" then
        local elapsed = pendingStart and (GetTime() - pendingStart) or nil
        if not pendingSpell and CastingBarFrameText and CastingBarFrameText:GetText() then
            local cb = CastingBarFrameText:GetText()
            local base = StripRank(cb)
            dprint("SPELLCAST_STOP fallback CastingBar text: '" .. tostring(cb) .. "' -> base '" .. tostring(base) .. "'")
            if IsTrackedTotem(base) then
                pendingSpell = base
            end
        end

        dprint("EVENT: SPELLCAST_STOP pending=" .. tostring(pendingSpell) .. (elapsed and string.format(" elapsed=%.0fms", elapsed * 1000) or ""))
        if pendingSpell then
            if elapsed then
                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00[TotemTime]|r Cast confirmed: %s in %.0fms", pendingSpell, elapsed * 1000))
            else
                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00[TotemTime]|r Cast confirmed: %s", pendingSpell))
            end
            ActivateTotem(pendingSpell)
            pendingSpell = nil
            pendingStart = nil
        end
        return
    end

    if event == "SPELLCAST_FAILED" or event == "SPELLCAST_INTERRUPTED" then
        local elapsed = pendingStart and (GetTime() - pendingStart) or nil
        -- DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff3333[TotemTime]|r %s: %s%s", event, tostring(pendingSpell or "unknown"), elapsed and string.format(" after %.0fms", elapsed * 1000) or ""))
        dprint("Clearing pending due to " .. event)
        pendingSpell = nil
        pendingStart = nil
        return
    end
end)

-- OnUpdate: update visible timers
TotemTime:SetScript("OnUpdate", function()
    local now = GetTime()
    local anyActive = false

    for element = 1, 4 do
        local t = activeTotems[element]
        if t then
            local remaining = math.ceil(t.start + t.duration - now)
            if remaining <= 0 then
                activeTotems[element] = nil
                TotemTime.lines[element]:SetText("")
            else
                TotemTime.lines[element]:SetText(string.format("%s: %s - %ds", ELEMENT_NAMES[element], t.name, remaining))
                anyActive = true
            end
        else
            TotemTime.lines[element]:SetText("")
        end
    end

    if anyActive then TotemTime:Show() else TotemTime:Hide() end
end)

-- Slash commands
SLASH_TOTEMTIME1 = "/totemtime"
SLASH_TOTEMTIME2 = "/ttlock"
SlashCmdList["TOTEMTIME"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "reset" then
        TotemTime:ClearAllPoints()
        TotemTime:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        TotemTimeDB.point, TotemTimeDB.relPoint, TotemTimeDB.x, TotemTimeDB.y = "CENTER", "CENTER", 0, 0
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00TotemTime: position reset.|r")
        return
    end
    -- toggle lock
    TotemTimeDB.locked = not TotemTimeDB.locked
    TotemTime:SetMovable(not TotemTimeDB.locked)
    TotemTime:EnableMouse(not TotemTimeDB.locked)
    if TotemTimeDB.locked then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00TotemTime: locked.|r")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00TotemTime: unlocked (drag to move).|r")
    end
end

SLASH_TOTEMTIMEDEBUG1 = "/ttdebug"
SlashCmdList["TOTEMTIMEDEBUG"] = function()
    TOTEMTIME_DEBUG = not TOTEMTIME_DEBUG
    TotemTimeDB.debug = TOTEMTIME_DEBUG
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00TotemTime: Debug|r = " .. (TOTEMTIME_DEBUG and "ON" or "OFF"))
end