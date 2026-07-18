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

-- The default AuctionFrame sub-panels. Each is a full panel that owns its own
-- result buttons, sort headers, sell slot, list insets, etc. On our tab we
-- hide these PARENTS (hiding a frame hides all its children), which clears the
-- "holes" and inset art and lets the native frame interior show through with
-- no overlay of our own. The stock AuctionFrameTab_OnClick re-shows the right
-- one when the player returns to a default tab.
local DEFAULT_PANELS = { "AuctionFrameBrowse", "AuctionFrameBid", "AuctionFrameAuctions" }

function ui.HideDefaultPanels()
    local n = table.getn(DEFAULT_PANELS)
    local i = 1
    while i <= n do
        local f = getglobal(DEFAULT_PANELS[i])
        if f then f:Hide() end
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

    -- Content sits DIRECTLY on the native frame interior — no backdrop, no
    -- border, no box. With the default panels hidden the native art shows
    -- through, so our tab reads flush like the stock tabs (no frame-in-frame).

    -- Info columns (gold header, value below), under the button row.
    ui.lastScanText = InfoColumn(panel, 30,  -84, "Last Full Scan")
    ui.statText     = InfoColumn(panel, 300, -84, "Items Tracked")
    local feed      = InfoColumn(panel, 470, -84, "Data Source")
    feed:SetText("Full scans + browsing")

    -- Status line.
    local statusText = panel:CreateFontString(
        "AegisExchangeStatusText", "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", panel, "TOPLEFT", 30, -122)
    statusText:SetJustifyH("LEFT")
    ui.statusText = statusText

    -- Progress bar spanning the interior, just below the status line. Only a
    -- functional StatusBar with its own thin track — not a panel background.
    local bar = CreateFrame("StatusBar", "AegisExchangeScanBar", panel)
    bar:SetPoint("TOPLEFT", panel, "TOPLEFT", 30, -140)
    bar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -40, -140)
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
    bar:SetBackdropColor(0.03, 0.03, 0.03, 0.85)
    bar:SetBackdropBorderColor(0.4, 0.35, 0.2)
    ui.bar = bar

    -- "How scanning works" section, below the bar.
    local infoTitle = panel:CreateFontString(
        "AegisExchangeInfoTitle", "OVERLAY", "GameFontNormal")
    infoTitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 30, -170)
    infoTitle:SetText("How scanning works")
    infoTitle:SetTextColor(COLOR_GOLD.r, COLOR_GOLD.g, COLOR_GOLD.b)

    -- Body copy. Two horizontal anchors give the FontString a width so it
    -- word-wraps.
    local infoBody = panel:CreateFontString(
        "AegisExchangeInfoBody", "OVERLAY", "GameFontHighlightSmall")
    infoBody:SetPoint("TOPLEFT", infoTitle, "BOTTOMLEFT", 0, -8)
    infoBody:SetPoint("RIGHT", panel, "RIGHT", -40, 0)
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
    -- it does not exist on 1.12).
    --   * Non-Aegis tab: delegate to the original so Browse/Bid/Auctions show
    --     and behave exactly as stock (it re-shows the panel we hid).
    --   * Aegis tab: do NOT call the original (index has no stock branch).
    --     Hide the default panels ourselves, mark our tab selected via
    --     PanelTemplates_SetTab, and show our content — flush on the native
    --     frame with nothing of our own drawn behind it.
    ui.orig_AuctionFrameTab_OnClick = AuctionFrameTab_OnClick
    AuctionFrameTab_OnClick = function(clickedIndex)
        local i = clickedIndex
        if not i and this and this.GetID then
            i = this:GetID()
        end
        ui.panel:Hide()   -- always start hidden
        if i ~= index then
            ui.orig_AuctionFrameTab_OnClick(clickedIndex)
            return
        end
        ui.HideDefaultPanels()
        if PanelTemplates_SetTab then
            PanelTemplates_SetTab(AuctionFrame, index)
        end
        ui.panel:Show()
        ui.Refresh()
    end

    ui.tab = tab
    ui.tabIndex = index
    ui.tabAttached = true
end

-- Attach as soon as the auction UI addon loads. AuctionFrame is load-on-demand
-- (it does NOT exist at login), so this is the correct, earliest moment to
-- attach. Case-insensitive match; AttachTab self-guards against re-fires.
A.RegisterEvent("ADDON_LOADED", function(evt, loadedName)
    if loadedName and string.lower(loadedName) == "blizzard_auctionui" then
        ui.AttachTab()
    end
end)

-- Fallback: if the AH is shown and we still have not attached, try now.
A.RegisterEvent("AUCTION_HOUSE_SHOW", function()
    ui.AttachTab()
end)
