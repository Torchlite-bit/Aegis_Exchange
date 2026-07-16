-- Aegis: Exchange
-- ui/frame.lua
--
-- "Aegis" tab on the Blizzard AuctionFrame plus the scan strip, built to
-- match design/01-scan-strip.png and design/overview.png with vanilla 1.12
-- templates only:
--
--   [Full Scan] [Pause] [Resume]            Last full scan: 2h 14m ago · ...
--   [==================         progress StatusBar                       ]
--             Page 412 / 1832 · ~38m remaining · 5.1 auctions/sec
--
-- Idle shows "Last scan: Xh ago"; past ~24h it turns amber with a
-- "prices may be outdated" warning (design panel 1c).
--
-- The auction UI is load-on-demand (Blizzard_AuctionUI): AuctionFrame does
-- not exist until the player first opens an auctioneer, so everything is
-- built from that addon's ADDON_LOADED (AUCTION_HOUSE_SHOW as fallback).

local A = AegisExchange
A.ui = A.ui or {}
local ui = A.ui
local util = A.util

-- Palette from the design (approximate in 0-1 space).
local COLOR_TEXT  = { r = 0.87, g = 0.82, b = 0.69 }   -- #ddd0b0
local COLOR_AMBER = { r = 0.88, g = 0.65, b = 0.19 }   -- #e0a530
local COLOR_BAR   = { r = 0.25, g = 0.56, b = 0.20 }   -- #3f8f34

-- Last scan older than this is "stale" and rendered amber.
local STALE_SECONDS = 24 * 60 * 60

-- Guard so we only attach our tab once.
ui.tabAttached = false

-- ---------------------------------------------------------------------------
-- Full-scan confirmation popup
-- ---------------------------------------------------------------------------

-- Estimated pages for the popup: prefer the last full scan's page count;
-- otherwise fall back to whatever the currently displayed query reports.
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

function ui.StartFullScan()
    A.scan.Start({}, {
        onPage     = function() ui.Refresh() end,
        onComplete = function(stats) ui.OnScanComplete(stats) end,
    })
    ui.Refresh()
end

function ui.ConfirmFullScan()
    local pages = EstimatePages()
    local pagesText, minutesText
    if pages then
        pagesText = tostring(pages)
        minutesText =
            tostring(math.ceil(pages * A.scan.PAGE_DELAY / 60))
    else
        pagesText, minutesText = "?", "?"
    end
    StaticPopup_Show("AEGIS_EXCHANGE_FULL_SCAN", pagesText, minutesText)
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

function ui.OnScanComplete(stats)
    ui.Refresh()
    DEFAULT_CHAT_FRAME:AddMessage(
        string.format(
            "Aegis: Exchange — scan complete: %d auctions across %d pages in %s.",
            stats.auctions, stats.pages, util.FormatDuration(stats.duration)),
        0.35, 0.78, 0.98)
end

-- ---------------------------------------------------------------------------
-- Panel construction
-- ---------------------------------------------------------------------------

local function BuildPanel()
    -- Content frame shown when the Aegis tab is selected. Anchored inside
    -- AuctionFrame's usable region (below the 1.12 frame's title art).
    local panel = CreateFrame("Frame", "AegisExchangePanel", AuctionFrame)
    panel:SetPoint("TOPLEFT", AuctionFrame, "TOPLEFT", 22, -80)
    panel:SetPoint("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -40, 40)
    panel:Hide()
    ui.panel = panel

    -- Header: title left, last-full-scan summary right (design 1a).
    local title = panel:CreateFontString(
        "AegisExchangePanelTitle", "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -2)
    title:SetText("Aegis: Exchange")
    ui.title = title

    local lastScanText = panel:CreateFontString(
        "AegisExchangeLastScanText", "ARTWORK", "GameFontHighlightSmall")
    lastScanText:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -4)
    lastScanText:SetJustifyH("RIGHT")
    ui.lastScanText = lastScanText

    -- The scan strip: a recessed well holding buttons, bar, and status text.
    local strip = CreateFrame("Frame", "AegisExchangeScanStrip", panel)
    strip:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -22)
    strip:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -22)
    strip:SetHeight(86)
    strip:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    strip:SetBackdropColor(0.05, 0.05, 0.04, 0.9)
    strip:SetBackdropBorderColor(0.79, 0.64, 0.15)   -- gold-bevel edge
    ui.strip = strip

    -- Button row (design 1b: Full Scan | Pause | Resume).
    local fullScanBtn = CreateFrame(
        "Button", "AegisExchangeFullScanButton", strip,
        "UIPanelButtonTemplate")
    fullScanBtn:SetWidth(100)
    fullScanBtn:SetHeight(21)
    fullScanBtn:SetPoint("TOPLEFT", strip, "TOPLEFT", 10, -10)
    fullScanBtn:SetText("Full Scan")
    fullScanBtn:SetScript("OnClick", function()
        ui.ConfirmFullScan()
    end)
    ui.fullScanBtn = fullScanBtn

    local pauseBtn = CreateFrame(
        "Button", "AegisExchangePauseButton", strip,
        "UIPanelButtonTemplate")
    pauseBtn:SetWidth(70)
    pauseBtn:SetHeight(21)
    pauseBtn:SetPoint("LEFT", fullScanBtn, "RIGHT", 6, 0)
    pauseBtn:SetText("Pause")
    pauseBtn:SetScript("OnClick", function()
        A.scan.Pause()
        ui.Refresh()
    end)
    ui.pauseBtn = pauseBtn

    local resumeBtn = CreateFrame(
        "Button", "AegisExchangeResumeButton", strip,
        "UIPanelButtonTemplate")
    resumeBtn:SetWidth(70)
    resumeBtn:SetHeight(21)
    resumeBtn:SetPoint("LEFT", pauseBtn, "RIGHT", 6, 0)
    resumeBtn:SetText("Resume")
    resumeBtn:SetScript("OnClick", function()
        A.scan.Continue()
        ui.Refresh()
    end)
    ui.resumeBtn = resumeBtn

    -- Progress bar: one flat-fill StatusBar over a dark well (design 1b).
    local bar = CreateFrame("StatusBar", "AegisExchangeScanBar", strip)
    bar:SetPoint("TOPLEFT", strip, "TOPLEFT", 10, -38)
    bar:SetPoint("TOPRIGHT", strip, "TOPRIGHT", -10, -38)
    bar:SetHeight(18)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(COLOR_BAR.r, COLOR_BAR.g, COLOR_BAR.b)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    bar:SetBackdropColor(0.09, 0.06, 0.03, 1)   -- #2b1a0c well
    bar:SetBackdropBorderColor(0.4, 0.35, 0.2)
    ui.bar = bar

    -- Status line, centered under the bar.
    local statusText = strip:CreateFontString(
        "AegisExchangeStatusText", "ARTWORK", "GameFontHighlightSmall")
    statusText:SetPoint("TOP", bar, "BOTTOM", 0, -6)
    statusText:SetJustifyH("CENTER")
    ui.statusText = statusText

    -- Throttled refresh while the panel is visible. OnUpdate receives no
    -- args on this client; elapsed is the GLOBAL arg1.
    ui.refreshAccum = 0
    panel:SetScript("OnUpdate", function()
        ui.refreshAccum = ui.refreshAccum + arg1
        if ui.refreshAccum >= 0.25 then
            ui.refreshAccum = 0
            ui.Refresh()
        end
    end)

    ui.Refresh()
end

-- ---------------------------------------------------------------------------
-- State -> widgets
-- ---------------------------------------------------------------------------

function ui.Refresh()
    if not ui.panel then return end
    local p = A.scan.GetProgress()

    -- Header summary (design 1a: "Last full scan: 2h 14m ago · 1,832 pages").
    local last = A.db.GetLastScan()
    if last and last.when then
        ui.lastScanText:SetText(string.format(
            "Last full scan: %s · %d pages",
            util.FormatAgo(time() - last.when), last.pages or 0))
    else
        ui.lastScanText:SetText("Last full scan: never")
    end

    if p.phase == "wait_query" or p.phase == "wait_results" then
        -- Scanning (design 1b).
        ui.fullScanBtn:Disable()
        ui.pauseBtn:Enable()
        ui.resumeBtn:Disable()
        local totalPages = p.totalPages
        if totalPages < 1 then totalPages = 1 end
        ui.bar:SetMinMaxValues(0, totalPages)
        ui.bar:SetValue(p.pagesDone)
        if p.totalPages > 0 then
            ui.statusText:SetText(string.format(
                "Page %d / %d · ~%s remaining · %s auctions/sec",
                p.page, p.totalPages,
                util.FormatDuration(p.eta),
                string.format("%.1f", p.rate)))
        else
            ui.statusText:SetText("Requesting first page...")
        end
        ui.statusText:SetTextColor(
            COLOR_TEXT.r, COLOR_TEXT.g, COLOR_TEXT.b)
    elseif p.phase == "paused" then
        -- Paused: Resume takes over (design 1b caption).
        ui.fullScanBtn:Enable()
        ui.pauseBtn:Disable()
        ui.resumeBtn:Enable()
        ui.statusText:SetText(string.format(
            "Paused at page %d / %d — Resume to continue",
            p.pagesDone, p.totalPages))
        ui.statusText:SetTextColor(
            COLOR_AMBER.r, COLOR_AMBER.g, COLOR_AMBER.b)
    else
        -- Idle (design 1a/1c).
        ui.fullScanBtn:Enable()
        ui.pauseBtn:Disable()
        ui.resumeBtn:Disable()
        ui.bar:SetMinMaxValues(0, 1)
        ui.bar:SetValue(0)
        if last and last.when then
            local age = time() - last.when
            if age > STALE_SECONDS then
                ui.statusText:SetText(string.format(
                    "Last scan: %s — prices may be outdated",
                    util.FormatAgo(age)))
                ui.statusText:SetTextColor(
                    COLOR_AMBER.r, COLOR_AMBER.g, COLOR_AMBER.b)
            else
                ui.statusText:SetText(
                    "Last scan: " .. util.FormatAgo(age))
                ui.statusText:SetTextColor(
                    COLOR_TEXT.r, COLOR_TEXT.g, COLOR_TEXT.b)
            end
        else
            ui.statusText:SetText("No scan data yet — run a Full Scan.")
            ui.statusText:SetTextColor(
                COLOR_TEXT.r, COLOR_TEXT.g, COLOR_TEXT.b)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Tab attachment
-- ---------------------------------------------------------------------------

function ui.AttachTab()
    if ui.tabAttached then return end
    if not AuctionFrame then return end   -- auction UI not loaded yet

    -- Vanilla ships Browse/Bids/Auctions (numTabs == 3); ours is next. The
    -- tab is NAMED "AuctionFrameTab"..index so PanelTemplates_SetTab and
    -- Blizzard's own AuctionFrameTab_OnClick manage its visuals for free.
    local index = (AuctionFrame.numTabs or 3) + 1
    local prevTab = getglobal("AuctionFrameTab" .. (index - 1))

    local tab = CreateFrame("Button", "AuctionFrameTab" .. index,
        AuctionFrame, "AuctionFrameTab")
    tab:SetID(index)
    tab:SetText("Aegis")
    tab:SetPoint("LEFT", prevTab, "RIGHT", -8, 0)

    if PanelTemplates_SetNumTabs then
        PanelTemplates_SetNumTabs(AuctionFrame, index)
    else
        AuctionFrame.numTabs = index
    end

    BuildPanel()

    -- Save-and-replace hook on the Blizzard tab handler (NOT hooksecurefunc;
    -- it does not exist on 1.12). The original hides Browse/Bid/Auctions and
    -- updates tab visuals; we then toggle our panel by the clicked index.
    ui.orig_AuctionFrameTab_OnClick = AuctionFrameTab_OnClick
    AuctionFrameTab_OnClick = function(clickedIndex)
        ui.orig_AuctionFrameTab_OnClick(clickedIndex)
        local i = clickedIndex
        if not i and this and this.GetID then
            i = this:GetID()
        end
        if i == index then
            ui.panel:Show()
            ui.Refresh()
        else
            ui.panel:Hide()
        end
    end

    ui.tab = tab
    ui.tabIndex = index
    ui.tabAttached = true
end

-- Attach as soon as the auction UI addon loads.
A.RegisterEvent("ADDON_LOADED", function(evt, loadedName)
    if loadedName == "Blizzard_AuctionUI" then
        ui.AttachTab()
    end
end)

-- Fallback: if the AH is shown and we still have not attached, try now.
A.RegisterEvent("AUCTION_HOUSE_SHOW", function()
    ui.AttachTab()
end)
