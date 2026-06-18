--!strict
--[[
	ShopService
	-----------
	Server module (ServerScriptService.Services.ShopService).

	Authoritative handler for economy actions, exposed through the
	ReplicatedStorage.ShopFunction RemoteFunction. Every price check and coin
	deduction happens here against GameConfig; the client only ever requests.

	Request:  ShopFunction:InvokeServer(action: string, payload: table?)
	Response: { success: boolean, reason: string?, [extra fields] }

	Actions:
	  "BuyRod"   {rodId}  Unlock + equip a rod (charges Price once; equips free if
	                      already owned).
	  "EquipRod" {rodId}  Equip a rod the player already owns.
	  "BuyLuck"           Advance LuckLevel by one (geometric cost).
	  "SellAll"           Convert the whole inventory to coins.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local DataService = require(ServerScriptService.Services.DataService)
local BoostService = require(ServerScriptService.Services.BoostService)

local ShopFunction = ReplicatedStorage:WaitForChild("ShopFunction") :: RemoteFunction

local ShopService = {}

type Response = { success: boolean, reason: string?, [string]: any }

local function fail(reason: string): Response
	return { success = false, reason = reason }
end

-- ---------------------------------------------------------------------------
-- Action handlers
-- ---------------------------------------------------------------------------

local function buyRod(player: Player, payload: { [string]: any }): Response
	local rodId = payload.rodId
	if type(rodId) ~= "string" or GameConfig.Rods[rodId] == nil then
		return fail("Unknown rod.")
	end

	local data = DataService:GetData(player)
	if data == nil then
		return fail("Data unavailable.")
	end

	-- Already owned -> just equip it (no charge).
	if data.OwnedRods[rodId] then
		DataService:SetActiveRod(player, rodId)
		return { success = true, equipped = true }
	end

	local rod = GameConfig.GetRod(rodId)
	if data.Coins < rod.Price then
		return fail("Not enough coins.")
	end

	-- Charge, grant, equip. AwardCoins clamps at zero but we pre-checked above.
	DataService:AwardCoins(player, -rod.Price)
	DataService:SetOwnedRod(player, rodId, true)
	DataService:SetActiveRod(player, rodId)
	return { success = true, purchased = true }
end

local function equipRod(player: Player, payload: { [string]: any }): Response
	local rodId = payload.rodId
	if type(rodId) ~= "string" or GameConfig.Rods[rodId] == nil then
		return fail("Unknown rod.")
	end
	if DataService:SetActiveRod(player, rodId) then
		return { success = true }
	end
	return fail("You don't own that rod.")
end

local function buyLuck(player: Player): Response
	local data = DataService:GetData(player)
	if data == nil then
		return fail("Data unavailable.")
	end

	local cost = GameConfig.GetLuckUpgradeCost(data.LuckLevel)
	if cost == nil then
		return fail("Luck is already maxed.")
	end
	if data.Coins < cost then
		return fail("Not enough coins.")
	end

	DataService:AwardCoins(player, -cost)
	DataService:SetLuckLevel(player, data.LuckLevel + 1)
	return { success = true, level = data.LuckLevel + 1 }
end

local function sellAll(player: Player): Response
	local data = DataService:GetData(player)
	if data == nil then
		return fail("Data unavailable.")
	end
	if #data.Inventory == 0 then
		return fail("Nothing to sell.")
	end

	-- Clear first (returns the summed base value), then apply any coin multiplier
	-- from monetization perks (VIP / Premium) before crediting.
	local base = DataService:ClearInventory(player)
	if base == nil then
		return fail("Data unavailable.")
	end
	local multiplier = BoostService:GetCoinMultiplier(player)
	local earned = math.floor(base * multiplier + 0.5)
	DataService:AwardCoins(player, earned)
	return { success = true, earned = earned, base = base, multiplier = multiplier }
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

local function onInvoke(player: Player, action: unknown, payload: unknown): Response
	local safePayload: { [string]: any } = if type(payload) == "table" then payload :: any else {}

	if action == "BuyRod" then
		return buyRod(player, safePayload)
	elseif action == "EquipRod" then
		return equipRod(player, safePayload)
	elseif action == "BuyLuck" then
		return buyLuck(player)
	elseif action == "SellAll" then
		return sellAll(player)
	end

	return fail("Unknown action.")
end

function ShopService:Init()
	ShopFunction.OnServerInvoke = function(player: Player, action: unknown, payload: unknown)
		-- Wrap in pcall so a malformed request can never error the RemoteFunction
		-- thread (which would yield the client forever).
		local ok, result = pcall(onInvoke, player, action, payload)
		if ok then
			return result
		end
		warn("[ShopService] action failed:", result)
		return fail("Internal error.")
	end
end

return ShopService
