--!strict
--[[
	FishingService
	--------------
	Server module (ServerScriptService.Services.FishingService).

	The authoritative fishing loop. The client may only ever *request* actions;
	every decision that affects persisted state (whether a bite happens, what is
	caught) is made here and cannot be forged by an exploiter.

	Economy: a catch goes into the player's inventory as an unsold record. Coins
	are realised later through the sell flow (ShopService), giving the classic
	collect -> sell -> upgrade incremental loop.

	Protocol over ReplicatedStorage.FishingNetwork (RemoteEvent):

	  Client -> Server
	    "RequestCast"                  Begin a cast. Server validates rod + cooldown,
	                                   starts a bite timer, and replies "FishBite".
	    "ResolveMinigame" {success}    Report minigame outcome. Server validates the
	                                   cast was active and the timing is realistic,
	                                   rolls the catch, stores it, and replies.

	  Server -> Client
	    "FishBite"     { castId }                Minigame may begin.
	    "CatchResult"  { success, item?, value? } Outcome + UI/particle data.
	    "CastRejected" { reason }                Request refused (spam, no rod, ...).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local LootManager = require(ReplicatedStorage.Shared.LootManager)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local DataService = require(ServerScriptService.Services.DataService)
local BoostService = require(ServerScriptService.Services.BoostService)

local FishingNetwork = ReplicatedStorage:WaitForChild("FishingNetwork") :: RemoteEvent

-- ---------------------------------------------------------------------------
-- Tuning
-- ---------------------------------------------------------------------------

-- Anti-spam: minimum seconds between two RequestCast calls from one player.
local CAST_COOLDOWN = 0.5

-- You must be near the water's edge (a dock or the shoreline) to cast. We sample
-- a small ring of downward rays around the character and require at least one to
-- hit Terrain water — so standing back on the grass/beach won't work.
local WATER_SAMPLE_RADII = { 7, 13 }
local WATER_RAY_DROP = 45 -- how far down each sample ray reaches

local function isNearWater(player: Player): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root == nil then
		return false
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = false -- we specifically want to detect water

	local origin = root.Position + Vector3.new(0, 6, 0)
	local drop = Vector3.new(0, -WATER_RAY_DROP, 0)

	-- Straight down, then a ring of samples at increasing radius / 8 directions.
	if (function()
		local hit = Workspace:Raycast(origin, drop, params)
		return hit ~= nil and hit.Material == Enum.Material.Water
	end)() then
		return true
	end
	for _, radius in ipairs(WATER_SAMPLE_RADII) do
		for step = 0, 7 do
			local angle = (step / 8) * math.pi * 2
			local sample = origin + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			local hit = Workspace:Raycast(sample, drop, params)
			if hit ~= nil and hit.Material == Enum.Material.Water then
				return true
			end
		end
	end
	return false
end

-- The minigame must resolve within a realistic window after the bite.
local MINIGAME_GRACE = 0.5       -- Slack on the realistic upper bound.
local MINIGAME_MAX_DURATION = 15 -- Hard ceiling regardless of rod.

-- ---------------------------------------------------------------------------
-- Per-player cast session state
-- ---------------------------------------------------------------------------

type CastSession = {
	castId: number,
	rod: GameConfig.RodConfig,
	biteAt: number,    -- os.clock() at which the fish bites.
	expiresAt: number, -- Latest os.clock() a valid resolution may arrive.
	resolved: boolean,
}

local sessions: { [Player]: CastSession } = {}
local lastCastClock: { [Player]: number } = {}
local castCounter = 0

local FishingService = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function reject(player: Player, reason: string)
	FishingNetwork:FireClient(player, "CastRejected", { reason = reason })
end

-- ---------------------------------------------------------------------------
-- "RequestCast"
-- ---------------------------------------------------------------------------

local function handleRequestCast(player: Player)
	local now = os.clock()

	-- 1) Cooldown / anti-spam gate.
	local last = lastCastClock[player]
	if last ~= nil and (now - last) < CAST_COOLDOWN then
		reject(player, "Casting too quickly.")
		return
	end

	-- 2) One line in the water at a time.
	if sessions[player] ~= nil then
		reject(player, "A cast is already in progress.")
		return
	end

	-- 3) The player must have a loaded profile (and therefore a rod).
	local data = DataService:GetData(player)
	if data == nil then
		reject(player, "Your data is still loading.")
		return
	end

	-- 4) Must be at the water's edge (a dock or shoreline) — no fishing on land.
	if not isNearWater(player) then
		reject(player, "Move closer to the water to fish!")
		return
	end

	lastCastClock[player] = now

	local rod = GameConfig.GetRod(data.ActiveRod)

	castCounter += 1
	local castId = castCounter

	local biteAt = now + rod.BiteTime
	sessions[player] = {
		castId = castId,
		rod = rod,
		biteAt = biteAt,
		expiresAt = biteAt + MINIGAME_MAX_DURATION,
		resolved = false,
	}

	-- Schedule the bite, re-validating the session identity so a superseded
	-- cast never fires a stale bite.
	task.delay(rod.BiteTime, function()
		local session = sessions[player]
		if session ~= nil and session.castId == castId and not session.resolved then
			FishingNetwork:FireClient(player, "FishBite", { castId = castId })
		end
	end)

	-- Safety net: reclaim an abandoned session so the player is never soft-locked.
	task.delay(rod.BiteTime + MINIGAME_MAX_DURATION + MINIGAME_GRACE, function()
		local session = sessions[player]
		if session ~= nil and session.castId == castId then
			sessions[player] = nil
		end
	end)
end

-- ---------------------------------------------------------------------------
-- "ResolveMinigame"
-- ---------------------------------------------------------------------------

local function handleResolveMinigame(player: Player, payload: unknown)
	local session = sessions[player]
	if session == nil then
		reject(player, "No active cast to resolve.")
		return
	end

	-- Consume the session immediately so a replayed packet cannot double-process.
	sessions[player] = nil
	if session.resolved then
		return
	end
	session.resolved = true

	if type(payload) ~= "table" then
		reject(player, "Malformed resolution.")
		return
	end
	local success = (payload :: any).success == true

	-- Timing validation: after the bite, before the deadline.
	local now = os.clock()
	if now < session.biteAt then
		reject(player, "Resolved before the fish bit.")
		return
	end
	if now > session.expiresAt + MINIGAME_GRACE then
		reject(player, "Resolution arrived too late.")
		return
	end

	-- A failed minigame is legitimate: the fish got away.
	if not success then
		FishingNetwork:FireClient(player, "CatchResult", { success = false })
		return
	end

	local data = DataService:GetData(player)
	if data == nil then
		reject(player, "Your data is unavailable.")
		return
	end

	-- Server-authoritative roll. Luck combines the player's luck level, the rod's
	-- multiplier, and all stacking boosts (passes, pets, luck potions).
	local luck = GameConfig.GetLuckMultiplier(data.LuckLevel)
		* session.rod.LuckMultiplier
		* BoostService:GetLuckMultiplier(player)
	local caught = LootManager.RollCatch(luck, session.rod.ValueMultiplier)

	-- Persist into the inventory (coins are realised on sell, not on catch).
	local newSize = DataService:AddToInventory(player, {
		Id = caught.Item.Id,
		Name = caught.Item.Name,
		Rarity = caught.Item.Rarity,
		Value = caught.Value,
		CaughtAt = os.time(),
	})

	if newSize == nil then
		reject(player, "Your data is unavailable.")
		return
	end

	-- Fire the catch details for UI + particle feedback. Include the live odds of
	-- this catch's rarity tier (at the exact luck used for the roll) so the client
	-- can show "... — 0.07% chance".
	local odds = LootManager.GetTierOdds(luck)
	FishingNetwork:FireClient(player, "CatchResult", {
		success = true,
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
-- Lifecycle
-- ---------------------------------------------------------------------------

function FishingService:Init()
	FishingNetwork.OnServerEvent:Connect(function(player: Player, action: unknown, payload: unknown)
		if action == "RequestCast" then
			handleRequestCast(player)
		elseif action == "ResolveMinigame" then
			handleResolveMinigame(player, payload)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		sessions[player] = nil
		lastCastClock[player] = nil
	end)
end

return FishingService
