-- Aegis: Exchange
-- ui/frame.lua
--
-- Attaches an "Aegis" tab to the vanilla AuctionFrame -- STUB. Creates the tab
-- scaffolding only; no panel contents yet.
--
-- The auction UI is a load-on-demand addon (Blizzard_AuctionUI): AuctionFrame
-- does not exist until the player first opens an auctioneer. We therefore wait
-- for that addon to load (and also try on AUCTION_HOUSE_SHOW as a fallback).
--
-- Dynamic frame names are resolved with getglobal(); frames are built with
-- CreateFrame using vanilla templates (here: AuctionFrameTab).

local A = AegisExchange
A.ui = A.ui or {}
local ui = A.ui

-- Guard so we only attach our tab once.
ui.tabAttached = false

-- Create and wire our tab into the AuctionFrame tab strip. STUB.
function ui.AttachTab()
    if ui.tabAttached then return end
    if not AuctionFrame then return end   -- auction UI not loaded yet

    -- Blizzard tracks the tab count as AuctionFrame.numTabs (Browse/Bid/
    -- Auctions == 3 in vanilla). Our tab takes the next index.
    local index    = (AuctionFrame.numTabs or 3) + 1
    local tabName  = "AegisExchangeAuctionTab"
    local prevName = "AuctionFrameTab" .. (index - 1)

    -- CreateFrame with the vanilla AuctionFrameTab template.
    local tab = CreateFrame("Button", tabName, AuctionFrame, "AuctionFrameTab")
    tab:SetID(index)
    tab:SetText("Aegis")
    tab:SetPoint("LEFT", getglobal(prevName), "RIGHT", -8, 0)

    -- TODO: hook the tab into AuctionFrame's tab-switch machinery and build
    -- the panel shown when it is selected.

    AuctionFrame.numTabs = index
    ui.tab         = tab
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
