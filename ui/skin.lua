-- Aegis: Exchange
-- ui/skin.lua
--
-- Optional pfUI skin. When pfUI is installed, restyle our window with pfUI's
-- own backdrop / button / checkbox / scrollbar helpers so Aegis matches the
-- rest of the UI instead of wearing vanilla tooltip borders.
--
-- Design rules for this file:
--   * It is PURELY cosmetic. Nothing here may change behaviour, and every
--     pfUI call is wrapped so a pfUI API change can never break the addon --
--     worst case you keep the default look.
--   * pfUI's helpers come from pfUI:GetEnvironment() (the same entry point the
--     pfUI-addonskinner skins use). Each is checked before use.
--   * Skinning is applied ONCE, after the window is built.
--
-- Users of pfUI-addonskinner can also drive this from their skins folder --
-- see pfui/Aegis_Exchange.lua in this repo; it just calls A.skin.Apply().

local A = AegisExchange
A.skin = {}
local skin = A.skin

skin.applied = false

-- pfUI present and exposing its helper environment?
function skin.Available()
    return (pfUI and pfUI.GetEnvironment) and true or false
end

-- Should we skin? pfUI must be present AND the user setting left on.
function skin.Enabled()
    if not skin.Available() then return false end
    if A.db and A.db.Setting and A.db.Setting("pfSkin") == false then
        return false
    end
    return true
end

-- Fetch pfUI's helpers once. Returns a table of the ones we actually use, each
-- possibly nil (callers must check).
local function Env()
    if skin.env then return skin.env end
    local ok, env = pcall(function() return pfUI:GetEnvironment() end)
    if not ok or not env then return nil end
    skin.env = {
        CreateBackdrop  = env.CreateBackdrop,
        StripTextures   = env.StripTextures,
        SkinButton      = env.SkinButton,
        SkinCloseButton = env.SkinCloseButton,
        SkinCheckbox    = env.SkinCheckbox,
        SkinScrollbar   = env.SkinScrollbar,
    }
    return skin.env
end

-- ---------------------------------------------------------------------------
-- Small wrappers -- every pfUI call goes through pcall so a missing or changed
-- helper degrades to "unskinned", never to an error.
-- ---------------------------------------------------------------------------

local function Backdrop(frame, alpha)
    local env = Env()
    if not frame or not env or not env.CreateBackdrop then return end
    -- Drop our own vanilla backdrop first so we don't end up double-bordered.
    if frame.SetBackdrop then pcall(function() frame:SetBackdrop(nil) end) end
    pcall(function() env.CreateBackdrop(frame, nil, nil, alpha) end)
end

-- Push pfUI's backdrop BEHIND the frame it was made for.
--
-- CreateBackdrop builds a CHILD FRAME, and a child draws above ALL of its
-- parent's regions whatever draw layer they are on -- the same rule that makes
-- ui/frame.lua put the Filter Builder's text on a child rather than on the
-- well. For a button that means the plate can cover the label, and a button
-- with no text on it reads as a broken button rather than as a layering
-- accident.
--
-- Dropping the backdrop one frame level below its parent puts the label back
-- on top. Harmless where pfUI already does this; the point is that we no
-- longer depend on whether it does.
local function SinkBackdrop(frame)
    if not frame or not frame.backdrop then return end
    pcall(function()
        local lvl = frame:GetFrameLevel()
        if lvl and lvl > 0 then
            frame.backdrop:SetFrameLevel(lvl - 1)
        end
    end)
end

-- Move an Aegis button's label ONTO pfUI's backdrop frame.
--
-- SinkBackdrop above was the first attempt and it is not enough on its own.
-- Frame level orders SIBLINGS; the rule that a child frame draws over its
-- parent's regions is separate, and how far a child's level may be pushed
-- below its parent's is not something worth betting a button's text on --
-- least of all for a button buried three frames deep inside a ScrollFrame's
-- scroll child. The Aegis settings panel is exactly that (ui.BuildAegisSettings
-- draws into AegisExchangeAegisScrollChild) and under pfUI its buttons came
-- back as blank plates, while the scan strip's buttons -- one frame under the
-- window -- kept their text with the same sink applied.
--
-- Re-homing the label removes the question. Inside ONE frame the draw layer is
-- the whole ordering rule, so a FontString on the backdrop's OVERLAY layer is
-- above that backdrop's own background and border textures no matter what the
-- levels around it are.
--
-- Everything that reads the label goes through b.label (RepaintButton,
-- SetText, GetFontString, the sub-tab tint), so swapping the field is the
-- whole change -- there is no second reference to update.
local function LiftLabel(f)
    if not f or not f.backdrop or not f.label then return end
    if f.aegisLabelLifted then return end
    pcall(function()
        local old = f.label
        -- Read everything we need off the old string BEFORE touching
        -- anything, so a missing accessor aborts the lift with nothing
        -- half-done rather than leaving a button with two labels.
        local text = old:GetText() or ""
        local r, g, b = old:GetTextColor()

        local fs = f.backdrop:CreateFontString(nil, "OVERLAY",
            f.aegisFont or "GameFontNormalSmall")
        fs:SetPoint("CENTER", f, "CENTER", 0, 0)
        fs:SetText(text)
        if r then fs:SetTextColor(r, g, b) end

        f.label = fs
        f.aegisLabelLifted = true
        old:SetText("")
        old:Hide()
    end)
end

local function Strip(frame)
    local env = Env()
    if not frame or not env or not env.StripTextures then return end
    pcall(function() env.StripTextures(frame, true) end)
end

local function Button(b)
    local env = Env()
    if not b or not env or not env.SkinButton then return end
    pcall(function() env.SkinButton(b) end)
end

-- Close buttons need pfUI's dedicated helper: running the generic SkinButton
-- over a UIPanelCloseButton strips its "X" texture and leaves an oversized
-- empty box. If pfUI has no close-button skinner, leave the stock X alone --
-- a vanilla X looks far better than a blank button.
local function CloseButton(b)
    local env = Env()
    if not b or not env then return end
    if env.SkinCloseButton then
        pcall(function() env.SkinCloseButton(b) end)
    end
end

local function Checkbox(c)
    local env = Env()
    if not c or not env or not env.SkinCheckbox then return end
    pcall(function() env.SkinCheckbox(c) end)
end

local function Scrollbar(sb)
    local env = Env()
    if not sb or not env or not env.SkinScrollbar then return end
    pcall(function() env.SkinScrollbar(sb) end)
end

-- ---------------------------------------------------------------------------
-- Frame walking
-- ---------------------------------------------------------------------------

-- Children of `frame` as an array (1.12 returns them as multiple values; the
-- table constructor captures them, which is Lua 5.0 safe).
local function Children(frame)
    if not frame or not frame.GetChildren then return {} end
    local ok, t = pcall(function() return { frame:GetChildren() } end)
    if not ok or not t then return {} end
    return t
end

-- Skin one widget according to what it is. Returns true when handled.
local function SkinWidget(f)
    if not f or f.aegisSkinned then return false end
    local ok, otype = pcall(function() return f:GetObjectType() end)
    if not ok then return false end

    -- Widgets that opt out: bare-text sort headers, and LIST ROWS that happen
    -- to be Buttons because a row has to be clickable. The category tree is
    -- the one that matters -- it says something with its row backgrounds
    -- (top-level categories carry a plate, subcategories are bare indented
    -- text) and pfUI's SkinButton gives every Button the same plate, which
    -- erased the distinction and made the sidebar read as a stack of buttons.
    -- Result rows were never affected: those are Frames, so the Button branch
    -- below never reached them, which is why only the tree showed it.
    -- Marked with aegisNoSkin at creation.
    if f.aegisNoSkin then
        f.aegisSkinned = true
        return false
    end

    -- Our own backdrop-drawn buttons (ui.MakeButton). pfUI's SkinButton strips
    -- template textures and applies its plate -- but these have no template
    -- textures and already carry a backdrop, so the generic path would leave
    -- them double-bordered. Give them a pfUI backdrop instead and let the
    -- button's own repaint colour it: RepaintButton re-resolves its target to
    -- f.backdrop, which is the child pfUI creates below. Same arrangement the
    -- sub-tab pills use.
    if f.aegisButton then
        Backdrop(f, 1)
        SinkBackdrop(f)
        LiftLabel(f)
        f.aegisSkinned = true
        if A.ui and A.ui.SetButtonKind then
            A.ui.SetButtonKind(f, f.aegisKind)
        end
        return true
    end

    if otype == "Button" or otype == "CheckButton" then
        if otype == "CheckButton" then
            Checkbox(f)
        elseif f.aegisCloseButton then
            CloseButton(f)
        else
            Button(f)
        end
        f.aegisSkinned = true
        return true
    elseif otype == "EditBox" then
        Strip(f)
        Backdrop(f)
        f.aegisSkinned = true
        return true
    elseif otype == "Slider" then
        Scrollbar(f)
        f.aegisSkinned = true
        return true
    elseif otype == "StatusBar" then
        Backdrop(f, 0.8)
        f.aegisSkinned = true
        return true
    end
    return false
end

-- Walk `frame` and its descendants, skinning what we recognise. `depth` guards
-- against any pathological nesting.
local function SkinTree(frame, depth)
    if not frame or depth > 6 then return end
    local kids = Children(frame)
    local i = 1
    local n = table.getn(kids)
    while i <= n do
        local child = kids[i]
        if child then
            SkinWidget(child)
            SkinTree(child, depth + 1)
        end
        i = i + 1
    end
end

-- ---------------------------------------------------------------------------
-- Apply
-- ---------------------------------------------------------------------------

-- Restyle the Aegis window (and our buttons on other frames) to match pfUI.
-- Safe to call repeatedly; only the first full pass does the work.
function skin.Apply()
    if not skin.Enabled() then return false end
    if not Env() then return false end
    local ui = A.ui
    if not ui or not ui.frame then return false end
    if skin.applied then
        skin.ApplyExternal()   -- late-created buttons on other addons' frames
        return true
    end

    -- Main window + the recessed content well.
    Backdrop(ui.frame, 1)
    Backdrop(ui.content, 1)
    if ui.titleBar then Backdrop(ui.titleBar, 1) end
    skin.AdjustHeader()

    -- Sub-tab pills. These are custom-drawn Buttons whose colour we manage in
    -- SelectSubTab, so give them a pfUI backdrop and let our colouring ride on
    -- top (SelectSubTab re-tints frame.backdrop when present).
    if ui.subtabs then
        for _, tab in pairs(ui.subtabs) do
            Backdrop(tab, 1)
            SinkBackdrop(tab)         -- ...and keep their labels above it
            LiftLabel(tab)            -- ...and mean it
            tab.aegisSkinned = true   -- keep the generic pass off them
        end
    end

    -- Everything else in the window, by widget type.
    SkinTree(ui.frame, 0)

    -- Overlays are parented to the window but built lazily.
    if ui.picker then Backdrop(ui.picker, 1); SkinTree(ui.picker, 0) end
    if ui.vendList then Backdrop(ui.vendList, 1); SkinTree(ui.vendList, 0) end

    skin.applied = true
    skin.ApplyExternal()
    return true
end

-- Re-anchor the header for the skin.
--
-- Our default offsets are tuned for the VANILLA frame border, which is thick
-- and ornate (edgeSize 28 / 10px insets). pfUI's border is a hairline, so those
-- same insets leave the title strip floating away from the edge and the close
-- button sitting above it rather than on it.
--
-- Rather than guess pfUI's exact border width, tie the pieces to each other:
-- the strip hugs the frame with a small inset, and the close button is
-- vertically CENTERED on the strip. The "Blizzard UI" button and version text
-- already chain off the close button, so the whole row follows automatically.
function skin.AdjustHeader()
    local ui = A.ui
    if not ui or not ui.frame or not ui.titleBar then return end
    local close = getglobal("AegisExchangeCloseButton")

    pcall(function()
        ui.titleBar:ClearAllPoints()
        ui.titleBar:SetPoint("TOPLEFT", ui.frame, "TOPLEFT", 5, -5)
        ui.titleBar:SetPoint("TOPRIGHT", ui.frame, "TOPRIGHT", -5, -5)
    end)

    if close then
        pcall(function()
            close:ClearAllPoints()
            -- Centered on the strip, just inside its right edge.
            close:SetPoint("RIGHT", ui.titleBar, "RIGHT", -3, 0)
        end)
    end
end

-- How far pfUI needs each external button moved from where the stock UI wants
-- it, in (x, y). Zero means the stock placement is already right.
--
-- These exist because pfUI does not move the windows underneath by the same
-- amount in every direction. The attach code anchors to something that moves
-- WITH the skin -- the profession window's own Exit button, the merchant's own
-- tabs -- which gets most of the way there, and this covers the remainder.
--
-- EYEBALLED, and meant to stay that way. There is nothing to compute them
-- from: pfUI's border is a hairline where vanilla's is thick ornate art, and
-- the difference is whatever pfUI's author chose. Tune by looking.
skin.EXTERNAL_NUDGE = {
    -- "Add to Aegis" sat flush against the panel's bottom-right inner border
    -- in pfUI while clearing it comfortably on the stock frame.
    AegisExchangeAddTradeSkillButton = { x = 0, y = 10 },
    AegisExchangeAddCraftButton      = { x = 0, y = 10 },
    -- "Aegis: sell N marked" rode slightly high and tight against the tabs.
    AegisExchangeMerchantSellButton  = { x = 4, y = -4 },
    -- The stock AH swap button lands right in both; named anyway so the table
    -- lists every external button rather than only the ones that move.
    AegisExchangeSwapButton          = { x = 0, y = 0 },
}

-- The nudged anchor for one button, as a pure function so the arithmetic is
-- testable without pfUI, a client, or a frame. Returns x, y.
--
-- An unknown name nudges by nothing, which is the safe direction: a button
-- this table has never heard of keeps exactly the placement the attach code
-- gave it.
function skin.NudgedPoint(name, x, y)
    local n = skin.EXTERNAL_NUDGE[name]
    if not n then return x or 0, y or 0 end
    return (x or 0) + (n.x or 0), (y or 0) + (n.y or 0)
end

-- Re-point one external button for pfUI, from the anchor ui.SetExternalPoint
-- recorded. Silent when there is no record (nothing to re-point from) or no
-- nudge to make. Returns whether it moved anything.
--
-- ONCE PER BUTTON, and that guard is the whole reason this is public rather
-- than a file-scope local. skin.ApplyExternal runs on every attach AND from
-- skin.Apply, so a nudge that re-applied would walk the button a little
-- further every time the merchant was opened -- and nothing about the first
-- open would look wrong. A local could not be reached from a suite, so that
-- guard could not be sabotaged, and an unsabotaged guard is decoration.
function skin.NudgeExternal(b, name)
    if not b or b.aegisNudged then return false end
    local a = b.aegisAnchor
    if not a or not a.rel then return false end
    local x, y = skin.NudgedPoint(name, a.x, a.y)
    b.aegisNudged = true
    if x == a.x and y == a.y then return false end
    pcall(function()
        b:ClearAllPoints()
        b:SetPoint(a.point, a.rel, a.relPoint, x, y)
    end)
    return true
end

-- Our buttons that live on OTHER frames (profession windows, the merchant, the
-- stock auction house). They appear later than the window, so this runs both
-- from Apply and whenever one of them is created.
function skin.ApplyExternal()
    if not skin.Enabled() then return end
    local names = {
        "AegisExchangeAddTradeSkillButton",
        "AegisExchangeAddCraftButton",
        "AegisExchangeMerchantSellButton",
        "AegisExchangeSwapButton",
    }
    local i = 1
    while i <= table.getn(names) do
        local b = getglobal(names[i])
        if b then
            -- Straight through SkinWidget, which now lands them in the generic
            -- Button branch -- pfUI's own SkinButton.
            --
            -- This USED to be the wrong path and is now the right one, because
            -- these four stopped being ui.MakeButton plates. A plate carries
            -- its own backdrop, so SkinButton gave it a second border and
            -- buried the label; a stock UIPanelButtonTemplate is exactly what
            -- SkinButton is written for, and is what pfUI's own addon-skinner
            -- does to every Blizzard button it meets.
            if not b.aegisSkinned then SkinWidget(b) end
            skin.NudgeExternal(b, names[i])
        end
        i = i + 1
    end
end

-- Skin a widget built AFTER the initial pass.
--
-- skin.Apply is deliberately one-shot, which was fine while every widget
-- existed by the time it ran. Resizable lists changed that: rows are grown on
-- demand, so a window dragged taller gains rows the skin never saw -- and you
-- get skinned rows sitting directly above unskinned ones. Callers hand each
-- new row here once.
function skin.SkinNew(frame)
    if not skin.Enabled() or not frame then return end
    if not Env() then return end
    SkinWidget(frame)
    SkinTree(frame, 0)
end

-- Re-skin the lazily-built overlays the first time they appear.
function skin.ApplyOverlay(frame)
    if not skin.Enabled() or not frame then return end
    if frame.aegisSkinnedOverlay then return end
    if not Env() then return end
    Backdrop(frame, 1)
    SkinTree(frame, 0)
    frame.aegisSkinnedOverlay = true
end
