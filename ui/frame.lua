-- Aegis: Exchange
-- ui/frame.lua
--
-- "Aegis" tab on the Blizzard AuctionFrame. Modeled on AuctionatorVanilla's
-- own tabs (e.g. its "Info" panel): we KEEP the entire native auction house
-- frame — portrait, gold border, title bar, the player money frame, the tab
-- strip — and simply lay our content directly on the native content area.
-- Nothing is overlaid or hidden, so there is no chrome "husk" to peek through;
-- on our tab the frame is just the stock auction house frame with our tab up
-- (Blizzard already hides the Browse/Bid/Auctions sub-frames for us).
--
-- The auction UI is load-on-demand (Blizzard_AuctionUI): AuctionFrame does not
-- exist until the player first opens an auctioneer, so everything is built
-- from that addon's ADDON_LOADED (AUCTION_HOUSE_SHOW as fallback).

local A = AegisExchange
A.ui = A.ui or {}
local ui = A.ui
local util = A.util

-- Palette (0-1 space).
local COLOR_TEXT  = { r = 0.87, g = 0.82, b = 0.69 }   -- body text
local COLOR_AMBER = { r = 0.88, g = 0.65, b = 0.19 }   -- stale / paused
local COLOR_BAR   = { r = 0.25, g = 0.56, b = 0.20 }   -- progress fill
local COLOR_GOLD  = { r = 1.00, g = 0.82, b = 0.00 }   -- section headers

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

-- The AuctionFrame's background is six quadrant textures. Blizzard swaps them
-- per tab; our tab inherits whatever the last stock tab set — and the Browse
-- set has a TWO-PANE recess (narrow filter pane + wide list pane), which shows
-- as a stray "left box". The Auctions set is a single full-width pane, so we
-- point the background at it on our tab (verified paths from the 1.12
-- AuctionFrameTab_OnClick index==3 branch). Leaving our tab, Blizzard's own
-- handler re-textures these for the destination tab.
local AUCTION_BG = {
    { "AuctionFrameTopLeft",  "Interface\\AuctionFrame\\UI-AuctionFrame-Auction-TopLeft" },
    { "AuctionFrameTop",      "Interface\\AuctionFrame\\UI-AuctionFrame-Auction-Top" },
    { "AuctionFrameTopRight", "Interface\\AuctionFrame\\UI-AuctionFrame-Auction-TopRight" },
    { "AuctionFrameBotLeft",  "Interface\\AuctionFrame\\UI-AuctionFrame-Auction-BotLeft" },
    { "AuctionFrameBot",      "Interface\\AuctionFrame\\UI-AuctionFrame-Auction-Bot" },
    { "AuctionFrameBotRight", "Interface\\AuctionFrame\\UI-AuctionFrame-Auction-BotRight" },
}

function ui.SetAuctionsBackground()
    local n = table.getn(AUCTION_BG)
    local i = 1
    while i <= n do
        local t = getglobal(AUCTION_BG[i][1])
        if t then t:SetTexture(AUCTION_BG[i][2]) end
        i = i + 1
    end
end

-- Small helper: a labelled info column (gold header, value below), placed on
-- the native content area at a fixed x. Returns the value FontString.
local function InfoColumn(parent, x, y, header)
    local h = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    h:SetText(header)
    h:SetTextColor(COLOR_GOLD.r, COLOR_GOLD.g, COLOR_GOLD.b)
    local v = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    v:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -5)
    v:SetJustifyH("LEFT")
    return v
end

local function BuildPanel()
    -- Transparent container across the whole frame, shown/hidden with our tab.
    -- No backdrop: the native AH content background shows through, so our tab
    -- matches the stock frames exactly.
    local panel = CreateFrame("Frame", "AegisExchangePanel", AuctionFrame)
    panel:SetPoint("TOPLEFT", AuctionFrame, "TOPLEFT", 0, 0)
    panel:SetPoint("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", 0, 0)
    panel:Hide()
    ui.panel = panel

    -- Title in the native title bar (the stock sub-frames set their own title
    -- here and clear it when hidden; ours shows with our tab).
    local title = panel:CreateFontString(
        "AegisExchangePanelTitle", "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", panel, "TOP", 0, -18)
    title:SetText("Aegis: Exchange")
    ui.title = title

    -- Action buttons, top-right below the title bar (Auctionator puts its
    -- actions there). Right-to-left: Full Scan (primary) | Resume | Pause.
    local fullScanBtn = CreateFrame("Button", "AegisExchangeFullScanButton",
        panel, "UIPanelButtonTemplate")
    fullScanBtn:SetWidth(104)
    fullScanBtn:SetHeight(22)
    fullScanBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -26, -44)
    fullScanBtn:SetText("Full Scan")
    fullScanBtn:SetScript("OnClick", function()
        ui.ConfirmFullScan()
    end)
    ui.fullScanBtn = fullScanBtn

    local resumeBtn = CreateFrame("Button", "AegisExchangeResumeButton",
        panel, "UIPanelButtonTemplate")
    resumeBtn:SetWidth(74)
    resumeBtn:SetHeight(22)
    resumeBtn:SetPoint("RIGHT", fullScanBtn, "LEFT", -6, 0)
    resumeBtn:SetText("Resume")
    resumeBtn:SetScript("OnClick", function()
        A.scan.Continue()
        ui.Refresh()
    end)
    ui.resumeBtn = resumeBtn

    local pauseBtn = CreateFrame("Button", "AegisExchangePauseButton",
        panel, "UIPanelButtonTemplate")
    pauseBtn:SetWidth(74)
    pauseBtn:SetHeight(22)
    pauseBtn:SetPoint("RIGHT", resumeBtn, "LEFT", -6, 0)
    pauseBtn:SetText("Pause")
    pauseBtn:SetScript("OnClick", function()
        A.scan.Pause()
        ui.Refresh()
    end)
    ui.pauseBtn = pauseBtn

    -- Content box: ONE opaque panel that replaces the native content recess.
    -- Both stock backgrounds bake pane structure into the frame art (Browse =
    -- a two-pane filter/list recess; Auctions = the create-auction item slots),
    -- so neither gives a clean surface. Following how AuctionatorVanilla builds
    -- its panels, we keep the native OUTER frame (border, title bar, portrait,
    -- money frame, tabs) and cover just the busy content region with a single
    -- clean box built from an in-game asset. It starts below the auctioneer
    -- portrait (top-left, 58x58 at 12,-8) and above the money frame.
    local box = CreateFrame("Frame", "AegisExchangeContentBox", panel)
    box:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -68)
    box:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -14, 34)
    box:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    box:SetBackdropColor(0.06, 0.05, 0.04, 1)   -- opaque; hides the native art
    box:SetBackdropBorderColor(0.5, 0.42, 0.24)
    ui.box = box

    -- Progress bar across the top of the content box, full width.
    local bar = CreateFrame("StatusBar", "AegisExchangeScanBar", box)
    bar:SetPoint("TOPLEFT", box, "TOPLEFT", 12, -12)
    bar:SetPoint("TOPRIGHT", box, "TOPRIGHT", -12, -12)
    bar:SetHeight(16)
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
    bar:SetBackdropColor(0.02, 0.02, 0.02, 1)
    bar:SetBackdropBorderColor(0.4, 0.35, 0.2)
    ui.bar = bar

    -- Info columns inside the box, under the bar.
    ui.lastScanText = InfoColumn(box, 16,  -40, "Last Full Scan")
    ui.statText     = InfoColumn(box, 300, -40, "Items Tracked")
    local feed      = InfoColumn(box, 470, -40, "Data Source")
    feed:SetText("Full scans + browsing")

    -- Status line under the columns.
    local statusText = box:CreateFontString(
        "AegisExchangeStatusText", "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", box, "TOPLEFT", 16, -88)
    statusText:SetJustifyH("LEFT")
    ui.statusText = statusText

    -- "How scanning works" section, lower in the content box.
    local infoTitle = box:CreateFontString(
        "AegisExchangeInfoTitle", "OVERLAY", "GameFontNormal")
    infoTitle:SetPoint("TOPLEFT", box, "TOPLEFT", 16, -116)
    infoTitle:SetText("How scanning works")
    infoTitle:SetTextColor(COLOR_GOLD.r, COLOR_GOLD.g, COLOR_GOLD.b)

    -- Body copy. Two horizontal anchors give the FontString a width so it
    -- word-wraps.
    local infoBody = box:CreateFontString(
        "AegisExchangeInfoBody", "OVERLAY", "GameFontHighlightSmall")
    infoBody:SetPoint("TOPLEFT", infoTitle, "BOTTOMLEFT", 0, -8)
    infoBody:SetPoint("RIGHT", box, "RIGHT", -16, 0)
    infoBody:SetJustifyH("LEFT")
    infoBody:SetJustifyV("TOP")
    infoBody:SetText(
        "A Full Scan reads every page of the auction house to build a price "
        .. "database. The 1.12 server limits how often pages can be requested, "
        .. "so Aegis waits about " .. A.scan.PAGE_DELAY .. " seconds between "
        .. "pages: a busy auction house of 1,000+ pages can take 15 minutes or "
        .. "more.\n\n"
        .. "You can Pause and Resume at any time, and a scan picks up where it "
        .. "left off if you step away from the auctioneer. You don't have to "
        .. "run a full scan to collect data \226\128\148 browsing the Browse "
        .. "tab normally records every auction Aegis sees.\n\n"
        .. "Collected prices appear as market value and minimum buyout lines on "
        .. "item tooltips.")
    infoBody:SetTextColor(COLOR_TEXT.r, COLOR_TEXT.g, COLOR_TEXT.b)
    ui.infoBody = infoBody

    -- Throttled refresh while the panel is visible. OnUpdate receives no args
    -- on this client; elapsed is the GLOBAL arg1.
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

    -- Items-tracked column value.
    if ui.statText then
        ui.statText:SetText(tostring(A.db.ItemCount()))
    end

    -- Last-full-scan column value.
    local last = A.db.GetLastScan()
    if last and last.when then
        ui.lastScanText:SetText(string.format("%s \226\128\162 %d pages",
            util.FormatAgo(time() - last.when), last.pages or 0))
    else
        ui.lastScanText:SetText("never")
    end

    if p.phase == "wait_query" or p.phase == "wait_results" then
        -- Scanning.
        ui.fullScanBtn:Disable()
        ui.pauseBtn:Enable()
        ui.resumeBtn:Disable()
        local totalPages = p.totalPages
        if totalPages < 1 then totalPages = 1 end
        ui.bar:SetMinMaxValues(0, totalPages)
        ui.bar:SetValue(p.pagesDone)
        if p.totalPages > 0 then
            ui.statusText:SetText(string.format(
                "Page %d / %d \226\128\162 ~%s remaining \226\128\162 %s auctions/sec",
                p.page, p.totalPages,
                util.FormatDuration(p.eta),
                string.format("%.1f", p.rate)))
        else
            ui.statusText:SetText("Requesting first page...")
        end
        ui.statusText:SetTextColor(
            COLOR_TEXT.r, COLOR_TEXT.g, COLOR_TEXT.b)
    elseif p.phase == "paused" then
        -- Paused: Resume takes over. Bar stays visible to show where we are.
        ui.fullScanBtn:Enable()
        ui.pauseBtn:Disable()
        ui.resumeBtn:Enable()
        ui.statusText:SetText(string.format(
            "Paused at page %d / %d — Resume to continue",
            p.pagesDone, p.totalPages))
        ui.statusText:SetTextColor(
            COLOR_AMBER.r, COLOR_AMBER.g, COLOR_AMBER.b)
    else
        -- Idle.
        ui.fullScanBtn:Enable()
        ui.pauseBtn:Disable()
        ui.resumeBtn:Disable()
        ui.bar:SetMinMaxValues(0, 1)
        ui.bar:SetValue(0)
        if last and last.when then
            local age = time() - last.when
            if age > STALE_SECONDS then
                ui.statusText:SetText(string.format(
                    "Last scan %s — prices may be outdated",
                    util.FormatAgo(age)))
                ui.statusText:SetTextColor(
                    COLOR_AMBER.r, COLOR_AMBER.g, COLOR_AMBER.b)
            else
                ui.statusText:SetText(
                    "Idle — data is current.")
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
    -- The virtual template is "AuctionTabTemplate" — the one the stock
    -- AuctionFrameTab1..3 inherit in Blizzard_AuctionUI.xml (verified against
    -- the Turtle 1.12 UI source; AuctionatorVanilla creates its tab the same
    -- way). There is NO template named "AuctionFrameTab".
    local index = (AuctionFrame.numTabs or 3) + 1
    local prevTab = getglobal("AuctionFrameTab" .. (index - 1))

    local tab = CreateFrame("Button", "AuctionFrameTab" .. index,
        AuctionFrame, "AuctionTabTemplate")
    tab:SetID(index)
    tab:SetText("Aegis")
    tab:SetPoint("LEFT", prevTab, "RIGHT", -8, 0)
    tab:Show()

    if PanelTemplates_SetNumTabs then
        PanelTemplates_SetNumTabs(AuctionFrame, index)
    else
        AuctionFrame.numTabs = index
    end
    if PanelTemplates_EnableTab then
        PanelTemplates_EnableTab(AuctionFrame, index)
    end

    BuildPanel()

    -- Save-and-replace hook on the Blizzard tab handler (NOT hooksecurefunc;
    -- it does not exist on 1.12). The original hides Browse/Bid/Auctions and
    -- updates tab visuals; we then just toggle our content by the clicked
    -- index. The native frame chrome is left entirely alone.
    ui.orig_AuctionFrameTab_OnClick = AuctionFrameTab_OnClick
    AuctionFrameTab_OnClick = function(clickedIndex)
        ui.orig_AuctionFrameTab_OnClick(clickedIndex)
        local i = clickedIndex
        if not i and this and this.GetID then
            i = this:GetID()
        end
        if i == index then
            -- Point the frame background at the single-pane Auctions art so
            -- the content area is one full-width box (no Browse left pane).
            ui.SetAuctionsBackground()
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
