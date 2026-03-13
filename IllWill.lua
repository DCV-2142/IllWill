-- IllWill.lua (Turtle WoW / Vanilla 1.12)
-- Raid/Party/Player Death Wish tracker for Warriors:
--  READY (green), ACTIVE (yellow + timer), COOLDOWN (red timer), plus usage count.
--
-- Commands:
--   /iw            (toggle window)
--   /iw show|hide
--   /iw lock|unlock
--   /iw reset
--   /iw debug
--   /iw assume ready|unknown
--   /iw sort status|name
--   /iw offline on|off
--   /iw scale <0.6-2.0>
--   /iw probe      (prints what YOUR client sees for Death Wish detection on player)

IllWill = IllWill or {}
local IW = IllWill

-- forward declarations for functions used before definition
local UI_Build

local ADDON_NAME = "IllWill"
local VERSION    = "1.0"

-- Timings (per your description)
local DW_ACTIVE   = 30     -- seconds
local DW_COOLDOWN = 180    -- seconds

-- How often we scan
local SCAN_INTERVAL          = 0.25
local ROSTER_REBUILD_SECONDS = 2.5

-- Default detection:
-- - Prefer matching aura NAME containing "death wish"
-- - Fallback to icon/texture substring matches (helps if tooltip name funcs are missing)
local DEFAULT_DW_NAME_SUBSTR = "death wish"
local ICON_SUBSTRINGS = {
  "spell_shadow_deathpact",
  "deathpact",
  "death_wish",
  "deathwish",
}

-- Colors
local C_READY   = { 0.20, 1.00, 0.20 }
local C_ACTIVE  = { 1.00, 0.85, 0.20 }
local C_CD      = { 1.00, 0.25, 0.25 }
local C_UNKNOWN = { 0.70, 0.70, 0.70 }
local C_OFFLINE = { 0.60, 0.60, 0.60 }

-- Warrior localization
local WARRIOR_LOCAL = "Warrior"
if LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE["WARRIOR"] then
  WARRIOR_LOCAL = LOCALIZED_CLASS_NAMES_MALE["WARRIOR"]
end

-- ------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------

local function Lower(s)
  if not s then return "" end
  return string.lower(s)
end

local function Clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function FormatTime(sec)
  if not sec then sec = 0 end
  if sec < 0 then sec = 0 end
  sec = math.floor(sec + 0.5)
  local m = math.floor(sec / 60)
  local s = sec - (m * 60)
  if s < 10 then return m .. ":0" .. s end
  return m .. ":" .. s
end

local function Print(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff<IllWill>|r " .. msg)
  end
end

local function Debug(msg)
  if IllWillDB and IllWillDB.debug and DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa<IllWill dbg>|r " .. msg)
  end
end

-- ------------------------------------------------------------
-- DB
-- ------------------------------------------------------------

local function EnsureDB()
  IllWillDB = IllWillDB or {}
  if IllWillDB.locked == nil then IllWillDB.locked = false end
  if IllWillDB.scale == nil then IllWillDB.scale = 1.0 end
  if IllWillDB.sort == nil then IllWillDB.sort = "status" end -- status|name
  if IllWillDB.assumeReady == nil then IllWillDB.assumeReady = true end
  if IllWillDB.showOffline == nil then IllWillDB.showOffline = true end
  if IllWillDB.debug == nil then IllWillDB.debug = false end
  if IllWillDB.dwNameSubstr == nil then IllWillDB.dwNameSubstr = DEFAULT_DW_NAME_SUBSTR end

  if IllWillDB.shown == nil then IllWillDB.shown = false end
  if IllWillDB.minimalUI == nil then IllWillDB.minimalUI = false end
  if type(IllWillDB.pos) ~= "table" then
    IllWillDB.pos = { point="CENTER", relPoint="CENTER", x=0, y=0 }
  end
end

-- ------------------------------------------------------------
-- Tooltip-based aura name reading (BuzzKill-style approach)
-- ------------------------------------------------------------

local IW_Tip = nil
local function EnsureTooltip()
  if IW_Tip then return end
  -- GameTooltipTemplate creates TextLeft1 etc which we can read like BuzzKill does.
  IW_Tip = CreateFrame("GameTooltip", "IllWillScanTip", UIParent, "GameTooltipTemplate")
  IW_Tip:SetOwner(UIParent, "ANCHOR_NONE")
end

local function GetAuraName(unit, index, isDebuff)
  EnsureTooltip()
  IW_Tip:ClearLines()

  -- Try the most common vanilla APIs. If they don't exist on this client,
  -- we'll simply return nil and rely on texture matching.
  if isDebuff then
    if IW_Tip.SetUnitDebuff then
      IW_Tip:SetUnitDebuff(unit, index)
    elseif IW_Tip.SetUnitAura then
      IW_Tip:SetUnitAura(unit, index, "HARMFUL")
    else
      return nil
    end
  else
    if IW_Tip.SetUnitBuff then
      IW_Tip:SetUnitBuff(unit, index)
    elseif IW_Tip.SetUnitAura then
      IW_Tip:SetUnitAura(unit, index, "HELPFUL")
    else
      return nil
    end
  end

  local fs = _G["IllWillScanTipTextLeft1"]
  local name = fs and fs:GetText() or nil
  return name
end

-- ------------------------------------------------------------
-- Death Wish detection
-- ------------------------------------------------------------

local function TextureLooksLikeDW(tex)
  if not tex then return false end
  local t = Lower(tex)
  local i = 1
  while ICON_SUBSTRINGS[i] do
    if string.find(t, ICON_SUBSTRINGS[i], 1, true) then return true end
    i = i + 1
  end
  return false
end

local function NameLooksLikeDW(name)
  if not name then return false end
  local n = Lower(name)
  local key = Lower(IllWillDB and IllWillDB.dwNameSubstr or DEFAULT_DW_NAME_SUBSTR)
  if key == "" then key = DEFAULT_DW_NAME_SUBSTR end
  return string.find(n, key, 1, true) ~= nil
end

local function UnitHasDeathWish(unit)
  -- Prefer debuffs first (you described it as a debuff)
  local i
  for i = 1, 16 do
    local tex = UnitDebuff(unit, i)
    if not tex then break end

    local nm = GetAuraName(unit, i, true)
    if NameLooksLikeDW(nm) then
      return true, tex, nm, true
    end
    if TextureLooksLikeDW(tex) then
      return true, tex, nm, true
    end
  end

  -- Fallback: sometimes servers represent it as a buff
  for i = 1, 16 do
    local tex = UnitBuff(unit, i)
    if not tex then break end

    local nm = GetAuraName(unit, i, false)
    if NameLooksLikeDW(nm) then
      return true, tex, nm, false
    end
    if TextureLooksLikeDW(tex) then
      return true, tex, nm, false
    end
  end

  return false, nil, nil, nil
end

-- ------------------------------------------------------------
-- Group enumeration (player/party/raid)
-- ------------------------------------------------------------

local function ForEachGroupUnit(callback)
  local nRaid = GetNumRaidMembers()
  if nRaid and nRaid > 0 then
    local i
    for i = 1, nRaid do
      callback("raid" .. i)
    end
    return
  end

  local nParty = GetNumPartyMembers()
  if nParty and nParty > 0 then
    callback("player")
    local i
    for i = 1, nParty do
      callback("party" .. i)
    end
    return
  end

  callback("player")
end

-- ------------------------------------------------------------
-- State + sorting
-- ------------------------------------------------------------

local function GetStateRank(state)
  -- Default sort: ACTIVE first, then COOLDOWN, READY, UNKNOWN, OFFLINE
  if state == "ACTIVE" then return 1 end
  if state == "COOLDOWN" then return 2 end
  if state == "READY" then return 3 end
  if state == "UNKNOWN" then return 4 end
  if state == "OFFLINE" then return 5 end
  return 9
end

local function ComputeState(w, now)
  if w.offline then return "OFFLINE" end

  if w.active and w.activeUntil and now < w.activeUntil then
    return "ACTIVE"
  end

  if w.seen and w.cdUntil and now < w.cdUntil then
    return "COOLDOWN"
  end

  if w.seen and w.cdUntil and now >= w.cdUntil then
    return "READY"
  end

  if not w.seen then
    if IllWillDB.assumeReady then return "READY" end
    return "UNKNOWN"
  end

  return "UNKNOWN"
end

-- ------------------------------------------------------------
-- Core data
-- ------------------------------------------------------------

IW.warriors = IW.warriors or {} -- [name] => state table
IW.order    = IW.order or {}    -- list of current warrior names
IW.rows     = IW.rows or {}     -- UI row frames

-- ------------------------------------------------------------
-- UI (BuzzKill-inspired: dialog backdrop + close button + simple list)
-- ------------------------------------------------------------

local IW_UI = nil

local function SavePosition()
  if not IW_UI then return end
  local p, _, rp, x, y = IW_UI:GetPoint(1)
  if not p then return end
  IllWillDB.pos.point = p
  IllWillDB.pos.relPoint = rp
  IllWillDB.pos.x = x
  IllWillDB.pos.y = y
end

local function RestorePosition()
  if not IW_UI then return end
  IW_UI:ClearAllPoints()
  local pos = IllWillDB.pos or {}
  IW_UI:SetPoint(pos.point or "CENTER", UIParent, pos.relPoint or "CENTER", pos.x or 0, pos.y or 0)
end

local function ApplyLockState()
  if not IW_UI then return end
  if IllWillDB.locked then
    IW_UI:EnableMouse(false)
  else
    IW_UI:EnableMouse(true)
  end
end

-- ------------------------------------------------------------
-- Minimal UI mode (rows only, no background)
-- ------------------------------------------------------------

local MAIN_BACKDROP = {
  bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 8, right = 8, top = 8, bottom = 8 }
}

local BOX_BACKDROP = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 12,
  insets = { left = 3, right = 3, top = 3, bottom = 3 }
}

local function UI_ApplyMode()
  if not IW_UI then return end
  EnsureDB()

  local f = IW_UI
  local minimal = IllWillDB.minimalUI and true or false

  local function SetDecorShown(shown)
    if not f._decor then return end
    local _, obj
    for _, obj in pairs(f._decor) do
      if obj and obj.Show and obj.Hide then
        if shown then obj:Show() else obj:Hide() end
      end
    end
  end

  local sb = _G["IllWillScrollFrameScrollBar"]

  if minimal then
    SetDecorShown(false)

    -- In Vanilla 1.12, SetBackdrop(nil) can error; keep a backdrop but make it fully transparent.
    if f.SetBackdrop then f:SetBackdrop(MAIN_BACKDROP) end
    if f.SetBackdropColor then f:SetBackdropColor(0, 0, 0, 0) end
    if f.SetBackdropBorderColor then f:SetBackdropBorderColor(0, 0, 0, 0) end

    if f._box then
      local box = f._box
      box:ClearAllPoints()
      box:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -2)
      box:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)

      if box.SetBackdrop then box:SetBackdrop(BOX_BACKDROP) end
      if box.SetBackdropColor then box:SetBackdropColor(0, 0, 0, 0) end
      if box.SetBackdropBorderColor then box:SetBackdropBorderColor(0, 0, 0, 0) end
    end

    if sb then sb:Hide() end
  else
    SetDecorShown(true)

    -- Restore full-mode frame size (minimal mode shrinks it to fit rows)
    f:SetWidth(250)
    f:SetHeight(300)

    if f.SetBackdrop then f:SetBackdrop(MAIN_BACKDROP) end
    if f.SetBackdropColor then f:SetBackdropColor(1, 1, 1, 1) end
    if f.SetBackdropBorderColor then f:SetBackdropBorderColor(1, 1, 1, 1) end

    if f._box then
      local box = f._box
      box:ClearAllPoints()
      box:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -110)
      box:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 14)

      if box.SetBackdrop then
        box:SetBackdrop(BOX_BACKDROP)
        box:SetBackdropColor(0, 0, 0, 0.35)
        box:SetBackdropBorderColor(0.25, 0.25, 0.25, 0.9)
      end
    end

    if sb then sb:Show() end
  end

  ApplyLockState()
end

function IW:SetMinimalUI(on)
  UI_Build()
  EnsureDB()
  IllWillDB.minimalUI = on and true or false
  UI_ApplyMode()
  IW:UpdateDisplay()
end

local function EnsureRow(i, parent, y)
  if IW.rows[i] then
    -- Reposition in case sort order changed
    local row = IW.rows[i]
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, y)
    row:SetParent(parent)
    return row
  end

  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(16)
  row:SetWidth(parent:GetWidth() - 10)
  row:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, y)

  row.count = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.count:SetPoint("LEFT", row, "LEFT", 0, 0)
  row.count:SetWidth(24)
  row.count:SetJustifyH("LEFT")

  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetWidth(14)
  row.icon:SetHeight(14)
  row.icon:SetPoint("LEFT", row, "LEFT", 24, 0)
  row.icon:Hide()

  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.name:SetPoint("LEFT", row, "LEFT", 42, 0)
  row.name:SetWidth(50)
  row.name:SetJustifyH("LEFT")

  row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.status:SetPoint("LEFT", row, "LEFT", 100, 0)
  row.status:SetWidth(80)
  row.status:SetJustifyH("RIGHT")

  IW.rows[i] = row
  return row
end

UI_Build = function()
  if IW_UI then return end
  EnsureDB()

  local f = CreateFrame("Frame", "IllWillFrame", UIParent)
  IW_UI = f

  f:SetWidth(250)
  f:SetHeight(300)
  f:SetFrameStrata("DIALOG")

  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 8, right = 8, top = 8, bottom = 8 }
    })
  end

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

  local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -14)
  title:SetText("IllWill")

  local sub = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
  sub:SetText("Death Wish tracker  •  v" .. VERSION)

  local hdr = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  hdr:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -90)
  hdr:SetText("  Count            Name                              Status")

  -- Debug checkbox
  local dbg = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  dbg:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -50)
  dbg.text = dbg:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  dbg.text:SetPoint("LEFT", dbg, "RIGHT", 2, 0)
  dbg.text:SetText("Debug chat")
  dbg:SetChecked(IllWillDB.debug and 1 or 0)
  dbg:SetScript("OnClick", function()
    EnsureDB()
    IllWillDB.debug = (dbg:GetChecked() == 1)
  end)

  local resetBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  resetBtn:SetWidth(50)
  resetBtn:SetHeight(12)
  resetBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 120, -60)
  resetBtn:SetText("Reset")
  resetBtn:SetScript("OnClick", function()
    IW:ResetAll()
    IW:Scan()
    IW:UpdateDisplay()
  end)

  local lockBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  lockBtn:SetWidth(50)
  lockBtn:SetHeight(12)
  lockBtn:SetPoint("LEFT", resetBtn, "RIGHT", 6, 0)
  lockBtn:SetText("Lock")
  lockBtn:SetScript("OnClick", function()
    EnsureDB()
    IllWillDB.locked = not IllWillDB.locked
    lockBtn:SetText(IllWillDB.locked and "Unlock" or "Lock")
    ApplyLockState()
  end)
  lockBtn:SetText(IllWillDB.locked and "Unlock" or "Lock")

  -- List box
  local box = CreateFrame("Frame", nil, f)
  f._box = box
  box:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -110)
  box:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 14)

  if box.SetBackdrop then
    box:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    box:SetBackdropColor(0, 0, 0, 0.35)
    box:SetBackdropBorderColor(0.25, 0.25, 0.25, 0.9)
  end

  local scroll = CreateFrame("ScrollFrame", "IllWillScrollFrame", box, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", box, "TOPLEFT", 5, -5)
  scroll:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -24, 5)

  local child = CreateFrame("Frame", "IllWillScrollChild", scroll)
  child:SetWidth(260)
  child:SetHeight(1)
  scroll:SetScrollChild(child)

  f._scroll = scroll
  f._child  = child


-- Store "decor" widgets so hideui/showui can toggle them
f._decor = {
  close   = close,
  title   = title,
  sub     = sub,
  hdr     = hdr,
  dbg     = dbg,
  resetBtn= resetBtn,
  lockBtn = lockBtn,
}

-- Apply saved UI mode (full vs minimal)
UI_ApplyMode()


  -- Movement
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function()
    if IllWillDB.locked then return end
    f:StartMoving()
  end)
  f:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    SavePosition()
  end)

  -- Catch any hide path (X button, Escape, etc.) so shown state persists
  f:SetScript("OnHide", function()
    EnsureDB()
    IllWillDB.shown = false
  end)

  RestorePosition()
  f:SetScale(IllWillDB.scale or 1.0)
  ApplyLockState()

  f:Hide()
end

function IW:Show()
  UI_Build()
  EnsureDB()
  IW_UI:Show()
  IllWillDB.shown = true
  IW:Scan()
  IW:UpdateDisplay()
end

function IW:Hide()
  EnsureDB()
  IllWillDB.shown = false
  if IW_UI then IW_UI:Hide() end
end

function IW:Toggle()
  UI_Build()
  if IW_UI:IsShown() then IW_UI:Hide() else IW:Show() end
end

-- ------------------------------------------------------------
-- Scan + Update
-- ------------------------------------------------------------

function IW:ResetAll()
  IW.warriors = {}
  IW.order = {}
  -- Hide all existing row frames but keep them for reuse (no :Destroy() in 1.12)
  local j = 1
  while IW.rows[j] do
    IW.rows[j]:Hide()
    j = j + 1
  end
  Print("Reset counts + timers.")
end

function IW:Scan()
  EnsureDB()

  local now = GetTime()
  local seen = {}
  local names = {}

  ForEachGroupUnit(function(unit)
    if UnitExists(unit) then
      local class = UnitClass(unit)
      if class == WARRIOR_LOCAL then
        local name = UnitName(unit)
        if name and name ~= "" then
          local w = IW.warriors[name]
          if not w then
            w = { uses=0, seen=false, active=false, cdUntil=0, activeUntil=0, offline=false, icon=nil }
            IW.warriors[name] = w
          end

          w.unit = unit
          w.offline = (UnitIsConnected(unit) == nil) or (UnitIsConnected(unit) == false)
          seen[name] = true
          table.insert(names, name)

          if not w.offline then
            local hasDW, tex, nm = UnitHasDeathWish(unit)

            if hasDW and not w.active then
              -- Rising edge: count a new Death Wish use
              w.active = true
              w.seen = true
              w.uses = (w.uses or 0) + 1
              w.lastCast = now
              w.activeUntil = now + DW_ACTIVE
              w.cdUntil = now + DW_COOLDOWN
              w.icon = tex or w.icon
              Debug("DW detected: " .. name .. " (" .. (nm or "icon") .. ") uses=" .. w.uses)
            end

            if hasDW then
              w.active = true
              -- keep icon fresh
              if tex and tex ~= "" then w.icon = tex end
              -- safety: if we see it later than the exact cast time, keep active window reasonable
              if not w.activeUntil or w.activeUntil < now then
                w.activeUntil = now + DW_ACTIVE
              end
              if not w.cdUntil or w.cdUntil < now then
                w.cdUntil = now + DW_COOLDOWN
              end
            else
              -- not currently seen
              if w.active and w.activeUntil and now >= w.activeUntil then
                w.active = false
              end
            end
          end
        end
      end
    end
  end)

  -- Keep only current-group warriors in the order list
  IW.order = names
end

function IW:UpdateDisplay()
  if not IW_UI or not IW_UI:IsShown() then return end

  local now = GetTime()
  local list = {}

  -- Filter + decorate
  local i
  for i = 1, table.getn(IW.order) do
    local name = IW.order[i]
    local w = IW.warriors[name]
    if w then
      if (not w.offline) or IllWillDB.showOffline then
        local state = ComputeState(w, now)
        table.insert(list, { name=name, w=w, state=state })
      end
    end
  end

  -- Sort
  if IllWillDB.sort == "name" then
    table.sort(list, function(a, b)
      return a.name < b.name
    end)
  else
    table.sort(list, function(a, b)
      local ra = GetStateRank(a.state)
      local rb = GetStateRank(b.state)
      if ra ~= rb then return ra < rb end
      return a.name < b.name
    end)
  end

  -- Layout
  local rowH = 16
  local max = table.getn(list)
  local child = IW_UI._child
  if not child then return end

  local height = max * rowH
  if height < 1 then height = 1 end
  child:SetHeight(height)


-- In minimal UI mode, shrink/grow the frame to fit the rows (within reason)
if IllWillDB and IllWillDB.minimalUI and IW_UI then
  local want = height + 6
  if want < 28 then want = 28 end
  if want > 420 then want = 420 end
  IW_UI:SetHeight(want)
end


  local y = -2
  for i = 1, max do
    local e = list[i]
    local w = e.w
    local state = e.state

    local row = EnsureRow(i, child, y)

    row.count:SetText(tostring(w.uses or 0))

    if w.icon then
      row.icon:SetTexture(w.icon)
      row.icon:Show()
    else
      row.icon:Hide()
    end

    row.name:SetText(e.name)

    if state == "ACTIVE" then
      local left = (w.activeUntil or now) - now
      row.status:SetText("ACTIVE " .. FormatTime(left))
      row.status:SetTextColor(C_ACTIVE[1], C_ACTIVE[2], C_ACTIVE[3])

    elseif state == "COOLDOWN" then
      local left = (w.cdUntil or now) - now
      row.status:SetText(FormatTime(left))
      row.status:SetTextColor(C_CD[1], C_CD[2], C_CD[3])

    elseif state == "READY" then
      row.status:SetText("READY")
      row.status:SetTextColor(C_READY[1], C_READY[2], C_READY[3])

    elseif state == "OFFLINE" then
      row.status:SetText("OFFLINE")
      row.status:SetTextColor(C_OFFLINE[1], C_OFFLINE[2], C_OFFLINE[3])

    else
      row.status:SetText("??")
      row.status:SetTextColor(C_UNKNOWN[1], C_UNKNOWN[2], C_UNKNOWN[3])
    end

    y = y - rowH
  end

  -- Hide unused rows
  local j = max + 1
  while IW.rows[j] do
    IW.rows[j]:Hide()
    j = j + 1
  end
  for i = 1, max do
    IW.rows[i]:Show()
  end
end

-- ------------------------------------------------------------
-- Engine (runs regardless of UI visibility so counts keep updating)
-- ------------------------------------------------------------

IW._inited = false
IW._scanElapsed = 0
IW._rosterElapsed = 0

function IW:Init()
  if IW._inited then return end
  IW._inited = true
  EnsureDB()
  Debug("Init OK")
end

local engine = CreateFrame("Frame")
engine:RegisterEvent("ADDON_LOADED")
engine:RegisterEvent("PLAYER_ENTERING_WORLD")
engine:RegisterEvent("RAID_ROSTER_UPDATE")
engine:RegisterEvent("PARTY_MEMBERS_CHANGED")

engine:SetScript("OnEvent", function()
  IW:Init()

  -- On roster changes, rebuild immediately (and refresh if shown)
  if event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
    IW:Scan()
    IW:UpdateDisplay()
  end

  -- On entering world, do an initial scan
  if event == "PLAYER_ENTERING_WORLD" then
    EnsureDB()
    IW:Scan()
    if IllWillDB.shown then
      IW:Show()
    end
    IW:UpdateDisplay()
  end
end)

engine:SetScript("OnUpdate", function(self, elapsed)
  elapsed = elapsed or arg1 or 0
  if type(elapsed) ~= "number" then elapsed = 0 end
  IW:Init()
  IW._scanElapsed = IW._scanElapsed + elapsed
  IW._rosterElapsed = IW._rosterElapsed + elapsed

  if IW._rosterElapsed >= ROSTER_REBUILD_SECONDS then
    IW._rosterElapsed = 0
    IW:Scan()
  end

  if IW._scanElapsed >= SCAN_INTERVAL then
    IW._scanElapsed = 0
    IW:Scan()
    IW:UpdateDisplay()
  end
end)

-- ------------------------------------------------------------
-- Slash commands (registered immediately; does NOT depend on folder name)
-- ------------------------------------------------------------

local function ShowHelp()
  Print("Commands:")
  Print("/iw                (toggle window)")
  Print("/iw show | hide")
  Print("/iw lock | unlock")
  Print("/iw reset")
  Print("/iw debug")
  Print("/iw assume ready | unknown")
  Print("/iw sort status | name")
  Print("/iw offline on | off")
  Print("/iw scale <0.6-2.0>")
  Print("/iw hideui | showui")
  Print("/iw probe  (prints YOUR Death Wish aura match info)")
end

local function HandleSlash(msg)
  IW:Init()
  EnsureDB()

  msg = msg or ""
  msg = string.gsub(msg, "^%s+", "")
  msg = string.gsub(msg, "%s+$", "")

  if msg == "" then
    IW:Toggle()
    return
  end

  local _, _, cmd, rest = string.find(msg, "^(%S+)%s*(.*)$")
  cmd = cmd and string.lower(cmd) or ""
  rest = rest or ""

  if cmd == "help" then
    ShowHelp()
    return

  elseif cmd == "show" then
    IW:Show()
    return

  elseif cmd == "hide" then
    IW:Hide()
    return


elseif cmd == "hideui" then
  IW:SetMinimalUI(true)
  Print("UI: minimal (rows only).")
  return

elseif cmd == "showui" then
  IW:SetMinimalUI(false)
  Print("UI: full.")
  return


  elseif cmd == "toggle" or cmd == "ui" then
    IW:Toggle()
    return

  elseif cmd == "lock" then
    IllWillDB.locked = true
    ApplyLockState()
    Print("Locked.")
    return

  elseif cmd == "unlock" then
    IllWillDB.locked = false
    ApplyLockState()
    Print("Unlocked. Drag to move.")
    return

  elseif cmd == "reset" then
    IW:ResetAll()
    IW:Scan()
    IW:UpdateDisplay()
    return

  elseif cmd == "debug" then
    IllWillDB.debug = not IllWillDB.debug
    Print("Debug is now " .. (IllWillDB.debug and "ON" or "OFF"))
    return

  elseif cmd == "assume" then
    rest = string.lower(rest or "")
    if rest == "ready" then
      IllWillDB.assumeReady = true
      Print("Assume-ready: ON (unknowns show READY).")
    elseif rest == "unknown" then
      IllWillDB.assumeReady = false
      Print("Assume-ready: OFF (unknowns show ?? until first seen).")
    else
      Print("Usage: /iw assume ready | unknown")
    end
    IW:UpdateDisplay()
    return

  elseif cmd == "sort" then
    rest = string.lower(rest or "")
    if rest == "name" or rest == "status" then
      IllWillDB.sort = rest
      Print("Sort set to " .. rest)
    else
      Print("Sort options: name | status")
    end
    IW:UpdateDisplay()
    return

  elseif cmd == "offline" then
    rest = string.lower(rest or "")
    if rest == "on" then
      IllWillDB.showOffline = true
      Print("Show offline warriors: ON")
    elseif rest == "off" then
      IllWillDB.showOffline = false
      Print("Show offline warriors: OFF")
    else
      Print("Usage: /iw offline on | off")
    end
    IW:UpdateDisplay()
    return

  elseif cmd == "scale" then
    local n = tonumber(rest)
    if not n then
      Print("Usage: /iw scale <0.6-2.0>")
      return
    end
    n = Clamp(n, 0.6, 2.0)
    IllWillDB.scale = n
    UI_Build()
    IW_UI:SetScale(n)
    Print("Scale set to " .. n)
    return

  elseif cmd == "probe" then
    -- Show what this client sees on PLAYER for easier troubleshooting
    local hasDW, tex, nm, isDebuff = UnitHasDeathWish("player")
    Print("Probe(player): hasDW=" .. (hasDW and "YES" or "NO")
      .. " type=" .. (isDebuff == nil and "?" or (isDebuff and "debuff" or "buff"))
      .. " name=" .. (nm or "nil")
      .. " tex=" .. (tex or "nil"))
    return
  end

  ShowHelp()
end

SLASH_ILLWILL1 = "/illwill"
SLASH_ILLWILL2 = "/iw"
SlashCmdList["ILLWILL"] = HandleSlash

-- Friendly hello in chat once the file is definitely loaded
Print("Loaded. Type /iw to open the tracker.")

