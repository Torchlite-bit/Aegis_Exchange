-- Aegis: Exchange
-- ui/frame.lua
--
-- STANDALONE custom auction window.
--
-- Aegis is its OWN top-level frame parented to UIParent — it does NOT tab onto
-- or parent to the Blizzard AuctionFrame. When the auction house opens we hide
-- the Blizzard window and show ours in its place (the approach the Aux addon
-- uses on this 1.12 client); when it closes we hide ours. The 1.12 client has
-- no taint / protected-frame system, so replacing the AH window is safe, and
-- because no Blizzard AH frame is visible there are no default widgets, holes,
-- sort headers, or backgrounds to conflict with.
--
-- Layout: BuildWindow() creates the frame, the sub-tab strip and one empty
-- panel per sub-tab, then hands each panel to its own builder —
-- BuildBuyTab / BuildSellTab / BuildAuctionsTab / BuildCraftTab /
-- BuildHistoryTab, plus the scan controls and BuildAegisSettings for the
-- "Aegis" tab. Every panel is a real tab; none are placeholders.
--
-- The one frame here that is NOT parented to our window is
-- AegisExchangeSwapButton, the "Aegis UI" button we put ON the Blizzard AH so
-- the hand-off works both ways. See HookAuctionFrame.

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

-- Forward declarations: these are defined further down with the other
-- widget helpers, but ui.BuildAegisSettings is written above that point
-- and a local is only in scope after its declaration.
local MakeMoneyGSC, MakeHSlider, SetSliderRange

-- Window size bounds. The minimum is the old fixed size -- below it the Sell
-- tab's header rows start colliding -- and the maximum is generous enough for
-- a big monitor without letting the window escape a small one.
-- MIN_W is 1000, and what SETS it changed. It was the control strip: with
-- the strip starting beyond the sidebar, the left cluster and the right-hand
-- buttons collided below ~1000. Moving the strip to the panel's left edge
-- gave it ~190px back and it now fits comfortably at 832.
--
-- The RESULT COLUMNS are the binding constraint now. `ui.ColumnsFitAt` puts
-- the true floor at ~970, so 1000 stands with a little slack rather than
-- dropping to a number with none. It could only go lower by narrowing the
-- table, which would move AWAY from the mockup -- its table is wide -- and
-- the whole point of this pass is to match it.
--
-- A saved width below the minimum is clamped UP by RestoreWindowSize, so an
-- existing character just gets a wider window on first login.
local MIN_W, MIN_H = 1000, 492
local MAX_W, MAX_H = 1400, 900

-- How far the Aegis tab's settings block is inset inside its scroll child.
--
-- A ScrollFrame is the only 1.12 widget that CLIPS, which is why the settings
-- live in one -- and the clip line falls exactly on the scroll child's left
-- edge. Content at x=0 sits ON it, and the checkbox column is nudged 2px
-- FURTHER left (see tipChk) so the boxes line up under the text above them,
-- which put their left edge outside the frame entirely. Text got away with it
-- because a glyph carries its own side bearing; a solid 1px edge texture does
-- not, so the check boxes -- and only the check boxes -- came back shaved.
--
-- The scroll frame moves the same distance the other way, so the block still
-- lines up with the tip line above it and the inset is pure clip margin.
local SET_INSET = 6

-- Buy tab control-strip widths, from the mockup. Fixed, so the left cluster
-- stays tight and the slack falls between it and the buttons.
local BUY_NAME_W   = 200
local BUY_LVL_W    = 32
local BUY_QUAL_W   = 116
local BUY_SEARCH_W = 82
local BUY_ADV_W    = 88
-- What the cluster occupies end to end, including the gaps chained above.
-- Anything that needs to know whether the strip fits asks this rather than
-- re-adding the numbers and drifting.
local BUY_STRIP_W = BUY_NAME_W + 14 + BUY_LVL_W + 7 + 8 + 7 + BUY_LVL_W
                    + 16 + BUY_QUAL_W + 10 + 20 + 2 + 74

-- Does the default control strip fit in a window `w` wide?
--
-- With fixed widths, nothing in the anchoring prevents the left cluster from
-- reaching the right-hand buttons -- the guarantee has to come from the window
-- never being narrow enough for that to happen. So the arithmetic lives here,
-- where it can be checked, rather than as a number someone once did in their
-- head and wrote into MIN_W.
--
-- Layout: sidebar (SIDE_W + 48) | 10 | strip | GAP | Search + 10 + Advanced | 12
function ui.StripFitsAt(w)
    local MIN_GAP = 24        -- the mockup's empty middle, at its narrowest
    -- The strip now starts at the PANEL's left edge, not beyond the sidebar,
    -- so it no longer pays SIDE_W + gutter before it begins. That is ~190px
    -- back, and it is why this is no longer what sets MIN_W -- the result
    -- columns are (see ui.ColumnsFitAt).
    local left  = 10 + BUY_STRIP_W
    local right = BUY_SEARCH_W + 14 + BUY_ADV_W + 12
    -- The panel is inset from the window by roughly its border on each side.
    return (left + MIN_GAP + right) <= (w - 22)
end

-- Sell tab control block, top to bottom: a header band carrying the item and
-- the four money figures, a control grid, then the action bar. The bag list
-- and the listings table both hang off SELL_TOP_H, so the whole tab shifts
-- together when the controls change.
local SELL_HEAD_H = 46    -- header band
local SELL_FOOT_Y = 136   -- action bar starts here
local SELL_TOP_H  = 166   -- ...and the whole block ends here

-- The g/s/c triplet plus its coin icons, measured from its label's right edge.
-- Both money rows hang this far in from the panel's right edge so the copper
-- box lands exactly on it.
local PRICE_GSC_W = 139

-- Sub-tab order, left to right. "Scan" hosts the scanner controls (Full Scan /
-- Pause / Resume / Stop / Categories + status and progress) and the settings
-- block; it is displayed as "Aegis" via TAB_LABELS below.
local SUBTABS = { "Buy", "Sell", "Auctions", "Crafting", "History", "Scan" }

-- Display label per sub-tab (internal keys stay stable). The scan tab also
-- hosts user settings, so it reads as "Aegis".
local TAB_LABELS = { Scan = "Aegis" }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function ChatMsg(text)
    DEFAULT_CHAT_FRAME:AddMessage(text, 0.35, 0.78, 0.98)
end

-- ui.TintButton lived here. It vertex-coloured a template button's existing
-- textures so one button could stand out, and it has no work left to do: no
-- button in the addon inherits UIPanelButtonTemplate any more, so there are
-- no textures to colour. ui.SetButtonKind replaces it.

-- ---------------------------------------------------------------------------
-- Buttons
--
-- We draw our own rather than inherit UIPanelButtonTemplate. The template's
-- warm red-brown plate is vanilla's own art and there is nothing wrong with
-- it -- ROADMAP 2l settled that explicitly -- but the design concept asks for
-- flat dark plates with a thin border, and no vanilla template produces that.
-- So the plate is a backdrop and we own all four visual states.
--
-- Two kinds, straight from the concept's stylesheet:
--   * "primary" -- the deep red plate with a gold label (.btn). ONE per area:
--     the thing the area exists to do (Search, Post, Full Scan).
--   * "quiet"   -- the dark neutral plate with a tan label (.btn-quiet).
--     Everything else. This is the common case, so it is the default.
--
-- What the template gave away for free and is hand-written below: the hover
-- and pressed plates, the 1px label nudge on press (a button that does not
-- move when clicked feels dead), and the disabled look. Note that a bare
-- CreateFrame("Button") DOES have working Enable/Disable/IsEnabled -- they
-- just have no appearance attached, which is exactly the trap that would ship
-- a button that stops responding while still looking clickable.
-- ---------------------------------------------------------------------------

-- Borders are DARK, not warm. The concept edges both plates with #14120f --
-- near black -- and the first pass instead used a warm brown on quiet and a
-- bright red on primary, which is what made the unskinned buttons read as
-- outlined-in-brown rather than as flat plates. Under pfUI they already
-- looked right, because pfUI supplies its own dark edge; that difference
-- between the two skins was the tell.
--
-- Not literally #14120f though. The concept's panel behind these is #3c3a36,
-- lighter than the buttons, so a near-black edge makes them pop. Our panel is
-- #211F1A -- DARKER than the plates -- so the same edge would erase the
-- outline entirely. These sit a little above it: dark enough to read as the
-- concept's crisp edge, light enough to still separate a plate from the panel.
-- WHICH REFERENCE WINS, because the two disagree and this has now flipped
-- once. `design/07-buy-tab.png` styles the primary button `#5a1414` -- deep
-- red -- and 1.14.0 took its palette from there. The later "A - Default view"
-- mockup (v1.9.0) draws Search and Buyout as a warm brown-gold plate and adds
-- a PURPLE Advanced. **The mockup is newer and it wins.** Do not re-derive
-- these from the older PNG.
local BTN_KIND = {
    primary = {
        bg     = { 0.42, 0.31, 0.13 },
        over   = { 0.52, 0.39, 0.17 },
        down   = { 0.30, 0.22, 0.09 },
        border = { 0.62, 0.49, 0.22 },
        text   = { 1.00, 0.86, 0.48 },
        font   = "GameFontNormal",
    },
    -- The Advanced button, and nothing else. It is the one control in the
    -- default strip with no counterpart in the stock auction house, and the
    -- mockup gives it its own colour to say so.
    --
    -- 1.14.0 removed a purple VERTEX TINT from this button, which is not the
    -- same thing: a tint sat on top of another plate and read as a smudge.
    -- This is a plate in its own right.
    accent = {
        bg     = { 0.36, 0.26, 0.56 },
        over   = { 0.45, 0.33, 0.68 },
        down   = { 0.26, 0.18, 0.40 },
        border = { 0.58, 0.45, 0.80 },
        text   = { 0.95, 0.92, 1.00 },
        font   = "GameFontNormal",
    },
    quiet = {
        bg     = { 0.17, 0.16, 0.15 },
        over   = { 0.27, 0.25, 0.22 },
        down   = { 0.11, 0.10, 0.09 },
        border = { 0.13, 0.12, 0.10 },
        text   = { 0.80, 0.71, 0.42 },
        font   = "GameFontNormalSmall",
    },
}

-- Disabled is DERIVED, not a fourth hand-picked row: the concept just drops
-- the opacity. Deriving it means a palette edit can never leave the disabled
-- colour behind pointing at the old plate.
local BTN_DIM_BG, BTN_DIM_TEXT = 0.55, 0.45

local function DimRGB(c, f)
    return c[1] * f, c[2] * f, c[3] * f
end

-- Repaint `b` for its current state. Reads the state off the button rather
-- than taking it as an argument so every script can just call Repaint(b).
--
-- The backdrop target is resolved HERE, every time, not cached at creation:
-- under pfUI the visible plate is pfUI's own child frame (b.backdrop), and it
-- does not exist until skin.Apply runs -- which is after the window is built.
-- Same reason TintTab resolves it late for the sub-tabs.
local function RepaintButton(b)
    local k = BTN_KIND[b.aegisKind] or BTN_KIND.quiet
    local target = b
    if b.backdrop and b.backdrop.SetBackdropColor then target = b.backdrop end

    -- 1.12 returns 1/nil from IsEnabled(), not a boolean.
    local enabled = true
    if b.IsEnabled then
        local ok, v = pcall(function() return b:IsEnabled() end)
        if ok and not v then enabled = false end
    end

    local bg, br, tx = k.bg, k.border, k.text
    if enabled then
        if b.aegisDown then
            bg = k.down
        elseif b.aegisOver then
            bg = k.over
        end
    end

    if target.SetBackdropColor then
        if enabled then
            target:SetBackdropColor(bg[1], bg[2], bg[3], 1)
        else
            local r, g, bl = DimRGB(bg, BTN_DIM_BG)
            target:SetBackdropColor(r, g, bl, 1)
        end
    end
    if target.SetBackdropBorderColor then
        if enabled then
            target:SetBackdropBorderColor(br[1], br[2], br[3])
        else
            local r, g, bl = DimRGB(br, BTN_DIM_BG)
            target:SetBackdropBorderColor(r, g, bl)
        end
    end

    if b.label then
        -- aegisTextColor overrides the kind's text colour, and it has to be
        -- read HERE rather than set once by the caller: this function runs on
        -- every hover, press and enable, so anything that colours the label
        -- from outside is wiped by the next mouseover. The Min Quality
        -- dropdown uses it to show its selection in that quality's colour.
        local tc = b.aegisTextColor or tx
        if enabled then
            b.label:SetTextColor(tc[1], tc[2], tc[3])
        else
            local r, g, bl = DimRGB(tc, BTN_DIM_TEXT)
            b.label:SetTextColor(r, g, bl)
        end
        -- Press nudge. Done by moving the label ourselves rather than via
        -- SetPushedTextOffset, because that only fires for a font string
        -- registered with SetFontString and we deliberately do not depend on
        -- that call existing.
        local dy = 0
        if enabled and b.aegisDown then dy = -1 end
        b.label:ClearAllPoints()
        b.label:SetPoint("CENTER", b, "CENTER", 0, dy)
    end
end

-- Change a button's kind after creation and repaint it. This replaces what
-- ui.TintButton did for the accent buttons: there are no template textures to
-- vertex-colour any more, so "make this one stand out" means "make it
-- primary".
function ui.SetButtonKind(b, kind)
    if not b or not b.aegisButton then return end
    b.aegisKind = BTN_KIND[kind] and kind or "quiet"
    RepaintButton(b)
end

-- Mark exactly one of a row of segmented buttons as the chosen one.
-- `match(b)` answers true for it.
--
-- SIX loops used to do this with b:LockHighlight() / b:UnlockHighlight(), and
-- every one of them was doing NOTHING. LockHighlight drives a TEMPLATE
-- highlight texture; ui.MakeButton draws its own backdrop and has no such
-- texture, so the chosen duration, sell mode, undercut mode, throttle mode,
-- history period and post duration all looked identical to their neighbours.
--
-- This is the same bug that was found and fixed for the Advanced view tabs --
-- see the note in ui.SetBuyView. It was fixed there in one place and left
-- everywhere else, which is why this is now a shared function rather than a
-- seventh copy of the loop.
function ui.MarkChosen(btns, match)
    local i = 1
    while i <= table.getn(btns or {}) do
        local b = btns[i]
        if b then
            -- The kind it had BEFORE we ever touched it. Restoring "quiet"
            -- would be a guess, and a row of accent buttons would come back
            -- wrong the first time one was deselected.
            if not b.aegisBaseKind then
                b.aegisBaseKind = b.aegisKind or "quiet"
            end
            ui.SetButtonKind(b, match(b) and "primary" or b.aegisBaseKind)
        end
        i = i + 1
    end
end

-- Build an Aegis button. Drop-in for
--     ui.MakeButton(parent, "quiet", name)
-- -- the returned frame answers SetText/GetText/Enable/Disable/IsEnabled the
-- same way, so existing call sites keep working after the constructor swap.
function ui.MakeButton(parent, kind, name)
    local b = CreateFrame("Button", name, parent)
    b.aegisButton = true
    b.aegisKind = BTN_KIND[kind] and kind or "quiet"
    b:SetHeight(22)
    b:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })

    -- Recorded so ui/skin.lua can rebuild this font string on pfUI's backdrop
    -- frame with the same font. SetButtonKind only ever changes colours, so
    -- the font a button is born with is the font it keeps.
    b.aegisFont = (BTN_KIND[b.aegisKind] or BTN_KIND.quiet).font
    local fs = b:CreateFontString(nil, "OVERLAY", b.aegisFont)
    fs:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.label = fs

    -- SetText/GetText are defined on the OBJECT, shadowing the widget
    -- metatable for this frame only -- the same containment rule the tooltip
    -- hook follows. Nothing else that draws a Button is affected.
    b.SetText = function(self, t)
        self.aegisText = t or ""
        self.label:SetText(self.aegisText)
    end
    b.GetText = function(self) return self.aegisText or "" end
    -- Real 1.12 returns the font string REGISTERED with SetFontString, which
    -- for a template-less button is nil. Two callers measure a button's label
    -- through this to clip it (both dropdowns), and nil would error there, so
    -- answer it properly rather than leaving a hole for the sweep to fall in.
    b.GetFontString = function(self) return self.label end

    -- Enable/Disable exist and work already; they just have no look. Wrap
    -- them so the plate follows the state.
    local origEnable, origDisable = b.Enable, b.Disable
    b.Enable = function(self)
        if origEnable then origEnable(self) end
        RepaintButton(self)
    end
    b.Disable = function(self)
        if origDisable then origDisable(self) end
        self.aegisDown = false
        self.aegisOver = false
        RepaintButton(self)
    end

    -- These close over `b` rather than reading the global `this`. `this` is
    -- the right mechanism for a handler SHARED across frames, but each button
    -- already has itself in scope, and depending on the global means the
    -- script only works when the CLIENT is the one invoking it. It is not:
    -- the Filter Builder hides its action buttons from Lua the moment it
    -- builds them, which fires OnHide with no `this` set.
    b:SetScript("OnEnter", function()
        b.aegisOver = true
        RepaintButton(b)
    end)
    -- A press that drags off the button never sends it an OnMouseUp, so the
    -- pressed plate would stick until the next hover. OnLeave clears BOTH
    -- flags for that reason, not just the hover one.
    b:SetScript("OnLeave", function()
        b.aegisOver = false
        b.aegisDown = false
        RepaintButton(b)
    end)
    b:SetScript("OnMouseDown", function()
        b.aegisDown = true
        RepaintButton(b)
    end)
    b:SetScript("OnMouseUp", function()
        b.aegisDown = false
        RepaintButton(b)
    end)
    -- Hiding mid-press leaves the same stuck plate waiting for the reshow.
    b:SetScript("OnHide", function()
        b.aegisDown = false
        b.aegisOver = false
        RepaintButton(b)
    end)

    b:SetText("")
    RepaintButton(b)
    return b
end

-- A recessed content well: the dark inset panel a list or a form sits in.
-- The concept uses one for every content area (.well), and it is what stops an
-- area with little in it from reading as a hole in the window rather than as
-- an empty list.
--
-- `inset` is how far the well is pushed OUT past the frame it wraps, since a
-- well is drawn around its contents. Its backdrop border draws a few pixels
-- outside the frame rect, so anything anchored just below one needs to allow
-- for that -- see the 1.13.0 clipping fix.
function ui.MakeWell(parent, around, inset)
    inset = inset or 6
    local w = CreateFrame("Frame", nil, parent)
    w:SetPoint("TOPLEFT", around, "TOPLEFT", -inset, inset)
    w:SetPoint("BOTTOMRIGHT", around, "BOTTOMRIGHT", inset, -inset)
    w:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    w:SetBackdropColor(0.05, 0.04, 0.03, 0.85)
    w:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3])
    return w
end

-- Give an InputBoxTemplate edit box the mockup's flat field instead of
-- vanilla's art.
--
-- The template draws three textures -- a left cap, a right cap and a tiling
-- middle, all from Common-Input-Border. At a text field's width that reads as
-- a long rounded trough; at the width of a level-range box it reads as two
-- brackets with a gap, which is what got reported as "( )" shapes. Neither is
-- the mockup's flat dark rectangle with a thin border.
--
-- We keep the template -- it carries the cursor, selection and focus
-- behaviour, none of which is worth reimplementing -- and only replace what
-- it DRAWS. The textures are found through GetRegions() rather than by
-- $parentLeft/$parentMiddle/$parentRight, because most of these boxes are
-- created without a name and getglobal has nothing to look up.
function ui.FlattenEditBox(e)
    if not e then return e end
    local regions = { e:GetRegions() }
    local i = 1
    while i <= table.getn(regions) do
        local r = regions[i]
        local ok, t = pcall(function() return r:GetObjectType() end)
        if ok and t == "Texture" then pcall(function() r:Hide() end) end
        i = i + 1
    end
    e:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    e:SetBackdropColor(0.06, 0.05, 0.04, 1)
    e:SetBackdropBorderColor(0.42, 0.35, 0.20)
    return e
end

-- A square check box, at any size, in either skin.
--
-- Two problems this solves.
--
-- 1. A `SetBackdrop` whose edgeSize approaches the frame size renders as a
--    garbled CROSS, not a box: the two corner pieces are each edgeSize square
--    and physically cannot both fit across a 14px frame. The result rows used
--    edgeSize 8 in a 14px button. Borders here are four 1px textures, which
--    stay square at any size.
--
-- 2. pfUI reskins anything reporting `CheckButton` -- that is what turned the
--    row boxes into crosses and "Usable items" into a circle under the skin
--    while they looked correct unskinned. aegisNoSkin opts out, the same way
--    the sort headers and category rows already do.
--
-- The checked state stays the WIDGET's OWN state -- SetChecked/GetChecked are
-- deliberately NOT overridden. A CheckButton toggles itself before OnClick
-- runs, and every handler in this file is written against that (they read
-- GetChecked() inside OnClick and expect the new value). Shadowing those two
-- methods with our own flag would leave the widget's state and ours
-- disagreeing, and each of those handlers would silently read the wrong one.
-- Instead we only replace the ART: the tick is the widget's CHECKED texture,
-- so the client shows and hides it for us and it can never drift.
function ui.MakeCheckBox(parent, size, name)
    size = size or 14
    local c = CreateFrame("CheckButton", name, parent)
    c:SetWidth(size); c:SetHeight(size)
    c.aegisNoSkin = true          -- our art, not pfUI's

    local fill = c:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints(c)
    fill:SetTexture(0.08, 0.07, 0.06, 1)
    c.fill = fill

    c.edge = {}
    local ei = 1
    while ei <= 4 do
        local ln = c:CreateTexture(nil, "BORDER")
        ln:SetTexture(0.45, 0.38, 0.22, 1)
        c.edge[ei] = ln
        ei = ei + 1
    end
    c.edge[1]:SetPoint("TOPLEFT", c, "TOPLEFT", 0, 0)
    c.edge[1]:SetPoint("TOPRIGHT", c, "TOPRIGHT", 0, 0)
    c.edge[1]:SetHeight(1)
    c.edge[2]:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 0, 0)
    c.edge[2]:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 0)
    c.edge[2]:SetHeight(1)
    c.edge[3]:SetPoint("TOPLEFT", c, "TOPLEFT", 0, 0)
    c.edge[3]:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 0, 0)
    c.edge[3]:SetWidth(1)
    c.edge[4]:SetPoint("TOPRIGHT", c, "TOPRIGHT", 0, 0)
    c.edge[4]:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 0)
    c.edge[4]:SetWidth(1)

    -- SetCheckedTexture takes a PATH on 1.12, not a texture object, so the
    -- texture has to be created from a file that exists -- then immediately
    -- re-pointed and repainted as a flat colour, which SetTexture(r,g,b,a)
    -- does without touching the file again. If a client ever fails to hand
    -- back the region, the stock check mark stays: wrong art, still legible,
    -- never a box you cannot read the state of.
    pcall(function()
        c:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    end)
    local tick
    pcall(function() tick = c:GetCheckedTexture() end)
    if tick then
        tick:ClearAllPoints()
        tick:SetPoint("TOPLEFT", c, "TOPLEFT", 3, -3)
        tick:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -3, 3)
        tick:SetTexture(1.0, 0.82, 0.0, 1)
        c.tick = tick
    end

    -- Caption to the right of the box. UICheckButtonTemplate supplied one as
    -- a global named "<name>Text"; ours is a plain field, so the settings
    -- rows no longer need a name just to reach their own label.
    c.SetLabel = function(self, text, colour)
        if not self.label then
            self.label = self:CreateFontString(nil, "OVERLAY",
                "GameFontHighlightSmall")
            self.label:SetPoint("LEFT", self, "RIGHT", 5, 0)
            self.label:SetJustifyH("LEFT")
        end
        self.label:SetText(text)
        if colour then
            self.label:SetTextColor(colour[1], colour[2], colour[3])
        end
        return self.label
    end

    -- Dimmed rather than hidden, so a row you cannot tick still reads as a
    -- row with a tick box rather than one missing a column. Pairs with
    -- Disable(), which is what actually refuses the click.
    c.SetDimmed = function(self, on)
        local a = on and 0.30 or 1
        self.fill:SetAlpha(a)
        if self.tick then self.tick:SetAlpha(a) end
        local k = 1
        while k <= 4 do self.edge[k]:SetAlpha(a); k = k + 1 end
        if self.label then self.label:SetAlpha(on and 0.45 or 1) end
        if on then self:Disable() else self:Enable() end
    end
    return c
end

-- Set `text` on a FontString, shortened with an ellipsis if it would run wider
-- than `maxWidth` pixels.
--
-- 1.12 has no ellipsis/truncation mode for FontStrings: calling SetWidth() makes
-- long text WRAP onto a second line rather than clip, which inside a fixed-height
-- row looks worse than the overflow it was meant to fix. So we deliberately do
-- NOT constrain the FontString and instead measure with GetStringWidth() and cut
-- the string ourselves. Binary search keeps it to ~6 SetText calls rather than
-- one per character.
function ui.SetTextClipped(fs, text, maxWidth)
    text = text or ""
    fs:SetText(text)
    if not maxWidth or maxWidth <= 0 then return end
    if fs:GetStringWidth() <= maxWidth then return end
    local lo, hi = 0, string.len(text)
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        fs:SetText(string.sub(text, 1, mid) .. "...")
        if fs:GetStringWidth() <= maxWidth then lo = mid else hi = mid - 1 end
    end
    fs:SetText(string.sub(text, 1, lo) .. "...")
end

-- ---------------------------------------------------------------------------
-- Window sizing
-- ---------------------------------------------------------------------------

-- Remember the size per character (AegisExchangeCharDB.ui is exactly the
-- "window position, open tab, column widths" bucket db.lua describes).
function ui.SaveWindowSize()
    if not ui.frame or not A.db or not A.db.char then return end
    local s = A.db.char.ui
    if not s then s = {}; A.db.char.ui = s end
    s.width  = math.floor(ui.frame:GetWidth() or MIN_W)
    s.height = math.floor(ui.frame:GetHeight() or MIN_H)
end

-- Remember where the window was dragged to.
--
-- All FOUR values, not just x and y: GetPoint returns the anchor it is
-- currently using, and a pair of offsets means nothing without the point they
-- are measured from. Storing only x/y and restoring against CENTER puts the
-- window somewhere it has never been.
function ui.SaveWindowPoint()
    if not ui.frame or not A.db or not A.db.char then return end
    local s = A.db.char.ui
    if not s then s = {}; A.db.char.ui = s end
    local ok, point, _, relPoint, x, y = pcall(function()
        return ui.frame:GetPoint(1)
    end)
    if not ok or not point then return end
    s.point    = point
    s.relPoint = relPoint or point
    s.x        = math.floor(x or 0)
    s.y        = math.floor(y or 0)
end

-- Would this saved point put the window somewhere it can still be dragged?
--
-- THE CASE THIS EXISTS FOR: a window saved near the edge of a large screen,
-- restored on a smaller one, lands with its title bar off-screen -- and the
-- title bar is the only drag handle, so there is no way back short of wiping
-- the saved variables. Anything that can strand a user gets checked, not
-- assumed.
--
-- Deliberately generous: it asks only that a reasonable slice of the title bar
-- is reachable, not that the whole window fits. Someone who likes their window
-- half off the edge is allowed to keep it there.
local GRAB_MARGIN = 80      -- of title bar that must remain on screen
local BAR_H = 26            -- ...and its height, for the bottom-edge check
function ui.PointIsReachable(point, relPoint, x, y, screenW, screenH,
                             winW, winH)
    if not point or not relPoint then return false end
    screenW, screenH = screenW or 0, screenH or 0
    winW, winH = winW or 0, winH or 0
    -- An unmeasured screen means UIParent has not been laid out yet. Refusing
    -- the saved point there would move the window to CENTER on some logins,
    -- which is worse than the fault this guards against.
    if screenW <= 0 or screenH <= 0 then return true end

    -- Convert the anchor and its offsets into the frame's LEFT and TOP edges,
    -- both measured from the screen's top-left with DOWN and RIGHT positive.
    -- The offsets mean different things per anchor, and the window's own size
    -- is needed for the far edges -- a BOTTOM anchor fixes the frame's bottom,
    -- so its top depends on how tall the frame is.
    local left
    if string.find(relPoint, "LEFT") then
        left = x
    elseif string.find(relPoint, "RIGHT") then
        left = screenW + x - winW
    else
        left = screenW / 2 + x - winW / 2
    end

    local top
    if string.find(relPoint, "TOP") then
        top = -y                                  -- y is negative going down
    elseif string.find(relPoint, "BOTTOM") then
        top = screenH - (y + winH)
    else
        top = screenH / 2 - y - winH / 2
    end

    -- A grabbable slice of the title bar has to be on screen horizontally,
    -- and the bar itself has to be within the screen vertically.
    if left + GRAB_MARGIN > screenW then return false end
    if left + winW - GRAB_MARGIN < 0 then return false end
    if top < 0 then return false end                    -- above the top edge
    if top > screenH - BAR_H then return false end      -- below the bottom
    return true
end

-- The window's size, held inside the range it is designed for.
--
-- Pure arithmetic, split out from the frame calls so the invariant "the window
-- is never below MIN" can be asserted rather than only commented. nil means
-- "no saved size", which is the case that shipped a clipped window.
function ui.ClampWindowSize(w, h)
    w = w or MIN_W
    h = h or MIN_H
    if w < MIN_W then w = MIN_W end
    if h < MIN_H then h = MIN_H end
    if w > MAX_W then w = MAX_W end
    if h > MAX_H then h = MAX_H end
    return w, h
end

function ui.RestoreWindowSize()
    if not ui.frame or not A.db or not A.db.char then return end
    -- Scale first, and unconditionally: it is stored independently of the size,
    -- so someone who scaled the window but never dragged it bigger has no saved
    -- width to restore -- and would otherwise lose their scale every login.
    ui.ApplyWindowScale()
    -- NOT `if not s then return end`. A character who has never resized has no
    -- `ui` table at all, and that is exactly the case this function most needs
    -- to run for -- returning early there is what let a fresh install open
    -- below MIN_W. An empty stand-in gives the clamp below something to read
    -- and costs nothing: there is no saved point to clear either.
    local s = A.db.char.ui or {}

    -- Clamped UNCONDITIONALLY, not only when there is a size to restore.
    --
    -- The `if s.width and s.height` guard used to wrap this whole block, so
    -- with nothing saved the frame kept whatever CreateFrame had given it --
    -- and that literal had been left behind at 832 x 460 when MIN_W rose to
    -- 1000. Reading the frame's own size and clamping it makes "the window is
    -- never below MIN" true however it got here, so the next drift in a
    -- default cannot ship as a clipped window again.
    local w, h = ui.ClampWindowSize(s.width or ui.frame:GetWidth(),
                                    s.height or ui.frame:GetHeight())
    ui.frame:SetWidth(w)
    ui.frame:SetHeight(h)

    -- Put it back where it was left -- but only if that is somewhere it can
    -- still be dragged from. See ui.PointIsReachable: the title bar is the
    -- only drag handle, so a point restored off-screen on a smaller monitor
    -- would strand the window with no way back.
    if s.point and s.relPoint then
        local sw = (UIParent and UIParent.GetWidth
                    and UIParent:GetWidth()) or 0
        local sh = (UIParent and UIParent.GetHeight
                    and UIParent:GetHeight()) or 0
        if ui.PointIsReachable(s.point, s.relPoint, s.x or 0, s.y or 0,
                               sw, sh, ui.frame:GetWidth() or 0,
                               ui.frame:GetHeight() or 0) then
            ui.frame:ClearAllPoints()
            ui.frame:SetPoint(s.point, UIParent, s.relPoint,
                              s.x or 0, s.y or 0)
        else
            -- Unreachable: centre it and forget the bad point, so the next
            -- drag saves a good one instead of this running every login.
            ui.frame:ClearAllPoints()
            ui.frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            s.point, s.relPoint, s.x, s.y = nil, nil, nil, nil
        end
    end

    ui.QueueRepaint()
end

-- Repaint the open tab on the NEXT OnUpdate tick.
--
-- Deferred deliberately. The client relayouts frames one tick after an
-- ancestor's size changes, so calling RefreshCurrentTab inline here would
-- read exactly the stale numbers this exists to avoid. The Buy tab no longer
-- depends on that -- it derives from the window's own height -- but every
-- other list still measures, and they all need the second look.
function ui.QueueRepaint()
    if not ui.frame then return end
    if not ui.repaintDriver then
        local drv = CreateFrame("Frame", nil, ui.frame)
        drv:Hide()
        drv:SetScript("OnUpdate", function()
            this:Hide()
            -- Width-driven layout goes first: the Advanced tab strip spreads
            -- itself across the panel, so it has to be re-spread on a resize
            -- or it keeps whatever widths the previous size gave it.
            if ui.LayoutViewTabs then ui.LayoutViewTabs() end
            if ui.LayoutAdvColumns then ui.LayoutAdvColumns() end
            if ui.LayoutBuilderForm then ui.LayoutBuilderForm() end
            if ui.RefreshCurrentTab then ui.RefreshCurrentTab() end
        end)
        ui.repaintDriver = drv
    end
    ui.repaintDriver:Show()
end

-- ---------------------------------------------------------------------------
-- Window scale
--
-- Resizing and scaling answer different questions. A taller window shows MORE
-- rows (vanilla frames never reflow, so that is all it can do); scale makes
-- the same window physically bigger or smaller. On a 4K screen you want both:
-- more rows AND text you can read.
--
-- Stored per character alongside the size, and clamped -- below ~0.6 the
-- fonts stop being legible and above ~1.5 the window no longer fits a 1024-
-- tall screen at MAX_H.
-- ---------------------------------------------------------------------------

local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.70, 1.50, 0.05

function ui.WindowScale()
    if not A.db or not A.db.char then return 1 end
    local s = A.db.char.ui
    local v = s and s.scale
    if not v or v < SCALE_MIN then return 1 end
    if v > SCALE_MAX then return SCALE_MAX end
    return v
end

-- Push the stored scale onto the window. Safe to call before the DB exists.
function ui.ApplyWindowScale()
    if not ui.frame or not ui.frame.SetScale then return end
    ui.frame:SetScale(ui.WindowScale())
end

-- Nudge the scale by `delta` (pass nil to reset to 1.0).
function ui.StepWindowScale(delta)
    if not A.db or not A.db.char then return end
    local v = 1
    if delta then
        v = ui.WindowScale() + delta
        -- Round to the step so repeated nudges can't drift off it.
        v = math.floor(v * 100 + 0.5) / 100
        if v < SCALE_MIN then v = SCALE_MIN end
        if v > SCALE_MAX then v = SCALE_MAX end
    end
    local s = A.db.char.ui
    if not s then s = {}; A.db.char.ui = s end
    s.scale = v
    ui.ApplyWindowScale()
    -- No list repaint needed: scale leaves every measurement in frame units
    -- exactly where it was, so the row fit and the text truncation are both
    -- unchanged. Only the readout has to catch up.
    ui.RefreshSettings()
end

-- Skin any rows in `pool` that were grown after the skin's one-shot pass.
-- Flagged per row so this stays cheap on the paint path -- it runs on every
-- list update, but only ever does work the first time a row appears.
function ui.SkinNewRows(pool)
    if not pool or not A.skin or not A.skin.SkinNew then return end
    local i = 1
    local n = table.getn(pool)
    while i <= n do
        local row = pool[i]
        if row and not row.aegisRowSkinned then
            row.aegisRowSkinned = true
            A.skin.SkinNew(row)
        end
        i = i + 1
    end
end

-- How many rows of `rowH` actually fit in `scroll` at its current height.
-- This is what makes a taller window show more listings instead of more blank
-- space: every list asks at paint time rather than trusting the count it was
-- built with.
--
-- `minRows` is the answer when the frame has NO measurable height -- it has
-- not been laid out yet, or there is no frame at all. It is NOT a floor on a
-- real measurement, and the difference is the whole bug this signature had.
--
-- When rows grew from 20px to 26px, a floor of 11 kept insisting on 11 rows
-- in a space that now held eight. Rows anchor to each other and are not the
-- scroll frame's scroll-child, so nothing clips them: the surplus three drew
-- straight down over the match count, the pager, the bid boxes and the action
-- bar. A measured fit must win over any expectation of how many "should" fit,
-- because the measurement is the only thing that knows about the space.
--
-- (1.14.1 raised a floor from 1 to 12 for the Saved Searches list, which is
-- the OTHER case: a two-edge-anchored frame reports 0 until the client lays
-- it out, and painting one row on that pass was wrong. Both behaviours are
-- correct; they are just not the same parameter, and conflating them is what
-- produced an overflowing table.)
-- WARNING -- THIS MEASURES A FRAME, AND MEASURING IS A TRAP.
--
-- GetHeight() on a frame anchored by TWO EDGES returns the height it was last
-- LAID OUT at, not its current one; the client relayouts a frame after its
-- ancestor's size changes. Restoring a saved window size and then asking a
-- two-edge-anchored scroll frame how tall it is gets the answer from the
-- window's CREATION size, forever.
--
-- That has now cost three separate bugs: the Buy table's row count (fixed by
-- ui.PanelHeightAt), the Advanced layout's widths (ui.PanelWidthAt, 1.19.2)
-- and the Saved Searches lists (ui.SavedRowsAt, 1.19.4). Each replaced a call
-- to this function with arithmetic on the WINDOW's height, which is set
-- explicitly and is therefore true the moment it is read.
--
-- THE AUDIT IS DONE AND THIS FUNCTION IS GONE. The remaining six callers --
-- Crafting, its recipe tree, Auctions, History, and the Sell tab's bag and
-- listings lists -- every one anchored its scroll frame by two corners, so
-- every one of them was carrying the fault. They derive from the window's
-- height through ui.ListRowsAt now, and there is no measuring version left to
-- reach for.
--
-- ui.RowsFor is deliberately NOT kept as a shim. A trap that four separate
-- bugs walked into does not want a convenient spelling.

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
    b.aegisFont = "GameFontNormalSmall"
    local fs = b:CreateFontString(nil, "OVERLAY", b.aegisFont)
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
    -- THE DEFAULT IS THE MINIMUM, and it must be, because nothing in this
    -- window is laid out for anything smaller.
    --
    -- This was 832 x 460 -- the size the window was created at back when
    -- MIN_W was 832 -- and it stayed a literal when MIN_W went to 1000 and
    -- MIN_H to 492. The note above MIN_W reasoned about the SAVED size
    -- ("clamped UP by RestoreWindowSize") and never about the case with no
    -- saved size at all, which is every fresh install: the window opened
    -- 168px narrower than its own declared minimum, `ui.ColumnsFitAt` puts
    -- the true column floor at ~970, and the result table's right-hand
    -- columns ran off the panel.
    --
    -- It presented as "the window is clipped until you touch the resize
    -- grip", because SetMinResize snaps the frame to MIN the instant sizing
    -- starts and OnMouseUp saves that size -- so one drag fixed it forever
    -- and nobody who had ever resized could reproduce it. Screen resolution
    -- and pfUI had nothing to do with it either way.
    f:SetWidth(MIN_W)
    f:SetHeight(MIN_H)
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
    titleBar:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        ui.SaveWindowPoint()
    end)
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
    -- Flagged so the pfUI skin uses its close-button helper rather than the
    -- generic one (which would strip the X and leave an empty box).
    close.aegisCloseButton = true
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
    close:SetFrameLevel(f:GetFrameLevel() + 10)
    close:SetScript("OnClick", function()
        ui.CloseWindow()
    end)

    -- Swap to the stock Blizzard AH (its counterpart button swaps back —
    -- see HookAuctionFrame). Raised above the title bar's drag region and
    -- anchored to the close button so it sits neatly on the extended bar.
    local blizBtn = ui.MakeButton(f, "quiet", "AegisExchangeBlizzardButton")
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

    -- ---- Resize grip ----------------------------------------------------
    -- Everything inside the window already anchors to its panel's edges, so
    -- widening or heightening the frame carries the panels and their scroll
    -- frames with it for free. The only thing that doesn't follow on its own
    -- is how many ROWS each list draws -- see ui.RowsFor, which recomputes
    -- that from the live height, so dragging taller genuinely shows more
    -- listings rather than leaving a blank gap.
    f:SetResizable(true)
    if f.SetMinResize then f:SetMinResize(MIN_W, MIN_H) end
    if f.SetMaxResize then f:SetMaxResize(MAX_W, MAX_H) end

    -- On the OUTER border, not inside the content well. The well is inset 14
    -- right / 16 bottom, so a 16px grip at -6,6 spanned 6..22 -- more than half
    -- of it sitting inside the recessed panel. 14px at -2,2 spans 2..16, which
    -- lands it on the frame's own border where a resize handle belongs.
    local grip = CreateFrame("Button", "AegisExchangeResizeGrip", f)
    grip:SetWidth(14)
    grip:SetHeight(14)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    grip:SetFrameLevel(f:GetFrameLevel() + 12)
    grip.aegisNoSkin = true
    local gripTex = grip:CreateTexture(nil, "OVERLAY")
    gripTex:SetAllPoints(grip)
    gripTex:SetTexture("Interface\\AddOns\\Aegis_Exchange\\media\\ResizeGrip")
    grip.tex = gripTex
    grip:SetScript("OnMouseDown", function()
        f.aegisSizing = true
        f:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        f.aegisSizing = false
        f:StopMovingOrSizing()
        ui.SaveWindowSize()
        ui.Refresh()
        ui.LayoutViewTabs()      -- re-centre the Advanced tabs
        ui.LayoutAdvColumns()    -- ...re-split BOTH overlay views together
        ui.LayoutBuilderForm()   -- ...and size the builder's own controls
        ui.RefreshCurrentTab()   -- re-fit the visible list to the new height
    end)
    -- Deliberately NO per-frame refresh while dragging. Repainting mid-drag
    -- means calling FauxScrollFrame_Update with a row count that is changing
    -- every frame; that moves the scrollbar's range, which fires
    -- OnVerticalScroll, which calls the update function again -- a recursion
    -- that only terminates because the range normally holds still. While
    -- resizing it doesn't. The lists re-fit once, on release.
    grip:SetScript("OnEnter", function() gripTex:SetVertexColor(1, 0.9, 0.4) end)
    grip:SetScript("OnLeave", function() gripTex:SetVertexColor(1, 1, 1) end)
    ui.resizeGrip = grip

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

    -- One panel per sub-tab, filling the content region. Each is populated by
    -- its own Build*Tab function below.
    ui.panels = {}
    i = 1
    while i <= nTabs do
        local name = SUBTABS[i]
        local panel = CreateFrame("Frame", "AegisExchangePanel" .. name, content)
        panel:SetPoint("TOPLEFT", content, "TOPLEFT", 6, -6)
        panel:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -6, 6)
        panel:Hide()
        ui.panels[name] = panel
        i = i + 1
    end

    -- Scan tab: Full Scan / Pause / Resume / Categories + status + progress.
    local scanPanel = ui.panels["Scan"]

    local fullScan = ui.MakeButton(scanPanel, "primary", "AegisExchangeFullScanButton")
    fullScan:SetWidth(100)
    fullScan:SetHeight(22)
    fullScan:SetPoint("TOPLEFT", scanPanel, "TOPLEFT", 8, -10)
    fullScan:SetText("Full Scan")
    fullScan:SetScript("OnClick", function()
        ui.ConfirmFullScan()
    end)
    ui.fullScanBtn = fullScan

    local pause = ui.MakeButton(scanPanel, "quiet", "AegisExchangePauseButton")
    pause:SetWidth(74)
    pause:SetHeight(22)
    pause:SetPoint("LEFT", fullScan, "RIGHT", 6, 0)
    pause:SetText("Pause")
    pause:SetScript("OnClick", function()
        A.scan.Pause()
        ui.Refresh()
    end)
    ui.pauseBtn = pause

    local resume = ui.MakeButton(scanPanel, "quiet", "AegisExchangeResumeButton")
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
    local stop = ui.MakeButton(scanPanel, "quiet", "AegisExchangeStopButton")
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

    local cats = ui.MakeButton(scanPanel, "quiet", "AegisExchangeCategoriesButton")
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

    -- The settings block lives in a REAL ScrollFrame, not a FauxScrollFrame.
    -- Every other tab virtualises fixed-height rows, which is what
    -- FauxScrollFrame is for; settings are heterogeneous widgets that can't be
    -- recycled into rows. A ScrollFrame is also the only 1.12 widget that
    -- CLIPS its child -- this client has no SetClipsChildren -- so it's the
    -- only way to keep overflow inside the window instead of spilling past the
    -- bottom edge, which is what 1.1.1 did once the pacing and confirm-cancel
    -- rows were added.
    local SB_W = 16
    local scroll = CreateFrame("ScrollFrame", "AegisExchangeAegisScroll",
        scanPanel)
    -- Pulled left by exactly the inset the content carries, so the settings
    -- block still lines up with the tip line above it.
    scroll:SetPoint("TOPLEFT", tip, "BOTTOMLEFT", -SET_INSET, -8)
    scroll:SetPoint("BOTTOMRIGHT", scanPanel, "BOTTOMRIGHT", -(SB_W + 10), 6)
    ui.aegisScroll = scroll

    local scrollChild = CreateFrame("Frame", "AegisExchangeAegisScrollChild",
        scroll)
    scrollChild:SetWidth(600)
    scrollChild:SetHeight(300)
    scroll:SetScrollChild(scrollChild)
    ui.aegisScrollChild = scrollChild

    -- Hand-built from a base Slider rather than inheriting a scroll template:
    -- Slider is a primitive widget type that always exists, so there's no
    -- "Couldn't find inherited node" risk from guessing a 1.12 template name
    -- (the AuctionFrameTab lesson), and it matches the Aegis palette. Marked
    -- aegisNoSkin because pfUI's SkinScrollbar reaches for the up/down buttons
    -- a template would have supplied.
    local sb = CreateFrame("Slider", "AegisExchangeAegisScrollBar", scanPanel)
    sb.aegisNoSkin = true
    sb:SetWidth(SB_W)
    sb:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 8, 0)
    sb:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 8, 0)
    sb:SetOrientation("VERTICAL")
    sb:SetMinMaxValues(0, 0)
    sb:SetValue(0)
    sb:SetValueStep(1)
    sb:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
    local thumb = sb:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture("Interface\\Buttons\\UI-SliderBar-Button-Vertical")
    thumb:SetWidth(SB_W)
    thumb:SetHeight(24)
    sb:SetThumbTexture(thumb)
    -- 1.12: the scripted widget is the global `this`, never a self argument.
    sb:SetScript("OnValueChanged", function()
        scroll:SetVerticalScroll(this:GetValue())
    end)
    sb:Hide()
    ui.aegisScrollBar = sb

    -- Wheel over the settings area scrolls it. arg1 is the wheel delta global
    -- (+1 up / -1 down) on this client.
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function()
        local _, maxV = sb:GetMinMaxValues()
        local v = sb:GetValue() - (arg1 * 24)
        if v < 0 then v = 0 end
        if v > maxV then v = maxV end
        sb:SetValue(v)
    end)

    ui.BuildAegisSettings(scrollChild, nil)
    ui.BuildSellTab()
    ui.BuildBuyTab()
    ui.BuildCraftTab()
    ui.BuildAuctionsTab()
    ui.BuildHistoryTab()

    -- Apply the remembered size once every tab exists, so the first paint
    -- already fits the restored height rather than snapping a frame later.
    ui.RestoreWindowSize()

    -- Live refresh while a scan runs (elapsed is the GLOBAL arg1). Only ticks
    -- while the window is shown, i.e. while the AH is open.
    ui.refreshAccum = 0
    f:SetScript("OnUpdate", function()
        ui.refreshAccum = ui.refreshAccum + arg1
        if ui.refreshAccum >= 0.3 then
            ui.refreshAccum = 0
            if A.scan.IsRunning() or A.scan.IsPaused() then
                ui.Refresh()
                -- Keep the Sell tab's per-item scan header ticking too, so it
                -- shows the same live page / ETA / rate as the Aegis strip.
                if ui.selectedSubTab == "Sell" and ui.sellScanState == "scanning" then
                    ui.UpdateListingsList()
                end
            end
        end
    end)

    -- Match pfUI's look when pfUI is installed (purely cosmetic, and a no-op
    -- otherwise). Runs last so every widget above already exists.
    if A.skin then A.skin.Apply() end

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

-- Distance from a frame's top edge to the lowest edge of anything inside it.
-- Measured rather than hardcoded so that adding a setting later can't silently
-- clip again. Returns nil until the frame has actually been laid out (GetTop
-- is nil while hidden), so callers keep the last good value.
local function ContentExtent(frame)
    local top = frame:GetTop()
    if not top then return nil end
    local lowest = top
    local function sweep(list)
        local i = 1
        local n = table.getn(list)
        while i <= n do
            local o = list[i]
            if o and o.GetBottom then
                local b = o:GetBottom()
                if b and b < lowest then lowest = b end
            end
            i = i + 1
        end
    end
    -- 1.12 returns these as multiple values; the table constructor captures
    -- them without needing select(), which doesn't exist on Lua 5.0.
    sweep({ frame:GetChildren() })
    sweep({ frame:GetRegions() })
    return top - lowest
end

-- Fit the Aegis tab's scroll child to its content and update the bar's range.
-- Hides the bar entirely when everything already fits.
function ui.UpdateAegisScroll()
    local scroll = ui.aegisScroll
    local child = ui.aegisScrollChild
    local sb = ui.aegisScrollBar
    if not scroll or not child or not sb then return end

    local w = scroll:GetWidth()
    if w and w > 0 then child:SetWidth(w) end

    local measured = ContentExtent(child)
    if measured then
        ui.aegisContentH = measured + 10   -- breathing room under the last row
    end
    local contentH = ui.aegisContentH or 300
    child:SetHeight(contentH)

    local viewH = scroll:GetHeight() or 0
    local maxScroll = contentH - viewH
    if maxScroll < 1 then
        sb:SetMinMaxValues(0, 0)
        sb:SetValue(0)
        sb:Hide()
    else
        sb:SetMinMaxValues(0, maxScroll)
        if sb:GetValue() > maxScroll then sb:SetValue(maxScroll) end
        sb:Show()
    end
end

-- `anchorAbove` is optional: when the settings sit in the Aegis tab's scroll
-- child they start at its top instead of hanging off the scan controls.
function ui.BuildAegisSettings(panel, anchorAbove)
    -- Section header under the scan controls.
    local hdr = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if anchorAbove then
        hdr:SetPoint("TOPLEFT", anchorAbove, "BOTTOMLEFT", 0, -18)
    else
        hdr:SetPoint("TOPLEFT", panel, "TOPLEFT", SET_INSET, -4)
    end
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
        local b = ui.MakeButton(panel, "quiet")
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

    local pctMode = ui.MakeButton(panel, "quiet")
    pctMode:SetWidth(34); pctMode:SetHeight(20)
    pctMode:SetPoint("LEFT", ucLbl, "RIGHT", 10, 0)
    pctMode:SetText("%")
    pctMode.mode = "pct"
    pctMode:SetScript("OnClick", function()
        A.db.SetSetting("undercutMode", "pct"); ui.RefreshSettings()
    end)
    local flatMode = ui.MakeButton(panel, "quiet")
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

    -- Flat-amount entry. A gold/silver/copper triplet, the same widget the Sell
    -- tab uses for bid and buyout -- one way to type a price everywhere.
    --
    -- Committing on every keystroke would repaint the boxes from the stored
    -- value while the user is still typing, so the live edits commit QUIETLY
    -- and only losing focus (or pressing Enter) triggers the full repaint.
    local flat = MakeMoneyGSC(panel, function() ui.CommitUndercutFlat(true) end)
    flat:Attach(pctLbl, 12, 0)
    local fbox = { flat.g, flat.s, flat.c }
    local fi = 1
    while fi <= 3 do
        fbox[fi]:SetScript("OnEditFocusLost", function()
            ui.CommitUndercutFlat()
        end)
        fi = fi + 1
    end
    ui.setUndercutFlat = flat
    -- Percent, then the three coins. Only one of the two is on screen at a
    -- time -- ui.NextInputIn skips whichever the mode has hidden.
    ui.LinkTabOrder({ uc, flat.g, flat.s, flat.c })
    local flatLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    flatLbl:SetPoint("LEFT", flat.c.tag, "RIGHT", 8, 0)
    flatLbl:SetText("below")
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
        local b = ui.MakeButton(panel, "quiet")
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

    -- ---- Window scale ------------------------------------------------------
    -- Deliberately buttons rather than a slider. A slider that rescales the
    -- window it lives on moves itself out from under the cursor mid-drag, and
    -- the thumb then tracks to a different value -- a feedback loop. Discrete
    -- steps have no such problem and are easier to land on a round number.
    local scLbl = label("Window scale:", spLbl, -20)

    local scDown = ui.MakeButton(panel, "quiet")
    scDown:SetWidth(24); scDown:SetHeight(20)
    scDown:SetPoint("LEFT", scLbl, "RIGHT", 10, 0)
    scDown:SetText("-")
    scDown:SetScript("OnClick", function() ui.StepWindowScale(-SCALE_STEP) end)

    ui.setScaleText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.setScaleText:SetPoint("LEFT", scDown, "RIGHT", 8, 0)
    ui.setScaleText:SetWidth(40)
    ui.setScaleText:SetJustifyH("CENTER")
    ui.setScaleText:SetTextColor(C.text[1], C.text[2], C.text[3])

    local scUp = ui.MakeButton(panel, "quiet")
    scUp:SetWidth(24); scUp:SetHeight(20)
    scUp:SetPoint("LEFT", ui.setScaleText, "RIGHT", 8, 0)
    scUp:SetText("+")
    scUp:SetScript("OnClick", function() ui.StepWindowScale(SCALE_STEP) end)

    local scReset = ui.MakeButton(panel, "quiet")
    scReset:SetWidth(56); scReset:SetHeight(20)
    scReset:SetPoint("LEFT", scUp, "RIGHT", 10, 0)
    scReset:SetText("Reset")
    scReset:SetScript("OnClick", function() ui.StepWindowScale(nil) end)

    -- ---- Toggles ----------------------------------------------------------
    local tipChk = ui.MakeCheckBox(panel, 18, "AegisExchangeSetTooltip")
    tipChk:SetPoint("TOPLEFT", scLbl, "BOTTOMLEFT", -2, -16)
    tipChk:SetLabel("Show Aegis price lines on item tooltips", C.text)
    tipChk:SetScript("OnClick", function()
        A.db.SetSetting("tooltip", tipChk:GetChecked() and true or false)
        ui.RefreshSettings()   -- grey the per-line options with the master
    end)
    ui.setTooltip = tipChk

    -- Per-line tooltip options, indented under the master toggle because they
    -- only mean anything while it's on. Tooltips now reach loot, quest rewards
    -- and profession reagents as well as bags and the AH, so being able to trim
    -- the lines back matters more than it did.
    local tipSubs = {
        { key = "tipMarket",     text = "Market value" },
        { key = "tipMinBuyout",  text = "Minimum buyout" },
        { key = "tipVendor",     text = "Vendor price" },
    }
    ui.setTipSubs = {}
    local prevSub = nil
    local si = 1
    while si <= table.getn(tipSubs) do
        local spec = tipSubs[si]
        local c = ui.MakeCheckBox(panel, 16, "AegisExchangeSet" .. spec.key)
        if prevSub then
            c:SetPoint("TOPLEFT", prevSub, "BOTTOMLEFT", 0, -4)
        else
            c:SetPoint("TOPLEFT", tipChk, "BOTTOMLEFT", 18, -6)
        end
        c:SetLabel(spec.text, C.goldDim)
        c.settingKey = spec.key
        c:SetScript("OnClick", function()
            A.db.SetSetting(c.settingKey, c:GetChecked() and true or false)
        end)
        ui.setTipSubs[si] = c
        prevSub = c
        si = si + 1
    end

    local stackChk = ui.MakeCheckBox(panel, 16,
        "AegisExchangeSetTipStackShift")
    stackChk:SetPoint("TOPLEFT", prevSub, "BOTTOMLEFT", 0, -4)
    stackChk:SetLabel("Stack totals only while Shift is held", C.goldDim)
    stackChk:SetScript("OnClick", function()
        A.db.SetSetting("tipStackShift", stackChk:GetChecked() and true or false)
    end)
    ui.setTipStackShift = stackChk

    local profChk = ui.MakeCheckBox(panel, 18, "AegisExchangeSetProfLine")
    profChk:SetPoint("TOPLEFT", stackChk, "BOTTOMLEFT", -18, -8)
    profChk:SetLabel("Show profit line on profession windows", C.text)
    profChk:SetScript("OnClick", function()
        A.db.SetSetting("profLine", profChk:GetChecked() and true or false)
        ui.UpdateProfLine()
    end)
    ui.setProfLine = profChk

    -- pfUI skin toggle. Only meaningful with pfUI installed, and changing it
    -- takes effect on the next /reload (we can't un-skin frames in place).
    local pfChk = ui.MakeCheckBox(panel, 18, "AegisExchangeSetPfSkin")
    pfChk:SetPoint("TOPLEFT", profChk, "BOTTOMLEFT", 0, -6)
    pfChk:SetLabel("Match pfUI's look (needs /reload)", C.text)
    pfChk:SetScript("OnClick", function()
        A.db.SetSetting("pfSkin", pfChk:GetChecked() and true or false)
    end)
    ui.setPfSkin = pfChk

    -- Ask before cancelling an auction? Off makes the Auctions tab's Cancel
    -- buttons act immediately.
    local ccChk = ui.MakeCheckBox(panel, 18,
        "AegisExchangeSetConfirmCancel")
    ccChk:SetPoint("TOPLEFT", pfChk, "BOTTOMLEFT", 0, -6)
    ccChk:SetLabel("Ask before cancelling an auction", C.text)
    ccChk:SetScript("OnClick", function()
        A.db.SetSetting("confirmCancel", ccChk:GetChecked() and true or false)
    end)
    ui.setConfirmCancel = ccChk

    -- Ask before posting an auction? Off makes the Sell tab's Post button act
    -- immediately. Same shape as the cancel toggle above it.
    local cpChk = ui.MakeCheckBox(panel, 18, "AegisExchangeSetConfirmPost")
    cpChk:SetPoint("TOPLEFT", ccChk, "BOTTOMLEFT", 0, -6)
    cpChk:SetLabel("Ask before posting an auction", C.text)
    cpChk:SetScript("OnClick", function()
        A.db.SetSetting("confirmPost", cpChk:GetChecked() and true or false)
    end)
    ui.setConfirmPost = cpChk

    -- Keep leftovers in the slot after posting? Same shape again.
    local klChk = ui.MakeCheckBox(panel, 18, "AegisExchangeSetKeepLeftovers")
    klChk:SetPoint("TOPLEFT", cpChk, "BOTTOMLEFT", 0, -6)
    klChk:SetLabel("Keep leftovers ready to post", C.text)
    klChk:SetScript("OnClick", function()
        A.db.SetSetting("keepLeftovers", klChk:GetChecked() and true or false)
    end)
    ui.setKeepLeftovers = klChk

    -- ---- Scan pacing -------------------------------------------------------
    -- "Auto" leans on the client's own CanSendAuctionQuery() gate, so a client
    -- running the AuctionQueryThrottle DLL scans as fast as the server answers
    -- while a stock client still waits its ~5s. "Safe" keeps the fixed floor.
    -- Anchored to cpChk, the LAST checkbox above it. v1.20.0 added cpChk into
    -- the middle of the chain and left this pointing at ccChk, which drew the
    -- new checkbox and this whole row -- pacing, its buttons, the price-data
    -- line and Clear price data, all of which chain off thLbl -- on top of
    -- each other. Inserting a widget into an anchor chain means re-pointing
    -- the link BELOW it as well.
    local thLbl = label("Scan pacing:", klChk, -12)

    ui.setThrottleBtns = {}
    local modes = { { "Auto", "auto" }, { "Safe 4s", "safe" } }
    local prevTh = nil
    local ti = 1
    while ti <= table.getn(modes) do
        local m = modes[ti]
        local b = ui.MakeButton(panel, "quiet")
        b:SetWidth(64); b:SetHeight(20)
        if prevTh then b:SetPoint("LEFT", prevTh, "RIGHT", 4, 0)
        else b:SetPoint("LEFT", thLbl, "RIGHT", 10, 0) end
        b:SetText(m[1])
        b.mode = m[2]
        b:SetScript("OnClick", function()
            A.db.SetSetting("queryThrottle", b.mode)
            ui.RefreshSettings()
        end)
        ui.setThrottleBtns[ti] = b
        prevTh = b
        ti = ti + 1
    end

    ui.setThrottleInfo = panel:CreateFontString(nil, "OVERLAY",
        "GameFontHighlightSmall")
    ui.setThrottleInfo:SetPoint("LEFT", prevTh, "RIGHT", 10, 0)
    ui.setThrottleInfo:SetJustifyH("LEFT")

    -- ---- Price data -------------------------------------------------------
    ui.setDataText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.setDataText:SetPoint("TOPLEFT", thLbl, "BOTTOMLEFT", 0, -14)
    ui.setDataText:SetTextColor(C.text[1], C.text[2], C.text[3])

    local clearBtn = ui.MakeButton(panel, "quiet")
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
--
-- `quiet` skips the repaint. The g/s/c boxes commit on every keystroke, and
-- repainting them from the stored value mid-word would fight the typist; the
-- full refresh happens when the field is left instead.
function ui.CommitUndercutFlat(quiet)
    if not ui.setUndercutFlat then return end
    local c = util.ParseMoney(util.Trim(ui.setUndercutFlat:GetText() or ""))
    if not c or c < 1 then c = A.db.Setting("undercutAmount") end
    A.db.SetSetting("undercutAmount", math.floor(c))
    if not quiet then ui.RefreshSettings() end
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
    ui.MarkChosen(ui.setDurBtns, function(b) return b.minutes == dur end)
    local mode = A.db.Setting("sellDefault")
    ui.MarkChosen(ui.setSellModeBtns, function(b) return b.mode == mode end)
    local ucMode = A.db.Setting("undercutMode")
    ui.MarkChosen(ui.setUcModeBtns, function(b) return b.mode == ucMode end)
    if ui.setUndercut then
        ui.setUndercut:SetText(tostring(A.db.Setting("undercutPct")))
    end
    if ui.setUndercutFlat then
        ui.setUndercutFlat:SetText(util.FormatMoney(A.db.Setting("undercutAmount"), false))
    end
    if ui.setScaleText then
        ui.setScaleText:SetText(math.floor(ui.WindowScale() * 100 + 0.5) .. "%")
    end
    local tipOn = A.db.Setting("tooltip") ~= false
    if ui.setTooltip then
        ui.setTooltip:SetChecked(tipOn and 1 or nil)
    end
    -- The per-line options are meaningless with the master switch off, so grey
    -- them out rather than leaving them looking live.
    if ui.setTipSubs then
        local si = 1
        while si <= table.getn(ui.setTipSubs) do
            local c = ui.setTipSubs[si]
            c:SetChecked(A.db.Setting(c.settingKey) ~= false and 1 or nil)
            -- SetDimmed, not Enable/Disable: the stock template greyed its own
            -- label when disabled, ours has to be told to.
            c:SetDimmed(not tipOn)
            si = si + 1
        end
    end
    if ui.setTipStackShift then
        ui.setTipStackShift:SetChecked(
            A.db.Setting("tipStackShift") == true and 1 or nil)
        ui.setTipStackShift:SetDimmed(not tipOn)
    end
    if ui.setProfLine then
        ui.setProfLine:SetChecked(A.db.Setting("profLine") ~= false and 1 or nil)
    end
    if ui.setConfirmPost then
        ui.setConfirmPost:SetChecked(
            A.db.Setting("confirmPost") ~= false and 1 or nil)
    end
    if ui.setConfirmCancel then
        ui.setConfirmCancel:SetChecked(
            A.db.Setting("confirmCancel") ~= false and 1 or nil)
    end
    if ui.setKeepLeftovers then
        ui.setKeepLeftovers:SetChecked(
            A.db.Setting("keepLeftovers") ~= false and 1 or nil)
    end
    if ui.setPfSkin then
        ui.setPfSkin:SetChecked(A.db.Setting("pfSkin") ~= false and 1 or nil)
        -- Without pfUI the toggle does nothing; grey it out rather than lie.
        if A.skin and A.skin.Available() then
            ui.setPfSkin:Enable()
        else
            ui.setPfSkin:Disable()
        end
    end
    if ui.setDataText then
        -- Name the realm: prices are per-realm from v1.1.6 on, and the count
        -- (and the Clear button beside it) covers THIS realm only. Saying so
        -- beats leaving people to wonder why the number changed after a
        -- server switch.
        local realm = A.db.RealmKey and A.db.RealmKey() or nil
        local txt = "Price data: " .. A.db.ItemCount() .. " item(s) recorded"
        if realm and realm ~= "?" then txt = txt .. " on " .. realm end
        ui.setDataText:SetText(txt)
    end

    -- Scan pacing: highlight the active mode and report what the client's
    -- query gate is actually doing, so it's obvious whether a throttle-removing
    -- DLL (AuctionQueryThrottle) is having any effect.
    local thMode = A.db.Setting("queryThrottle") or "auto"
    ui.MarkChosen(ui.setThrottleBtns, function(b) return b.mode == thMode end)
    if ui.setThrottleInfo then
        local p = A.scan.GetProgress()
        if thMode == "safe" then
            ui.setThrottleInfo:SetText("fixed 4s between pages")
            ui.setThrottleInfo:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
        elseif p.fastGate then
            -- Show BOTH halves of the per-page cost. If the gate is ~0 and the
            -- reply is slow, the server is the limit, not us -- which is why
            -- the same scan can differ between realms.
            ui.setThrottleInfo:SetText(string.format(
                "fast \226\128\148 gate %.2fs, server %.2fs",
                p.lastGate or 0, p.lastReply or 0))
            ui.setThrottleInfo:SetTextColor(0.30, 0.85, 0.30)
        elseif p.lastGate then
            ui.setThrottleInfo:SetText(string.format(
                "client throttled \226\128\148 gate %.1fs, server %.2fs",
                p.lastGate, p.lastReply or 0))
            ui.setThrottleInfo:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
        else
            ui.setThrottleInfo:SetText("follows the client's own query gate")
            ui.setThrottleInfo:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
        end
    end

    -- Content can change height (the pacing readout wraps differently), so
    -- re-measure whenever we repaint. SelectSubTab already routes the Scan tab
    -- through here, which is the moment the panel becomes measurable.
    ui.UpdateAegisScroll()
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

-- Quality report order (best first) and their standard item colours.
local SCAN_QUALITY_ORDER = { 6, 5, 4, 3, 2, 1, 0 }
local SCAN_QUALITY_COLOR = {
    [0] = "9d9d9d", [1] = "ffffff", [2] = "1eff00", [3] = "0070dd",
    [4] = "a335ee", [5] = "ff8000", [6] = "e6cc80",
}

-- Full breakdown once a scan finishes: totals, a per-quality tally, and what
-- it did to the price DB. Printed as separate lines so it reads like a report
-- rather than one dense sentence.
function ui.OnScanComplete(stats)
    ui.Refresh()
    local function line(text)
        DEFAULT_CHAT_FRAME:AddMessage("|cff5fc8f8Aegis:|r " .. text,
            0.35, 0.78, 0.98)
    end

    local head = stats.auctions .. " auctions scanned"
    if stats.items then head = head .. "  (" .. stats.items .. " items)" end
    line(head)

    -- Per quality, best first, each in its own item colour. Skip empties.
    if stats.byQuality then
        local qi = 1
        while qi <= table.getn(SCAN_QUALITY_ORDER) do
            local q = SCAN_QUALITY_ORDER[qi]
            local n = stats.byQuality[q]
            if n and n > 0 then
                local name = A.scan.QUALITY_NAMES[q] or ("Quality " .. q)
                line("  |cff" .. (SCAN_QUALITY_COLOR[q] or "ffffff")
                    .. name .. " items:|r " .. n)
            end
            qi = qi + 1
        end
    end

    if stats.added then
        line("  Items added to database: " .. stats.added)
        line("  Items updated in database: " .. (stats.updated or 0))
        line("  Items ignored: " .. (stats.ignored or 0))
    end
    line("  Scanned " .. stats.pages .. " page(s) in "
        .. util.FormatDuration(stats.duration))
end

-- Live scan progress as one line ("Page 3 / 6 - ~12s - 16.6/s"), or nil when
-- the first page hasn't landed yet. Shared by the Aegis strip and the Sell
-- tab's per-item scan header so both report the same thing.
function ui.ScanProgressText()
    local p = A.scan.GetProgress()
    if p.totalPages <= 0 then return nil end
    local text = string.format(
        "Page %d / %d \226\128\162 ~%s \226\128\162 %s/s",
        p.page, p.totalPages, util.FormatDuration(p.eta),
        string.format("%.1f", p.rate))
    if p.catCount > 1 then
        text = string.format("Cat %d / %d \226\128\162 ", p.catIndex, p.catCount)
            .. text
    end
    if p.retries > 0 then
        text = text .. string.format(" (retry %d)", p.retries)
    end
    return text
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
        local pageText = ui.ScanProgressText()
        if pageText then
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
-- Tab traversal between input boxes
-- ---------------------------------------------------------------------------

-- The next box after `from` in `list`, wrapping past the end -- or the one
-- before it when `back` is true.
--
-- HIDDEN BOXES ARE SKIPPED. The Sell tab's money triplets, the settings
-- panel's flat-amount boxes and the Buy tab's bid entry all come and go with
-- the mode they belong to, and tabbing into one that is not on screen puts
-- the cursor somewhere the eye cannot follow it -- keystrokes land in a box
-- nobody can see.
--
-- Returns nil when there is nowhere to go, which the caller reads as "stay
-- put". Never clear focus on a dead end: losing the cursor is a worse answer
-- than not moving it.
function ui.NextInputIn(list, from, back)
    local n = table.getn(list or {})
    if n == 0 then return nil end

    local at
    local i = 1
    while i <= n do
        if list[i] == from then at = i end
        i = i + 1
    end
    if not at then return nil end

    local step = back and -1 or 1
    local k = 1
    while k <= n - 1 do
        -- + n keeps the operand positive: math.mod is fmod on 5.0 and returns
        -- a NEGATIVE remainder for a negative left side, so Shift-Tab off the
        -- front of the list would index nothing.
        local idx = math.mod(at - 1 + step * k + n, n) + 1
        local box = list[idx]
        if box and box:IsVisible() then return box end
        k = k + 1
    end
    return nil
end

-- Bind Tab / Shift-Tab across an ORDERED list of edit boxes.
--
-- The order is written out by hand at each call site on purpose. Deriving it
-- from frame positions would hand the cursor to whichever box the layout
-- happens to place next -- including one in a column the eye reads second --
-- and every layout change would silently re-order the form.
--
-- NOT BOUND on ui.buyBox or ui.buyQueryBox. Tab autocompletes item names
-- there, which is older, more valuable and already in people's fingers; the
-- two search boxes keep it and are the documented exception rather than
-- something to be discovered.
function ui.LinkTabOrder(list)
    local n = table.getn(list or {})
    local i = 1
    while i <= n do
        local box = list[i]
        if box then
            box:SetScript("OnTabPressed", function()
                local back = IsShiftKeyDown and IsShiftKeyDown()
                local nxt = ui.NextInputIn(list, box, back)
                if nxt then
                    nxt:SetFocus()
                    -- Select what is there, so the next keystroke replaces a
                    -- default rather than appending a digit to it -- these
                    -- are stack counts and prices, and both arrive pre-filled.
                    if nxt.HighlightText then nxt:HighlightText() end
                end
            end)
        end
        i = i + 1
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

-- A read-only money READOUT: "6 (gold) 75 (silver) 43 (copper)", the way the
-- stock money frame prints it, rather than the "6g 75s 43c" text shorthand.
--
-- Laid out right-to-left from an anchor so the copper coin lands on a fixed
-- point and the gold figure grows leftwards -- a total that gains a digit
-- must not shove the rest of the bar sideways.
local MONEY_COIN_U = { gold = 0, silver = 0.25, copper = 0.5 }
MakeMoneyGSC = function(parent, onChange)
    local grp = {}
    -- Blizzard's own coin art, the same the stock money frame uses -- so a
    -- price here reads exactly like a price anywhere else in the game.
    --
    -- 1.12 has no per-denomination icon files. There is ONE sprite sheet,
    -- UI-MoneyIcons, holding gold/silver/copper side by side, and the stock UI
    -- picks one with SetTexCoord. Pointing at "UI-GoldIcon" (which is how later
    -- clients do it) resolves to nothing at all, which is why the coins were
    -- invisible rather than wrong.
    local COIN_U = { gold = 0, silver = 0.25, copper = 0.5 }
    local function mk(w, coin)
        local e = ui.FlattenEditBox(
            CreateFrame("EditBox", nil, parent, "InputBoxTemplate"))
        e:SetWidth(w)
        e:SetHeight(18)
        e:SetAutoFocus(false)
        e:SetNumeric(true)
        e:SetJustifyH("RIGHT")
        e:SetScript("OnEnterPressed", function() e:ClearFocus() end)
        e:SetScript("OnEscapePressed", function() e:ClearFocus() end)
        e:SetScript("OnTextChanged", function()
            if grp.quiet then return end     -- our own SetText, not the user
            if onChange then onChange() end
        end)
        -- `tag` stays the name the layout anchors off, texture or not.
        local tag = parent:CreateTexture(nil, "OVERLAY")
        tag:SetTexture("Interface\\MoneyFrame\\UI-MoneyIcons")
        local u = COIN_U[coin] or 0
        tag:SetTexCoord(u, u + 0.25, 0, 1)
        tag:SetWidth(13)
        tag:SetHeight(13)
        tag:SetPoint("LEFT", e, "RIGHT", 2, 0)
        e.tag = tag
        e.coin = coin
        return e
    end
    grp.g = mk(34, "gold")
    grp.s = mk(22, "silver")
    grp.c = mk(22, "copper")

    grp.GetText = function(self)
        local gg = tonumber(self.g:GetText()) or 0
        local ss = tonumber(self.s:GetText()) or 0
        local cc = tonumber(self.c:GetText()) or 0
        local total = gg * 10000 + ss * 100 + cc
        if total <= 0 then return "" end
        return util.FormatMoney(total, false)
    end
    grp.SetText = function(self, txt)
        local copper = nil
        if txt and txt ~= "" then copper = util.ParseMoney(txt) end
        self.quiet = true
        if not copper or copper <= 0 then
            self.g:SetText(""); self.s:SetText(""); self.c:SetText("")
        else
            -- Blank LEADING zeros only. Gold already did this and silver did
            -- not, so 11c drew as [ ][0][11] -- an empty box beside a zero
            -- reads as a missing value rather than "no silver".
            local gg, ss, cc = util.MoneyParts(copper)
            self.g:SetText(gg > 0 and tostring(gg) or "")
            self.s:SetText((gg > 0 or ss > 0) and tostring(ss) or "")
            self.c:SetText(tostring(cc))
        end
        self.quiet = false
    end
    grp.ClearFocus = function(self)
        self.g:ClearFocus(); self.s:ClearFocus(); self.c:ClearFocus()
    end
    -- Raise/lower the whole group. The coin textures are parented to the
    -- PANEL (they anchor off the boxes but are not children of them), so
    -- hiding the boxes alone would leave three coins floating on the bar.
    grp.Show = function(self)
        self.g:Show(); self.s:Show(); self.c:Show()
        self.g.tag:Show(); self.s.tag:Show(); self.c.tag:Show()
    end
    grp.Hide = function(self)
        self.g:Hide(); self.s:Hide(); self.c:Hide()
        self.g.tag:Hide(); self.s.tag:Hide(); self.c.tag:Hide()
    end

    -- Anchor the whole triplet off one widget.
    grp.Attach = function(self, anchor, dx, dy)
        self.g:SetPoint("LEFT", anchor, "RIGHT", dx or 6, dy or 0)
        self.s:SetPoint("LEFT", self.g.tag, "RIGHT", 5, 0)
        self.c:SetPoint("LEFT", self.s.tag, "RIGHT", 5, 0)
    end
    return grp
end

-- A read-only coin readout, LEFT-aligned: the figure grows rightward from
-- its anchor, so its left edge stays on the panel margin with the Name field,
-- BROWSE and the category plates.
--
-- It used to be anchored by its COPPER coin and grow leftwards, so that a
-- total gaining a digit could not shove the layout about. That mattered when
-- it sat mid-bar; on the left margin there is nothing to its right until the
-- Bid row, so growth is free and alignment is what you actually see.
--
-- The catch with left-aligning: Blizzard hides denominations ABOVE the value
-- (43 copper shows one coin, not three), and hiding the LEADING elements of a
-- left-anchored chain leaves a gap where they would have been. So the anchor
-- is stored and re-applied to the first VISIBLE denomination each time the
-- value changes.
local function MakeMoneyDisplay(parent)
    local m = {}
    local function part(coin, after)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetJustifyH("LEFT")
        fs:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
        if after then
            -- The gap belongs BETWEEN denominations, not between a number and
            -- the coin it labels -- that is what makes it read as three
            -- amounts rather than six separate things.
            fs:SetPoint("LEFT", after, "RIGHT", 7, 0)
        end
        local tex = parent:CreateTexture(nil, "OVERLAY")
        tex:SetTexture("Interface\\MoneyFrame\\UI-MoneyIcons")
        local u = MONEY_COIN_U[coin]
        tex:SetTexCoord(u, u + 0.25, 0, 1)
        tex:SetWidth(15); tex:SetHeight(15)
        tex:SetPoint("LEFT", fs, "RIGHT", 1, 0)
        return { tex = tex, fs = fs }
    end
    m.gold   = part("gold",   nil)
    m.silver = part("silver", m.gold.tex)
    m.copper = part("copper", m.silver.tex)

    -- Anchor STORES the point; SetMoney is what places things, because which
    -- denomination sits on the margin depends on the value. Placing anything
    -- here as well would be dead work -- SetMoney clears and re-anchors the
    -- whole chain on the next call regardless.
    -- Put the chain's head on the stored anchor. Called whenever which
    -- denominations are visible changes.
    m.Rehead = function(self, first)
        if not self.anchor then return end
        first.fs:ClearAllPoints()
        first.fs:SetPoint(unpack(self.anchor))
    end
    m.Anchor = function(self, ...)
        self.anchor = arg
        self:Rehead(self.gold)
    end
    m.SetMoney = function(self, copper)
        local g, sv, c = util.MoneyParts(copper or 0)
        self.gold.fs:SetText(tostring(g))
        self.silver.fs:SetText(tostring(sv))
        self.copper.fs:SetText(tostring(c))
        local showG = g > 0
        local showS = showG or sv > 0
        if showG then self.gold.tex:Show(); self.gold.fs:Show()
        else self.gold.tex:Hide(); self.gold.fs:Hide() end
        if showS then self.silver.tex:Show(); self.silver.fs:Show()
        else self.silver.tex:Hide(); self.silver.fs:Hide() end
        -- Re-anchor whichever denomination is now leftmost, or the hidden
        -- ones leave a hole on the margin.
        if showG then
            self:Rehead(self.gold)
        elseif showS then
            self.silver.fs:ClearAllPoints()
            self:Rehead(self.silver)
        else
            self.copper.fs:ClearAllPoints()
            self:Rehead(self.copper)
        end
        -- ...and restore the chain for the ones still shown.
        if showG then
            self.silver.fs:ClearAllPoints()
            self.silver.fs:SetPoint("LEFT", self.gold.tex, "RIGHT", 7, 0)
        end
        if showS then
            self.copper.fs:ClearAllPoints()
            self.copper.fs:SetPoint("LEFT", self.silver.tex, "RIGHT", 7, 0)
        end
    end
    m.Show = function(self)
        self.copper.tex:Show(); self.copper.fs:Show()
        -- gold/silver visibility is SetMoney's call, not ours.
    end
    return m
end

local openDropdown
-- `noAll` suppresses the implicit "All" row. Class / Subclass / Slot /
-- Quality all want it -- "no filter" is a real choice there. Component does
-- not: there is no such thing as "all components", and the row only offered
-- a way to pick nothing.
local function MakeDropdown(parent, width, onSelect, noAll)
    local dd = {}
    dd.options = {}
    dd.value = nil
    dd.noAll = noAll and true or false

    local btn = ui.MakeButton(parent, "quiet")
    btn:SetWidth(width)
    btn:SetHeight(20)
    btn:SetText("All")
    -- The affordance that says "this opens". Without it a dropdown is
    -- indistinguishable from a button that does something when clicked.
    local caret = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    caret:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
    caret:SetText("\226\150\188")
    caret:SetTextColor(0.80, 0.71, 0.42)
    btn.caret = caret
    dd.button = btn

    local list = CreateFrame("Frame", nil, ui.frame)
    -- The popup must cover EVERYTHING in the window, so it gets its own
    -- strata rather than a frame-level bid inside the panel's -- the same
    -- move Blizzard's own DropDownList makes. Level alone lost to the form's
    -- edit boxes.
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:SetFrameLevel(parent:GetFrameLevel() + 20)
    -- DOUBLED backslashes, and this file has three tests pinning them: in Lua
    -- source "\T" is not an escape, so a single backslash silently vanishes
    -- and the client gets "InterfaceTooltips..." -- a texture that does not
    -- exist. SetBackdrop draws nothing for a bad path, which shipped as a
    -- see-through popup with the form bleeding through the option text.
    list:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    -- Fully opaque. The default tooltip backdrop color is translucent by
    -- design (tooltips hover over the world); a menu you read options from
    -- is not a tooltip.
    list:SetBackdropColor(C.well[1], C.well[2], C.well[3], 1)
    list:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3])
    list:EnableMouse(true)     -- swallow clicks; don't fall through to the form
    list:Hide()
    dd.list = list
    dd.rows = {}

    local ROW_H = 15

    function dd:Close()
        list:Hide()
        if openDropdown == dd then openDropdown = nil end
    end

    -- Label for the currently selected value, or "All" when nothing is set.
    --
    -- An option may carry `colour = {r,g,b}`; the closed button then shows the
    -- selection in it. "All" carries none and stays the button's own colour,
    -- which is the point -- "no quality filter" is not a quality and must not
    -- borrow one's colour.
    function dd:Repaint()
        local text = dd.noAll and "" or "All"
        local colour = nil
        local i = 1
        while i <= table.getn(dd.options) do
            if dd.options[i].value == dd.value then
                text = dd.options[i].text
                colour = dd.options[i].colour
                break
            end
            i = i + 1
        end
        btn.aegisTextColor = colour
        RepaintButton(btn)
        ui.SetTextClipped(btn:GetFontString(), text, width - 8)
    end

    function dd:SetOptions(opts)
        dd.options = opts or {}
        -- A value that is no longer offered cannot stay selected -- this is
        -- what clears Subclass when the Class above it changes.
        local stillValid = (dd.value == nil)
        local i = 1
        while i <= table.getn(dd.options) do
            if dd.options[i].value == dd.value then stillValid = true end
            i = i + 1
        end
        if not stillValid then dd.value = nil end
        dd:Repaint()
    end

    function dd:SetValue(v, silent)
        dd.value = v
        dd:Repaint()
        if not silent and onSelect then onSelect(v) end
    end

    function dd:GetValue() return dd.value end

    -- Resize after creation. `width` is not just the button's width -- it is
    -- also what Repaint clips the label to and what Open sizes the popup to --
    -- so setting the button alone would leave a narrow list under a wide
    -- button and a label still clipped to the old width.
    function dd:SetWidth(w)
        if not w or w < 40 then return end
        width = w
        btn:SetWidth(w)
        dd:Repaint()
    end

    function dd:SetEnabled(on)
        if on then btn:Enable() else btn:Disable(); dd:Close() end
    end

    function dd:Open()
        if openDropdown and openDropdown ~= dd then openDropdown:Close() end
        -- "All" plus one row per option; All clears the filter -- unless
        -- this dropdown opted out of it.
        local entries = {}
        if not dd.noAll then
            table.insert(entries, { text = "All", value = nil })
        end
        local i = 1
        while i <= table.getn(dd.options) do
            table.insert(entries, dd.options[i])
            i = i + 1
        end
        local n = table.getn(entries)
        list:SetWidth(width)
        list:SetHeight(n * ROW_H + 8)
        list:ClearAllPoints()
        list:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)

        local r = 1
        while r <= n do
            local row = dd.rows[r]
            if not row then
                row = CreateFrame("Button", nil, list)
                row:SetHeight(ROW_H)
                row:SetPoint("TOPLEFT", list, "TOPLEFT", 4, -(4 + (r - 1) * ROW_H))
                row:SetPoint("TOPRIGHT", list, "TOPRIGHT", -4, -(4 + (r - 1) * ROW_H))
                row:SetHighlightTexture(
                    "Interface\\QuestFrame\\UI-QuestTitleHighlight")
                row.aegisNoSkin = true
                local fs = row:CreateFontString(nil, "OVERLAY",
                    "GameFontHighlightSmall")
                fs:SetPoint("LEFT", row, "LEFT", 3, 0)
                fs:SetJustifyH("LEFT")
                row.label = fs
                row:SetScript("OnClick", function()
                    dd:SetValue(row.optValue)
                    dd:Close()
                end)
                -- An option may carry `tip`, which is how a dimmed entry
                -- explains why it is dimmed rather than leaving the user to
                -- guess from the colour alone.
                row:SetScript("OnEnter", function()
                    if not row.optTip then return end
                    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
                    GameTooltip:SetText(row.optTip, 1, 1, 1, 1, 1)
                    GameTooltip:Show()
                end)
                row:SetScript("OnLeave", function() GameTooltip:Hide() end)
                dd.rows[r] = row
            end
            row.optTip = entries[r].tip
            row.optValue = entries[r].value
            -- Rows are pooled, so the colour is set on EVERY pass -- including
            -- back to the default. Setting it only when an option has one
            -- leaves the previous option's colour on a reused row.
            local oc = entries[r].colour
            if oc then
                row.label:SetTextColor(oc[1], oc[2], oc[3])
            else
                row.label:SetTextColor(C.text[1], C.text[2], C.text[3])
            end
            ui.SetTextClipped(row.label, entries[r].text, width - 12)
            row:Show()
            r = r + 1
        end
        while r <= table.getn(dd.rows) do dd.rows[r]:Hide(); r = r + 1 end

        list:Show()
        openDropdown = dd
    end

    btn:SetScript("OnClick", function()
        if list:IsVisible() then dd:Close() else dd:Open() end
    end)

    dd:Repaint()
    return dd
end

-- Horizontal slider, hand-built from the base Slider widget for the same reason
-- as the Aegis tab's scroll bar: Slider is a primitive that always exists, so
-- there's no "Couldn't find inherited node" risk from guessing a 1.12 template.
MakeHSlider = function(parent, width, onChange)
    local sb = CreateFrame("Slider", nil, parent)
    sb.aegisNoSkin = true
    sb:SetWidth(width)
    sb:SetHeight(15)
    sb:SetOrientation("HORIZONTAL")
    sb:SetMinMaxValues(1, 1)
    sb:SetValue(1)
    sb:SetValueStep(1)
    sb:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
    local thumb = sb:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    thumb:SetWidth(20)
    thumb:SetHeight(20)
    sb:SetThumbTexture(thumb)
    sb:SetScript("OnValueChanged", function()
        if ui.sellSliderSync then return end   -- we moved it, not the user
        if onChange then onChange(this:GetValue()) end
    end)
    return sb
end

-- Point a slider at a range and value without its OnValueChanged firing back
-- into the code that is currently painting the UI.
SetSliderRange = function(sb, minV, maxV, value)
    if not sb then return end
    if maxV < minV then maxV = minV end
    ui.sellSliderSync = true
    sb:SetMinMaxValues(minV, maxV)
    if value < minV then value = minV end
    if value > maxV then value = maxV end
    sb:SetValue(value)
    ui.sellSliderSync = false
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
local function MakeNumBox(parent, width, onChanged, height)
    local e = ui.FlattenEditBox(
        CreateFrame("EditBox", nil, parent, "InputBoxTemplate"))
    e:SetWidth(width)
    -- Callers that share a strip with a dropdown pass its height, so every
    -- control on the row lines up top AND bottom rather than only at its
    -- anchor point.
    e:SetHeight(height or 18)
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
        -- NEUTRAL at exactly market, not yellow. Yellow reads as a warning,
        -- and paying exactly market price is the unremarkable case -- the
        -- mockup renders it in plain white for that reason. Green and red
        -- mean something precisely because the middle does not.
        return 0.88, 0.86, 0.80
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

-- Result-row column layout, row-relative. TWO of them, because the two tabs
-- that use BuildResultRow want different tables.
--
-- The Buy tab follows the mockup: a checkbox, the icon and name, then Lvl,
-- Time Left, Seller, Current Bid, Buyout, Unit and % Mkt. The stack count is
-- NOT a column -- it is appended to the name as "x3", which is what the
-- mockup does and what frees the width for the four new columns.
--
-- The Crafting tab keeps the older five-column shape with its own per-row Buy
-- and Bid buttons. It is a different question ("what can I make and what does
-- it cost"), it has no room for a seller or a time left, and changing it was
-- not asked for.
-- NO SELLER COLUMN. The mockup has one; we deliberately do not -- see
-- ROADMAP 2q. `owner` is still read by the scanner, because it is what marks
-- your own auctions; only the column is gone.
--
-- The 92px that freed goes first to the gap between Lvl and Time Left, which
-- were close enough to touch ("43 Very Long" ran together), and then to the
-- three money columns.
local RCX_BUY = {
    check = 2, icon = 22, name = 44, lvl = 288, left = 336,
    bid = 420, stack = 512, unit = 604, pct = 678,
}
local RCW_BUY = {
    name = 236, lvl = 30, left = 78,
    bid = 84, stack = 84, unit = 66, pct = 44,
}
-- Where the rightmost column ends. Asked for rather than re-added by hand, so
-- a column edit cannot silently push the table under the scrollbar.
local BUY_COLS_END = 678 + 44

-- Extra width the ITEM column has been given, over its RCW_BUY.name default.
--
-- Advanced hides the category tree, so the results table there starts at the
-- panel margin and is ~200px wider than the same table in the Blizzlike view.
-- That surplus goes to Item -- it is the column that actually runs out of
-- room, and the numeric columns are sized to their contents. Every column
-- AFTER name shifts right by this, which is why it is one number rather than
-- a second copy of RCX_BUY: two column tables would drift.
local BUY_NAME_EXTRA = 0

-- x of column `key` at the current width.
local function ColX(key)
    local x = RCX_BUY[key]
    if key == "check" or key == "icon" or key == "name" then return x end
    return x + BUY_NAME_EXTRA
end

-- Re-place one result row's cells at the current width. Called for every row
-- when the table's width changes, and for a row built after that point.
function ui.LayoutBuyRow(row)
    if not row or not row.pct then return end     -- Crafting row: five columns
    row.name:SetWidth(RCW_BUY.name + BUY_NAME_EXTRA)
    local keys = { "lvl", "left", "bid", "stack", "unit", "pct" }
    local i = 1
    while i <= table.getn(keys) do
        local cell = row[keys[i]]
        if cell then
            cell:ClearAllPoints()
            cell:SetPoint("LEFT", row, "LEFT", ColX(keys[i]), 0)
        end
        i = i + 1
    end
end
local RCX = { name = 2, ct = 178, unit = 210, stack = 296, pct = 390,
              buy = 436, bid = 490 }
local RCW = { name = 172, ct = 26, unit = 82, stack = 90, pct = 40 }

-- Build a listing result row (name/ct/unit/stack/pct + Buy/Bid) into `store`.
-- Buttons act on row.entry, so the same rows serve Buy and Crafting.
-- `selectable` (Buy tab only) builds a Blizzlike row: no per-row Buy/Bid
-- buttons, click to select, and the window's bottom bar acts on the selection.
-- The Crafting tab passes nothing and keeps its own per-row buttons.
-- The chrome every results row wears: a zebra stripe, a hairline separator,
-- and -- where rows can be picked -- a selection tint.
--
-- ONE function, five tables. The Buy table had the only copy of this, which
-- is exactly why every other table read as a different addon; four tabs each
-- growing their own copy instead is the shape that produced the
-- Saved-vs-Builder drift in 1.19.3.
--
-- CREATION ORDER IS THE WHOLE THING. All three are BACKGROUND textures, and
-- within one layer the draw order IS the creation order:
--   zebra     first -- bottom-most, so a selected odd row reads as selected
--                      rather than as striped-and-selected;
--   separator next  -- above the stripe, so it survives on a banded row;
--   selection last  -- so it covers the separator on the picked row instead
--                      of letting it show through as a scar.
-- Any other order is a silent visual bug: nothing errors, every row still
-- draws, and the fault is only visible to a person looking at the tab. The
-- cells are FontStrings on OVERLAY, so they sit above all three whenever they
-- are created.
--
-- The stripe is keyed to the row's POSITION IN THE POOL, never to the entry
-- it happens to be showing. Set once here and never touched by any paint,
-- which is what makes scrolling slide the data past fixed banding instead of
-- making the stripes crawl with it.
function ui.AddRowChrome(row, i, selectable)
    if not row then return row end

    local zebra = row:CreateTexture(nil, "BACKGROUND")
    zebra:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    zebra:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    if math.mod(i, 2) == 0 then
        zebra:SetTexture(1, 1, 1, 0.022)
    else
        -- Fully transparent rather than absent, so every row owns a stripe
        -- texture and the banding cannot depend on which rows exist.
        zebra:SetTexture(0, 0, 0, 0)
    end
    row.zebra = zebra

    local sep = row:CreateTexture(nil, "BACKGROUND")
    sep:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    sep:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    sep:SetHeight(1)
    sep:SetTexture(0.28, 0.24, 0.15, 0.55)
    row.sep = sep

    if selectable then
        -- Under the text (BACKGROUND) so it TINTS the row rather than
        -- covering the numbers.
        local sel = row:CreateTexture(nil, "BACKGROUND")
        sel:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        sel:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
        sel:SetTexture(0.6, 0.45, 0.10, 0.34)
        sel:Hide()
        row.selTex = sel
    end
    return row
end

local function BuildResultRow(parent, scroll, store, i, rowH, selectable)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(rowH)
    if i == 1 then
        row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
        row:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, 0)
    else
        row:SetPoint("TOPLEFT", store[i - 1], "BOTTOMLEFT", 0, 0)
        row:SetPoint("TOPRIGHT", store[i - 1], "BOTTOMRIGHT", 0, 0)
    end
    -- Before any cell, so the stripe, the hairline and the selection tint are
    -- created in that order and nothing else is between them.
    ui.AddRowChrome(row, i, selectable)
    local mkCell = function(x, w, just)
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", row, "LEFT", x, 0)
        fs:SetWidth(w)
        fs:SetJustifyH(just or "LEFT")
        return fs
    end
    if selectable then
        -- ---- Buy tab: the mockup's eight columns ------------------------
        local X, W = RCX_BUY, RCW_BUY

        -- Tick box for the multi-buyout batch. Its own small CheckButton
        -- rather than the 32px UICheckButtonTemplate, which does not fit a
        -- listing row.
        local cb = ui.MakeCheckBox(row, 14)
        cb:SetPoint("LEFT", row, "LEFT", X.check, 0)
        cb:SetScript("OnClick", function()
            if row.entry then ui.ToggleBuyCheck(row.entry) end
        end)
        row.check = cb

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(16); icon:SetHeight(16)
        icon:SetPoint("LEFT", row, "LEFT", X.icon, 0)
        row.icon   = icon
        row.name   = mkCell(ColX("name"), W.name + BUY_NAME_EXTRA)
        row.lvl    = mkCell(ColX("lvl"),    W.lvl,    "RIGHT")
        row.left   = mkCell(ColX("left"),   W.left)
        row.bid    = mkCell(ColX("bid"),    W.bid,    "RIGHT")
        row.stack  = mkCell(ColX("stack"),  W.stack,  "RIGHT")
        row.unit   = mkCell(ColX("unit"),   W.unit,   "RIGHT")
        row.pct    = mkCell(ColX("pct"),    W.pct,    "RIGHT")
        -- Rows are built on demand as the window grows, so a row created
        -- AFTER a mode switch has to be laid out at the current width too.
        ui.LayoutBuyRow(row)
    else
        -- ---- Crafting tab: the older five-column shape ------------------
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(16); icon:SetHeight(16)
        icon:SetPoint("LEFT", row, "LEFT", RCX.name, 0)
        row.icon = icon
        row.name  = mkCell(RCX.name + 20, RCW.name - 20)
        row.ct    = mkCell(RCX.ct, RCW.ct, "RIGHT")
        row.unit  = mkCell(RCX.unit, RCW.unit)
        row.stack = mkCell(RCX.stack, RCW.stack)
        row.pct   = mkCell(RCX.pct, RCW.pct)
    end
    if not selectable then
        -- Buy is the primary plate and Bid the quiet one, exactly as the
        -- concept has them: on a row of listings the buyout is the action,
        -- and a bid is the hedge.
        local buyBtn = ui.MakeButton(row, "primary")
        buyBtn:SetWidth(50); buyBtn:SetHeight(17)
        buyBtn:SetPoint("LEFT", row, "LEFT", RCX.buy, 0)
        buyBtn:SetText("Buy")
        buyBtn:SetScript("OnClick", function()
            if row.entry then ui.ConfirmBuyout(row.entry) end
        end)
        row.buyBtn = buyBtn
        local bidBtn = ui.MakeButton(row, "quiet")
        bidBtn:SetWidth(44); bidBtn:SetHeight(17)
        bidBtn:SetPoint("LEFT", row, "LEFT", RCX.bid, 0)
        bidBtn:SetText("Bid")
        bidBtn:SetScript("OnClick", function()
            if row.entry then ui.ConfirmBid(row.entry) end
        end)
        row.bidBtn = bidBtn
    end
    -- Hover tooltip. A Frame gets no OnEnter until its mouse is enabled; the
    -- Buy/Bid buttons are children so they still take their own clicks.
    row:EnableMouse(true)
    row:SetScript("OnEnter", function()
        ui.ShowListingTooltip(row, row.entry)
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    if selectable then
        -- A Frame has no OnClick; OnMouseDown is the 1.12 equivalent once the
        -- mouse is enabled (which it is, for the tooltip above).
        row:SetScript("OnMouseDown", function()
            if row.entry then ui.SelectBuyRow(row.entry) end
        end)
    end
    row:Hide()
    store[i] = row
    return row
end

-- Tooltip for a browse ("list") listing row.
--
-- SetAuctionItem indexes into the CURRENTLY loaded page, and our rows are sorted
-- for display while the page can also be re-queried under us -- so verify the
-- index still holds the auction we drew before trusting it, exactly as the
-- Buy/Bid paths do. Falling back to the item link keeps the tooltip useful (item
-- stats, just not the auction's bid state) when the page has moved on.
function ui.ShowListingTooltip(owner, r)
    if not r then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local shown = false
    if r.index and GameTooltip.SetAuctionItem and A.buy.Verify(r) then
        shown = pcall(function() GameTooltip:SetAuctionItem("list", r.index) end)
    end
    if not shown then
        local link = r.index and GetAuctionItemLink
            and GetAuctionItemLink("list", r.index) or nil
        if link and GameTooltip.SetHyperlink then
            shown = pcall(function() GameTooltip:SetHyperlink(link) end)
        end
    end
    if not shown then
        -- Nothing authoritative left to read; at least name the item.
        GameTooltip:SetText(r.name or "")
    end
    GameTooltip:Show()
end

-- Fill a result row's content from a listing `r` (shared by Buy and Crafting).
function ui.FillResultRow(row, r)
    row.entry = r
    -- Selection tint (Buy tab rows only; the Crafting tab builds no selTex).
    if row.selTex then
        if ui.IsBuySelected(r) then row.selTex:Show() else row.selTex:Hide() end
    end
    if row.icon then
        if r.texture then
            row.icon:SetTexture(r.texture); row.icon:Show()
        else
            row.icon:Hide()
        end
    end
    row.name:SetText(r.name)
    -- Colour the name by item QUALITY, the way its tooltip does -- a rare
    -- reads blue, an epic purple. ITEM_QUALITY_COLORS is FrameXML's own table,
    -- so the greens and blues match the rest of the game exactly rather than
    -- being re-guessed here. Same treatment the Auctions tab already gives its
    -- rows.
    local q = r.quality
    if q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q] then
        local c = ITEM_QUALITY_COLORS[q]
        row.name:SetTextColor(c.r, c.g, c.b)
    else
        row.name:SetTextColor(C.text[1], C.text[2], C.text[3])
    end
    -- "You can't use this" used to be the name turning red, which quality
    -- colouring now owns. It moves to a red tint on the ICON so the warning
    -- survives -- the two cues were always fighting for the same pixels, and
    -- the hover tooltip spells out the actual requirement either way.
    --
    -- The old test was `r.canUse == nil or r.canUse`, which never warned about
    -- anything: GetAuctionItemInfo returns canUse as 1-or-NIL, so "nil" IS the
    -- cannot-use answer, and treating it as unknown-so-assume-fine made the
    -- red branch unreachable. Usable is simply "canUse is truthy".
    if row.icon then
        if r.canUse then
            row.icon:SetVertexColor(1, 1, 1)
        else
            row.icon:SetVertexColor(1, 0.3, 0.3)
        end
    end
    local DASH = "\226\128\148"
    if row.ct then
        -- Crafting tab: the stack count is its own column.
        row.ct:SetText("x" .. r.count)
        row.unit:SetText(r.unit and util.FormatMoney(r.unit, true) or DASH)
        if r.buyout and r.buyout > 0 then
            row.stack:SetText(util.FormatMoney(r.buyout, true))
        else
            local nb = r.nextBid or r.minBid or 0
            if nb > 0 then
                row.stack:SetText("bid " .. util.FormatMoney(nb, true))
            else
                row.stack:SetText("bid only")
            end
        end
    else
        -- Buy tab: the mockup's columns.
        --
        -- Stack count rides on the NAME ("Thick Leather Tunic x2") rather than
        -- taking a column of its own -- that is what buys the width for Lvl,
        -- Time Left, Seller and Current Bid.
        if r.count and r.count > 1 then
            row.name:SetText(r.name .. "  x" .. r.count)
        end
        row.lvl:SetText((r.level and r.level > 0) and r.level or "")
        -- 1..4 -> Short / Medium / Long / Very Long, through the client's own
        -- localized globals, so this reads correctly on a non-English client.
        local tl = ""
        if r.timeLeft then
            tl = getglobal("AUCTION_TIME_LEFT" .. r.timeLeft) or ""
        end
        row.left:SetText(tl)
        local bidNow = (r.bidAmount and r.bidAmount > 0) and r.bidAmount
                       or (r.minBid or 0)
        row.bid:SetText(bidNow > 0 and util.FormatMoneyGold(bidNow) or DASH)

        if r.buyout and r.buyout > 0 then
            row.stack:SetText(util.FormatMoneyGold(r.buyout))
            row.unit:SetText(util.FormatMoneyGold(r.unit or r.buyout))
        else
            -- No buyout: an em-dash in the Buyout column and "bid only" under
            -- Unit, exactly as the mockup's Dredgemire Leggings row reads.
            row.stack:SetText(DASH)
            row.unit:SetText("bid only")
        end
    end
    local market = r.itemId and A.db.MarketValue(r.itemId)
    if market and market > 0 and r.unit then
        local pct = math.floor(r.unit / market * 100)
        row.pct:SetText(pct .. "%")
        row.pct:SetTextColor(PctColorBuy(pct))
    else
        row.pct:SetText(DASH)
        row.pct:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
    end

    -- A row you own is dimmed WHOLE and labelled, the way the mockup greys
    -- its "Wild Leather Vest (yours)". Applied after every cell is written,
    -- so nothing above can undo it.
    if row.check then
        if r.mine then
            row.name:SetText(row.name:GetText() .. " |cff808080(yours)|r")
        end
        local a = r.mine and 0.45 or 1.0
        local dim = { row.lvl, row.left, row.bid, row.stack,
                      row.unit, row.pct }
        local di = 1
        while di <= table.getn(dim) do
            dim[di]:SetAlpha(a)
            di = di + 1
        end
        row.name:SetAlpha(a)
        if row.icon then row.icon:SetAlpha(a) end
        -- ...and you cannot tick your own auction into a buyout batch. The
        -- box is DIMMED rather than hidden: hiding it punched a hole in the
        -- tick column, so an owned row read as a row missing a cell instead
        -- of a row you are not allowed to buy.
        row.check:SetChecked(ui.IsBuyChecked(r) and 1 or nil)
        row.check:SetDimmed(r.mine and true or false)
    end
    -- Per-row buttons exist only on the Crafting tab's rows now; the Buy tab
    -- is Blizzlike (select a row, act from the bottom bar), so its rows carry
    -- selTex instead and this block is skipped.
    if row.buyBtn then
        if r.mine then
            row.buyBtn:Disable(); row.bidBtn:Disable()
        else
            if r.buyout and r.buyout > 0 then row.buyBtn:Enable()
            else row.buyBtn:Disable() end
            row.bidBtn:Enable()
        end
    end
    row:Show()
end

-- Clicking a column header: the SAME column flips direction, a NEW column
-- starts ascending. Returns the new key and direction.
--
-- One rule, five tables. There were three hand-written copies of this before
-- Auctions and History wanted a fourth and a fifth -- and three copies of a
-- four-line rule is how a table ends up flipping when its neighbour does not.
function ui.NextSort(curKey, curDir, key)
    if curKey == key then
        return key, (curDir == "asc") and "desc" or "asc"
    end
    return key, "asc"
end

-- Order a copy of `all` by `keyOf`, ascending or descending.
--
-- THE NIL RULE IS THE WHOLE FUNCTION, and this addon has already got it
-- wrong once: a row whose value is missing ALWAYS sinks, in BOTH directions.
-- Folding the guards into the direction branch instead floats priceless rows
-- to the TOP of a descending sort, where they read as the most expensive
-- things on the page -- a bid-only auction presenting as the dearest listing.
-- That is a claim about what the table MEANS, not about any one column, so it
-- lives in one place and every table borrows it.
--
-- `keyOf` may return numbers or strings, but must be consistent within a
-- column: Lua cannot order a number against a string. An empty string is a
-- value and does not sink -- "" is truthy in Lua.
function ui.SortByKey(all, keyOf, dir)
    local rows = {}
    local i = 1
    while i <= table.getn(all or {}) do
        table.insert(rows, all[i])
        i = i + 1
    end
    table.sort(rows, function(a, b)
        local av, bv = keyOf(a), keyOf(b)
        if not av and not bv then return false end
        if not av then return false end   -- no value -> always last
        if not bv then return true end
        if dir == "desc" then return av > bv end
        return av < bv
    end)
    return rows
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
    -- Name sorts alphabetically; everything else numerically. Both go
    -- through ui.SortByKey -- a name is never nil here (it falls back to "",
    -- which is truthy), so the sink rule simply never fires on this column.
    if sortKey == "name" then
        return ui.SortByKey(rows, function(r)
            return string.lower(r.name or "")
        end, dir)
    end

    local function keyOf(r)
        if sortKey == "stack" then
            return (r.buyout and r.buyout > 0) and r.buyout or nil
        elseif sortKey == "pct" then
            local m = r.itemId and A.db.MarketValue(r.itemId)
            if m and m > 0 and r.unit then return r.unit / m end
            return nil
        elseif sortKey == "ct" then
            return r.count
        elseif sortKey == "lvl" then
            return r.level
        elseif sortKey == "left" then
            return r.timeLeft
        elseif sortKey == "bid" then
            local b = (r.bidAmount and r.bidAmount > 0) and r.bidAmount
                      or r.minBid
            return (b and b > 0) and b or nil
        end
        return r.unit
    end
    return ui.SortByKey(rows, keyOf, dir)
end

-- Build the clickable column headers for a results table. Every column sorts.
-- The headers are bare text on an invisible button (aegisNoSkin) so the pfUI
-- skin leaves them alone -- skinning them draws a backdrop per header and they
-- overlap. Each button is sized to its own label so hit areas never collide.
-- `cols` maps key -> x offset, `widths` key -> column width. Returns the
-- key -> button table for ui.PaintSortHeaders.
-- Crafting's five columns. The Buy tab passes its own eight.
local CRAFT_HEADER_DEFS = {
    { key = "name",  text = "Item" },
    { key = "ct",    text = "Ct" },
    { key = "unit",  text = "Unit price" },
    { key = "stack", text = "Stack buyout" },
    { key = "pct",   text = "% mkt" },
}

function ui.MakeSortHeaders(panel, rowLeft, y, cols, widths, onClick, defs)
    local headers = {}
    defs = defs or CRAFT_HEADER_DEFS
    local i = 1
    while i <= table.getn(defs) do
        local d = defs[i]
        local cx = cols[d.key]
        if cx then
            local b = CreateFrame("Button", nil, panel)
            b:SetHeight(16)
            b.aegisNoSkin = true       -- keep pfUI's button backdrop off it
            local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetText(d.text)
            -- Warm tan, as the mockup has them. GameFontDisableSmall's grey
            -- made the whole header band read as disabled rather than as the
            -- table's headings.
            fs:SetTextColor(0.85, 0.72, 0.42)
            b.label = fs
            b.baseText = d.text
            if d.just == "RIGHT" then
                -- A numeric column's header sits over the RIGHT edge of its
                -- cells, because the cells are right-justified. Left-aligning
                -- the header of a right-aligned column is the thing that makes
                -- a table look like it was assembled rather than designed.
                b:SetWidth(widths[d.key] or 40)
                b:SetPoint("TOPLEFT", panel, "TOPLEFT", rowLeft + cx, y)
                fs:SetPoint("RIGHT", b, "RIGHT", 0, 0)
                fs:SetJustifyH("RIGHT")
            else
                b:SetPoint("TOPLEFT", panel, "TOPLEFT", rowLeft + cx, y)
                fs:SetPoint("LEFT", b, "LEFT", 0, 0)
                -- Width: the label plus room for the sort arrow, but never
                -- wider than the column, so adjacent headers can't overlap.
                local w = fs:GetStringWidth() + 12
                local maxw = (widths[d.key] or 40) + 12
                if w > maxw then w = maxw end
                b:SetWidth(w)
            end
            b:SetScript("OnClick", function() onClick(d.key) end)
            headers[d.key] = b
        end
        i = i + 1
    end
    return headers
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

-- Row height 26, up from 20. The mockup's rows are noticeably taller than a
-- packed list -- eight columns need the breathing room to stay readable, and
-- a tick box needs somewhere to sit. Not the mockup's literal 43: that is a
-- CSS pixel in a 2000px-wide render, and translating it straight across would
-- give five visible rows.
local BUY_ROWS,  BUY_ROW_H  = 11, 26
local BUY_ROWS_MAX  = 34
-- Two row heights: the mockup's plates are noticeably taller than its bare
-- subcategory rows (38px vs 27px at its scale). One height for both is what
-- made our tree look cramped and evenly-spaced where the mockup has rhythm.
local SIDE_ROWS, SIDE_ROW_H = 13, 22   -- SIDE_ROW_H is the PLATED height
local SIDE_BARE_H = 17                 -- ...and bare rows are tighter
-- Table geometry, named because three things have to agree about it: the well
-- that draws the box, the headers inside it, and the scroll frame the rows
-- live in. When these were three loose numbers at three call sites the well
-- ended up enclosing the rows but not the headings.
-- Buy tab layout, in ONE table rather than a dozen file-scope locals.
--
-- Not tidiness: Lua 5.0 allows a function only 32 UPVALUES, and every
-- file-scope local that ui.BuildBuyTab reads costs one. Thirteen separate
-- constants took it to 36 and the client refused to load the file at all --
-- "too many upvalues (limit=32)". A table is a single upvalue however many
-- fields it carries. Keep new layout numbers in here.
--
-- THE CONTROL STRIP SPANS THE FULL WIDTH AND BOTH COLUMNS SIT UNDER IT.
-- It used to start to the RIGHT of the sidebar, so the sidebar sat beside
-- the strip rather than beneath it. In the mockup the Name field, the BROWSE
-- heading and the category plates all share one left edge.
local BUYL = {
    strip_lbl_gap = 6,  -- air between a field label and ITS control
    strip_ctl_y = 23,   -- ...and ONE top edge for every control
    ctl_h       = 20,   -- ...at ONE height, dropdown included
    side_x      = 10,   -- shared left edge: strip, BROWSE, plates
    gut_w       = 8,    -- sidebar -> table gutter (the mockup's is tight)

    browse_y    = 62,   -- BROWSE heading, below the strip
    side_top    = 82,   -- ...and the first category row under it
    side_bot    = 40,   -- the tree runs nearly to the action bar

    well_top    = 56,   -- table box starts just above the headings
    hdr_top     = 62,   -- headings sit INSIDE the box
    hdr_h       = 22,   -- headings band inside the well
    rows_top    = 86,   -- ...so the first row starts here

    -- The table FILLS the height available to it, stopping only far enough
    -- above the action bar for the count/pager row and the rule.
    --
    -- It used to stop at ~64% of the panel because the mockup's does. That
    -- reads as dead space on a real window: the mockup is one screenshot with
    -- five results, and ours has fifty. Rows are what the tab is for.
    -- Budget below this line: 8 gap + 20 pager + 10 gap + rule at 38.
    table_bot   = 82,

    -- Gutter right of the table. FauxScrollFrameTemplate hangs its scrollbar
    -- OUTWARD from the scroll frame's right edge; this keeps it off the last
    -- column instead of drawn across the percentages.
    gutter_w    = 26,
}

-- ADVANCED-mode layout, in ONE table for the same upvalue reason as BUYL --
-- see the note above it. ui.BuildBuyTab is the function that reads both, and
-- it is the one that broke the 32-upvalue ceiling once already.
--
-- Advanced hides the category tree, so every number here is measured from the
-- panel's own left margin, not from the results column.
local ADVL = {
    strip_y   = 12,   -- Back button / query box, top of the panel
    tabs_y    = 38,   -- the three view tabs, under the strip
    tab_h     = 20,   -- ...their height, so body_y can be checked against it
    tab_gap   = 8,    -- between tabs
    -- A tab is sized to the widest LABEL, clamped, and the row is centred --
    -- it does not stretch to fill the panel. Three equal thirds of a 1400px
    -- window is a 442px pill for a 95px label; three thirds of a 1000px one is
    -- still 308. Bounded and centred, a tab is the same size wherever the
    -- window is, which is what a tab strip should be.
    tab_pad   = 26,   -- label -> tab edge, each side
    tab_min   = 200,
    tab_max   = 280,

    -- CONTENT TOP. All three Advanced views start here -- Search Results as
    -- well as Saved and Builder. It used to be Saved/Builder only, with the
    -- results table still positioned from BUYL.well_top (56), a number
    -- measured against the Blizzlike CONTROL strip. The tab strip ends at
    -- tabs_y + tab_h = 58, so that table's box began 2px ABOVE the tabs, and
    -- the three views started on three different lines.
    body_y    = 78,
    -- ...and stops here, clear of the action bar's rule.
    --
    -- The rule is 38px up (ui.buyBarRule). At 36 the wells stopped BELOW it
    -- and drew over it, which is why the footer only looked right on Search
    -- Results -- its table stops at BUYL.table_bot (82) to leave room for the
    -- count and pager, and cleared the rule by accident rather than by intent.
    body_bot  = 52,

    right_pad = 12,   -- content's right margin inside the panel
    strip_gap = 10,   -- query box -> Search button
    gutter    = 12,   -- between the two columns, Saved and Builder alike
}

-- Put the Search button where the CURRENT mode wants it.
--
-- It cannot simply hang off the Advanced button, which is what it did: that
-- button belongs to the default strip, so in Advanced it is hidden but still
-- positioned, and Search inherited a slot 10px below the Advanced strip's own
-- baseline and inset by the Advanced button's width plus its gap. The query
-- box then ran across it, because the box's right margin was a constant that
-- had to agree with three numbers it could not see.
--
-- Both modes put Search at the right end of the strip; only the strip's
-- baseline and what sits beside it differ.
function ui.AnchorSearchButton()
    local b = ui.buySearchBtn
    if not b then return end
    b:ClearAllPoints()
    if ui.buyMode == "advanced" then
        -- Nothing to its right in Advanced: the Advanced button is what took
        -- that slot, and it is gone.
        b:SetPoint("TOPRIGHT", b:GetParent(), "TOPRIGHT",
            -ADVL.right_pad, -ADVL.strip_y)
    else
        -- A real gap. These were flush against each other, so they read as one
        -- two-tone control rather than as two buttons.
        b:SetPoint("RIGHT", ui.buyAdvBtn, "LEFT", -14, 0)
    end
end

-- Spread the three view tabs across the panel so they fill its width, and
-- CENTRE the group.
--
-- Two things went wrong here before. The widths came from `panel:GetWidth()` --
-- a measured, two-edge-anchored frame, so they were computed at the window's
-- creation size and the strip filled 69% of a resized panel. And the group was
-- anchored from the LEFT, so all of that shortfall pooled into one gap on the
-- right, which is what it looked like: three buttons shoved to one side.
--
-- Both are fixed by the same pair of changes: take the width from the WINDOW,
-- which is set explicitly (ui.AdvContentWidth), and anchor the row by its
-- centre so any rounding residue splits evenly instead of landing on one edge.
-- The width all three tabs take: the widest LABEL plus padding, clamped.
--
-- Equal to each other, as the concept has them, but sized to their text rather
-- than to the panel. Three equal thirds of the content width made a 442px pill
-- for a 95px label on a wide window and was still 308px on the narrowest one.
local function ViewTabWidth(btns)
    local widest = 0
    local i = 1
    while i <= table.getn(btns) do
        local fs = btns[i].label
        if fs then
            local ok, sw = pcall(function() return fs:GetStringWidth() end)
            if ok and sw and sw > widest then widest = sw end
        end
        i = i + 1
    end
    local w = math.ceil(widest) + 2 * ADVL.tab_pad
    if w < ADVL.tab_min then w = ADVL.tab_min end
    if w > ADVL.tab_max then w = ADVL.tab_max end
    return w
end

-- Size the three view tabs and CENTRE the row.
--
-- Centred on the CONTENT's centre, not the panel's. The content does not sit
-- symmetrically in the panel -- it runs from BUYL.side_x (10) to
-- -ADVL.right_pad (12) -- so centring on the panel put the row 1-2px off the
-- wells below it, and by a different amount at each window size because
-- math.floor threw the remainder away. Off by two at the minimum size, off by
-- one the other way at the maximum.
function ui.LayoutViewTabs()
    local btns = ui.buyViewBtns
    if not btns or table.getn(btns) == 0 then return end
    local n = table.getn(btns)
    local avail = ui.AdvContentWidth()
    if avail < 200 then return end          -- no window size yet

    local w = ViewTabWidth(btns)
    -- Never wider than the space actually available, however the labels
    -- measure -- a localised client could hand us a long one.
    local maxW = math.floor((avail - (n - 1) * ADVL.tab_gap) / n)
    if w > maxW then w = maxW end
    local i = 1
    while i <= n do
        btns[i]:SetWidth(w)
        i = i + 1
    end

    -- Only the FIRST tab is anchored to the panel; the other two chain off it,
    -- so this one point places all three. The offset is from the content's
    -- left edge, which is what makes the row agree with every well below it.
    local total = n * w + (n - 1) * ADVL.tab_gap
    local left = BUYL.side_x + math.floor((avail - total) / 2)
    btns[1]:ClearAllPoints()
    btns[1]:SetPoint("TOPLEFT", btns[1]:GetParent(), "TOPLEFT",
        left, -ADVL.tabs_y)
end

-- NOTE ON PLACEMENT: this sits AFTER BUYL because it reads it.
-- Lua scopes a local from its declaration onward, so at its previous
-- home 500 lines earlier `BUYL` was not a local in scope -- it was a
-- read of a nil GLOBAL, which compiles cleanly and only fails when the
-- function runs. It shipped in 1.19.0 and the window would not open.
-- tests/lint/scoping.py exists to catch the next one.
-- Move the results table between its two origins, and give the width it gains
-- in Advanced to the Item column.
--
-- Only THREE things are re-anchored -- the well, the scroll frame and the
-- header buttons. The header rule, the column ticks, the count line and the
-- pager all hang off the well, and the rows off the scroll frame, so they
-- follow. That is why those anchors were written as relationships rather than
-- as repeated panel offsets.
function ui.LayoutBuyTable()
    local panel = ui.buyPanel
    if not panel or not ui.buyListWell or not ui.buyScroll then return end
    local left = ui.buyTableLeft
    if ui.buyMode == "advanced" then left = ui.buyTableLeftAdv end
    -- Surplus over the Blizzlike width, all of it to Item: it is the column
    -- that actually runs out of room, and every numeric column is already
    -- sized to its contents.
    BUY_NAME_EXTRA = ui.buyTableLeft - left
    if BUY_NAME_EXTRA < 0 then BUY_NAME_EXTRA = 0 end

    -- The table's TOP also moves with the mode.
    --
    -- BUYL.well_top / hdr_top / rows_top were measured against the BLIZZLIKE
    -- control strip. Advanced has a TAB STRIP there instead, ending at
    -- tabs_y + tab_h = 58 -- so in Advanced the Blizzlike well_top of 56 put
    -- the table's box 2px ABOVE the tabs, and Search Results began ten pixels
    -- higher than Saved Searches and the Filter Builder. All three views start
    -- on ADVL.body_y now; the header and row offsets keep their spacing
    -- relative to the box rather than being restated.
    local wellTop, hdrTop, rowsTop = BUYL.well_top, BUYL.hdr_top, BUYL.rows_top
    if ui.buyMode == "advanced" then
        wellTop = ADVL.body_y
        hdrTop  = wellTop + (BUYL.hdr_top - BUYL.well_top)
        rowsTop = wellTop + (BUYL.rows_top - BUYL.well_top)
    end

    ui.buyScroll:ClearAllPoints()
    ui.buyScroll:SetPoint("TOPLEFT", panel, "TOPLEFT", left, -rowsTop)
    ui.buyScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT",
        -BUYL.gutter_w, BUYL.table_bot)
    ui.buyListWell:ClearAllPoints()
    ui.buyListWell:SetPoint("TOPLEFT", panel, "TOPLEFT",
        left - 6, -wellTop)
    ui.buyListWell:SetPoint("BOTTOMRIGHT", ui.buyScroll, "BOTTOMRIGHT", 0, -6)

    for key, b in pairs(ui.buyHeaders or {}) do
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", panel, "TOPLEFT",
            left + ColX(key), -hdrTop)
    end
    local tk = { "lvl", "left", "bid", "stack", "unit", "pct" }
    local ti = 1
    while ti <= table.getn(ui.buyHdrTicks or {}) do
        local t = ui.buyHdrTicks[ti]
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", ui.buyListWell, "TOPLEFT",
            6 + ColX(tk[ti]) - 8, -6)
        t:SetPoint("BOTTOMLEFT", ui.buyListWell, "TOPLEFT",
            6 + ColX(tk[ti]) - 8, -(BUYL.hdr_h))
        ti = ti + 1
    end
    local ri = 1
    while ri <= table.getn(ui.buyRows or {}) do
        ui.LayoutBuyRow(ui.buyRows[ri])
        ri = ri + 1
    end
end

-- Do the result columns fit the row width at a window `w` wide?
--
-- Same reasoning as StripFitsAt below: with fixed column offsets nothing in
-- the anchoring stops the last column running under the scrollbar, so the
-- constraint is arithmetic and belongs somewhere it can be checked. Removing
-- the Seller column changed every offset after it; this is what says whether
-- the new numbers still fit rather than someone re-adding them by hand.
-- How much room the results table has, and whether what sits beneath it
-- still fits, at a window `h` tall.
--
-- The table now FILLS the height rather than stopping at a fixed fraction, so
-- the thing that has to be checked is the other direction: that the strip
-- above and the count/pager, rule and action bar below all still have their
-- space. Returns the usable row area, and false if the budget is blown.
-- Vertical distance from the WINDOW's height to a tab panel's height. The
-- content frame is inset 80 at the top and 16 at the bottom of the window,
-- and each tab panel a further 6 inside that.
--
-- This said 22, so everything derived from it thought the panel had 86 more
-- pixels than it does. It was never noticed because nothing in the addon
-- actually called the functions below -- only the tests did.
local PANEL_V_INSET = 80 + 16 + 6 + 6

-- ...and the same sum horizontally: the content frame is inset 14 at each side
-- of the window, and each tab panel a further 6 inside that.
--
-- This exists for the reason PANEL_V_INSET does, and it was added after the
-- same bug happened again in the other axis. The Advanced tab strip and the
-- Filter Builder's columns both sized themselves from a MEASURED frame, and
-- both came out at the window's CREATION width -- a tab strip filling 69% of
-- the panel and a form column at 29% where 41% was asked for. See
-- ui.PanelWidthAt.
local PANEL_H_INSET = 14 + 14 + 6 + 6

-- Panel height at a given WINDOW height.
--
-- Deriving from the window rather than measuring a frame is the whole point:
-- GetHeight() on a two-edge-anchored frame reports the height it was last
-- LAID OUT at, and the client relayouts on the next frame. RestoreWindowSize
-- sets the window's height and nothing repaints afterwards, so every list
-- that measured its own scroll frame kept the count it computed at the
-- window's creation size while the box grew with its anchors. That gap
-- between a full-height box and a half-full list is the bug.
--
-- The window's height is set explicitly, so it is true the moment it is read.
function ui.PanelHeightAt(h)
    return (h or 0) - PANEL_V_INSET
end

-- Panel width at a given WINDOW width. Same reasoning as PanelHeightAt above,
-- and it is not a hypothetical: GetWidth() on the Buy panel returned ~1003 on
-- a window whose panel was ~1430, because that is the size it was laid out at
-- when the window was created and nothing had relaid it since.
--
-- ANY layout that divides the panel horizontally must come through here rather
-- than measure a frame.
function ui.PanelWidthAt(w)
    return (w or 0) - PANEL_H_INSET
end

-- The width available to Advanced's content: the panel, less its left margin
-- and right padding. One place, because the tab strip and the Filter Builder
-- both divide it and drifting apart would show as a form that does not line up
-- with the tabs above it.
function ui.AdvContentWidth()
    local w = ui.PanelWidthAt(ui.frame and ui.frame:GetWidth() or 0)
    return w - BUYL.side_x - ADVL.right_pad
end

-- Split an Advanced view's frame into two equal columns with one gutter.
--
-- ONE function for BOTH overlay views, because Saved Searches and the Filter
-- Builder occupy the same space and clicking between them must move nothing.
-- They had two copies of this arithmetic and the copies disagreed:
--
--   Saved   anchored colL's right to the frame's own BOTTOM midpoint at -8 and
--           colR's left to its TOP at +8  -> a 16px gutter, columns (W-16)/2,
--           measured off the frame.
--   Builder set colL's width to (AdvContentWidth - 12) / 2 and hung colR off
--           it -> a 12px gutter, columns (W-12)/2, measured off the window.
--
-- Two pixels on each column and four on the gutter, which is exactly the shift
-- you see switching tabs. Returns the column width.
function ui.SplitAdvColumns(frame, colL, colR)
    if not frame or not colL or not colR then return 0 end
    local total = ui.AdvContentWidth()
    local lw = math.floor((total - ADVL.gutter) / 2)
    if lw < 100 then lw = 100 end

    colL:ClearAllPoints()
    colL:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    colL:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    colL:SetWidth(lw)

    -- The right column takes what is left rather than a second computed width,
    -- so the two can never fail to meet in the middle.
    colR:ClearAllPoints()
    colR:SetPoint("TOPLEFT", colL, "TOPRIGHT", ADVL.gutter, 0)
    colR:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    return lw
end

-- Re-split both overlay views. Called from every path that changes the
-- window's width, so the two stay identical rather than only agreeing on the
-- pass that happened to run last.
function ui.LayoutAdvColumns()
    if ui.buySaved and ui.savedColL and ui.savedColR then
        ui.SplitAdvColumns(ui.buySaved, ui.savedColL, ui.savedColR)
    end
    if ui.buyBuilder and ui.fbColL and ui.fbColR then
        ui.SplitAdvColumns(ui.buyBuilder, ui.fbColL, ui.fbColR)
    end
end

-- Where the table's first row starts, for the CURRENT mode. Advanced puts the
-- tab strip where Blizzlike puts its control strip, so the table sits lower
-- there -- and the row count has to know, or it fills the box for a Blizzlike
-- height and draws the last row past the bottom of a shorter one. Rows are not
-- the scroll frame's scroll-child; nothing clips an overflowing one.
function ui.TableRowsTop()
    if ui.buyMode == "advanced" then
        return ADVL.body_y + (BUYL.rows_top - BUYL.well_top)
    end
    return BUYL.rows_top
end

function ui.TableAreaAt(h)
    local panelH = ui.PanelHeightAt(h)
    local area = panelH - ui.TableRowsTop() - BUYL.table_bot
    -- Below the table: 8px gap, the 20px pager row, 10px gap, then the rule
    -- at 38 and the action bar under it.
    local belowNeeded = 8 + 20 + 10 + 38
    return area, (area > 0 and BUYL.table_bot >= belowNeeded)
end

-- How much room below the table is NOT spoken for -- the dead band between
-- the table's bottom edge and the things that have to sit under it.
--
-- The point of the table filling the height is that this stays small. A
-- generous table_bot satisfies TableAreaAt perfectly well while leaving a
-- visible empty strip, which is the state this pass set out to remove, so it
-- needs its own number rather than being implied by "the budget fits".
function ui.TableSlack()
    return BUYL.table_bot - (8 + 20 + 10 + 38)
end

-- How many WHOLE rows that area holds. Never a partial row: a row clipped by
-- the box's bottom edge is worse than the gap it would have filled, and rows
-- are not the scroll frame's scroll-child so nothing would clip it -- it
-- would simply draw over the count line.
function ui.TableRowsAt(h)
    local area = ui.TableAreaAt(h)
    local n = math.floor(area / BUY_ROW_H)
    if n < 1 then n = 1 end
    if n > BUY_ROWS_MAX then n = BUY_ROWS_MAX end
    return n
end

-- The Sell tab's geometry, in ONE place: the two columns' horizontal
-- positions and the listings table's vertical bands.
--
-- `bag_right` is the bag column's right edge and `list_x` where the listings
-- column starts; both were literals (168, and 200 repeated at three call
-- sites), which is how a column and the thing beside it drift apart. The bag
-- column was 156px wide, which truncated most item names to "Pattern: Fine
-- Leather Bo...". A FauxScrollFrame's scrollbar sits just OUTSIDE its right
-- edge, so the gutter between the two columns has to clear it -- that is what
-- `list_x - bag_right` buys.
--
-- The vertical bands mirror BUYL's, because the listings table is now drawn
-- the same way: ONE box around the headings AND the rows, a rule under the
-- headings, and the status line hanging below the box rather than floating
-- above it. Same spacing as the Buy table -- 6 from the box's top to the
-- headings, a 22px heading band, 8 below the rule to the first row.
local SELLL = {
    bag_x      = 12,
    bag_right  = 238,
    list_x     = 270,
    list_right = 26,

    well_top   = SELL_TOP_H + 10,
    hdr_top    = SELL_TOP_H + 16,
    hdr_h      = 22,
    rows_top   = SELL_TOP_H + 40,
    -- Room under the box for the status line. Smaller than the Buy tab's 82
    -- because nothing follows it: the Sell tab has no action bar and the
    -- listings need no pager (one scan, one item, one page).
    table_bot  = 26,
}

-- Scroll-frame insets for every list OUTSIDE the Buy results table, in ONE
-- place per list, because two things have to agree about each pair: the
-- SetPoint that positions the box, and the arithmetic that decides how many
-- rows go in it. When those were separate numbers the second did not exist at
-- all -- every one of these lists measured its own frame instead.
--
-- `top` is the inset from the top of the PANEL, `bot` from the bottom, which
-- is exactly what each SetPoint already carried. Two of them start below the
-- Sell tab's fixed upper block, so they are written as SELL_TOP_H plus their
-- own gap rather than as a total nobody could check.
--
-- A table rather than twelve file-scope locals: thirteen constants as
-- thirteen locals cost thirteen upvalues (HARD RULE 12a), and ui.BuildSellTab
-- is already a large function.
local LISTBOX = {
    craftSide = { top = 28,  bot = 132 },
    craft     = { top = 94,  bot = 10 },
    auc       = { top = 70,  bot = 10 },
    hist      = { top = 100, bot = 10 },
    bag       = { top = SELL_TOP_H + 26, bot = 10 },
    sellList  = { top = SELLL.rows_top, bot = SELLL.table_bot },
}
ui.LISTBOX = LISTBOX     -- read by the geometry suite

-- How many WHOLE rows a list shows at a given WINDOW height.
--
-- THIS REPLACES ui.RowsFor, WHICH MEASURED THE SCROLL FRAME. Every one of its
-- six callers anchored that frame by two corners, so GetHeight() reported the
-- height it was last LAID OUT at -- the window's creation size -- and the list
-- kept that row count however tall the window was dragged. Same trap that took
-- the Buy table (ui.PanelHeightAt), the Advanced widths (ui.PanelWidthAt) and
-- the Saved Searches columns (ui.SavedRowsAt); this is the fourth, fifth,
-- sixth, seventh, eighth and ninth instance of it, all at once.
--
-- The window's own height is set explicitly, so it is true the moment it is
-- read. `box` is one entry of LISTBOX above.
--
-- Whole rows only. A row hanging past the bottom of its box is worse than the
-- gap it would have filled: these rows are not the scroll frame's scroll
-- child, so nothing clips one -- it simply draws over whatever is below.
function ui.ListRowsAt(h, box, rowH, maxRows)
    if not box or not rowH or rowH <= 0 then return 1 end
    local area = ui.PanelHeightAt(h) - box.top - box.bot
    local n = math.floor(area / rowH)
    if n < 1 then n = 1 end
    if maxRows and n > maxRows then n = maxRows end
    return n
end

-- The window height every one of those lists is measured against. One reader,
-- so a list cannot accidentally ask a frame instead.
function ui.WindowH()
    return (ui.frame and ui.frame.GetHeight and ui.frame:GetHeight()) or 0
end

-- Usable height of the BROWSE column at a given window height.
function ui.CatAreaAt(h)
    return ui.PanelHeightAt(h) - BUYL.side_top - BUYL.side_bot
end

-- Do all the TOP-LEVEL categories fit without scrolling, at window height h?
--
-- There are eleven ("All Categories" plus ten classes) and they are the
-- plated, taller kind. Asserted true at MIN_H: a category list that cannot
-- show its own categories at the smallest allowed window is a list with a
-- hidden minimum nobody wrote down.
local CAT_TOP_LEVEL_N = 11

function ui.AllCategoriesFitAt(h)
    return ui.CatAreaAt(h) >= (CAT_TOP_LEVEL_N * SIDE_ROW_H)
end

function ui.ColumnsFitAt(w)
    local rowLeft = BUYL.side_x + 176 + BUYL.gut_w + 6   -- SIDE_W is 176
    local rowW = (w - 22) - rowLeft - BUYL.gutter_w
    return BUY_COLS_END <= rowW
end
-- Post Filter clause rows in the Filter Builder.
local FB_POST_ROWS = 9

-- Filter Builder layout, in ONE table -- same upvalue reason as BUYL and ADVL.
-- Row offsets are negative y from the column's top edge; a control sits on its
-- label's row at +3 so text and box share a centre line.
local FBL = {
    pad     = 10,   -- well inset, shared by header, rows and the clause box
    gutter  = 12,   -- between the two columns
    lbl_x   = 12,   -- labels: ONE left margin, not right-aligned into a box
    ctl_x   = 112,  -- ...and the controls form a second column here
    ctl_w   = 230,  -- widened by ui.LayoutBuilderForm at runtime
    lvl_w   = 66,   -- the two level boxes and Stack Size
    chk_gap = 12,   -- box -> its trailing checkbox (Exact / Usable)
    comp_w  = 126,  -- component dropdown

    -- ROW GEOMETRY, derived rather than written out.
    --
    -- These used to be ten hand-written offsets ending at -276, and nothing
    -- checked they fit. At MIN_H the column is only 254px tall
    -- (384 panel - 78 body_y - 52 body_bot), so the Stack Size box overran its
    -- well by 21px and the note below it by 34 -- which is the clipping you
    -- see at the smallest window size. Three rows were added in 1.19.0 and the
    -- form had no way to say it had run out of room.
    --
    -- row_1 is the first row's baseline, row_h the pitch, and gap_extra the
    -- deliberate separation before the Buyout / Full stacks / Stack Size
    -- block. ui.FBRow(n) turns a row number into an offset, and
    -- tests/units/geometry_test.lua asserts the last one still fits at MIN_H.
    row_1     = 30,
    row_h     = 21,
    gap_extra = 8,    -- before the extra-options block (rows 7-9)
    n_rows    = 9,
}

-- Negative y of form row `n` (1-based) inside the builder's left column.
-- Rows 7-9 are the extra-options block and sit after one added gap.
function ui.FBRow(n)
    local y = FBL.row_1 + (n - 1) * FBL.row_h
    if n >= 7 then y = y + FBL.gap_extra end
    return -y
end

-- Set the Builder's status line. Empty text puts it away.
--
-- ONE writer, because the note now lives on the action bar rather than inside
-- the form's column, and something has to raise and lower it -- eight call
-- sites each remembering to Show and Hide is seven chances to forget. `warn`
-- picks the amber the multi-term and missing-value messages use; everything
-- else is quiet gold.
function ui.BuilderNote(text, warn)
    local fs = ui.fbNote
    if not fs then return end
    if not text or text == "" then
        fs:SetText("")
        fs:Hide()
        return
    end
    fs:SetText(text)
    if warn then
        fs:SetTextColor(0.9, 0.6, 0.3)
    else
        fs:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
    end
    fs:Show()
end

-- Full stacks and an explicit stack size cannot both be set: the term holds
-- one or the other (TermToQuery emits `stack/N` when stackSize is set, bare
-- `stack` only when it is not). Typing a size therefore clears the tick.
--
-- Enforced in ONE place, called from the size box, so the two controls cannot
-- drift into a state the query language has no way to express.
function ui.BuilderStackGate()
    if not ui.fbStackSize or not ui.fbFullStack then return end
    local n = tonumber(util.Trim(ui.fbStackSize:GetText() or ""))
    if n and n >= 1 then
        ui.fbFullStack:SetChecked(nil)
    end
end

-- Room a trailing checkbox and its label need to the right of a control:
-- the 16px box, its gap, and the wider of the two labels ("Usable").
--
-- MEASURED, not guessed. A guess that is too small puts the checkbox over the
-- next column -- which is exactly what shipped: Exact and Usable landed in the
-- gutter and drew on top of the POST FILTER panel's own labels.
local function CheckReserve()
    local w = 0
    if ui.fbUsable and ui.fbUsable.label then
        local ok, sw = pcall(function()
            return ui.fbUsable.label:GetStringWidth()
        end)
        if ok and sw and sw > 0 then w = sw end
    end
    if w < 40 then w = 40 end       -- before the font string has measured
    return 16 + FBL.chk_gap + math.ceil(w) + 6
end

-- Give the builder's two columns their share of the panel, and size the form's
-- controls to the left one.
--
-- TWO widths, not one, and that is the whole fix. Stretching every control to
-- fill the column left no room for the checkbox anchored to the Name box's
-- right edge, so it landed past the column. The concept has it right: the Name
-- box and the level pair stop SHORT with their checkbox beside them, while the
-- four dropdowns run the FULL width, past where that checkbox sits.
--
-- The width comes from the WINDOW, not from measuring ui.buyBuilder: that
-- frame is anchored by two edges and reports the width it was last laid out
-- at, which is how the left column ended up at 29% of the panel when it was
-- asked for 41%. See ui.PanelWidthAt.
function ui.LayoutBuilderForm()
    local colL = ui.fbColL
    if not colL or not ui.buyBuilder then return end
    local total = ui.AdvContentWidth()
    if total < 200 then return end          -- no window size yet; keep defaults

    -- The 50/50 split itself is ui.SplitAdvColumns' job, shared with Saved
    -- Searches so the two views cannot drift apart. What is left here is
    -- sizing the CONTROLS inside the column it returns.
    local lw = ui.SplitAdvColumns(ui.buyBuilder, colL, ui.fbColR)

    -- Full width: the four dropdowns, which have nothing beside them.
    local ctl = lw - FBL.ctl_x - FBL.pad
    if ctl < 120 then ctl = 120 end
    FBL.ctl_w = ctl

    -- Short: the Name box, which has Exact beside it.
    local nameW = ctl - CheckReserve()
    if nameW < 80 then nameW = 80 end

    if ui.fbName then ui.fbName:SetWidth(nameW) end
    local dds = { ui.fbClass, ui.fbSubclass, ui.fbSlot, ui.fbQuality }
    local i = 1
    while i <= table.getn(dds) do
        if dds[i] and dds[i].SetWidth then dds[i]:SetWidth(ctl) end
        i = i + 1
    end

    -- The level pair shares the Name box's span, so Usable lands under Exact
    -- rather than wherever two fixed 66px boxes and a dash happened to end.
    -- Each box takes half of what is left after the dash's gaps.
    local lvl = math.floor((nameW - 14) / 2)
    if lvl < 40 then lvl = 40 end
    if ui.fbMinLevel then ui.fbMinLevel:SetWidth(lvl) end
    if ui.fbMaxLevel then ui.fbMaxLevel:SetWidth(lvl) end
end
local SIDE_ROWS_MAX = 38
-- Sidebar width. The mockup's is 18.1% of the panel; ours was ~16%, and the
-- gutter beside it was four times too wide.
local SIDE_W = 176    -- sidebar width

function ui.BuildBuyTab()
    local panel = ui.panels["Buy"]
    if not panel or ui.buyBuilt then return end
    ui.buyBuilt = true
    ui.buyExpanded = {}

    -- ===== Left column: the category tree (DEFAULT mode only) ===========
    -- The Shopping Lists sidebar is gone. Advanced has NO left column at all
    -- now -- its Builder and Saved views span the full content width, which
    -- is what the approved concept shows and what stops the form's headings
    -- being clipped by a column that had no business being there.
    local browseHdr = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    browseHdr:SetPoint("TOPLEFT", panel, "TOPLEFT",
        BUYL.side_x, -BUYL.browse_y)
    -- Letter-spaced caps, as the mockup has it. 1.12 has no letter-spacing
    -- property, so the spaces are in the string.
    browseHdr:SetText("B R O W S E")
    browseHdr:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    ui.buyBrowseHdr = browseHdr

    -- ===== Left, mode 2: the category tree (ROADMAP 2e) =================
    local catScroll = CreateFrame("ScrollFrame", "AegisExchangeBuyCatScroll",
        panel, "FauxScrollFrameTemplate")
    catScroll:SetPoint("TOPLEFT", panel, "TOPLEFT",
        BUYL.side_x, -BUYL.side_top)
    -- The tree is the LONGER column in the mockup: it runs down past the
    -- table's bottom edge to just above the action bar. It used to stop
    -- halfway, leaving the lower half of the sidebar empty.
    catScroll:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT",
        BUYL.side_x, BUYL.side_bot)
    catScroll:SetWidth(SIDE_W)
    catScroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(SIDE_ROW_H, ui.UpdateCatTree)
    end)
    catScroll:Hide()
    ui.buyCatScroll = catScroll

    -- HIDE THE SCROLLBAR. FauxScrollFrameTemplate hangs it OUTWARD from the
    -- scroll frame's right edge, which here is 186 -- and the results box
    -- starts at 194. The two occupied the same eight pixels, so the arrows
    -- and thumb drew across the table's left border. Its down-arrow also
    -- floated far below the list, because this frame runs to the panel bottom
    -- while the categories usually end much higher.
    --
    -- Widening the gutter would fix the overlap but open the tight gap the
    -- mockup deliberately has, and the mockup shows no scrollbar at all. The
    -- WHEEL still scrolls: FauxScrollFrameTemplate's OnMouseWheel drives the
    -- scroll bar's value, and a hidden frame still holds and reports a value.
    ui.HideScrollBar = function(sf)
        local nm = sf:GetName()
        if not nm then return end
        local bar = getglobal(nm .. "ScrollBar")
        if bar then
            bar:Hide()
            -- FauxScrollFrame_Update re-Shows the bar whenever the content
            -- overflows, so neutralise Show rather than relying on one Hide.
            bar.Show = function() end
        end
    end
    ui.HideScrollBar(catScroll)

    -- The mockup draws NO box around the category list -- just the BROWSE
    -- heading and the plates below it, directly on the panel. This frame is
    -- kept because BitsFor and the mode switch both raise and lower it with
    -- the tree, but it draws nothing: a bordered trough fought with the
    -- plated rows inside it, and the results table is the only thing on this
    -- tab the mockup puts in a box.
    local catWell = CreateFrame("Frame", nil, panel)
    catWell:SetPoint("TOPLEFT", catScroll, "TOPLEFT", -6, 6)
    catWell:SetPoint("BOTTOMRIGHT", catScroll, "BOTTOMRIGHT", 24, -6)
    catWell:SetFrameLevel(panel:GetFrameLevel())
    catWell:Hide()
    ui.buyCatWell = catWell

    ui.buyCatRows = {}
    ui.buyCatExpanded = {}
    ui.GrowCatRows = function(n)
        if n > SIDE_ROWS_MAX then n = SIDE_ROWS_MAX end
        local i = table.getn(ui.buyCatRows) + 1
        while i <= n do
            local row = CreateFrame("Button", nil, panel)
            row:SetHeight(SIDE_ROW_H)
            row:SetWidth(SIDE_W)
            -- Clickable, but a LIST ROW, not a button: the plate below is
            -- the tree's own and says whether this is a top-level category,
            -- so the skin must not replace it with a uniform button plate.
            -- aegisNoSkin is the existing opt-out for exactly this.
            row.aegisNoSkin = true
            -- Anchored at PAINT time, not here: plated and bare rows are
            -- different heights in the mockup, so a row's position depends on
            -- what is above it, which is not known until the tree is walked.
            -- See ui.UpdateCatTree.
            row:SetPoint("TOPLEFT", catScroll, "TOPLEFT", 0, 0)
            -- Blizzard's filter list gives every TOP-LEVEL category a plate
            -- of its own and leaves subcategories as bare indented text. The
            -- plate is drawn per row and hidden on child rows by the paint,
            -- so one row pool serves both.
            local plate = row:CreateTexture(nil, "BACKGROUND")
            plate:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -1)
            plate:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -1, 1)
            plate:SetTexture(0.18, 0.15, 0.10, 0.85)
            row.plate = plate
            -- The selected category's blue bar, exactly what the stock list
            -- uses to say "this is the one you are browsing".
            -- The mockup marks the browsed category with a LIGHTER plate and
            -- a gold border, not with a coloured highlight bar. The old
            -- blue/green gradient appears nowhere in the reference.
            local sel = row:CreateTexture(nil, "ARTWORK")
            sel:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -1)
            sel:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -1, 1)
            sel:SetTexture(0.30, 0.25, 0.15, 1)
            sel:Hide()
            row.selTex = sel

            -- Gold edge on the selected plate, four hairlines rather than a
            -- backdrop: this is a texture-only row and a backdrop here would
            -- draw over the label.
            row.selEdge = {}
            local ei = 1
            while ei <= 4 do
                local ln = row:CreateTexture(nil, "OVERLAY")
                ln:SetTexture(C.border[1], C.border[2], C.border[3], 0.9)
                ln:Hide()
                row.selEdge[ei] = ln
                ei = ei + 1
            end
            row.selEdge[1]:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -1)
            row.selEdge[1]:SetPoint("TOPRIGHT", row, "TOPRIGHT", -1, -1)
            row.selEdge[1]:SetHeight(1)
            row.selEdge[2]:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 1, 1)
            row.selEdge[2]:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -1, 1)
            row.selEdge[2]:SetHeight(1)
            row.selEdge[3]:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -1)
            row.selEdge[3]:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 1, 1)
            row.selEdge[3]:SetWidth(1)
            row.selEdge[4]:SetPoint("TOPRIGHT", row, "TOPRIGHT", -1, -1)
            row.selEdge[4]:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -1, 1)
            row.selEdge[4]:SetWidth(1)
            local lbl = row:CreateFontString(nil, "OVERLAY",
                "GameFontHighlightSmall")
            lbl:SetPoint("LEFT", row, "LEFT", 8, 0)
            -- No width constraint; the paint clips (same wrap-onto-the-next-
            -- row reason as everywhere else in this file).
            lbl:SetJustifyH("LEFT")
            row.label = lbl
            row:SetScript("OnClick", function() ui.OnCatClick(row.entry) end)
            row:Hide()
            ui.buyCatRows[i] = row
            i = i + 1
        end
    end
    ui.GrowCatRows(SIDE_ROWS)

    -- ===== Right: filter row + results ==================================
    -- The well runs to catScroll's right + 24 (it covers the scrollbar), so
    -- the right column has to start beyond that or the well clips the Item
    -- column and the match-count line beneath it.
    -- Results column origin. The sidebar plus one tight gutter -- the
    -- mockup's gap here is about a quarter of what we had.
    local RX = BUYL.side_x + SIDE_W + BUYL.gut_w

    -- ADVANCED-mode content origin. Advanced HIDES the category tree, so its
    -- content starts at the panel's own left margin.
    --
    -- Everything Advanced owns used to anchor at RX, which is the RESULTS
    -- column's origin and sits that far right only because the tree occupies
    -- the space to its left. With the tree hidden, that left the tree's whole
    -- width as dead window -- about 300px of empty panel down the left of the
    -- search strip, the sub-tabs, the builder and the saved lists.
    local AX = BUYL.side_x

    -- ---- DEFAULT-mode control strip (Blizzlike) ------------------------
    -- Field order is the stock auction house's: Name, Level Range, Min
    -- Quality, Usable, Search. Everything here composes into ONE term
    -- alongside whatever the category tree has selected -- see ui.DefaultTerm.
    -- Every field label is placed by ONE rule: sit on my own control's top
    -- edge, left edges flush, the same gap above it.
    --
    -- They were placed by two rules before, and that is the whole of why they
    -- looked crooked. "Name" hung off the PANEL at a fixed y while "Level
    -- Range" and "Min Quality" hung off their CONTROLS -- so the moment a
    -- control's height or the strip's y changed, Name stayed put and the other
    -- two moved, and no amount of nudging one of the numbers could hold all
    -- three in line because there was no single number to nudge. The controls
    -- already share one top edge (strip_ctl_y), so hanging every label off its
    -- own control gives one baseline for free, and strip_lbl_gap is now the
    -- only place the label-to-control air is set.
    local function stripLabel(text, ctl)
        local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("BOTTOMLEFT", ctl, "TOPLEFT", 0, BUYL.strip_lbl_gap)
        fs:SetText(text)
        return fs
    end

    -- The strip is a FIXED-WIDTH cluster on the left, two buttons pinned
    -- right, and the slack left as empty space between them -- the mockup's
    -- arrangement.
    --
    -- Two earlier versions of this both failed, in opposite directions.
    -- Originally everything chained left-to-right off the Name box while
    -- Search and Advanced were pinned a fixed distance from the right edge,
    -- with nothing joining the halves: they overlapped, printing Search
    -- through the "Usable" label. 1.14.1 fixed that by letting Name stretch
    -- to fill the gap -- which made overlap impossible but pushed Level Range
    -- and Min Quality into the middle of the strip, away from Name.
    --
    -- Fixed widths bring the overlap risk back, so it is bounded arithmetically
    -- instead of by an anchor: STRIP_MIN_W below is the cluster's total width,
    -- and MIN_W is large enough to fit it plus the buttons. See the note on
    -- MIN_W -- eight result columns do not fit in the old 832 either.
    local box = ui.FlattenEditBox(
        CreateFrame("EditBox", "AegisExchangeBuySearchBox", panel,
            "InputBoxTemplate"))
    box:SetWidth(BUY_NAME_W); box:SetHeight(BUYL.ctl_h)
    box:SetPoint("TOPLEFT", panel, "TOPLEFT",
        BUYL.side_x, -BUYL.strip_ctl_y)
    box:SetAutoFocus(false)
    box:SetScript("OnEnterPressed", function() ui.DoBuySearch() end)
    box:SetScript("OnEscapePressed", function() box:ClearFocus() end)
    -- THE EXCEPTION to Tab traversal, and a deliberate one: Tab completes item
    -- names here. That binding is older than traversal and worth more on a
    -- search box than stepping to the level fields, so the two search boxes
    -- keep it and nothing else does. See ui.LinkTabOrder.
    box:SetScript("OnTabPressed", function() ui.BuyAutocomplete() end)
    ui.buyBox = box
    ui.buyNameLbl = stripLabel("Name", box)

    -- Left cluster, chained left-to-right off Name at fixed widths.
    ui.buyMinLevel = MakeNumBox(panel, BUY_LVL_W, nil, BUYL.ctl_h)
    ui.buyMinLevel:SetPoint("LEFT", box, "RIGHT", 14, 0)
    local lvlDash = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lvlDash:SetPoint("LEFT", ui.buyMinLevel, "RIGHT", 7, 0)
    lvlDash:SetText("-")
    ui.buyLvlDash = lvlDash
    ui.buyMaxLevel = MakeNumBox(panel, BUY_LVL_W, nil, BUYL.ctl_h)
    ui.buyMaxLevel:SetPoint("LEFT", lvlDash, "RIGHT", 7, 0)

    -- The two level boxes tab between themselves. Name is NOT in the list --
    -- it is one of the two autocomplete boxes.
    ui.LinkTabOrder({ ui.buyMinLevel, ui.buyMaxLevel })

    ui.buyLvlLbl = stripLabel("Level Range", ui.buyMinLevel)

    ui.buyQuality = MakeDropdown(panel, BUY_QUAL_W, function() end)
    ui.buyQuality.button:SetPoint("LEFT", ui.buyMaxLevel, "RIGHT", 16, 0)
    ui.buyQualLbl = stripLabel("Min Quality", ui.buyQuality.button)

    ui.buyUsable = ui.MakeCheckBox(panel, 16)
    ui.buyUsable:SetPoint("LEFT", ui.buyQuality.button, "RIGHT", 10, 0)
    local usableLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    usableLbl:SetPoint("LEFT", ui.buyUsable, "RIGHT", 2, 0)
    usableLbl:SetText("Usable items")
    usableLbl:SetTextColor(C.text[1], C.text[2], C.text[3])
    ui.buyUsableLbl = usableLbl

    -- Right pair. Advanced is the outermost, so it lands where the stock UI
    -- put "Display on Character".
    local advBtn = ui.MakeButton(panel, "accent",
        "AegisExchangeBuyAdvancedButton")
    advBtn:SetWidth(BUY_ADV_W); advBtn:SetHeight(20)
    advBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -22)
    advBtn:SetText("Advanced >")
    advBtn:SetScript("OnClick", function() ui.SetBuyMode("advanced") end)
    ui.buyAdvBtn = advBtn

    local searchBtn = ui.MakeButton(panel, "primary",
        "AegisExchangeBuySearchButton")
    searchBtn:SetWidth(BUY_SEARCH_W); searchBtn:SetHeight(20)
    -- Placed by ui.AnchorSearchButton, because WHERE it belongs depends on the
    -- mode. It used to hang off the Advanced button in both -- but Advanced is
    -- a DEFAULT-mode widget, hidden in Advanced and still carrying a position,
    -- so in Advanced the Search button inherited a slot 10px below the strip's
    -- own baseline and 88+14px in from the edge that nothing else knew about.
    searchBtn:SetText("Search")
    searchBtn:SetScript("OnClick", function() ui.DoBuySearch() end)
    ui.buySearchBtn = searchBtn

    -- The mockup rules off the control strip from the columns below it, in a
    -- matching pair with the one above the action bar. We only had the lower
    -- one, so the strip ran into the BROWSE heading and the table with
    -- nothing between them.
    local stripRule = panel:CreateTexture(nil, "ARTWORK")
    stripRule:SetPoint("TOPLEFT", panel, "TOPLEFT", 10,
        -(BUYL.strip_ctl_y + BUYL.ctl_h + 8))
    stripRule:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12,
        -(BUYL.strip_ctl_y + BUYL.ctl_h + 8))
    stripRule:SetHeight(1)
    stripRule:SetTexture(0.35, 0.30, 0.18, 0.6)
    ui.buyStripRule = stripRule

    -- ---- ADVANCED-mode strip -------------------------------------------
    -- Accent, not quiet: this is the counterpart of the Advanced button that
    -- got you here, and the concept draws the pair in the same purple.
    local backBtn = ui.MakeButton(panel, "accent", "AegisExchangeBuyBackButton")
    backBtn:SetWidth(72); backBtn:SetHeight(20)
    backBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", AX, -ADVL.strip_y)
    backBtn:SetText("\226\151\128 Back")
    backBtn:SetScript("OnClick", function() ui.SetBuyMode("default") end)
    ui.buyBackBtn = backBtn

    ui.buyQueryBox = CreateFrame("EditBox", "AegisExchangeBuyQueryBox", panel,
        "InputBoxTemplate")
    ui.buyQueryBox:SetHeight(20)
    -- Its right edge hangs off the SEARCH BUTTON, not off a constant measured
    -- to clear it. The constant was 172 where the button's left edge is at
    -- 196, so the box drew across the button -- and the two numbers had no way
    -- to know about each other. Anchoring to the widget cannot drift.
    ui.buyQueryBox:SetPoint("TOPLEFT", backBtn, "TOPRIGHT", 12, -1)
    ui.buyQueryBox:SetPoint("RIGHT", searchBtn, "LEFT", -ADVL.strip_gap, 0)
    ui.buyQueryBox:SetAutoFocus(false)
    ui.buyQueryBox:SetScript("OnEnterPressed", function() ui.DoBuySearch() end)
    ui.buyQueryBox:SetScript("OnEscapePressed", function()
        ui.buyQueryBox:ClearFocus()
    end)
    -- The OTHER autocomplete box, and the other half of the traversal
    -- exception. See ui.LinkTabOrder.
    ui.buyQueryBox:SetScript("OnTabPressed", function() ui.BuyAutocomplete() end)


    -- View switcher: a row of three, INSIDE the frame and under the query
    -- box. It used to be anchored 232px right of the Search button -- which
    -- was fine while Search lived on the left, and threw all three clean off
    -- the window the moment Phase 2 moved Search to the right edge. Anchored
    -- to the panel now, so it cannot follow another widget off screen.
    --
    -- The three SPAN the content width, as the concept has them: they are a
    -- tab strip, not three buttons that happen to sit together, and three
    -- 112px buttons on a 1400px panel read as the latter. Widths are computed
    -- in ui.LayoutViewTabs from the panel's real width so they refill on every
    -- resize; nothing here is a fixed pixel count.
    ui.buyViewBtns = {}
    local views = { { "Search Results", "results" },
                    { "Saved Searches", "saved" },
                    { "Filter Builder", "builder" } }
    local prevView = nil
    local vi = 1
    while vi <= table.getn(views) do
        local v = views[vi]
        local b = ui.MakeButton(panel, "quiet",
            "AegisExchangeBuyView" .. v[2])
        b:SetHeight(20)
        if prevView then
            b:SetPoint("LEFT", prevView, "RIGHT", ADVL.tab_gap, 0)
        else
            b:SetPoint("TOPLEFT", panel, "TOPLEFT", AX, -ADVL.tabs_y)
        end
        b:SetText(v[1])
        b.view = v[2]
        b:SetScript("OnClick", function() ui.SetBuyView(b.view) end)
        ui.buyViewBtns[vi] = b
        prevView = b
        vi = vi + 1
    end
    ui.LayoutViewTabs()

    -- Pager, bottom-right of the results area. It used to sit at the panel's
    -- TOP right -- the same spot the Advanced button now occupies, which is
    -- where the stray "< >" over that button came from.
    local nextBtn = ui.MakeButton(panel, "quiet", "AegisExchangeBuyNextButton")
    nextBtn:SetWidth(24); nextBtn:SetHeight(20)
    -- Anchored properly below, once the table's box exists. The count and
    -- pager follow the TABLE's bottom edge in the mockup, sitting directly
    -- under the box rather than pinned to the panel with a gap between.
    nextBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -BUYL.gutter_w, -200)
    nextBtn:SetText("\226\150\182")
    nextBtn:SetScript("OnClick", function() if A.buy then A.buy.NextPage() end end)

    ui.buyPageText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.buyPageText:SetPoint("RIGHT", nextBtn, "LEFT", -6, 0)
    ui.buyPageText:SetJustifyH("RIGHT")
    ui.buyPageText:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])

    local prevBtn = ui.MakeButton(panel, "quiet", "AegisExchangeBuyPrevButton")
    prevBtn:SetWidth(24); prevBtn:SetHeight(20)
    prevBtn:SetPoint("RIGHT", ui.buyPageText, "LEFT", -6, 0)
    prevBtn:SetText("\226\151\128")
    prevBtn:SetScript("OnClick", function() if A.buy then A.buy.PrevPage() end end)
    -- Kept on ui so SetBuyView can hide the pager with the rest of the
    -- results view -- paging results you cannot see still queries the server.
    ui.buyPrevBtn = prevBtn
    ui.buyNextBtn = nextBtn

    -- Result count / sort, bottom-LEFT of the results area, opposite the
    -- pager. It hung off the Search button before, which dragged it to the
    -- top right when Search moved.
    ui.buyStatus = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    -- Same baseline as the pager opposite it. They sat 4px apart, which is
    -- the kind of gap that reads as a mistake rather than as a choice.
    ui.buyStatus:SetPoint("TOPLEFT", panel, "TOPLEFT", RX + 6, -200)
    ui.buyStatus:SetJustifyH("LEFT")
    -- Muted, as the mockup has it. Gold made the least important line on
    -- screen the loudest thing in the results column.
    -- Plain grey. This is the least important line in the column and was
    -- one of the warmest things on the tab.
    ui.buyStatus:SetTextColor(0.62, 0.60, 0.55)
    ui.buyStatus:SetText("Type an item name and Search.")

    -- Column layout (row-relative x, width). Sized so Buy+Bid finish well
    -- before the scrollbar. The unit / stack / % headers are clickable to sort.
    ui.buySortKey = "unit"
    ui.buySortDir = "asc"
    local rowLeft = RX + 4
    -- Both origins the table can have. Blizzlike starts right of the category
    -- tree; Advanced hides the tree and starts at the panel margin, which
    -- makes the same table ~200px wider. ui.LayoutBuyTable switches between
    -- them; keeping both here means neither is re-derived at a call site.
    ui.buyTableLeft    = rowLeft
    ui.buyTableLeftAdv = AX + 4

    -- EVERY column sorts. Headers are bare clickable text (aegisNoSkin),
    -- never skinned into boxes -- pfUI's SkinButton would give each one a
    -- backdrop and they'd visibly overlap.
    ui.buyHeaders = ui.MakeSortHeaders(panel, rowLeft, -BUYL.hdr_top,
        RCX_BUY, RCW_BUY,
        function(key) ui.SetBuySort(key) end,
        {
            { key = "name",   text = "Item" },
            { key = "lvl",    text = "Lvl",         just = "RIGHT" },
            { key = "left",   text = "Time Left" },
            { key = "bid",    text = "Current Bid", just = "RIGHT" },
            { key = "stack",  text = "Buyout",      just = "RIGHT" },
            { key = "unit",   text = "Unit",        just = "RIGHT" },
            { key = "pct",    text = "% Mkt",       just = "RIGHT" },
        })

    local scroll = CreateFrame("ScrollFrame", "AegisExchangeBuyScroll",
        panel, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", rowLeft, -BUYL.rows_top)
    -- Headroom for the status/pager row AND the action bar beneath it.
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT",
        -BUYL.gutter_w, BUYL.table_bot)

    -- ONE box around the headers AND the rows, which is what the mockup
    -- shows. The well used to wrap the scroll frame alone, so the column
    -- headings floated on the panel above the box and the rule that should
    -- have sat under them landed on the box's top edge instead.
    --
    -- Anchored explicitly rather than via ui.MakeWell(scroll): the well has
    -- to reach UP past the scroll frame to enclose the header row, and its
    -- right edge has to stop AT the scroll frame's, so that the scrollbar --
    -- which FauxScrollFrameTemplate anchors outward from that edge -- ends up
    -- outside the box rather than drawn across the last column.
    local well = CreateFrame("Frame", nil, panel)
    well:SetPoint("TOPLEFT", panel, "TOPLEFT", rowLeft - 6, -BUYL.well_top)
    -- Right edge flush with the scroll frame's, NOT past it: the scrollbar
    -- hangs outward from exactly that line, so any positive offset here puts
    -- the box under the scrollbar again.
    well:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 0, -6)
    well:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    well:SetBackdropColor(0.05, 0.04, 0.03, 0.85)
    well:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3])
    ui.buyListWell = well

    -- NOW the count and the pager can hang off the table, which is what the
    -- mockup does. They are also CENTRED on each other rather than sharing a
    -- bottom offset: the pager is a 20px button and the count is a ~12px
    -- font string, so an equal offset left their text baselines ~9px apart.
    nextBtn:ClearAllPoints()
    nextBtn:SetPoint("TOPRIGHT", well, "BOTTOMRIGHT", 0, -8)
    ui.buyStatus:ClearAllPoints()
    ui.buyStatus:SetPoint("LEFT", well, "BOTTOMLEFT", 6, 0)
    ui.buyStatus:SetPoint("TOP", nextBtn, "TOP", 0, 0)
    ui.buyStatus:SetPoint("BOTTOM", nextBtn, "BOTTOM", 0, 0)

    -- ui.LayoutBuyTable is defined at FILE scope, not here, and reads the
    -- panel back off ui.buyPanel. Nesting it cost ui.BuildBuyTab two more
    -- upvalues (BUY_NAME_EXTRA and ColX) against a hard limit of 32 that this
    -- function has already broken once -- see the note above BUYL.
    ui.buyPanel = panel

    -- The rule goes UNDER the headings, not at the top of the box.
    local hdrRule = panel:CreateTexture(nil, "ARTWORK")
    hdrRule:SetPoint("TOPLEFT", well, "TOPLEFT", 6, -(BUYL.hdr_h))
    hdrRule:SetPoint("TOPRIGHT", well, "TOPRIGHT", -6, -(BUYL.hdr_h))
    hdrRule:SetHeight(1)
    hdrRule:SetTexture(0.45, 0.38, 0.22, 0.85)
    ui.buyHdrRule = hdrRule

    -- Thin separators between the header cells, as the mockup has.
    ui.buyHdrTicks = {}
    local tickKeys = { "lvl", "left", "bid", "stack", "unit", "pct" }
    local ti = 1
    while ti <= table.getn(tickKeys) do
        local tk = panel:CreateTexture(nil, "ARTWORK")
        tk:SetWidth(1)
        tk:SetPoint("TOPLEFT", well, "TOPLEFT",
            6 + RCX_BUY[tickKeys[ti]] - 8, -6)
        tk:SetPoint("BOTTOMLEFT", well, "TOPLEFT",
            6 + RCX_BUY[tickKeys[ti]] - 8, -(BUYL.hdr_h))
        tk:SetTexture(0.35, 0.30, 0.18, 0.7)
        ui.buyHdrTicks[ti] = tk
        ti = ti + 1
    end

    scroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(BUY_ROW_H, ui.UpdateBuyList)
    end)
    ui.buyScroll = scroll

    ui.buyRows = {}
ui.GrowBuyRows = function(n)
        if n > BUY_ROWS_MAX then n = BUY_ROWS_MAX end
        -- Built on demand: a minimum-size window costs exactly what it
        -- did before, and dragging taller adds only the rows needed.
        local i = table.getn(ui.buyRows) + 1
        while i <= n do
            BuildResultRow(panel, scroll, ui.buyRows, i, BUY_ROW_H, true)
            i = i + 1
        end
    end
    ui.GrowBuyRows(BUY_ROWS)

    -- ===== Bottom action bar (both modes) ===============================
    -- Blizzard's shape: your money on the left, a bid entry, then
    -- Bid / Buyout / Close. All three act on the SELECTED row.
    local closeBtn = ui.MakeButton(panel, "quiet",
        "AegisExchangeBuyCloseButton")
    closeBtn:SetWidth(64); closeBtn:SetHeight(21)
    closeBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -12, 8)
    closeBtn:SetText("Close")
    closeBtn:SetScript("OnClick", function() ui.CloseWindow() end)
    ui.buyCloseBtn = closeBtn

    local buyoutBtn = ui.MakeButton(panel, "primary",
        "AegisExchangeBuyBuyoutButton")
    buyoutBtn:SetWidth(70); buyoutBtn:SetHeight(21)
    buyoutBtn:SetPoint("RIGHT", closeBtn, "LEFT", -5, 0)
    buyoutBtn:SetText("Buyout")
    buyoutBtn:SetScript("OnClick", function()
        -- Ticked rows win over the single selection. You cannot have both
        -- meanings on one button, and having ticked something is the more
        -- deliberate act.
        if table.getn(ui.buyChecked or {}) > 0 then
            ui.ConfirmBatchBuyout()
        elseif ui.buySel then
            ui.ConfirmBuyout(ui.buySel)
        end
    end)
    ui.buyBuyoutBtn = buyoutBtn

    -- The mockup rules off the action bar from the table above it. Full
    -- panel width, so it reads as the window's own division rather than as
    -- part of the results column.
    local barRule = panel:CreateTexture(nil, "ARTWORK")
    barRule:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 38)
    barRule:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -12, 38)
    barRule:SetHeight(1)
    barRule:SetTexture(0.35, 0.30, 0.18, 0.6)
    ui.buyBarRule = barRule

    -- What the ticked rows come to, beside the action bar. Doubles as the
    -- progress line while a batch runs.
    ui.buyCheckTotal = panel:CreateFontString(nil, "OVERLAY",
        "GameFontHighlightSmall")
    -- Beside the gold, on the action bar's own baseline. It used to sit at
    -- bottom+26 which is inside the button band (8..29), so it crowded Bid /
    -- Buyout / Close and the rule above them at once.
    ui.buyCheckTotal:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT",
        BUYL.side_x + 190, 13)
    ui.buyCheckTotal:SetJustifyH("LEFT")
    ui.buyCheckTotal:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    ui.buyCheckTotal:Hide()

    local bidBtn = ui.MakeButton(panel, "quiet", "AegisExchangeBuyBidButton")
    bidBtn:SetWidth(58); bidBtn:SetHeight(21)
    bidBtn:SetPoint("RIGHT", buyoutBtn, "LEFT", -5, 0)
    bidBtn:SetText("Bid")
    bidBtn:SetScript("OnClick", function()
        if ui.buySel then ui.ConfirmBid(ui.buySel) end
    end)
    ui.buyBidBtn = bidBtn

    -- The same g/s/c triplet the Sell tab uses, coin art and all, rather than
    -- one plain box: a price should read the same everywhere in the window.
    -- MakeMoneyGSC emulates GetText/SetText/ClearFocus, so SetMoneyBox and
    -- every existing caller keep working against it untouched.
    local bidEntryLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    bidEntryLbl:SetPoint("RIGHT", bidBtn, "LEFT", -(PRICE_GSC_W + 4), 0)
    bidEntryLbl:SetText("Bid")
    ui.buyBidEntryLbl = bidEntryLbl
    ui.buyBidBox = MakeMoneyGSC(panel, nil)
    ui.buyBidBox:Attach(bidEntryLbl, 6, 0)
    ui.LinkTabOrder({ ui.buyBidBox.g, ui.buyBidBox.s, ui.buyBidBox.c })

    -- Your money, with the game's own coin art rather than "6g 75s 43c"
    -- text. Anchored by its COPPER coin, so the figure grows leftwards and a
    -- total that gains a digit does not shove the bar about.
    ui.buyMoney = MakeMoneyDisplay(panel)
    -- LEFT-aligned on the panel margin, sharing the spine that the Name
    -- field, BROWSE and the category plates all sit on.
    ui.buyMoney:Anchor("BOTTOMLEFT", panel, "BOTTOMLEFT", BUYL.side_x, 13)

    -- AX, not rowLeft: both of these belong to ADVANCED, where the category
    -- tree is hidden, so they start at the panel margin. Handing them the
    -- results column's origin is what left the tree's width as dead window.
    ui.BuildFilterBuilder(panel, AX)
    ui.BuildSavedSearches(panel, AX)
    ui.SetBuyView("results")

    -- Mode: default (Blizzlike) unless this character last used Advanced.
    local saved = A.db and A.db.char and A.db.char.ui
        and A.db.char.ui.buyMode
    ui.SetBuyMode(saved == "advanced" and "advanced" or "default")
end

-- ---------------------------------------------------------------------------
-- Filter Builder (ROADMAP 2b)
--
-- Form-driven query construction: pick from dropdowns, get a valid query
-- string. It occupies the same area as the results table and the two swap via
-- ui.SetBuyView -- the ROADMAP calls for a row of switchable views (Results /
-- Saved Searches / Filter Builder) reusing this space rather than adding a
-- fourth top-level sub-tab. Saved Searches is 2c; the switcher is built to
-- take a third entry without rework.
--
-- Every dropdown is populated from buy.Categories() / buy.SlotOptions(), which
-- read the auction house's OWN localized names -- there is no second copy of
-- the category list here to drift out of sync.
-- ---------------------------------------------------------------------------

function ui.SetBuyView(name)
    ui.buyView = name
    local builder = (name == "builder")
    local saved   = (name == "saved")
    -- Anything that is not the results table takes the same space, so both
    -- overlay panels hide the results furniture below.
    local overlay = builder or saved
    if ui.buyBuilder then
        if builder then ui.buyBuilder:Show() else ui.buyBuilder:Hide() end
    end
    if ui.buySaved then
        if saved then ui.buySaved:Show() else ui.buySaved:Hide() end
    end
    -- The action row lives on the window's action bar, so it is raised and
    -- lowered here rather than with the builder frame.
    --
    -- It belongs to BOTH overlay views, not just the Builder. Search, Import
    -- and Clear all mean something on Saved Searches, and the concept shows
    -- the full row there; hiding everything but Close left that view looking
    -- like it had no actions at all.
    local ai = 1
    while ai <= table.getn(ui.fbActionBtns or {}) do
        if overlay then ui.fbActionBtns[ai]:Show()
        else ui.fbActionBtns[ai]:Hide() end
        ai = ai + 1
    end
    -- Build composes the FORM into a query, so it has nothing to act on
    -- anywhere but the Builder. Disabled rather than hidden: a button that
    -- vanishes between tabs makes the row jump, and the concept greys it.
    if ui.fbBuildBtn then
        if builder then ui.fbBuildBtn:Enable() else ui.fbBuildBtn:Disable() end
    end
    -- The Builder's status line lives on the action bar now, so it has to be
    -- put away with the view rather than with the form's frame.
    if not builder and ui.BuilderNote then ui.BuilderNote("") end
    -- Bid / Buyout and the bid entry act on a SELECTED AUCTION, and neither
    -- Builder nor Saved has one. Showing them there offers an action that
    -- cannot do anything. Close and the gold total stay everywhere.
    local bidBits = { ui.buyBidBtn, ui.buyBuyoutBtn, ui.buyBidEntryLbl }
    local bi = 1
    while bi <= table.getn(bidBits) do
        local w = bidBits[bi]
        if w then if overlay then w:Hide() else w:Show() end end
        bi = bi + 1
    end
    if ui.buyBidBox then
        if overlay then ui.buyBidBox:Hide() else ui.buyBidBox:Show() end
    end
    -- Mark which view you are actually in. All three buttons drew identically
    -- whatever was on screen, so Results / Saved / Builder read as three
    -- unrelated actions rather than as the tab strip they are. The active one
    -- takes the primary plate -- the same thing the sub-tabs above do with
    -- their gold label.
    local vi2 = 1
    while vi2 <= table.getn(ui.buyViewBtns or {}) do
        local b = ui.buyViewBtns[vi2]
        if b then
            ui.SetButtonKind(b, (b.view == name) and "primary" or "quiet")
        end
        vi2 = vi2 + 1
    end
    if saved then ui.RefreshSavedSearches() end
    -- Everything belonging to the results view hides together. buyStatus is
    -- in the list because it paints at the same height as the form's first
    -- header -- "7 match(es) ..." showing through "AUCTION HOUSE FILTER" was
    -- a reported bug. The pager goes with it: its buttons still worked while
    -- invisible results were underneath, so a stray click queried the server.
    -- buyCheckTotal is here because it is the results table's "N selected"
    -- line and belongs to no other view.
    local resultsBits = { ui.buyScroll, ui.buyPageText, ui.buyStatus,
                          ui.buyPrevBtn, ui.buyNextBtn,
                          ui.buyListWell, ui.buyHdrRule, ui.buyCheckTotal }
    local i = 1
    while i <= table.getn(resultsBits) do
        local w = resultsBits[i]
        if w then if overlay then w:Hide() else w:Show() end end
        i = i + 1
    end
    if ui.buyHeaders then
        for _, h in pairs(ui.buyHeaders) do
            if overlay then h:Hide() else h:Show() end
        end
    end
    -- The header column separators. An ARRAY of textures rather than a single
    -- widget, which is exactly how they escaped every list and stayed drawn
    -- across the top of the Saved and Builder views as a row of stray ticks.
    local ti = 1
    while ti <= table.getn(ui.buyHdrTicks or {}) do
        if overlay then ui.buyHdrTicks[ti]:Hide()
        else ui.buyHdrTicks[ti]:Show() end
        ti = ti + 1
    end
    local ri = 1
    while ri <= table.getn(ui.buyRows or {}) do
        if overlay then ui.buyRows[ri]:Hide() end
        ri = ri + 1
    end
    -- (The active view is marked further up, by swapping its button to the
    -- primary plate. LockHighlight used to do this job and no longer can --
    -- it drives a template highlight texture these buttons do not have, so it
    -- was silently doing nothing.)
    if not overlay then ui.UpdateBuyList() end
end

-- ---------------------------------------------------------------------------
-- Saved Searches (ROADMAP 2j): Recent | Favorites
--
-- Two columns sharing the results area. Recent is fed by every search you
-- run; Favorites is what you promoted out of it and ordered yourself.
--
-- Mouse language, matching the spec:
--   left-click        run it
--   shift-left-click  load it into the Filter Builder instead of running
--   right-click       on a recent  -> promote straight to Favorites
--                     on a favorite-> Move Up / Move Down / Delete menu
-- ---------------------------------------------------------------------------

-- SAVED_ROWS is the POOL CEILING, not the count. The visible number comes from
-- ui.SavedRowsAt, computed from the WINDOW's height -- not from measuring the
-- column, which is what left both lists stopping short of the bottom of their
-- own well whatever size the window was. Rows beyond the visible count are
-- reachable by the wheel; see ui.ScrollSaved.
local SAVED_ROWS, SAVED_ROW_H = 30, 21
local SAVED_HEAD_H = 32       -- heading band INSIDE the well
local SAVED_PAD = 8           -- well inset: heading, rows and rules share it
-- A real star, not an ASCII asterisk. "*" reads as a footnote marker; the
-- concept's favourites are marked with a gold star and so are ours.
local SAVED_STAR = "\226\152\133"

-- `advLeft` is the ADVANCED content origin (the panel margin), not the
-- results column's -- Advanced hides the category tree, so there is nothing to
-- its left to make room for.
function ui.BuildSavedSearches(panel, advLeft)
    if ui.buySaved then return end

    local f = CreateFrame("Frame", "AegisExchangeSavedSearches", panel)
    f:SetPoint("TOPLEFT", panel, "TOPLEFT", advLeft, -ADVL.body_y)
    f:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT",
        -ADVL.right_pad, ADVL.body_bot)
    f:Hide()
    ui.buySaved = f

    -- Two columns that SPLIT the frame rather than sitting at fixed offsets:
    -- left half and right half, each stretching with the window. The old
    -- fixed 0 / 262 left a dead gap on a wide window and overlapped on a
    -- narrow one.
    -- Placed by ui.SplitAdvColumns, the SAME function the Filter Builder uses.
    -- These two views share the space and must not move relative to each
    -- other; two copies of the split is how they came to differ by 2px on each
    -- column and 4px on the gutter.
    local colL = CreateFrame("Frame", nil, f)
    local colR = CreateFrame("Frame", nil, f)
    ui.savedColL, ui.savedColR = colL, colR
    ui.SplitAdvColumns(f, colL, colR)

    -- Each column's rows live in a WELL that runs to the bottom of the view.
    -- Without one the rows just stopped wherever the content ran out and the
    -- remaining two-thirds of the panel was bare window -- the reported gap.
    -- A well makes the same emptiness read as an empty list, which is what the
    -- concept does with every content area.
    -- The heading and its hint sit INSIDE the well, on ONE line -- the concept
    -- puts them there, and stacking them above the box cost two rows of height
    -- and read as a caption floating over an unlabelled list.
    --
    -- So the well is drawn around the WHOLE column and the heading is placed
    -- inside its top inset, rather than the well starting below the heading.
    local function column(parentCol, title, hint, which)
        ui.MakeWell(parentCol, parentCol, 0)

        local h = parentCol:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOPLEFT", parentCol, "TOPLEFT", SAVED_PAD, -SAVED_PAD)
        h:SetText(title)
        h:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
        -- On the SAME baseline as the heading, immediately to its right.
        local sub = parentCol:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        sub:SetPoint("LEFT", h, "RIGHT", 8, 0)
        sub:SetText(hint)

        local area = CreateFrame("Frame", nil, parentCol)
        area:SetPoint("TOPLEFT", parentCol, "TOPLEFT", SAVED_PAD, -SAVED_HEAD_H)
        area:SetPoint("BOTTOMRIGHT", parentCol, "BOTTOMRIGHT",
            -SAVED_PAD, SAVED_PAD)
        -- Wheel scrolling, on the AREA -- and again on each row below, which
        -- is a Button and would otherwise swallow the event wherever the
        -- pointer actually is, i.e. over the list you are trying to scroll.
        area.which = which
        area:EnableMouseWheel(true)
        area:SetScript("OnMouseWheel", function()
            ui.ScrollSaved(area.which, arg1)
        end)
        return area
    end
    -- "right-click -> * favorite" / "right-click -> menu", the concept's
    -- wording: it names the RESULT of the click, not a verb for it.
    ui.savedAreaL = column(colL, "RECENT",
        "right-click \226\134\146 " .. SAVED_STAR .. " favorite", "recent")
    ui.savedAreaR = column(colR, "FAVORITES",
        "right-click \226\134\146 menu", "fav")

    -- One row builder for both columns; `which` tags the row so the click
    -- handlers know which list they are looking at.
    local function makeRows(store, col, which)
        local i = 1
        while i <= SAVED_ROWS do
            local r = CreateFrame("Button", nil, col)
            r:SetHeight(SAVED_ROW_H)
            -- A LIST ROW that happens to be a Button because a row has to be
            -- clickable -- exactly the case ui/skin.lua's aegisNoSkin branch
            -- exists for. Without this pfUI's SkinButton gives every row a
            -- plate, and the concept's clean text list became a stack of
            -- buttons under the skin while looking correct unskinned.
            r.aegisNoSkin = true
            -- Both edges anchored, so a row fills its column at any width.
            r:SetPoint("TOPLEFT", col, "TOPLEFT", SAVED_PAD,
                -SAVED_HEAD_H - (i - 1) * SAVED_ROW_H)
            r:SetPoint("TOPRIGHT", col, "TOPRIGHT", -SAVED_PAD,
                -SAVED_HEAD_H - (i - 1) * SAVED_ROW_H)
            r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            -- A row covers the area beneath it, so the wheel has to be
            -- forwarded from here as well or scrolling only works in the
            -- empty band under the last entry -- which is exactly where the
            -- pointer is not.
            r:EnableMouseWheel(true)
            r:SetScript("OnMouseWheel", function()
                ui.ScrollSaved(which, arg1)
            end)

            -- Hover / selection band, full row width. Drawn in BACKGROUND so
            -- the separator and the label both sit over it.
            local sel = r:CreateTexture(nil, "BACKGROUND")
            sel:SetAllPoints(r)
            sel:SetTexture(1, 1, 1, 0.055)
            sel:Hide()
            r.selTex = sel

            -- Separator under the row. Recent gets one per row, as the concept
            -- draws it; favourites are a shorter, starred list and the concept
            -- leaves them unruled.
            if which == "recent" then
                local rule = r:CreateTexture(nil, "ARTWORK")
                rule:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0)
                rule:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", 0, 0)
                rule:SetHeight(1)
                rule:SetTexture(0.32, 0.27, 0.16, 0.55)
                r.rule = rule
            end

            -- Favourites carry a gold star in its own FontString, so the star
            -- stays gold while the label takes the row's own colour.
            local x = 2
            if which == "fav" then
                local st = r:CreateFontString(nil, "OVERLAY",
                    "GameFontNormalSmall")
                st:SetPoint("LEFT", r, "LEFT", 2, 0)
                st:SetText(SAVED_STAR)
                st:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
                r.star = st
                x = 16
            end

            local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", r, "LEFT", x, 0)
            fs:SetJustifyH("LEFT")
            r.label = fs
            r.which = which
            r.idx = i
            r:SetScript("OnClick", function()
                ui.OnSavedClick(r, arg1)
            end)
            r:SetScript("OnEnter", function()
                r.selTex:Show()
                if r.full then
                    GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
                    GameTooltip:SetText(r.full, 1, 1, 1, 1, 1)
                    GameTooltip:Show()
                end
            end)
            r:SetScript("OnLeave", function()
                -- Stays lit while its own context menu is open: the menu is a
                -- separate frame, so the pointer leaving the row would
                -- otherwise unlight the row the menu is acting on.
                if ui.savedMenuRow ~= r then r.selTex:Hide() end
                GameTooltip:Hide()
            end)
            r:Hide()
            store[i] = r
            i = i + 1
        end
    end
    ui.savedRecentRows = {}
    ui.savedFavRows = {}
    makeRows(ui.savedRecentRows, colL, "recent")
    makeRows(ui.savedFavRows, colR, "fav")

    -- The favorite context menu. One frame, repositioned onto whichever row
    -- was right-clicked -- three buttons is not worth a pool.
    local menu = CreateFrame("Frame", "AegisExchangeSavedMenu", ui.frame)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetWidth(104); menu:SetHeight(58)
    menu:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    menu:SetBackdropColor(C.well[1], C.well[2], C.well[3], 1)
    menu:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3])
    menu:EnableMouse(true)
    menu:Hide()
    ui.savedMenu = menu

    -- Each item is glyph + label in TWO FontStrings, so the glyph can carry
    -- its own colour -- the concept's Delete has a red x AND red text, and one
    -- string cannot be two colours without |c markup in every caller.
    local function menuItem(glyph, text, order, fn)
        local b = CreateFrame("Button", nil, menu)
        b:SetHeight(18)
        b:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, -5 - (order - 1) * 18)
        b:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -4, -5 - (order - 1) * 18)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        b.aegisNoSkin = true
        local g = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        g:SetPoint("LEFT", b, "LEFT", 4, 0)
        g:SetText(glyph)
        g:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
        b.glyph = g
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", g, "RIGHT", 6, 0)
        fs:SetText(text)
        b.label = fs
        b:SetScript("OnClick", function() fn(); ui.HideSavedMenu() end)
        return b
    end
    menuItem("\226\150\178", "Move Up", 1, function()
        if ui.savedMenuIndex then
            A.buy.MoveFavorite(ui.savedMenuIndex, -1)
            ui.RefreshSavedSearches()
        end
    end)
    menuItem("\226\150\188", "Move Down", 2, function()
        if ui.savedMenuIndex then
            A.buy.MoveFavorite(ui.savedMenuIndex, 1)
            ui.RefreshSavedSearches()
        end
    end)
    local del = menuItem("\195\151", "Delete", 3, function()
        if ui.savedMenuIndex then
            A.buy.RemoveFavorite(ui.savedMenuIndex)
            ui.RefreshSavedSearches()
        end
    end)
    del.label:SetTextColor(0.90, 0.39, 0.39)
    del.glyph:SetTextColor(0.90, 0.39, 0.39)
end

function ui.HideSavedMenu()
    if ui.savedMenu then ui.savedMenu:Hide() end
    ui.savedMenuIndex = nil
    -- Put the row's highlight down with the menu. OnLeave deliberately leaves
    -- it lit while the menu is open, so something has to take it back.
    if ui.savedMenuRow then
        if ui.savedMenuRow.selTex then ui.savedMenuRow.selTex:Hide() end
        ui.savedMenuRow = nil
    end
end

-- Left-click runs, shift-left-click loads into the builder, right-click
-- either promotes (recent) or opens the reorder menu (favorite).
function ui.OnSavedClick(row, button)
    if not row.full then return end
    if button == "RightButton" then
        if row.which == "recent" then
            if A.buy.AddFavorite(row.full) then
                ui.RefreshSavedSearches()
            end
        else
            ui.savedMenuIndex = row.listIndex
            -- Keep this row lit while its menu is up, so the menu visibly
            -- belongs to it -- see the row's OnLeave.
            if ui.savedMenuRow and ui.savedMenuRow.selTex then
                ui.savedMenuRow.selTex:Hide()
            end
            ui.savedMenuRow = row
            if row.selTex then row.selTex:Show() end
            ui.savedMenu:ClearAllPoints()
            -- Drops BELOW the row and stays inside the favourites column.
            -- Opening to the left cleared the row it acts on but landed on
            -- the Recent column instead; below-right clears both.
            --
            -- Inset from the row's right edge by the well's own padding, so
            -- the menu sits clear of the border rather than straddling it.
            ui.savedMenu:SetPoint("TOPRIGHT", row, "BOTTOMRIGHT",
                -SAVED_PAD, -2)
            ui.savedMenu:Show()
        end
        return
    end
    ui.HideSavedMenu()
    if IsShiftKeyDown and IsShiftKeyDown() then
        -- Load it for editing rather than running it: the whole point of a
        -- saved search you want to tweak.
        ui.BuilderSetTerm(A.buy.ParseQuery(row.full)[1])
        ui.SetBuyView("builder")
        return
    end
    if ui.buyQueryBox then ui.buyQueryBox:SetText(row.full) end
    ui.SetBuyView("results")
    ui.DoBuySearch()
end

-- How many rows a Saved Searches column shows at a given WINDOW height.
--
-- Derived, never measured -- see ui.PanelHeightAt for why. The column runs
-- from ADVL.body_y to ADVL.body_bot, less the heading band that sits inside
-- the well above the first row.
function ui.SavedRowsAt(h)
    local col = ui.PanelHeightAt(h) - ADVL.body_y - ADVL.body_bot
    local n = math.floor((col - SAVED_HEAD_H - SAVED_PAD) / SAVED_ROW_H)
    if n < 1 then n = 1 end
    if n > SAVED_ROWS then n = SAVED_ROWS end
    return n
end

-- NOTE ON PLACEMENT: below the SAVED_* constants because it reads
-- them. tests/lint/scoping.py caught this one before it shipped --
-- written 900 lines higher, every one of those names resolved to a
-- nil GLOBAL, which compiles cleanly and fails only when called.
function ui.RefreshSavedSearches()
    if not ui.buySaved then return end
    -- DERIVED from the window's height, not measured off the column.
    --
    -- It used to call ui.RowsFor(ui.savedAreaL, ...), which reads GetHeight()
    -- on a frame anchored by two edges -- so it got the height that frame was
    -- last LAID OUT at, which is the window's creation size. Both lists then
    -- stopped short of the bottom of their own well however tall the window
    -- was. Third time this trap has bitten: ui.PanelHeightAt exists for it and
    -- ui.PanelWidthAt was added for it in 1.19.2.
    local fit = ui.SavedRowsAt(
        (ui.frame and ui.frame.GetHeight and ui.frame:GetHeight()) or 0)

    local function paint(rows, list, which, offset)
        local total = table.getn(list)
        -- Re-clamp EVERY paint, not only on the wheel: deleting a favourite
        -- while scrolled to the bottom would otherwise leave the list showing
        -- an empty band past the end of it.
        local maxOff = total - fit
        if maxOff < 0 then maxOff = 0 end
        if offset > maxOff then offset = maxOff end
        if offset < 0 then offset = 0 end
        if which == "recent" then ui.savedOffRecent = offset
        else ui.savedOffFav = offset end

        local i = 1
        while i <= table.getn(rows) do
            local r = rows[i]
            local q = nil
            if i <= fit then q = list[i + offset] end
            if q then
                r.full = q
                -- The list index is the REAL one, not the row's position:
                -- Move Up / Move Down / Delete act on the favourite you
                -- clicked, and a scrolled list would otherwise reorder the
                -- wrong one.
                r.listIndex = i + offset
                -- The favourite star is its OWN FontString now (created with
                -- the row), so it stays gold whatever the label does and no
                -- longer needs a |c prefix spliced onto every query string.
                --
                -- Clip, never wrap: a row is one line high and a query is
                -- long. The width comes from the ROW rather than a constant,
                -- so a wider window clips less instead of clipping to the
                -- same 244px it did at the minimum size.
                local avail = (r:GetWidth() or 0) - 8
                if r.star then avail = avail - 14 end
                if avail < 60 then avail = 244 end
                ui.SetTextClipped(r.label, q, avail)
                r:Show()
            else
                r.full = nil
                r.listIndex = nil
                r.selTex:Hide()
                r:Hide()
            end
            i = i + 1
        end
    end
    paint(ui.savedRecentRows, A.buy.Recent(), "recent",
          ui.savedOffRecent or 0)
    paint(ui.savedFavRows, A.buy.Favorites(), "fav", ui.savedOffFav or 0)
    ui.HideSavedMenu()
end

-- Scroll one saved column by `delta` wheel notches and repaint.
--
-- The two columns scroll INDEPENDENTLY -- Recent is a capped auto-list and
-- Favorites is yours, and there is no reason moving through one should move
-- the other. The clamp lives in the paint, so this only has to nudge the
-- number and let the paint decide whether it was legal.
function ui.ScrollSaved(which, delta)
    if which == "recent" then
        ui.savedOffRecent = (ui.savedOffRecent or 0) - delta
    else
        ui.savedOffFav = (ui.savedOffFav or 0) - delta
    end
    ui.HideSavedMenu()
    ui.RefreshSavedSearches()
end

-- `advLeft` is the ADVANCED content origin -- see ui.BuildSavedSearches.
function ui.BuildFilterBuilder(panel, advLeft)
    if ui.buyBuilder then return end

    local f = CreateFrame("Frame", "AegisExchangeFilterBuilder", panel)
    f:SetPoint("TOPLEFT", panel, "TOPLEFT", advLeft, -ADVL.body_y)
    f:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT",
        -ADVL.right_pad, ADVL.body_bot)
    f:Hide()
    ui.buyBuilder = f

    -- TWO wells side by side, as the concept has them: the Blizzard-side form
    -- and the post-filter builder are two different things and one box around
    -- both said they were one. colL's width is set by ui.LayoutBuilderForm so
    -- the split holds at any window size; colR simply takes what is left.
    -- Placed by ui.SplitAdvColumns, the SAME function Saved Searches uses --
    -- see the note there. Split at BUILD time as well as on resize: the
    -- builder used to carry a 400px placeholder until the first layout pass,
    -- so the two views disagreed on the very first paint too.
    local colL = CreateFrame("Frame", nil, f)
    local colR = CreateFrame("Frame", nil, f)
    ui.fbColL, ui.fbColR = colL, colR
    ui.SplitAdvColumns(f, colL, colR)
    ui.MakeWell(colL, colL, 0)
    ui.MakeWell(colR, colR, 0)

    -- Text goes on a child frame, not on the column: a child draws above ALL
    -- of its parent's regions, so a FontString made on the column would sit
    -- behind the well whatever order it was created in.
    local contentL = CreateFrame("Frame", nil, colL)
    contentL:SetAllPoints(colL)
    local contentR = CreateFrame("Frame", nil, colR)
    contentR:SetAllPoints(colR)

    local function header(parent, on, text)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", on, "TOPLEFT", FBL.pad, -FBL.pad)
        fs:SetText(text)
        fs:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
        return fs
    end
    -- LEFT-aligned, on a shared left margin, with the controls forming a
    -- second column. They used to be right-aligned into a 58px box, which put
    -- every label at a different x and read as ragged rather than as a form.
    local function label(text, y)
        local fs = contentL:CreateFontString(nil, "OVERLAY",
            "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", colL, "TOPLEFT", FBL.lbl_x, y)
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
        fs:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
        return fs
    end
    local function check(text, x, y, onClick)
        local c = ui.MakeCheckBox(colL, 16)
        c:SetPoint("TOPLEFT", colL, "TOPLEFT", x, y)
        c:SetLabel(text, C.text)
        c:SetScript("OnClick", function()
            if onClick then onClick() end
            ui.RefreshBuilder()
        end)
        return c
    end

    local CX = FBL.ctl_x

    -- ---- Blizzard-side filters ----------------------------------------
    header(contentL, colL, "AUCTION HOUSE FILTER")

    label("Name", ui.FBRow(1))
    local nameBox = ui.FlattenEditBox(
        CreateFrame("EditBox", nil, colL, "InputBoxTemplate"))
    nameBox:SetWidth(FBL.ctl_w); nameBox:SetHeight(18)
    nameBox:SetPoint("TOPLEFT", colL, "TOPLEFT", CX, ui.FBRow(1) + 3)
    nameBox:SetAutoFocus(false)
    nameBox:SetScript("OnEscapePressed", function() nameBox:ClearFocus() end)
    nameBox:SetScript("OnEnterPressed", function()
        nameBox:ClearFocus(); ui.RefreshBuilder()
    end)
    nameBox:SetScript("OnTextChanged", function() ui.RefreshBuilder() end)
    ui.fbName = nameBox

    -- Exact rides the NAME row and Usable the LEVEL row, as the concept has
    -- them. On rows of their own they cost the form two rows of height and
    -- read as unrelated to the field each one actually qualifies.
    ui.fbExact = check("Exact", 0, 0)
    ui.fbExact:ClearAllPoints()
    ui.fbExact:SetPoint("LEFT", nameBox, "RIGHT", FBL.chk_gap, 0)

    label("Level Range", ui.FBRow(2))
    ui.fbMinLevel = MakeNumBox(colL, FBL.lvl_w, function() ui.RefreshBuilder() end)
    ui.fbMinLevel:SetPoint("TOPLEFT", colL, "TOPLEFT", CX, ui.FBRow(2) + 3)
    local dash = contentL:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dash:SetPoint("LEFT", ui.fbMinLevel, "RIGHT", 7, 0)
    dash:SetText("\226\128\147")
    dash:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
    ui.fbMaxLevel = MakeNumBox(colL, FBL.lvl_w, function() ui.RefreshBuilder() end)
    ui.fbMaxLevel:SetPoint("LEFT", dash, "RIGHT", 7, 0)

    ui.fbUsable = check("Usable", 0, 0)
    ui.fbUsable:ClearAllPoints()
    ui.fbUsable:SetPoint("LEFT", ui.fbMaxLevel, "RIGHT", FBL.chk_gap, 0)

    label("Item Class", ui.FBRow(3))
    ui.fbClass = MakeDropdown(colL, FBL.ctl_w, function()
        -- Class gates Subclass gates Slot: changing it invalidates both below.
        ui.fbSubclass:SetValue(nil, true)
        ui.fbSlot:SetValue(nil, true)
        ui.RefreshBuilder()
    end)
    ui.fbClass.button:SetPoint("TOPLEFT", colL, "TOPLEFT", CX, ui.FBRow(3) + 3)

    label("Item Subclass", ui.FBRow(4))
    ui.fbSubclass = MakeDropdown(colL, FBL.ctl_w, function()
        ui.fbSlot:SetValue(nil, true)
        ui.RefreshBuilder()
    end)
    ui.fbSubclass.button:SetPoint("TOPLEFT", colL, "TOPLEFT", CX, ui.FBRow(4) + 3)

    label("Item Slot", ui.FBRow(5))
    ui.fbSlot = MakeDropdown(colL, FBL.ctl_w, function() ui.RefreshBuilder() end)
    ui.fbSlot.button:SetPoint("TOPLEFT", colL, "TOPLEFT", CX, ui.FBRow(5) + 3)

    label("Min Quality", ui.FBRow(6))
    ui.fbQuality = MakeDropdown(colL, FBL.ctl_w, function() ui.RefreshBuilder() end)
    ui.fbQuality.button:SetPoint("TOPLEFT", colL, "TOPLEFT", CX, ui.FBRow(6) + 3)

    -- ---- Extra term options --------------------------------------------
    -- Three flags the term language has always understood and the form could
    -- not reach: `buyout`, bare `stack`, and `stack/N`. Until now ui.BuilderTerm
    -- did not read them either, so a query carrying any of them lost it the
    -- moment you pressed Build.
    ui.fbBuyout = check("Buyout only", CX, ui.FBRow(7))

    -- Full stacks and an explicit size are MUTUALLY EXCLUSIVE, because the
    -- term cannot hold both: TermToQuery emits `stack/N` when stackSize is set
    -- and bare `stack` only when it is not. A form that let you tick both
    -- would express a state the query cannot, and Build would silently drop
    -- one of them. So each one clears the other -- see ui.BuilderStackGate.
    ui.fbFullStack = check("Full stacks only", CX, ui.FBRow(8), function()
        if ui.fbFullStack:GetChecked() and ui.fbStackSize then
            ui.fbStackSize:SetText("")
        end
    end)

    label("Stack Size", ui.FBRow(9))
    ui.fbStackSize = MakeNumBox(colL, FBL.lvl_w, function()
        ui.BuilderStackGate()
        ui.RefreshBuilder()
    end)
    ui.fbStackSize:SetPoint("TOPLEFT", colL, "TOPLEFT", CX, ui.FBRow(9) + 3)

    -- ---- Component / post-filter system --------------------------------
    -- Pick a component, type a value, press Enter: the clause is appended to
    -- the list below. Stacked clauses are ANDed; `and`/`or`/`not` are there
    -- to override that, not to be typed for the common case.
    header(contentR, colR, "POST FILTER")

    local compLbl = contentR:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    compLbl:SetPoint("TOPLEFT", colR, "TOPLEFT", FBL.pad, ui.FBRow(1))
    compLbl:SetText("Component")
    compLbl:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])

    ui.fbComponent = MakeDropdown(colR, FBL.comp_w,
        function() ui.RefreshBuilder() end,
        true)   -- no "All" row: there is no such thing as all components
    ui.fbComponent.button:SetPoint("TOPLEFT", colR, "TOPLEFT",
        FBL.pad + 72, ui.FBRow(1) + 3)

    -- Right of the value box, so the Enter-to-add rule is visible while you
    -- are typing rather than only in the empty-state hint underneath.
    --
    -- PLAIN WORDS, not the concept's "↵". U+21B5 is not in the 1.12 font and
    -- rendered as nothing at all, leaving a blank before "adds" -- an
    -- invisible character is worse than a longer label, because it reads as a
    -- layout fault rather than as a missing glyph.
    local addsHint = contentR:CreateFontString(nil, "OVERLAY",
        "GameFontDisableSmall")
    addsHint:SetPoint("TOPRIGHT", colR, "TOPRIGHT", -FBL.pad, ui.FBRow(1))
    addsHint:SetText("Enter adds")

    -- FLATTENED, like every other box in the window. Raw InputBoxTemplate
    -- brings its own rounded end-cap textures, and with nothing drawn between
    -- them the box rendered as a bare "( )" -- which had previously been read
    -- as the box being clipped and "fixed" by anchoring both edges.
    local cvBox = ui.FlattenEditBox(
        CreateFrame("EditBox", nil, colR, "InputBoxTemplate"))
    cvBox:SetHeight(18)
    cvBox:SetPoint("TOPLEFT", ui.fbComponent.button, "TOPRIGHT", 10, -1)
    cvBox:SetPoint("TOPRIGHT", addsHint, "TOPLEFT", -8, -3)
    cvBox:SetAutoFocus(false)
    cvBox:SetScript("OnEscapePressed", function() cvBox:ClearFocus() end)
    cvBox:SetScript("OnEnterPressed", function() ui.BuilderAddComponent() end)
    ui.fbCompValue = cvBox

    -- Tab down the left column in the order it is READ, then across to the
    -- component value -- which is the last thing you fill in before pressing
    -- Enter to add a clause. The dropdowns are not in the chain: they are
    -- buttons, not edit boxes, and there is nothing to type into them.
    ui.LinkTabOrder({ ui.fbName, ui.fbMinLevel, ui.fbMaxLevel,
                      ui.fbStackSize, ui.fbCompValue })

    local pfLbl = contentR:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    pfLbl:SetPoint("TOPLEFT", colR, "TOPLEFT", FBL.pad, ui.FBRow(2))
    pfLbl:SetText("Post Filter:")

    -- The clause list gets its own recessed well, as the concept draws it.
    -- Bare rows on the panel read as text that happened to land there rather
    -- than as a list you can act on.
    local pfArea = CreateFrame("Frame", nil, colR)
    pfArea:SetPoint("TOPLEFT", colR, "TOPLEFT", FBL.pad, ui.FBRow(2) - 18)
    pfArea:SetPoint("BOTTOMRIGHT", colR, "BOTTOMRIGHT", -FBL.pad, FBL.pad)
    ui.MakeWell(colR, pfArea, 0)
    ui.fbPostArea = pfArea

    -- The stacking rule, on the well rather than printed under the clauses.
    -- Mouse is enabled ONLY for this: the clause rows are children and take
    -- their own clicks, so nothing is swallowed.
    pfArea:EnableMouse(true)
    pfArea:SetScript("OnEnter", function()
        GameTooltip:SetOwner(pfArea, "ANCHOR_TOPLEFT")
        GameTooltip:SetText("Post filter", 1, 1, 1)
        GameTooltip:AddLine(
            "Stacked lines must ALL hold. Add 'or' between two to widen.",
            0.8, 0.8, 0.8, 1)
        GameTooltip:AddLine("Click a line to remove it.", 0.8, 0.8, 0.8, 1)
        GameTooltip:Show()
    end)
    pfArea:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- One clickable row per clause. Clicking removes it, which is the only
    -- edit the list needs: order is assembled front-to-back anyway.
    ui.fbPostRows = {}
    local pi = 1
    while pi <= FB_POST_ROWS do
        local r = CreateFrame("Button", nil, pfArea)
        r:SetHeight(16)
        r:SetPoint("TOPLEFT", pfArea, "TOPLEFT", 6, -6 - (pi - 1) * 16)
        r:SetPoint("TOPRIGHT", pfArea, "TOPRIGHT", -6, -6 - (pi - 1) * 16)
        r.aegisNoSkin = true      -- a list row that has to be clickable
        local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", r, "LEFT", 2, 0)
        fs:SetJustifyH("LEFT")
        r.label = fs
        r.idx = pi
        r:SetScript("OnClick", function() ui.BuilderRemoveComponent(r.idx) end)
        r:Hide()
        ui.fbPostRows[pi] = r
        pi = pi + 1
    end

    -- Empty-state hint, centred in the clause well. The concept only ever
    -- shows the populated state, but an empty box still has to say what puts
    -- something in it.
    ui.fbPostHint = contentR:CreateFontString(nil, "OVERLAY",
        "GameFontDisableSmall")
    ui.fbPostHint:SetPoint("CENTER", pfArea, "CENTER", 0, 0)
    ui.fbPostHint:SetJustifyH("CENTER")

    -- ---- Preview + actions ---------------------------------------------
    -- The note is a STATUS line -- "Copied to the search box.", "Loaded term 1
    -- of 3..." -- not a form field, and it is parented to the PANEL, not to
    -- the column.
    --
    -- It used to sit below the last form row, at a fixed offset that assumed a
    -- column tall enough to hold it. At the minimum window height the column
    -- is 254px and the note landed at 288, so it escaped the well entirely and
    -- drew across the money readout on the action bar. It belongs on that bar,
    -- which is where every other status line in this window lives.
    ui.fbNote = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.fbNote:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", FBL.pad, 26)
    ui.fbNote:SetJustifyH("LEFT")
    ui.fbNote:Hide()

    -- Action row: parented to the PANEL and anchored bottom-right, not to the
    -- builder frame. It sits on the window's action bar beside Bid / Buyout /
    -- Close, so it must line up with them rather than float wherever the
    -- builder's own bottom edge happens to land.
    --
    -- Built right-to-left from the Bid box so the row stays put whatever the
    -- window width. Only shown while the Builder view is up.
    local function action(text, w, rightOf, fn, kind)
        local b = ui.MakeButton(panel, kind or "quiet")
        b:SetWidth(w); b:SetHeight(21)
        b:SetPoint("RIGHT", rightOf, "LEFT", -5, 0)
        b:SetText(text)
        b:SetScript("OnClick", fn)
        b:Hide()
        return b
    end
    -- Right to left: Clear, Import, Build, Search -- so on screen they read
    -- Search | Build > | Import | Clear, then the window's Bid / Buyout /
    -- Close.
    --
    -- Import is back. It was dropped when the Builder was somewhere you only
    -- ever LEFT from; now that a shift-click in Saved Searches lands you in
    -- it, a query typed by hand has no other route into the form.
    local bClear = action("Clear", 54, ui.buyCloseBtn,
        function() ui.BuilderClear() end)
    local bImport = action("Import", 60, bClear,
        function() ui.BuilderImport() end)
    -- No "+ OR": a `;` term is still typeable in the search box and `or` is
    -- still a component, so the button bought nothing for the space.
    -- Accent, and an arrow rather than a ">": Build is the Builder's own verb,
    -- the thing the form exists to produce, and the concept gives it the same
    -- purple plate the Advanced / Back pair wear.
    local bBuild = action("Build \226\134\146", 72, bImport,
        function() ui.BuilderExport() end, "accent")
    -- Search is the primary plate here for the same reason it is on the
    -- default strip: it is what the Builder exists to reach. Build > lost its
    -- purple tint with the Advanced button's, and for the same reason.
    local bSearch = action("Search", 62, bBuild,
        function() ui.BuilderSearch() end, "primary")
    ui.fbSearchBtn = bSearch
    ui.fbBuildBtn = bBuild
    ui.fbImportBtn = bImport
    -- Raised and lowered with the Builder view by SetBuyView.
    ui.fbActionBtns = { bSearch, bBuild, bImport, bClear }

    ui.BuilderClear()
end


-- ---- Filter Builder: form <-> term --------------------------------------

-- Quality dropdown options, from the client's own localized names, each
-- carrying that quality's colour so the list reads as the qualities it is
-- naming rather than as six identical words. ITEM_QUALITY_COLORS is FrameXML's
-- own table -- the same one item links and the result rows' Item column use --
-- so a Rare here is exactly the blue a Rare is everywhere else. Guarded
-- because a colourless list is a cosmetic loss and a nil index is an error.
local function BuilderQualityOptions()
    local out = {}
    local i = 0
    while i <= 5 do
        local desc = getglobal("ITEM_QUALITY" .. i .. "_DESC")
        if desc and desc ~= "" then
            local colour = nil
            if ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[i] then
                local c = ITEM_QUALITY_COLORS[i]
                colour = { c.r, c.g, c.b }
            end
            table.insert(out, { value = i, text = desc, colour = colour })
        end
        i = i + 1
    end
    return out
end

-- Read the form into a parsed-term-shaped table -- the same shape
-- buy.ParseTerm produces, so buy.TermToQuery and buy.TermsEqual both apply.
function ui.BuilderTerm()
    local function num(box)
        local n = tonumber(util.Trim(box:GetText() or ""))
        if n and n >= 1 then return math.floor(n) end
        return nil
    end
    local minL, maxL = num(ui.fbMinLevel), num(ui.fbMaxLevel)
    -- One end of a range alone still means a range; the parser stores both.
    if minL and not maxL then maxL = minL end
    if maxL and not minL then minL = maxL end

    -- An explicit size WINS over the full-stacks tick, and the two can never
    -- both reach the term: `stack/N` and bare `stack` are alternatives in the
    -- query language, not additions. The form gate keeps them apart while you
    -- type; this keeps them apart even if something set both directly.
    local stackSize = num(ui.fbStackSize)
    local stackOnly = ui.fbFullStack:GetChecked() and true or false
    if stackSize then stackOnly = false end

    return {
        name       = util.Trim(ui.fbName:GetText() or ""),
        exact      = ui.fbExact:GetChecked() and true or false,
        usable     = ui.fbUsable:GetChecked() and true or false,
        -- These three were missing entirely, which is why a query carrying
        -- `buyout` or `stack/20` lost it the moment you pressed Build.
        buyoutOnly = ui.fbBuyout:GetChecked() and true or false,
        stackOnly  = stackOnly,
        stackSize  = stackSize,
        quality    = ui.fbQuality:GetValue(),
        minLevel   = minL,
        maxLevel   = maxL,
        class      = ui.fbClass:GetValue(),
        subclass   = ui.fbSubclass:GetValue(),
        slot       = ui.fbSlot:GetValue(),
        -- Copied, not referenced: BuilderTerm's result is handed to
        -- TermToQuery and TermsEqual, and a shared table would let either
        -- mutate the builder's live list.
        post       = util.CopyList(ui.builderPost),
    }
end

-- Push a parsed term INTO the form. Dropdowns are set silently so filling the
-- form doesn't fire the gating callbacks and immediately clear what we just
-- set -- the gating is re-applied once, by RefreshBuilder, at the end.
function ui.BuilderSetTerm(t)
    t = t or {}
    ui.fbName:SetText(t.name or "")
    ui.fbExact:SetChecked(t.exact and 1 or nil)
    ui.fbUsable:SetChecked(t.usable and 1 or nil)
    ui.fbMinLevel:SetText(t.minLevel and tostring(t.minLevel) or "")
    ui.fbMaxLevel:SetText(t.maxLevel and tostring(t.maxLevel) or "")
    -- The other half of the round trip. Without these, loading a query into
    -- the form dropped its buyout/stack flags, and Build then wrote the term
    -- back WITHOUT them -- so importing and rebuilding quietly changed the
    -- search. The size is written before the tick so the gate cannot clear it.
    ui.fbBuyout:SetChecked(t.buyoutOnly and 1 or nil)
    ui.fbStackSize:SetText(t.stackSize and tostring(t.stackSize) or "")
    ui.fbFullStack:SetChecked((t.stackOnly and not t.stackSize) and 1 or nil)
    ui.builderPost = util.CopyList(t.post)

    ui.fbClass:SetOptions(A.buy.ClassOptions())
    ui.fbClass:SetValue(t.class, true)
    ui.fbSubclass:SetOptions(A.buy.SubclassOptions(t.class))
    ui.fbSubclass:SetValue(t.subclass, true)
    ui.fbSlot:SetOptions(A.buy.SlotOptions(t.class, t.subclass))
    ui.fbSlot:SetValue(t.slot, true)
    ui.fbQuality:SetOptions(BuilderQualityOptions())
    ui.fbQuality:SetValue(t.quality, true)

    ui.RefreshBuilder()
end

-- Load the search bar back into the form.
--
-- The form edits ONE term, so a multi-term query loads its FIRST and SAYS so.
-- Quietly loading term 1 would be the worst option: you would edit what
-- looked like your whole query and Build something narrower.
function ui.BuilderImport()
    if not ui.buyQueryBox then return end
    local text = util.Trim(ui.buyQueryBox:GetText() or "")
    local terms = A.buy.ParseQuery(text)
    ui.BuilderSetTerm(terms[1])
    local n = table.getn(terms)
    if n > 1 then
        ui.BuilderNote("Loaded term 1 of " .. n
            .. " \226\128\148 the other " .. (n - 1)
            .. " are not shown here, and Build will replace them.", true)
    else
        ui.BuilderNote("Loaded from the search box.")
    end
end

function ui.BuilderClear()
    ui.BuilderSetTerm(nil)
    ui.BuilderNote("")
    if ui.fbCompValue then ui.fbCompValue:SetText("") end
    -- Clear the SEARCH BAR too. Leaving the query behind after emptying the
    -- form is the worst of both: the next Search runs the old query while the
    -- form in front of you says something else entirely.
    if ui.buyQueryBox then ui.buyQueryBox:SetText("") end
end

-- ---- the component / post-filter system ---------------------------------

-- What the Component dropdown offers. Only what the engine can actually
-- honour: an option that silently does nothing is worse than an absent one.
-- The combinators come first because they are the ones you reach for to
-- CHANGE the default, and the default (stacking = AND) needs no component.
-- Components that are NOT wired to the engine yet. They appear in the
-- dropdown so the shape of the finished list is visible, and they parse and
-- round-trip -- but they narrow nothing, so every one of them is labelled
-- and drawn as inert. A component that silently did nothing would be
-- indistinguishable from a broken filter, which is the exact failure this
-- addon keeps having to fix.
-- A component's colour, used BOTH by the dropdown's selected text and by its
-- line in the Post Filter list. One source, so the two can never disagree
-- about what a tooltip clause looks like.
function ui.ComponentColor(kind)
    if kind == "and" or kind == "or" or kind == "not" then
        return 1.00, 0.48, 0.48          -- combinators: red
    elseif kind == "tooltip" then
        return 0.79, 0.63, 1.00          -- tooltip: violet
    elseif kind == "max-unit-buy" or kind == "min-unit-buy" then
        return 0.50, 0.82, 1.00          -- price bounds: blue
    elseif ui.PENDING_COMPONENTS and ui.PENDING_COMPONENTS[kind] then
        return 0.37, 0.33, 0.25          -- not wired up yet: dim
    end
    return C.text[1], C.text[2], C.text[3]
end

-- Shrinking this table is what un-greys a component: the dropdown's colour,
-- its tooltip and the Post Filter list's "ignored" label all read it, so the
-- UI follows the engine rather than being told twice.
ui.PENDING_COMPONENTS = {
    ["item"]              = true,
    ["disenchant-profit"] = true,
}

-- The concept's order: the three COMBINATORS first, then the filters. They
-- lead because they are a different kind of thing -- they change how the
-- clauses below combine rather than narrowing anything themselves -- and
-- ui.ComponentColor draws them red to say so.
local COMPONENT_ORDER = {
    "and", "or", "not",
    "tooltip", "item", "min-level", "max-level", "rarity", "seller",
    "max-unit-buy", "min-unit-buy", "percent", "vendor-profit",
    "left", "disenchant-profit",
}

local function BuilderComponentOptions()
    local out = {}
    local i = 1
    while i <= table.getn(COMPONENT_ORDER) do
        local kind = COMPONENT_ORDER[i]
        local r, g, b = ui.ComponentColor(kind)
        local tip = nil
        -- Unavailability is said with COLOUR, as the concept says it, not with
        -- "(soon)" glued onto the label -- which made every pending row wider
        -- than the working ones and read as part of the component's name. The
        -- dim entry still needs to explain itself, so it carries a tooltip.
        if ui.PENDING_COMPONENTS[kind] then
            tip = "Not wired up yet \226\128\148 this parses and round-trips, "
                .. "but it narrows nothing."
        end
        table.insert(out, {
            value = kind, text = kind, colour = { r, g, b }, tip = tip,
        })
        i = i + 1
    end
    return out
end

-- Does this component need a typed value?
local function ComponentTakesValue(kind)
    if not kind then return false end
    if kind == "and" or kind == "or" or kind == "not" then return false end
    return true
end

-- Append the chosen component to the Post Filter list. This is the Enter key
-- in the workflow: pick, type, Enter.
function ui.BuilderAddComponent()
    if not ui.fbComponent then return end
    local kind = ui.fbComponent:GetValue()
    if not kind then
        ui.BuilderNote("Pick a component first.", true)
        return
    end
    local raw = util.Trim(ui.fbCompValue:GetText() or "")
    local value = nil
    if ComponentTakesValue(kind) then
        if raw == "" then
            ui.BuilderNote("'" .. kind .. "' needs a value.", true)
            return
        end
        if kind == "tooltip" then
            value = raw
        else
            -- ONE parser, the engine's. The form used to assume every
            -- non-tooltip component took MONEY, which was true only while
            -- money bounds were the only ones wired up -- a level or a
            -- quality typed here would have been read as a price.
            value = A.buy.ParseComponentValue(kind, raw)
            if value == nil then
                ui.BuilderNote("'" .. kind .. "' needs "
                    .. A.buy.ComponentValueHint(kind) .. ".", true)
                return
            end
        end
    end
    ui.builderPost = ui.builderPost or {}
    table.insert(ui.builderPost, { kind = kind, value = value })
    ui.fbCompValue:SetText("")
    ui.BuilderNote("")
    ui.RefreshBuilder()
end

function ui.BuilderRemoveComponent(i)
    if not ui.builderPost or not ui.builderPost[i] then return end
    table.remove(ui.builderPost, i)
    ui.RefreshBuilder()
end

-- Paint the Post Filter list, with the live parser feedback beside each
-- clause. That feedback is the point of the panel: it is where abbreviation
-- expansion becomes visible, so you can see that "agi" really did become
-- Agility before you spend a scan on it.
local function PaintPostFilter()
    local list = ui.builderPost or {}
    local i = 1
    while i <= table.getn(ui.fbPostRows) do
        local row = ui.fbPostRows[i]
        local e = list[i]
        if e then
            -- Three parts, kept separate so the CLIP below can shorten the
            -- value without ever cutting a colour escape in half. Splicing
            -- them first and clipping the result would sooner or later slice
            -- through a "|cffRRGGBB", which prints as literal garbage and
            -- leaks the colour into every line after it.
            local pre, val, post
            local cr, cg, cb = ui.ComponentColor(e.kind)
            local hex = string.format("|cff%02x%02x%02x",
                math.floor(cr * 255), math.floor(cg * 255), math.floor(cb * 255))
            if e.kind == "and" or e.kind == "or" or e.kind == "not" then
                pre, val, post = hex .. e.kind .. "|r", "", ""
            elseif e.kind == "tooltip" then
                pre, val = hex .. e.kind .. ":|r ", tostring(e.value)
                local needles = A.buy.TooltipNeedles(e.value)
                if table.getn(needles) > 1 then
                    post = "  |cff8d7d5c\226\134\146 or \226\128\156"
                        .. needles[2] .. "\226\128\157|r"
                else
                    post = ""
                end
            elseif ui.PENDING_COMPONENTS[e.kind] then
                -- Drawn dim and labelled, because it does not filter yet.
                pre, val = hex .. e.kind .. ": ", tostring(e.value)
                post = "|r  |cffd08050not wired up yet \226\128\148 ignored|r"
            else
                -- The value's SHAPE comes from the engine, not from an
                -- assumption made here. This branch used to format every
                -- remaining component as money and tack "per item" on --
                -- correct only while the price bounds were the only ones
                -- implemented, and quietly wrong the moment a level or a
                -- quality reached it.
                pre = hex .. e.kind .. ":|r "
                local vk = A.buy.ComponentValueKind(e.kind)
                if vk == "money" then
                    val = util.FormatMoney(e.value, true)
                    -- Both money components are per-unit, but they bound
                    -- opposite ends: a price CAP versus a margin FLOOR.
                    -- "per item" is true of both and tells you nothing about
                    -- which way round this one reads.
                    if e.kind == "vendor-profit" then
                        post = "  |cff8d7d5cper item, or more|r"
                    else
                        post = "  |cff8d7d5cper item|r"
                    end
                elseif vk == "quality" then
                    -- Named back for the reader. The QUERY keeps the index
                    -- (see buy.ComponentValueText); a list you are reading
                    -- can afford the word.
                    val = A.scan.QUALITY_NAMES[e.value] or tostring(e.value)
                    post = "  |cff8d7d5cexactly|r"
                elseif vk == "timeleft" then
                    val = A.buy.ComponentValueText(e.kind, e.value)
                    post = "  |cff8d7d5cor less|r"
                elseif vk == "percent" then
                    -- The % goes back on for READING. The query stores a bare
                    -- number (see buy.ComponentValueText) because that is what
                    -- the comparison needs; a list you are reading can afford
                    -- the sign.
                    val = tostring(e.value) .. "%"
                    post = "  |cff8d7d5cof market, or less|r"
                else
                    val = A.buy.ComponentValueText(e.kind, e.value)
                    post = ""
                end
            end

            -- Clip, never wrap -- a wrapped line in a fixed-height row is
            -- worse than a clipped one, the rule everywhere else in this file.
            -- The label carries no SetWidth, so an over-long clause runs past
            -- the well's edge instead; measured here and shortened only when
            -- it actually overflows, so the common case costs nothing.
            row.label:SetText(pre .. val .. post)
            local avail = (row:GetWidth() or 0) - 6
            if avail > 40 and row.label:GetStringWidth() > avail then
                -- Budget for the value = what is left once the decorations
                -- have had their share. Measured with the escapes stripped by
                -- setting the plain text and reading it back.
                row.label:SetText(pre .. post)
                local fixed = row.label:GetStringWidth() or 0
                ui.SetTextClipped(row.label, val, avail - fixed)
                row.label:SetText(pre .. (row.label:GetText() or "") .. post)
            end
            row:Show()
        else
            row:Hide()
        end
        i = i + 1
    end
    -- The hint belongs to the EMPTY state only.
    --
    -- It used to change with the clause count and stay on screen underneath
    -- them, so a populated list carried a long centred sentence competing with
    -- the clauses themselves -- and the concept has no such line. What it said
    -- is worth keeping, so the stacking rule moved to a tooltip on the well
    -- (see the OnEnter in ui.BuildFilterBuilder), where it is there when
    -- wanted and is not permanent furniture.
    if ui.fbPostHint then
        if table.getn(list) == 0 then
            ui.fbPostHint:SetText("Pick a component, type a value, press Enter.")
            ui.fbPostHint:Show()
        else
            ui.fbPostHint:Hide()
        end
    end
end

-- Re-apply the class -> subclass -> slot gating, then repaint the preview.
function ui.RefreshBuilder()
    if not ui.buyBuilder or ui.builderPainting then return end
    -- SetOptions can clear a now-invalid value, which would re-enter here.
    ui.builderPainting = true

    local class = ui.fbClass:GetValue()
    ui.fbSubclass:SetOptions(A.buy.SubclassOptions(class))
    ui.fbSubclass:SetEnabled(class ~= nil)
    local subclass = ui.fbSubclass:GetValue()
    ui.fbSlot:SetOptions(A.buy.SlotOptions(class, subclass))
    ui.fbSlot:SetEnabled(class ~= nil
        and table.getn(A.buy.SlotOptions(class, subclass)) > 0)

    if table.getn(ui.fbComponent.options or {}) == 0 then
        ui.fbComponent:SetOptions(BuilderComponentOptions())
        ui.fbComponent:SetValue("tooltip", true)
    end
    -- A combinator takes no value, so dim the box to say so.
    --
    -- DIM, not disable: EditBox has no SetEnabled on 1.12 (that is a Button
    -- method), and calling one would error the moment a combinator was
    -- picked. SetTextColor comes from FontInstance and is safe here.
    local compKind = ui.fbComponent:GetValue()
    if ComponentTakesValue(compKind) then
        ui.fbCompValue:SetTextColor(C.text[1], C.text[2], C.text[3])
    else
        ui.fbCompValue:SetTextColor(0.42, 0.38, 0.30)
    end
    -- The dropdown's selected text takes the component's own colour, so what
    -- you are about to add is identifiable before you add it. That now rides
    -- on the option's own `colour`, applied inside RepaintButton -- setting
    -- the FontString here instead was wiped by the first mouseover, because
    -- RepaintButton runs on every hover and press.
    PaintPostFilter()

    local term = ui.BuilderTerm()
    local q = A.buy.TermToQuery(term)
    if ui.fbSearchBtn then ui.fbSearchBtn:Enable() end

    ui.builderPainting = false
end

function ui.BuilderSearch()
    local q = A.buy.TermToQuery(ui.BuilderTerm())
    -- Force ADVANCED before searching. The builder writes into the query box,
    -- and only Advanced mode READS that box -- in default mode DoBuySearch
    -- composes the term from the Name field instead and would silently run a
    -- different search than the one on screen. The builder is only reachable
    -- from Advanced in practice, but the two must not be able to disagree.
    if ui.buyMode ~= "advanced" then ui.SetBuyMode("advanced") end
    if ui.buyQueryBox then ui.buyQueryBox:SetText(q) end
    ui.SetBuyView("results")
    ui.DoBuySearch()
end

-- Put the built query into the search box. `orTerm` appends it as another
-- semicolon term instead of replacing -- the builder edits ONE term, and this
-- is how you assemble a multi-term query out of it.
function ui.BuilderExport(orTerm)
    local q = A.buy.TermToQuery(ui.BuilderTerm())
    if not ui.buyQueryBox then return end
    local cur = util.Trim(ui.buyQueryBox:GetText() or "")
    if orTerm and cur ~= "" and q ~= "" then
        ui.buyQueryBox:SetText(cur .. ";" .. q)
        ui.BuilderNote("Appended as another OR term.")
    else
        ui.buyQueryBox:SetText(q)
        ui.BuilderNote("Copied to the search box.")
    end

end

-- ---- sidebar model + paint ---------------------------------------------

-- ---- category tree (ROADMAP 2e) ----------------------------------------

-- ---- Buy tab view mode (ROADMAP 2f) ------------------------------------
--
-- DEFAULT is the Blizzlike face: category tree on the left, the stock
-- control strip (Name / Level Range / Min Quality / Usable / Search), and
-- one extra button -- Advanced.
--
-- ADVANCED is the aux-style face: no tree, a full query box, and the
-- Shopping Lists sidebar + Filter Builder.
--
-- Everything each mode owns is listed here rather than hidden ad hoc at the
-- call sites, because the failure mode is a widget that belongs to one mode
-- painting over the other -- which is exactly the bug 2e's sidebar guard had
-- to fix. Rows are handled separately: their PAINT re-Shows them, so the
-- paint functions are mode-guarded too.
local function BitsFor(mode)
    if mode == "advanced" then
        return { ui.buyBackBtn, ui.buyQueryBox,
                 ui.buyViewBtns and ui.buyViewBtns[1],
                 ui.buyViewBtns and ui.buyViewBtns[2],
                 ui.buyViewBtns and ui.buyViewBtns[3] }
    end
    -- buyStripRule is DEFAULT-only. It separates the Blizzlike control strip
    -- from the content below it, which is a job only that mode has: Advanced
    -- puts its tab strip in the same band, and the rule drew straight through
    -- it. The concept has no rule there.
    return { ui.buyNameLbl, ui.buyBox, ui.buyLvlLbl, ui.buyMinLevel,
             ui.buyLvlDash, ui.buyMaxLevel, ui.buyQualLbl,
             ui.buyQuality and ui.buyQuality.button, ui.buyUsable,
             ui.buyUsableLbl, ui.buyAdvBtn, ui.buyBrowseHdr,
             ui.buyCatWell, ui.buyCatScroll, ui.buyStripRule }
end

local function ShowBits(list, on)
    local i = 1
    while i <= table.getn(list) do
        local w = list[i]
        if w then if on then w:Show() else w:Hide() end end
        i = i + 1
    end
end

function ui.SetBuyMode(mode)
    if mode ~= "advanced" then mode = "default" end
    ui.buyMode = mode
    -- Filled HERE, not in BuildBuyTab: BuilderQualityOptions is a file-scope
    -- local declared further down, so the name is not in scope inside
    -- BuildBuyTab's body (it would resolve to a nil global). This function is
    -- declared after it, and BuildBuyTab calls this on the way out.
    if ui.buyQuality and table.getn(ui.buyQuality.options or {}) == 0 then
        ui.buyQuality:SetOptions(BuilderQualityOptions())
    end
    if A.db and A.db.char then
        A.db.char.ui = A.db.char.ui or {}
        A.db.char.ui.buyMode = mode
    end
    local adv = (mode == "advanced")

    -- Carry the search across the switch, in whichever direction. The term
    -- is the shared currency: TermToQuery going out, ParseTerm coming back.
    -- Without this, clicking Advanced would throw away what you had typed.
    if adv then
        if ui.buyQueryBox then
            ui.buyQueryBox:SetText(A.buy.TermToQuery(ui.DefaultTerm()))
        end
    else
        if ui.buyQueryBox then
            local terms = A.buy.ParseQuery(
                util.Trim(ui.buyQueryBox:GetText() or ""))
            ui.DefaultSetTerm(terms[1])
        end
        ui.SetBuyView("results")
    end

    ShowBits(BitsFor("advanced"), adv)
    ShowBits(BitsFor("default"), not adv)

    -- The results table moves with the mode: Advanced has no category tree, so
    -- the table starts at the panel margin and is wider. Search moves with it,
    -- because the widget it hung off in default mode is not there any more.
    if ui.AnchorSearchButton then ui.AnchorSearchButton() end
    if ui.LayoutBuyTable then ui.LayoutBuyTable() end
    if ui.LayoutViewTabs then ui.LayoutViewTabs() end
    if ui.LayoutAdvColumns then ui.LayoutAdvColumns() end
    if ui.LayoutBuilderForm then ui.LayoutBuilderForm() end

    -- Rows of the column that is now hidden, put down explicitly.
    local ri = 1
    while ri <= table.getn(ui.buyCatRows or {}) do
        if adv then ui.buyCatRows[ri]:Hide() end
        ri = ri + 1
    end

    if not adv then ui.RefreshCatTree() end
    ui.RefreshBuyMoney()
    ui.RefreshBuyActionBar()
end

-- Whichever box the user is actually typing a search into right now. In the
-- default view that is Blizzard's "Name" field; in Advanced it is the full
-- query box. Everything that puts text in front of the user -- shift-click an
-- item, tab-complete, click a recent search, the builder's Build button --
-- goes through here so it lands where they can see it.
function ui.ActiveSearchBox()
    if ui.buyMode == "advanced" then return ui.buyQueryBox end
    return ui.buyBox
end

-- The default view's whole search, as ONE term: the control strip plus
-- whatever the category tree has selected. This is what makes "the search bar
-- restricts to all categories or the currently selected category" true without
-- any special casing -- the category is simply three more fields on the term,
-- and the same buy.TermToQuery / buy.CompileTerm the typed language uses does
-- the rest.
function ui.DefaultTerm()
    local function num(box)
        if not box then return nil end
        local n = tonumber(util.Trim(box:GetText() or ""))
        if n and n >= 1 then return math.floor(n) end
        return nil
    end
    local minL, maxL = num(ui.buyMinLevel), num(ui.buyMaxLevel)
    -- One end alone is still a range; the parser stores both.
    if minL and not maxL then maxL = minL end
    if maxL and not minL then minL = maxL end
    return {
        name     = util.Trim((ui.buyBox and ui.buyBox:GetText()) or ""),
        minLevel = minL,
        maxLevel = maxL,
        quality  = ui.buyQuality and ui.buyQuality:GetValue() or nil,
        usable   = (ui.buyUsable and ui.buyUsable:GetChecked()) and true or false,
        class    = ui.buyCatClass,
        subclass = ui.buyCatSubclass,
        slot     = ui.buyCatSlot,
    }
end

-- ...and the reverse, for coming back from Advanced. Post-filters (tooltip,
-- stack, buyout-only, exact) have no control in this view; they are dropped
-- and SAID SO rather than silently carried, because a filter you cannot see
-- but that still narrows your results is the worst of both.
function ui.DefaultSetTerm(t)
    t = t or {}
    if ui.buyBox then ui.buyBox:SetText(t.name or "") end
    if ui.buyMinLevel then
        ui.buyMinLevel:SetText(t.minLevel and tostring(t.minLevel) or "")
    end
    if ui.buyMaxLevel then
        ui.buyMaxLevel:SetText(t.maxLevel and tostring(t.maxLevel) or "")
    end
    if ui.buyQuality then ui.buyQuality:SetValue(t.quality, true) end
    if ui.buyUsable then ui.buyUsable:SetChecked(t.usable and 1 or nil) end
    ui.buyCatClass, ui.buyCatSubclass, ui.buyCatSlot = t.class, t.subclass, t.slot
    ui.buyCatSel = ui.CatKey(t.class and {
        kind = t.slot and "slot" or (t.subclass and "sub" or "class"),
        class = t.class, subclass = t.subclass, slot = t.slot,
    } or nil)

    local dropped = table.getn(t.post or {}) > 0 or t.exact
        or t.buyoutOnly or t.stackOnly or t.stackSize
    if dropped and ui.buyStatus then
        ui.buyStatus:SetText("Extra filters stay in Advanced \226\128\148 "
            .. "this view searches without them.")
    end
end

-- ---- row selection (Blizzlike: pick a row, act from the bottom bar) -----

function ui.SelectBuyRow(entry)
    ui.buySel = entry
    -- Prefill the bid box with what this auction actually needs next, the way
    -- the stock UI does -- so Bid is one click when you accept the minimum.
    if entry and ui.buyBidBox then
        SetMoneyBox(ui.buyBidBox, entry.nextBid or entry.minBid or 0)
    end
    ui.UpdateBuyList()
    ui.RefreshBuyActionBar()
end

-- Is `entry` the selected row? Compared by auction index AND name: the page
-- can be re-queried under us and a stale index would light up whatever slid
-- into that slot. Same reasoning as buy.Verify guarding a purchase.
function ui.IsBuySelected(entry)
    local s = ui.buySel
    if not s or not entry then return false end
    return s.index == entry.index and s.name == entry.name
end

-- ---------------------------------------------------------------------------
-- Ticked rows (multi-buyout)
--
-- Held as an ordered LIST of entries rather than a set of indices. An index is
-- only meaningful against the page the client is holding right now, and this
-- selection has to survive a re-query, a sort and a page turn -- the same
-- reason buy.StartBatch works from fingerprints instead of indices.
-- ---------------------------------------------------------------------------

ui.buyChecked = {}

function ui.IsBuyChecked(entry)
    if not entry then return false end
    local i = 1
    while i <= table.getn(ui.buyChecked) do
        local c = ui.buyChecked[i]
        if c.index == entry.index and c.name == entry.name
           and c.buyout == entry.buyout then
            return true
        end
        i = i + 1
    end
    return false
end

function ui.ToggleBuyCheck(entry)
    if not entry or entry.mine then return end
    local i = 1
    while i <= table.getn(ui.buyChecked) do
        local c = ui.buyChecked[i]
        if c.index == entry.index and c.name == entry.name
           and c.buyout == entry.buyout then
            table.remove(ui.buyChecked, i)
            ui.UpdateBuyList()
            ui.RefreshBuyActionBar()
            return
        end
        i = i + 1
    end
    table.insert(ui.buyChecked, entry)
    ui.UpdateBuyList()
    ui.RefreshBuyActionBar()
end

function ui.ClearBuyChecks()
    ui.buyChecked = {}
    ui.RefreshBuyActionBar()
end

function ui.RefreshBuyActionBar()
    if not ui.buyBidBtn then return end
    local nChecked = table.getn(ui.buyChecked or {})

    -- Ticked rows take over the Buyout button. Bid stays single-target --
    -- bidding a batch means nothing, since each auction needs its own amount.
    if nChecked > 0 then
        local total = A.buy.BatchCost(ui.buyChecked)
        local money = GetMoney and GetMoney() or 0
        local afford = total <= money
        ui.buyBuyoutBtn:SetText("Buyout (" .. nChecked .. ")")
        if afford then
            ui.buyBuyoutBtn:Enable()
        else
            ui.buyBuyoutBtn:Disable()
        end
        if ui.buyCheckTotal then
            if afford then
                ui.buyCheckTotal:SetText(nChecked .. " selected \226\128\148 "
                    .. util.FormatMoneyGold(total))
            else
                -- Say WHY it is disabled. A greyed button with no reason is
                -- the thing this addon has shipped twice and both times it
                -- read as broken.
                ui.buyCheckTotal:SetText("|cffff5555" .. nChecked
                    .. " selected \226\128\148 need "
                    .. util.FormatMoney(total - money, false) .. " more|r")
            end
            ui.buyCheckTotal:Show()
        end
        ui.buyBidBtn:Disable()
        return
    end

    if ui.buyCheckTotal then ui.buyCheckTotal:Hide() end
    ui.buyBuyoutBtn:SetText("Buyout")
    local s = ui.buySel
    if s and s.mine then
        -- Your own auction: the client refuses both, so say why by greying
        -- rather than letting the server reject the click.
        ui.buyBidBtn:Disable(); ui.buyBuyoutBtn:Disable()
    elseif s then
        ui.buyBidBtn:Enable()
        if s.buyout and s.buyout > 0 then
            ui.buyBuyoutBtn:Enable()
        else
            ui.buyBuyoutBtn:Disable()   -- bid-only auction
        end
    else
        ui.buyBidBtn:Disable(); ui.buyBuyoutBtn:Disable()
    end
end

function ui.RefreshBuyMoney()
    if not ui.buyMoney then return end
    ui.buyMoney:SetMoney(GetMoney and GetMoney() or 0)
end

-- Flatten the class > subclass > slot hierarchy into visible rows, honouring
-- what is expanded. Everything comes from buy.ClassOptions / SubclassOptions
-- / SlotOptions -- the same three calls the Filter Builder's dropdowns use,
-- which read the client's own localized names. No category list lives here.
function ui.FlattenCats()
    local flat = { { kind = "all", name = "All Categories" } }
    local classes = A.buy and A.buy.ClassOptions() or {}
    local ci = 1
    while ci <= table.getn(classes) do
        local c = classes[ci]
        local cx = ui.buyCatExpanded[c.value] and true or false
        table.insert(flat, { kind = "class", class = c.value,
            name = c.text, expanded = cx })
        if cx then
            local subs = A.buy.SubclassOptions(c.value)
            local si = 1
            while si <= table.getn(subs) do
                local s = subs[si]
                local skey = c.value .. ":" .. s.value
                local slots = A.buy.SlotOptions(c.value, s.value)
                local canX = table.getn(slots) > 0
                local sx = (canX and ui.buyCatExpanded[skey]) and true or false
                table.insert(flat, { kind = "sub", class = c.value,
                    subclass = s.value, name = s.text,
                    expandable = canX, expanded = sx })
                if sx then
                    local li = 1
                    while li <= table.getn(slots) do
                        table.insert(flat, { kind = "slot", class = c.value,
                            subclass = s.value, slot = slots[li].value,
                            name = slots[li].text })
                        li = li + 1
                    end
                end
                si = si + 1
            end
        end
        ci = ci + 1
    end
    ui.buyCatFlat = flat
end

function ui.RefreshCatTree()
    if not ui.buyCatScroll or ui.buyMode == "advanced" then return end
    ui.FlattenCats()
    ui.UpdateCatTree()
end

function ui.UpdateCatTree()
    if not ui.buyCatScroll or ui.buyMode == "advanced" then return end
    local flat = ui.buyCatFlat or {}
    -- How many rows fit is not a division any more: plated and bare rows are
    -- different heights, so it depends on WHICH rows are about to be shown.
    -- The scroll offset is still counted in ROWS, which is what lets the
    -- FauxScrollFrame maths keep working with a ragged list.
    -- Same reason as the results table: measuring this frame returns whatever
    -- height it was last laid out at, which is why the tree stopped at
    -- "Quiver" on a window tall enough for all eleven categories.
    local avail = ui.CatAreaAt(
        (ui.frame and ui.frame.GetHeight and ui.frame:GetHeight()) or 0)
    if avail <= 0 then avail = SIDE_ROWS * SIDE_ROW_H end
    local offset = FauxScrollFrame_GetOffset(ui.buyCatScroll) or 0
    local function HeightOf(e)
        if e and (e.kind == "sub" or e.kind == "slot") then return SIDE_BARE_H end
        return SIDE_ROW_H
    end
    local vis, used = 0, 0
    while vis < SIDE_ROWS_MAX do
        local e = flat[vis + 1 + offset]
        if not e then break end
        local h = HeightOf(e)
        if used + h > avail then break end
        used = used + h
        vis = vis + 1
    end
    if vis < 1 then vis = 1 end
    ui.GrowCatRows(vis)
    ui.SkinNewRows(ui.buyCatRows)
    FauxScrollFrame_Update(ui.buyCatScroll, table.getn(flat), vis, SIDE_ROW_H)
    local i = 1
    while i <= table.getn(ui.buyCatRows) do
        local row = ui.buyCatRows[i]
        local e = (i <= vis) and flat[i + offset] or nil
        if e then
            row.entry = e
            -- TOP-LEVEL rows get a plate, children are bare indented text,
            -- and an EXPANDED row carries a minus glyph.
            --
            -- The glyphs were removed in ROADMAP 2l on the grounds that the
            -- stock 1.12 list signals expansion by highlighting the parent
            -- and showing its children. That works for ONE level. This tree
            -- has three -- Armor > Leather > Chest -- and highlight-alone
            -- cannot say which of two open levels you are in, or that Leather
            -- is open at all while Chest is the selected leaf. 2l is reversed
            -- here; see 2q.
            --
            -- Only EXPANDED rows are marked. A "+" on every collapsed row is
            -- noise, and the mockup does not draw one.
            local text, plated
            if e.kind == "all" then
                text, plated = e.name, true
            elseif e.kind == "class" then
                text, plated = e.name, true
                if e.expanded then text = "- " .. e.name end
            elseif e.kind == "sub" then
                text, plated = "    " .. e.name, false
                if e.expanded then text = "  - " .. e.name end
            else
                text, plated = "         " .. e.name, false
            end
            if plated then row.plate:Show() else row.plate:Hide() end

            -- Height and position, both decided here because both depend on
            -- what kind of row this is and what is above it.
            row:SetHeight(HeightOf(e))
            row:ClearAllPoints()
            if i == 1 then
                row:SetPoint("TOPLEFT", ui.buyCatScroll, "TOPLEFT", 0, 0)
            else
                row:SetPoint("TOPLEFT", ui.buyCatRows[i - 1], "BOTTOMLEFT", 0, 0)
            end

            ui.SetTextClipped(row.label, text, SIDE_W - 14)

            local key = ui.CatKey(e)
            local selected = (key == ui.buyCatSel)
            -- A parent also lights up while you are inside it, so the path
            -- you are browsing reads at a glance rather than only the leaf.
            if not selected and e.kind == "class" and e.expanded then
                selected = (ui.buyCatClass == e.class)
            end
            -- A selected LEAF is plain bright text with no bar, which is what
            -- the mockup shows for "Chest". The bar stays on plated rows,
            -- where it reads as "this whole category is what you are
            -- browsing" rather than as a highlight smeared across a word.
            local function edges(on)
                if not row.selEdge then return end
                local k = 1
                while k <= 4 do
                    if on then row.selEdge[k]:Show() else row.selEdge[k]:Hide() end
                    k = k + 1
                end
            end
            if selected then
                if plated then row.selTex:Show() else row.selTex:Hide() end
                edges(selected and plated)
                row.label:SetTextColor(1, 1, 1)
            else
                row.selTex:Hide()
                edges(false)
                -- Three dimming steps, as the mockup has: a plated top-level
                -- row is warm off-white, a subcategory is dimmer, and a third
                -- level (Head / Chest / Legs) dimmer still. One colour for
                -- everything unplated flattened two levels into one.
                if plated then
                    row.label:SetTextColor(C.text[1], C.text[2], C.text[3])
                elseif e.kind == "sub" then
                    row.label:SetTextColor(0.72, 0.66, 0.52)
                else
                    row.label:SetTextColor(0.55, 0.50, 0.40)
                end
            end
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
        i = i + 1
    end
end

-- Identity of a tree node, for selection highlighting.
function ui.CatKey(e)
    if not e or e.kind == "all" then return "all" end
    if e.kind == "class" then return "c" .. e.class end
    if e.kind == "sub" then return "c" .. e.class .. ":" .. e.subclass end
    return "c" .. e.class .. ":" .. e.subclass .. ":" .. e.slot
end

function ui.OnCatClick(e)
    if not e then return end
    if e.kind == "class" then
        ui.buyCatExpanded[e.class] = not ui.buyCatExpanded[e.class]
        ui.CatApply(e.class, nil, nil, e.name)
    elseif e.kind == "sub" then
        if e.expandable then
            local skey = e.class .. ":" .. e.subclass
            ui.buyCatExpanded[skey] = not ui.buyCatExpanded[skey]
        end
        ui.CatApply(e.class, e.subclass, nil, e.name)
    elseif e.kind == "slot" then
        ui.CatApply(e.class, e.subclass, e.slot, e.name)
    else
        ui.CatApply(nil, nil, nil, nil)
    end
    ui.buyCatSel = ui.CatKey(e)
    ui.RefreshCatTree()
end

-- A tree pick sets the category and re-runs the search.
--
-- The picked category is held as STATE rather than written into the Name
-- box, because in the default view that box is Blizzard's "Name" field and
-- nothing else. ui.DefaultTerm folds the two back together at search time,
-- which is what makes the Name field mean "within the selected category"
-- exactly as the stock UI does -- and why the level/quality/usable controls
-- keep applying across a category change instead of being wiped by it.
-- Set the browse selection. DOES NOT SEARCH.
--
-- It used to call DoBuySearch, so every click in the tree fired a full server
-- query -- selecting "Weapon" pulled every weapon on the auction house, and
-- merely EXPANDING a category did the same. Navigation should be free; the
-- Search button is what costs a round trip.
--
-- The results already on screen are left alone rather than cleared: they are
-- a real search someone asked for, and blanking the table on a fold click
-- would be worse than leaving it. What is not acceptable is silence about it,
-- so the status line says which selection is pending -- see ui.NotePendingCat.
function ui.CatApply(class, subclass, slot, label)
    if not A.buy then return end
    ui.buyCatClass, ui.buyCatSubclass, ui.buyCatSlot = class, subclass, slot
    ui.NotePendingCat(label)
end

-- Name the selection that Search would apply, so the rows above are not
-- mistaken for it.
-- `label` is the row's own display name, passed down from the click. The
-- class/subclass/slot values are numeric INDICES into the client's category
-- tables, so building a name from them here would print "1 selected".
function ui.NotePendingCat(label)
    if not ui.buyStatus then return end
    ui.buyCatPending = true
    if label and label ~= "" then
        ui.buyStatus:SetText(label .. " selected \226\128\148 press Search")
    else
        ui.buyStatus:SetText("All categories selected \226\128\148 press Search")
    end
end

-- ---- (shopping lists removed) -------------------------------------------
--
-- The Shopping Lists sidebar and its list-management popups are gone: the
-- concept has no left column in Advanced, and every entry point into these
-- functions went with the sidebar. The ENGINE side (buy.Lists / AddList /
-- AddItemToList and friends in core/buy.lua) is deliberately left in place
-- and still tested -- the saved data is untouched, so nothing a user built is
-- lost, and re-homing the feature later costs a UI, not a rewrite.

-- ---- search + results --------------------------------------------------

-- Cycle through autocomplete candidates for whatever's currently typed.
-- Re-bases off the live text on the FIRST Tab press for a given prefix (so it
-- always completes what you actually typed), then keeps cycling through the
-- same candidate list on repeated presses without re-querying it each time.
function ui.BuyAutocomplete()
    local acb = ui.ActiveSearchBox()
    if not acb or not A.buy then return end
    local cur = acb:GetText() or ""
    local ac = ui.buyAC
    if not ac or cur ~= ac.current then
        ac = { base = cur, candidates = A.buy.AutocompleteCandidates(cur),
               index = 0 }
        ui.buyAC = ac
    end
    local n = table.getn(ac.candidates)
    if n == 0 then return end
    ac.index = math.mod(ac.index, n) + 1
    local pick = ac.candidates[ac.index]
    acb:SetText(pick)
    ac.current = pick
    if acb.SetCursorPosition then
        acb:SetCursorPosition(string.len(pick))
    end
end

function ui.DoBuySearch()
    -- The pending-category note is answered by the search it was asking for.
    ui.buyCatPending = nil
    local sb = ui.ActiveSearchBox()
    if not sb then return end
    sb:ClearFocus()
    -- Any search shows its results. Running one while the form is up and
    -- leaving the form covering the answer would be its own small bug.
    if ui.buyView ~= "results" then ui.SetBuyView("results") end
    if not A.buy then
        ui.buyStatus:SetText("Buy engine not loaded \226\128\148 fully restart WoW.")
        return
    end
    -- DEFAULT mode searches the composed term (control strip + the category
    -- the tree has selected); ADVANCED searches the query box verbatim.
    local name
    if ui.buyMode == "advanced" then
        name = util.Trim((ui.buyQueryBox and ui.buyQueryBox:GetText()) or "")
    else
        name = A.buy.TermToQuery(ui.DefaultTerm())
    end
    ui.buyResults = nil
    ui.buySel = nil            -- the rows are about to be replaced
    ui.RefreshBuyActionBar()
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
end

function ui.RefreshBuyStatus()
    if not ui.buyStatus or not A.buy then return end
    if ui.buyView == "saved" or ui.buyView == "builder" then return end
    local phase = A.buy.state.phase
    if phase == "wait_query" or phase == "wait_results" then
        ui.buyStatus:SetText("Searching...")
    end
end

function ui.RefreshBuy()
    if not ui.buyBuilt then return end
    if ui.buyMode ~= "advanced" then
        ui.RefreshCatTree()
    else
        end
    if ui.buyView == "builder" then
        -- The builder owns this space right now; repainting the results list
        -- would un-hide its rows over the top of the form.
        ui.RefreshBuilder()
    else
        ui.UpdateBuyList()
    end
end

function ui.UpdateBuyList()
    if not ui.buyScroll then return end
    -- The results table only ever paints while the RESULTS view owns the
    -- space. Guarding the view SWITCH is not enough: a search fires
    -- onResults/onState asynchronously, so rows arriving while Saved or
    -- Builder is up would Show() straight through them -- two views'
    -- rows interleaved on screen. Third time this shape has bitten (the
    -- shopping sidebar, then the pager), so the guard lives in the paint.
    if ui.buyView == "saved" or ui.buyView == "builder" then return end
    local all = ui.buyResults or {}

    -- Working copy (so sorting doesn't disturb the engine's row order), with
    -- the Max-price filter (per-unit) applied and the chosen column sort.
    --
    -- Max belongs to ADVANCED mode. Reading it in the default view would let a
    -- value typed there keep narrowing results after the box itself was
    -- hidden -- an invisible filter, which is precisely the failure the empty
    -- "No auctions found" fix exists to prevent. Advanced has `max-unit-buy`.
    -- The Max box is gone (not in the concept). Its job is the
    -- `max-unit-buy` post-filter component, which lives in the query where
    -- it is visible and saveable rather than in a box you can leave set.
    local maxUnit = nil
    local sortKey = ui.buySortKey or "unit"
    local dir = ui.buySortDir or "asc"
    local rows = ui.SortResults(all, sortKey, dir, maxUnit)
    ui.PaintSortHeaders(ui.buyHeaders, sortKey, dir)

    local total = table.getn(rows)
    -- Row count comes from the same arithmetic that POSITIONS the box, not
    -- from measuring the scroll frame -- see ui.PanelHeightAt for why a
    -- measurement is unreliable here. Whole rows only: nothing clips a
    -- partial one, it would simply draw over the match-count line.
    local vis = ui.TableRowsAt(
        (ui.frame and ui.frame.GetHeight and ui.frame:GetHeight()) or 0)
    ui.GrowBuyRows(vis)
    ui.SkinNewRows(ui.buyRows)
    FauxScrollFrame_Update(ui.buyScroll, total, vis, BUY_ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.buyScroll)

    if A.buy then
        local _, page, totalPages, totalAuctions, termIndex, totalTerms, stats =
            A.buy.GetResults()
        local unknown = stats and stats.unknownStack or 0
        -- Rows a post-filter could not JUDGE, as opposed to rows that did not
        -- match: seller before the owner names resolve, time left on a server
        -- that does not answer for it. Same confession the unknown-stack path
        -- makes, and for the same reason -- an unexplained empty page reads as
        -- a broken filter.
        local blind, blindWho, blindFix = A.buy.UnansweredSummary(stats)
        local blindNote = ""
        if blind > 0 then
            -- The REMEDY comes from the engine, per component. "Search again"
            -- is right for a seller name and wrong for a vendor price -- that
            -- one is only learned at a merchant, so the advice would send
            -- someone round a loop that cannot succeed. When two causes want
            -- two different cures, no advice is offered at all.
            blindNote = " \226\128\162 " .. blind .. " skipped (no "
                .. blindWho .. " data"
            if blindFix then
                blindNote = blindNote .. " \226\128\148 " .. blindFix
            end
            blindNote = blindNote .. ")"
        end
        -- A pending category note owns the status line until the search it
        -- asks for actually runs. Repainting the list must not answer a
        -- question nobody has pressed Search on yet.
        if ui.buyResults and not ui.buyCatPending then
            local usedPageMax = stats and stats.usedPageMax
            if table.getn(all) == 0 then
                if unknown > 0 then
                    -- Never a bare "No auctions found" when a filter threw rows
                    -- away for want of data: an unexplained empty page is
                    -- indistinguishable from a broken filter, which is exactly
                    -- how /stack got reported.
                    ui.buyStatus:SetText("No full stacks \226\128\162 " .. unknown
                        .. " skipped (stack size unknown \226\128\148 search again)")
                elseif totalAuctions and totalAuctions > 0 then
                    -- The server DID match auctions; the post-filter (exact,
                    -- stack size, buyout, tooltip) removed every one on this
                    -- page. Same rule as above: an emptied page must say a
                    -- filter emptied it -- a bare "No auctions found" here
                    -- reads as a broken filter, and hides that another page
                    -- may still hold matches.
                    local t = "0 match(es) (of " .. totalAuctions .. ") \226\128\162 "
                        .. "filters removed this page's rows"
                    -- WHICH filter, when it was one that could not answer.
                    -- "filters removed this page's rows" is true but useless
                    -- if the real reason is that no owner name had arrived
                    -- yet and searching again would fix it.
                    t = t .. blindNote
                    if totalPages and totalPages > 1 then
                        t = t .. " \226\128\162 try the next page"
                    end
                    ui.buyStatus:SetText(t)
                else
                    ui.buyStatus:SetText("No auctions found.")
                end
            else
                local order = dir == "asc" and "low to high" or "high to low"
                local shown = ""
                if maxUnit and maxUnit > 0 then
                    shown = " \226\128\162 " .. total .. " under max"
                end
                -- `all` is already query-filtered (buyout-only, exact, tooltip
                -- -- see buy.ReadPage's post-filter); totalAuctions is the raw
                -- Blizzard count for this page's query, which can be bigger
                -- once a filter is active. Showing both keeps the bigger
                -- number from reading as "how many I can buy".
                local headline = table.getn(all) .. " match(es)"
                if table.getn(all) ~= totalAuctions then
                    headline = headline .. " (of " .. totalAuctions .. ")"
                end
                if usedPageMax then
                    -- Say which rule produced these rows: "biggest on this
                    -- page" is not the same promise as "a full stack", and
                    -- quietly swapping one for the other would be worse than
                    -- the dead end it replaced.
                    shown = shown .. " \226\128\162 biggest on this page"
                end
                if unknown > 0 then
                    shown = shown .. " \226\128\162 " .. unknown
                        .. " skipped (stack size unknown)"
                end
                shown = shown .. blindNote
                ui.buyStatus:SetText(headline .. " \226\128\162 "
                    .. sortKey .. " " .. order .. shown)
            end
            local pageTxt = "Page " .. (page + 1) .. " / " .. totalPages
            -- Multiple semicolon-separated OR terms browse as one combined
            -- search (NextPage/PrevPage roll across term boundaries), so the
            -- pager names which term you're currently on -- but only when
            -- there's more than one, so the common single-term case looks
            -- exactly as it always has.
            if totalTerms and totalTerms > 1 then
                pageTxt = "Term " .. termIndex .. "/" .. totalTerms
                    .. "  \226\128\162  " .. pageTxt
            end
            ui.buyPageText:SetText(pageTxt)
        else
            ui.buyPageText:SetText("")
        end
    end

    local i = 1
    while i <= table.getn(ui.buyRows) do
        local row = ui.buyRows[i]
        local r = (i <= vis) and rows[i + offset] or nil
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
    ui.buySortKey, ui.buySortDir =
        ui.NextSort(ui.buySortKey, ui.buySortDir, key)
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

-- ONE dialog for the whole batch, not one per item. A per-item prompt for a
-- twelve-auction buyout trains you to click through without reading, which
-- defeats the point of confirming at all.
StaticPopupDialogs["AEGIS_EXCHANGE_BUYOUT_BATCH"] = {
    text = "Buy %s?\n%s",
    button1 = "Buy all", button2 = "Cancel",
    OnAccept = function() ui.DoBatchBuyout() end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

function ui.ConfirmBatchBuyout()
    local sel = ui.buyChecked or {}
    local n = table.getn(sel)
    if n == 0 then return end
    local total, buyable = A.buy.BatchCost(sel)
    if buyable == 0 then
        ChatMsg("Aegis: nothing selected has a buyout price.")
        return
    end
    local money = GetMoney and GetMoney() or 0
    if total > money then
        ChatMsg("Aegis: that selection costs "
            .. util.FormatMoney(total) .. " and you have "
            .. util.FormatMoney(money) .. ".")
        return
    end
    -- Spell out the warning rather than relying on the button label. This
    -- spends real gold on several auctions at once and cannot be undone.
    local detail = string.format(
        "Total %s, leaving %s.\n\nThis buys all %d immediately and cannot be undone.",
        util.FormatMoney(total), util.FormatMoney(money - total), buyable)
    StaticPopup_Show("AEGIS_EXCHANGE_BUYOUT_BATCH",
        buyable .. " auction(s)", detail)
end

function ui.DoBatchBuyout()
    local sel = ui.buyChecked or {}
    if table.getn(sel) == 0 then return end
    local ok, err = A.buy.StartBatch(sel,
        function(bought, want, spent, reason)
            -- Record what ACTUALLY completed, item by item, so the History
            -- tab and the ledger agree with the gold that left the bag even
            -- when the batch stopped early.
            ui.ClearBuyChecks()
            if reason then
                ChatMsg("Aegis: bought " .. bought .. " of " .. want
                    .. " \226\128\148 " .. reason)
            else
                ChatMsg("Aegis: bought " .. bought .. " auction(s) for "
                    .. util.FormatMoney(spent) .. ".")
            end
            ui.UpdateBuyList()
            ui.RefreshBuyActionBar()
            ui.RefreshBuyMoney()
            if ui.selectedSubTab == "History" then ui.RefreshHistory() end
        end,
        function(bought, want, name, price)
            -- Booked per purchase, not once at the end: a batch that aborts
            -- halfway has still spent the gold on what it did buy, and the
            -- ledger has to match the bag.
            if name then A.db.RecordTxn("buy", name, price) end
            if ui.buyCheckTotal then
                ui.buyCheckTotal:SetText("Buying " .. bought .. " / " .. want
                    .. " \226\128\166")
                ui.buyCheckTotal:Show()
            end
        end)
    if not ok then ChatMsg("Aegis: " .. (err or "buyout failed.")) end
end

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
        -- Log the spend for the History tab.
        A.db.RecordTxn("buy", row.name, row.buyout, row.itemId)
        ChatMsg("Aegis: bought " .. row.name .. " x" .. row.count .. ".")
        if ui.selectedSubTab == "History" then ui.RefreshHistory() end
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
local CRAFT_ROWS_MAX  = 34
local CSIDE_ROWS,  CSIDE_ROW_H  = 10, 18
local CSIDE_ROWS_MAX  = 38
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
    sideScroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -LISTBOX.craftSide.top)
    sideScroll:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10,
        LISTBOX.craftSide.bot)
    sideScroll:SetWidth(CSIDE_W)
    sideScroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(CSIDE_ROW_H, ui.UpdateCraftTree)
    end)
    ui.craftSideScroll = sideScroll

    ui.craftSideRows = {}
ui.GrowCraftSideRows = function(n)
        if n > CSIDE_ROWS_MAX then n = CSIDE_ROWS_MAX end
        -- Built on demand: a minimum-size window costs exactly what it
        -- did before, and dragging taller adds only the rows needed.
        local i = table.getn(ui.craftSideRows) + 1
        while i <= n do
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
    end
    ui.GrowCraftSideRows(CSIDE_ROWS)

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
    local priceBtn = ui.MakeButton(panel, "quiet", "AegisExchangeCraftPriceButton")
    priceBtn:SetWidth(CSIDE_W); priceBtn:SetHeight(18)
    priceBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 42)
    priceBtn:SetText("Price recipe")
    priceBtn:SetScript("OnClick", function() ui.CraftPriceRecipe() end)
    ui.craftPriceBtn = priceBtn

    -- Delete the selected recipe.
    local delBtn = ui.MakeButton(panel, "quiet", "AegisExchangeCraftDelButton")
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
    local searchBtn = ui.MakeButton(panel, "primary", "AegisExchangeCraftSearchButton")
    searchBtn:SetWidth(64); searchBtn:SetHeight(20)
    searchBtn:SetPoint("LEFT", box, "RIGHT", 10, 0)
    searchBtn:SetText("Search")
    searchBtn:SetScript("OnClick", function() ui.DoCraftSearch() end)

    -- Pager (mirrors the Buy tab).
    local nextBtn = ui.MakeButton(panel, "quiet", "AegisExchangeCraftNextButton")
    nextBtn:SetWidth(24); nextBtn:SetHeight(20)
    nextBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -34)
    nextBtn:SetText(">")
    nextBtn:SetScript("OnClick", function() if A.buy then A.buy.NextPage() end end)

    ui.craftPageText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.craftPageText:SetPoint("RIGHT", nextBtn, "LEFT", -6, 0)
    ui.craftPageText:SetJustifyH("RIGHT")
    ui.craftPageText:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])

    local prevBtn = ui.MakeButton(panel, "quiet", "AegisExchangeCraftPrevButton")
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

    -- Every column sorts (see ui.MakeSortHeaders); headers stay unskinned.
    ui.craftHeaders = ui.MakeSortHeaders(panel, rowLeft, -76, CX, CW,
        function(key) ui.SetCraftSort(key) end)

    local scroll = CreateFrame("ScrollFrame", "AegisExchangeCraftScroll",
        panel, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", rowLeft, -LISTBOX.craft.top)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, LISTBOX.craft.bot)
    scroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(CRAFT_ROW_H, ui.UpdateCraftList)
    end)
    ui.craftScroll = scroll

    ui.craftRows = {}
ui.GrowCraftRows = function(n)
        if n > CRAFT_ROWS_MAX then n = CRAFT_ROWS_MAX end
        -- Built on demand: a minimum-size window costs exactly what it
        -- did before, and dragging taller adds only the rows needed.
        local i = table.getn(ui.craftRows) + 1
        while i <= n do
            BuildResultRow(panel, scroll, ui.craftRows, i, CRAFT_ROW_H)
            i = i + 1
        end
    end
    ui.GrowCraftRows(CRAFT_ROWS)

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
    local vis = ui.ListRowsAt(ui.WindowH(), LISTBOX.craftSide,
        CSIDE_ROW_H, CSIDE_ROWS_MAX)
    ui.GrowCraftSideRows(vis)
    ui.SkinNewRows(ui.craftSideRows)
    FauxScrollFrame_Update(ui.craftSideScroll, table.getn(flat),
        vis, CSIDE_ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.craftSideScroll)
    local i = 1
    while i <= table.getn(ui.craftSideRows) do
        local row = ui.craftSideRows[i]
        local e = (i <= vis) and flat[i + offset] or nil
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
    ui.craftSortKey, ui.craftSortDir =
        ui.NextSort(ui.craftSortKey, ui.craftSortDir, key)
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
    local vis = ui.ListRowsAt(ui.WindowH(), LISTBOX.craft,
        CRAFT_ROW_H, CRAFT_ROWS_MAX)
    ui.GrowCraftRows(vis)
    ui.SkinNewRows(ui.craftRows)
    FauxScrollFrame_Update(ui.craftScroll, total, vis, CRAFT_ROW_H)
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
    while i <= table.getn(ui.craftRows) do
        local row = ui.craftRows[i]
        local r = (i <= vis) and rows[i + offset] or nil
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
function ui.AttachCraftButton(frame, name, anchorNames)
    if not frame or getglobal(name) then return end
    local b = ui.MakeButton(frame, "quiet", name)
    b:SetWidth(96); b:SetHeight(20)
    -- Anchor to the window's OWN Exit/Create button, not to the frame corner.
    -- Same principle as the pfUI header fix: anchor to something that moves
    -- with the skin. The stock profession window's BOTTOMRIGHT sits out under
    -- its thick ornate border art, so -16,46 landed the button (and the profit
    -- lines stacked above it) outside the panel; pfUI's border is a hairline,
    -- which is why it only ever looked right when skinned. The Exit button is
    -- inside the content area in both.
    local anchor = nil
    if anchorNames then
        local i = 1
        while i <= table.getn(anchorNames) and not anchor do
            anchor = getglobal(anchorNames[i])
            i = i + 1
        end
    end
    if anchor then
        -- Pulled 10px LEFT of the Exit button's right edge rather than flush
        -- with it. "Add to Aegis" is wider than Exit, and its template's border
        -- art overhangs its logical bounds, so a flush right edge clipped the
        -- window frame in both UIs. The profit lines stack off this button, so
        -- they inset with it.
        b:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", -10, 8)
    else
        -- Unknown window layout: fall back well inside the frame rather than
        -- on top of its border.
        b:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -40, 60)
    end
    b:SetText("Add to Aegis")
    b:SetScript("OnClick", function() ui.CraftCapture() end)
    if A.skin then A.skin.ApplyExternal() end
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
        sub:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -40, 88)
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
        ui.AttachCraftButton(TradeSkillFrame, "AegisExchangeAddTradeSkillButton",
            { "TradeSkillCancelButton", "TradeSkillCreateButton" })
        ui.AttachProfLine(TradeSkillFrame,
            "AegisExchangeAddTradeSkillButton", "tradeskill")
    end
    if CraftFrame then
        ui.AttachCraftButton(CraftFrame, "AegisExchangeAddCraftButton",
            { "CraftCancelButton", "CraftCreateButton" })
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
local AUC_ROWS_MAX = 32
-- Row-relative column x / width.
local ACX = { name = 2, qty = 176, unit = 216, stack = 300, time = 392,
              mkt = 452, cancel = 540 }
local ACW = { name = 172, qty = 34, unit = 80, stack = 88, time = 56, mkt = 84 }
-- Numeric columns are right-justified in the rows, so their headers sit over
-- the RIGHT edge of the cells -- ui.MakeSortHeaders does that from `just`.
-- Left-aligning the header of a right-aligned column is what makes a table
-- look assembled rather than designed.
local AUC_HEADER_DEFS = {
    { key = "name",  text = "Item" },
    { key = "qty",   text = "Qty" },
    { key = "unit",  text = "Unit" },
    { key = "stack", text = "Buyout" },
    { key = "time",  text = "Time" },
    { key = "mkt",   text = "vs market" },
}

function ui.BuildAuctionsTab()
    local panel = ui.panels["Auctions"]
    if not panel or ui.aucBuilt then return end
    ui.aucBuilt = true

    -- Summary + refresh.
    ui.aucSummary = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.aucSummary:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -12)
    ui.aucSummary:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    ui.aucSummary:SetText("Your auctions")

    local refresh = ui.MakeButton(panel, "quiet", "AegisExchangeAucRefreshButton")
    refresh:SetWidth(72); refresh:SetHeight(20)
    refresh:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -10)
    refresh:SetText("Refresh")
    refresh:SetScript("OnClick", function() ui.RefreshAuctions(true) end)

    -- Clear out everything you've been undercut on in one go.
    local cancelAll = ui.MakeButton(panel, "quiet", "AegisExchangeAucCancelAllButton")
    cancelAll:SetWidth(132); cancelAll:SetHeight(20)
    cancelAll:SetPoint("RIGHT", refresh, "LEFT", -6, 0)
    cancelAll:SetText("Cancel all undercuts")
    cancelAll:SetScript("OnClick", function() ui.ConfirmCancelAllUndercut() end)
    ui.aucCancelAllBtn = cancelAll

    ui.aucStatus = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.aucStatus:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -34)
    ui.aucStatus:SetJustifyH("LEFT")
    ui.aucStatus:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])

    -- Column headers -- CLICKABLE, through the same builder the Buy and
    -- Crafting tables use. They were bare grey text before, which read as a
    -- disabled band rather than as the table's headings and could not be
    -- pressed at all.
    ui.aucSortKey = "unit"
    ui.aucSortDir = "asc"
    local rowLeft = 6
    ui.aucHeaders = ui.MakeSortHeaders(panel, rowLeft, -54, ACX, ACW,
        function(key) ui.SetAucSort(key) end, AUC_HEADER_DEFS)

    local scroll = CreateFrame("ScrollFrame", "AegisExchangeAucScroll",
        panel, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", rowLeft, -LISTBOX.auc.top)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, LISTBOX.auc.bot)
    scroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(AUC_ROW_H, ui.UpdateAuctionsList)
    end)
    ui.aucScroll = scroll

    ui.aucRows = {}
ui.GrowAucRows = function(n)
        if n > AUC_ROWS_MAX then n = AUC_ROWS_MAX end
        -- Built on demand: a minimum-size window costs exactly what it
        -- did before, and dragging taller adds only the rows needed.
        local i = table.getn(ui.aucRows) + 1
        while i <= n do
            local row = CreateFrame("Frame", nil, panel)
            row:SetHeight(AUC_ROW_H)
            if i == 1 then
                row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
                row:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, 0)
            else
                row:SetPoint("TOPLEFT", ui.aucRows[i - 1], "BOTTOMLEFT", 0, 0)
                row:SetPoint("TOPRIGHT", ui.aucRows[i - 1], "BOTTOMRIGHT", 0, 0)
            end
            -- Before the cells: the chrome is BACKGROUND and creation order
            -- is draw order within a layer. No selection tint -- an auction
            -- row is acted on by its own Cancel button, not by being picked.
            ui.AddRowChrome(row, i)
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
            local cancel = ui.MakeButton(row, "quiet")
            cancel:SetWidth(64); cancel:SetHeight(18)
            cancel:SetPoint("LEFT", row, "LEFT", ACX.cancel, 0)
            cancel:SetText("Cancel")
            cancel:SetScript("OnClick", function()
                if row.entry then ui.ConfirmCancelAuction(row.entry) end
            end)
            row.cancelBtn = cancel
            -- Hover tooltip, read from the "owner" list rather than "list".
            row:EnableMouse(true)
            row:SetScript("OnEnter", function()
                local r = row.entry
                if not r then return end
                GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
                local shown = false
                if r.index and GameTooltip.SetAuctionItem then
                    shown = pcall(function()
                        GameTooltip:SetAuctionItem("owner", r.index)
                    end)
                end
                if not shown then GameTooltip:SetText(r.name or "") end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row:Hide()
            ui.aucRows[i] = row
            i = i + 1
        end
    end
    ui.GrowAucRows(AUC_ROWS)
end

function ui.SetAucSort(key)
    ui.aucSortKey, ui.aucSortDir =
        ui.NextSort(ui.aucSortKey, ui.aucSortDir, key)
    ui.UpdateAuctionsList()
end

-- Order your own auctions by the chosen column.
--
-- `mkt` sorts by how far ABOVE the cheapest known listing each one is, so
-- ascending puts the auctions that are still lowest first and descending puts
-- the ones you have been undercut hardest on at the top -- which is the
-- question this column exists to answer. An item the price DB has never seen
-- has no answer and sinks, the same way a bid-only row does.
function ui.SortAuctions(all, sortKey, dir)
    local function keyOf(r)
        if sortKey == "name" then return string.lower(r.name or "")
        elseif sortKey == "qty" then return r.count
        elseif sortKey == "stack" then
            return (r.buyout and r.buyout > 0) and r.buyout or nil
        elseif sortKey == "time" then return r.timeLeft
        elseif sortKey == "mkt" then
            local m = r.itemId and A.db.MinBuyout(r.itemId)
            if m and m > 0 and r.unit then return r.unit / m end
            return nil
        end
        return r.unit
    end
    return ui.SortByKey(all, keyOf, dir)
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
    local sortKey = ui.aucSortKey or "unit"
    local dir = ui.aucSortDir or "asc"
    local rows = ui.SortAuctions(ui.aucAuctions or {}, sortKey, dir)
    ui.PaintSortHeaders(ui.aucHeaders, sortKey, dir)
    local total = table.getn(rows)

    local cap = A.sell.CAP or 120
    ui.aucSummary:SetText("Your auctions: " .. total .. " / " .. cap)

    -- Label the bulk-cancel with how many are actually undercut, and disable it
    -- when there's nothing to do.
    if ui.aucCancelAllBtn then
        local nUnder = table.getn(ui.UndercutAuctions())
        if nUnder > 0 then
            ui.aucCancelAllBtn:SetText("Cancel " .. nUnder .. " undercut")
            ui.aucCancelAllBtn:Enable()
        else
            ui.aucCancelAllBtn:SetText("No undercuts")
            ui.aucCancelAllBtn:Disable()
        end
    end
    if total == 0 then
        ui.aucStatus:SetText("No active auctions. Post some on the Sell tab.")
    else
        ui.aucStatus:SetText("Cancel refunds the item (deposit is forfeit)."
            .. "  Undercut = someone is cheaper than you.")
    end

    local vis = ui.ListRowsAt(ui.WindowH(), LISTBOX.auc,
        AUC_ROW_H, AUC_ROWS_MAX)
    ui.GrowAucRows(vis)
    ui.SkinNewRows(ui.aucRows)
    FauxScrollFrame_Update(ui.aucScroll, total, vis, AUC_ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.aucScroll)
    local i = 1
    while i <= table.getn(ui.aucRows) do
        local row = ui.aucRows[i]
        local r = (i <= vis) and rows[i + offset] or nil
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
    -- The Aegis tab can turn the confirmation off, which is what you want when
    -- clearing a pile of undercuts by hand.
    if A.db.Setting("confirmCancel") == false then
        ui.DoCancelAuction()
        return
    end
    StaticPopup_Show("AEGIS_EXCHANGE_CANCEL", r.name .. " (x" .. r.count .. ")")
end

-- ---- cancel every undercut auction --------------------------------------

-- Auctions of ours that someone is currently beating on unit price.
function ui.UndercutAuctions()
    local out = {}
    local rows = ui.aucAuctions or {}
    local i = 1
    while i <= table.getn(rows) do
        local r = rows[i]
        local mkt = r.itemId and A.db.MinBuyout(r.itemId)
        if mkt and mkt > 0 and r.unit and r.unit > mkt then
            table.insert(out, r)
        end
        i = i + 1
    end
    return out
end

StaticPopupDialogs["AEGIS_EXCHANGE_CANCELALL"] = {
    text = "Cancel %s?\n%s\nThe items return by mail; deposits are lost.",
    button1 = "Cancel them", button2 = "Keep",
    OnAccept = function() ui.DoCancelAllUndercut() end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

function ui.ConfirmCancelAllUndercut()
    local rows = ui.UndercutAuctions()
    local n = table.getn(rows)
    if n == 0 then
        ChatMsg("Aegis: nothing of yours is undercut.")
        return
    end
    if A.db.Setting("confirmCancel") == false then
        ui.DoCancelAllUndercut()
        return
    end
    local names, i = {}, 1
    while i <= n and i <= 4 do
        table.insert(names, rows[i].name .. " x" .. rows[i].count)
        i = i + 1
    end
    local detail = table.concat(names, ", ")
    if n > 4 then detail = detail .. ", +" .. (n - 4) .. " more" end
    StaticPopup_Show("AEGIS_EXCHANGE_CANCELALL",
        n .. " undercut auction(s)", detail)
end

-- Cancel them from the HIGHEST owner index down: cancelling shifts every later
-- index down by one, so walking upward would skip auctions.
function ui.DoCancelAllUndercut()
    local rows = ui.UndercutAuctions()
    local n = table.getn(rows)
    if n == 0 then return end
    table.sort(rows, function(a, b) return a.index > b.index end)
    local done = 0
    local i = 1
    while i <= n do
        if A.sell.CancelOwnerAuction(rows[i].index) then done = done + 1 end
        i = i + 1
    end
    ChatMsg("Aegis: cancelled " .. done .. " undercut auction(s).")
    ui.RefreshAuctions(true)
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
-- History tab: sales income (from the mailbox) + purchases (from the Buy tab),
-- with totals over a selectable window.
-- ---------------------------------------------------------------------------

-- Row-relative column x / width, at file scope because the headers, the row
-- cells and the sort all have to agree about them. They were three separate
-- sets of numbers -- a local HCX for the headers, literal widths in the row
-- builder, and no sort at all.
local HCX = { when = 2, kind = 92, item = 176, amount = 470 }
local HCW = { when = 86, kind = 80, item = 290, amount = 96 }
local HIST_HEADER_DEFS = {
    { key = "when",   text = "When" },
    { key = "kind",   text = "Type" },
    { key = "item",   text = "Item" },
    { key = "amount", text = "Amount", just = "RIGHT" },
}

local HIST_ROWS, HIST_ROW_H = 12, 20
local HIST_ROWS_MAX = 34
-- Period options: label + window seconds (0 = all time).
local HIST_PERIODS = {
    { label = "24h", secs = 86400 },
    { label = "7d",  secs = 7 * 86400 },
    { label = "30d", secs = 30 * 86400 },
    { label = "All", secs = 0 },
}

-- Pull the item name out of an AH "sold" mail subject. enUS: the subject is
-- "Auction successful: <item>". Returns the item name, or nil for other mail.
local function AuctionSoldItem(subject)
    if not subject then return nil end
    local s, e = string.find(subject, "Auction successful: ", 1, true)
    if s == 1 then return string.sub(subject, e + 1) end
    return nil
end

-- Scan the open mailbox for AH sale mails and log each one once (deduped by an
-- approximate arrival time so the same mail isn't re-counted across sessions).
function ui.ScanMailSales()
    -- Stand down when a companion addon (Aegis: Courier) owns the mailbox.
    -- Two scanners on one inbox means two hooks racing and sales counted
    -- twice; Courier reads mail far more thoroughly, so it wins. See the
    -- integration block in core/db.lua.
    if A.MailScanningExternal and A.MailScanningExternal() then return end
    if not GetInboxNumItems then return end
    local n = GetInboxNumItems() or 0
    local i = 1
    while i <= n do
        local _, _, sender, subject, money, _, daysLeft = GetInboxHeaderInfo(i)
        local item = AuctionSoldItem(subject)
        if item and money and money > 0 then
            -- Key built through the shared helper, which Courier also calls --
            -- that is what stops a mail Aegis already logged from being
            -- re-counted when Courier takes over.
            local key = A.MailTxnKey(subject, money, daysLeft)
            if not A.db.WasSeen(key) then
                A.db.MarkSeen(key)
                A.db.RecordTxn("sale", item, money)
            end
        end
        i = i + 1
    end
    if ui.selectedSubTab == "History" then ui.RefreshHistory() end
end

function ui.BuildHistoryTab()
    local panel = ui.panels["History"]
    if not panel or ui.histBuilt then return end
    ui.histBuilt = true
    ui.histPeriod = 2   -- default to 7d

    -- Period buttons.
    local perLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    perLbl:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -14)
    perLbl:SetText("Period:")
    perLbl:SetTextColor(C.text[1], C.text[2], C.text[3])

    ui.histPerBtns = {}
    local prev = nil
    local pi = 1
    while pi <= table.getn(HIST_PERIODS) do
        local b = ui.MakeButton(panel, "quiet")
        b:SetWidth(44); b:SetHeight(20)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else b:SetPoint("LEFT", perLbl, "RIGHT", 8, 0) end
        b:SetText(HIST_PERIODS[pi].label)
        b.idx = pi
        b:SetScript("OnClick", function()
            ui.histPeriod = b.idx
            ui.RefreshHistory()
        end)
        ui.histPerBtns[pi] = b
        prev = b
        pi = pi + 1
    end

    local clearBtn = ui.MakeButton(panel, "quiet")
    clearBtn:SetWidth(100); clearBtn:SetHeight(20)
    clearBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -12)
    clearBtn:SetText("Clear history")
    clearBtn:SetScript("OnClick", function()
        StaticPopup_Show("AEGIS_EXCHANGE_CLEARLEDGER")
    end)

    -- Totals line.
    ui.histTotals = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.histTotals:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -42)
    ui.histTotals:SetJustifyH("LEFT")

    ui.histNote = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.histNote:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -62)
    ui.histNote:SetJustifyH("LEFT")
    ui.histNote:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
    ui.histNote:SetText("Sales are logged from your mailbox; buys from the Buy tab.")

    -- Column headers -- clickable, through the shared builder.
    --
    -- The default is `when` DESCENDING, which is the order the list has
    -- always been built in (most recent first). Making it the sort's default
    -- rather than a fixed reversal is what lets it be changed at all.
    ui.histCols = HCX
    local rowLeft = 6
    ui.histSortKey = "when"
    ui.histSortDir = "desc"
    ui.histHeaders = ui.MakeSortHeaders(panel, rowLeft, -84, HCX, HCW,
        function(key) ui.SetHistSort(key) end, HIST_HEADER_DEFS)

    local scroll = CreateFrame("ScrollFrame", "AegisExchangeHistScroll",
        panel, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", rowLeft, -LISTBOX.hist.top)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, LISTBOX.hist.bot)
    scroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(HIST_ROW_H, ui.UpdateHistoryList)
    end)
    ui.histScroll = scroll

    ui.histRows = {}
ui.GrowHistRows = function(n)
        if n > HIST_ROWS_MAX then n = HIST_ROWS_MAX end
        -- Built on demand: a minimum-size window costs exactly what it
        -- did before, and dragging taller adds only the rows needed.
        local i = table.getn(ui.histRows) + 1
        while i <= n do
            local row = CreateFrame("Frame", nil, panel)
            row:SetHeight(HIST_ROW_H)
            if i == 1 then
                row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
                row:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, 0)
            else
                row:SetPoint("TOPLEFT", ui.histRows[i - 1], "BOTTOMLEFT", 0, 0)
                row:SetPoint("TOPRIGHT", ui.histRows[i - 1], "BOTTOMRIGHT", 0, 0)
            end
            -- No selection tint and no tick column: a ledger line is a
            -- record, and there is nothing to select one FOR.
            ui.AddRowChrome(row, i)
            local mk = function(cx, w, just)
                local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                fs:SetPoint("LEFT", row, "LEFT", cx, 0)
                fs:SetWidth(w); fs:SetJustifyH(just or "LEFT")
                return fs
            end
            row.when   = mk(HCX.when, HCW.when)
            row.kind   = mk(HCX.kind, HCW.kind)
            row.item   = mk(HCX.item, HCW.item)
            row.amount = mk(HCX.amount, HCW.amount, "RIGHT")
            row:Hide()
            ui.histRows[i] = row
            i = i + 1
        end
    end
    ui.GrowHistRows(HIST_ROWS)
end

function ui.RefreshHistory()
    if not ui.histBuilt then return end
    -- Highlight the active period button.
    ui.MarkChosen(ui.histPerBtns, function(b) return b.idx == ui.histPeriod end)

    local secs = HIST_PERIODS[ui.histPeriod].secs
    local since = (secs > 0) and (time() - secs) or nil
    local income, spend = A.db.LedgerTotals(since)
    local net = income - spend
    local netColor
    if net >= 0 then netColor = "|cff4cd94c" else netColor = "|cffe64c4c" end
    ui.histTotals:SetText(
        "Income " .. util.FormatMoney(income, true)
        .. "   Spent " .. util.FormatMoney(spend, true)
        .. "   Net " .. netColor .. util.FormatMoney(math.abs(net), true) .. "|r")

    -- Build the display list within the window, in LEDGER order. The reversal
    -- that used to live here is now the sort's default (`when` descending), so
    -- clicking a header can actually change the order -- reversing here as
    -- well would have fought it.
    local led = A.db.Ledger()
    ui.histView = {}
    local i = 1
    while i <= table.getn(led) do
        local e = led[i]
        if not since or (e.t and e.t >= since) then
            table.insert(ui.histView, e)
        end
        i = i + 1
    end
    ui.UpdateHistoryList()
end

function ui.SetHistSort(key)
    ui.histSortKey, ui.histSortDir =
        ui.NextSort(ui.histSortKey, ui.histSortDir, key)
    ui.UpdateHistoryList()
end

-- Order the ledger view by the chosen column.
--
-- `amount` sorts by MAGNITUDE, which is what the column shows: the sign is
-- carried by Sold/Bought in the Type column, and mixing a 40g sale with a 40g
-- purchase into +40 and -40 would put the two furthest apart when they are
-- the same size of transaction.
function ui.SortHistory(all, sortKey, dir)
    local function keyOf(e)
        if sortKey == "kind" then return string.lower(e.kind or "")
        elseif sortKey == "item" then return string.lower(e.item or "")
        elseif sortKey == "amount" then return e.amount
        end
        return e.t
    end
    return ui.SortByKey(all, keyOf, dir)
end

function ui.UpdateHistoryList()
    if not ui.histScroll then return end
    local sortKey = ui.histSortKey or "when"
    local dir = ui.histSortDir or "desc"
    local rows = ui.SortHistory(ui.histView or {}, sortKey, dir)
    ui.PaintSortHeaders(ui.histHeaders, sortKey, dir)
    local total = table.getn(rows)
    local vis = ui.ListRowsAt(ui.WindowH(), LISTBOX.hist,
        HIST_ROW_H, HIST_ROWS_MAX)
    ui.GrowHistRows(vis)
    ui.SkinNewRows(ui.histRows)
    FauxScrollFrame_Update(ui.histScroll, total, vis, HIST_ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.histScroll)
    local i = 1
    while i <= table.getn(ui.histRows) do
        local row = ui.histRows[i]
        local e = (i <= vis) and rows[i + offset] or nil
        if e then
            row.when:SetText(e.t and util.FormatAgo(time() - e.t) or "\226\128\148")
            row.when:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
            if e.kind == "sale" then
                row.kind:SetText("Sold")
                row.kind:SetTextColor(0.30, 0.85, 0.30)
                row.amount:SetText("+" .. util.FormatMoney(e.amount, true))
            else
                row.kind:SetText("Bought")
                row.kind:SetTextColor(0.90, 0.55, 0.35)
                row.amount:SetText("-" .. util.FormatMoney(e.amount, true))
            end
            -- DELIBERATELY NOT QUALITY-COLOURED, unlike every other table's
            -- item column. The ledger stores a NAME and an item id, never a
            -- quality, so colouring here would mean a GetItemInfo per row --
            -- inside a repaint that ui.ScanMailSales can trigger while the
            -- client is storming MAIL_INBOX_UPDATE and resolving item data.
            -- That is precisely the shape HARD RULE 16 exists to forbid, and
            -- it is what froze Courier. The Type column carries the colour
            -- that matters here (Sold green, Bought orange) and costs nothing.
            row.item:SetText(e.item or "?")
            row.item:SetTextColor(C.text[1], C.text[2], C.text[3])
            row:Show()
        else
            row:Hide()
        end
        i = i + 1
    end
    if total == 0 then
        ui.histNote:SetText("No transactions in this period yet.")
    else
        ui.histNote:SetText("Sales are logged from your mailbox; buys from the Buy tab.")
    end
end

StaticPopupDialogs["AEGIS_EXCHANGE_CLEARLEDGER"] = {
    text = "Clear ALL Aegis sales/income history?\nThis cannot be undone.",
    button1 = "Clear", button2 = "Cancel",
    OnAccept = function()
        A.db.ClearLedger()
        ui.RefreshHistory()
        ChatMsg("Aegis: history cleared.")
    end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

-- ---------------------------------------------------------------------------
-- Sell tab: bag browser + per-item listing scan + post
-- ---------------------------------------------------------------------------

-- 26, the Buy table's row height, not the 19 this list used to draw. The
-- taller row is what gives a 20px icon and a quality-coloured name room to
-- read as a table rather than as a packed list.
local BAG_ROWS,  BAG_ROW_H  = 9, 26
local BAG_ROWS_MAX  = 36
-- Row-relative column x / width for the Sell tab's listings table. ONE pair,
-- read by the row cells and by the headers.
--
-- They were two sets before: the headers carried panel-relative x values and
-- their own widths, the rows carried row-relative ones, and the two disagreed
-- by a few pixels on every numeric column. The scroll frame starts at
-- LISTBOX.sellList's x, which is what ui.MakeSortHeaders' `rowLeft` is for.
--
-- 4px in, not flush with the row's left edge: at 0 the price sat against the
-- row border -- and against the highlight box under the pfUI skin -- which
-- read as clipped.
local SCX = { unit = 4, avail = 92, stack = 252, pct = 392, you = 446 }
local SCW = { unit = 84, avail = 156, stack = 136, pct = 50, you = 44 }
-- Numeric columns are RIGHT-justified, which is the difference between a
-- table that reads as designed and one that reads as assembled. Every column
-- here was left-aligned -- the money ran ragged down the page while the Buy
-- table's lined up on its decimal point.
--
-- ui.MakeSortHeaders puts a right-aligned column's HEADING over the right
-- edge of its cells from the same flag, so the two halves cannot disagree.
local SELL_HEADER_DEFS = {
    { key = "unit",  text = "Unit price",   just = "RIGHT" },
    { key = "avail", text = "Available" },
    { key = "stack", text = "Stack price",  just = "RIGHT" },
    { key = "pct",   text = "% mkt",        just = "RIGHT" },
    { key = "you",   text = "You?" },
}

-- 26, the Buy table's row height. At 19 the listings table read as a packed
-- list beside a window whose every other table had breathing room.
local LIST_ROWS, LIST_ROW_H = 9, 26
local LIST_ROWS_MAX = 36

-- Text budget for the "Your Bags" rows. The bag scroll's right edge sits at
-- panel LEFT + 168 and it starts at LEFT + 12, so a row is ~156 wide; item
-- labels begin 30px in (past the icon and cache dot) and category headers 4px
-- in. Long names ("Formula: Enchant Shield - Lesser Protection") used to run
-- straight past the list into the listings table -- these are what they get
-- clipped to. See ui.SetTextClipped.
local BAG_ITEM_TEXT_W = 176
local BAG_CAT_TEXT_W  = 210

function ui.BuildSellTab()
    local panel = ui.panels["Sell"]
    if not panel or ui.sellBuilt then return end
    ui.sellBuilt = true
    ui.sellDuration = A.db.Setting("duration") or A.sell.DEFAULT_DURATION

    -- ------------------------------------------------------------------
    -- HEADER BAND -- what you're selling, and what it comes to.
    --
    -- Four figures used to be four loose right-aligned strings that each
    -- carried their own label ("Deposit ~1c (approx)", "1 x 11c = 11c").
    -- As columns with a caption above the value they read at a glance and
    -- stop competing with the item name for the same eye.
    -- ------------------------------------------------------------------
    local band = panel:CreateTexture(nil, "BACKGROUND")
    band:SetTexture(C.titleBG[1], C.titleBG[2], C.titleBG[3], 0.85)
    band:SetHeight(SELL_HEAD_H)
    band:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    band:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)

    local bandEdge = panel:CreateTexture(nil, "ARTWORK")
    bandEdge:SetTexture(C.border[1], C.border[2], C.border[3], 0.30)
    bandEdge:SetHeight(1)
    bandEdge:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -SELL_HEAD_H)
    bandEdge:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -SELL_HEAD_H)

    local slot = CreateFrame("Button", "AegisExchangeSellSlot", panel)
    slot:SetWidth(36)
    slot:SetHeight(36)
    slot:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -5)
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
        if not it then return end
        GameTooltip:SetOwner(slot, "ANCHOR_RIGHT")
        if GameTooltip.SetAuctionSellItem then
            GameTooltip:SetAuctionSellItem()          -- the slot item, safely
        elseif it.link and GameTooltip.SetHyperlink then
            GameTooltip:SetHyperlink(it.link)
        end
        GameTooltip:Show()
    end)
    slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ui.sellSlot = slot

    ui.sellName = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.sellName:SetPoint("TOPLEFT", slot, "TOPRIGHT", 10, -2)
    ui.sellName:SetJustifyH("LEFT")
    ui.sellName:SetText("Click a bag item, or drag one here")
    ui.sellName:SetTextColor(0.94, 0.87, 0.70)

    ui.sellCtx = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.sellCtx:SetPoint("TOPLEFT", slot, "TOPRIGHT", 10, -21)
    ui.sellCtx:SetJustifyH("LEFT")
    ui.sellCtx:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])

    -- A summary column: dim caption on top, value under it, both right-aligned
    -- on the same x so the four read as a row of figures.
    local function statCol(dx, caption)
        local cap = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cap:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -dx, -7)
        cap:SetJustifyH("RIGHT")
        cap:SetText(caption)
        cap:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
        local val = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        val:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -dx, -22)
        val:SetJustifyH("RIGHT")
        val:SetTextColor(C.text[1], C.text[2], C.text[3])
        return val
    end
    ui.sellCap     = statCol(12,  "Listings")
    ui.sellNet     = statCol(88,  "After cut")
    ui.sellDeposit = statCol(166, "Deposit")
    ui.sellTotal   = statCol(240, "Total")
    ui.sellTotal:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    -- ------------------------------------------------------------------
    -- CONTROL GRID -- left column is what you're posting, right column is
    -- for how much. One shared baseline per row, so the two line up.
    -- ------------------------------------------------------------------
    local ROW1, ROW2, ROW3 = -58, -82, -106

    -- Right-aligned caption in a fixed gutter: every control below starts at
    -- the same x whatever the label says.
    local function gutter(text, y)
        local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, y)
        fs:SetWidth(70)
        fs:SetJustifyH("RIGHT")
        fs:SetText(text)
        fs:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
        return fs
    end

    -- Sliders because picking a stack size is a "how do I want to split this"
    -- decision, not a number you know up front -- dragging shows the trade-off
    -- immediately, and the two are linked: a bigger stack means fewer of them.
    local sizeLabel = gutter("Stack size", ROW1)
    ui.sellStackSize = MakeNumBox(panel, 34, function()
        ui.SyncSellPrices("size")
    end)
    ui.sellSizeSlider = MakeHSlider(panel, 150, function(v)
        ui.sellStackSize:SetText(tostring(math.floor(v)))
        ui.SyncSellPrices("size")
    end)
    ui.sellSizeSlider:SetPoint("LEFT", sizeLabel, "RIGHT", 10, 0)
    ui.sellStackSize:SetPoint("LEFT", ui.sellSizeSlider, "RIGHT", 8, 0)

    local cntLabel = gutter("Stacks", ROW2)
    ui.sellNumStacks = MakeNumBox(panel, 34, function() ui.RefreshSell() end)
    ui.sellCountSlider = MakeHSlider(panel, 150, function(v)
        ui.SetStackCount(v)
    end)
    ui.sellCountSlider:SetPoint("LEFT", cntLabel, "RIGHT", 10, 0)
    ui.sellNumStacks:SetPoint("LEFT", ui.sellCountSlider, "RIGHT", 8, 0)

    -- "Max": fill the count with every stack of the chosen SIZE that can be
    -- assembled. sell.MaxStacks already computes it and the slider is already
    -- clamped to it -- this only saves the dragging.
    --
    -- It writes through ui.SetStackCount rather than straight to the box:
    -- size and count move each other's ceilings, and SetSliderRange is
    -- re-applied to both on every RefreshSell, so a raw SetText would leave
    -- the slider disagreeing with the number beside it until the next repaint.
    local maxBtn = ui.MakeButton(panel, "quiet", "AegisExchangeSellMaxButton")
    maxBtn:SetWidth(38); maxBtn:SetHeight(18)
    maxBtn:SetPoint("LEFT", ui.sellNumStacks, "RIGHT", 6, 0)
    maxBtn:SetText("Max")
    maxBtn:SetScript("OnClick", function() ui.SetStackCountMax() end)
    ui.sellMaxBtn = maxBtn

    ui.sellMaxInfo = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.sellMaxInfo:SetPoint("LEFT", maxBtn, "RIGHT", 10, 0)

    local durLabel = gutter("Duration", ROW3)
    ui.sellDurBtns = {}
    local prev = nil
    local di = 1
    while di <= table.getn(A.sell.DURATIONS) do
        local d = A.sell.DURATIONS[di]
        local b = ui.MakeButton(panel, "quiet")
        b:SetWidth(44)
        b:SetHeight(20)
        if prev then
            b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else
            b:SetPoint("LEFT", durLabel, "RIGHT", 10, 0)
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

    -- Right column. Every row is pinned to the panel's RIGHT edge, so the
    -- copper box of both money rows and the right edge of the button pair all
    -- land on the same line -- and nothing can drift into the left column when
    -- the window is dragged wider.
    --
    -- Two pricing buttons, not three. Undercut and price-match are the only
    -- choices that are actually about the market; "Market" was the same
    -- reference price with no undercut applied and "Vendor" is a floor, not a
    -- strategy -- the vendor figure is on the context line and the Vendor list
    -- still calls out items worth more to a merchant.
    local mkQuick = function(text, w, fn)
        local b = ui.MakeButton(panel, "quiet")
        b:SetWidth(w)
        b:SetHeight(20)
        b:SetText(text)
        b:SetScript("OnClick", fn)
        return b
    end
    -- These write through SetText, which stays quiet so the boxes don't fire
    -- while we're filling them -- so each one re-syncs explicitly afterwards.
    ui.sellMatchBtn = mkQuick("Price match", 84, function()
        local it = A.sell.GetItem()
        local m = it and A.sell.MatchUnit(it.itemId)
        if m then
            SetMoneyBox(ui.sellBuyout, m)
            ui.SyncSellPrices("unit")
        end
    end)
    ui.sellMatchBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, ROW1 + 4)

    ui.sellUnderBtn = mkQuick("Undercut", 70, function()
        local it = A.sell.GetItem()
        local u = it and A.sell.UndercutUnit(it.itemId)
        if u then
            SetMoneyBox(ui.sellBuyout, u)
            ui.SyncSellPrices("unit")
        end
    end)
    ui.sellUnderBtn:SetPoint("RIGHT", ui.sellMatchBtn, "LEFT", -5, 0)

    -- The triplet plus its coin icons is PRICE_GSC_W wide measured from the
    -- label's right edge, so the label hangs that far in from the panel edge
    -- and the copper coin lands exactly on it.
    local function moneyRow(text, y)
        local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -(PRICE_GSC_W + 12), y)
        fs:SetWidth(76)
        fs:SetJustifyH("RIGHT")
        fs:SetText(text)
        fs:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])
        return fs
    end

    -- Left blank, the start bid follows the buyout -- which is what the Sell
    -- tab has always done.
    local bidLabel = moneyRow("Bid each", ROW2)
    ui.sellBid = MakeMoneyGSC(panel, function() ui.RefreshSell() end)
    ui.sellBid:Attach(bidLabel, 6, 0)

    local buyLabel = moneyRow("Buyout each", ROW3)
    ui.sellBuyout = MakeMoneyGSC(panel, function() ui.SyncSellPrices("unit") end)
    ui.sellBuyout:Attach(buyLabel, 6, 0)

    -- Down the form as it reads: stack size, how many, then the two prices a
    -- coin at a time. Posting is the one thing on this tab that commits, and
    -- Tab now walks everything that feeds it without reaching for the mouse.
    ui.LinkTabOrder({ ui.sellStackSize, ui.sellNumStacks,
                      ui.sellBid.g, ui.sellBid.s, ui.sellBid.c,
                      ui.sellBuyout.g, ui.sellBuyout.s, ui.sellBuyout.c })

    -- ------------------------------------------------------------------
    -- ACTION BAR -- status on the left, Post and Skip pinned right. Making
    -- it a band of its own is the point: the rows above are all inputs, and
    -- exactly one row commits them.
    -- ------------------------------------------------------------------
    local foot = panel:CreateTexture(nil, "BACKGROUND")
    foot:SetTexture(C.titleBG[1], C.titleBG[2], C.titleBG[3], 0.85)
    foot:SetHeight(SELL_TOP_H - SELL_FOOT_Y)
    foot:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -SELL_FOOT_Y)
    foot:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -SELL_FOOT_Y)

    local footEdge = panel:CreateTexture(nil, "ARTWORK")
    footEdge:SetTexture(C.border[1], C.border[2], C.border[3], 0.30)
    footEdge:SetHeight(1)
    footEdge:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -SELL_FOOT_Y)
    footEdge:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -SELL_FOOT_Y)

    local post = ui.MakeButton(panel, "primary", "AegisExchangeSellPostButton")
    post:SetWidth(96)
    post:SetHeight(22)
    post:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -(SELL_FOOT_Y + 4))
    post:SetText("Post")
    post:SetScript("OnClick", function()
        ui.ConfirmPost()
    end)
    ui.sellPostBtn = post

    local skip = ui.MakeButton(panel, "quiet", "AegisExchangeSellSkipButton")
    skip:SetWidth(60)
    skip:SetHeight(22)
    skip:SetPoint("RIGHT", post, "LEFT", -6, 0)
    skip:SetText("Skip")
    skip:SetScript("OnClick", function()
        ui.SkipSell()
    end)
    ui.sellSkipBtn = skip

    -- ONE anchor point. A LEFT plus a TOP would each constrain the vertical
    -- position and over-constrain the string; TOPLEFT with a measured offset
    -- centres it on the bar without the ambiguity.
    ui.sellStatus = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.sellStatus:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -(SELL_FOOT_Y + 9))
    ui.sellStatus:SetJustifyH("LEFT")
    ui.sellStatus:SetTextColor(C.amber[1], C.amber[2], C.amber[3])

    -- Vendor warning. Only shown when the price is BELOW what a merchant
    -- would pay -- the "you're well above vendor" case was reassurance nobody
    -- needed taking up a permanent line, and the vendor figure itself is on
    -- the context line either way.
    ui.sellVendor = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.sellVendor:SetPoint("RIGHT", skip, "LEFT", -12, 0)
    ui.sellVendor:SetJustifyH("RIGHT")
    ui.sellVendor:SetTextColor(0.9, 0.4, 0.4)

    -- ---- Divider --------------------------------------------------------
    local div = panel:CreateTexture(nil, "ARTWORK")
    div:SetTexture(C.border[1], C.border[2], C.border[3], 0.4)
    div:SetHeight(1)
    div:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -SELL_TOP_H)
    div:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -SELL_TOP_H)

    -- ---- Bottom-left: Your Bags ----------------------------------------
    local bagHdr = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bagHdr:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -(SELL_TOP_H + 8))
    bagHdr:SetText("Your Bags")
    bagHdr:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    local bagScroll = CreateFrame("ScrollFrame", "AegisExchangeBagScroll",
        panel, "FauxScrollFrameTemplate")
    bagScroll:SetPoint("TOPLEFT", panel, "TOPLEFT", SELLL.bag_x,
        -LISTBOX.bag.top)
    -- The FauxScrollFrame's scrollbar sits just OUTSIDE this edge, so the gap
    -- to SELLL.list_x is what keeps the bar off the listings column.
    bagScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMLEFT", SELLL.bag_right,
        LISTBOX.bag.bot)

    -- Vendor list: bag items worth more at a merchant than on the AH.
    local vendListBtn = ui.MakeButton(panel, "quiet", "AegisExchangeVendorListButton")
    vendListBtn:SetWidth(56)
    vendListBtn:SetHeight(18)
    vendListBtn:SetPoint("TOPRIGHT", bagScroll, "TOPRIGHT", -52, 18)
    vendListBtn:SetText("Vendor")
    vendListBtn:SetScript("OnClick", function() ui.ToggleVendorList() end)
    ui.sellVendorListBtn = vendListBtn

    local scanAllBtn = ui.MakeButton(panel, "quiet")
    scanAllBtn:SetWidth(48)
    scanAllBtn:SetHeight(18)
    scanAllBtn:SetPoint("TOPRIGHT", bagScroll, "TOPRIGHT", 0, 18)
    scanAllBtn:SetText("Scan")
    scanAllBtn:SetScript("OnClick", function()
        if A.sell.batchActive then
            A.sell.StopBatchScan()
            ui.UpdateBagList()
            scanAllBtn:SetText("Scan")
        else
            scanAllBtn:SetText("Stop")
            A.sell.ScanAllBags(
                function(itemId)
                    -- Per-item: redraw dots (the just-scanned item turns green,
                    -- the next one turns yellow).
                    ui.UpdateBagList()
                end,
                function()
                    -- All done or stopped.
                    scanAllBtn:SetText("Scan")
                    ui.UpdateBagList()
                    -- Queue the scanned items for posting and slot the first
                    -- one, so you can Post / Skip straight down the list.
                    ui.StartSellQueue()
                end
            )
            ui.UpdateBagList()   -- show the first yellow dot immediately
        end
    end)
    ui.sellScanAllBtn = scanAllBtn
    bagScroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(BAG_ROW_H, ui.UpdateBagList)
    end)
    ui.bagScroll = bagScroll

    ui.bagRows = {}
ui.GrowBagRows = function(n)
        if n > BAG_ROWS_MAX then n = BAG_ROWS_MAX end
        -- Built on demand: a minimum-size window costs exactly what it
        -- did before, and dragging taller adds only the rows needed.
        local bi = table.getn(ui.bagRows) + 1
        while bi <= n do
            local row = CreateFrame("Button", nil, panel)
            row:SetHeight(BAG_ROW_H)
            if bi == 1 then
                row:SetPoint("TOPLEFT", bagScroll, "TOPLEFT", 0, 0)
                row:SetPoint("TOPRIGHT", bagScroll, "TOPRIGHT", 0, 0)
            else
                row:SetPoint("TOPLEFT", ui.bagRows[bi - 1], "BOTTOMLEFT", 0, 0)
                row:SetPoint("TOPRIGHT", ui.bagRows[bi - 1], "BOTTOMRIGHT", 0, 0)
            end
            -- The same chrome every other table wears, on the same terms:
            -- created before any cell, no selection tint (clicking a bag row
            -- places the item, it does not leave the row in a chosen state).
            ui.AddRowChrome(row, bi)

            -- A category header's band. Sized to the row and hidden on item
            -- rows, so the headers read as the dividers they are instead of
            -- as text that happened to land there -- which is what the
            -- reference screenshot is actually showing.
            local band = row:CreateTexture(nil, "BORDER")
            band:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
            band:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
            band:SetTexture(C.titleBG[1], C.titleBG[2], C.titleBG[3], 0.85)
            band:Hide()
            row.band = band

            local ic = row:CreateTexture(nil, "ARTWORK")
            ic:SetWidth(20)
            ic:SetHeight(20)
            ic:SetPoint("LEFT", row, "LEFT", 4, 0)
            ic:Hide()
            row.icon = ic
            local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            lbl:SetPoint("LEFT", row, "LEFT", 34, 0)
            lbl:SetJustifyH("LEFT")
            row.label = lbl
            -- Cache indicator: small green asterisk left of the label, between the
            -- icon and the item name so long names never overlap it.
            local dot = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            dot:SetPoint("LEFT", row, "LEFT", 26, 0)
            dot:SetJustifyH("LEFT")
            dot:SetTextColor(0.30, 0.85, 0.30)
            dot:SetText("*")
            dot:Hide()
            row.cacheDot = dot
            row:SetScript("OnClick", function()
                local e = row.entry
                if e and e.kind == "item" then ui.SelectBagEntry(e.item) end
            end)
            row:SetScript("OnEnter", function()
                local e = row.entry
                if e and e.kind == "item" and e.item and GameTooltip.SetBagItem then
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
    end
    ui.GrowBagRows(BAG_ROWS)

    -- ---- Bottom-right: listings table ----------------------------------
    -- Column headers, through the SHARED builder. This tab carried its own
    -- copy of it -- same idea, its own font, its own widths, and no support
    -- for right-aligning a numeric column -- which is why the listings
    -- headers were grey where every other table's are warm tan.
    ui.sellSortKey = "unit"
    ui.sellSortDir = "asc"
    ui.sellHeaders = ui.MakeSortHeaders(panel, SELLL.list_x,
        -SELLL.hdr_top,
        SCX, SCW, function(key) ui.SetSellSort(key) end, SELL_HEADER_DEFS)

    local listScroll = CreateFrame("ScrollFrame", "AegisExchangeListScroll",
        panel, "FauxScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", panel, "TOPLEFT", SELLL.list_x,
        -LISTBOX.sellList.top)
    listScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT",
        -SELLL.list_right, LISTBOX.sellList.bot)
    listScroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(LIST_ROW_H, ui.UpdateListingsList)
    end)
    ui.listScroll = listScroll

    -- ONE box around the headings AND the rows, exactly as the Buy table
    -- draws it. This table had no box at all: the headings and rows sat on
    -- the bare panel, so the tab read as a list of text rather than a table.
    --
    -- Anchored explicitly rather than through ui.MakeWell, for the same two
    -- reasons the Buy table's is: the box has to reach UP past the scroll
    -- frame to enclose the header row, and its right edge has to stop AT the
    -- scroll frame's -- FauxScrollFrameTemplate hangs its scrollbar OUTWARD
    -- from that line, so any positive offset puts the box under the bar.
    local listWell = CreateFrame("Frame", nil, panel)
    listWell:SetPoint("TOPLEFT", panel, "TOPLEFT", SELLL.list_x - 6,
        -SELLL.well_top)
    listWell:SetPoint("BOTTOMRIGHT", listScroll, "BOTTOMRIGHT", 0, -6)
    listWell:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    listWell:SetBackdropColor(0.05, 0.04, 0.03, 0.85)
    listWell:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3])
    ui.sellListWell = listWell

    -- The rule goes UNDER the headings, not at the top of the box.
    local listRule = panel:CreateTexture(nil, "ARTWORK")
    listRule:SetPoint("TOPLEFT", listWell, "TOPLEFT", 6, -SELLL.hdr_h)
    listRule:SetPoint("TOPRIGHT", listWell, "TOPRIGHT", -6, -SELLL.hdr_h)
    listRule:SetHeight(1)
    listRule:SetTexture(0.45, 0.38, 0.22, 0.85)

    -- Thin separators between the header cells, as the Buy table has. The
    -- first column needs none -- there is a box edge to its left already.
    local sellTickKeys = { "avail", "stack", "pct", "you" }
    local sti = 1
    while sti <= table.getn(sellTickKeys) do
        local tk = panel:CreateTexture(nil, "ARTWORK")
        tk:SetWidth(1)
        tk:SetPoint("TOPLEFT", listWell, "TOPLEFT",
            6 + SCX[sellTickKeys[sti]] - 8, -6)
        tk:SetPoint("BOTTOMLEFT", listWell, "TOPLEFT",
            6 + SCX[sellTickKeys[sti]] - 8, -SELLL.hdr_h)
        tk:SetTexture(0.35, 0.30, 0.18, 0.7)
        sti = sti + 1
    end

    -- The status line hangs BELOW the box now, the way the Buy table's count
    -- does. It used to float above the headings, where it competed with them
    -- for the same eye and left the table looking unanchored at the top.
    ui.listHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.listHeader:SetPoint("TOPLEFT", listWell, "BOTTOMLEFT", 6, -6)
    ui.listHeader:SetJustifyH("LEFT")
    ui.listHeader:SetText("Select an item to see its listings")
    ui.listHeader:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    ui.listRows = {}
ui.GrowListRows = function(n)
        if n > LIST_ROWS_MAX then n = LIST_ROWS_MAX end
        -- Built on demand: a minimum-size window costs exactly what it
        -- did before, and dragging taller adds only the rows needed.
        local li = table.getn(ui.listRows) + 1
        while li <= n do
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
            -- The highlight above is HOVER, which is a different thing from
            -- selection: these rows are pressed to copy a price, never left
            -- in a chosen state. So chrome without a selection tint.
            ui.AddRowChrome(row, li)
            local mkCell = function(x, w, just)
                local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                fs:SetPoint("LEFT", row, "LEFT", x, 0)
                fs:SetWidth(w)
                fs:SetJustifyH(just or "LEFT")
                return fs
            end
            row.unit  = mkCell(SCX.unit,  SCW.unit,  "RIGHT")
            row.avail = mkCell(SCX.avail, SCW.avail)
            row.stack = mkCell(SCX.stack, SCW.stack, "RIGHT")
            row.pct   = mkCell(SCX.pct,   SCW.pct,   "RIGHT")
            row.you   = mkCell(SCX.you,   SCW.you)
            row:SetScript("OnClick", function()
                local g = row.group
                if g and g.unit then
                    SetMoneyBox(ui.sellBuyout, g.unit)
                    ui.SyncSellPrices("unit")   -- price the whole stack from it
                end
            end)
            -- DELIBERATELY NO TOOLTIP on these rows. Every row here is a price
            -- bucket for the SAME item -- the one already in the sell slot -- so a
            -- tooltip repeats what the header shows, and anchored off a row this
            -- far right it hangs outside the window. The Sell tab shows item
            -- tooltips only where they tell you something you can't already see:
            -- the "Your Bags" list and the sell slot itself.
            row:Hide()
            ui.listRows[li] = row
            li = li + 1
        end
    end
    ui.GrowListRows(LIST_ROWS)

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
    local vis = ui.ListRowsAt(ui.WindowH(), LISTBOX.bag,
        BAG_ROW_H, BAG_ROWS_MAX)
    ui.GrowBagRows(vis)
    ui.SkinNewRows(ui.bagRows)
    FauxScrollFrame_Update(ui.bagScroll, table.getn(flat), vis, BAG_ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.bagScroll)
    local i = 1
    while i <= table.getn(ui.bagRows) do
        local row = ui.bagRows[i]
        local e = (i <= vis) and flat[i + offset] or nil
        if e then
            row.entry = e
            if e.kind == "cat" then
                row.icon:Hide()
                row.cacheDot:Hide()
                row.band:Show()
                row.label:ClearAllPoints()
                row.label:SetPoint("LEFT", row, "LEFT", 6, 0)
                ui.SetTextClipped(row.label, e.name .. " (" .. e.num .. ")",
                    BAG_CAT_TEXT_W)
                row.label:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
            else
                row.band:Hide()
                local it = e.item
                if it.texture then
                    row.icon:SetTexture(it.texture)
                    row.icon:Show()
                else
                    row.icon:Hide()
                end
                -- Cache dot: yellow * while this item is being batch-scanned,
                -- green * when a fresh result is cached, hidden otherwise.
                local dot = row.cacheDot
                if A.sell.batchActive and A.sell.batchCurrentItemId == it.itemId then
                    dot:SetTextColor(1.0, 0.85, 0.10)   -- yellow
                    dot:Show()
                else
                    local ce = A.sell.cache[it.itemId]
                    if ce and time() - ce.when < A.sell.CACHE_TTL then
                        dot:SetTextColor(0.30, 0.85, 0.30)   -- green
                        dot:Show()
                    else
                        dot:Hide()
                    end
                end
                row.label:ClearAllPoints()
                row.label:SetPoint("LEFT", row, "LEFT", 34, 0)
                local txt = it.name
                -- ONE line per item now, so this count is the whole holding
                -- across every bag rather than one slot's worth. See
                -- sell.ScanBags: `count` is the total and `stackMax` is the
                -- largest single stack, and only the second bounds what can
                -- be posted as one auction.
                if it.count and it.count > 1 then txt = txt .. " x" .. it.count end
                ui.SetTextClipped(row.label, txt, BAG_ITEM_TEXT_W)
                -- Quality-coloured, as every other item column in the window
                -- is. nil quality means a cold item cache, not "common", so
                -- it falls back to plain text rather than painting it white.
                local q = it.quality
                if q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q] then
                    local qc = ITEM_QUALITY_COLORS[q]
                    row.label:SetTextColor(qc.r, qc.g, qc.b)
                else
                    row.label:SetTextColor(C.text[1], C.text[2], C.text[3])
                end
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
    -- During a scan, only allow cached items (they load instantly).
    if A.scan.IsRunning() or A.scan.IsPaused() then
        local ce = A.sell.cache[item.itemId]
        if ce and time() - ce.when < A.sell.CACHE_TTL then
            -- Render directly from the cache without setting sell.listings.
            -- Setting sell.listings = ce.listings creates a shared reference
            -- that the batch scan's onListing callbacks could corrupt via
            -- table.insert — the scan engine modifies sell.listings for the
            -- item it is currently querying.
            A.sell.PlaceFromBag(item.bag, item.slot)
            A.sell.scanItemId = item.itemId
            A.sell.scanName   = item.name
            A.sell.scanWhen   = ce.when
            ui.lastScanItemId = item.itemId
            local it = A.sell.GetItem()
            local market = it and it.itemId and A.db.MarketValue(it.itemId) or nil
            ui.sellListingGroups = A.sell.GroupListings(ce.listings, market)
            ui.sellScanState = "done"
            ui.UpdateListingsList()
            ui.UpdateBagList()
            ui.RefreshSell()
            return
        else
            ChatMsg("Aegis: scan in progress \226\128\148 cached items still available.")
            return
        end
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
    -- During a running scan we can't start a new ScanItem (it would either
    -- return false or, worse, set sell.listings to a cached reference that
    -- the scan engine's onListing callbacks would corrupt). Render from
    -- cache directly instead.
    if A.scan.IsRunning() or A.scan.IsPaused() then
        local ce = A.sell.cache[it.itemId]
        if ce and time() - ce.when < A.sell.CACHE_TTL then
            A.sell.scanItemId = it.itemId
            A.sell.scanName   = it.name
            A.sell.scanWhen   = ce.when
            local market = A.db.MarketValue(it.itemId)
            ui.sellListingGroups = A.sell.GroupListings(ce.listings, market)
            ui.sellScanState = "done"
            ui.UpdateListingsList()
        else
            ui.sellScanState = "scanning"
            ui.UpdateListingsList()
        end
        return
    end
    local started = A.sell.ScanItem(it.name, it.itemId, nil, function(rows)
        ui.OnItemListings(rows)
    end)
    -- On a cache hit, onDone fires synchronously and sellListingGroups is
    -- already populated. Only mark "scanning" when a real scan is in flight.
    if not ui.sellListingGroups then
        ui.sellScanState = started and "scanning" or "busy"
    end
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
    -- Price it automatically: whenever a scan lands for a NEW item, fill the
    -- buyout from the lowest competing listing with the configured undercut
    -- applied (DefaultSellUnit -> UndercutUnit). Also fills an empty box, so
    -- clearing the price and re-scanning re-prices it.
    if ui.sellPrefilledFor ~= it.itemId
        or util.Trim(ui.sellBuyout:GetText() or "") == "" then
        local u = ui.DefaultSellUnit(it.itemId)
        if u then
            SetMoneyBox(ui.sellBuyout, u)
            ui.SyncSellPrices("unit")   -- keep the stack price in step
        end
        ui.sellPrefilledFor = it.itemId
    end
    ui.UpdateListingsList()
    ui.UpdateBagList()     -- refresh cache dots on the bag rows
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

-- Click a listings header: same column toggles direction, a new column starts
-- ascending. Mirrors the Buy / Crafting behaviour.
function ui.SetSellSort(key)
    ui.sellSortKey, ui.sellSortDir =
        ui.NextSort(ui.sellSortKey, ui.sellSortDir, key)
    ui.UpdateListingsList()
end

-- Sort a copy of the grouped listings by the chosen column.
function ui.SortSellGroups(all, sortKey, dir)
    local function keyOf(g)
        if sortKey == "avail" then return g.num
        elseif sortKey == "stack" then
            return (g.buyout and g.buyout > 0) and g.buyout or nil
        elseif sortKey == "pct" then return g.pct
        elseif sortKey == "you" then return g.mine and 1 or 0 end
        return g.unit
    end
    return ui.SortByKey(all, keyOf, dir)
end

function ui.UpdateListingsList()
    if not ui.listScroll then return end
    local all = ui.sellListingGroups or {}
    local groups = ui.SortSellGroups(all,
        ui.sellSortKey or "unit", ui.sellSortDir or "asc")
    ui.PaintSortHeaders(ui.sellHeaders,
        ui.sellSortKey or "unit", ui.sellSortDir or "asc")
    local vis = ui.ListRowsAt(ui.WindowH(), LISTBOX.sellList,
        LIST_ROW_H, LIST_ROWS_MAX)
    ui.GrowListRows(vis)
    ui.SkinNewRows(ui.listRows)
    FauxScrollFrame_Update(ui.listScroll, table.getn(groups), vis, LIST_ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.listScroll)

    if ui.sellScanState == "scanning" then
        -- Share the Aegis strip's live progress (page / ETA / rate) so this
        -- scan is just as diagnosable from here.
        local prog = ui.ScanProgressText()
        if prog then
            ui.listHeader:SetText("Scanning \226\128\162 " .. prog)
        else
            ui.listHeader:SetText("Scanning this item...")
        end
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
    while i <= table.getn(ui.listRows) do
        local row = ui.listRows[i]
        local g = (i <= vis) and groups[i + offset] or nil
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

    ui.MarkChosen(ui.sellDurBtns,
        function(b) return b.minutes == ui.sellDuration end)

    local count = A.sell.OwnerCount()
    local atCap = count >= A.sell.CAP
    ui.sellCap:SetText(count .. "/" .. A.sell.CAP)
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
        ui.sellNet:SetText("")
        ui.sellMaxInfo:SetText("")
        ui.sellPostBtn:Disable()
        ui.lastScanItemId = nil
        ui.sellDefaultsFor = nil
        ui.sellPrefilledFor = nil
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
        table.insert(parts, "market " .. util.FormatMoney(sg.market, true))
    end
    if sg and sg.minBuyout then
        table.insert(parts, "lowest " .. util.FormatMoney(sg.minBuyout, true))
    end
    if sg and sg.vendor then
        table.insert(parts, "vendor " .. util.FormatMoney(sg.vendor, true))
    end
    if table.getn(parts) > 0 then
        -- Middle dots, not runs of spaces: the three figures are one sentence
        -- about the item, and separators make that read at a glance.
        ui.sellCtx:SetText(table.concat(parts, " \226\128\162 "))
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
    ui.sellMaxInfo:SetText(string.format("= %d of %d", size * nStacks, totalHave))

    -- Re-range both sliders. Stack size can't exceed the item's own max stack
    -- or what you actually hold; the count follows from whatever size is
    -- chosen, which is what makes dragging one move the other's ceiling.
    -- BOUNDED BY THE LARGEST SINGLE STACK, not by total holdings.
    --
    -- 1.12 has no way to merge two partial stacks, and sell.MaxStacks counts
    -- `floor(count / size)` PER SLOT -- so with thirty held as three tens,
    -- asking for a stack of 30 yields zero postable stacks. Ranging the slider
    -- to the total let you pick a size that could never be assembled and left
    -- the count reading 0 with no explanation.
    --
    -- The total is still shown (the header says "30 total" and the readout
    -- says "= N of 30"); it is the size CEILING that has to be honest.
    local sizeMax = A.sell.LargestStack(it.itemId)
    if sizeMax < 1 then sizeMax = it.count or 1 end
    if it.maxStack and sizeMax > it.maxStack then sizeMax = it.maxStack end
    if sizeMax < 1 then sizeMax = 1 end
    SetSliderRange(ui.sellSizeSlider, 1, sizeMax, size)
    SetSliderRange(ui.sellCountSlider, 1, (maxStacks >= 1) and maxStacks or 1,
        nStacks)

    -- Totals across all stacks being posted.
    local stackTotal = unitBuy and math.floor(unitBuy * size) or 0
    local grandTotal = stackTotal * nStacks
    if grandTotal > 0 then
        ui.sellTotal:SetText(util.FormatMoney(grandTotal, true))
        -- What actually reaches your mailbox. The 5% consignment cut used to
        -- be documented and never shown, so the headline total was always a
        -- number you would not receive.
        ui.sellNet:SetText(util.FormatMoney(
            math.floor(grandTotal * (1 - A.sell.CUT)), true))
        ui.sellNet:SetTextColor(0.35, 0.80, 0.35)
    else
        ui.sellTotal:SetText("")
        ui.sellNet:SetText("")
    end

    -- Vendor comparison, shown ONLY as a warning. "1371% of vendor - above
    -- vendor" was reassurance nobody needed holding a permanent line; the
    -- vendor figure itself is on the context line either way. Below vendor is
    -- the case worth interrupting for: you would make more at a merchant.
    local vc = A.sell.VendorCompare(it.itemId, unitBuy)
    if vc and not vc.above then
        ui.sellVendor:SetText(string.format(
            "Below vendor price (%d%%)", vc.pct))
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
    ui.sellDeposit:SetText((approx and "~" or "")
        .. util.FormatMoney(depTotal, true))

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
-- Set the number of stacks and re-sync. ONE writer, because the count box and
-- its slider are re-ranged against each other on every repaint -- writing the
-- box directly leaves the two showing different numbers until something else
-- repaints them.
function ui.SetStackCount(n)
    if not ui.sellNumStacks then return end
    if not n or n < 1 then n = 1 end
    ui.sellNumStacks:SetText(tostring(math.floor(n)))
    ui.RefreshSell()
end

-- Every stack of the CURRENT size that can actually be assembled.
--
-- Not the total holding divided by the size: 1.12 cannot merge partial
-- stacks, so sell.MaxStacks counts per slot and thirty held as three tens
-- gives three stacks of ten and none of thirty. See sell.LargestStack.
function ui.SetStackCountMax()
    local it = A.sell.GetItem()
    if not it or not it.itemId then return end
    local n = A.sell.MaxStacks(it.itemId, ui.GetStackSize(it))
    if n < 1 then n = 1 end
    ui.SetStackCount(n)
end

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

-- Repaint after a price or stack-size change.
--
-- Prices are now entered PER ITEM only. The editable stack-price box is gone --
-- with a stack-size slider it was a second way to say the same thing, and the
-- two boxes rounding into each other made a price drift as you dragged. The
-- stack total is shown instead, on the right, by RefreshSell. `source` is kept
-- so callers read the same as before.
function ui.SyncSellPrices(source)
    if ui.sellSyncing then return end
    ui.sellSyncing = true
    ui.sellSyncing = false
    ui.RefreshSell()
end

-- ---- vendor list overlay -----------------------------------------------
-- Bag items that are worth MORE at a merchant than on the AH (after the 5%
-- consignment cut). Built lazily over the content region, like the category
-- picker.

local VEND_ROWS, VEND_ROW_H = 12, 20

function ui.BuildVendorList()
    if ui.vendList then return end
    local f = CreateFrame("Frame", "AegisExchangeVendorList", ui.frame)
    f:SetPoint("TOPLEFT", ui.content, "TOPLEFT", 0, 0)
    f:SetPoint("BOTTOMRIGHT", ui.content, "BOTTOMRIGHT", 0, 0)
    f:SetFrameLevel(ui.content:GetFrameLevel() + 5)
    f:EnableMouse(true)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(C.well[1], C.well[2], C.well[3], 1)
    f:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3])
    f:Hide()
    ui.vendList = f

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
    title:SetText("Better at a vendor than on the AH")
    title:SetTextColor(C.gold[1], C.gold[2], C.gold[3])

    local closeBtn = ui.MakeButton(f, "quiet")
    closeBtn:SetWidth(60); closeBtn:SetHeight(20)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -8)
    closeBtn:SetText("Close")
    closeBtn:SetScript("OnClick", function() ui.HideVendorList() end)

    ui.vendNote = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.vendNote:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -30)
    ui.vendNote:SetJustifyH("LEFT")
    ui.vendNote:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])

    -- Mark-all / clear, so you can flag the whole list for the merchant.
    local markAll = ui.MakeButton(f, "quiet")
    markAll:SetWidth(74); markAll:SetHeight(20)
    markAll:SetPoint("RIGHT", closeBtn, "LEFT", -4, 0)
    markAll:SetText("Mark all")
    markAll:SetScript("OnClick", function()
        local rows = ui.vendData or {}
        local i = 1
        while i <= table.getn(rows) do
            A.db.SetVendorMark(rows[i].itemId, true)
            i = i + 1
        end
        ui.UpdateVendorList()
    end)

    local clearMarks = ui.MakeButton(f, "quiet")
    clearMarks:SetWidth(74); clearMarks:SetHeight(20)
    clearMarks:SetPoint("RIGHT", markAll, "LEFT", -4, 0)
    clearMarks:SetText("Clear all")
    clearMarks:SetScript("OnClick", function()
        A.db.ClearVendorMarks()
        ui.UpdateVendorList()
    end)

    -- Columns (name shifts right to make room for the mark checkbox).
    local VX = { name = 30, qty = 226, vendor = 276, ah = 372, gain = 476 }
    local hdr = function(cx, text, just)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("TOPLEFT", f, "TOPLEFT", cx, -52)
        fs:SetText(text)
        if just then fs:SetJustifyH(just) end
        return fs
    end
    hdr(VX.name, "Item")
    hdr(VX.qty, "Qty")
    hdr(VX.vendor, "Vendor (ea)")
    hdr(VX.ah, "AH net (ea)")
    hdr(VX.gain, "You gain")

    local scroll = CreateFrame("ScrollFrame", "AegisExchangeVendScroll", f,
        "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -68)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 10)
    scroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(VEND_ROW_H, ui.UpdateVendorList)
    end)
    ui.vendScroll = scroll

    ui.vendRows = {}
    local i = 1
    while i <= VEND_ROWS do
        local row = CreateFrame("Frame", nil, f)
        row:SetHeight(VEND_ROW_H)
        if i == 1 then
            row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
            row:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, 0)
        else
            row:SetPoint("TOPLEFT", ui.vendRows[i - 1], "BOTTOMLEFT", 0, 0)
            row:SetPoint("TOPRIGHT", ui.vendRows[i - 1], "BOTTOMRIGHT", 0, 0)
        end
        local mk = function(cx, w, just)
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", row, "LEFT", cx, 0)
            fs:SetWidth(w); fs:SetJustifyH(just or "LEFT")
            return fs
        end
        -- Mark this item to sell at a merchant.
        local chk = ui.MakeCheckBox(row, 16, "AegisExchangeVendCheck" .. i)
        chk:SetPoint("LEFT", row, "LEFT", 4, 0)
        chk:SetScript("OnClick", function()
            if row.entry then
                A.db.SetVendorMark(row.entry.itemId,
                    chk:GetChecked() and true or false)
                ui.UpdateVendorList()
            end
        end)
        row.check = chk
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(16); icon:SetHeight(16)
        icon:SetPoint("LEFT", row, "LEFT", VX.name, 0)
        row.icon = icon
        row.name   = mk(VX.name + 20, 172)
        row.qty    = mk(VX.qty, 44)
        row.vendor = mk(VX.vendor, 90)
        row.ah     = mk(VX.ah, 98)
        row.gain   = mk(VX.gain, 92)
        row:Hide()
        ui.vendRows[i] = row
        i = i + 1
    end
end

function ui.RefreshVendorList()
    if not ui.vendList then return end
    ui.vendData = A.sell.VendorList()
    ui.UpdateVendorList()
end

function ui.UpdateVendorList()
    if not ui.vendScroll then return end
    local rows = ui.vendData or {}
    local total = table.getn(rows)

    local sum = 0
    local k = 1
    while k <= total do sum = sum + (rows[k].total or 0); k = k + 1 end

    if total == 0 then
        ui.vendNote:SetText("Nothing in your bags is worth more at a vendor"
            .. " \226\128\148 or those items have no vendor price recorded yet"
            .. " (hover them at a merchant to learn it).")
    else
        local marked = table.getn(A.sell.MarkedInBags())
        ui.vendNote:SetText(total .. " item(s) \226\128\162 vendoring them all"
            .. " nets about " .. util.FormatMoney(sum, true) .. " more than the AH."
            .. "  Tick items, then use the Aegis button at any merchant ("
            .. marked .. " marked).")
    end

    FauxScrollFrame_Update(ui.vendScroll, total, VEND_ROWS, VEND_ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.vendScroll)
    local i = 1
    while i <= VEND_ROWS do
        local row = ui.vendRows[i]
        local r = rows[i + offset]
        if r then
            row.entry = r
            row.check:SetChecked(A.db.IsVendorMarked(r.itemId) and 1 or nil)
            if r.texture then row.icon:SetTexture(r.texture); row.icon:Show()
            else row.icon:Hide() end
            row.name:SetText(r.name)
            row.name:SetTextColor(C.text[1], C.text[2], C.text[3])
            row.qty:SetText("x" .. r.count)
            row.vendor:SetText(util.FormatMoney(r.vendorUnit, true))
            if r.ahUnit then
                row.ah:SetText(util.FormatMoney(r.netAh, true))
            else
                row.ah:SetText("no AH data")
            end
            row.gain:SetText("+" .. util.FormatMoney(r.total, true))
            row.gain:SetTextColor(0.30, 0.85, 0.30)
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
        i = i + 1
    end
end

function ui.ShowVendorList()
    ui.BuildVendorList()
    if A.skin then A.skin.ApplyOverlay(ui.vendList) end
    ui.RefreshVendorList()
    ui.vendList:Show()
end

function ui.HideVendorList()
    if ui.vendList then ui.vendList:Hide() end
end

function ui.ToggleVendorList()
    ui.BuildVendorList()
    if ui.vendList:IsVisible() then ui.HideVendorList()
    else ui.ShowVendorList() end
end

-- ---- merchant window: sell everything you marked ------------------------

StaticPopupDialogs["AEGIS_EXCHANGE_VENDORSELL"] = {
    text = "Sell %s to this merchant?\n%s",
    button1 = "Sell", button2 = "Cancel",
    OnAccept = function() ui.DoSellMarked() end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

-- Put an Aegis button on the merchant window showing how many marked stacks
-- are in your bags. Save-and-anchor only, no secure hooks.
function ui.AttachMerchantButton()
    if not MerchantFrame then return end
    if not ui.merchantBtn then
        local b = ui.MakeButton(MerchantFrame, "quiet", "AegisExchangeMerchantSellButton")
        b:SetWidth(150); b:SetHeight(22)
        -- Sit in the tab row, to the right of Merchant / Buyback -- effectively
        -- a third tab position.
        --
        -- Anchoring to the TABS (rather than the frame edge) is what makes this
        -- line up in the stock UI and pfUI alike: pfUI restyles and repositions
        -- the merchant window, but the tabs move with it, so we move too. Every
        -- frame-relative offset we tried drifted between the two, because
        -- pfUI's border is a hairline where vanilla's is thick and ornate.
        local anchor = getglobal("MerchantFrameTab2")
            or getglobal("MerchantFrameTab1")
        if anchor then
            b:SetPoint("LEFT", anchor, "RIGHT", 2, 0)
        else
            -- No tabs (shouldn't happen): fall back to under the frame.
            b:SetPoint("TOP", MerchantFrame, "BOTTOM", 0, -6)
        end
        b:SetFrameStrata("HIGH")
        b:SetScript("OnClick", function() ui.ConfirmSellMarked() end)
        ui.merchantBtn = b
        if A.skin then A.skin.ApplyExternal() end
    end
    ui.RefreshMerchantButton()
end

function ui.RefreshMerchantButton()
    if not ui.merchantBtn then return end
    local rows = A.sell.MarkedInBags()
    local n = table.getn(rows)
    local value = 0
    local i = 1
    while i <= n do value = value + (rows[i].value or 0); i = i + 1 end
    if n == 0 then
        ui.merchantBtn:SetText("Aegis: nothing marked")
        ui.merchantBtn:Disable()
    else
        ui.merchantBtn:SetText("Aegis: sell " .. n .. " marked")
        ui.merchantBtn:Enable()
    end
    ui.merchantMarkedValue = value
end

function ui.ConfirmSellMarked()
    local rows = A.sell.MarkedInBags()
    local n = table.getn(rows)
    if n == 0 then
        ChatMsg("Aegis: nothing marked to sell.")
        return
    end
    -- Name the first few so it's obvious what's about to go.
    local names, i = {}, 1
    while i <= n and i <= 4 do
        table.insert(names, rows[i].name .. " x" .. rows[i].count)
        i = i + 1
    end
    local detail = table.concat(names, ", ")
    if n > 4 then detail = detail .. ", +" .. (n - 4) .. " more" end
    if ui.merchantMarkedValue and ui.merchantMarkedValue > 0 then
        detail = detail .. "\nabout "
            .. util.FormatMoney(ui.merchantMarkedValue) .. " total"
    end
    StaticPopup_Show("AEGIS_EXCHANGE_VENDORSELL", n .. " marked stack(s)", detail)
end

function ui.DoSellMarked()
    local sold, value = A.sell.SellMarkedToVendor()
    if sold == 0 then
        ChatMsg("Aegis: nothing was sold (is the merchant window open?).")
        return
    end
    ChatMsg("Aegis: sold " .. sold .. " stack(s) for about "
        .. util.FormatMoney(value) .. ".")
    -- Vendor sales are income too.
    if value > 0 then
        A.db.RecordTxn("sale", "Vendor sale (" .. sold .. " stacks)", value)
    end
    ui.RefreshMerchantButton()
    if ui.vendList and ui.vendList:IsVisible() then ui.RefreshVendorList() end
    if ui.sellBuilt then ui.RefreshBags() end
end

-- ---- post-scan sell queue ----------------------------------------------
-- After a bag scan, walk the bag items one at a time: the first is placed in
-- the sell slot automatically, and Post or Skip moves on to the next.

-- Build the queue from the current bag contents and slot the first item.
function ui.StartSellQueue()
    local cats = A.sell.ScanBags()
    local q = {}
    local ci = 1
    while ci <= table.getn(cats) do
        local items = cats[ci].items
        local ii = 1
        while ii <= table.getn(items) do
            table.insert(q, items[ii])
            ii = ii + 1
        end
        ci = ci + 1
    end
    ui.sellQueue = q
    ui.sellQueueIndex = 0
    if table.getn(q) == 0 then
        ui.sellQueue = nil
        return
    end
    ui.AdvanceSellQueue()
end

-- Place the next queued item into the sell slot. Ends quietly when exhausted.
function ui.AdvanceSellQueue()
    local q = ui.sellQueue
    if not q then return false end
    local i = (ui.sellQueueIndex or 0) + 1
    -- Skip anything no longer in bags (already posted or moved).
    while i <= table.getn(q) do
        local item = q[i]
        -- Re-locate by itemId: the bag/slot captured when the queue was built
        -- goes stale as posting shifts bags around, which is why the walk
        -- sometimes slotted the wrong item (or nothing) instead of the next one.
        if item.itemId and A.sell.PlaceItemById(item.itemId) then
            ui.sellQueueIndex = i
            ui.RefreshSell()
            if ui.sellStatus then
                ui.sellStatus:SetText("Item " .. i .. " of " .. table.getn(q)
                    .. " \226\128\148 Post or Skip.")
            end
            return true
        end
        i = i + 1
    end
    ui.sellQueue = nil
    ui.sellQueueIndex = nil
    if ui.sellStatus then ui.sellStatus:SetText("Bag list finished.") end
    return false
end

-- Skip button: cancel an in-progress post, else move to the next queued item
-- (or just clear the slot when we're not walking a queue).
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
    ui.sellPrefilledFor = nil
    ui.sellListingGroups = nil
    ui.sellScanState = nil
    SetMoneyBox(ui.sellBuyout, nil)
    SetMoneyBox(ui.sellBid, nil)
    ui.UpdateListingsList()
    -- Walking the post-scan list? Move on to the next item.
    if ui.sellQueue and ui.AdvanceSellQueue() then return end
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
    -- Bid is optional: blank means "same as the buyout", which is what the Sell
    -- tab has always done. A bid above the buyout is a typo, not an intent.
    local unitBid = ReadMoneyBox(ui.sellBid)
    if unitBid and unitBuy and unitBid > unitBuy then
        ChatMsg("Aegis: the bid per item can't be above the buyout.")
        return
    end
    local size    = ui.GetStackSize(it)
    local nStacks = ui.GetNumStacks()
    local maxStacks = A.sell.MaxStacks(it.itemId, size)
    if nStacks > maxStacks then nStacks = maxStacks end
    local stackBuyout = math.floor((unitBuy or 0) * size)
    if stackBuyout < 1 then
        ChatMsg("Aegis: enter a buyout per item of at least 1 copper.")
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
        nStacks = nStacks, unitBuyout = unitBuy, unitBid = unitBid,
        minutes = ui.sellDuration,
    }
    -- The Aegis tab can turn the confirmation off, which is what you want when
    -- relisting a stack at a time. Same shape as ui.ConfirmCancelAuction.
    --
    -- The check goes AFTER pendingPost is filled and after every validation
    -- above it: skipping the dialog must skip only the dialog, not the price
    -- and stack checks that decide whether posting is sane at all.
    if A.db.Setting("confirmPost") == false then
        ui.DoPost()
        return
    end
    StaticPopup_Show("AEGIS_EXCHANGE_POST", it.name, detail)
end

function ui.DoPost()
    local p = ui.pendingPost
    if not p then return end
    ui.pendingPost = nil
    ui.sellStatus:SetText("Posting...")
    local ok, err = A.sell.StartPosting(p.itemId, p.itemName, p.size,
        p.nStacks, p.unitBuyout, p.unitBid or p.unitBuyout, p.minutes, {
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
                elseif reason == "nospace" then
                    msg = msg .. " (no free bag slot to split into)"
                elseif reason == "stuck" then
                    msg = msg .. " (couldn't assemble a stack \226\128\148"
                        .. " /aex debug shows why)"
                end
                -- LEFTOVERS STAY TARGETED. Post two stacks of ten out of
                -- twenty-five and the remaining five are re-slotted at the
                -- same price, so the small stack can go straight out without
                -- finding it in the bags and pricing it again.
                --
                -- Gated on the item MATCHING, which is the part that matters:
                -- ui.sellPrefilledFor is what stops the price boxes being
                -- refilled from the market, so carrying it across a different
                -- item would post that one at a stale price -- the worst
                -- thing this tab could do. It is only kept when the item we
                -- just posted is the item now in the slot.
                --
                -- Not while walking a queue (the queue owns what comes next),
                -- and not after a cancel (the user asked to stop).
                local left = p.itemId and A.sell.CountInBags(p.itemId) or 0
                local kept = false
                if A.db.Setting("keepLeftovers") ~= false
                    and reason ~= "cancelled"
                    and not ui.sellQueue
                    and left > 0
                    and A.sell.PlaceItemById(p.itemId) then
                    kept = true
                    -- The holding is smaller now, so the stack controls
                    -- re-derive; the PRICE deliberately does not.
                    ui.sellDefaultsFor = nil
                    msg = msg .. "  " .. left .. " left \226\128\148 "
                        .. "same price, ready to post."
                else
                    ui.lastScanItemId = nil
                    ui.sellDefaultsFor = nil
                    ui.sellPrefilledFor = nil
                end
                ui.sellStatus:SetText(msg)
                ChatMsg("Aegis: " .. msg)
                ui.RefreshSell()
                ui.RefreshBags()
                -- Walking the post-scan bag list? Move to the next item
                -- (unless the user cancelled, which should stop the walk).
                if ui.sellQueue and reason ~= "cancelled" then
                    ui.AdvanceSellQueue()
                end
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

        local check = ui.MakeCheckBox(row, 16,
            "AegisExchangePickerCheck" .. i)
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

    local scanSel = ui.MakeButton(picker, "primary", "AegisExchangePickerScanButton")
    scanSel:SetWidth(150)
    scanSel:SetHeight(22)
    scanSel:SetPoint("BOTTOMLEFT", picker, "BOTTOMLEFT", 12, 12)
    scanSel:SetText("Scan Selected (0)")
    scanSel:SetScript("OnClick", function()
        ui.ScanSelected()
    end)
    ui.scanSelBtn = scanSel

    local clear = ui.MakeButton(picker, "quiet", "AegisExchangePickerClearButton")
    clear:SetWidth(70)
    clear:SetHeight(22)
    clear:SetPoint("LEFT", scanSel, "RIGHT", 6, 0)
    clear:SetText("Clear")
    clear:SetScript("OnClick", function()
        ui.ClearChecks()
    end)

    local closeBtn = ui.MakeButton(picker, "quiet", "AegisExchangePickerCloseButton")
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
    if A.skin then A.skin.ApplyOverlay(ui.picker) end
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

-- Tint a sub-tab. Under the pfUI skin the visible backdrop is pfUI's own child
-- frame (tab.backdrop), so colour that instead of the tab itself.
local function TintTab(tab, bg, border)
    local target = tab
    if tab.backdrop and tab.backdrop.SetBackdropColor then
        target = tab.backdrop
    end
    if not target.SetBackdropColor then return end
    target:SetBackdropColor(bg[1], bg[2], bg[3], 1)
    if target.SetBackdropBorderColor then
        target:SetBackdropBorderColor(border[1], border[2], border[3])
    end
end

function ui.SelectSubTab(name)
    if not ui.subtabs then return end
    ui.selectedSubTab = name
    for k, tab in pairs(ui.subtabs) do
        if k == name then
            TintTab(tab, C.tabOn, C.border)
            tab.label:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
        else
            TintTab(tab, C.tabOff, { 0.30, 0.26, 0.16 })
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
    -- The vendor list belongs to the Sell tab; don't leave it over another.
    if name ~= "Sell" then
        ui.HideVendorList()
    end
    ui.RefreshCurrentTab(true)
end

-- Repaint whichever tab is showing.
--
-- ui.Refresh() only ever touched the scan strip, so resizing the window
-- recomputed nothing: the lists kept the row count they were last painted with
-- and the extra height just went blank. Anything that changes how much room the
-- lists have has to come through here.
function ui.RefreshCurrentTab(requestAuctions)
    local name = ui.selectedSubTab
    if name == "Sell" then
        ui.RefreshBags()
        ui.RefreshSell()
    elseif name == "Buy" then
        ui.RefreshBuy()
    elseif name == "Crafting" then
        ui.RefreshCraft()
    elseif name == "Auctions" then
        -- Only ping the server when actually switching to the tab; a resize
        -- must not fire an owner-list query.
        ui.RefreshAuctions(requestAuctions and true or false)
    elseif name == "History" then
        ui.RefreshHistory()
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

    -- Blizzard's AuctionFrameAuctions_Update() does arithmetic on
    -- AuctionFrameAuctions.page, which its own OnShow normally seeds. We
    -- replace that window, so its Auctions tab may never be shown and the
    -- field stays nil -- then ANY AUCTION_OWNED_LIST_UPDATE (posting,
    -- cancelling, our owner-list request) reaches their handler and throws
    -- "attempt to perform arithmetic on field 'page'". Seed it once here.
    if AuctionFrameAuctions and AuctionFrameAuctions.page == nil then
        AuctionFrameAuctions.page = 0
    end

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
    --
    -- DELIBERATE EXCEPTION to "never parent anything to AuctionFrame": this is
    -- the ONE frame we hang off the Blizzard window, and it has to be, because
    -- it must appear on THEIR window while ours is hidden. Parenting it to
    -- AuctionFrame is what makes it show and hide with the Blizzard AH for
    -- free. Do not read this as leftover overlay code and remove it -- it is
    -- the documented return path (README: "Aegis UI button (on the stock AH)").
    -- Everything else Aegis draws lives under UIParent.
    if not ui.blizSwapBtn then
        local b = ui.MakeButton(AuctionFrame, "quiet", "AegisExchangeSwapButton")
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
        if A.skin then A.skin.ApplyExternal() end
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

-- ---------------------------------------------------------------------------
-- Right-click a bag item to load it into the Sell tab
-- ---------------------------------------------------------------------------

-- Only hijack right-click while the Aegis window is up AND Sell is the visible
-- tab. Everywhere else -- bags open in the world, our other tabs, the stock AH
-- -- right-click keeps its normal meaning, so eating food or opening a container
-- still works exactly as it always did.
function ui.SellRightClickActive()
    return (ui.frame and ui.frame:IsVisible() and true or false)
        and ui.selectedSubTab == "Sell"
        and not A.sell.PostingActive()
end

-- Load (bag, slot) into the sell slot exactly as clicking its "Your Bags" row
-- does, so the undercut prefill and the per-item listing scan both fire the same
-- way. Returns true when we handled the click (caller must then NOT run the
-- default behaviour).
function ui.TrySellFromBag(bag, slot)
    if not bag or not slot then return false end
    if CursorHasItem and CursorHasItem() then return false end
    local link = GetContainerItemLink(bag, slot)
    if not link then return false end
    -- Soulbound / conjured / otherwise unpostable: fall through to the default
    -- action rather than silently swallowing the click.
    if not A.sell.IsAuctionable(bag, slot) then return false end
    local itemId = util.ItemIdFromLink(link)
    if not itemId then return false end
    local texture, count = GetContainerItemInfo(bag, slot)
    -- Via util.ItemInfo like every other caller. The NAME is position 1 and
    -- never moved between client layouts, so this is uniformity rather than a
    -- fix -- but it stops a second return being bolted on here later and
    -- quietly reintroducing the shift.
    local info = util.ItemInfo(link)
    local iname = info and info.name
    if not iname then
        -- Same cold-item-cache fallback sell.ScanBags uses.
        local _, _, n = string.find(link, "%[([^%]]+)%]")
        iname = n
    end
    ui.SelectBagEntry({
        bag = bag, slot = slot, itemId = itemId,
        name = iname or link, texture = texture, count = count or 1,
    })
    return true
end

-- Right-click a bag item while the BUY tab is up: search for it. Mirrors
-- TrySellFromBag's shape but has no "auctionable" gate (you can shop for
-- soulbound/conjured items even though you could never post them yourself).
function ui.BuyRightClickActive()
    return (ui.frame and ui.frame:IsVisible() and true or false)
        and ui.selectedSubTab == "Buy"
end

function ui.TryBuySearchFromBag(bag, slot)
    if not bag or not slot then return false end
    if CursorHasItem and CursorHasItem() then return false end
    local link = GetContainerItemLink(bag, slot)
    if not link then return false end
    -- Via util.ItemInfo like every other caller. The NAME is position 1 and
    -- never moved between client layouts, so this is uniformity rather than a
    -- fix -- but it stops a second return being bolted on here later and
    -- quietly reintroducing the shift.
    local info = util.ItemInfo(link)
    local iname = info and info.name
    if not iname then
        local _, _, n = string.find(link, "%[([^%]]+)%]")
        iname = n
    end
    if not iname then return false end
    local b = ui.ActiveSearchBox()
    if b then b:SetText(iname) end
    ui.DoBuySearch()
    return true
end

-- Save-and-replace (no secure hooks on 1.12) on BOTH right-click paths:
--
--   ContainerFrameItemButton_OnClick -- the stock bag buttons.
--   UseContainerItem                 -- where every bag addon's right-click
--                                       ultimately lands, so replacement bag
--                                       UIs (pfUI, Stonkz's Bags, ...) work too.
--
-- The first hook returns without chaining when it handles the click, so the
-- second never double-fires for the stock bags. Sell (place in slot) and Buy
-- (search for it) are mutually exclusive by construction -- each Active()
-- check requires its OWN sub-tab to be the visible one.
function ui.HookBagRightClick()
    if ui.bagClickHooked then return end
    ui.bagClickHooked = true

    local function tryHandle(bag, slot)
        if ui.SellRightClickActive() and ui.TrySellFromBag(bag, slot) then
            return true
        end
        if ui.BuyRightClickActive() and ui.TryBuySearchFromBag(bag, slot) then
            return true
        end
        return false
    end

    if ContainerFrameItemButton_OnClick then
        ui.orig_ContainerFrameItemButton_OnClick = ContainerFrameItemButton_OnClick
        ContainerFrameItemButton_OnClick = function(button, ignoreModifiers)
            if button == "RightButton" then
                -- `this` is the clicked item button; its parent carries the bag id.
                local btn = this
                local parent = btn and btn.GetParent and btn:GetParent() or nil
                local bag = parent and parent.GetID and parent:GetID() or nil
                local slot = btn and btn.GetID and btn:GetID() or nil
                if tryHandle(bag, slot) then return end
            end
            return ui.orig_ContainerFrameItemButton_OnClick(button, ignoreModifiers)
        end
    end

    if UseContainerItem then
        ui.orig_UseContainerItem = UseContainerItem
        UseContainerItem = function(bag, slot, onSelf)
            if tryHandle(bag, slot) then return end
            return ui.orig_UseContainerItem(bag, slot, onSelf)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Shift-click an item to search for it on the Buy tab
--
-- The ROADMAP quick win is worded as "drag an inventory item onto the search
-- box, or right-click an item link in chat". 1.12 has no generic way to ask
-- "what item is on the cursor" for an arbitrary custom frame like our search
-- box -- that only exists for API-blessed drop targets (the AH's own sell
-- slot uses ClickAuctionSellItemButton precisely because of this gap). Assume
-- the generic form does not exist, per CLAUDE.md.
--
-- What 1.12 DOES have, and is the standard vanilla idiom for exactly this
-- interaction, is HandleModifiedItemClick(itemLink) -- the single global every
-- shift-click on an item funnels through, whether the item is in a bag, a
-- tooltip, an AH row, OR a chat link. Hooking it covers both halves of the
-- ROADMAP bullet with one well-understood, save-and-replace-safe hook instead
-- of two separate guesses at cursor APIs.
function ui.HookItemShiftClick()
    if ui.shiftClickHooked then return end
    ui.shiftClickHooked = true
    if not HandleModifiedItemClick then return end

    ui.orig_HandleModifiedItemClick = HandleModifiedItemClick
    HandleModifiedItemClick = function(link)
        if ui.BuyRightClickActive() and IsShiftKeyDown and IsShiftKeyDown()
            and link then
            local shiftInfo = util.ItemInfo(link)
            local name = shiftInfo and shiftInfo.name
            if not name then
                local _, _, n = string.find(link, "%[([^%]]+)%]")
                name = n
            end
            if name then
                local b = ui.ActiveSearchBox()
                if b then b:SetText(name) end
                ui.DoBuySearch()
                return
            end
        end
        return ui.orig_HandleModifiedItemClick(link)
    end
end

function ui.OpenWindow()
    ui.BuildWindow()
    ui.HookAuctionFrame()
    ui.HookBagRightClick()
    ui.HookItemShiftClick()
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
    -- Clear the Sell tab's per-item cache so next session gets fresh prices.
    A.sell.StopBatchScan()
    A.sell.cache = {}
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

-- The mailbox updated (opened one, or took mail): log any AH sale mail so the
-- History tab tracks income even when the AH window isn't open.
A.RegisterEvent("MAIL_INBOX_UPDATE", function()
    ui.ScanMailSales()
end)

-- At a merchant: offer to sell everything marked on the Vendor list.
A.RegisterEvent("MERCHANT_SHOW", function()
    ui.AttachMerchantButton()
end)
-- Bags change as items are sold; keep the button's count honest.
A.RegisterEvent("BAG_UPDATE", function()
    if ui.merchantBtn and MerchantFrame and MerchantFrame:IsVisible() then
        ui.RefreshMerchantButton()
    end
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
