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

    -- Widgets that opt out: bare-text sort headers and our row buttons that
    -- must keep their own look. Marked with aegisNoSkin at creation.
    if f.aegisNoSkin then
        f.aegisSkinned = true
        return false
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
        if b and not b.aegisSkinned then
            Button(b)
            b.aegisSkinned = true
        end
        i = i + 1
    end
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
