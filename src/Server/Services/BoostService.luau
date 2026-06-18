--!strict
--[[
	BoostService
	------------
	Server module (ServerScriptService.Services.BoostService).

	The single source of truth for a player's luck and coin multipliers. It
	aggregates every stacking bonus so gameplay systems (FishingService,
	ShopService, Auto Fisher) ask exactly one place:

	  * Game passes      (VIP coin/luck, Lucky Charm luck)        — from data.Passes
	  * Roblox Premium   (coin bonus)                             — from data.IsPremium
	  * Equipped pets    (luck/coin bonuses)                      — from data.EquippedPets
	  * Timed luck potions (from crates / products / daily)       — in-memory here

	Keeping this independent of MonetizationService/CrateService avoids cyclic
	requires: both of those depend on BoostService, never the other way round.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage.Shared.MonetizationConfig)
local CrateConfig = require(ReplicatedStorage.Shared.CrateConfig)
local DataService = require(script.Parent.DataService)

local FishingNetwork = ReplicatedStorage:WaitForChild("FishingNetwork") :: RemoteEvent

local BoostService = {}

-- In-memory, non-persisted timed luck boosts (from Luck Potions).
type Boost = { multiplier: number, expiresAt: number }
local luckBoosts: { [Player]: Boost } = {}

-- ---------------------------------------------------------------------------
-- Aggregated multipliers
-- ---------------------------------------------------------------------------

--[[
	GetLuckMultiplier
	Product of: Lucky-Charm/VIP passes, equipped pet luck bonuses, and any active
	luck potion. Returns 1.0 when nothing applies.
]]
function BoostService:GetLuckMultiplier(player: Player): number
	local data = DataService:GetData(player)
	if data == nil then
		return 1
	end

	local multiplier = 1

	-- Passes.
	for _, pass in pairs(MonetizationConfig.GamePasses) do
		if pass.LuckMultiplier ~= nil and data.Passes[pass.Key] then
			multiplier *= pass.LuckMultiplier
		end
	end

	-- Equipped pets (their bonuses sum into a single multiplier).
	local petBonus = 0
	for _, petId in ipairs(data.EquippedPets) do
		local pet = CrateConfig.GetPet(petId)
		if pet ~= nil then
			petBonus += pet.LuckBonus
		end
	end
	multiplier *= (1 + petBonus)

	-- Timed potion.
	local boost = luckBoosts[player]
	if boost ~= nil and os.clock() < boost.expiresAt then
		multiplier *= boost.multiplier
	end

	return multiplier
end

--[[
	GetCoinMultiplier
	Product of: VIP pass, Roblox Premium, and equipped pet coin bonuses.
]]
function BoostService:GetCoinMultiplier(player: Player): number
	local data = DataService:GetData(player)
	if data == nil then
		return 1
	end

	local multiplier = 1

	for _, pass in pairs(MonetizationConfig.GamePasses) do
		if pass.CoinMultiplier ~= nil and data.Passes[pass.Key] then
			multiplier *= pass.CoinMultiplier
		end
	end
	if data.IsPremium then
		multiplier *= MonetizationConfig.PremiumCoinMultiplier
	end

	local petBonus = 0
	for _, petId in ipairs(data.EquippedPets) do
		local pet = CrateConfig.GetPet(petId)
		if pet ~= nil then
			petBonus += pet.CoinBonus
		end
	end
	multiplier *= (1 + petBonus)

	return multiplier
end

-- ---------------------------------------------------------------------------
-- Timed luck potions
-- ---------------------------------------------------------------------------

--[[
	ApplyLuckBoost
	Starts (or replaces) a timed luck multiplier and notifies the client.
]]
function BoostService:ApplyLuckBoost(player: Player, multiplier: number, duration: number)
	luckBoosts[player] = {
		multiplier = multiplier,
		expiresAt = os.clock() + duration,
	}
	FishingNetwork:FireClient(player, "Notice", {
		text = string.format("Luck Potion active: x%g for %d min!", multiplier, math.max(1, math.floor(duration / 60))),
	})
end

function BoostService:Init()
	Players.PlayerRemoving:Connect(function(player: Player)
		luckBoosts[player] = nil
	end)
end

return BoostService
