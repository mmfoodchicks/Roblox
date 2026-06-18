--!strict
--[[
	MerchantController
	------------------
	Client module (StarterPlayerScripts.Controllers.MerchantController).

	Bridges the cavern's merchant-stand ProximityPrompts to the shop UIs. Each
	stand's prompt carries an "OpenUI" attribute (set by MapBuilder); when the
	local player triggers one, the matching window opens. The prompt itself only
	appears when the player is close, so the market stays uncluttered until you
	walk up to a stand.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")

local ShopController = require(script.Parent.ShopController)
local InventoryController = require(script.Parent.InventoryController)
local CrateController = require(script.Parent.CrateController)
local StoreController = require(script.Parent.StoreController)
local DailyController = require(script.Parent.DailyController)

local LocalPlayer = Players.LocalPlayer

local MerchantController = {}

-- Maps an "OpenUI" attribute value to the controller that should open.
local openers: { [string]: () -> () } = {
	Shop = function()
		ShopController:Open()
	end,
	Inventory = function()
		InventoryController:Open()
	end,
	Crates = function()
		CrateController:Open()
	end,
	Store = function()
		StoreController:Open()
	end,
	Daily = function()
		DailyController:Open()
	end,
}

function MerchantController:Init()
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
		if player ~= LocalPlayer then
			return
		end
		local key = prompt:GetAttribute("OpenUI")
		if type(key) == "string" then
			local opener = openers[key]
			if opener ~= nil then
				opener()
			end
		end
	end)
end

return MerchantController
