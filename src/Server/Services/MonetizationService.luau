--!strict
--[[
	MonetizationService
	-------------------
	Server module (ServerScriptService.Services.MonetizationService).

	The authoritative Robux monetization engine:

	  * Verifies Game Pass ownership on join (UserOwnsGamePassAsync) and caches it.
	  * Tracks Roblox Premium status (passive coin bonus + Premium Payouts).
	  * Grants Developer Product purchases through an idempotent ProcessReceipt.
	  * Exposes GetCoinMultiplier / GetLuckMultiplier that FishingService and
	    ShopService consult so perks actually affect gameplay.
	  * Runs the Auto Fisher perk (server-side passive catching).
	  * Applies timed luck boosts (from the Luck Potion product).

	No client trusts: ownership and grants are decided here; the client only
	prompts purchases.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local LootManager = require(ReplicatedStorage.Shared.LootManager)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.MonetizationConfig)
local DataService = require(ServerScriptService.Services.DataService)

local FishingNetwork = ReplicatedStorage:WaitForChild("FishingNetwork") :: RemoteEvent

local MonetizationService = {}

-- In-memory, non-persisted temporary luck boosts (from the Luck Potion).
type Boost = { multiplier: number, expiresAt: number }
local luckBoosts: { [Player]: Boost } = {}

-- Auto Fisher per-player accumulators.
local autoTimers: { [Player]: number } = {}

-- ---------------------------------------------------------------------------
-- Multiplier queries (read by FishingService / ShopService)
-- ---------------------------------------------------------------------------

--[[
	GetCoinMultiplier
	Combined coin multiplier from owned passes and Premium. 1.0 when nothing
	applies.
]]
function MonetizationService:GetCoinMultiplier(player: Player): number
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
	return multiplier
end

--[[
	GetLuckMultiplier
	Combined luck multiplier from owned passes and any active timed boost.
]]
function MonetizationService:GetLuckMultiplier(player: Player): number
	local data = DataService:GetData(player)
	if data == nil then
		return 1
	end

	local multiplier = 1
	for _, pass in pairs(MonetizationConfig.GamePasses) do
		if pass.LuckMultiplier ~= nil and data.Passes[pass.Key] then
			multiplier *= pass.LuckMultiplier
		end
	end

	local boost = luckBoosts[player]
	if boost ~= nil and os.clock() < boost.expiresAt then
		multiplier *= boost.multiplier
	end
	return multiplier
end

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

-- ---------------------------------------------------------------------------
-- Timed boosts
-- ---------------------------------------------------------------------------

function MonetizationService:ApplyLuckBoost(player: Player, multiplier: number, duration: number)
	luckBoosts[player] = {
		multiplier = multiplier,
		expiresAt = os.clock() + duration,
	}
	-- Lightweight client feedback (FishingController shows it as a toast).
	FishingNetwork:FireClient(player, "Notice", {
		text = string.format("Luck Potion active: x%g for %d min!", multiplier, math.floor(duration / 60)),
	})
end

-- ---------------------------------------------------------------------------
-- Auto Fisher
-- ---------------------------------------------------------------------------

local function autoCatch(player: Player)
	local data = DataService:GetData(player)
	if data == nil then
		return
	end

	local rod = GameConfig.GetRod(data.ActiveRod)
	local luck = GameConfig.GetLuckMultiplier(data.LuckLevel)
		* rod.LuckMultiplier
		* MonetizationService:GetLuckMultiplier(player)
	local caught = LootManager.RollCatch(luck, rod.ValueMultiplier)

	DataService:AddToInventory(player, {
		Id = caught.Item.Id,
		Name = caught.Item.Name,
		Rarity = caught.Item.Rarity,
		Value = caught.Value,
		CaughtAt = os.time(),
	})

	-- Feedback flagged auto = true so the client can render it more subtly.
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
	})
end

-- ---------------------------------------------------------------------------
-- Ownership / membership refresh
-- ---------------------------------------------------------------------------

local function refreshOwnership(player: Player)
	-- Premium status (drives the coin bonus + Premium Payouts eligibility).
	DataService:SetPremium(player, player.MembershipType == Enum.MembershipType.Premium)

	-- Verify each configured game pass against Roblox.
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

local function processReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if player == nil then
		-- Player left before we could grant; let Roblox retry when they return.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local data = DataService:GetData(player)
	if data == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseKey = tostring(receiptInfo.PurchaseId)

	-- Idempotency: if we already granted this exact receipt, acknowledge it.
	if DataService:HasHandledPurchase(player, purchaseKey) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local product = MonetizationConfig.GetProductById(receiptInfo.ProductId)
	if product == nil then
		-- Unknown product id — do not consume; let Roblox retry.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Grant the product's effects. (Fields copied to locals so the nil-checks
	-- narrow cleanly under strict typing.)
	local coins = product.Coins
	if coins ~= nil then
		DataService:AwardCoins(player, coins)
	end
	local luckMultiplier = product.LuckMultiplier
	local luckDuration = product.LuckDuration
	if luckMultiplier ~= nil and luckDuration ~= nil then
		MonetizationService:ApplyLuckBoost(player, luckMultiplier, luckDuration)
	end

	-- Record before acknowledging so a retry can't double-grant.
	DataService:RecordPurchase(player, purchaseKey)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function MonetizationService:Init()
	-- Grant Developer Product purchases. (Only one ProcessReceipt callback may
	-- exist game-wide; this is it.)
	MarketplaceService.ProcessReceipt = processReceipt

	-- Reflect a completed game pass purchase instantly, without a rejoin.
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

	-- Verify ownership once each player's profile is ready.
	DataService.ProfileLoaded:Connect(function(player: Player)
		task.spawn(refreshOwnership, player)
	end)

	-- Premium can change mid-session.
	Players.PlayerMembershipChanged:Connect(function(player: Player)
		DataService:SetPremium(player, player.MembershipType == Enum.MembershipType.Premium)
	end)

	-- Cleanup transient state on leave.
	Players.PlayerRemoving:Connect(function(player: Player)
		luckBoosts[player] = nil
		autoTimers[player] = nil
	end)

	-- Auto Fisher tick.
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
