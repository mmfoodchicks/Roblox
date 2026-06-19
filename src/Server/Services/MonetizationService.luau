--!strict
--[[
	MonetizationService
	-------------------
	Server module (ServerScriptService.Services.MonetizationService).

	Owns the Robux purchase surface:

	  * Verifies Game Pass ownership on join (UserOwnsGamePassAsync) and caches it.
	  * Tracks Roblox Premium status (passive coin bonus + Premium Payouts).
	  * Grants Developer Product purchases through an idempotent ProcessReceipt
	    (coins, keys, crate opens, luck potions).
	  * Runs the Auto Fisher perk (server-side passive catching).

	Stacking multipliers live in BoostService; this service only flips ownership
	flags and routes purchases. That keeps it free of cyclic requires.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LootManager = require(ReplicatedStorage.Shared.LootManager)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.MonetizationConfig)
local DataService = require(script.Parent.DataService)
local BoostService = require(script.Parent.BoostService)
local CrateService = require(script.Parent.CrateService)

local FishingNetwork = ReplicatedStorage:WaitForChild("FishingNetwork") :: RemoteEvent

local MonetizationService = {}

-- Auto Fisher per-player accumulators.
local autoTimers: { [Player]: number } = {}

-- ---------------------------------------------------------------------------
-- Auto Fisher
-- ---------------------------------------------------------------------------

local function ownsAutoFish(player: Player): boolean
	local data = DataService:GetData(player)
	if data == nil then
		return false
	end
	for _, pass in pairs(MonetizationConfig.GamePasses) do
		if pass.AutoFish and data.Passes[pass.Key] then
			return true
		end
	end
	return false
end

local function autoCatch(player: Player)
	local data = DataService:GetData(player)
	if data == nil then
		return
	end

	local rod = GameConfig.GetRod(data.ActiveRod)
	local luck = GameConfig.GetLuckMultiplier(data.LuckLevel)
		* rod.LuckMultiplier
		* BoostService:GetLuckMultiplier(player)
	local caught = LootManager.RollCatch(luck, rod.ValueMultiplier)

	DataService:AddToInventory(player, {
		Id = caught.Item.Id,
		Name = caught.Item.Name,
		Rarity = caught.Item.Rarity,
		Value = caught.Value,
		CaughtAt = os.time(),
	})

	local odds = LootManager.GetTierOdds(luck)
	FishingNetwork:FireClient(player, "CatchResult", {
		success = true,
		auto = true,
		item = {
			Id = caught.Item.Id,
			Name = caught.Item.Name,
			Rarity = caught.Item.Rarity,
			Color = caught.Item.Color,
		},
		value = caught.Value,
		chance = odds[caught.Item.Rarity],
	})
end

-- ---------------------------------------------------------------------------
-- Ownership / membership refresh
-- ---------------------------------------------------------------------------

local function refreshOwnership(player: Player)
	DataService:SetPremium(player, player.MembershipType == Enum.MembershipType.Premium)

	for _, pass in pairs(MonetizationConfig.GamePasses) do
		if pass.Id ~= 0 then
			local ok, owns = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.Id)
			end)
			if ok then
				DataService:SetPass(player, pass.Key, owns == true)
			else
				warn("[MonetizationService] UserOwnsGamePassAsync failed for", pass.Key, owns)
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Receipt processing (Developer Products)
-- ---------------------------------------------------------------------------

local function grantProduct(player: Player, product: MonetizationConfig.Product)
	local coins = product.Coins
	if coins ~= nil then
		DataService:AwardCoins(player, coins)
	end

	local keys = product.Keys
	if keys ~= nil then
		DataService:AddKeys(player, keys)
	end

	local crateKey = product.Crate
	if crateKey ~= nil then
		CrateService:OpenFromReceipt(player, crateKey)
	end

	local luckMultiplier = product.LuckMultiplier
	local luckDuration = product.LuckDuration
	if luckMultiplier ~= nil and luckDuration ~= nil then
		BoostService:ApplyLuckBoost(player, luckMultiplier, luckDuration)
	end
end

local function processReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if player == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local data = DataService:GetData(player)
	if data == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseKey = tostring(receiptInfo.PurchaseId)
	if DataService:HasHandledPurchase(player, purchaseKey) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local product = MonetizationConfig.GetProductById(receiptInfo.ProductId)
	if product == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	grantProduct(player, product)

	-- Record before acknowledging so a retry can't double-grant.
	DataService:RecordPurchase(player, purchaseKey)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function MonetizationService:Init()
	MarketplaceService.ProcessReceipt = processReceipt

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, gamePassId: number, wasPurchased: boolean)
			if wasPurchased then
				local pass = MonetizationConfig.GetPassById(gamePassId)
				if pass ~= nil then
					DataService:SetPass(player, pass.Key, true)
				end
			end
		end
	)

	DataService.ProfileLoaded:Connect(function(player: Player)
		task.spawn(refreshOwnership, player)
	end)

	Players.PlayerMembershipChanged:Connect(function(player: Player)
		DataService:SetPremium(player, player.MembershipType == Enum.MembershipType.Premium)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		autoTimers[player] = nil
	end)

	RunService.Heartbeat:Connect(function(deltaTime: number)
		for _, player in ipairs(Players:GetPlayers()) do
			if ownsAutoFish(player) then
				local elapsed = (autoTimers[player] or 0) + deltaTime
				if elapsed >= MonetizationConfig.AutoFishInterval then
					elapsed = 0
					autoCatch(player)
				end
				autoTimers[player] = elapsed
			end
		end
	end)
end

return MonetizationService
