-- Aegis: Exchange -- skin for pfUI-addonskinner
--
-- OPTIONAL. Aegis skins itself when pfUI is present, so you do not need this
-- file. It exists for people who manage every skin through
-- pfUI-addonskinner (https://github.com/mrrosh/pfUI-addonskinner) and want
-- Aegis to appear in that addon's list with the rest.
--
-- To use it:
--   1. Copy this file to  Interface/AddOns/pfUI-addonskinner/skins/Aegis_Exchange.lua
--   2. Add this line to pfUI-addonskinner.toc, under "# skins":
--          skins\Aegis_Exchange.lua
--   3. Restart the client.
--
-- All it does is call Aegis's own skinning routine, so the look stays in one
-- place and cannot drift between the two paths.

pfUI.addonskinner:RegisterSkin("Aegis_Exchange", function()
    if AegisExchange and AegisExchange.skin then
        -- The window is built lazily (first time you open the auction house),
        -- so Apply() is also re-run from Aegis itself after the build. Calling
        -- it here covers the case where the window already exists.
        AegisExchange.skin.Apply()
    end

    -- Remove from the pending list now that it has been applied.
    pfUI.addonskinner:UnregisterSkin("Aegis_Exchange")
end)
