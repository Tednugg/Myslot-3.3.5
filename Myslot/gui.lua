-- Myslot main window, rebuilt for 3.3.5a.
--
-- The retail window uses Blizzard_Menu (MenuUtil) for every dropdown; 3.3.5
-- only has UIDropDownMenu, which caps a menu at 32 entries. So the
-- import/export option menus use UIDropDownMenu, and the saved profile picker
-- is a small scrollable list panel instead of a dropdown.

local _, MySlot = ...

local L = MySlot.L
local RegEvent = MySlot.regevent
local compat = MySlot.compat
local MAX_PROFILES_COUNT = 100
local IMPORT_BACKUP_COUNT = 3

local NUM_ACTION_BARS = MySlot.MAX_ACTIONBAR / 12

-- Blizzard's 3.3.5 templates find their pieces by global name, so every
-- templated frame gets a unique one.
local nameCounter = 0
local function NextName(kind)
    nameCounter = nameCounter + 1
    return "Myslot" .. kind .. nameCounter
end

local function NewButton(parent, width, height, text)
    local b = CreateFrame("Button", NextName("Button"), parent, "GameMenuButtonTemplate")
    b:SetWidth(width)
    b:SetHeight(height)
    if text then
        b:SetText(text)
    end
    return b
end

local function NoWrap(fs)
    if fs.SetWordWrap then
        fs:SetWordWrap(false)
    end
end

local f = CreateFrame("Frame", "MyslotMainFrame", UIParent)
f:SetWidth(650)
f:SetHeight(600)
f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 32,
    insets = { left = 8, right = 8, top = 10, bottom = 10 }
})
f:SetBackdropColor(0, 0, 0)
f:SetPoint("CENTER", 0, 0)
f:SetToplevel(true)
-- below StaticPopups (DIALOG) so confirmations always show on top
f:SetFrameStrata("HIGH")
f:EnableMouse(true)
f:SetMovable(true)
f:SetClampedToScreen(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", f.StopMovingOrSizing)
f:Hide()
-- Escape closes it
tinsert(UISpecialFrames, "MyslotMainFrame")

MySlot.MainFrame = f

-- {{{ Import progress bar
local progressFrame = CreateFrame("Frame", nil, UIParent)
progressFrame:SetWidth(360)
progressFrame:SetHeight(70)
progressFrame:SetPoint("CENTER", 0, 0)
progressFrame:SetFrameStrata("FULLSCREEN_DIALOG")
progressFrame:SetToplevel(true)
progressFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 }
})
progressFrame:SetBackdropColor(0, 0, 0)
progressFrame:Hide()

local progressText = progressFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
progressText:SetPoint("TOP", 0, -14)

local progressBar = CreateFrame("StatusBar", nil, progressFrame)
progressBar:SetWidth(320)
progressBar:SetHeight(18)
progressBar:SetPoint("BOTTOM", 0, 16)
progressBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
progressBar:SetStatusBarColor(0.2, 0.6, 1.0)
progressBar:SetMinMaxValues(0, 1)
progressBar:SetValue(0)

local progressBg = progressBar:CreateTexture(nil, "BACKGROUND")
progressBg:SetAllPoints(progressBar)
progressBg:SetTexture(0, 0, 0, 0.6)

local function ShowImportProgress()
    progressBar:SetValue(0)
    progressText:SetText(L["Importing..."])
    progressFrame:Show()
end

local function SetImportProgress(frac, waiting)
    if waiting then
        progressText:SetText(L["Importing..."] .. " " .. L["(waiting for combat to end)"])
        return
    end
    frac = frac or 0
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    progressBar:SetValue(frac)
    progressText:SetText(("%s %d%%"):format(L["Importing..."], math.floor(frac * 100 + 0.5)))
end

local function HideImportProgress(ok)
    progressFrame:Hide()
    if ok == false then
        MySlot:Print(L["Import failed"])
    end
end
-- }}}

-- title
do
    local t = f:CreateTexture(nil, "ARTWORK")
    t:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    t:SetWidth(256)
    t:SetHeight(64)
    t:SetPoint("TOP", f, 0, 12)
    f.texture = t
end

do
    local t = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    t:SetText(L["Myslot"])
    t:SetPoint("TOP", f.texture, 0, -14)
end

local exportEditbox
local infolabel

-- Put text in the editor. Unless `unsaved`, the text counts as saved.
local function SetEditorText(text, unsaved)
    exportEditbox.savedtxt = nil
    exportEditbox:SetText(text or "")
    if unsaved then
        infolabel.ShowUnsaved()
    else
        -- compare against what the box actually holds after SetText
        exportEditbox.savedtxt = exportEditbox:GetText()
        infolabel:SetText("")
    end
end

-- options
do
    local b = NewButton(f, 100, 25, OPTIONS or "Options")
    b:SetPoint("BOTTOMRIGHT", -145, 15)
    b:SetScript("OnClick", function()
        if MySlot.OpenOptions then
            MySlot.OpenOptions()
        end
    end)
end

-- close
do
    local b = NewButton(f, 100, 25, CLOSE or "Close")
    b:SetPoint("BOTTOMRIGHT", -40, 15)
    b:SetScript("OnClick", function() f:Hide() end)
end

-- {{{ Option menus (UIDropDownMenu)
local menuFrame = CreateFrame("Frame", "MyslotOptionMenu", UIParent, "UIDropDownMenuTemplate")
local currentMenu, currentAnchor

local OpenOptionMenu

-- Menu entries are plain tables: { text, isTitle, checked = fn, func = fn,
-- menuList = {...} }. 3.3.5's dropdown wants `checked` as a value, so it is
-- evaluated every time the menu is built.
local function InitOptionMenu(self, level)
    local list = (level or 1) == 1 and currentMenu or UIDROPDOWNMENU_MENU_VALUE
    if type(list) ~= "table" then
        return
    end

    for _, m in ipairs(list) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = m.text
        if m.isTitle then
            info.isTitle = 1
            info.notCheckable = 1
        else
            info.checked = (m.checked and m.checked()) and 1 or nil
            info.keepShownOnClick = 1
            if m.menuList then
                info.hasArrow = 1
                info.value = m.menuList
                -- toggling a whole group changes its children, rebuild
                info.func = function()
                    m.func()
                    CloseDropDownMenus()
                    OpenOptionMenu(currentMenu, currentAnchor)
                end
            else
                info.func = function()
                    m.func()
                end
            end
        end
        UIDropDownMenu_AddButton(info, level)
    end
end

OpenOptionMenu = function(menu, anchor)
    currentMenu, currentAnchor = menu, anchor
    UIDropDownMenu_Initialize(menuFrame, InitOptionMenu, "MENU")
    ToggleDropDownMenu(1, nil, menuFrame, anchor, 0, 0)
end

local function CreateSettingMenu(opt, onChanged)

    local tableref = function(name)
        if name == "action" then
            return opt.ignoreActionBars
        end

        if name == "macro" then
            return opt.ignoreMacros
        end
    end

    local function changed()
        if onChanged then
            onChanged()
        end
    end

    local function child(name, key, text)
        return {
            text = text,
            checked = function()
                return tableref(name)[key]
            end,
            func = function()
                local t = tableref(name)
                t[key] = not t[key]
                changed()
            end,
        }
    end

    local function parentchecked(name)
        for _, v in pairs(tableref(name)) do
            if v then
                return true
            end
        end
        return false
    end

    local function parentclicked(name)
        local checkedany = parentchecked(name)
        local t = tableref(name)
        for i in pairs(t) do
            t[i] = not checkedany
        end
        changed()
    end

    if not opt.ignoreActionBars then
        opt.ignoreActionBars = {}
        for i = 1, NUM_ACTION_BARS do
            opt.ignoreActionBars[i] = false
        end
    end

    opt.ignoreBinding = false

    opt.ignoreMacros = opt.ignoreMacros or {
        ["ACCOUNT"] = false,
        ["CHARACTOR"] = false,
    }

    opt.ignorePetActionBar = false

    -- https://wowpedia.fandom.com/wiki/Action_slot (3.3.5 layout)
    local actionbarlist = {
        child("action", 1, L["Main Action Bar Page"] .. " 1"),
        child("action", 2, L["Main Action Bar Page"] .. " 2"),
        child("action", BOTTOMLEFT_ACTIONBAR_PAGE or 6, SHOW_MULTIBAR1_TEXT or "Bottom Left ActionBar"),
        child("action", BOTTOMRIGHT_ACTIONBAR_PAGE or 5, SHOW_MULTIBAR2_TEXT or "Bottom Right ActionBar"),
        child("action", RIGHT_ACTIONBAR_PAGE or 3, SHOW_MULTIBAR3_TEXT or "Right ActionBar"),
        child("action", LEFT_ACTIONBAR_PAGE or 4, SHOW_MULTIBAR4_TEXT or "Right ActionBar 2"),
    }
    -- 73-120: the bars warriors, druids, rogues and priests swap to in a
    -- stance / form / stealth / shadowform
    for i = 1, 4 do
        table.insert(actionbarlist, child("action", 6 + i, L["Stance Action Bar"] .. " " .. i))
    end

    local menu = {
        {
            text = ACTIONBARS_LABEL or "Action Bars",
            menuList = actionbarlist,
            checked = function() return parentchecked("action") end,
            func = function() parentclicked("action") end,
        },
        {
            text = L["Key Binding"],
            checked = function() return opt.ignoreBinding end,
            func = function()
                opt.ignoreBinding = not opt.ignoreBinding
                changed()
            end,
        },
        {
            text = MACRO or "Macro",
            menuList = {
                child("macro", "ACCOUNT", GENERAL_MACROS or "General Macros"),
                child("macro", "CHARACTOR", (CHARACTER_SPECIFIC_MACROS or "%s Specific Macros"):format("")),
            },
            checked = function() return parentchecked("macro") end,
            func = function() parentclicked("macro") end,
        },
    }

    if MySlot:IsPetActionBarSupported() then
        table.insert(menu, {
            text = (PET or "Pet") .. " " .. (ACTIONBARS_LABEL or "Action Bars"),
            isPet = true,
            checked = function() return opt.ignorePetActionBar end,
            func = function()
                opt.ignorePetActionBar = not opt.ignorePetActionBar
                changed()
            end,
        })
    end

    return menu
end

local function AllSettingMenuIgnored(opt)
    if not opt or not opt.ignoreActionBars or not opt.ignoreMacros then
        return false
    end
    for _, v in pairs(opt.ignoreActionBars) do
        if not v then
            return false
        end
    end
    if not opt.ignoreBinding then
        return false
    end
    for _, v in pairs(opt.ignoreMacros) do
        if not v then
            return false
        end
    end
    if MySlot:IsPetActionBarSupported() and not opt.ignorePetActionBar then
        return false
    end
    return true
end

local function ArrowButton(anchorTo)
    local ba = CreateFrame("Button", NextName("Button"), f, "GameMenuButtonTemplate")
    ba:SetWidth(25)
    ba:SetHeight(25)
    ba:SetPoint("LEFT", anchorTo, "RIGHT", 0, 0)
    ba:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local icon = ba:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
    icon:SetPoint("CENTER", 1, 0)
    icon:SetWidth(16)
    icon:SetHeight(16)
    return ba
end
-- }}}

-- import
do
    local actionOpt = {}
    local clearOpt = {}
    local forceImport = false

    local b = NewButton(f, 125, 25, L["Import"])
    b:SetPoint("BOTTOMLEFT", 200, 15)
    b:SetScript("OnClick", function()
        local text = exportEditbox:GetText()
        local msg, meta = MySlot:Import(text, {
            force = forceImport,
        })

        if not msg then
            return
        end

        -- Talents aren't part of the import, so warn when the bars about to
        -- be restored were saved with a different talent spread.
        local warning
        local profileTalent = MySlot:ParseTalentString(text)
        local myTalent = MySlot:GetTalentString()
        if profileTalent and myTalent and profileTalent ~= myTalent then
            warning = L["The talents of this profile are different from your current talents."]
                .. " (" .. profileTalent .. " / " .. myTalent .. ")"
            MySlot:Print(warning)
        end

        StaticPopupDialogs["MYSLOT_MSGBOX"].text = warning
            and (L["Are you SURE to import ?"] .. "\n\n" .. compat.Red(warning))
            or L["Are you SURE to import ?"]

        StaticPopupDialogs["MYSLOT_MSGBOX"].OnAccept = function()
            if InCombatLockdown() then
                MySlot:Print(L["Import is not allowed when you are in combat"])
                return
            end

            MySlot:Print(L["Starting backup..."])
            local ok, backup = pcall(MySlot.Export, MySlot, actionOpt)

            if not ok or not backup then
                MySlot:Print(L["Backup failed"])
                if not forceImport then
                    return
                end
                backup = nil
            end

            if backup then
                table.insert(MyslotExports["backups"], { value = backup, time = time() })
                while #MyslotExports["backups"] > IMPORT_BACKUP_COUNT do
                    table.remove(MyslotExports["backups"], 1)
                end
            end

            MySlot:Clear("MACRO", clearOpt.ignoreMacros)
            MySlot:Clear("ACTION", clearOpt.ignoreActionBars)
            if clearOpt.ignoreBinding then
                MySlot:Clear("BINDING")
            end

            ShowImportProgress()
            MySlot:RunAsync(function()
                MySlot:RecoverData(msg, {
                    actionOpt = actionOpt,
                    clearOpt = clearOpt,
                    meta = meta,
                })
            end, SetImportProgress, HideImportProgress)
        end
        StaticPopup_Show("MYSLOT_MSGBOX")
    end)

    local ba = ArrowButton(b)

    local settings = {
        { isTitle = true, text = "|cffff0000" .. L["IGNORE"] .. "|r" .. L[" during Import"] },
    }
    compat.AppendAll(settings, CreateSettingMenu(actionOpt))

    local clearbegin = #settings + 1
    table.insert(settings, { isTitle = true, text = "|cffff0000" .. L["CLEAR"] .. "|r" .. L[" before Import"] })
    -- the pet bar has no "clear before import"
    for _, m in ipairs(CreateSettingMenu(clearOpt)) do
        if not m.isPet then
            table.insert(settings, m)
        end
    end
    local clearend = #settings

    compat.AppendAll(settings, {
        { isTitle = true, text = OTHER or "Other" },
        {
            text = L["Force Import"],
            checked = function() return forceImport end,
            func = function() forceImport = not forceImport end,
        },
    })

    local settingswithoutclear = {}
    compat.AppendAll(settingswithoutclear, settings)
    for i = clearend, clearbegin, -1 do
        table.remove(settingswithoutclear, i)
    end

    ba:SetScript("OnClick", function(self)
        OpenOptionMenu(MyslotSettings.allowclearonimport and settings or settingswithoutclear, self)
    end)
end

-- export
do
    local actionOpt = {}

    local b = NewButton(f, 125, 25, L["Export"])
    b:SetPoint("BOTTOMLEFT", 40, 15)

    local function UpdateExportButtonState()
        compat.SetEnabled(b, not AllSettingMenuIgnored(actionOpt))
    end

    b:SetScript("OnClick", function()
        local s = MySlot:Export(actionOpt)
        SetEditorText(s, true)
        exportEditbox:HighlightText()
    end)

    local ba = ArrowButton(b)

    local settings = {
        { isTitle = true, text = "|cffff0000" .. L["IGNORE"] .. "|r" .. L[" during Export"] },
    }
    compat.AppendAll(settings, CreateSettingMenu(actionOpt, UpdateExportButtonState))

    UpdateExportButtonState()

    ba:SetScript("OnClick", function(self)
        OpenOptionMenu(settings, self)
    end)
end

RegEvent("ADDON_LOADED", function()
    MyslotSettings = MyslotSettings or {}
    MyslotExports = MyslotExports or {}
    MyslotExports["exports"] = MyslotExports["exports"] or {}
    MyslotExports["backups"] = MyslotExports["backups"] or {}

    -- {{{ Text area
    do
        local t = CreateFrame("Frame", nil, f)
        t:SetWidth(600)
        t:SetHeight(455)
        t:SetPoint("TOPLEFT", f, 25, -75)
        t:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        t:SetBackdropColor(0, 0, 0, 0)
        t:SetBackdropBorderColor(0.6, 0.6, 0.6)
        t:EnableMouse(true)

        local s = CreateFrame("ScrollFrame", "MyslotEditScroll", t, "UIPanelScrollFrameTemplate")
        s:SetWidth(560)
        s:SetHeight(435)
        s:SetPoint("TOPLEFT", 10, -10)

        local edit = CreateFrame("EditBox", "MyslotEditBox", s)
        edit:SetWidth(550)
        edit:SetHeight(435)
        s:SetScrollChild(edit)
        edit:SetAutoFocus(false)
        edit:EnableMouse(true)
        edit:SetMaxLetters(99999999)
        edit:SetMultiLine(true)
        edit:SetFontObject(GameFontHighlightSmall)
        edit:SetScript("OnEscapePressed", edit.ClearFocus)
        edit:SetScript("OnMouseUp", function()
            edit:HighlightText(0, -1)
        end)

        -- keep the cursor in view while typing / pasting
        edit:SetScript("OnCursorChanged", function(self, x, y, w, h)
            if ScrollingEdit_OnCursorChanged then
                ScrollingEdit_OnCursorChanged(self, x, y - 10, w, h)
            end
        end)
        edit:SetScript("OnUpdate", function(self, elapsed)
            if ScrollingEdit_OnUpdate then
                ScrollingEdit_OnUpdate(self, elapsed, s)
            end
        end)
        edit:SetScript("OnTextChanged", function(self)
            if ScrollingEdit_OnTextChanged then
                ScrollingEdit_OnTextChanged(self, s)
            end
            if infolabel and self.savedtxt ~= nil and self:GetText() ~= self.savedtxt then
                self.savedtxt = nil
                infolabel.ShowUnsaved()
            end
        end)

        t:SetScript("OnMouseDown", function()
            edit:SetFocus()
        end)

        exportEditbox = edit
    end
    -- }}}

    -- {{{ Profiles
    local exports = MyslotExports["exports"]
    local backups = MyslotExports["backups"]

    local selectedIdx
    local profileButton

    do
        local tt = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        tt:SetPoint("TOPLEFT", f, 45, -32)

        tt.ShowUnsaved = function()
            tt:SetText(compat.Yellow(L["Unsaved"]))
        end

        infolabel = tt
    end

    -- the profile picker button
    do
        local t = CreateFrame("Button", NextName("Button"), f, "GameMenuButtonTemplate")
        t:SetPoint("TOPLEFT", f, 25, -45)
        t:SetWidth(240)
        t:SetHeight(26)

        local icon = t:CreateTexture(nil, "OVERLAY")
        icon:SetTexture("Interface\\Icons\\inv_scroll_03")
        icon:SetWidth(18)
        icon:SetHeight(18)
        icon:SetPoint("LEFT", t, "LEFT", 6, 0)

        local arrow = t:CreateTexture(nil, "OVERLAY")
        arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
        arrow:SetWidth(20)
        arrow:SetHeight(20)
        arrow:SetPoint("RIGHT", t, "RIGHT", -4, 0)

        -- replace the template's centered label with a left aligned one
        if t:GetFontString() then
            t:GetFontString():SetText("")
        end
        local label = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("LEFT", t, "LEFT", 28, 0)
        label:SetPoint("RIGHT", t, "RIGHT", -24, 0)
        label:SetJustifyH("LEFT")
        NoWrap(label)
        t.label = label

        profileButton = t
    end

    local function setButtonText(s)
        local label = profileButton.label
        if s and s ~= "" then
            label:SetText(s)
            label:SetTextColor(1, 0.82, 0)
        else
            label:SetText(L["Select a profile"])
            label:SetTextColor(0.5, 0.5, 0.5)
        end
    end

    local function setSelected(idx)
        selectedIdx = idx
        setButtonText(idx and exports[idx] and exports[idx].name or "")
    end

    local function selectLoadout(idx)
        setSelected(idx)
        SetEditorText(exports[idx] and exports[idx].value or "")
    end

    setSelected(nil)

    local create = function(name)
        if #exports >= MAX_PROFILES_COUNT then
            MySlot:Print(L["Too many profiles, please delete before create new one."])
            return
        end

        table.insert(exports, {
            name = name,
            class = select(2, UnitClass("player")),
        })

        return true
    end

    local save = function(force)
        local c = selectedIdx
        local v = exportEditbox:GetText()
        if not force and v == "" then
            return
        end
        if (not c) or (not exports[c]) then
            if not create(date()) then
                return
            end
            c = #exports
            setSelected(c)
        end

        exports[c].value = v
        exportEditbox.savedtxt = v
        infolabel:SetText("")
    end

    -- {{{ Profile list panel
    local ROW_HEIGHT = 18
    local NUM_ROWS = 14

    local SORT_MODES = {
        { value = "date", text = L["By date"] },
        { value = "name", text = L["By name"] },
        { value = "class", text = L["By class"] },
    }

    local list = CreateFrame("Frame", "MyslotProfileList", f)
    list:SetWidth(300)
    list:SetHeight(64 + NUM_ROWS * ROW_HEIGHT)
    list:SetPoint("TOPLEFT", profileButton, "BOTTOMLEFT", 0, 0)
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:SetToplevel(true)
    list:EnableMouse(true)
    list:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    list:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    list:Hide()
    f:HookScript("OnHide", function() list:Hide() end)

    local displayRows = {}
    local UpdateList

    -- "Only my class"
    local classCheck = CreateFrame("CheckButton", "MyslotProfileListClassCheck", list, "UICheckButtonTemplate")
    classCheck:SetWidth(24)
    classCheck:SetHeight(24)
    classCheck:SetPoint("TOPLEFT", 8, -8)
    do
        local text = _G[classCheck:GetName() .. "Text"]
        text:SetText(L["Only my class"])
        text:SetFontObject(GameFontHighlightSmall)
    end
    classCheck:SetScript("OnClick", function(self)
        MyslotSettings.loadoutFilterClass = self:GetChecked() and true or false
        UpdateList()
    end)

    -- sort mode, cycles on click
    local sortButton = CreateFrame("Button", "MyslotProfileListSort", list, "UIPanelButtonTemplate")
    sortButton:SetWidth(120)
    sortButton:SetHeight(20)
    sortButton:SetPoint("TOPRIGHT", -10, -10)
    sortButton:SetScript("OnClick", function()
        local cur = MyslotSettings.loadoutSort or "date"
        for i, mode in ipairs(SORT_MODES) do
            if mode.value == cur then
                MyslotSettings.loadoutSort = SORT_MODES[i % #SORT_MODES + 1].value
                break
            end
        end
        UpdateList()
    end)

    local scroll = CreateFrame("ScrollFrame", "MyslotProfileListScroll", list, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -40)
    scroll:SetPoint("BOTTOMRIGHT", -30, 12)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, UpdateList)
    end)

    local rows = {}
    for i = 1, NUM_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 10, -40 - (i - 1) * ROW_HEIGHT)
        row:SetPoint("RIGHT", list, "RIGHT", -30, 0)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetWidth(16)
        row.icon:SetHeight(16)
        row.icon:SetPoint("LEFT", 2, 0)

        row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        row.text:SetJustifyH("LEFT")
        NoWrap(row.text)

        row:SetScript("OnClick", function(self)
            local d = self.data
            if not d then
                return
            end
            if d.backup then
                SetEditorText(d.backup)
                setSelected(nil)
                setButtonText(L["Before Last Import"])
            elseif d.index then
                selectLoadout(d.index)
            end
            list:Hide()
        end)

        rows[i] = row
    end

    local function classHeaderText(token)
        if not token then
            return OTHER or "Other"
        end
        local name = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]) or token
        return compat.ClassColor(token, name)
    end

    local function buildDisplayRows()
        wipe(displayRows)

        -- newest backup first
        for i = #backups, 1, -1 do
            local b = backups[i]
            local val = type(b) == "table" and b.value or b
            local when = type(b) == "table" and b.time
            local lbl = L["Before Last Import"]
            if i ~= #backups or when then
                lbl = lbl .. " (" .. (when and date("%Y-%m-%d %H:%M", when) or (L["Backup"] .. " " .. (#backups - i + 1))) .. ")"
            end
            displayRows[#displayRows + 1] = { backup = val, text = lbl, icon = "Interface\\Icons\\inv_scroll_04" }
        end

        local sort = MyslotSettings.loadoutSort or "date"
        local filterClass = MyslotSettings.loadoutFilterClass or false
        local myClass = select(2, UnitClass("player"))
        for _, r in ipairs(MySlot:OrderLoadouts(exports, sort, filterClass, myClass)) do
            if r.header ~= nil then
                displayRows[#displayRows + 1] = { header = true, text = classHeaderText(r.header) }
            else
                displayRows[#displayRows + 1] = {
                    index = r.index,
                    text = exports[r.index].name or "?",
                    icon = "Interface\\Icons\\inv_scroll_03",
                }
            end
        end
    end

    UpdateList = function()
        buildDisplayRows()

        classCheck:SetChecked(MyslotSettings.loadoutFilterClass and 1 or nil)
        local cur = MyslotSettings.loadoutSort or "date"
        for _, mode in ipairs(SORT_MODES) do
            if mode.value == cur then
                sortButton:SetText(L["Sort by"] .. ": " .. mode.text)
            end
        end

        -- the list may have shrunk (filter, delete): don't stay scrolled past it
        if #displayRows <= NUM_ROWS or FauxScrollFrame_GetOffset(scroll) > #displayRows - NUM_ROWS then
            scroll.offset = 0
            local bar = _G[scroll:GetName() .. "ScrollBar"]
            if bar then
                bar:SetValue(0)
            end
        end
        FauxScrollFrame_Update(scroll, #displayRows, NUM_ROWS, ROW_HEIGHT)
        local offset = FauxScrollFrame_GetOffset(scroll)

        for i = 1, NUM_ROWS do
            local row = rows[i]
            local d = displayRows[offset + i]
            row.data = d
            if not d then
                row:Hide()
            else
                row:Show()
                if d.header then
                    row.icon:Hide()
                    row.text:SetText(d.text)
                    row.text:SetFontObject(GameFontNormalSmall)
                    row:EnableMouse(false)
                else
                    row.icon:SetTexture(d.icon)
                    row.icon:Show()
                    local txt = d.text
                    if d.index and d.index == selectedIdx then
                        txt = compat.Green(txt)
                    end
                    row.text:SetText(txt)
                    row.text:SetFontObject(GameFontHighlightSmall)
                    row:EnableMouse(true)
                end
            end
        end
    end

    list:SetScript("OnShow", UpdateList)

    profileButton:SetScript("OnClick", function()
        if list:IsShown() then
            list:Hide()
        else
            list:Show()
        end
    end)
    -- }}}

    -- {{{ New / Save / Delete / Rename
    local popctx = {}

    StaticPopupDialogs["MYSLOT_EXPORT_TITLE"].OnShow = function(self)
        local c = popctx.current
        local editBox = compat.PopupEditBox(self)
        editBox:SetText((c and exports[c] and exports[c].name) or "")
        editBox:SetFocus()
    end

    StaticPopupDialogs["MYSLOT_EXPORT_TITLE"].OnAccept = function(self)
        local c = popctx.current
        local editBox = compat.PopupEditBox(self)
        local n = editBox:GetText()
        -- if c then rename
        if c and exports[c] then
            if n ~= "" then
                exports[c].name = n
                if selectedIdx == c then
                    setButtonText(n)
                end
            end
            return
        end

        if n == "" then
            n = date()
        end
        if create(n) then
            selectLoadout(#exports)
        end
    end

    do
        local b = NewButton(f, 70, 25, NEW or "New")
        b:SetPoint("TOPLEFT", profileButton, 280, 0)
        b:SetScript("OnClick", function()
            popctx.current = nil
            StaticPopup_Show("MYSLOT_EXPORT_TITLE")
        end)
    end

    do
        local b = NewButton(f, 70, 25, SAVE or "Save")
        b:SetPoint("TOPLEFT", profileButton, 355, 0)
        b:SetScript("OnClick", function() save(true) end)
    end

    do
        local b = NewButton(f, 70, 25, DELETE or "Delete")
        b:SetPoint("TOPLEFT", profileButton, 430, 0)
        b:SetScript("OnClick", function()
            local c = selectedIdx

            if c and exports[c] then
                StaticPopupDialogs["MYSLOT_CONFIRM_DELETE"].OnAccept = function()
                    table.remove(exports, c)

                    if #exports == 0 then
                        setSelected(nil)
                        SetEditorText("")
                    else
                        selectLoadout(#exports)
                    end
                end
                StaticPopup_Show("MYSLOT_CONFIRM_DELETE", exports[c].name)
            end
        end)
    end

    do
        local b = NewButton(f, 70, 25, L["Rename"])
        b:SetPoint("TOPLEFT", profileButton, 505, 0)
        b:SetScript("OnClick", function()
            local c = selectedIdx

            if c and exports[c] then
                popctx.current = c
                StaticPopup_Show("MYSLOT_EXPORT_TITLE")
            end
        end)
    end
    -- }}}
    -- }}}
end)

-- {{{ Minimap icon
RegEvent("ADDON_LOADED", function()
    local ldb = LibStub("LibDataBroker-1.1")
    local icon = LibStub("LibDBIcon-1.0")

    MyslotSettings = MyslotSettings or {}
    MyslotSettings.minimap = MyslotSettings.minimap or { hide = false }

    icon:Register("Myslot", ldb:NewDataObject("Myslot", {
        type = "launcher",
        icon = "Interface\\MacroFrame\\MacroFrame-Icon",
        OnClick = function()
            compat.SetShown(f, not f:IsShown())
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine(L["Myslot"])
        end,
    }), MyslotSettings.minimap)

    local lib = LibStub:NewLibrary("Myslot-5.0", 1)
    if lib then
        lib.MainFrame = MySlot.MainFrame
    end
end)
-- }}}

SlashCmdList["MYSLOT"] = function()
    compat.SetShown(f, not f:IsShown())
end
SLASH_MYSLOT1 = "/myslot"

-- {{{ Popups
local function AcceptOnEnter(editBox)
    local popup = editBox:GetParent()
    local dialog = StaticPopupDialogs[popup.which]
    if dialog and dialog.OnAccept then
        dialog.OnAccept(popup, popup.data)
    end
    popup:Hide()
end

local function HideOnEscape(editBox)
    editBox:GetParent():Hide()
end

StaticPopupDialogs["MYSLOT_MSGBOX"] = {
    text = L["Are you SURE to import ?"],
    button1 = ACCEPT,
    button2 = CANCEL,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

StaticPopupDialogs["MYSLOT_EXPORT_TITLE"] = {
    text = L["Name of exported text"],
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = 1,
    maxLetters = 64,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    OnAccept = function() end,
    OnShow = function() end,
    EditBoxOnEnterPressed = AcceptOnEnter,
    EditBoxOnEscapePressed = HideOnEscape,
}

StaticPopupDialogs["MYSLOT_CONFIRM_DELETE"] = {
    text = L["Are you SURE to delete '%s'?"],
    button1 = ACCEPT,
    button2 = CANCEL,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

MySlot.PopupAcceptOnEnter = AcceptOnEnter
MySlot.PopupHideOnEscape = HideOnEscape
-- }}}
