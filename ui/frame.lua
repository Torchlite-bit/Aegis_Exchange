-- Aegis: Exchange
-- ui/frame.lua
--
-- STANDALONE custom auction window (Stage A: shell only).
--
-- Aegis is its OWN top-level frame parented to UIParent — it does NOT tab onto
-- or parent to the Blizzard AuctionFrame. When the auction house opens we hide
-- the Blizzard window and show ours in its place (the approach the Aux addon
-- uses on this 1.12 client); when it closes we hide ours. The 1.12 client has
-- no taint / protected-frame system, so replacing the AH window is safe, and
-- because no Blizzard AH frame is visible there are no default widgets, holes,
-- sort headers, or backgrounds to conflict with.
--
-- Stage A is skin + lifecycle + sub-tab switching only. Full Scan / Pause /
-- Resume are placeholders (chat messages); the sub-tab panels are empty labels.
-- Scanning, price DB, posting, search, etc. arrive in later stages, rendered
-- into these panels. (The scan/db/tooltip modules are unchanged and still
-- feed item tooltips.)

local A = AegisExchange
A.ui = A.ui or {}
local ui = A.ui
local util = A.util

-- Palette approximated from design/ (0-1 space).
local C = {
    panelBG = { 0.13, 0.12, 0.10 },
    titleBG = { 0.08, 0.07, 0.05 },
    well    = { 0.05, 0.05, 0.04 },
    gold    = { 1.00, 0.82, 0.00 },
    goldDim = { 0.72, 0.58, 0.32 },
    text    = { 0.87, 0.82, 0.69 },
    amber   = { 0.88, 0.65, 0.19 },
    barFill = { 0.25, 0.56, 0.20 },
    tabOff  = { 0.21, 0.17, 0.12 },
    tabOn   = { 0.32, 0.27, 0.16 },
    border  = { 0.79, 0.64, 0.15 },
}

-- Last scan older than this is "stale" and rendered amber.
local STALE_SECONDS = 24 * 60 * 60

-- "Scan" hosts the scanner controls (Full Scan / Pause / Resume / Categories
-- + status and progress); the others are placeholders for later stages.
local SUBTABS = { "Buy", "Sell", "Auctions", "Crafting", "Scan" }

-- Display label per sub-tab (internal keys stay stable). The scan tab also
-- hosts user settings, so it reads as "Aegis".
local TAB_LABELS = { Scan = "Aegis" }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function ChatMsg(text)
    DEFAULT_CHAT_FRAME:AddMessage(text, 0.35, 0.78, 0.98)
end

-- A sub-tab button: a dark pill with a centered label, recoloured on select.
local function MakeSubTab(parent, name)
    local b = CreateFrame("Button", "AegisExchangeSubTab" .. name, parent)
    b:SetHeight(24)
    b:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER", b, "CENTER", 0, 0)
    fs:SetText(TAB_LABELS[name] or name)
    b.label = fs
    b:SetWidth(fs:GetStringWidth() + 30)
    b:SetScript("OnClick", function()
        ui.SelectSubTab(name)
    end)
    return b
end

-- ---------------------------------------------------------------------------
-- Window construction (once)
-- ---------------------------------------------------------------------------

function ui.BuildWindow()
    if ui.frame then return end

    local f = CreateFrame("Frame", "AegisExchangeFrame", UIParent)
    f:SetWidth(832)
    f:SetHeight(460)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    if f.SetClampedToScreen then f:SetClampedToScreen(true) end
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 28,
        insets = { left = 10, right = 10, top = 10, bottom = 10 },
    })
    f:SetBackdropColor(C.panelBG[1], C.panelBG[2], C.panelBG[3], 1)
    f:SetBackdropBorderColor(1, 1, 1)
    f:Hide()
    ui.frame = f

    -- ESC closes our window (and, via OnHide below, the AH session). Without
    -- this the client swallows ESC while our top-level frame is up instead of
    -- opening the game menu.
    if UISpecialFrames then
        table.insert(UISpecialFrames, "AegisExchangeFrame")
    end

    -- Hiding our window is the single close path: whether it's the close
    -- button, ESC, or an AUCTION_HOUSE_CLOSED from walking away, end the AH
    -- session here. Skipped only during the /aex hand-off to the Blizzard AH,
    -- which needs the session to stay open.
    f:SetScript("OnHide", function()
        if not ui.showBlizzard then
            CloseAuctionHouse()
        end
    end)

    -- Title bar (also the drag handle). It stops well short of the top-right
    -- corner so its mouse-enabled drag region never overlaps the close button
    -- (otherwise the button is only clickable along its top edge).
    local titleBar = CreateFrame("Frame", "AegisExchangeTitleBar", f)
    titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12)
    -- Extend the dark bar to just left of the close button (the raised buttons
    -- sit on top of it), so the header reads as one clean strip.
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -12)
    titleBar:SetHeight(26)
    titleBar:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        tile = true, tileSize = 16,
    })
    titleBar:SetBackdropColor(C.titleBG[1], C.titleBG[2], C.titleBG[3], 1)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    ui.titleBar = titleBar

    local titleText = titleBar:CreateFontString(
        "AegisExchangeTitleText", "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("LEFT", titleBar, "LEFT", 10, 0)
    titleText:SetText("Aegis: Exchange")
    titleText:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    -- Close button (top-right) — closes the auction house. Its frame level is
    -- raised above the title bar so the whole button is clickable, not just the
    -- sliver above the drag region. Created first so the swap button can anchor
    -- to its left.
    local close = CreateFrame("Button", "AegisExchangeCloseButton", f,
        "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
    close:SetFrameLevel(f:GetFrameLevel() + 10)
    close:SetScript("OnClick", function()
        ui.CloseWindow()
    end)

    -- Swap to the stock Blizzard AH (its counterpart button swaps back —
    -- see HookAuctionFrame). Raised above the title bar's drag region and
    -- anchored to the close button so it sits neatly on the extended bar.
    local blizBtn = CreateFrame("Button", "AegisExchangeBlizzardButton", f,
        "UIPanelButtonTemplate")
    blizBtn:SetWidth(92)
    blizBtn:SetHeight(20)
    blizBtn:SetPoint("RIGHT", close, "LEFT", -4, 0)
    blizBtn:SetFrameLevel(f:GetFrameLevel() + 10)
    blizBtn:SetText("Blizzard UI")
    blizBtn:SetScript("OnClick", function()
        ui.ShowBlizzardUI()
    end)

    local subTitle = titleBar:CreateFontString(
        nil, "OVERLAY", "GameFontHighlightSmall")
    subTitle:SetPoint("RIGHT", blizBtn, "LEFT", -10, 0)
    -- The version here is the quickest way to confirm which build is
    -- actually installed when triaging a bug report.
    subTitle:SetText("Turtle WoW 1.12 \226\128\162 v" .. (A.version or "?"))
    subTitle:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])

    -- Sub-tab row, directly under the title bar.
    ui.subtabs = {}
    local prev = nil
    local nTabs = table.getn(SUBTABS)
    local i = 1
    while i <= nTabs do
        local name = SUBTABS[i]
        local tab = MakeSubTab(f, name)
        if prev then
            tab:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else
            tab:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -10)
        end
        ui.subtabs[name] = tab
        prev = tab
        i = i + 1
    end

    -- Content region (recessed well) below the sub-tabs.
    -- 12 border + 26 title bar + 10 gap + 24 tabs + 8 gap = 80 from the top.
    local content = CreateFrame("Frame", "AegisExchangeContent", f)
    content:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -80)
    content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 16)
    content:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    content:SetBackdropColor(C.well[1], C.well[2], C.well[3], 1)
    content:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3])
    ui.content = content

    -- One panel per sub-tab, filling the content region. All but Scan are
    -- placeholders (centered label); Scan hosts the scanner controls below.
    ui.panels = {}
    i = 1
    while i <= nTabs do
        local name = SUBTABS[i]
        local panel = CreateFrame("Frame", "AegisExchangePanel" .. name, content)
        panel:SetPoint("TOPLEFT", content, "TOPLEFT", 6, -6)
        panel:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -6, 6)
        panel:Hide()
        -- Every tab is now a real tab (built below); no placeholders remain.
        if name ~= "Scan" and name ~= "Sell" and name ~= "Buy"
            and name ~= "Crafting" and name ~= "Auctions" then
            local label = panel:CreateFontString(
                "AegisExchangePanelLabel" .. name, "OVERLAY",
                "GameFontNormalLarge")
            label:SetPoint("CENTER", panel, "CENTER", 0, 0)
            label:SetText(name)
            label:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
        end
        ui.panels[name] = panel
        i = i + 1
    end

    -- Scan tab: Full Scan / Pause / Resume / Categories + status + progress.
    local scanPanel = ui.panels["Scan"]

    local fullScan = CreateFrame("Button", "AegisExchangeFullScanButton",
        scanPanel, "UIPanelButtonTemplate")
    fullScan:SetWidth(100)
    fullScan:SetHeight(22)
    fullScan:SetPoint("TOPLEFT", scanPanel, "TOPLEFT", 8, -10)
    fullScan:SetText("Full Scan")
    fullScan:SetScript("OnClick", function()
        ui.ConfirmFullScan()
    end)
    ui.fullScanBtn = fullScan

    local pause = CreateFrame("Button", "AegisExchangePauseButton",
        scanPanel, "UIPanelButtonTemplate")
    pause:SetWidth(74)
    pause:SetHeight(22)
    pause:SetPoint("LEFT", fullScan, "RIGHT", 6, 0)
    pause:SetText("Pause")
    pause:SetScript("OnClick", function()
        A.scan.Pause()
        ui.Refresh()
    end)
    ui.pauseBtn = pause

    local resume = CreateFrame("Button", "AegisExchangeResumeButton",
        scanPanel, "UIPanelButtonTemplate")
    resume:SetWidth(74)
    resume:SetHeight(22)
    resume:SetPoint("LEFT", pause, "RIGHT", 6, 0)
    resume:SetText("Resume")
    resume:SetScript("OnClick", function()
        A.scan.Continue()
        ui.Refresh()
    end)
    ui.resumeBtn = resume

    -- Stop: abandon the scan entirely and free the AH for browsing/posting.
    -- (Pause keeps progress for Resume, but the scanner is shared, so it still
    -- holds the query channel -- Stop is the way to bail out completely.)
    local stop = CreateFrame("Button", "AegisExchangeStopButton",
        scanPanel, "UIPanelButtonTemplate")
    stop:SetWidth(60)
    stop:SetHeight(22)
    stop:SetPoint("LEFT", resume, "RIGHT", 6, 0)
    stop:SetText("Stop")
    stop:SetScript("OnClick", function()
        A.scan.Stop()
        ui.Refresh()
        ChatMsg("Aegis: scan stopped.")
    end)
    ui.stopBtn = stop

    local cats = CreateFrame("Button", "AegisExchangeCategoriesButton",
        scanPanel, "UIPanelButtonTemplate")
    cats:SetWidth(94)
    cats:SetHeight(22)
    cats:SetPoint("LEFT", stop, "RIGHT", 6, 0)
    cats:SetText("Categories")
    cats:SetScript("OnClick", function()
        ui.TogglePicker()
    end)
    ui.catsBtn = cats

    local status = scanPanel:CreateFontString(
        "AegisExchangeStatusText", "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("RIGHT", scanPanel, "RIGHT", -10, 0)
    status:SetPoint("TOP", fullScan, "TOP", 0, -4)
    status:SetJustifyH("RIGHT")
    status:SetText("Last scan: never")
    status:SetTextColor(C.text[1], C.text[2], C.text[3])
    ui.statusText = status

    -- Progress bar under the buttons. Shown only while a scan is running or
    -- paused (hidden when idle).
    local bar = CreateFrame("StatusBar", "AegisExchangeScanBar", scanPanel)
    bar:SetPoint("TOPLEFT", fullScan, "BOTTOMLEFT", 0, -10)
    bar:SetPoint("RIGHT", scanPanel, "RIGHT", -10, 0)
    bar:SetHeight(14)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(C.barFill[1], C.barFill[2], C.barFill[3])
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    bar:SetBackdropColor(0.03, 0.03, 0.03, 0.9)
    bar:SetBackdropBorderColor(0.4, 0.35, 0.2)
    bar:Hide()
    ui.bar = bar

    local tip = scanPanel:CreateFontString(
        nil, "OVERLAY", "GameFontHighlightSmall")
    tip:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -10)
    tip:SetJustifyH("LEFT")
    tip:SetText("Tip: Categories \226\134\146 check classes \226\134\146"
        .. " Scan Selected runs a fast targeted scan.")
    tip:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])

    ui.BuildAegisSettings(scanPanel, tip)
    ui.BuildSellTab()
    ui.BuildBuyTab()
    ui.BuildCraftTab()
    ui.BuildAuctionsTab()

    -- Live refresh while a scan runs (elapsed is the GLOBAL arg1). Only ticks
    -- while the window is shown, i.e. while the AH is open.
    ui.refreshAccum = 0
    f:SetScript("OnUpdate", function()
        ui.refreshAccum = ui.refreshAccum + arg1
        if ui.refreshAccum >= 0.3 then
            ui.refreshAccum = 0
            if A.scan.IsRunning() or A.scan.IsPaused() then
                ui.Refresh()
            end
        end
    end)

    -- Land on Buy (the most-used tab); Buy / Sell / Scan are all functional.
    ui.SelectSubTab("Buy")
    ui.Refresh()
end

-- ---------------------------------------------------------------------------
-- Aegis tab: user settings (built onto the scan panel, below the scan strip)
-- ---------------------------------------------------------------------------

StaticPopupDialogs["AEGIS_EXCHANGE_CLEARDB"] = {
    text = "Clear ALL recorded Aegis price data?\nThis cannot be undone.",
    button1 = "Clear", button2 = "Cancel",
    OnAccept = function()
        A.db.ClearItems()
        ui.RefreshSettings()
        ChatMsg("Aegis: price data cleared.")
    end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

function ui.BuildAegisSettings(panel, anchorAbove)
    -- Section header under the scan controls.
    local hdr = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hdr:SetPoint("TOPLEFT", anchorAbove, "BOTTOMLEFT", 0, -18)
    hdr:SetText("Settings")
    hdr:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    local function label(text, anchor, dy)
        local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, dy)
        fs:SetText(text)
        fs:SetTextColor(C.text[1], C.text[2], C.text[3])
        return fs
    end

    -- ---- Default post duration --------------------------------------------
    local durLbl = label("Default post duration:", hdr, -16)
    ui.setDurBtns = {}
    local prev = nil
    local di = 1
    while di <= table.getn(A.sell.DURATIONS) do
        local d = A.sell.DURATIONS[di]
        local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        b:SetWidth(44); b:SetHeight(20)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else b:SetPoint("LEFT", durLbl, "RIGHT", 10, 0) end
        b:SetText(d.label)
        b.minutes = d.minutes
        b:SetScript("OnClick", function()
            A.db.SetSetting("duration", b.minutes)
            ui.ApplySettingsToSell()
            ui.RefreshSettings()
        end)
        ui.setDurBtns[di] = b
        prev = b
        di = di + 1
    end

    -- ---- Default undercut: percent OR a flat copper amount ----------------
    local ucLbl = label("Default undercut:", durLbl, -20)

    local pctMode = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    pctMode:SetWidth(34); pctMode:SetHeight(20)
    pctMode:SetPoint("LEFT", ucLbl, "RIGHT", 10, 0)
    pctMode:SetText("%")
    pctMode.mode = "pct"
    pctMode:SetScript("OnClick", function()
        A.db.SetSetting("undercutMode", "pct"); ui.RefreshSettings()
    end)
    local flatMode = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    flatMode:SetWidth(48); flatMode:SetHeight(20)
    flatMode:SetPoint("LEFT", pctMode, "RIGHT", 3, 0)
    flatMode:SetText("Flat")
    flatMode.mode = "flat"
    flatMode:SetScript("OnClick", function()
        A.db.SetSetting("undercutMode", "flat"); ui.RefreshSettings()
    end)
    ui.setUcModeBtns = { pctMode, flatMode }

    -- Percent entry.
    local uc = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    uc:SetWidth(34); uc:SetHeight(18)
    uc:SetAutoFocus(false); uc:SetNumeric(true); uc:SetJustifyH("CENTER")
    uc:SetPoint("LEFT", flatMode, "RIGHT", 12, 0)
    uc:SetScript("OnEnterPressed", function() ui.CommitUndercut(); uc:ClearFocus() end)
    uc:SetScript("OnEscapePressed", function() uc:ClearFocus() end)
    uc:SetScript("OnEditFocusLost", function() ui.CommitUndercut() end)
    ui.setUndercut = uc
    local pctLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pctLbl:SetPoint("LEFT", uc, "RIGHT", 3, 0)
    pctLbl:SetText("%")
    pctLbl:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])

    -- Flat-amount entry (money text like "1s" or "50c").
    local flat = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    flat:SetWidth(64); flat:SetHeight(18)
    flat:SetAutoFocus(false); flat:SetJustifyH("CENTER")
    flat:SetPoint("LEFT", pctLbl, "RIGHT", 12, 0)
    flat:SetScript("OnEnterPressed", function()
        ui.CommitUndercutFlat(); flat:ClearFocus()
    end)
    flat:SetScript("OnEscapePressed", function() flat:ClearFocus() end)
    flat:SetScript("OnEditFocusLost", function() ui.CommitUndercutFlat() end)
    ui.setUndercutFlat = flat
    local flatLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    flatLbl:SetPoint("LEFT", flat, "RIGHT", 4, 0)
    flatLbl:SetText("below (e.g. 1s, 50c)")
    flatLbl:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])

    -- ---- Default sell price -----------------------------------------------
    local spLbl = label("Default sell price:", ucLbl, -20)
    ui.setSellModeBtns = {}
    local modes = { { "Undercut", "undercut" }, { "Market", "market" },
                    { "None", "none" } }
    prev = nil
    local mi = 1
    while mi <= table.getn(modes) do
        local m = modes[mi]
        local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        b:SetWidth(72); b:SetHeight(20)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else b:SetPoint("LEFT", spLbl, "RIGHT", 10, 0) end
        b:SetText(m[1])
        b.mode = m[2]
        b:SetScript("OnClick", function()
            A.db.SetSetting("sellDefault", b.mode)
            ui.RefreshSettings()
        end)
        ui.setSellModeBtns[mi] = b
        prev = b
        mi = mi + 1
    end

    -- ---- Toggles ----------------------------------------------------------
    local tipChk = CreateFrame("CheckButton", "AegisExchangeSetTooltip", panel,
        "UICheckButtonTemplate")
    tipChk:SetWidth(24); tipChk:SetHeight(24)
    tipChk:SetPoint("TOPLEFT", spLbl, "BOTTOMLEFT", -2, -16)
    local tipTxt = getglobal(tipChk:GetName() .. "Text")
    if tipTxt then
        tipTxt:SetText("Show Aegis price lines on item tooltips")
        tipTxt:SetTextColor(C.text[1], C.text[2], C.text[3])
    end
    tipChk:SetScript("OnClick", function()
        A.db.SetSetting("tooltip", tipChk:GetChecked() and true or false)
    end)
    ui.setTooltip = tipChk

    local profChk = CreateFrame("CheckButton", "AegisExchangeSetProfLine", panel,
        "UICheckButtonTemplate")
    profChk:SetWidth(24); profChk:SetHeight(24)
    profChk:SetPoint("TOPLEFT", tipChk, "BOTTOMLEFT", 0, -4)
    local profTxt = getglobal(profChk:GetName() .. "Text")
    if profTxt then
        profTxt:SetText("Show profit line on profession windows")
        profTxt:SetTextColor(C.text[1], C.text[2], C.text[3])
    end
    profChk:SetScript("OnClick", function()
        A.db.SetSetting("profLine", profChk:GetChecked() and true or false)
        ui.UpdateProfLine()
    end)
    ui.setProfLine = profChk

    -- ---- Price data -------------------------------------------------------
    ui.setDataText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.setDataText:SetPoint("TOPLEFT", profChk, "BOTTOMLEFT", 4, -14)
    ui.setDataText:SetTextColor(C.text[1], C.text[2], C.text[3])

    local clearBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    clearBtn:SetWidth(120); clearBtn:SetHeight(20)
    clearBtn:SetPoint("LEFT", ui.setDataText, "RIGHT", 14, 0)
    clearBtn:SetText("Clear price data")
    clearBtn:SetScript("OnClick", function()
        StaticPopup_Show("AEGIS_EXCHANGE_CLEARDB")
    end)

    ui.settingsBuilt = true
    ui.RefreshSettings()
end

-- Clamp and store the undercut-percent box.
function ui.CommitUndercut()
    if not ui.setUndercut then return end
    local n = tonumber(ui.setUndercut:GetText())
    if not n then n = A.db.Setting("undercutPct") end
    if n < 0 then n = 0 end
    if n > 90 then n = 90 end
    A.db.SetSetting("undercutPct", math.floor(n))
    ui.RefreshSettings()
end

-- Parse and store the flat-amount undercut (money text -> copper).
function ui.CommitUndercutFlat()
    if not ui.setUndercutFlat then return end
    local c = util.ParseMoney(util.Trim(ui.setUndercutFlat:GetText() or ""))
    if not c or c < 1 then c = A.db.Setting("undercutAmount") end
    A.db.SetSetting("undercutAmount", math.floor(c))
    ui.RefreshSettings()
end

-- Push the saved default duration to the Sell tab immediately.
function ui.ApplySettingsToSell()
    local dur = A.db.Setting("duration")
    if dur then ui.sellDuration = dur end
    if ui.sellBuilt then ui.RefreshSell() end
end

-- Paint the settings widgets from the stored values.
function ui.RefreshSettings()
    if not ui.settingsBuilt then return end
    local dur = A.db.Setting("duration")
    local di = 1
    while di <= table.getn(ui.setDurBtns) do
        local b = ui.setDurBtns[di]
        if b.minutes == dur then b:LockHighlight() else b:UnlockHighlight() end
        di = di + 1
    end
    local mode = A.db.Setting("sellDefault")
    local mi = 1
    while mi <= table.getn(ui.setSellModeBtns) do
        local b = ui.setSellModeBtns[mi]
        if b.mode == mode then b:LockHighlight() else b:UnlockHighlight() end
        mi = mi + 1
    end
    local ucMode = A.db.Setting("undercutMode")
    if ui.setUcModeBtns then
        local ui2 = 1
        while ui2 <= table.getn(ui.setUcModeBtns) do
            local b = ui.setUcModeBtns[ui2]
            if b.mode == ucMode then b:LockHighlight() else b:UnlockHighlight() end
            ui2 = ui2 + 1
        end
    end
    if ui.setUndercut then
        ui.setUndercut:SetText(tostring(A.db.Setting("undercutPct")))
    end
    if ui.setUndercutFlat then
        ui.setUndercutFlat:SetText(util.FormatMoney(A.db.Setting("undercutAmount"), false))
    end
    if ui.setTooltip then
        ui.setTooltip:SetChecked(A.db.Setting("tooltip") ~= false and 1 or nil)
    end
    if ui.setProfLine then
        ui.setProfLine:SetChecked(A.db.Setting("profLine") ~= false and 1 or nil)
    end
    if ui.setDataText then
        ui.setDataText:SetText("Price data: " .. A.db.ItemCount()
            .. " item(s) recorded")
    end
end

-- ---------------------------------------------------------------------------
-- Scan strip: wire Full Scan / Pause / Resume to the real scanner
-- ---------------------------------------------------------------------------

-- Estimated pages for the confirm popup: prefer the last full scan's page
-- count, else whatever the currently displayed query reports.
local function EstimatePages()
    local last = A.db.GetLastScan()
    if last and last.pages and last.pages > 0 then
        return last.pages
    end
    local _, totalAuctions = GetNumAuctionItems("list")
    if totalAuctions and totalAuctions > 0 then
        return math.ceil(totalAuctions / A.scan.PAGE_SIZE)
    end
    return nil
end

StaticPopupDialogs["AEGIS_EXCHANGE_FULL_SCAN"] = {
    text = "Full scan of ~%s pages will take about %s minutes. Continue?",
    button1 = "Continue",
    button2 = "Cancel",
    OnAccept = function()
        ui.StartFullScan()
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

function ui.ConfirmFullScan()
    local pages = EstimatePages()
    local pagesText, minutesText
    if pages then
        pagesText = tostring(pages)
        minutesText = tostring(math.ceil(pages * A.scan.PAGE_DELAY / 60))
    else
        pagesText, minutesText = "?", "?"
    end
    StaticPopup_Show("AEGIS_EXCHANGE_FULL_SCAN", pagesText, minutesText)
end

-- Start a scan of `queries` (a single query, or a list — see scan.Start).
function ui.StartScan(queries)
    A.scan.Start(queries, {
        onPage     = function() ui.Refresh() end,
        onComplete = function(stats) ui.OnScanComplete(stats) end,
    })
    ui.Refresh()
end

function ui.StartFullScan()
    ui.StartScan({})
end

function ui.OnScanComplete(stats)
    ui.Refresh()
    ChatMsg(string.format(
        "Aegis: scan complete \226\128\148 %d auctions across %d pages in %s.",
        stats.auctions, stats.pages, util.FormatDuration(stats.duration)))
end

-- State -> scan strip widgets.
function ui.Refresh()
    if not ui.frame then return end
    local p = A.scan.GetProgress()
    local last = A.db.GetLastScan()

    if p.phase == "wait_query" or p.phase == "wait_results" then
        ui.fullScanBtn:Disable()
        ui.pauseBtn:Enable()
        ui.resumeBtn:Disable()
        local totalPages = p.totalPages
        if totalPages < 1 then totalPages = 1 end
        ui.bar:SetMinMaxValues(0, totalPages)
        ui.bar:SetValue(p.pagesDone)
        ui.bar:Show()
        if p.totalPages > 0 then
            local pageText = string.format(
                "Page %d / %d \226\128\162 ~%s \226\128\162 %s/s",
                p.page, p.totalPages, util.FormatDuration(p.eta),
                string.format("%.1f", p.rate))
            if p.catCount > 1 then
                pageText = string.format("Cat %d / %d \226\128\162 ",
                    p.catIndex, p.catCount) .. pageText
            end
            if p.retries > 0 then
                pageText = pageText
                    .. string.format(" (retry %d)", p.retries)
            end
            ui.statusText:SetText(pageText)
        else
            -- Still before the first page. Say WHICH leg we're on so a stall
            -- is diagnosable from the strip alone (see /aex debug for the
            -- full trace).
            if p.sent == 0 then
                ui.statusText:SetText(
                    "Starting scan \226\128\148 waiting for client...")
            elseif p.retries > 0 then
                ui.statusText:SetText(string.format(
                    "Requesting first page... (no reply \226\128\148 retry %d)",
                    p.retries))
            else
                ui.statusText:SetText("Requesting first page...")
            end
        end
        ui.statusText:SetTextColor(C.text[1], C.text[2], C.text[3])
    elseif p.phase == "paused" then
        ui.fullScanBtn:Enable()
        ui.pauseBtn:Disable()
        ui.resumeBtn:Enable()
        ui.bar:Show()
        ui.statusText:SetText(string.format(
            "Paused at page %d / %d", p.pagesDone, p.totalPages))
        ui.statusText:SetTextColor(C.amber[1], C.amber[2], C.amber[3])
    else
        ui.fullScanBtn:Enable()
        ui.pauseBtn:Disable()
        ui.resumeBtn:Disable()
        ui.bar:Hide()
        if last and last.when then
            local age = time() - last.when
            local kind = ""
            if not last.full then kind = " (targeted)" end
            if age > STALE_SECONDS then
                ui.statusText:SetText("Last scan: " .. util.FormatAgo(age)
                    .. kind .. " \226\128\148 may be outdated")
                ui.statusText:SetTextColor(C.amber[1], C.amber[2], C.amber[3])
            else
                ui.statusText:SetText(
                    "Last scan: " .. util.FormatAgo(age) .. kind)
                ui.statusText:SetTextColor(C.text[1], C.text[2], C.text[3])
            end
        else
            ui.statusText:SetText("Last scan: never")
            ui.statusText:SetTextColor(C.text[1], C.text[2], C.text[3])
        end
    end
end

-- ---------------------------------------------------------------------------
-- Shared input helpers (used by the Buy and Sell tabs)
-- ---------------------------------------------------------------------------

-- A money entry box. Accepts "1g 50s 20c" style text (util.ParseMoney). The
-- caller can override OnTextChanged; the Sell tab wires it to ui.RefreshSell.
local function MakeMoneyBox(parent, width)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetWidth(width)
    e:SetHeight(18)
    e:SetAutoFocus(false)   -- InputBoxTemplate already provides the font
    e:SetScript("OnEnterPressed", function() e:ClearFocus() end)
    e:SetScript("OnEscapePressed", function() e:ClearFocus() end)
    e:SetScript("OnTextChanged", function()
        if ui.RefreshSell then ui.RefreshSell() end
    end)
    return e
end

local function ReadMoneyBox(e)
    local txt = util.Trim(e:GetText() or "")
    if txt == "" then return nil end
    return util.ParseMoney(txt)
end

local function SetMoneyBox(e, copper)
    if copper and copper > 0 then
        e:SetText(util.FormatMoney(copper))
    else
        e:SetText("")
    end
end

-- A small numeric entry box (stack size / number of stacks).
local function MakeNumBox(parent, width, onChanged)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetWidth(width)
    e:SetHeight(18)
    e:SetAutoFocus(false)
    e:SetNumeric(true)
    e:SetJustifyH("CENTER")
    e:SetScript("OnEnterPressed", function() e:ClearFocus() end)
    e:SetScript("OnEscapePressed", function() e:ClearFocus() end)
    e:SetScript("OnTextChanged", onChanged)
    return e
end

local function NumVal(e, default)
    local n = tonumber(e:GetText())
    if not n or n < 1 then return default end
    return math.floor(n)
end

-- ---------------------------------------------------------------------------
-- Buy tab: shopping-list sidebar + search + browse + buy / bid
-- ---------------------------------------------------------------------------

-- "% of market" cell colours. The two tabs want OPPOSITE signals:
--   Buy  -- cheap is good: under 100% = green, at 100% = yellow, over = red.
--   Sell -- dear is good: under 100% = red,   at 100% = yellow, over = green.
local function PctColorBuy(pct)
    if pct < 100 then
        return 0.35, 0.85, 0.35   -- under 100%: green (a deal)
    elseif pct == 100 then
        return 0.90, 0.82, 0.35   -- at 100%: yellow
    end
    return 0.90, 0.38, 0.38       -- over 100%: red (overpriced)
end
local function PctColorSell(pct)
    if pct < 100 then
        return 0.90, 0.38, 0.38   -- under 100%: red (selling cheap)
    elseif pct == 100 then
        return 0.90, 0.82, 0.35   -- at 100%: yellow
    end
    return 0.35, 0.85, 0.35       -- over 100%: green (selling high)
end
ui.PctColorBuy = PctColorBuy     -- exposed for tests
ui.PctColorSell = PctColorSell

-- Shared result-row column layout (Buy tab AND Crafting tab), row-relative.
local RCX = { name = 2, ct = 178, unit = 210, stack = 296, pct = 390,
              buy = 436, bid = 490 }
local RCW = { name = 172, ct = 26, unit = 82, stack = 90, pct = 40 }

-- Build a listing result row (name/ct/unit/stack/pct + Buy/Bid) into `store`.
-- Buttons act on row.entry, so the same rows serve Buy and Crafting.
local function BuildResultRow(parent, scroll, store, i, rowH)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(rowH)
    if i == 1 then
        row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
        row:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, 0)
    else
        row:SetPoint("TOPLEFT", store[i - 1], "BOTTOMLEFT", 0, 0)
        row:SetPoint("TOPRIGHT", store[i - 1], "BOTTOMRIGHT", 0, 0)
    end
    local mkCell = function(x, w, just)
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", row, "LEFT", x, 0)
        fs:SetWidth(w)
        fs:SetJustifyH(just or "LEFT")
        return fs
    end
    -- Item icon, then the name shifted to its right.
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(16); icon:SetHeight(16)
    icon:SetPoint("LEFT", row, "LEFT", RCX.name, 0)
    row.icon = icon
    row.name  = mkCell(RCX.name + 20, RCW.name - 20)
    row.ct    = mkCell(RCX.ct, RCW.ct, "RIGHT")
    row.unit  = mkCell(RCX.unit, RCW.unit)
    row.stack = mkCell(RCX.stack, RCW.stack)
    row.pct   = mkCell(RCX.pct, RCW.pct)
    local buyBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    buyBtn:SetWidth(50); buyBtn:SetHeight(17)
    buyBtn:SetPoint("LEFT", row, "LEFT", RCX.buy, 0)
    buyBtn:SetText("Buy")
    buyBtn:SetScript("OnClick", function()
        if row.entry then ui.ConfirmBuyout(row.entry) end
    end)
    row.buyBtn = buyBtn
    local bidBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    bidBtn:SetWidth(44); bidBtn:SetHeight(17)
    bidBtn:SetPoint("LEFT", row, "LEFT", RCX.bid, 0)
    bidBtn:SetText("Bid")
    bidBtn:SetScript("OnClick", function()
        if row.entry then ui.ConfirmBid(row.entry) end
    end)
    row.bidBtn = bidBtn
    row:Hide()
    store[i] = row
    return row
end

-- Fill a result row's content from a listing `r` (shared by Buy and Crafting).
function ui.FillResultRow(row, r)
    row.entry = r
    if row.icon then
        if r.texture then
            row.icon:SetTexture(r.texture); row.icon:Show()
        else
            row.icon:Hide()
        end
    end
    row.name:SetText(r.name)
    if r.canUse == nil or r.canUse then
        row.name:SetTextColor(C.text[1], C.text[2], C.text[3])
    else
        row.name:SetTextColor(0.9, 0.4, 0.4)
    end
    row.ct:SetText("x" .. r.count)
    row.unit:SetText(r.unit and util.FormatMoney(r.unit, true) or "\226\128\148")
    if r.buyout and r.buyout > 0 then
        row.stack:SetText(util.FormatMoney(r.buyout, true))
    else
        -- Bid-only auction: show the current/next bid instead of just "bid only".
        local nb = r.nextBid or r.minBid or 0
        if nb > 0 then
            row.stack:SetText("bid " .. util.FormatMoney(nb, true))
        else
            row.stack:SetText("bid only")
        end
    end
    local market = r.itemId and A.db.MarketValue(r.itemId)
    if market and market > 0 and r.unit then
        local pct = math.floor(r.unit / market * 100)
        row.pct:SetText(pct .. "%")
        row.pct:SetTextColor(PctColorBuy(pct))
    else
        row.pct:SetText("\226\128\148")
        row.pct:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
    end
    if r.mine then
        row.buyBtn:Disable(); row.bidBtn:Disable()
    else
        if r.buyout and r.buyout > 0 then row.buyBtn:Enable()
        else row.buyBtn:Disable() end
        row.bidBtn:Enable()
    end
    row:Show()
end

-- Sort a working copy of `all` by column key/direction, applying an optional
-- per-unit Max filter. Shared by the Buy and Crafting result panes so both
-- handle bid-only rows (no buyout) and % market the same way.
function ui.SortResults(all, sortKey, dir, maxUnit)
    local rows = {}
    local k = 1
    while k <= table.getn(all) do
        local r = all[k]
        if not (maxUnit and maxUnit > 0) or (r.unit and r.unit <= maxUnit) then
            table.insert(rows, r)
        end
        k = k + 1
    end
    local function keyOf(r)
        if sortKey == "stack" then
            return (r.buyout and r.buyout > 0) and r.buyout or nil
        elseif sortKey == "pct" then
            local m = r.itemId and A.db.MarketValue(r.itemId)
            if m and m > 0 and r.unit then return r.unit / m end
            return nil
        end
        return r.unit
    end
    table.sort(rows, function(a, b)
        local av, bv = keyOf(a), keyOf(b)
        if not av and not bv then return false end
        if not av then return false end   -- no price -> always last
        if not bv then return true end
        if dir == "desc" then return av > bv end
        return av < bv
    end)
    return rows
end

-- Put a ↑/↓ arrow on whichever sort header is active (shared Buy/Crafting).
function ui.PaintSortHeaders(headers, sortKey, dir)
    if not headers then return end
    for hk, hb in pairs(headers) do
        local t = hb.baseText
        if hk == sortKey then
            t = t .. (dir == "asc" and " \226\134\145" or " \226\134\147")
        end
        hb.label:SetText(t)
    end
end

local BUY_ROWS,  BUY_ROW_H  = 11, 20
local SIDE_ROWS, SIDE_ROW_H = 13, 18
local SIDE_W = 158    -- sidebar width

function ui.BuildBuyTab()
    local panel = ui.panels["Buy"]
    if not panel or ui.buyBuilt then return end
    ui.buyBuilt = true
    ui.buyExpanded = {}

    -- ===== Left: shopping-list sidebar ==================================
    local sideHdr = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sideHdr:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -10)
    sideHdr:SetText("Shopping Lists")
    sideHdr:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    local sideScroll = CreateFrame("ScrollFrame", "AegisExchangeBuySideScroll",
        panel, "FauxScrollFrameTemplate")
    sideScroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -28)
    sideScroll:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 62)
    sideScroll:SetWidth(SIDE_W)
    sideScroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(SIDE_ROW_H, ui.UpdateBuySidebar)
    end)
    ui.buySideScroll = sideScroll

    ui.buySideRows = {}
    local i = 1
    while i <= SIDE_ROWS do
        local row = CreateFrame("Button", nil, panel)
        row:SetHeight(SIDE_ROW_H)
        row:SetWidth(SIDE_W)
        if i == 1 then
            row:SetPoint("TOPLEFT", sideScroll, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", ui.buySideRows[i - 1], "BOTTOMLEFT", 0, 0)
        end
        local ex = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        ex:SetPoint("LEFT", row, "LEFT", 2, 0)
        ex:SetWidth(12)
        ex:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
        row.ex = ex
        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("LEFT", row, "LEFT", 14, 0)
        lbl:SetWidth(SIDE_W - 16)
        lbl:SetJustifyH("LEFT")
        row.label = lbl
        row:SetScript("OnClick", function() ui.OnBuySideClick(row.entry) end)
        row:Hide()
        ui.buySideRows[i] = row
        i = i + 1
    end

    -- Sidebar action buttons.
    local addBtn = CreateFrame("Button", "AegisExchangeBuyAddListButton",
        panel, "UIPanelButtonTemplate")
    addBtn:SetWidth(50); addBtn:SetHeight(18)
    addBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 40)
    addBtn:SetText("+ Add")
    addBtn:SetScript("OnClick", function() ui.BuyAddList() end)

    local renBtn = CreateFrame("Button", "AegisExchangeBuyRenameButton",
        panel, "UIPanelButtonTemplate")
    renBtn:SetWidth(56); renBtn:SetHeight(18)
    renBtn:SetPoint("LEFT", addBtn, "RIGHT", 4, 0)
    renBtn:SetText("Rename")
    renBtn:SetScript("OnClick", function() ui.BuyRenameList() end)

    local delBtn = CreateFrame("Button", "AegisExchangeBuyDelButton",
        panel, "UIPanelButtonTemplate")
    delBtn:SetWidth(40); delBtn:SetHeight(18)
    delBtn:SetPoint("LEFT", renBtn, "RIGHT", 4, 0)
    delBtn:SetText("Del")
    delBtn:SetScript("OnClick", function() ui.BuyDeleteList() end)

    local listSearchBtn = CreateFrame("Button", "AegisExchangeBuyListSearchButton",
        panel, "UIPanelButtonTemplate")
    listSearchBtn:SetWidth(SIDE_W); listSearchBtn:SetHeight(18)
    listSearchBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 20)
    listSearchBtn:SetText("Search entire list")
    listSearchBtn:SetScript("OnClick", function() ui.BuySearchList() end)
    ui.buyListSearchBtn = listSearchBtn

    -- ===== Right: filter row + results ==================================
    local RX = SIDE_W + 24    -- right-column origin

    local box = CreateFrame("EditBox", "AegisExchangeBuySearchBox", panel,
        "InputBoxTemplate")
    box:SetWidth(180); box:SetHeight(18)
    box:SetPoint("TOPLEFT", panel, "TOPLEFT", RX + 6, -12)
    box:SetAutoFocus(false)
    box:SetScript("OnEnterPressed", function() ui.DoBuySearch() end)
    box:SetScript("OnEscapePressed", function() box:ClearFocus() end)
    ui.buyBox = box

    local maxLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    maxLbl:SetPoint("LEFT", box, "RIGHT", 8, 0)
    maxLbl:SetText("Max")
    ui.buyMax = MakeMoneyBox(panel, 78)
    ui.buyMax:SetPoint("LEFT", maxLbl, "RIGHT", 4, 0)
    ui.buyMax:SetScript("OnTextChanged", function() ui.UpdateBuyList() end)

    local searchBtn = CreateFrame("Button", "AegisExchangeBuySearchButton",
        panel, "UIPanelButtonTemplate")
    searchBtn:SetWidth(64); searchBtn:SetHeight(20)
    searchBtn:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -6)
    searchBtn:SetText("Search")
    searchBtn:SetScript("OnClick", function() ui.DoBuySearch() end)
    ui.buySearchBtn = searchBtn

    local addToList = CreateFrame("Button", "AegisExchangeBuyAddToListButton",
        panel, "UIPanelButtonTemplate")
    addToList:SetWidth(90); addToList:SetHeight(20)
    addToList:SetPoint("LEFT", searchBtn, "RIGHT", 6, 0)
    addToList:SetText("Add to list")
    addToList:SetScript("OnClick", function() ui.BuyAddSearchToList() end)

    -- Pager.
    local nextBtn = CreateFrame("Button", "AegisExchangeBuyNextButton",
        panel, "UIPanelButtonTemplate")
    nextBtn:SetWidth(24); nextBtn:SetHeight(20)
    nextBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -12)
    nextBtn:SetText(">")
    nextBtn:SetScript("OnClick", function() if A.buy then A.buy.NextPage() end end)

    ui.buyPageText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.buyPageText:SetPoint("RIGHT", nextBtn, "LEFT", -6, 0)
    ui.buyPageText:SetJustifyH("RIGHT")
    ui.buyPageText:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])

    local prevBtn = CreateFrame("Button", "AegisExchangeBuyPrevButton",
        panel, "UIPanelButtonTemplate")
    prevBtn:SetWidth(24); prevBtn:SetHeight(20)
    prevBtn:SetPoint("RIGHT", ui.buyPageText, "LEFT", -6, 0)
    prevBtn:SetText("<")
    prevBtn:SetScript("OnClick", function() if A.buy then A.buy.PrevPage() end end)

    ui.buyStatus = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.buyStatus:SetPoint("TOPLEFT", searchBtn, "BOTTOMLEFT", 0, -8)
    ui.buyStatus:SetJustifyH("LEFT")
    ui.buyStatus:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    ui.buyStatus:SetText("Type an item name and Search.")

    -- Column layout (row-relative x, width). Sized so Buy+Bid finish well
    -- before the scrollbar. The unit / stack / % headers are clickable to sort.
    ui.buySortKey = "unit"
    ui.buySortDir = "asc"
    local rowLeft = RX + 4
    local CX = { name = 2, ct = 178, unit = 210, stack = 296, pct = 390,
                 buy = 436, bid = 490 }
    local CW = { name = 172, ct = 26, unit = 82, stack = 90, pct = 40 }

    local mkText = function(cx, text)
        local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("TOPLEFT", panel, "TOPLEFT", rowLeft + cx, -78)
        fs:SetText(text)
        return fs
    end
    mkText(CX.name, "Item")
    mkText(CX.ct, "Ct")

    ui.buyHeaders = {}
    local mkSort = function(cx, w, text, key)
        local b = CreateFrame("Button", nil, panel)
        b:SetPoint("TOPLEFT", panel, "TOPLEFT", rowLeft + cx, -76)
        b:SetWidth(w + 14); b:SetHeight(16)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("LEFT", b, "LEFT", 0, 0)
        fs:SetText(text)
        b.label = fs
        b.baseText = text
        b:SetScript("OnClick", function() ui.SetBuySort(key) end)
        ui.buyHeaders[key] = b
        return b
    end
    mkSort(CX.unit, CW.unit, "Unit price", "unit")
    mkSort(CX.stack, CW.stack, "Stack buyout", "stack")
    mkSort(CX.pct, CW.pct, "% mkt", "pct")

    local scroll = CreateFrame("ScrollFrame", "AegisExchangeBuyScroll",
        panel, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", rowLeft, -94)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, 10)
    scroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(BUY_ROW_H, ui.UpdateBuyList)
    end)
    ui.buyScroll = scroll

    ui.buyRows = {}
    i = 1
    while i <= BUY_ROWS do
        BuildResultRow(panel, scroll, ui.buyRows, i, BUY_ROW_H)
        i = i + 1
    end

    ui.RefreshBuySidebar()
end

-- ---- sidebar model + paint ---------------------------------------------

function ui.FlattenShopping()
    local flat = {}
    table.insert(flat, { kind = "hdr", text = "LISTS" })
    local lists = A.buy and A.buy.Lists() or {}
    local li = 1
    while li <= table.getn(lists) do
        local L = lists[li]
        table.insert(flat, { kind = "list", index = li, name = L.name })
        if ui.buyExpanded[li] then
            local ii = 1
            while ii <= table.getn(L.items) do
                table.insert(flat, { kind = "item", listIndex = li,
                    name = L.items[ii] })
                ii = ii + 1
            end
            if table.getn(L.items) == 0 then
                table.insert(flat, { kind = "note", text = "(empty)" })
            end
        end
        li = li + 1
    end
    table.insert(flat, { kind = "hdr", text = "RECENT" })
    local recent = A.buy and A.buy.Recent() or {}
    local ri = 1
    while ri <= table.getn(recent) do
        table.insert(flat, { kind = "recent", name = recent[ri] })
        ri = ri + 1
    end
    ui.buyFlat = flat
end

function ui.RefreshBuySidebar()
    if not ui.buySideScroll then return end
    ui.FlattenShopping()
    ui.UpdateBuySidebar()
end

function ui.UpdateBuySidebar()
    if not ui.buySideScroll then return end
    local flat = ui.buyFlat or {}
    FauxScrollFrame_Update(ui.buySideScroll, table.getn(flat), SIDE_ROWS, SIDE_ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.buySideScroll)
    local i = 1
    while i <= SIDE_ROWS do
        local row = ui.buySideRows[i]
        local e = flat[i + offset]
        if e then
            row.entry = e
            row.ex:SetText("")
            if e.kind == "hdr" then
                row.label:SetText(e.text)
                row.label:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
            elseif e.kind == "list" then
                row.ex:SetText(ui.buyExpanded[e.index] and "-" or "+")
                local mark = ""
                if ui.buySelList == e.index then mark = "> " end
                row.label:SetText(mark .. e.name)
                if ui.buySelList == e.index then
                    row.label:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
                else
                    row.label:SetTextColor(C.text[1], C.text[2], C.text[3])
                end
            elseif e.kind == "item" then
                row.label:SetText("  " .. e.name)
                row.label:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
            elseif e.kind == "recent" then
                row.label:SetText(e.name)
                row.label:SetTextColor(C.text[1], C.text[2], C.text[3])
            else
                row.label:SetText("  " .. (e.text or ""))
                row.label:SetTextColor(0.5, 0.5, 0.5)
            end
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
        i = i + 1
    end
end

function ui.OnBuySideClick(e)
    if not e then return end
    if e.kind == "list" then
        ui.buySelList = e.index
        ui.buyExpanded[e.index] = not ui.buyExpanded[e.index]
        ui.RefreshBuySidebar()
    elseif e.kind == "item" then
        ui.buyBox:SetText(e.name)
        ui.DoBuySearch()
    elseif e.kind == "recent" then
        ui.buyBox:SetText(e.name)
        ui.DoBuySearch()
    end
end

-- ---- list management (via a name-entry popup) --------------------------

StaticPopupDialogs["AEGIS_EXCHANGE_LISTNAME"] = {
    text = "%s",
    button1 = "OK",
    button2 = "Cancel",
    hasEditBox = 1,
    maxLetters = 40,
    OnAccept = function()
        local eb = getglobal(this:GetParent():GetName() .. "EditBox")
        ui.OnListNameEntered(eb and eb:GetText() or "")
    end,
    EditBoxOnEnterPressed = function()
        local eb = this
        ui.OnListNameEntered(eb:GetText() or "")
        eb:GetParent():Hide()
    end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

function ui.OnListNameEntered(text)
    text = util.Trim(text or "")
    if text == "" then return end
    if ui.listNameMode == "add" then
        local list = A.buy and A.buy.AddList(text)
        if list then ui.buySelList = table.getn(A.buy.Lists()) end
    elseif ui.listNameMode == "rename" and ui.buySelList then
        if A.buy then A.buy.RenameList(ui.buySelList, text) end
    end
    ui.RefreshBuySidebar()
end

function ui.BuyAddList()
    if not A.buy then return end
    ui.listNameMode = "add"
    StaticPopup_Show("AEGIS_EXCHANGE_LISTNAME", "Name for the new shopping list:")
end

function ui.BuyRenameList()
    if not A.buy or not ui.buySelList then
        ChatMsg("Aegis: select a list first.")
        return
    end
    ui.listNameMode = "rename"
    StaticPopup_Show("AEGIS_EXCHANGE_LISTNAME", "Rename this shopping list:")
end

function ui.BuyDeleteList()
    if not A.buy or not ui.buySelList then
        ChatMsg("Aegis: select a list first.")
        return
    end
    A.buy.DeleteList(ui.buySelList)
    ui.buySelList = nil
    ui.RefreshBuySidebar()
end

function ui.BuyAddSearchToList()
    if not A.buy then return end
    if not ui.buySelList then
        ChatMsg("Aegis: select a list on the left first.")
        return
    end
    local term = util.Trim(ui.buyBox:GetText() or "")
    if term == "" then
        ChatMsg("Aegis: type an item name to add.")
        return
    end
    if A.buy.AddItemToList(ui.buySelList, term) then
        ChatMsg("Aegis: added '" .. term .. "' to the list.")
    end
    ui.buyExpanded[ui.buySelList] = true
    ui.RefreshBuySidebar()
end

-- Search each item in the selected list, one after another. Only the LAST
-- item's results stay on the AH page (and are buyable); the rest just warm the
-- price DB. A convenience for reviewing a whole list's prices.
function ui.BuySearchList()
    if not A.buy or not ui.buySelList then
        ChatMsg("Aegis: select a list first.")
        return
    end
    local list = A.buy.Lists()[ui.buySelList]
    if not list or table.getn(list.items) == 0 then
        ChatMsg("Aegis: that list is empty.")
        return
    end
    ui.buyListQueue = {}
    local i = 1
    while i <= table.getn(list.items) do
        table.insert(ui.buyListQueue, list.items[i])
        i = i + 1
    end
    ui.BuyRunListQueue()
end

function ui.BuyRunListQueue()
    if not ui.buyListQueue or table.getn(ui.buyListQueue) == 0 then
        ui.buyListQueue = nil
        return
    end
    local term = table.remove(ui.buyListQueue, 1)
    ui.buyBox:SetText(term)
    A.buy.Search(term, {
        onResults = function(rows)
            ui.buyResults = rows
            ui.UpdateBuyList()
            if ui.buyListQueue and table.getn(ui.buyListQueue) > 0 then
                ui.BuyRunListQueue()   -- next item
            else
                ui.RefreshBuySidebar()
            end
        end,
        onState = function() ui.RefreshBuyStatus() end,
    })
end

-- ---- search + results --------------------------------------------------

function ui.DoBuySearch()
    if not ui.buyBox then return end
    ui.buyBox:ClearFocus()
    if not A.buy then
        ui.buyStatus:SetText("Buy engine not loaded \226\128\148 fully restart WoW.")
        return
    end
    local name = util.Trim(ui.buyBox:GetText() or "")
    ui.buyResults = nil
    ui.UpdateBuyList()
    local ok, err = A.buy.Search(name, {
        onResults = function(rows) ui.buyResults = rows; ui.UpdateBuyList() end,
        onState = function() ui.RefreshBuyStatus() end,
    })
    if not ok then
        ui.buyStatus:SetText(err or "Could not search.")
    else
        ui.buyStatus:SetText("Searching...")
    end
    ui.RefreshBuySidebar()   -- recent search list changed
end

function ui.RefreshBuyStatus()
    if not ui.buyStatus or not A.buy then return end
    local phase = A.buy.state.phase
    if phase == "wait_query" or phase == "wait_results" then
        ui.buyStatus:SetText("Searching...")
    end
end

function ui.RefreshBuy()
    if not ui.buyBuilt then return end
    ui.RefreshBuySidebar()
    ui.UpdateBuyList()
end

function ui.UpdateBuyList()
    if not ui.buyScroll then return end
    local all = ui.buyResults or {}

    -- Working copy (so sorting doesn't disturb the engine's row order), with
    -- the Max-price filter (per-unit) applied and the chosen column sort.
    local maxUnit = ui.buyMax and util.ParseMoney(util.Trim(ui.buyMax:GetText() or ""))
    local sortKey = ui.buySortKey or "unit"
    local dir = ui.buySortDir or "asc"
    local rows = ui.SortResults(all, sortKey, dir, maxUnit)
    ui.PaintSortHeaders(ui.buyHeaders, sortKey, dir)

    local total = table.getn(rows)
    FauxScrollFrame_Update(ui.buyScroll, total, BUY_ROWS, BUY_ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.buyScroll)

    if A.buy then
        local _, page, totalPages, totalAuctions = A.buy.GetResults()
        if ui.buyResults then
            if table.getn(all) == 0 then
                ui.buyStatus:SetText("No auctions found.")
            else
                local order = dir == "asc" and "low to high" or "high to low"
                local shown = ""
                if maxUnit and maxUnit > 0 then
                    shown = " \226\128\162 " .. total .. " under max"
                end
                ui.buyStatus:SetText(totalAuctions .. " auction(s) \226\128\162 "
                    .. sortKey .. " " .. order .. shown)
            end
            ui.buyPageText:SetText("Page " .. (page + 1) .. " / " .. totalPages)
        else
            ui.buyPageText:SetText("")
        end
    end

    local i = 1
    while i <= BUY_ROWS do
        local row = ui.buyRows[i]
        local r = rows[i + offset]
        if r then
            ui.FillResultRow(row, r)
        else
            row.entry = nil
            row:Hide()
        end
        i = i + 1
    end
end

-- Click a sortable header: same column toggles direction, a new column resets
-- to ascending. Re-renders the current results.
function ui.SetBuySort(key)
    if ui.buySortKey == key then
        ui.buySortDir = (ui.buySortDir == "asc") and "desc" or "asc"
    else
        ui.buySortKey = key
        ui.buySortDir = "asc"
    end
    ui.UpdateBuyList()
end

StaticPopupDialogs["AEGIS_EXCHANGE_BUYOUT"] = {
    text = "Buy %s?\n%s",
    button1 = "Buy", button2 = "Cancel",
    OnAccept = function() ui.DoBuyout() end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

StaticPopupDialogs["AEGIS_EXCHANGE_BID"] = {
    text = "Bid on %s?\n%s",
    button1 = "Bid", button2 = "Cancel",
    OnAccept = function() ui.DoBid() end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

function ui.ConfirmBuyout(row)
    if row.mine then ChatMsg("Aegis: that's your own auction."); return end
    if not (row.buyout and row.buyout > 0) then
        ChatMsg("Aegis: that auction has no buyout.")
        return
    end
    ui.pendingBuy = row
    local detail = string.format("%d x %s \226\128\162 buyout %s",
        row.count, row.name, util.FormatMoney(row.buyout))
    StaticPopup_Show("AEGIS_EXCHANGE_BUYOUT",
        row.name .. " (x" .. row.count .. ")", detail)
end

function ui.DoBuyout()
    local row = ui.pendingBuy
    ui.pendingBuy = nil
    if not row or not A.buy then return end
    local ok, err = A.buy.Buyout(row)
    if not ok then
        ChatMsg("Aegis: " .. (err or "buyout failed."))
    else
        ChatMsg("Aegis: bought " .. row.name .. " x" .. row.count .. ".")
    end
end

function ui.ConfirmBid(row)
    if row.mine then ChatMsg("Aegis: that's your own auction."); return end
    ui.pendingBid = row
    local detail = string.format("%d x %s \226\128\162 bid %s",
        row.count, row.name, util.FormatMoney(row.nextBid))
    StaticPopup_Show("AEGIS_EXCHANGE_BID",
        row.name .. " (x" .. row.count .. ")", detail)
end

function ui.DoBid()
    local row = ui.pendingBid
    ui.pendingBid = nil
    if not row or not A.buy then return end
    local ok, err = A.buy.Bid(row, row.nextBid)
    if not ok then
        ChatMsg("Aegis: " .. (err or "bid failed."))
    else
        ChatMsg("Aegis: bid on " .. row.name .. ".")
    end
end

-- ---------------------------------------------------------------------------
-- Crafting tab: recipes captured from a profession window, their reagents, and
-- a Buy-style price/buy pane for whichever reagent you click.
--
-- Left  = recipe tree (project -> its reagents, expandable).
-- Right = the same searchable result list as the Buy tab (shared row helpers),
--         populated when you click a reagent.
-- ---------------------------------------------------------------------------

local CRAFT_ROWS,  CRAFT_ROW_H  = 11, 20
local CSIDE_ROWS,  CSIDE_ROW_H  = 10, 18
local CSIDE_W = 172   -- recipe-tree width (reagent lines carry a count)

function ui.BuildCraftTab()
    local panel = ui.panels["Crafting"]
    if not panel or ui.craftBuilt then return end
    ui.craftBuilt = true
    ui.craftExpanded = {}

    -- ===== Left: recipe tree ============================================
    local sideHdr = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sideHdr:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -10)
    sideHdr:SetText("Recipes")
    sideHdr:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    local sideScroll = CreateFrame("ScrollFrame", "AegisExchangeCraftSideScroll",
        panel, "FauxScrollFrameTemplate")
    sideScroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -28)
    sideScroll:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 132)
    sideScroll:SetWidth(CSIDE_W)
    sideScroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(CSIDE_ROW_H, ui.UpdateCraftTree)
    end)
    ui.craftSideScroll = sideScroll

    ui.craftSideRows = {}
    local i = 1
    while i <= CSIDE_ROWS do
        local row = CreateFrame("Button", nil, panel)
        row:SetHeight(CSIDE_ROW_H)
        row:SetWidth(CSIDE_W)
        if i == 1 then
            row:SetPoint("TOPLEFT", sideScroll, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", ui.craftSideRows[i - 1], "BOTTOMLEFT", 0, 0)
        end
        local ex = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        ex:SetPoint("LEFT", row, "LEFT", 2, 0)
        ex:SetWidth(12)
        ex:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
        row.ex = ex
        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("LEFT", row, "LEFT", 14, 0)
        lbl:SetWidth(CSIDE_W - 40)
        lbl:SetJustifyH("LEFT")
        row.label = lbl
        local ct = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        ct:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        ct:SetWidth(24)
        ct:SetJustifyH("RIGHT")
        row.ct = ct
        row:SetScript("OnClick", function() ui.OnCraftTreeClick(row.entry) end)
        row:Hide()
        ui.craftSideRows[i] = row
        i = i + 1
    end

    -- Profit estimate for the selected recipe (buy mats -> craft -> resell).
    local estHdr = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    estHdr:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 116)
    estHdr:SetText("Profit estimate")
    estHdr:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    ui.craftCostFS = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.craftCostFS:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 100)
    ui.craftCostFS:SetWidth(CSIDE_W); ui.craftCostFS:SetJustifyH("LEFT")

    ui.craftValueFS = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.craftValueFS:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 84)
    ui.craftValueFS:SetWidth(CSIDE_W); ui.craftValueFS:SetJustifyH("LEFT")

    ui.craftNetFS = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.craftNetFS:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 64)
    ui.craftNetFS:SetWidth(CSIDE_W); ui.craftNetFS:SetJustifyH("LEFT")

    -- Fill the DB with a fresh price for the crafted item and every reagent.
    local priceBtn = CreateFrame("Button", "AegisExchangeCraftPriceButton",
        panel, "UIPanelButtonTemplate")
    priceBtn:SetWidth(CSIDE_W); priceBtn:SetHeight(18)
    priceBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 42)
    priceBtn:SetText("Price recipe")
    priceBtn:SetScript("OnClick", function() ui.CraftPriceRecipe() end)
    ui.craftPriceBtn = priceBtn

    -- Delete the selected recipe.
    local delBtn = CreateFrame("Button", "AegisExchangeCraftDelButton",
        panel, "UIPanelButtonTemplate")
    delBtn:SetWidth(CSIDE_W); delBtn:SetHeight(18)
    delBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 20)
    delBtn:SetText("Remove recipe")
    delBtn:SetScript("OnClick", function() ui.CraftDeleteProject() end)
    ui.craftDelBtn = delBtn

    -- ===== Right: reagent title + result list ============================
    local RX = CSIDE_W + 24

    ui.craftTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    ui.craftTitle:SetPoint("TOPLEFT", panel, "TOPLEFT", RX + 6, -10)
    ui.craftTitle:SetText("Crafting")
    ui.craftTitle:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    local box = CreateFrame("EditBox", "AegisExchangeCraftSearchBox", panel,
        "InputBoxTemplate")
    box:SetWidth(180); box:SetHeight(18)
    box:SetPoint("TOPLEFT", panel, "TOPLEFT", RX + 6, -34)
    box:SetAutoFocus(false)
    box:SetScript("OnEnterPressed", function() ui.DoCraftSearch() end)
    box:SetScript("OnEscapePressed", function() box:ClearFocus() end)
    ui.craftBox = box

    -- Search button sits to the RIGHT of the box (not below it), so the yellow
    -- label never lands on the "Item" column header underneath.
    local searchBtn = CreateFrame("Button", "AegisExchangeCraftSearchButton",
        panel, "UIPanelButtonTemplate")
    searchBtn:SetWidth(64); searchBtn:SetHeight(20)
    searchBtn:SetPoint("LEFT", box, "RIGHT", 10, 0)
    searchBtn:SetText("Search")
    searchBtn:SetScript("OnClick", function() ui.DoCraftSearch() end)

    -- Pager (mirrors the Buy tab).
    local nextBtn = CreateFrame("Button", "AegisExchangeCraftNextButton",
        panel, "UIPanelButtonTemplate")
    nextBtn:SetWidth(24); nextBtn:SetHeight(20)
    nextBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -34)
    nextBtn:SetText(">")
    nextBtn:SetScript("OnClick", function() if A.buy then A.buy.NextPage() end end)

    ui.craftPageText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.craftPageText:SetPoint("RIGHT", nextBtn, "LEFT", -6, 0)
    ui.craftPageText:SetJustifyH("RIGHT")
    ui.craftPageText:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])

    local prevBtn = CreateFrame("Button", "AegisExchangeCraftPrevButton",
        panel, "UIPanelButtonTemplate")
    prevBtn:SetWidth(24); prevBtn:SetHeight(20)
    prevBtn:SetPoint("RIGHT", ui.craftPageText, "LEFT", -6, 0)
    prevBtn:SetText("<")
    prevBtn:SetScript("OnClick", function() if A.buy then A.buy.PrevPage() end end)

    ui.craftStatus = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.craftStatus:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -8)
    ui.craftStatus:SetJustifyH("LEFT")
    ui.craftStatus:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    ui.craftStatus:SetText("Click a reagent on the left to shop for it.")

    -- Sortable column headers (same layout / behaviour as the Buy tab).
    ui.craftSortKey = "unit"
    ui.craftSortDir = "asc"
    local rowLeft = RX + 4
    local CX = { name = 2, ct = 178, unit = 210, stack = 296, pct = 390,
                 buy = 436, bid = 490 }
    local CW = { name = 172, ct = 26, unit = 82, stack = 90, pct = 40 }

    local mkText = function(cx, text)
        local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("TOPLEFT", panel, "TOPLEFT", rowLeft + cx, -78)
        fs:SetText(text)
        return fs
    end
    mkText(CX.name, "Item")
    mkText(CX.ct, "Ct")

    ui.craftHeaders = {}
    local mkSort = function(cx, w, text, key)
        local b = CreateFrame("Button", nil, panel)
        b:SetPoint("TOPLEFT", panel, "TOPLEFT", rowLeft + cx, -76)
        b:SetWidth(w + 14); b:SetHeight(16)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("LEFT", b, "LEFT", 0, 0)
        fs:SetText(text)
        b.label = fs
        b.baseText = text
        b:SetScript("OnClick", function() ui.SetCraftSort(key) end)
        ui.craftHeaders[key] = b
        return b
    end
    mkSort(CX.unit, CW.unit, "Unit price", "unit")
    mkSort(CX.stack, CW.stack, "Stack buyout", "stack")
    mkSort(CX.pct, CW.pct, "% mkt", "pct")

    local scroll = CreateFrame("ScrollFrame", "AegisExchangeCraftScroll",
        panel, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", rowLeft, -94)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, 10)
    scroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(CRAFT_ROW_H, ui.UpdateCraftList)
    end)
    ui.craftScroll = scroll

    ui.craftRows = {}
    i = 1
    while i <= CRAFT_ROWS do
        BuildResultRow(panel, scroll, ui.craftRows, i, CRAFT_ROW_H)
        i = i + 1
    end

    ui.RefreshCraftTree()
end

-- ---- recipe-tree model + paint -----------------------------------------

function ui.FlattenCraft()
    local flat = {}
    local projects = A.craft and A.craft.Projects() or {}
    local pi = 1
    while pi <= table.getn(projects) do
        local p = projects[pi]
        table.insert(flat, { kind = "project", index = pi, name = p.name })
        if ui.craftExpanded[pi] then
            local reagents = p.reagents or {}
            local ri = 1
            while ri <= table.getn(reagents) do
                local r = reagents[ri]
                table.insert(flat, { kind = "reagent", projIndex = pi,
                    name = r.name, count = r.count, itemId = r.itemId })
                ri = ri + 1
            end
            if table.getn(reagents) == 0 then
                table.insert(flat, { kind = "note", text = "(no reagents)" })
            end
        end
        pi = pi + 1
    end
    if table.getn(projects) == 0 then
        table.insert(flat, { kind = "note",
            text = "Open a profession, select a recipe," })
        table.insert(flat, { kind = "note",
            text = "then click 'Add to Aegis'." })
    end
    ui.craftFlat = flat
end

function ui.RefreshCraftTree()
    if not ui.craftSideScroll then return end
    ui.FlattenCraft()
    ui.UpdateCraftTree()
end

function ui.UpdateCraftTree()
    if not ui.craftSideScroll then return end
    local flat = ui.craftFlat or {}
    FauxScrollFrame_Update(ui.craftSideScroll, table.getn(flat),
        CSIDE_ROWS, CSIDE_ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.craftSideScroll)
    local i = 1
    while i <= CSIDE_ROWS do
        local row = ui.craftSideRows[i]
        local e = flat[i + offset]
        if e then
            row.entry = e
            row.ex:SetText("")
            row.ct:SetText("")
            if e.kind == "project" then
                row.ex:SetText(ui.craftExpanded[e.index] and "-" or "+")
                local mark = (ui.craftSel == e.index) and "> " or ""
                row.label:SetText(mark .. e.name)
                if ui.craftSel == e.index then
                    row.label:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
                else
                    row.label:SetTextColor(C.text[1], C.text[2], C.text[3])
                end
            elseif e.kind == "reagent" then
                row.label:SetText("  " .. e.name)
                row.label:SetTextColor(C.text[1], C.text[2], C.text[3])
                if e.count and e.count > 1 then
                    row.ct:SetText("x" .. e.count)
                end
            else
                row.label:SetText("  " .. (e.text or ""))
                row.label:SetTextColor(0.5, 0.5, 0.5)
            end
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
        i = i + 1
    end
end

function ui.OnCraftTreeClick(e)
    if not e then return end
    if e.kind == "project" then
        ui.craftSel = e.index
        ui.craftExpanded[e.index] = not ui.craftExpanded[e.index]
        ui.RefreshCraftTree()
        ui.UpdateCraftSummary()
    elseif e.kind == "reagent" then
        ui.craftSel = e.projIndex
        ui.craftBox:SetText(e.name)
        ui.DoCraftSearch()
        ui.RefreshCraftTree()
        ui.UpdateCraftSummary()
    end
end

function ui.CraftDeleteProject()
    if not A.craft or not ui.craftSel then
        ChatMsg("Aegis: select a recipe first.")
        return
    end
    A.craft.DeleteProject(ui.craftSel)
    ui.craftSel = nil
    ui.RefreshCraftTree()
    ui.UpdateCraftSummary()
end

-- ---- search + results (Buy-style, shared row helpers) ------------------

function ui.DoCraftSearch()
    if not ui.craftBox then return end
    ui.craftBox:ClearFocus()
    if not A.buy then
        ui.craftStatus:SetText("Buy engine not loaded \226\128\148 fully restart WoW.")
        return
    end
    local name = util.Trim(ui.craftBox:GetText() or "")
    if name == "" then
        ui.craftStatus:SetText("Type a reagent name and Search.")
        return
    end
    ui.craftTitle:SetText(name)
    ui.craftResults = nil
    ui.UpdateCraftList()
    local ok, err = A.buy.Search(name, {
        onResults = function(rows)
            ui.craftResults = rows
            ui.UpdateCraftList()
            ui.UpdateCraftSummary()   -- the search fed the price DB
        end,
        onState = function() ui.RefreshCraftStatus() end,
    })
    if not ok then
        ui.craftStatus:SetText(err or "Could not search.")
    else
        ui.craftStatus:SetText("Searching...")
    end
end

-- Price every part of the selected recipe in one go: search the crafted item
-- (when it's an auctionable item) and each reagent, one after another, so the
-- price DB is filled and the profit estimate resolves. Only the last search's
-- listings remain on the right; the rest just warm the DB.
function ui.CraftPriceRecipe()
    if not A.buy or not A.craft then return end
    local p = ui.craftSel and A.craft.Projects()[ui.craftSel]
    if not p then
        ChatMsg("Aegis: select a recipe on the left first.")
        return
    end
    local q = {}
    if p.itemId then table.insert(q, p.name) end   -- crafted item, if it's an item
    local i = 1
    while i <= table.getn(p.reagents) do
        table.insert(q, p.reagents[i].name)
        i = i + 1
    end
    if table.getn(q) == 0 then
        ChatMsg("Aegis: nothing to price for this recipe.")
        return
    end
    ui.craftPriceQueue = q
    ui.CraftRunPriceQueue()
end

function ui.CraftRunPriceQueue()
    if not ui.craftPriceQueue or table.getn(ui.craftPriceQueue) == 0 then
        ui.craftPriceQueue = nil
        ui.UpdateCraftSummary()
        if ui.craftStatus then
            ui.craftStatus:SetText("Priced \226\128\148 net updated on the left.")
        end
        return
    end
    local term = table.remove(ui.craftPriceQueue, 1)
    ui.craftBox:SetText(term)
    ui.craftTitle:SetText(term)
    local ok = A.buy.Search(term, {
        onResults = function(rows)
            ui.craftResults = rows
            ui.UpdateCraftList()
            ui.UpdateCraftSummary()
            ui.CraftRunPriceQueue()   -- next part
        end,
        onState = function() ui.RefreshCraftStatus() end,
    })
    if not ok then
        ui.craftPriceQueue = nil
        if ui.craftStatus then ui.craftStatus:SetText("AH busy \226\128\148 try again.") end
        return
    end
    if ui.craftStatus then
        ui.craftStatus:SetText("Pricing... ("
            .. table.getn(ui.craftPriceQueue) .. " left)")
    end
end

function ui.RefreshCraftStatus()
    if not ui.craftStatus or not A.buy then return end
    local phase = A.buy.state.phase
    if phase == "wait_query" or phase == "wait_results" then
        ui.craftStatus:SetText("Searching...")
    end
end

function ui.SetCraftSort(key)
    if ui.craftSortKey == key then
        ui.craftSortDir = (ui.craftSortDir == "asc") and "desc" or "asc"
    else
        ui.craftSortKey = key
        ui.craftSortDir = "asc"
    end
    ui.UpdateCraftList()
end

function ui.RefreshCraft()
    if not ui.craftBuilt then return end
    -- First open with nothing chosen: expand the most-recent recipe so its
    -- reagents are visible right away (the recipe is inserted at index 1).
    if not ui.craftSel and A.craft and table.getn(A.craft.Projects()) > 0 then
        ui.craftSel = 1
        ui.craftExpanded[1] = true
    end
    ui.RefreshCraftTree()
    ui.UpdateCraftList()
    ui.UpdateCraftSummary()
end

-- Paint the Cost / Sells-for / Net lines for the selected recipe.
function ui.UpdateCraftSummary()
    if not ui.craftCostFS then return end
    local p = ui.craftSel and A.craft and A.craft.Projects()[ui.craftSel]
    if not p then
        ui.craftCostFS:SetText("Reagents: \226\128\148")
        ui.craftValueFS:SetText("Sells for: \226\128\148")
        ui.craftNetFS:SetText("Net: \226\128\148")
        ui.craftNetFS:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
        return
    end
    local cost, complete = A.craft.CostOf(p)
    local value, known = A.craft.ValueOf(p)

    if cost > 0 and not complete then
        ui.craftCostFS:SetText("Reagents: " .. util.FormatMoney(cost, true)
            .. " +?")
    elseif complete then
        ui.craftCostFS:SetText("Reagents: " .. util.FormatMoney(cost, true))
    else
        ui.craftCostFS:SetText("Reagents: |cff808080? \226\128\148 Price recipe|r")
    end

    if known then
        ui.craftValueFS:SetText("Sells for: " .. util.FormatMoney(value, true))
    else
        ui.craftValueFS:SetText("Sells for: |cff808080?|r")
    end

    local net, netKnown = A.craft.NetOf(p)
    if netKnown then
        local word = net >= 0 and "Profit: " or "Loss: "
        ui.craftNetFS:SetText(word .. util.FormatMoney(math.abs(net), true))
        if net >= 0 then
            ui.craftNetFS:SetTextColor(0.30, 0.85, 0.30)
        else
            ui.craftNetFS:SetTextColor(0.90, 0.30, 0.30)
        end
    else
        ui.craftNetFS:SetText("Net: |cff808080need prices|r")
        ui.craftNetFS:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
    end
end

function ui.UpdateCraftList()
    if not ui.craftScroll then return end
    local all = ui.craftResults or {}
    local sortKey = ui.craftSortKey or "unit"
    local dir = ui.craftSortDir or "asc"
    local rows = ui.SortResults(all, sortKey, dir, nil)
    ui.PaintSortHeaders(ui.craftHeaders, sortKey, dir)

    local total = table.getn(rows)
    FauxScrollFrame_Update(ui.craftScroll, total, CRAFT_ROWS, CRAFT_ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.craftScroll)

    if A.buy then
        local _, page, totalPages, totalAuctions = A.buy.GetResults()
        if ui.craftResults then
            if table.getn(all) == 0 then
                ui.craftStatus:SetText("No auctions found.")
            else
                local order = dir == "asc" and "low to high" or "high to low"
                ui.craftStatus:SetText(totalAuctions .. " auction(s) \226\128\162 "
                    .. sortKey .. " " .. order)
            end
            ui.craftPageText:SetText("Page " .. (page + 1) .. " / " .. totalPages)
        else
            ui.craftPageText:SetText("")
        end
    end

    local i = 1
    while i <= CRAFT_ROWS do
        local row = ui.craftRows[i]
        local r = rows[i + offset]
        if r then
            ui.FillResultRow(row, r)
        else
            row.entry = nil
            row:Hide()
        end
        i = i + 1
    end
end

-- ---- capture recipes from the profession windows -----------------------

-- Read the currently-selected recipe from whichever profession window is open
-- and store it as a Crafting project. TradeSkill covers most professions;
-- Craft covers Enchanting (and Beast Training).
function ui.CraftCapture()
    if not A.craft then
        ChatMsg("Aegis: crafting engine not loaded \226\128\148 fully restart WoW.")
        return
    end
    local project, reason
    if CraftFrame and CraftFrame:IsVisible() then
        project, reason = A.craft.CaptureCraft()
    else
        project, reason = A.craft.CaptureTradeSkill()
    end
    if not project then
        ChatMsg("Aegis: " .. (reason or "could not read that recipe."))
        return
    end
    A.craft.AddProject(project)
    ChatMsg("Aegis: added '" .. project.name .. "' to Crafting ("
        .. table.getn(project.reagents) .. " reagent type(s)).")
    if ui.craftBuilt then
        ui.craftSel = 1               -- new project is inserted at the front
        ui.craftExpanded[1] = true
        ui.RefreshCraftTree()
        ui.UpdateCraftSummary()
    end
end

-- Put an "Add to Aegis" button on a profession window, anchored to its close
-- button. Save-original-and-replace only: no secure hooks on 1.12.
function ui.AttachCraftButton(frame, name)
    if not frame or getglobal(name) then return end
    local b = CreateFrame("Button", name, frame, "UIPanelButtonTemplate")
    b:SetWidth(96); b:SetHeight(20)
    -- Pin to the frame's BOTTOM-RIGHT, above the Create/Exit buttons. This spot
    -- is clear in BOTH the stock UI and pfUI (no packed header / corner X to
    -- fight), and the profit line stacks directly above it.
    b:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 46)
    b:SetText("Add to Aegis")
    b:SetScript("OnClick", function() ui.CraftCapture() end)
end

-- A live "Profit / Loss" readout under our button on a profession window. It
-- works with the AH CLOSED -- it reads the price DB (filled by past scans and
-- searches), not the live AH. Two font strings: a coloured net line and a dim
-- mats/sells breakdown.
function ui.AttachProfLine(frame, btnName, key)
    if not frame then return end
    ui.profLines = ui.profLines or {}
    if ui.profLines[key] then return end
    -- Stack the two lines directly ABOVE the "Add to Aegis" button (which is
    -- pinned to the frame's bottom-right). Anchoring to the button keeps the
    -- whole cluster together in the clear space above the Create/Exit buttons.
    local btn = getglobal(btnName)
    local sub = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    if btn then
        sub:SetPoint("BOTTOMRIGHT", btn, "TOPRIGHT", 0, 6)
    else
        sub:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 74)
    end
    sub:SetJustifyH("RIGHT")
    sub:SetWidth(210)
    local net = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    net:SetPoint("BOTTOMRIGHT", sub, "TOPRIGHT", 0, 2)
    net:SetJustifyH("RIGHT")
    net:SetWidth(210)
    ui.profLines[key] = { net = net, sub = sub }
end

-- Paint the profit line for whichever profession window is currently visible,
-- and blank the other. Cheap enough to run on a timer (a few DB lookups).
function ui.UpdateProfLine()
    if not A.craft or not ui.profLines then return end
    -- Aegis-tab toggle: when off, keep every line blank.
    if A.db.Setting and A.db.Setting("profLine") == false then
        for _, refs in pairs(ui.profLines) do
            refs.net:SetText(""); refs.sub:SetText("")
        end
        return
    end
    local key
    if CraftFrame and CraftFrame:IsVisible() and ui.profLines.craft then
        key = "craft"
    elseif TradeSkillFrame and TradeSkillFrame:IsVisible()
        and ui.profLines.tradeskill then
        key = "tradeskill"
    end
    -- Blank the line on any window that isn't the active one.
    for k, refs in pairs(ui.profLines) do
        if k ~= key then refs.net:SetText(""); refs.sub:SetText("") end
    end
    if not key then return end
    local refs = ui.profLines[key]
    local p = A.craft.Current()
    if not p then refs.net:SetText(""); refs.sub:SetText(""); return end

    local cost, complete = A.craft.CostOf(p)
    local value, known = A.craft.ValueOf(p)
    local net, netKnown = A.craft.NetOf(p)
    if netKnown then
        local word = net >= 0 and "Profit " or "Loss "
        refs.net:SetText("Aegis: " .. word .. util.FormatMoney(math.abs(net), true))
        if net >= 0 then
            refs.net:SetTextColor(0.30, 0.85, 0.30)
        else
            refs.net:SetTextColor(0.90, 0.30, 0.30)
        end
        refs.sub:SetText("mats " .. util.FormatMoney(cost, true)
            .. "  sells " .. util.FormatMoney(value, true))
    else
        -- Missing prices: show what we can and point at the AH.
        refs.net:SetText("Aegis: price the mats in the AH")
        refs.net:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
        local matsTxt
        if cost > 0 then
            matsTxt = "mats " .. util.FormatMoney(cost, true)
                .. (complete and "" or " +?")
        else
            matsTxt = "mats ?"
        end
        local sellTxt = known and ("sells " .. util.FormatMoney(value, true))
            or "sells ?"
        refs.sub:SetText(matsTxt .. "  " .. sellTxt)
    end
end

function ui.HookProfessionFrames()
    if TradeSkillFrame then
        ui.AttachCraftButton(TradeSkillFrame, "AegisExchangeAddTradeSkillButton")
        ui.AttachProfLine(TradeSkillFrame,
            "AegisExchangeAddTradeSkillButton", "tradeskill")
    end
    if CraftFrame then
        ui.AttachCraftButton(CraftFrame, "AegisExchangeAddCraftButton")
        ui.AttachProfLine(CraftFrame, "AegisExchangeAddCraftButton", "craft")
    end
    if ui.profPoller then ui.profPoller:Show() end
    ui.UpdateProfLine()
end

-- Poll the open profession window so the profit line tracks the selected
-- recipe (there is no "selection changed" event on 1.12) and picks up new
-- prices from a scan/search. Self-idles when no profession window is open.
ui.profPoller = CreateFrame("Frame", "AegisExchangeProfPoller")
ui.profPoller:Hide()
ui.profPoller._accum = 0
ui.profPoller:SetScript("OnUpdate", function()
    ui.profPoller._accum = ui.profPoller._accum + arg1
    if ui.profPoller._accum < 0.3 then return end
    ui.profPoller._accum = 0
    local tsVis = TradeSkillFrame and TradeSkillFrame:IsVisible()
    local crVis = CraftFrame and CraftFrame:IsVisible()
    if not tsVis and not crVis then
        ui.profPoller:Hide()
        return
    end
    ui.UpdateProfLine()
end)

-- ---------------------------------------------------------------------------
-- Auctions tab: your active auctions -- time left, bid state, undercut flag,
-- and a per-row Cancel.
-- ---------------------------------------------------------------------------

local AUC_ROWS, AUC_ROW_H = 12, 21
-- Row-relative column x / width.
local ACX = { name = 2, qty = 176, unit = 216, stack = 300, time = 392,
              mkt = 452, cancel = 540 }
local ACW = { name = 172, qty = 34, unit = 80, stack = 88, time = 56, mkt = 84 }

function ui.BuildAuctionsTab()
    local panel = ui.panels["Auctions"]
    if not panel or ui.aucBuilt then return end
    ui.aucBuilt = true

    -- Summary + refresh.
    ui.aucSummary = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.aucSummary:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -12)
    ui.aucSummary:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    ui.aucSummary:SetText("Your auctions")

    local refresh = CreateFrame("Button", "AegisExchangeAucRefreshButton",
        panel, "UIPanelButtonTemplate")
    refresh:SetWidth(72); refresh:SetHeight(20)
    refresh:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -10)
    refresh:SetText("Refresh")
    refresh:SetScript("OnClick", function() ui.RefreshAuctions(true) end)

    ui.aucStatus = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.aucStatus:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -34)
    ui.aucStatus:SetJustifyH("LEFT")
    ui.aucStatus:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])

    -- Column headers.
    local rowLeft = 6
    local hdr = function(cx, text, just)
        local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("TOPLEFT", panel, "TOPLEFT", rowLeft + cx, -54)
        fs:SetText(text)
        if just then fs:SetJustifyH(just) end
        return fs
    end
    hdr(ACX.name, "Item")
    hdr(ACX.qty, "Qty")
    hdr(ACX.unit, "Unit")
    hdr(ACX.stack, "Buyout")
    hdr(ACX.time, "Time")
    hdr(ACX.mkt, "vs market")

    local scroll = CreateFrame("ScrollFrame", "AegisExchangeAucScroll",
        panel, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", rowLeft, -70)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, 10)
    scroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(AUC_ROW_H, ui.UpdateAuctionsList)
    end)
    ui.aucScroll = scroll

    ui.aucRows = {}
    local i = 1
    while i <= AUC_ROWS do
        local row = CreateFrame("Frame", nil, panel)
        row:SetHeight(AUC_ROW_H)
        if i == 1 then
            row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
            row:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, 0)
        else
            row:SetPoint("TOPLEFT", ui.aucRows[i - 1], "BOTTOMLEFT", 0, 0)
            row:SetPoint("TOPRIGHT", ui.aucRows[i - 1], "BOTTOMRIGHT", 0, 0)
        end
        local mk = function(cx, w, just)
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", row, "LEFT", cx, 0)
            fs:SetWidth(w); fs:SetJustifyH(just or "LEFT")
            return fs
        end
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(16); icon:SetHeight(16)
        icon:SetPoint("LEFT", row, "LEFT", ACX.name, 0)
        row.icon = icon
        row.name = mk(ACX.name + 20, ACW.name - 20)
        row.qty  = mk(ACX.qty, ACW.qty)
        row.unit = mk(ACX.unit, ACW.unit)
        row.stack = mk(ACX.stack, ACW.stack)
        row.time = mk(ACX.time, ACW.time)
        row.mkt  = mk(ACX.mkt, ACW.mkt)
        local cancel = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        cancel:SetWidth(64); cancel:SetHeight(18)
        cancel:SetPoint("LEFT", row, "LEFT", ACX.cancel, 0)
        cancel:SetText("Cancel")
        cancel:SetScript("OnClick", function()
            if row.entry then ui.ConfirmCancelAuction(row.entry) end
        end)
        row.cancelBtn = cancel
        row:Hide()
        ui.aucRows[i] = row
        i = i + 1
    end
end

-- Read the owner list into ui.aucAuctions; `request` also pings the server.
function ui.RefreshAuctions(request)
    if not ui.aucBuilt then return end
    if request then A.sell.RequestOwnerAuctions() end
    ui.aucAuctions = A.sell.OwnerAuctions()
    ui.UpdateAuctionsList()
end

function ui.UpdateAuctionsList()
    if not ui.aucScroll then return end
    local rows = ui.aucAuctions or {}
    local total = table.getn(rows)

    local cap = A.sell.CAP or 120
    ui.aucSummary:SetText("Your auctions: " .. total .. " / " .. cap)
    if total == 0 then
        ui.aucStatus:SetText("No active auctions. Post some on the Sell tab.")
    else
        ui.aucStatus:SetText("Cancel refunds the item (deposit is forfeit)."
            .. "  Undercut = someone is cheaper than you.")
    end

    FauxScrollFrame_Update(ui.aucScroll, total, AUC_ROWS, AUC_ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.aucScroll)
    local i = 1
    while i <= AUC_ROWS do
        local row = ui.aucRows[i]
        local r = rows[i + offset]
        if r then
            ui.FillAuctionRow(row, r)
        else
            row.entry = nil
            row:Hide()
        end
        i = i + 1
    end
end

function ui.FillAuctionRow(row, r)
    row.entry = r
    if row.icon then
        if r.texture then
            row.icon:SetTexture(r.texture); row.icon:Show()
        else
            row.icon:Hide()
        end
    end
    row.name:SetText(r.name)
    local q = r.quality
    if q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q] then
        local c = ITEM_QUALITY_COLORS[q]
        row.name:SetTextColor(c.r, c.g, c.b)
    else
        row.name:SetTextColor(C.text[1], C.text[2], C.text[3])
    end
    row.qty:SetText("x" .. r.count)
    row.unit:SetText(r.unit and util.FormatMoney(r.unit, true) or "\226\128\148")
    if r.buyout and r.buyout > 0 then
        row.stack:SetText(util.FormatMoney(r.buyout, true))
    else
        row.stack:SetText("bid only")
    end
    row.time:SetText(A.sell.TimeLeftText(r.timeLeft))

    -- Undercut check vs the recorded market minimum. mkt below your unit means
    -- a cheaper listing exists (you're undercut).
    local mkt = r.itemId and A.db.MinBuyout(r.itemId)
    if mkt and mkt > 0 and r.unit then
        if r.unit <= mkt then
            row.mkt:SetText("lowest")
            row.mkt:SetTextColor(0.30, 0.85, 0.30)
        else
            row.mkt:SetText("under " .. util.FormatMoney(mkt, true))
            row.mkt:SetTextColor(0.90, 0.30, 0.30)
        end
    else
        row.mkt:SetText("\226\128\148")
        row.mkt:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
    end
    row:Show()
end

StaticPopupDialogs["AEGIS_EXCHANGE_CANCEL"] = {
    text = "Cancel your auction of %s?\nThe item returns by mail; the deposit is lost.",
    button1 = "Cancel auction", button2 = "Keep",
    OnAccept = function() ui.DoCancelAuction() end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

function ui.ConfirmCancelAuction(r)
    ui.pendingCancel = r
    StaticPopup_Show("AEGIS_EXCHANGE_CANCEL", r.name .. " (x" .. r.count .. ")")
end

function ui.DoCancelAuction()
    local r = ui.pendingCancel
    ui.pendingCancel = nil
    if not r then return end
    if A.sell.CancelOwnerAuction(r.index) then
        ChatMsg("Aegis: cancelled " .. r.name .. " x" .. r.count .. ".")
    end
end

-- ---------------------------------------------------------------------------
-- Sell tab: bag browser + per-item listing scan + post
-- ---------------------------------------------------------------------------

local BAG_ROWS,  BAG_ROW_H  = 9, 19
local LIST_ROWS, LIST_ROW_H = 9, 19

function ui.BuildSellTab()
    local panel = ui.panels["Sell"]
    if not panel or ui.sellBuilt then return end
    ui.sellBuilt = true
    ui.sellDuration = A.db.Setting("duration") or A.sell.DEFAULT_DURATION

    -- ---- Header: sell slot + item context -------------------------------
    local slot = CreateFrame("Button", "AegisExchangeSellSlot", panel)
    slot:SetWidth(40)
    slot:SetHeight(40)
    slot:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -12)
    slot:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-EmptySlot",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    slot:SetBackdropColor(0, 0, 0, 0.6)
    slot:RegisterForDrag("LeftButton")
    local icon = slot:CreateTexture("AegisExchangeSellSlotIcon", "ARTWORK")
    icon:SetPoint("TOPLEFT", slot, "TOPLEFT", 3, -3)
    icon:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", -3, 3)
    icon:Hide()
    slot.icon = icon
    local place = function()
        ClickAuctionSellItemButton()   -- cursor item -> sell slot (session API)
        ui.RefreshSell()
    end
    slot:SetScript("OnClick", place)
    slot:SetScript("OnReceiveDrag", place)
    slot:SetScript("OnEnter", function()
        local it = A.sell.GetItem()
        if it and it.link then
            GameTooltip:SetOwner(slot, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(it.link)
            GameTooltip:Show()
        end
    end)
    slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ui.sellSlot = slot

    ui.sellName = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.sellName:SetPoint("TOPLEFT", slot, "TOPRIGHT", 10, -1)
    ui.sellName:SetJustifyH("LEFT")
    ui.sellName:SetText("Click a bag item, or drag one here")
    ui.sellName:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    ui.sellCtx = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.sellCtx:SetPoint("TOPLEFT", slot, "TOPRIGHT", 10, -20)
    ui.sellCtx:SetJustifyH("LEFT")
    ui.sellCtx:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])

    -- Vendor comparison lives in the RIGHT column (below the cap count) so it
    -- can't collide with the unit-price row that sits just under the slot.
    ui.sellVendor = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.sellVendor:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -60)
    ui.sellVendor:SetJustifyH("RIGHT")

    -- Deposit / total / cap count, right-aligned.
    ui.sellDeposit = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.sellDeposit:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -12)
    ui.sellDeposit:SetJustifyH("RIGHT")
    ui.sellDeposit:SetTextColor(C.text[1], C.text[2], C.text[3])

    ui.sellTotal = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.sellTotal:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -28)
    ui.sellTotal:SetJustifyH("RIGHT")
    ui.sellTotal:SetTextColor(C.text[1], C.text[2], C.text[3])

    ui.sellCap = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.sellCap:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -44)
    ui.sellCap:SetJustifyH("RIGHT")

    -- ---- Row 1: unit price + quick fills --------------------------------
    local buyLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    buyLabel:SetPoint("TOPLEFT", slot, "BOTTOMLEFT", 0, -8)
    buyLabel:SetWidth(82)
    buyLabel:SetJustifyH("LEFT")
    buyLabel:SetText("Unit price:")
    buyLabel:SetTextColor(C.text[1], C.text[2], C.text[3])

    ui.sellBuyout = MakeMoneyBox(panel, 92)
    ui.sellBuyout:SetPoint("LEFT", buyLabel, "RIGHT", 6, 0)
    ui.sellBuyout:SetScript("OnTextChanged", function()
        ui.SyncSellPrices("unit")
    end)

    local mkQuick = function(text, w, anchorTo, fn)
        local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        b:SetWidth(w)
        b:SetHeight(18)
        b:SetPoint("LEFT", anchorTo, "RIGHT", 5, 0)
        b:SetText(text)
        b:SetScript("OnClick", fn)
        return b
    end
    ui.sellMarketBtn = mkQuick("Market", 54, ui.sellBuyout, function()
        local it = A.sell.GetItem()
        local sg = it and A.sell.Suggest(it.itemId)
        if sg and sg.market then SetMoneyBox(ui.sellBuyout, sg.market) end
    end)
    ui.sellUnderBtn = mkQuick("Undercut", 62, ui.sellMarketBtn, function()
        local it = A.sell.GetItem()
        local u = it and A.sell.UndercutUnit(it.itemId)
        if u then SetMoneyBox(ui.sellBuyout, u) end
    end)
    ui.sellVendorBtn = mkQuick("Vendor", 52, ui.sellUnderBtn, function()
        local it = A.sell.GetItem()
        local sg = it and A.sell.Suggest(it.itemId)
        if sg and sg.vendor then SetMoneyBox(ui.sellBuyout, sg.vendor) end
    end)

    -- ---- Row 2: stack price + "N stacks of S" ---------------------------
    local stackLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stackLabel:SetPoint("TOPLEFT", buyLabel, "BOTTOMLEFT", 0, -10)
    stackLabel:SetWidth(82)
    stackLabel:SetJustifyH("LEFT")
    stackLabel:SetText("Stack price:")
    stackLabel:SetTextColor(C.text[1], C.text[2], C.text[3])

    ui.sellStackPrice = MakeMoneyBox(panel, 92)
    ui.sellStackPrice:SetPoint("LEFT", stackLabel, "RIGHT", 6, 0)
    ui.sellStackPrice:SetScript("OnTextChanged", function()
        ui.SyncSellPrices("stack")
    end)

    ui.sellNumStacks = MakeNumBox(panel, 34, function() ui.RefreshSell() end)
    ui.sellNumStacks:SetPoint("LEFT", ui.sellStackPrice, "RIGHT", 12, 0)
    local ofLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ofLabel:SetPoint("LEFT", ui.sellNumStacks, "RIGHT", 4, 0)
    ofLabel:SetText("stacks of")
    ofLabel:SetTextColor(C.text[1], C.text[2], C.text[3])
    ui.sellStackSize = MakeNumBox(panel, 34, function()
        ui.SyncSellPrices("size")
    end)
    ui.sellStackSize:SetPoint("LEFT", ofLabel, "RIGHT", 4, 0)

    ui.sellMaxInfo = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.sellMaxInfo:SetPoint("LEFT", ui.sellStackSize, "RIGHT", 8, 0)

    -- ---- Row 3: duration + Post + Skip + status -------------------------
    local durLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    durLabel:SetPoint("TOPLEFT", stackLabel, "BOTTOMLEFT", 0, -12)
    durLabel:SetText("Duration:")
    durLabel:SetTextColor(C.text[1], C.text[2], C.text[3])

    ui.sellDurBtns = {}
    local prev = nil
    local di = 1
    while di <= table.getn(A.sell.DURATIONS) do
        local d = A.sell.DURATIONS[di]
        local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        b:SetWidth(44)
        b:SetHeight(20)
        if prev then
            b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else
            b:SetPoint("LEFT", durLabel, "RIGHT", 8, 0)
        end
        b:SetText(d.label)
        b.minutes = d.minutes
        b:SetScript("OnClick", function()
            ui.sellDuration = b.minutes
            ui.RefreshSell()
        end)
        ui.sellDurBtns[di] = b
        prev = b
        di = di + 1
    end

    local post = CreateFrame("Button", "AegisExchangeSellPostButton",
        panel, "UIPanelButtonTemplate")
    post:SetWidth(110)
    post:SetHeight(22)
    post:SetPoint("LEFT", prev, "RIGHT", 14, 0)
    post:SetText("Post")
    post:SetScript("OnClick", function()
        ui.ConfirmPost()
    end)
    ui.sellPostBtn = post

    local skip = CreateFrame("Button", "AegisExchangeSellSkipButton",
        panel, "UIPanelButtonTemplate")
    skip:SetWidth(60)
    skip:SetHeight(22)
    skip:SetPoint("LEFT", post, "RIGHT", 6, 0)
    skip:SetText("Skip")
    skip:SetScript("OnClick", function()
        ui.SkipSell()
    end)
    ui.sellSkipBtn = skip

    ui.sellStatus = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.sellStatus:SetPoint("LEFT", skip, "RIGHT", 10, 0)
    ui.sellStatus:SetJustifyH("LEFT")
    ui.sellStatus:SetTextColor(C.amber[1], C.amber[2], C.amber[3])

    -- ---- Divider --------------------------------------------------------
    local div = panel:CreateTexture(nil, "ARTWORK")
    div:SetTexture(C.border[1], C.border[2], C.border[3], 0.4)
    div:SetHeight(1)
    div:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -134)
    div:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -8, -134)

    -- ---- Bottom-left: Your Bags ----------------------------------------
    local bagHdr = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bagHdr:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -142)
    bagHdr:SetText("Your Bags")
    bagHdr:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    local bagScroll = CreateFrame("ScrollFrame", "AegisExchangeBagScroll",
        panel, "FauxScrollFrameTemplate")
    bagScroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -160)
    -- Right edge pulled well in (168) so the FauxScrollFrame's scrollbar, which
    -- sits just OUTSIDE this edge, clears the listings column that starts at
    -- x=200 -- otherwise the bar overlaps the price info.
    bagScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMLEFT", 168, 10)
    bagScroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(BAG_ROW_H, ui.UpdateBagList)
    end)
    ui.bagScroll = bagScroll

    ui.bagRows = {}
    local bi = 1
    while bi <= BAG_ROWS do
        local row = CreateFrame("Button", nil, panel)
        row:SetHeight(BAG_ROW_H)
        if bi == 1 then
            row:SetPoint("TOPLEFT", bagScroll, "TOPLEFT", 0, 0)
            row:SetPoint("TOPRIGHT", bagScroll, "TOPRIGHT", 0, 0)
        else
            row:SetPoint("TOPLEFT", ui.bagRows[bi - 1], "BOTTOMLEFT", 0, 0)
            row:SetPoint("TOPRIGHT", ui.bagRows[bi - 1], "BOTTOMRIGHT", 0, 0)
        end
        local ic = row:CreateTexture(nil, "ARTWORK")
        ic:SetWidth(16)
        ic:SetHeight(16)
        ic:SetPoint("LEFT", row, "LEFT", 4, 0)
        ic:Hide()
        row.icon = ic
        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("LEFT", row, "LEFT", 24, 0)
        lbl:SetJustifyH("LEFT")
        row.label = lbl
        row:SetScript("OnClick", function()
            local e = row.entry
            if e and e.kind == "item" then ui.SelectBagEntry(e.item) end
        end)
        row:SetScript("OnEnter", function()
            local e = row.entry
            if e and e.kind == "item" and e.item then
                GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
                GameTooltip:SetBagItem(e.item.bag, e.item.slot)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:Hide()
        ui.bagRows[bi] = row
        bi = bi + 1
    end

    -- ---- Bottom-right: listings table ----------------------------------
    ui.listHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.listHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 200, -138)
    ui.listHeader:SetJustifyH("LEFT")
    ui.listHeader:SetText("Select an item to see its listings")
    ui.listHeader:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    -- Column header labels.
    local colX = { unit = 200, avail = 292, stack = 452, pct = 592, you = 646 }
    local mkCol = function(x, text)
        local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -155)
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
        return fs
    end
    mkCol(colX.unit, "Unit price")
    mkCol(colX.avail, "Available")
    mkCol(colX.stack, "Stack price")
    mkCol(colX.pct, "% mkt")
    mkCol(colX.you, "You?")

    local listScroll = CreateFrame("ScrollFrame", "AegisExchangeListScroll",
        panel, "FauxScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 200, -170)
    listScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -26, 10)
    listScroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(LIST_ROW_H, ui.UpdateListingsList)
    end)
    ui.listScroll = listScroll

    ui.listRows = {}
    local li = 1
    while li <= LIST_ROWS do
        -- Buttons (not plain frames) so a click can copy that listing's unit
        -- price into the buyout box -- one-click "match this seller".
        local row = CreateFrame("Button", nil, panel)
        row:SetHeight(LIST_ROW_H)
        if li == 1 then
            row:SetPoint("TOPLEFT", listScroll, "TOPLEFT", 0, 0)
            row:SetPoint("TOPRIGHT", listScroll, "TOPRIGHT", 0, 0)
        else
            row:SetPoint("TOPLEFT", ui.listRows[li - 1], "BOTTOMLEFT", 0, 0)
            row:SetPoint("TOPRIGHT", ui.listRows[li - 1], "BOTTOMRIGHT", 0, 0)
        end
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        local mkCell = function(x, w, just)
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", row, "LEFT", x, 0)
            fs:SetWidth(w)
            fs:SetJustifyH(just or "LEFT")
            return fs
        end
        row.unit  = mkCell(0, 86)
        row.avail = mkCell(92, 158)
        row.stack = mkCell(252, 130)
        row.pct   = mkCell(392, 48)
        row.you   = mkCell(446, 40)
        row:SetScript("OnClick", function()
            local g = row.group
            if g and g.unit then
                SetMoneyBox(ui.sellBuyout, g.unit)
                ui.SyncSellPrices("unit")   -- price the whole stack from it
            end
        end)
        row:Hide()
        ui.listRows[li] = row
        li = li + 1
    end

    ui.RefreshSell()
end

-- Flatten the grouped bag structure into visible rows (category header, then
-- its item rows).
function ui.FlattenBags()
    local flat = {}
    local cats = ui.bagCats or {}
    local ci = 1
    while ci <= table.getn(cats) do
        local cat = cats[ci]
        table.insert(flat, { kind = "cat", name = cat.name,
            num = table.getn(cat.items) })
        local ii = 1
        while ii <= table.getn(cat.items) do
            table.insert(flat, { kind = "item", item = cat.items[ii] })
            ii = ii + 1
        end
        ci = ci + 1
    end
    ui.bagFlat = flat
end

function ui.RefreshBags()
    if not ui.bagScroll then return end
    ui.bagCats = A.sell.ScanBags()
    ui.FlattenBags()
    ui.UpdateBagList()
end

function ui.UpdateBagList()
    if not ui.bagScroll then return end
    local flat = ui.bagFlat or {}
    FauxScrollFrame_Update(ui.bagScroll, table.getn(flat), BAG_ROWS, BAG_ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.bagScroll)
    local i = 1
    while i <= BAG_ROWS do
        local row = ui.bagRows[i]
        local e = flat[i + offset]
        if e then
            row.entry = e
            if e.kind == "cat" then
                row.icon:Hide()
                row.label:ClearAllPoints()
                row.label:SetPoint("LEFT", row, "LEFT", 4, 0)
                row.label:SetText(e.name .. " (" .. e.num .. ")")
                row.label:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
            else
                local it = e.item
                if it.texture then
                    row.icon:SetTexture(it.texture)
                    row.icon:Show()
                else
                    row.icon:Hide()
                end
                row.label:ClearAllPoints()
                row.label:SetPoint("LEFT", row, "LEFT", 24, 0)
                local txt = it.name
                if it.count and it.count > 1 then txt = txt .. " x" .. it.count end
                row.label:SetText(txt)
                row.label:SetTextColor(C.text[1], C.text[2], C.text[3])
            end
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
        i = i + 1
    end
end

-- Place a bag item into the sell slot; the NEW_AUCTION_UPDATE that follows
-- refreshes the header and kicks off the per-item listing scan.
function ui.SelectBagEntry(item)
    if A.scan.IsRunning() or A.scan.IsPaused() then
        ChatMsg("Aegis: a scan is in progress \226\128\148 try again in a moment.")
        return
    end
    A.sell.PlaceFromBag(item.bag, item.slot)
    ui.RefreshSell()
end

-- When the slot item changes, scan the AH for that item's listings (once).
function ui.MaybeScanSlotItem()
    if A.sell.PostingActive() then return end   -- slot churns during a post
    local it = A.sell.GetItem()
    if not it or not it.itemId then
        ui.lastScanItemId = nil
        return
    end
    if it.itemId == ui.lastScanItemId then return end
    ui.lastScanItemId = it.itemId
    ui.sellListingGroups = nil
    local started = A.sell.ScanItem(it.name, it.itemId, nil, function(rows)
        ui.OnItemListings(rows)
    end)
    ui.sellScanState = started and "scanning" or "busy"
    if not started then ui.lastScanItemId = nil end
    ui.UpdateListingsList()
end

function ui.OnItemListings(rows)
    local it = A.sell.GetItem()
    if not it or not it.itemId or it.itemId ~= A.sell.scanItemId then
        -- Slot changed mid-scan; results are stale. Re-scan the current item.
        ui.lastScanItemId = nil
        ui.MaybeScanSlotItem()
        return
    end
    ui.sellScanState = "done"
    local market = A.db.MarketValue(it.itemId)
    ui.sellListingGroups = A.sell.GroupListings(rows, market)
    -- Pre-fill the buyout from the default-price setting when the user hasn't
    -- typed one.
    if util.Trim(ui.sellBuyout:GetText() or "") == "" then
        local u = ui.DefaultSellUnit(it.itemId)
        if u then SetMoneyBox(ui.sellBuyout, u) end
    end
    ui.UpdateListingsList()
    ui.RefreshSell()
end

-- The per-unit price to auto-fill for a freshly slotted item, per the Aegis-tab
-- "Default sell price" setting. "none" leaves the box empty.
function ui.DefaultSellUnit(itemId)
    local mode = A.db.Setting("sellDefault") or "undercut"
    if mode == "none" then return nil end
    if mode == "market" then
        return A.db.MarketValue(itemId) or A.sell.UndercutUnit(itemId)
    end
    return A.sell.UndercutUnit(itemId)   -- "undercut" (default)
end

function ui.UpdateListingsList()
    if not ui.listScroll then return end
    local groups = ui.sellListingGroups or {}
    FauxScrollFrame_Update(ui.listScroll, table.getn(groups), LIST_ROWS, LIST_ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.listScroll)

    if ui.sellScanState == "scanning" then
        ui.listHeader:SetText("Scanning this item...")
    elseif ui.sellScanState == "busy" then
        ui.listHeader:SetText("Scanner busy \226\128\148 finish that scan first")
    elseif ui.sellListingGroups then
        local when = A.sell.scanWhen
        local ago = when and util.FormatAgo(time() - when) or "just now"
        ui.listHeader:SetText(table.getn(groups)
            .. " price(s) \226\128\162 scanned " .. ago
            .. " \226\128\162 click a row to use its price")
    else
        ui.listHeader:SetText("Select an item to see its listings")
    end

    local i = 1
    while i <= LIST_ROWS do
        local row = ui.listRows[i]
        local g = groups[i + offset]
        if g then
            row.group = g   -- click copies g.unit into the buyout box
            row.unit:SetText(g.unit and util.FormatMoney(g.unit, true) or "\226\128\148")
            local avail
            if g.num > 1 then
                avail = g.num .. " stacks of " .. g.count
            else
                avail = "1 stack of " .. g.count
            end
            row.avail:SetText(avail)
            if g.buyout and g.buyout > 0 then
                row.stack:SetText(util.FormatMoney(g.buyout, true))
            else
                row.stack:SetText("bid only")
            end
            if g.pct then
                row.pct:SetText(g.pct .. "%")
                row.pct:SetTextColor(PctColorSell(g.pct))
            else
                row.pct:SetText("\226\128\148")
                row.pct:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
            end
            if g.mine then
                row.you:SetText("yes")
                row.you:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
            else
                row.you:SetText("no")
                row.you:SetTextColor(0.5, 0.5, 0.5)
            end
            row:Show()
        else
            row.group = nil
            row:Hide()
        end
        i = i + 1
    end
end

function ui.RefreshSell()
    if not ui.sellBuilt then return end
    local it = A.sell.GetItem()

    local di = 1
    while di <= table.getn(ui.sellDurBtns) do
        local b = ui.sellDurBtns[di]
        if b.minutes == ui.sellDuration then b:LockHighlight() else b:UnlockHighlight() end
        di = di + 1
    end

    local count = A.sell.OwnerCount()
    local atCap = count >= A.sell.CAP
    ui.sellCap:SetText("Listings: " .. count .. " / " .. A.sell.CAP)
    if atCap then
        ui.sellCap:SetTextColor(0.9, 0.35, 0.35)
    else
        ui.sellCap:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
    end

    local posting = A.sell.PostingActive()

    if not it and not posting then
        ui.sellSlot.icon:Hide()
        ui.sellName:SetText("Click a bag item, or drag one here")
        ui.sellCtx:SetText("")
        ui.sellVendor:SetText("")
        ui.sellDeposit:SetText("")
        ui.sellTotal:SetText("")
        ui.sellMaxInfo:SetText("")
        ui.sellPostBtn:Disable()
        ui.lastScanItemId = nil
        ui.sellDefaultsFor = nil
        return
    end
    if not it then return end   -- mid-post, slot momentarily empty

    if it.texture then
        ui.sellSlot.icon:SetTexture(it.texture)
        ui.sellSlot.icon:Show()
    end
    -- On a new item, seed the stack-size / count defaults (one stack of the
    -- whole placed amount, capped to the item's max stack).
    local totalHave = A.sell.CountInBags(it.itemId)
    if it.itemId ~= ui.sellDefaultsFor then
        ui.sellDefaultsFor = it.itemId
        local defSize = it.count
        if it.maxStack and defSize > it.maxStack then defSize = it.maxStack end
        if defSize < 1 then defSize = 1 end
        ui.sellStackSize:SetText(tostring(defSize))
        ui.sellNumStacks:SetText("1")
    end
    ui.sellName:SetText(it.name .. "  (" .. totalHave .. " total)")

    -- Context line: market / min / vendor from the DB.
    local sg = A.sell.Suggest(it.itemId)
    local parts = {}
    if sg and sg.market then
        table.insert(parts, "Market " .. util.FormatMoney(sg.market, true))
    end
    if sg and sg.minBuyout then
        table.insert(parts, "Min " .. util.FormatMoney(sg.minBuyout, true))
    end
    if sg and sg.vendor then
        table.insert(parts, "Vendor " .. util.FormatMoney(sg.vendor, true))
    end
    if table.getn(parts) > 0 then
        ui.sellCtx:SetText(table.concat(parts, "   "))
    else
        ui.sellCtx:SetText("No price data yet \226\128\148 scanning...")
    end

    local unitBuy = ReadMoneyBox(ui.sellBuyout)
    local size    = ui.GetStackSize(it)
    local nStacks = ui.GetNumStacks()
    local maxStacks = A.sell.MaxStacks(it.itemId, size)

    -- Clamp the requested stack count to what's assemblable, and show the max.
    if nStacks > maxStacks and maxStacks >= 1 then
        nStacks = maxStacks
        ui.sellNumStacks:SetText(tostring(nStacks))
    end
    ui.sellMaxInfo:SetText(string.format("max %d stack(s) of %d",
        maxStacks, size))

    -- Totals across all stacks being posted.
    local stackTotal = unitBuy and math.floor(unitBuy * size) or 0
    local grandTotal = stackTotal * nStacks
    if grandTotal > 0 then
        ui.sellTotal:SetText(nStacks .. " x " .. util.FormatMoney(stackTotal)
            .. " = " .. util.FormatMoney(grandTotal, true))
    else
        ui.sellTotal:SetText("")
    end

    -- Vendor comparison: above vendor = fine (green), below = warning (red).
    local vc = A.sell.VendorCompare(it.itemId, unitBuy)
    if vc then
        local word = vc.above and "above vendor" or "BELOW vendor"
        ui.sellVendor:SetText(string.format(
            "%d%% of vendor \226\128\162 %s", vc.pct, word))
        if vc.above then
            ui.sellVendor:SetTextColor(0.35, 0.8, 0.35)
        else
            ui.sellVendor:SetTextColor(0.9, 0.4, 0.4)
        end
    else
        ui.sellVendor:SetText("")
    end

    -- Deposit: per stack of `size`, times the number of stacks.
    local perStack = A.sell.DepositFor(it.itemId, size, ui.sellDuration,
        it.maxStack)
    local approx = true
    if not perStack then
        perStack = A.sell.EstimateDeposit(ui.sellDuration)
    end
    local depTotal = (perStack or 0) * nStacks
    ui.sellDeposit:SetText("Deposit ~" .. util.FormatMoney(depTotal, true)
        .. (approx and " (approx)" or ""))

    -- Posting state / button enable.
    if posting then
        ui.sellPostBtn:Disable()
        ui.sellSkipBtn:SetText("Cancel")
    else
        ui.sellSkipBtn:SetText("Skip")
        if atCap or maxStacks < 1 or not (unitBuy and unitBuy > 0) then
            ui.sellPostBtn:Disable()
        else
            ui.sellPostBtn:Enable()
        end
    end

    ui.MaybeScanSlotItem()
end

-- Current stack-size / stack-count entry values (with sensible fallbacks).
function ui.GetStackSize(it)
    it = it or A.sell.GetItem()
    local def = 1
    if it then
        def = it.count
        if it.maxStack and def > it.maxStack then def = it.maxStack end
        if def < 1 then def = 1 end
    end
    local n = NumVal(ui.sellStackSize, def)
    if it and it.maxStack and n > it.maxStack then n = it.maxStack end
    if n < 1 then n = 1 end
    return n
end

function ui.GetNumStacks()
    return NumVal(ui.sellNumStacks, 1)
end

-- Keep unit price and stack price in step. `source` says which the user just
-- edited: "unit"/"size" -> recompute stack price; "stack" -> recompute unit.
function ui.SyncSellPrices(source)
    if ui.sellSyncing then return end
    ui.sellSyncing = true
    local size = ui.GetStackSize()
    if source == "stack" then
        local sp = ReadMoneyBox(ui.sellStackPrice)
        if sp and size > 0 then
            SetMoneyBox(ui.sellBuyout, math.floor(sp / size))
        end
    else
        local u = ReadMoneyBox(ui.sellBuyout)
        if u then SetMoneyBox(ui.sellStackPrice, u * size) end
    end
    ui.sellSyncing = false
    ui.RefreshSell()
end

-- Skip button: cancel an in-progress post, else clear the current selection.
function ui.SkipSell()
    if A.sell.PostingActive() then
        A.sell.CancelPosting()
        ui.sellStatus:SetText("Cancelled.")
        ui.RefreshSell()
        ui.RefreshBags()
        return
    end
    A.sell.ClearSlot()
    ui.lastScanItemId = nil
    ui.sellDefaultsFor = nil
    ui.sellListingGroups = nil
    ui.sellScanState = nil
    SetMoneyBox(ui.sellBuyout, nil)
    SetMoneyBox(ui.sellStackPrice, nil)
    ui.UpdateListingsList()
    ui.RefreshSell()
end

StaticPopupDialogs["AEGIS_EXCHANGE_POST"] = {
    text = "Post %s?\n%s",
    button1 = "Post",
    button2 = "Cancel",
    OnAccept = function() ui.DoPost() end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

function ui.ConfirmPost()
    local it = A.sell.GetItem()
    if not it then
        ChatMsg("Aegis: no item in the sell slot.")
        return
    end
    local unitBuy = ReadMoneyBox(ui.sellBuyout)
    local size    = ui.GetStackSize(it)
    local nStacks = ui.GetNumStacks()
    local maxStacks = A.sell.MaxStacks(it.itemId, size)
    if nStacks > maxStacks then nStacks = maxStacks end
    local stackBuyout = math.floor((unitBuy or 0) * size)
    if stackBuyout < 1 then
        ChatMsg("Aegis: enter a unit price of at least 1 copper.")
        return
    end
    if nStacks < 1 then
        ChatMsg("Aegis: not enough of that item to make a stack.")
        return
    end
    local durLabel = "?"
    local di = 1
    while di <= table.getn(A.sell.DURATIONS) do
        if A.sell.DURATIONS[di].minutes == ui.sellDuration then
            durLabel = A.sell.DURATIONS[di].label
        end
        di = di + 1
    end
    local perStack = A.sell.DepositFor(it.itemId, size, ui.sellDuration,
        it.maxStack) or A.sell.EstimateDeposit(ui.sellDuration) or 0
    local detail = string.format(
        "%d stack(s) of %d at %s each \226\128\162 %s \226\128\162 deposit ~%s (approx)",
        nStacks, size, util.FormatMoney(stackBuyout), durLabel,
        util.FormatMoney(perStack * nStacks))
    ui.pendingPost = {
        itemId = it.itemId, itemName = it.name, size = size,
        nStacks = nStacks, unitBuyout = unitBuy, minutes = ui.sellDuration,
    }
    StaticPopup_Show("AEGIS_EXCHANGE_POST", it.name, detail)
end

function ui.DoPost()
    local p = ui.pendingPost
    if not p then return end
    ui.pendingPost = nil
    ui.sellStatus:SetText("Posting...")
    local ok, err = A.sell.StartPosting(p.itemId, p.itemName, p.size,
        p.nStacks, p.unitBuyout, p.unitBuyout, p.minutes, {
            onProgress = function(done, total)
                ui.sellStatus:SetText("Posting " .. done .. " / " .. total
                    .. "...")
            end,
            onDone = function(done, total, reason)
                local msg = "Posted " .. done .. " of " .. total .. "."
                if reason == "out" then
                    msg = msg .. " (ran out of items)"
                elseif reason == "cap" then
                    msg = msg .. " (hit the auction cap)"
                elseif reason == "cancelled" then
                    msg = "Posting cancelled after " .. done .. "."
                elseif reason == "stuck" then
                    msg = msg .. " (couldn't assemble a stack)"
                end
                ui.sellStatus:SetText(msg)
                ChatMsg("Aegis: " .. msg)
                ui.lastScanItemId = nil
                ui.sellDefaultsFor = nil
                ui.RefreshSell()
                ui.RefreshBags()
            end,
        })
    if not ok then
        ui.sellStatus:SetText("")
        ChatMsg("Aegis: " .. (err or "could not post."))
    end
    ui.RefreshSell()
end

-- ---------------------------------------------------------------------------
-- Category picker (class -> subclass checklist) for a targeted scan
-- ---------------------------------------------------------------------------

-- Visible rows in the picker list. HARD BOTTOM: the picker matches the
-- content well (460 - 80 top - 16 bottom = 364px tall), the list starts 34px
-- down, and the button row + divider occupy the bottom 44px. Keep
--   34 + CAT_ROWS * CAT_ROW_H  <  picker height - 44
-- true whenever any of these change, or the last rows draw OVER the
-- "Scan Selected" button (the v0.4.0 overlap bug). 34 + 13*20 = 294 < 320.
local CAT_ROWS  = 13    -- reusable visible rows
local CAT_ROW_H = 20

-- Flatten the class tree into the currently visible rows (a class row, then
-- its subclass rows when that class is expanded).
function ui.FlattenCategories()
    local flat = {}
    local tree = ui.catTree or {}
    local nc = table.getn(tree)
    local ci = 1
    while ci <= nc do
        local cat = tree[ci]
        table.insert(flat, {
            kind = "class", name = cat.name, class = cat.class,
            key = "c" .. cat.class,
        })
        if ui.catExpanded[cat.class] then
            local ns = table.getn(cat.subs)
            local si = 1
            while si <= ns do
                local sub = cat.subs[si]
                table.insert(flat, {
                    kind = "sub", name = sub.name, class = sub.class,
                    subclass = sub.subclass,
                    key = "c" .. sub.class .. "s" .. sub.subclass,
                })
                si = si + 1
            end
        end
        ci = ci + 1
    end
    ui.catFlat = flat
end

-- Collect the checked selection into scanner queries. A checked class scans the
-- whole class (one query, no subclass) and supersedes its subclasses; otherwise
-- each checked subclass is its own query.
function ui.CollectQueries()
    local queries = {}
    local tree = ui.catTree or {}
    local ci = 1
    while ci <= table.getn(tree) do
        local cat = tree[ci]
        if ui.catChecked["c" .. cat.class] then
            table.insert(queries, { class = cat.class })
        else
            local si = 1
            while si <= table.getn(cat.subs) do
                local sub = cat.subs[si]
                if ui.catChecked["c" .. sub.class .. "s" .. sub.subclass] then
                    table.insert(queries,
                        { class = sub.class, subclass = sub.subclass })
                end
                si = si + 1
            end
        end
        ci = ci + 1
    end
    return queries
end

function ui.CountChecked()
    local n = 0
    for _ in pairs(ui.catChecked) do n = n + 1 end
    return n
end

function ui.UpdateSelCount()
    if not ui.scanSelBtn then return end
    local n = ui.CollectQueries()
    ui.scanSelBtn:SetText("Scan Selected (" .. table.getn(n) .. ")")
    if table.getn(n) > 0 then
        ui.scanSelBtn:Enable()
    else
        ui.scanSelBtn:Disable()
    end
end

-- Paint the visible rows from ui.catFlat at the current scroll offset.
function ui.UpdateCatList()
    if not ui.catScroll then return end
    local flat = ui.catFlat or {}
    local total = table.getn(flat)
    FauxScrollFrame_Update(ui.catScroll, total, CAT_ROWS, CAT_ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.catScroll)
    local i = 1
    while i <= CAT_ROWS do
        local row = ui.catRows[i]
        local entry = flat[i + offset]
        if entry then
            row.entry = entry
            row.label:SetText(entry.name)
            row.check:SetChecked(ui.catChecked[entry.key] and 1 or nil)
            if entry.kind == "class" then
                row.expand:Show()
                if ui.catExpanded[entry.class] then
                    row.expand.text:SetText("-")
                else
                    row.expand.text:SetText("+")
                end
                row.check:ClearAllPoints()
                row.check:SetPoint("LEFT", row, "LEFT", 20, 0)
                row.label:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
            else
                row.expand:Hide()
                row.check:ClearAllPoints()
                row.check:SetPoint("LEFT", row, "LEFT", 40, 0)
                row.label:SetTextColor(C.text[1], C.text[2], C.text[3])
            end
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
        i = i + 1
    end
end

function ui.ToggleExpand(entry)
    if not entry or entry.kind ~= "class" then return end
    if ui.catExpanded[entry.class] then
        ui.catExpanded[entry.class] = nil
    else
        ui.catExpanded[entry.class] = true
    end
    ui.FlattenCategories()
    ui.UpdateCatList()
end

function ui.ClearChecks()
    ui.catChecked = {}
    ui.UpdateSelCount()
    ui.UpdateCatList()
end

function ui.ScanSelected()
    local queries = ui.CollectQueries()
    if table.getn(queries) == 0 then return end
    ui.HidePicker()
    ui.StartScan(queries)
end

function ui.BuildCategoryPicker()
    if ui.picker then return end

    local picker = CreateFrame("Frame", "AegisExchangePicker", ui.frame)
    picker:SetPoint("TOPLEFT", ui.content, "TOPLEFT", 0, 0)
    picker:SetPoint("BOTTOMRIGHT", ui.content, "BOTTOMRIGHT", 0, 0)
    picker:SetFrameLevel(ui.content:GetFrameLevel() + 5)
    picker:EnableMouse(true)   -- swallow clicks so they don't fall through
    picker:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    picker:SetBackdropColor(C.well[1], C.well[2], C.well[3], 1)
    picker:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3])
    picker:Hide()
    ui.picker = picker

    local title = picker:CreateFontString(
        "AegisExchangePickerTitle", "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", picker, "TOPLEFT", 12, -10)
    title:SetText("Scan which categories?")
    title:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    local scroll = CreateFrame("ScrollFrame", "AegisExchangePickerScroll",
        picker, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", picker, "TOPLEFT", 12, -34)
    -- Bottom edge matches the last visible row (34 + 13*20 = 294 from the
    -- top of a 364px picker) so the scrollbar spans exactly the list area.
    scroll:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -30, 70)
    -- 1.12 signature: FauxScrollFrame_OnVerticalScroll(itemHeight, updateFn) —
    -- the frame and scroll offset are the implicit globals `this` / `arg1`.
    -- The offset-first form belongs to LATER clients; passing it here makes
    -- FrameXML receive a number as its update function and crash
    -- ("attempt to call local 'updateFunction' (a number value)").
    scroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(CAT_ROW_H, ui.UpdateCatList)
    end)
    ui.catScroll = scroll

    ui.catRows = {}
    local i = 1
    while i <= CAT_ROWS do
        local row = CreateFrame("Button", "AegisExchangePickerRow" .. i, picker)
        row:SetHeight(CAT_ROW_H)
        if i == 1 then
            row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
            row:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, 0)
        else
            row:SetPoint("TOPLEFT", ui.catRows[i - 1], "BOTTOMLEFT", 0, 0)
            row:SetPoint("TOPRIGHT", ui.catRows[i - 1], "BOTTOMRIGHT", 0, 0)
        end

        local expand = CreateFrame("Button", nil, row)
        expand:SetWidth(16)
        expand:SetHeight(16)
        expand:SetPoint("LEFT", row, "LEFT", 2, 0)
        local et = expand:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        et:SetPoint("CENTER", expand, "CENTER", 0, 0)
        et:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
        expand.text = et
        expand:SetScript("OnClick", function()
            ui.ToggleExpand(row.entry)
        end)
        row.expand = expand

        local check = CreateFrame("CheckButton",
            "AegisExchangePickerCheck" .. i, row, "UICheckButtonTemplate")
        check:SetWidth(20)
        check:SetHeight(20)
        check:SetPoint("LEFT", row, "LEFT", 20, 0)
        check:SetScript("OnClick", function()
            local entry = row.entry
            if entry then
                if check:GetChecked() then
                    ui.catChecked[entry.key] = true
                else
                    ui.catChecked[entry.key] = nil
                end
                ui.UpdateSelCount()
            end
        end)
        row.check = check

        local label = row:CreateFontString(
            nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", check, "RIGHT", 4, 0)
        label:SetJustifyH("LEFT")
        row.label = label

        row:Hide()
        ui.catRows[i] = row
        i = i + 1
    end

    -- Visual hard bottom: a thin rule between the list and the button row.
    local divider = picker:CreateTexture(nil, "ARTWORK")
    divider:SetTexture(C.border[1], C.border[2], C.border[3], 0.5)
    divider:SetHeight(1)
    divider:SetPoint("BOTTOMLEFT", picker, "BOTTOMLEFT", 10, 42)
    divider:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -10, 42)

    local scanSel = CreateFrame("Button", "AegisExchangePickerScanButton",
        picker, "UIPanelButtonTemplate")
    scanSel:SetWidth(150)
    scanSel:SetHeight(22)
    scanSel:SetPoint("BOTTOMLEFT", picker, "BOTTOMLEFT", 12, 12)
    scanSel:SetText("Scan Selected (0)")
    scanSel:SetScript("OnClick", function()
        ui.ScanSelected()
    end)
    ui.scanSelBtn = scanSel

    local clear = CreateFrame("Button", "AegisExchangePickerClearButton",
        picker, "UIPanelButtonTemplate")
    clear:SetWidth(70)
    clear:SetHeight(22)
    clear:SetPoint("LEFT", scanSel, "RIGHT", 6, 0)
    clear:SetText("Clear")
    clear:SetScript("OnClick", function()
        ui.ClearChecks()
    end)

    local closeBtn = CreateFrame("Button", "AegisExchangePickerCloseButton",
        picker, "UIPanelButtonTemplate")
    closeBtn:SetWidth(70)
    closeBtn:SetHeight(22)
    closeBtn:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -12, 12)
    closeBtn:SetText("Close")
    closeBtn:SetScript("OnClick", function()
        ui.HidePicker()
    end)
end

function ui.ShowPicker()
    ui.BuildCategoryPicker()
    if not ui.catTree then
        ui.catTree = A.scan.GetCategories()
        ui.catExpanded = {}
        ui.catChecked = {}
    end
    ui.FlattenCategories()
    ui.picker:Show()
    ui.UpdateSelCount()
    ui.UpdateCatList()
end

function ui.HidePicker()
    if ui.picker then ui.picker:Hide() end
end

function ui.TogglePicker()
    if ui.picker and ui.picker:IsVisible() then
        ui.HidePicker()
    else
        ui.ShowPicker()
    end
end

-- ---------------------------------------------------------------------------
-- Sub-tab switching
-- ---------------------------------------------------------------------------

function ui.SelectSubTab(name)
    if not ui.subtabs then return end
    ui.selectedSubTab = name
    for k, tab in pairs(ui.subtabs) do
        if k == name then
            tab:SetBackdropColor(C.tabOn[1], C.tabOn[2], C.tabOn[3], 1)
            tab:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3])
            tab.label:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
        else
            tab:SetBackdropColor(C.tabOff[1], C.tabOff[2], C.tabOff[3], 1)
            tab:SetBackdropBorderColor(0.30, 0.26, 0.16)
            tab.label:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
        end
    end
    for k, panel in pairs(ui.panels) do
        if k == name then panel:Show() else panel:Hide() end
    end
    -- The category picker belongs to the Scan tab; don't leave it floating
    -- over another tab's panel.
    if name ~= "Scan" then
        ui.HidePicker()
    end
    if name == "Sell" then
        ui.RefreshBags()
        ui.RefreshSell()
    elseif name == "Buy" then
        ui.RefreshBuy()
    elseif name == "Crafting" then
        ui.RefreshCraft()
    elseif name == "Auctions" then
        ui.RefreshAuctions(true)
    elseif name == "Scan" then
        ui.RefreshSettings()   -- keep the price-data count current
    end
end

-- ---------------------------------------------------------------------------
-- Lifecycle: replace the Blizzard AH window while the AH is open
-- ---------------------------------------------------------------------------

-- One-tick deferred hide of the Blizzard AH.
--
-- The client's AUCTION_HOUSE_SHOW path (AuctionFrame_Show() in
-- Blizzard_AuctionUI.lua, called from UIParent.lua) is, verbatim from the
-- Turtle UI source:
--
--     ShowUIPanel(AuctionFrame);
--     if ( not AuctionFrame:IsVisible() ) then
--         CloseAuctionHouse();
--     end
--
-- So if anything hides AuctionFrame SYNCHRONOUSLY from its own OnShow, that
-- IsVisible() check fails and the CLIENT closes the AH session — after which
-- every QueryAuctionItems is a silent no-op (this was the "no reply — retry
-- N" stall). The OnShow hook below therefore only QUEUES the hide; this
-- driver performs it one OnUpdate tick later, safely past the guard. No
-- flash is visible: our toplevel HIGH-strata window covers the Blizzard AH.
local hider = CreateFrame("Frame", "AegisExchangeHider")
hider:Hide()
hider:SetScript("OnUpdate", function()
    hider:Hide()
    if not ui.showBlizzard and AuctionFrame and AuctionFrame:IsVisible() then
        ui.HideBlizzardAH()
    end
end)

function ui.QueueHideBlizzard()
    hider:Show()
end

-- CRITICAL: AuctionFrame's XML <OnHide> runs CloseAuctionHouse(), which ends
-- the server-side AH session — after which QueryAuctionItems does nothing and a
-- scan just spins on "Requesting first page...". So we must NEVER let the
-- Blizzard window's OnHide fire its default body while we're driving the
-- session. We hook it (save-original-and-replace, no hooksecurefunc) and, when
-- WE are the one hiding it, suppress that body so the session stays alive.
--
-- The OnShow hook handles the client re-showing its AH — but it must NOT
-- hide synchronously (see the hider above); it queues the hide instead.
function ui.HookAuctionFrame()
    if ui.ahHooked then return end
    if not AuctionFrame then return end

    ui.orig_AuctionFrame_OnShow = AuctionFrame:GetScript("OnShow")
    AuctionFrame:SetScript("OnShow", function()
        if ui.orig_AuctionFrame_OnShow then
            ui.orig_AuctionFrame_OnShow()
        end
        if not ui.showBlizzard then
            -- Deferred, never synchronous — a synchronous hide here trips
            -- the client's IsVisible guard and closes the AH session.
            ui.QueueHideBlizzard()
        end
    end)

    ui.orig_AuctionFrame_OnHide = AuctionFrame:GetScript("OnHide")
    AuctionFrame:SetScript("OnHide", function()
        -- keepSessionOpen: we hid it ourselves to show Aegis; the session must
        -- live, so skip the default body (PlaySound + CloseAuctionHouse + ...).
        if ui.keepSessionOpen then return end
        if ui.orig_AuctionFrame_OnHide then
            ui.orig_AuctionFrame_OnHide()
        end
    end)

    -- "Aegis UI" button on the stock AH so the hand-off works both ways.
    -- OpenWindow hides the Blizzard AH session-safely and shows ours.
    if not ui.blizSwapBtn then
        local b = CreateFrame("Button", "AegisExchangeSwapButton",
            AuctionFrame, "UIPanelButtonTemplate")
        b:SetWidth(70)
        b:SetHeight(19)
        local blizClose = getglobal("AuctionFrameCloseButton")
        if blizClose then
            -- Negative gap: sit clearly to the LEFT of the X (the old +4 tucked
            -- our right edge under the close button, crammed in pfUI).
            b:SetPoint("RIGHT", blizClose, "LEFT", -6, 0)
        else
            b:SetPoint("TOPRIGHT", AuctionFrame, "TOPRIGHT", -60, -12)
        end
        b:SetText("Aegis UI")
        b:SetScript("OnClick", function()
            ui.OpenWindow()
        end)
        ui.blizSwapBtn = b
    end

    ui.ahHooked = true
end

-- Hide the Blizzard AH window WITHOUT closing the AH session (see the OnHide
-- suppression above). Normal HideUIPanel bookkeeping, minus the session teardown.
function ui.HideBlizzardAH()
    if not AuctionFrame then return end
    ui.keepSessionOpen = true
    HideUIPanel(AuctionFrame)
    ui.keepSessionOpen = false
end

function ui.OpenWindow()
    ui.BuildWindow()
    ui.HookAuctionFrame()
    ui.showBlizzard = false
    -- Synchronous hide is safe HERE: our AUCTION_HOUSE_SHOW handler runs
    -- after the client's AuctionFrame_Show() has already passed its
    -- IsVisible guard, and the OnHide suppression keeps the session open.
    ui.HideBlizzardAH()
    ui.frame:Show()
    ui.SelectSubTab(ui.selectedSubTab or "Buy")
    ui.Refresh()
end

-- Hand the session over to the stock Blizzard AH. Reached from the title-bar
-- "Blizzard UI" button and /aex. showBlizzard makes our frame's OnHide skip
-- CloseAuctionHouse, so the session survives the swap.
function ui.ShowBlizzardUI()
    ui.showBlizzard = true
    if ui.frame then ui.frame:Hide() end
    if AuctionFrame then
        ShowUIPanel(AuctionFrame)
    else
        ChatMsg("Aegis: open the auction house first.")
    end
end

-- Closing our window ends the session via the frame's OnHide (set in
-- BuildWindow), so all we do here is hide it.
function ui.CloseWindow()
    if ui.frame then ui.frame:Hide() end
end

-- Install the OnShow hook as early as the load-on-demand AuctionFrame exists,
-- so even the very first open does not flash the Blizzard window.
A.RegisterEvent("ADDON_LOADED", function(evt, loadedName)
    if loadedName and string.lower(loadedName) == "blizzard_auctionui" then
        ui.HookAuctionFrame()
    end
end)

-- By AUCTION_HOUSE_SHOW, Blizzard_AuctionUI is loaded and AuctionFrame exists,
-- and the auction API is usable — so this is the moment to take over.
A.RegisterEvent("AUCTION_HOUSE_SHOW", function()
    ui.OpenWindow()
end)

A.RegisterEvent("AUCTION_HOUSE_CLOSED", function()
    if ui.frame then ui.frame:Hide() end
end)

-- Profession windows are load-on-demand: by TRADE_SKILL_SHOW / CRAFT_SHOW the
-- respective frame exists, so this is the moment to add our "Add to Aegis"
-- button (AttachCraftButton no-ops if it is already there).
A.RegisterEvent("TRADE_SKILL_SHOW", function()
    ui.HookProfessionFrames()
end)
A.RegisterEvent("CRAFT_SHOW", function()
    ui.HookProfessionFrames()
end)
-- Stop the profit-line poller when the profession window closes.
A.RegisterEvent("TRADE_SKILL_CLOSE", function()
    if ui.profPoller then ui.profPoller:Hide() end
end)
A.RegisterEvent("CRAFT_CLOSE", function()
    if ui.profPoller then ui.profPoller:Hide() end
end)

-- The item in the sell slot changed (placed / removed) or our auctions
-- updated (a post landed): keep the Sell tab current.
A.RegisterEvent("NEW_AUCTION_UPDATE", function()
    ui.RefreshSell()
end)
A.RegisterEvent("AUCTION_OWNED_LIST_UPDATE", function()
    ui.RefreshSell()
    if ui.aucBuilt then ui.RefreshAuctions(false) end
end)
-- Bags changed (looted, moved, sold): refresh the Sell tab's bag browser, but
-- only while it's the visible tab so we don't rescan bags needlessly.
A.RegisterEvent("BAG_UPDATE", function()
    if ui.selectedSubTab == "Sell" then
        ui.RefreshBags()
    end
end)

-- /aex (or /aegisexchange)  — escape hatch: show the default Blizzard AH.
-- /aex debug                — toggle the scanner's chat trace.
-- Deliberately NOT "/aegis": other addons in the user's Aegis series (Aegis:
-- Rally Power) already own that slash, and when two addons register the same
-- slash text the client resolves it to only ONE of them.
SLASH_AEGISEXCHANGE1 = "/aex"
SLASH_AEGISEXCHANGE2 = "/aegisexchange"
SlashCmdList["AEGISEXCHANGE"] = function(msg)
    local cmd = string.lower(msg or "")
    if string.find(cmd, "debug", 1, true) then
        A.debugScan = not A.debugScan
        if A.debugScan then
            ChatMsg("Aegis: scan debug ON \226\128\148 start a scan and"
                .. " watch the trace lines.")
        else
            ChatMsg("Aegis: scan debug OFF")
        end
        return
    end
    ui.ShowBlizzardUI()
end
