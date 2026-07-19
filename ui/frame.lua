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
    tabOff  = { 0.21, 0.17, 0.12 },
    tabOn   = { 0.32, 0.27, 0.16 },
    border  = { 0.79, 0.64, 0.15 },
}

local SUBTABS = { "Buy", "Sell", "Auctions", "Crafting" }

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

    -- Title bar (also the drag handle).
    local titleBar = CreateFrame("Frame", "AegisExchangeTitleBar", f)
    titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -12)
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

    local subTitle = titleBar:CreateFontString(
        nil, "OVERLAY", "GameFontHighlightSmall")
    subTitle:SetPoint("RIGHT", titleBar, "RIGHT", -34, 0)
    subTitle:SetText("Turtle WoW 1.12")
    subTitle:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])

    -- Close button (top-right) — closes the auction house.
    local close = CreateFrame("Button", "AegisExchangeCloseButton", f,
        "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
    close:SetScript("OnClick", function()
        ui.CloseWindow()
    end)

    -- Persistent scan strip: Full Scan / Pause / Resume + status text.
    local fullScan = CreateFrame("Button", "AegisExchangeFullScanButton", f,
        "UIPanelButtonTemplate")
    fullScan:SetWidth(100)
    fullScan:SetHeight(22)
    fullScan:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -12)
    fullScan:SetText("Full Scan")
    fullScan:SetScript("OnClick", function()
        ChatMsg("Aegis: Full Scan (placeholder)")
    end)
    ui.fullScanBtn = fullScan

    local pause = CreateFrame("Button", "AegisExchangePauseButton", f,
        "UIPanelButtonTemplate")
    pause:SetWidth(74)
    pause:SetHeight(22)
    pause:SetPoint("LEFT", fullScan, "RIGHT", 6, 0)
    pause:SetText("Pause")
    pause:SetScript("OnClick", function()
        ChatMsg("Aegis: Pause (placeholder)")
    end)
    ui.pauseBtn = pause

    local resume = CreateFrame("Button", "AegisExchangeResumeButton", f,
        "UIPanelButtonTemplate")
    resume:SetWidth(74)
    resume:SetHeight(22)
    resume:SetPoint("LEFT", pause, "RIGHT", 6, 0)
    resume:SetText("Resume")
    resume:SetScript("OnClick", function()
        ChatMsg("Aegis: Resume (placeholder)")
    end)
    ui.resumeBtn = resume

    local status = f:CreateFontString(
        "AegisExchangeStatusText", "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", -4, -18)
    status:SetJustifyH("RIGHT")
    status:SetText("Last scan: never")
    status:SetTextColor(C.text[1], C.text[2], C.text[3])
    ui.statusText = status

    -- Sub-tab row.
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
            tab:SetPoint("TOPLEFT", fullScan, "BOTTOMLEFT", 0, -12)
        end
        ui.subtabs[name] = tab
        prev = tab
        i = i + 1
    end

    -- Content region (recessed well) below the sub-tabs.
    local content = CreateFrame("Frame", "AegisExchangeContent", f)
    content:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -128)
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

    -- One empty placeholder panel per sub-tab, filling the content region.
    ui.panels = {}
    i = 1
    while i <= nTabs do
        local name = SUBTABS[i]
        local panel = CreateFrame("Frame", "AegisExchangePanel" .. name, content)
        panel:SetPoint("TOPLEFT", content, "TOPLEFT", 6, -6)
        panel:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -6, 6)
        panel:Hide()
        local label = panel:CreateFontString(
            "AegisExchangePanelLabel" .. name, "OVERLAY", "GameFontNormalLarge")
        label:SetPoint("CENTER", panel, "CENTER", 0, 0)
        label:SetText(name)
        label:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
        ui.panels[name] = panel
        i = i + 1
    end

    ui.SelectSubTab("Buy")
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
end

-- ---------------------------------------------------------------------------
-- Lifecycle: replace the Blizzard AH window while the AH is open
-- ---------------------------------------------------------------------------

-- Anti-flash hook: save AuctionFrame's OnShow and replace it so the moment the
-- Blizzard window is shown it hides itself again (unless we deliberately asked
-- for it via /aegis). Save-original-and-replace — no hooksecurefunc.
function ui.HookAuctionFrame()
    if ui.ahHooked then return end
    if not AuctionFrame then return end
    ui.orig_AuctionFrame_OnShow = AuctionFrame:GetScript("OnShow")
    AuctionFrame:SetScript("OnShow", function()
        if ui.orig_AuctionFrame_OnShow then
            ui.orig_AuctionFrame_OnShow()
        end
        if not ui.showBlizzard then
            AuctionFrame:Hide()
        end
    end)
    ui.ahHooked = true
end

function ui.OpenWindow()
    ui.BuildWindow()
    ui.HookAuctionFrame()
    ui.showBlizzard = false
    if AuctionFrame then
        HideUIPanel(AuctionFrame)
    end
    ui.frame:Show()
    ui.SelectSubTab(ui.selectedSubTab or "Buy")
end

function ui.CloseWindow()
    if ui.frame then ui.frame:Hide() end
    CloseAuctionHouse()   -- fires AUCTION_HOUSE_CLOSED
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

-- Escape hatch: /aegis shows the default Blizzard AH (e.g. if its UI is needed).
SLASH_AEGISEXCHANGE1 = "/aegis"
SlashCmdList["AEGISEXCHANGE"] = function(msg)
    ui.showBlizzard = true
    if ui.frame then ui.frame:Hide() end
    if AuctionFrame then
        ShowUIPanel(AuctionFrame)
    else
        ChatMsg("Aegis: open the auction house first.")
    end
end
