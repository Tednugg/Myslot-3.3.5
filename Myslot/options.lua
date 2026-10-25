-- Interface Options panel (3.3.5: InterfaceOptions_AddCategory instead of
-- the retail Settings API).

local _, MySlot = ...
local L = MySlot.L
local RegEvent = MySlot.regevent
local compat = MySlot.compat

local f = CreateFrame("Frame", "MyslotOptionsPanel", UIParent)
f.name = L["Myslot"]
f:Hide()
InterfaceOptions_AddCategory(f)

MySlot.optionsPanel = f

function MySlot.OpenOptions()
    -- 3.3.5 often opens the wrong page on the first call; calling twice is
    -- the usual workaround.
    InterfaceOptionsFrame_OpenToCategory(f)
    InterfaceOptionsFrame_OpenToCategory(f)
end

local function NewCheck(name, parent, text)
    local b = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    _G[name .. "Text"]:SetText(text)
    return b
end

RegEvent("ADDON_LOADED", function()
    do
        local t = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        t:SetText(L["Myslot"])
        t:SetPoint("TOPLEFT", f, 15, -15)
    end

    do
        local t = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        t:SetText(L["Feedback"] .. "  farmer1992@gmail.com")
        t:SetPoint("TOPLEFT", f, 15, -50)
    end

    do
        local b = CreateFrame("Button", "MyslotOptionsOpen", f, "UIPanelButtonTemplate")
        b:SetWidth(240)
        b:SetHeight(25)
        b:SetPoint("TOPLEFT", 15, -80)
        b:SetText(L["Open Myslot"])
        b:SetScript("OnClick", function()
            InterfaceOptionsFrame:Hide()
            MySlot.MainFrame:Show()
        end)
    end

    MyslotSettings = MyslotSettings or {}

    do
        MyslotSettings.minimap = MyslotSettings.minimap or { hide = false }
        local config = MyslotSettings.minimap

        local b = NewCheck("MyslotOptionsMinimap", f, L["Minimap Icon"])
        b:SetPoint("TOPLEFT", f, 15, -110)
        b:SetChecked((not config.hide) and 1 or nil)
        b:SetScript("OnClick", function(self)
            config.hide = not self:GetChecked()

            local icon = LibStub("LibDBIcon-1.0")
            if self:GetChecked() then
                icon:Show("Myslot")
            else
                icon:Hide("Myslot")
            end
        end)
    end

    local doffset = -160
    do
        local t = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        t:SetText(compat.Red(L["DANGEROUS"]))
        t:SetPoint("TOPLEFT", f, 15, doffset)
    end

    local rowy = doffset - 20
    local function AddClearButton(text, what)
        local b = CreateFrame("Button", "MyslotOptionsClear" .. what, f, "UIPanelButtonTemplate")
        b:SetWidth(240)
        b:SetHeight(25)
        b:SetPoint("TOPLEFT", 15, rowy)
        b:SetText(text)
        b:SetScript("OnClick", function()
            StaticPopup_Show("MYSLOT_CONFIRM_CLEAR", what, nil, what)
        end)
        rowy = rowy - 30
    end

    AddClearButton(L["Remove everything in ActionBar"], "ACTION")
    AddClearButton(L["Remove all Key Bindings"], "BINDING")
    AddClearButton(L["Remove all Macros"], "MACRO")

    do
        local b = NewCheck("MyslotOptionsAllowClear", f,
            L["Allow"] .. " " .. "|cffff0000" .. L["CLEAR"] .. "|r" .. " " .. L[" before Import"])
        b:SetPoint("TOPLEFT", f, 15, rowy)
        b:SetChecked(MyslotSettings.allowclearonimport and 1 or nil)
        b:SetScript("OnClick", function(self)
            MyslotSettings.allowclearonimport = self:GetChecked() and true or false
        end)
    end
end)

local function DoClear(popup, data)
    local editBox = compat.PopupEditBox(popup)
    local tx = editBox:GetText()

    if tx == data then
        local all = { ["ACCOUNT"] = true, ["CHARACTOR"] = true }
        for i = 1, MySlot.MAX_ACTIONBAR / 12 do
            all[i] = true
        end
        MySlot:Clear(data, all)
    else
        MySlot:Print(L["Please type %s to confirm"]:format(data))
    end
end

StaticPopupDialogs["MYSLOT_CONFIRM_CLEAR"] = {
    text = L["Please type %s to confirm"],
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = 1,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    OnShow = function(self)
        local editBox = compat.PopupEditBox(self)
        editBox:SetText("")
        editBox:SetFocus()
    end,
    OnAccept = DoClear,
    EditBoxOnEnterPressed = function(editBox)
        local popup = editBox:GetParent()
        DoClear(popup, popup.data)
        popup:Hide()
    end,
    EditBoxOnEscapePressed = function(editBox)
        editBox:GetParent():Hide()
    end,
}
