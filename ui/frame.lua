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
        ui.ConfirmFullScan()
    end)
    ui.fullScanBtn = fullScan

    local pause = CreateFrame("Button", "AegisExchangePauseButton", f,
        "UIPanelButtonTemplate")
    pause:SetWidth(74)
    pause:SetHeight(22)
    pause:SetPoint("LEFT", fullScan, "RIGHT", 6, 0)
    pause:SetText("Pause")
    pause:SetScript("OnClick", function()
        A.scan.Pause()
        ui.Refresh()
    end)
    ui.pauseBtn = pause

    local resume = CreateFrame("Button", "AegisExchangeResumeButton", f,
        "UIPanelButtonTemplate")
    resume:SetWidth(74)
    resume:SetHeight(22)
    resume:SetPoint("LEFT", pause, "RIGHT", 6, 0)
    resume:SetText("Resume")
    resume:SetScript("OnClick", function()
        A.scan.Continue()
        ui.Refresh()
    end)
    ui.resumeBtn = resume

    local cats = CreateFrame("Button", "AegisExchangeCategoriesButton", f,
        "UIPanelButtonTemplate")
    cats:SetWidth(94)
    cats:SetHeight(22)
    cats:SetPoint("LEFT", resume, "RIGHT", 6, 0)
    cats:SetText("Categories")
    cats:SetScript("OnClick", function()
        ui.TogglePicker()
    end)
    ui.catsBtn = cats

    local status = f:CreateFontString(
        "AegisExchangeStatusText", "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    status:SetPoint("TOP", fullScan, "TOP", 0, -4)
    status:SetJustifyH("RIGHT")
    status:SetText("Last scan: never")
    status:SetTextColor(C.text[1], C.text[2], C.text[3])
    ui.statusText = status

    -- Progress bar spanning the scan strip, under the buttons. Shown only
    -- while a scan is running or paused (empty/hidden when idle).
    local bar = CreateFrame("StatusBar", "AegisExchangeScanBar", f)
    bar:SetPoint("TOPLEFT", fullScan, "BOTTOMLEFT", 0, -8)
    bar:SetPoint("RIGHT", f, "RIGHT", -14, 0)
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
            tab:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -10)
        end
        ui.subtabs[name] = tab
        prev = tab
        i = i + 1
    end

    -- Content region (recessed well) below the sub-tabs.
    local content = CreateFrame("Frame", "AegisExchangeContent", f)
    content:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -134)
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

    ui.SelectSubTab("Buy")
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
            ui.statusText:SetText(pageText)
        else
            ui.statusText:SetText("Requesting first page...")
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
-- Category picker (class -> subclass checklist) for a targeted scan
-- ---------------------------------------------------------------------------

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
    scroll:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -30, 42)
    scroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(arg1, CAT_ROW_H, ui.UpdateCatList)
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
    ui.Refresh()
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
