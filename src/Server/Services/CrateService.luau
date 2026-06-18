--!strict
--[[
	CrateService
	------------
	Server module (ServerScriptService.Services.CrateService).

	The authoritative gacha engine. Opens crates, rolls a reward with
	CrateConfig, grants it, and tells the client what was won so it can play the
	reveal animation. Two entry points:

	  * Coin/Key opens  — client invokes ReplicatedStorage.CrateFunction("Open",
	    {crateKey}); the rolled reward is returned in the response.
	  * Robux opens     — MonetizationService calls OpenFromReceipt() after a
	    successful Developer Product purchase; the reward is pushed over
	    ReplicatedStorage.CrateNetwork ("Reveal").

	Grants never trust the client: payment, roll and grant all happen here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CrateConfig = require(ReplicatedStorage.Shared.CrateConfig)
local DataService = require(script.Parent.DataService)
local BoostService = require(script.Parent.BoostService)

local CrateFunction = ReplicatedStorage:WaitForChild("CrateFunction") :: RemoteFunction
local CrateNetwork = ReplicatedStorage:WaitForChild("CrateNetwork") :: RemoteEvent

local CrateService = {}

-- A client-facing description of what was won (drives the reveal UI).
export type RewardSummary = {
	Type: string,
	Ref: string?,
	Name: string,
	Rarity: string?,
	Amount: number?,
	Color: Color3,
}

type Response = { success: boolean, reason: string?, reward: RewardSummary?, crateKey: string? }

local function fail(reason: string): Response
	return { success = false, reason = reason }
end

-- ---------------------------------------------------------------------------
-- Granting
-- ---------------------------------------------------------------------------

-- Applies a rolled reward to the player and returns a summary for the client.
-- Optional fields are copied to locals so the nil-checks narrow under strict.
local function grantReward(player: Player, reward: CrateConfig.Reward): RewardSummary
	local ref = reward.Ref
	local amount = reward.Amount
	local multiplier = reward.Multiplier
	local duration = reward.Duration

	if reward.Type == "Pet" and ref ~= nil then
		local pet = CrateConfig.GetPet(ref)
		if pet ~= nil then
			DataService:AddPet(player, pet.Id, 1)
			return {
				Type = "Pet",
				Ref = pet.Id,
				Name = pet.Name,
				Rarity = pet.Rarity,
				Color = pet.Color,
			}
		end
	elseif reward.Type == "Coins" and amount ~= nil then
		DataService:AwardCoins(player, amount)
		return {
			Type = "Coins",
			Name = amount .. " Coins",
			Amount = amount,
			Color = Color3.fromRGB(240, 200, 90),
		}
	elseif reward.Type == "Keys" and amount ~= nil then
		DataService:AddKeys(player, amount)
		return {
			Type = "Keys",
			Name = amount .. " Keys",
			Amount = amount,
			Color = Color3.fromRGB(120, 220, 240),
		}
	elseif reward.Type == "LuckPotion" and multiplier ~= nil and duration ~= nil then
		BoostService:ApplyLuckBoost(player, multiplier, duration)
		return {
			Type = "LuckPotion",
			Name = string.format("%gx Luck Potion", multiplier),
			Color = Color3.fromRGB(190, 96, 255),
		}
	end

	-- Defensive fallback (malformed pool entry): grant a tiny coin consolation.
	DataService:AwardCoins(player, 100)
	return { Type = "Coins", Name = "100 Coins", Amount = 100, Color = Color3.fromRGB(240, 200, 90) }
end

-- Rolls + grants a crate, returning the summary (used by both open paths).
local function rollAndGrant(player: Player, crateKey: string): RewardSummary?
	local reward = CrateConfig.RollCrate(crateKey)
	if reward == nil then
		return nil
	end
	return grantReward(player, reward)
end

-- ---------------------------------------------------------------------------
-- Open paths
-- ---------------------------------------------------------------------------

-- Coin/Key open requested by the client.
local function open(player: Player, crateKey: string): Response
	local crate = CrateConfig.GetCrate(crateKey)
	if crate == nil then
		return fail("Unknown crate.")
	end

	local data = DataService:GetData(player)
	if data == nil then
		return fail("Data unavailable.")
	end

	-- Charge the appropriate currency (pre-checked so we never clamp to zero).
	if crate.CostType == "Coins" then
		if data.Coins < crate.Cost then
			return fail("Not enough coins.")
		end
		DataService:AwardCoins(player, -crate.Cost)
	elseif crate.CostType == "Keys" then
		if data.Keys < crate.Cost then
			return fail("Not enough keys.")
		end
		DataService:AddKeys(player, -crate.Cost)
	else
		return fail("This crate isn't opened with currency.")
	end

	local summary = rollAndGrant(player, crateKey)
	if summary == nil then
		return fail("Roll failed.")
	end
	return { success = true, reward = summary, crateKey = crateKey }
end

--[[
	OpenFromReceipt
	Called by MonetizationService after a Robux crate-open product is purchased.
	Rolls, grants, and pushes the reveal to the client.
]]
function CrateService:OpenFromReceipt(player: Player, crateKey: string)
	local summary = rollAndGrant(player, crateKey)
	if summary ~= nil then
		CrateNetwork:FireClient(player, "Reveal", { crateKey = crateKey, reward = summary })
	end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function CrateService:Init()
	CrateFunction.OnServerInvoke = function(player: Player, action: unknown, payload: unknown)
		local ok, result = pcall(function(): Response
			if action == "Open" then
				local safePayload: { [string]: any } = if type(payload) == "table" then payload :: any else {}
				return open(player, tostring(safePayload.crateKey))
			end
			return fail("Unknown action.")
		end)
		if ok then
			return result
		end
		warn("[CrateService] open failed:", result)
		return fail("Internal error.")
	end
end

return CrateService
