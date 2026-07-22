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
    fs:SetText(name)
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
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -40, -12)
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

    -- Swap to the stock Blizzard AH (its counterpart button swaps back —
    -- see HookAuctionFrame). Raised above the title bar's drag region.
    local blizBtn = CreateFrame("Button", "AegisExchangeBlizzardButton", f,
        "UIPanelButtonTemplate")
    blizBtn:SetWidth(92)
    blizBtn:SetHeight(20)
    blizBtn:SetPoint("RIGHT", titleBar, "RIGHT", -4, 0)
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

    -- Close button (top-right) — closes the auction house. Its frame level is
    -- raised above the title bar so the whole button is clickable, not just the
    -- sliver above the drag region.
    local close = CreateFrame("Button", "AegisExchangeCloseButton", f,
        "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
    close:SetFrameLevel(f:GetFrameLevel() + 10)
    close:SetScript("OnClick", function()
        ui.CloseWindow()
    end)

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
        -- Scan and Sell are real tabs (built below); the rest are placeholders.
        if name ~= "Scan" and name ~= "Sell" then
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

    local cats = CreateFrame("Button", "AegisExchangeCategoriesButton",
        scanPanel, "UIPanelButtonTemplate")
    cats:SetWidth(94)
    cats:SetHeight(22)
    cats:SetPoint("LEFT", resume, "RIGHT", 6, 0)
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

    ui.BuildSellTab()

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

    -- Scan is the only functional tab so far; land there.
    ui.SelectSubTab("Scan")
    ui.Refresh()
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
-- Sell tab: bag browser + per-item listing scan + post
-- ---------------------------------------------------------------------------

local BAG_ROWS,  BAG_ROW_H  = 9, 19
local LIST_ROWS, LIST_ROW_H = 9, 19

-- Colour for a "% of market" cell: cheap = green, near market = gold, dear = red.
local function PctColor(pct)
    if pct < 100 then
        return 0.35, 0.85, 0.35
    elseif pct <= 110 then
        return 0.90, 0.82, 0.35
    end
    return 0.90, 0.38, 0.38
end

-- A money entry box. Accepts "1g 50s 20c" style text (util.ParseMoney).
local function MakeMoneyBox(parent, width)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetWidth(width)
    e:SetHeight(18)
    e:SetAutoFocus(false)   -- InputBoxTemplate already provides the font
    e:SetScript("OnEnterPressed", function() e:ClearFocus() end)
    e:SetScript("OnEscapePressed", function() e:ClearFocus() end)
    e:SetScript("OnTextChanged", function() ui.RefreshSell() end)
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

function ui.BuildSellTab()
    local panel = ui.panels["Sell"]
    if not panel or ui.sellBuilt then return end
    ui.sellBuilt = true
    ui.sellDuration = A.sell.DEFAULT_DURATION

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

    ui.sellVendor = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.sellVendor:SetPoint("TOPLEFT", slot, "TOPRIGHT", 10, -36)
    ui.sellVendor:SetJustifyH("LEFT")

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
        local row = CreateFrame("Frame", nil, panel)
        row:SetHeight(LIST_ROW_H)
        if li == 1 then
            row:SetPoint("TOPLEFT", listScroll, "TOPLEFT", 0, 0)
            row:SetPoint("TOPRIGHT", listScroll, "TOPRIGHT", 0, 0)
        else
            row:SetPoint("TOPLEFT", ui.listRows[li - 1], "BOTTOMLEFT", 0, 0)
            row:SetPoint("TOPRIGHT", ui.listRows[li - 1], "BOTTOMRIGHT", 0, 0)
        end
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
    -- Pre-fill the buyout from the undercut rule when the user hasn't typed one.
    if util.Trim(ui.sellBuyout:GetText() or "") == "" then
        local u = A.sell.UndercutUnit(it.itemId)
        if u then SetMoneyBox(ui.sellBuyout, u) end
    end
    ui.UpdateListingsList()
    ui.RefreshSell()
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
            .. " \226\128\162 lowest first")
    else
        ui.listHeader:SetText("Select an item to see its listings")
    end

    local i = 1
    while i <= LIST_ROWS do
        local row = ui.listRows[i]
        local g = groups[i + offset]
        if g then
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
                row.pct:SetTextColor(PctColor(g.pct))
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
            b:SetPoint("RIGHT", blizClose, "LEFT", 4, 0)
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
    ui.SelectSubTab(ui.selectedSubTab or "Scan")
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

-- The item in the sell slot changed (placed / removed) or our auctions
-- updated (a post landed): keep the Sell tab current.
A.RegisterEvent("NEW_AUCTION_UPDATE", function()
    ui.RefreshSell()
end)
A.RegisterEvent("AUCTION_OWNED_LIST_UPDATE", function()
    ui.RefreshSell()
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
