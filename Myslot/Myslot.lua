-- Myslot core, backported to WoW 3.3.5a (Interface 30300).
--
-- Export strings use the same format as modern Myslot (protobuf + CRC32 +
-- base64, version 42), so profiles can move between this backport, modern
-- clients and myslot.net. What differs from retail is how 3.3.5 talks to the
-- game:
--   * spells are picked up by spellbook index or "Name(Rank N)", not spell id
--   * mounts and non-combat pets are companions (PickupCompanion)
--   * CreateMacro wants an icon index, macros are 36 account + 18 character
--   * there are 120 action slots and no flyouts, outfits or click bindings

local _, MySlot = ...

local L = MySlot.L
local compat = MySlot.compat

local crc32 = MySlot.crc32
local base64 = MySlot.base64

local pblua = MySlot.luapb
local _MySlot = pblua.load_proto_ast(MySlot.ast)

local MYSLOT_AUTHOR = "Boshi Lian <farmer1992@gmail.com>"

local MYSLOT_VER = 42

-- 3.3.5 macro layout: ids 1-36 are account macros, 37-54 character macros.
local MAX_ACCOUNT_MACROS = 36
local MAX_CHARACTER_MACROS = 18
-- Modern clients (retail, every Classic flavor) use 120 account macros.
local MODERN_ACCOUNT_MACROS = 120
-- 3.3.5 rejects longer macro bodies.
local MAX_MACRO_BODY = 255

local MYSLOT_LINE_SEP = "\n"
local MYSLOT_MAX_ACTIONBAR = 120

MySlot.MAX_ACTIONBAR = MYSLOT_MAX_ACTIONBAR

local BOOKTYPE_SPELL = BOOKTYPE_SPELL or "spell"
local BOOKTYPE_PET = BOOKTYPE_PET or "pet"
local NUM_PET_ACTION_SLOTS = NUM_PET_ACTION_SLOTS or 10

-- {{{ SLOT TYPE
local SlotType = _MySlot.Slot.SlotType
local MYSLOT_SPELL = SlotType.SPELL
local MYSLOT_COMPANION = SlotType.COMPANION
local MYSLOT_ITEM = SlotType.ITEM
local MYSLOT_MACRO = SlotType.MACRO
local MYSLOT_FLYOUT = SlotType.FLYOUT
local MYSLOT_EQUIPMENTSET = SlotType.EQUIPMENTSET
local MYSLOT_EMPTY = SlotType.EMPTY
local MYSLOT_SUMMONPET = SlotType.SUMMONPET
local MYSLOT_SUMMONMOUNT = SlotType.SUMMONMOUNT
local MYSLOT_OUTFIT = SlotType.OUTFIT

-- GetActionInfo types on 3.3.5
MySlot.SLOT_TYPE = {
    ["spell"] = MYSLOT_SPELL,
    ["companion"] = MYSLOT_COMPANION,
    ["macro"] = MYSLOT_MACRO,
    ["item"] = MYSLOT_ITEM,
    ["equipmentset"] = MYSLOT_EQUIPMENTSET,
}

-- A parsed message holds enum names ("SPELL"), a new one holds the numbers.
-- Normalize to the number so the two compare equal.
local function NormType(t)
    if type(t) == "number" then
        return t
    end
    return t and SlotType[t] or nil
end
-- }}}

local MYSLOT_BIND_CUSTOM_FLAG = 0xFFFF

-- Yield back to the game while running inside MySlot:RunAsync, so a large
-- import is spread over several frames. A no-op on the main thread.
local function MaybeYield(progress)
    local co, isMain = coroutine.running()
    if co and not isMain then
        coroutine.yield(progress)
    end
end

-- Run fn() in a coroutine, one slice per frame. Values yielded by fn (a 0..1
-- progress fraction) go to onProgress; onDone(ok) is called at the end.
-- Waits while the player is in combat: action bars can't be changed then.
function MySlot:RunAsync(fn, onProgress, onDone)
    local co = coroutine.create(fn)
    local function step()
        if InCombatLockdown() then
            if onProgress then onProgress(nil, true) end
            compat.After(0.5, step)
            return
        end

        local ok, progress = coroutine.resume(co)
        if not ok then
            geterrorhandler()(progress)
            if onDone then onDone(false) end
            return
        end
        if coroutine.status(co) == "dead" then
            if onProgress then onProgress(1) end
            if onDone then onDone(true) end
            return
        end
        if onProgress and type(progress) == "number" then
            onProgress(progress)
        end
        compat.After(0, step)
    end
    step()
end

-- {{{ Byte table helpers
-- return item count merge into target
local function MergeTable(target, source)
    if source then
        assert(type(target) == 'table' and type(source) == 'table')
        for _, b in ipairs(source) do
            assert(b < 256)
            target[#target + 1] = b
        end
        return #source
    else
        return 0
    end
end

-- fix unpack stackoverflow
local function StringToTable(s)
    if type(s) ~= 'string' then
        return {}
    end
    local r = {}
    for i = 1, string.len(s) do
        r[#r + 1] = string.byte(s, i)
    end
    return r
end

local function TableToString(s)
    if type(s) ~= 'table' then
        return ''
    end
    local t = {}
    for _, c in pairs(s) do
        t[#t + 1] = string.char(c)
    end
    return table.concat(t)
end
-- }}}

function MySlot:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|CFFFF0000<|r|CFFFFD100Myslot|r|CFFFF0000>|r" .. (msg or "nil"))
end

local function SpellLink(spellId)
    local ok, link = pcall(GetSpellLink, spellId)
    return ok and link or ""
end

-- {{{ Spellbook / companion lookups
-- byId: spell id -> spellbook index; byName: spell name -> spellbook index of
-- its highest listed rank (ranks are listed lowest first).
local function BuildSpellBook(bookType)
    local book = { byId = {}, byName = {}, byNameRank = {} }

    local function add(i)
        local name, rank = GetSpellName(i, bookType)
        if not name then
            return
        end
        local id = compat.SpellIdFromLink(GetSpellLink(i, bookType))
        if id then
            book.byId[id] = i
        end
        book.byName[name] = i
        book.byNameRank[name .. "|" .. (rank or "")] = i
    end

    if bookType == BOOKTYPE_PET then
        local num = HasPetSpells()
        for i = 1, (num or 0) do
            add(i)
        end
    else
        for tab = 1, GetNumSpellTabs() do
            local _, _, offset, numSpells = GetSpellTabInfo(tab)
            for i = offset + 1, offset + numSpells do
                add(i)
            end
        end
    end

    return book
end

-- spell id -> { companionType, index }
local function BuildCompanionMap()
    local map = {}
    for _, ctype in ipairs({ "CRITTER", "MOUNT" }) do
        for i = 1, GetNumCompanions(ctype) do
            local _, _, spellId = GetCompanionInfo(ctype, i)
            if spellId then
                map[spellId] = { ctype, i }
            end
        end
    end
    return map
end

local function PickupCompanionBySpell(companions, spellId)
    local c = companions[spellId]
    if c then
        PickupCompanion(c[1], c[2])
    end
    return GetCursorInfo() ~= nil
end

-- Pick up a player spell by id. The exact rank is tried first; when that
-- rank isn't known the highest known rank of the same spell is used. Returns
-- "exact", "rank" (another rank was used) or nil.
local function PickupSpellById(book, spellId)
    local idx = book.byId[spellId]
    if idx then
        PickupSpell(idx, BOOKTYPE_SPELL)
        if GetCursorInfo() then
            return "exact"
        end
    end

    local name, rank = GetSpellInfo(spellId)
    if not name then
        return nil
    end

    -- The spellbook only lists every rank when "Show all spell ranks" is on,
    -- but picking up by "Name(Rank N)" works either way.
    if rank and rank ~= "" then
        PickupSpell(name .. "(" .. rank .. ")")
        if GetCursorInfo() then
            return "exact"
        end
    end

    idx = book.byName[name]
    if idx then
        PickupSpell(idx, BOOKTYPE_SPELL)
    else
        PickupSpell(name)
    end
    if GetCursorInfo() then
        -- Only count it as a rank swap when the spell has numbered ranks.
        return (rank and rank:find("%d")) and "rank" or "exact"
    end

    return nil
end
-- }}}

-- {{{ Macro icons
-- 3.3.5's CreateMacro takes an index into the macro icon list, not a name.
local macroIconIndex

local function IconKey(texture)
    return (gsub(strupper(texture or ""), "^INTERFACE\\ICONS\\", ""))
end

local function GetMacroIconIndex(icon)
    if not macroIconIndex then
        macroIconIndex = {}
        for i = 1, (GetNumMacroIcons() or 0) do
            local tex = GetMacroIconInfo(i)
            if tex then
                local key = IconKey(tex)
                if not macroIconIndex[key] then
                    macroIconIndex[key] = i
                end
            end
        end
    end
    return macroIconIndex[IconKey(icon)] or macroIconIndex["INV_MISC_QUESTIONMARK"] or 1
end
-- }}}

-- {{{ GetMacroInfo
function MySlot:GetMacroInfo(macroId)
    local name, iconTexture, body = GetMacroInfo(macroId)

    if not name then
        return nil
    end

    local msg = _MySlot.Macro()
    msg.id = macroId
    msg.icon = IconKey(iconTexture or "INV_Misc_QuestionMark")
    msg.name = name
    msg.body = body or ""

    return msg
end
-- }}}

-- {{{ Action slots
-- Reads one action slot as (type, index, strindex) in Myslot terms, or nil
-- when it's empty or holds something Myslot can't store.
--   spell        index = spell id (rank specific)
--   companion    index = summon spell id, strindex = "MOUNT" / "CRITTER"
--   item         index = item id
--   macro        index = macro id
--   equipmentset strindex = set name
local function ReadSlot(slotId, quiet)
    local slotType, id, subType, spellId = GetActionInfo(slotId)
    if not slotType then
        return nil
    end

    local stype = MySlot.SLOT_TYPE[slotType]
    if not stype then
        if not quiet then
            MySlot:Print(L["[WARN] Ignore unsupported Slot Type [ %s ] , contact %s please"]:format(slotType, MYSLOT_AUTHOR))
        end
        return nil
    end

    local index, strindex
    if slotType == "spell" then
        index = spellId
        if not index and id then
            local bookType = (subType and subType ~= "") and subType or BOOKTYPE_SPELL
            index = compat.SpellIdFromLink(GetSpellLink(id, bookType))
        end
    elseif slotType == "companion" then
        index = spellId
        if not index and id and subType then
            local _, _, sid = GetCompanionInfo(subType, id)
            index = sid
        end
        strindex = subType
    elseif slotType == "equipmentset" then
        index = 0
        strindex = id
    else
        index = id
    end

    if type(index) ~= "number" then
        return nil
    end

    return stype, index, strindex
end

function MySlot:GetActionInfo(slotId)
    local stype, index, strindex = ReadSlot(slotId)
    if not stype then
        return nil
    end

    local msg = _MySlot.Slot()
    msg.id = slotId
    msg.type = stype
    msg.index = index
    if strindex then
        msg.strindex = strindex
    end
    return msg
end
-- }}}

-- {{{ Pet action bar
local PET_CAPABLE_CLASSES = {
    HUNTER = true,
    WARLOCK = true,
    DEATHKNIGHT = true,
    MAGE = true, -- Water Elemental
}

function MySlot:IsPetActionBarSupported()
    local _, class = UnitClass("player")
    return class ~= nil and PET_CAPABLE_CLASSES[class] or false
end

local function HasPetBar()
    return (PetHasActionBar and PetHasActionBar()) and true or false
end

-- 3.3.5's GetPetActionInfo has no spell id, so look the spell up in the pet
-- spellbook by name and rank.
function MySlot:GetPetActionInfo(slotId, petBook)
    local name, subtext, _, isToken = GetPetActionInfo(slotId)

    local msg = _MySlot.Slot()
    msg.id = slotId
    msg.type = MYSLOT_SPELL

    if not name then
        msg.index = 0
        msg.type = MYSLOT_EMPTY
    elseif isToken then
        msg.strindex = name
        msg.index = 0
    else
        local idx = petBook.byNameRank[name .. "|" .. (subtext or "")] or petBook.byName[name]
        local spellId = idx and compat.SpellIdFromLink(GetSpellLink(idx, BOOKTYPE_PET))
        if not spellId then
            return nil
        end
        msg.index = spellId
    end

    return msg
end
-- }}}

-- {{{ GetBindingInfo
local function KeyToByte(key)
    -- {mod , key , command high 8, command low 8}
    if not key then
        return nil
    end

    local mod = nil
    local _, _, _mod, _key = string.find(key, "(.+)-(.+)")
    if _mod and _key then
        mod, key = _mod, _key
    end

    mod = mod or "NONE"

    if not MySlot.MOD_KEYS[mod] then
        MySlot:Print(L["[WARN] Ignore unsupported Key Binding [ %s ] , contact %s please"]:format(mod, MYSLOT_AUTHOR))
        return nil
    end

    local msg = _MySlot.Key()
    if MySlot.KEYS[key] then
        msg.key = MySlot.KEYS[key]
    else
        msg.key = MySlot.KEYS["KEYCODE"]
        msg.keycode = key
    end
    msg.mod = MySlot.MOD_KEYS[mod]

    return msg
end

function MySlot:GetBindingInfo(index)
    -- 3.3.5: command, key1, key2 (no category)
    local _command, key1, key2 = GetBinding(index)

    if not _command then
        return
    end

    local command = MySlot.BINDS[_command]

    local msg = _MySlot.Bind()

    if not command then
        msg.command = _command
        command = MYSLOT_BIND_CUSTOM_FLAG
    end

    msg.id = command

    msg.key1 = KeyToByte(key1)
    msg.key2 = KeyToByte(key2)

    if msg.key1 or msg.key2 then
        return msg
    else
        return nil
    end
end
-- }}}

-- {{{ Talents
-- Points spent per tree of the active spec, e.g. "0/53/18".
function MySlot:GetTalentString()
    if not GetTalentTabInfo then
        return nil
    end

    local numTabs = GetNumTalentTabs and GetNumTalentTabs() or 3
    if numTabs == 0 then
        return nil
    end

    local points = {}
    for tab = 1, numTabs do
        local _, _, spent = GetTalentTabInfo(tab)
        points[#points + 1] = tonumber(spent) or 0
    end
    return table.concat(points, "/")
end

-- The "x/y/z" talent spread from a profile's header, or nil. The header label
-- is localized, so look for any header value shaped like a spread.
function MySlot:ParseTalentString(text)
    if type(text) ~= "string" then
        return nil
    end

    for line in text:gmatch("[^\r\n]+") do
        local first = line:sub(1, 1)
        if first == "#" then
            local value = line:match("^#[^:]*:%s*(%d+/%d+/%d+)%s*$")
            if value then
                return value
            end
        elseif first ~= "@" and strtrim(line) ~= "" then
            -- headers all sit above the base64 payload
            break
        end
    end

    return nil
end
-- }}}

function MySlot:Export(opt)
    -- ver nop nop nop crc32 crc32 crc32 crc32

    local msg = _MySlot.Charactor()

    msg.ver = MYSLOT_VER
    msg.name = UnitName("player")

    msg.macro = {}

    if not opt.ignoreMacros["ACCOUNT"] then
        for i = 1, MAX_ACCOUNT_MACROS do
            local m = self:GetMacroInfo(i)
            if m then
                msg.macro[#msg.macro + 1] = m
            end
        end
    end

    if not opt.ignoreMacros["CHARACTOR"] then
        for i = MAX_ACCOUNT_MACROS + 1, MAX_ACCOUNT_MACROS + MAX_CHARACTER_MACROS do
            local m = self:GetMacroInfo(i)
            if m then
                msg.macro[#msg.macro + 1] = m
            end
        end
    end

    msg.slot = {}
    for i = 1, MYSLOT_MAX_ACTIONBAR do
        if not opt.ignoreActionBars[math.ceil(i / 12)] then
            local m = self:GetActionInfo(i)
            if m then
                msg.slot[#msg.slot + 1] = m
            end
        end
    end

    msg.bind = {}
    if not opt.ignoreBinding then
        for i = 1, GetNumBindings() do
            local m = self:GetBindingInfo(i)
            if m then
                msg.bind[#msg.bind + 1] = m
            end
        end
    end

    msg.petslot = {}
    if not opt.ignorePetActionBar and HasPetBar() then
        local petBook = BuildSpellBook(BOOKTYPE_PET)
        for i = 1, NUM_PET_ACTION_SLOTS do
            local m = self:GetPetActionInfo(i, petBook)
            if m then
                msg.petslot[#msg.petslot + 1] = m
            end
        end
    end

    msg.clickBinding = {}

    local ct = msg:Serialize()
    local t = { MYSLOT_VER, 86, 04, 22, 0, 0, 0, 0 }
    MergeTable(t, StringToTable(ct))

    -- {{{ CRC32
    local crc = crc32.enc(t)
    t[5] = bit.rshift(crc, 24)
    t[6] = bit.band(bit.rshift(crc, 16), 255)
    t[7] = bit.band(bit.rshift(crc, 8), 255)
    t[8] = bit.band(crc, 255)
    -- }}}

    -- {{{ OUTPUT
    local talent = MySlot:GetTalentString()

    local s = ""
    s = "# --------------------" .. MYSLOT_LINE_SEP .. s
    s = "# " .. L["Feedback"] .. "  farmer1992@gmail.com" .. MYSLOT_LINE_SEP .. s
    s = "# " .. MYSLOT_LINE_SEP .. s
    s = "# " .. (LEVEL or "Level") .. ": " .. UnitLevel("player") .. MYSLOT_LINE_SEP .. s
    if talent then
        s = "# " .. (TALENTS or "Talents") .. ": " .. talent .. MYSLOT_LINE_SEP .. s
    end
    s = "# " .. (CLASS or "Class") .. ": " .. UnitClass("player") .. MYSLOT_LINE_SEP .. s
    s = "# " .. (PLAYER or "Player") .. ": " .. UnitName("player") .. MYSLOT_LINE_SEP .. s
    s = "# " .. L["Time"] .. ": " .. date() .. MYSLOT_LINE_SEP .. s
    s = "# Addon Version: " .. (GetAddOnMetadata("Myslot", "Version") or "?") .. MYSLOT_LINE_SEP .. s
    s = "# Wow Version: " .. GetBuildInfo() .. MYSLOT_LINE_SEP .. s
    s = "# Myslot (https://myslot.net " .. L["<- share your profile here"] .. ")" .. MYSLOT_LINE_SEP .. s

    local d = base64.enc(t)
    local LINE_LEN = 60
    for i = 1, d:len(), LINE_LEN do
        s = s .. d:sub(i, i + LINE_LEN - 1) .. MYSLOT_LINE_SEP
    end
    s = strtrim(s)
    s = s .. MYSLOT_LINE_SEP .. "# --------------------"
    s = s .. MYSLOT_LINE_SEP .. "# END OF MYSLOT"

    return s
    -- }}}
end

local function IsEmptyTable(t)
    return (t == nil) or (next(t) == nil)
end

-- Strip comments, base64-decode and verify the CRC32 of an export string.
-- Returns the decoded byte table (CRC bytes zeroed) and whether the CRC
-- matched, or nil when the text is too short to be a Myslot export.
local function DecodeImportText(text)
    local s = text or ""
    s = string.gsub(s, "(@.[^\n]*\n*)", "")
    s = string.gsub(s, "(#.[^\n]*\n*)", "")
    s = string.gsub(s, "\n", "")
    s = string.gsub(s, "\r", "")
    s = base64.dec(s)

    if #s < 8 then
        return nil
    end

    local crc = s[5] * 2 ^ 24 + s[6] * 2 ^ 16 + s[7] * 2 ^ 8 + s[8]
    s[5], s[6], s[7], s[8] = 0, 0, 0, 0

    return s, crc == crc32.enc(s) % 2 ^ 32
end

-- True when text is a well-formed Myslot export (decodes and passes CRC32).
function MySlot:IsValidExportText(text)
    local s, crcOk = DecodeImportText(text)
    return s ~= nil and crcOk
end

-- Where the exporting client split account and character macros. A profile
-- from 3.3.x numbers character macros from 37, every modern client from 121.
local function SourceAccountMacroMax(text, msg)
    local ver = type(text) == "string" and text:match("#%s*Wow Version:%s*([%d%.]+)")
    if ver then
        return ver:match("^3%.3%.") and MAX_ACCOUNT_MACROS or MODERN_ACCOUNT_MACROS
    end

    -- No header: ids above 54 can only come from a modern client.
    for _, m in pairs(msg.macro or {}) do
        if m.id > MAX_ACCOUNT_MACROS + MAX_CHARACTER_MACROS then
            return MODERN_ACCOUNT_MACROS
        end
    end
    return MAX_ACCOUNT_MACROS
end

-- Decodes an export string. Returns the parsed message plus a table of
-- extra facts about it ({ accountMax = n }) for RecoverData, or nil.
function MySlot:Import(text, opt)
    if InCombatLockdown() then
        MySlot:Print(L["Import is not allowed when you are in combat"])
        return
    end

    local s, crcOk = DecodeImportText(text)

    if not s then
        MySlot:Print(L["Bad importing text [TEXT]"])
        return
    end

    local force = opt.force

    if not crcOk then
        MySlot:Print(L["Bad importing text [CRC32]"])
        if force then
            MySlot:Print(L["Skip bad CRC32"] .. " " .. L["Try force importing"])
        else
            return
        end
    end

    local ct = {}
    for i = 9, #s do
        ct[#ct + 1] = s[i]
    end
    ct = TableToString(ct)

    local ok, msg = pcall(function()
        return _MySlot.Charactor():Parse(ct)
    end)
    if not ok or not msg then
        MySlot:Print(L["Bad importing text [TEXT]"])
        return
    end

    if IsEmptyTable(msg.slot) and IsEmptyTable(msg.bind) and IsEmptyTable(msg.macro) and not force then
        MySlot:Print(L["Nothing to import"])
        return
    end

    return msg, { accountMax = SourceAccountMacroMax(text, msg) }
end

-- {{{ Macros
local function UnifyCRLF(text)
    text = string.gsub(text or "", "\r", "")
    return strtrim(text)
end

-- Fill `localMacro` with this character's macros keyed by "name_body" and
-- "body". 3.3.5 keeps macros sorted by name, so every CreateMacro can shift
-- the ids of others: refill after each one.
function MySlot:BuildMacroIndex(localMacro)
    localMacro = localMacro or {}
    for k in pairs(localMacro) do
        localMacro[k] = nil
    end
    for i = 1, MAX_ACCOUNT_MACROS + MAX_CHARACTER_MACROS do
        local name, _, body = GetMacroInfo(i)
        if name then
            body = UnifyCRLF(body)
            localMacro[name .. "_" .. body] = i
            localMacro[body] = i
        end
    end
    return localMacro
end

function MySlot:FindMacro(macroInfo, localMacro)
    if not macroInfo then
        return
    end

    localMacro = localMacro or MySlot:BuildMacroIndex()

    local body = UnifyCRLF(macroInfo["body"])
    return localMacro[macroInfo["name"] .. "_" .. body] or localMacro[body]
end

-- CreateMacro's arguments changed over time; on 3.3.5 it is
-- (name, iconIndex, body, local, perCharacter). Should this client take the
-- per-character flag in 4th place instead, the result lands in the wrong
-- half, so check and retry once.
local function CreateMacroCompat(name, iconIndex, body, perChar)
    local ok, newid = pcall(CreateMacro, name, iconIndex, body, nil, perChar and 1 or nil)
    if not ok then
        return nil
    end
    if newid and perChar and newid <= MAX_ACCOUNT_MACROS then
        DeleteMacro(newid)
        ok, newid = pcall(CreateMacro, name, iconIndex, body, 1)
        if not ok then
            return nil
        end
    end
    return newid
end

function MySlot:FindOrCreateMacro(macroInfo, localMacro, accountMax)
    if not macroInfo then
        return
    end

    localMacro = localMacro or MySlot:BuildMacroIndex()

    local localIndex = MySlot:FindMacro(macroInfo, localMacro)
    if localIndex then
        return localIndex
    end

    local id = macroInfo["oldid"]
    local name = macroInfo["name"]
    local icon = macroInfo["icon"]
    local body = UnifyCRLF(macroInfo["body"])

    if #body > MAX_MACRO_BODY then
        self:Print(L["Macro %s was ignored, check if there is enough space to create"]:format(name)
            .. " (" .. #body .. "/" .. MAX_MACRO_BODY .. ")")
        return nil
    end

    local numglobal, numperchar = GetNumMacros()
    local perchar = id > (accountMax or MAX_ACCOUNT_MACROS) and 2 or 1

    --[[
        perchar    G = 01 P = 10
        testallow  allow 01 | allow 10 = 00 , 01 , 10 , 11
        perchar & testallow = 01 , 10 , 00
        perchar = testallow when not allow
    ]]
    local testallow = bit.bor(numglobal < MAX_ACCOUNT_MACROS and 1 or 0, numperchar < MAX_CHARACTER_MACROS and 2 or 0)
    perchar = bit.band(perchar, testallow)
    perchar = perchar == 0 and testallow or perchar
    -- both halves have room and neither was asked for: keep account
    if perchar == 3 then
        perchar = 1
    end

    if perchar ~= 0 then
        -- #showtooltip macros take the icon of what they cast
        if strsub(body, 1, 12) == '#showtooltip' then
            icon = 'INV_Misc_QuestionMark'
        end
        local newid = CreateMacroCompat(name, GetMacroIconIndex(icon), body, perchar >= 2)
        if newid then
            MySlot:BuildMacroIndex(localMacro)
            return MySlot:FindMacro(macroInfo, localMacro) or newid
        end
    end

    self:Print(L["Macro %s was ignored, check if there is enough space to create"]:format(name))
    return nil
end
-- }}}

-- Builds the display order for the saved-loadout list. Pure helper.
--
--   exports     array of { name, value, class? } loadout entries (storage order)
--   sort        "date" (newest first, default), "name" (A-Z), or
--               "class" (grouped by class token, then name)
--   filterClass when true, hide entries whose class differs from myClass; entries
--               with no stored class (legacy) are always shown
--   myClass     the english class token to filter against (e.g. "DRUID")
--
-- Returns an array of rows preserving the ORIGINAL exports index as identity:
--   { index = i }      a loadout entry (exports[i])
--   { header = token } a class group header (only in "class" sort); token is the
--                      class token, or false for the legacy/unknown group
function MySlot:OrderLoadouts(exports, sort, filterClass, myClass)
    sort = sort or "date"

    local order = {}
    for i = 1, #exports do
        local e = exports[i]
        if e and not (filterClass and e.class and e.class ~= myClass) then
            order[#order + 1] = i
        end
    end

    local function byName(a, b)
        local na, nb = (exports[a].name or ""):lower(), (exports[b].name or ""):lower()
        if na == nb then
            return a < b
        end
        return na < nb
    end

    if sort == "name" then
        table.sort(order, byName)
    elseif sort == "class" then
        table.sort(order, function(a, b)
            local ca, cb = exports[a].class, exports[b].class
            if ca ~= cb then
                if not ca then return false end
                if not cb then return true end
                return ca < cb
            end
            return byName(a, b)
        end)
    else
        -- "date": newest first (entries are appended on create)
        for i = 1, math.floor(#order / 2) do
            order[i], order[#order - i + 1] = order[#order - i + 1], order[i]
        end
    end

    local rows = {}
    local lastClass, haveLast = nil, false
    for _, i in ipairs(order) do
        if sort == "class" then
            local c = exports[i].class or false
            if not haveLast or c ~= lastClass then
                lastClass, haveLast = c, true
                rows[#rows + 1] = { header = c }
            end
        end
        rows[#rows + 1] = { index = i }
    end
    return rows
end

local function ClearSlot(slotId)
    if GetActionInfo(slotId) then
        PickupAction(slotId)
        ClearCursor()
    end
end

-- Puts whatever the profile has in one action slot. Returns false when it
-- can't (unlearned spell, missing item, ...), after printing why; the caller
-- then empties the slot.
local function RestoreSlot(slotId, slotType, index, strindex, ctx)
    if slotType == MYSLOT_SPELL then
        local got = PickupSpellById(ctx.spellbook, index)
        if not got and PickupCompanionBySpell(ctx.companions, index) then
            got = "exact"
        end
        if got == "rank" then
            ctx.rankSwaps = ctx.rankSwaps + 1
        end
        if not got then
            MySlot:Print(L["Ignore unlearned skill [id=%s], %s"]:format(index, SpellLink(index)))
            return false
        end
    elseif slotType == MYSLOT_COMPANION then
        if not PickupCompanionBySpell(ctx.companions, index) then
            -- maybe it is a plain spell on this character
            PickupSpellById(ctx.spellbook, index)
        end
        if not GetCursorInfo() then
            MySlot:Print(L["Ignore unattained companion [id=%s], %s"]:format(index, SpellLink(index)))
            return false
        end
    elseif slotType == MYSLOT_ITEM then
        PickupItem(index)
        if not GetCursorInfo() then
            MySlot:Print(L["Ignore missing item [id=%s]"]:format(index))
            return false
        end
    elseif slotType == MYSLOT_EQUIPMENTSET then
        if strindex and strindex ~= "" then
            PickupEquipmentSetByName(strindex)
        end
        if not GetCursorInfo() then
            MySlot:Print(L["Ignore missing item [id=%s]"]:format(strindex or index))
            return false
        end
    elseif slotType == MYSLOT_EMPTY then
        PickupAction(slotId)
        ClearCursor()
        return true
    elseif slotType == MYSLOT_SUMMONMOUNT or slotType == MYSLOT_SUMMONPET
        or slotType == MYSLOT_FLYOUT or slotType == MYSLOT_OUTFIT then
        -- Retail-only slot types: their ids mean nothing on 3.3.5.
        ctx.unsupported = ctx.unsupported + 1
        return false
    else
        return false
    end

    PlaceAction(slotId)
    ClearCursor()
    return true
end

function MySlot:RecoverData(msg, opt)
    local meta = opt.meta or {}
    local accountMax = meta.accountMax or MAX_ACCOUNT_MACROS
    local actionOpt = opt.actionOpt

    ClearCursor()

    local ctx = {
        spellbook = BuildSpellBook(BOOKTYPE_SPELL),
        companions = BuildCompanionMap(),
        rankSwaps = 0,
        unsupported = 0,
    }

    local slotBucket = {}
    local outOfRange = 0

    local numMacro = msg.macro and #msg.macro or 0
    local numSlot = msg.slot and #msg.slot or 0
    local totalWork = numMacro + numSlot + MYSLOT_MAX_ACTIONBAR
    local function pct(done)
        if totalWork <= 0 then return nil end
        return done / totalWork
    end

    local function barIgnored(slotId)
        return actionOpt.ignoreActionBars[math.ceil(slotId / 12)]
    end

    -- {{{ Macro
    local macro = {}
    for _, s in pairs(msg.slot or {}) do
        if NormType(s.type) == MYSLOT_MACRO then
            macro[s.index] = macro[s.index] or {}
            table.insert(macro[s.index], s.id)
        end
    end

    local localMacro = MySlot:BuildMacroIndex()

    local macroProcessed = 0
    for _, m in pairs(msg.macro or {}) do
        local macroId = m.id

        local info = {
            ["oldid"] = macroId,
            ["name"] = m.name,
            ["icon"] = m.icon,
            ["body"] = m.body,
        }

        local newid = nil
        local isChar = macroId > accountMax

        if (not actionOpt.ignoreMacros["ACCOUNT"] and not isChar)
            or (not actionOpt.ignoreMacros["CHARACTOR"] and isChar) then
            newid = self:FindOrCreateMacro(info, localMacro, accountMax)
        end

        if not newid then
            newid = self:FindMacro(info, localMacro)
        end

        if newid then
            for _, slotId in pairs(macro[macroId] or {}) do
                if slotId <= MYSLOT_MAX_ACTIONBAR and not barIgnored(slotId) then
                    ClearCursor()
                    PickupMacro(newid)
                    PlaceAction(slotId)
                    ClearCursor()
                end
            end
        else
            MySlot:Print(L["Ignore unknown macro [id=%s]"]:format(macroId))
        end

        macroProcessed = macroProcessed + 1
        MaybeYield(pct(macroProcessed))
    end
    -- }}} Macro

    local slotProcessed = 0
    for _, s in pairs(msg.slot or {}) do
        local slotId = s.id
        local slotType = NormType(s.type)
        local index = s.index
        local strindex = s.strindex

        if slotId > MYSLOT_MAX_ACTIONBAR then
            -- retail-only bars (slots 121-180)
            outOfRange = outOfRange + 1
        else
            slotBucket[slotId] = true

            if slotType ~= MYSLOT_MACRO and not barIgnored(slotId) then
                local ok = pcall(function()
                    local curType, curIndex, curStr = ReadSlot(slotId, true)
                    if curType == slotType and curIndex == index
                        and (curStr or "") == (strindex or "") then
                        return
                    end

                    ClearCursor()
                    if not RestoreSlot(slotId, slotType, index, strindex, ctx) then
                        ClearCursor()
                        ClearSlot(slotId)
                    end
                end)
                ClearCursor()

                if not ok then
                    MySlot:Print(L["[WARN] Ignore slot due to an unknown error DEBUG INFO = [S=%s T=%s I=%s] Please send Importing Text and DEBUG INFO to %s"]:format(slotId, tostring(slotType), tostring(index), MYSLOT_AUTHOR))
                end
            end
        end

        slotProcessed = slotProcessed + 1
        if slotProcessed % 12 == 0 then
            MaybeYield(pct(numMacro + slotProcessed))
        end
    end

    -- empty every slot the profile leaves empty
    for i = 1, MYSLOT_MAX_ACTIONBAR do
        if not barIgnored(i) and not slotBucket[i] then
            ClearSlot(i)
        end

        if i % 12 == 0 then
            MaybeYield(pct(numMacro + numSlot + i))
        end
    end

    if not actionOpt.ignoreBinding then
        local function bindKey(k, command)
            local mod, key = MySlot.R_MOD_KEYS[k.mod], MySlot.R_KEYS[k.key]
            if key == "KEYCODE" then
                key = k.keycode
            end
            if not (mod and key and command) then
                return
            end
            key = (mod ~= "NONE" and (mod .. "-") or "") .. key
            pcall(SetBinding, key, command)
        end

        for _, b in pairs(msg.bind or {}) do
            local command = b.command
            if b.id ~= MYSLOT_BIND_CUSTOM_FLAG then
                command = MySlot.R_BINDS[b.id]
            end

            if b.key1 then
                bindKey(b.key1, command)
            end
            if b.key2 then
                bindKey(b.key2, command)
            end
        end
        SaveBindings(GetCurrentBindingSet())
    end

    if not actionOpt.ignorePetActionBar and HasPetBar() and not IsEmptyTable(msg.petslot) then
        local petBook = BuildSpellBook(BOOKTYPE_PET)

        local pettoken = {}
        for i = 1, NUM_PET_ACTION_SLOTS do
            local name, _, _, isToken = GetPetActionInfo(i)
            if isToken then
                pettoken[name] = i
            end
        end

        for _, p in pairs(msg.petslot or {}) do
            ClearCursor()
            if NormType(p.type) == MYSLOT_EMPTY then
                PickupPetAction(p.id)
            elseif p.strindex and p.strindex ~= "" then
                local slot = pettoken[p.strindex]
                if slot and slot ~= p.id then
                    PickupPetAction(slot)
                    PickupPetAction(p.id)
                end
            elseif p.index and p.index ~= 0 then
                local idx = petBook.byId[p.index]
                if not idx then
                    local name = GetSpellInfo(p.index)
                    idx = name and petBook.byName[name]
                end
                if idx then
                    PickupSpell(idx, BOOKTYPE_PET)
                    PickupPetAction(p.id)
                end
            end
            ClearCursor()
        end
    end

    if ctx.rankSwaps > 0 then
        MySlot:Print(L["Used the highest known rank for %d spell(s) whose exact rank you don't know"]:format(ctx.rankSwaps))
    end
    if ctx.unsupported > 0 or outOfRange > 0 then
        MySlot:Print(L["Skipped %d slot(s) that only exist on newer game versions"]:format(ctx.unsupported + outOfRange))
    end

    MySlot:Print(L["All slots were restored"])
end

function MySlot:Clear(what, opt)
    if what == "ACTION" then
        for i = 1, MYSLOT_MAX_ACTIONBAR do
            if opt[math.ceil(i / 12)] then
                PickupAction(i)
                ClearCursor()
            end
        end
    elseif what == "MACRO" then
        if opt["ACCOUNT"] then
            for i = MAX_ACCOUNT_MACROS, 1, -1 do
                if GetMacroInfo(i) then
                    DeleteMacro(i)
                end
            end
        end

        if opt["CHARACTOR"] then
            for i = MAX_ACCOUNT_MACROS + MAX_CHARACTER_MACROS, MAX_ACCOUNT_MACROS + 1, -1 do
                if GetMacroInfo(i) then
                    DeleteMacro(i)
                end
            end
        end
    elseif what == "BINDING" then
        for i = 1, GetNumBindings() do
            local _, key1, key2 = GetBinding(i)
            for _, key in pairs({ key1, key2 }) do
                if key then
                    SetBinding(key)
                end
            end
        end
        SaveBindings(GetCurrentBindingSet())
    end
end
