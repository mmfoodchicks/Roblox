--!strict
--[[
	DailyRewardService
	------------------
	Server module (ServerScriptService.Services.DailyRewardService).

	Authoritative daily-reward streak. A claim becomes available 20h after the
	last; missing the window (DailyConfig.ResetAfter) resets the streak to 1.
	Grants escalating rewards from DailyConfig.

	Exposed via ReplicatedStorage.DailyFunction:
	  "Claim"  ->  { success, reason?, streak?, label? }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DailyConfig = require(ReplicatedStorage.Shared.DailyConfig)
local CrateConfig = require(ReplicatedStorage.Shared.CrateConfig)
local DataService = require(script.Parent.DataService)
local BoostService = require(script.Parent.BoostService)

local DailyFunction = ReplicatedStorage:WaitForChild("DailyFunction") :: RemoteFunction

local DailyRewardService = {}

type Response = { success: boolean, reason: string?, streak: number?, label: string? }

local function grantDaily(player: Player, reward: DailyConfig.DailyReward)
	if reward.Type == "Coins" and reward.Amount ~= nil then
		DataService:AwardCoins(player, reward.Amount)
	elseif reward.Type == "Keys" and reward.Amount ~= nil then
		DataService:AddKeys(player, reward.Amount)
	elseif reward.Type == "Pet" and reward.Ref ~= nil then
		local pet = CrateConfig.GetPet(reward.Ref)
		if pet ~= nil then
			DataService:AddPet(player, pet.Id, 1)
		end
	elseif reward.Type == "LuckPotion" and reward.Multiplier ~= nil and reward.Duration ~= nil then
		BoostService:ApplyLuckBoost(player, reward.Multiplier, reward.Duration)
	end
end

local function claim(player: Player): Response
	local data = DataService:GetData(player)
	if data == nil then
		return { success = false, reason = "Data unavailable." }
	end

	local now = os.time()
	local sinceLast = now - data.LastDailyClaim

	-- Still on cooldown?
	if data.LastDailyClaim > 0 and sinceLast < DailyConfig.ClaimCooldown then
		local hours = math.ceil((DailyConfig.ClaimCooldown - sinceLast) / 3600)
		return { success = false, reason = string.format("Next reward in ~%dh.", hours) }
	end

	-- Continue or reset the streak.
	local streak: number
	if data.LastDailyClaim == 0 or sinceLast > DailyConfig.ResetAfter then
		streak = 1
	else
		streak = data.DailyStreak + 1
	end

	local reward = DailyConfig.GetReward(streak)
	grantDaily(player, reward)
	DataService:SetDailyClaim(player, streak, now)

	return { success = true, streak = streak, label = reward.Label }
end

function DailyRewardService:Init()
	DailyFunction.OnServerInvoke = function(player: Player, action: unknown)
		if action == "Claim" then
			local ok, result = pcall(claim, player)
			if ok then
				return result
			end
			warn("[DailyRewardService] claim failed:", result)
			return { success = false, reason = "Internal error." }
		end
		return { success = false, reason = "Unknown action." }
	end
end

return DailyRewardService
