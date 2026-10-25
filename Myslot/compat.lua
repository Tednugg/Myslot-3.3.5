-- 3.3.5a helpers for things the modern client has built in.
-- Everything lives on the addon table; no globals are created.

local _, MySlot = ...

local compat = {}
MySlot.compat = compat

-- {{{ Timer (3.3.5 has no C_Timer)
-- compat.After(delay, fn) runs fn once after `delay` seconds (0 = next frame).
do
    local timerFrame = CreateFrame("Frame")
    local queue = {}
    local now = 0

    timerFrame:Hide()
    timerFrame:SetScript("OnUpdate", function(self, elapsed)
        now = now + elapsed

        -- Run everything that is due. Callbacks may add new timers, which
        -- land in a fresh queue and wait for at least the next frame.
        local due = queue
        queue = {}
        for i = 1, #due do
            local t = due[i]
            if t.at <= now then
                local ok, err = pcall(t.fn)
                if not ok then
                    geterrorhandler()(err)
                end
            else
                queue[#queue + 1] = t
            end
        end

        if #queue == 0 then
            self:Hide()
        end
    end)

    function compat.After(delay, fn)
        queue[#queue + 1] = { at = now + (delay or 0), fn = fn }
        timerFrame:Show()
    end
end
-- }}}

-- {{{ Small helpers
function compat.AppendAll(target, source)
    for _, v in ipairs(source) do
        target[#target + 1] = v
    end
    return target
end

function compat.SetShown(region, shown)
    if shown then
        region:Show()
    else
        region:Hide()
    end
end

function compat.SetEnabled(button, enabled)
    if enabled then
        button:Enable()
    else
        button:Disable()
    end
end

-- Color helpers. 3.3.5 has the *_FONT_COLOR_CODE strings but no
-- WrapTextInColorCode.
function compat.Red(text)
    return (RED_FONT_COLOR_CODE or "|cffff2020") .. text .. (FONT_COLOR_CODE_CLOSE or "|r")
end

function compat.Green(text)
    return (GREEN_FONT_COLOR_CODE or "|cff20ff20") .. text .. (FONT_COLOR_CODE_CLOSE or "|r")
end

function compat.Yellow(text)
    return "|cffffff00" .. text .. "|r"
end

function compat.Orange(text)
    return "|cffff8000" .. text .. "|r"
end

function compat.ClassColor(token, text)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if not c then
        return text
    end
    return ("|cff%02x%02x%02x%s|r"):format(c.r * 255, c.g * 255, c.b * 255, text)
end

-- StaticPopup edit box: 3.3.5 only names it "<popup>EditBox".
function compat.PopupEditBox(popup)
    return popup.editBox or _G[popup:GetName() .. "EditBox"]
end

-- Spell id from a spell link ("|Hspell:12345|h[...]|h").
function compat.SpellIdFromLink(link)
    if type(link) ~= "string" then
        return nil
    end
    local id = link:match("|Hspell:(%d+)")
    return id and tonumber(id) or nil
end
-- }}}
