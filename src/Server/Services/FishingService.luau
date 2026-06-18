--!strict
--[[
	FishingService
	--------------
	Server module (ServerScriptService.Services.FishingService).

	The authoritative fishing loop. The client may only ever *request* actions;
	every decision that affects persisted state (whether a bite happens, what is
	caught, how many coins are awarded) is made here and cannot be forged by an
	exploiter.

	Protocol over ReplicatedStorage.FishingNetwork (RemoteEvent):

	  Client -> Server
	    "RequestCast"                  Begin a cast. Server validates rod + cooldown,
	                                   starts a bite timer, and replies "FishBite".
	    "ResolveMinigame" {success}    Report minigame outcome. Server validates the
	                                   cast was active and the timing is realistic,
	                                   rolls the catch, persists it, and replies.

	  Server -> Client
	    "FishBite"     { castId }                Minigame may begin.
	    "CatchResult"  { success, item?, value?, coins? }  Outcome + UI/particle data.
	    "CastRejected" { reason }                Request refused (spam, no rod, ...).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local LootManager = require(ReplicatedStorage.Shared.LootManager)
local DataService = require(ServerScriptService.Services.DataService)

local FishingNetwork = ReplicatedStorage:WaitForChild("FishingNetwork") :: RemoteEvent

-- ---------------------------------------------------------------------------
-- Rod tuning
-- ---------------------------------------------------------------------------

-- Per-rod configuration. BiteTime is how long the server waits before the fish
-- bites; LuckMultiplier and ValueMultiplier feed the loot roll. ActiveRod on
-- the player's profile indexes into this table.
type RodConfig = {
	BiteTime: number,        -- Seconds from cast to bite.
	LuckMultiplier: number,  -- Multiplies the player's luck for the roll.
	ValueMultiplier: number, -- Multiplies caught item BaseValue.
}

local RODS: { [string]: RodConfig } = {
	BasicRod = { BiteTime = 2.0, LuckMultiplier = 1.0, ValueMultiplier = 1.0 },
	SilverRod = { BiteTime = 1.5, LuckMultiplier = 1.25, ValueMultiplier = 1.5 },
	GoldRod = { BiteTime = 1.0, LuckMultiplier = 1.6, ValueMultiplier = 2.25 },
}

local DEFAULT_ROD = "BasicRod"

-- Anti-spam: minimum seconds between two RequestCast calls from one player.
local CAST_COOLDOWN = 0.5

-- The minigame must be resolved within BiteTime + this window. Resolving faster
-- than the bite could even occur, or far too late, is rejected as invalid.
local MINIGAME_GRACE = 0.5      -- Slack added to the realistic upper bound.
local MINIGAME_MAX_DURATION = 15 -- Hard ceiling regardless of rod.

-- ---------------------------------------------------------------------------
-- Per-player cast session state
-- ---------------------------------------------------------------------------

-- Tracks the single in-flight cast for a player. `castId` lets us correlate the
-- client's ResolveMinigame with the exact cast it belongs to and reject stale
-- or duplicated resolutions.
type CastSession = {
	castId: number,
	rodId: string,
	rod: RodConfig,
	biteAt: number,   -- os.clock() at which the fish bites (minigame can start).
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

local function getRodConfig(rodId: string): (string, RodConfig)
	local rod = RODS[rodId]
	if rod == nil then
		return DEFAULT_ROD, RODS[DEFAULT_ROD]
	end
	return rodId, rod
end

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

	-- 2) Reject overlapping casts — one line in the water at a time.
	if sessions[player] ~= nil then
		reject(player, "A cast is already in progress.")
		return
	end

	-- 3) The player must have a loaded profile and therefore a rod.
	local data = DataService:GetData(player)
	if data == nil then
		reject(player, "Your data is still loading.")
		return
	end

	lastCastClock[player] = now

	local rodId, rod = getRodConfig(data.ActiveRod)

	castCounter += 1
	local castId = castCounter

	local biteAt = now + rod.BiteTime
	sessions[player] = {
		castId = castId,
		rodId = rodId,
		rod = rod,
		biteAt = biteAt,
		-- Valid resolution window: from the bite until a generous upper bound.
		expiresAt = biteAt + MINIGAME_MAX_DURATION,
		resolved = false,
	}

	-- Schedule the bite. We re-validate the session identity inside the timer so
	-- a cancelled / superseded cast never fires a stale bite.
	task.delay(rod.BiteTime, function()
		local session = sessions[player]
		if session ~= nil and session.castId == castId and not session.resolved then
			FishingNetwork:FireClient(player, "FishBite", { castId = castId })
		end
	end)

	-- Safety net: if the client never resolves, reclaim the session so the
	-- player is not soft-locked out of casting.
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

	-- Consume the session immediately so a duplicate/replayed packet cannot be
	-- processed twice, regardless of the validation outcome below.
	sessions[player] = nil
	if session.resolved then
		return
	end
	session.resolved = true

	-- Validate payload shape.
	if type(payload) ~= "table" then
		reject(player, "Malformed resolution.")
		return
	end
	local success = (payload :: any).success == true

	-- Timing validation: the resolution must arrive *after* the fish could have
	-- bitten (no pre-bite auto-clicks) and *before* the realistic deadline.
	local now = os.clock()
	if now < session.biteAt then
		reject(player, "Resolved before the fish bit.")
		return
	end
	if now > session.expiresAt + MINIGAME_GRACE then
		reject(player, "Resolution arrived too late.")
		return
	end

	-- A failed minigame is a legitimate outcome: the fish got away, no reward.
	if not success then
		FishingNetwork:FireClient(player, "CatchResult", { success = false })
		return
	end

	-- Re-read live data (the player may have changed rods mid-cast).
	local data = DataService:GetData(player)
	if data == nil then
		reject(player, "Your data is unavailable.")
		return
	end

	-- Server-authoritative roll. Luck combines profile LuckLevel with the rod.
	local luck = math.max(1, data.LuckLevel) * session.rod.LuckMultiplier
	local caught = LootManager.RollCatch(luck, session.rod.ValueMultiplier)

	-- Persist: append the item, then award its coin value. Both are no-ops if
	-- the profile vanished, in which case we do not lie to the client.
	local inventoryEntry = {
		Id = caught.Item.Id,
		Name = caught.Item.Name,
		Rarity = caught.Item.Rarity,
		Value = caught.Value,
		CaughtAt = os.time(),
	}

	local newSize = DataService:AddToInventory(player, inventoryEntry)
	if newSize == nil then
		reject(player, "Your data is unavailable.")
		return
	end
	local newBalance = DataService:AwardCoins(player, caught.Value)

	-- Fire the catch details for UI + particle feedback.
	FishingNetwork:FireClient(player, "CatchResult", {
		success = true,
		item = {
			Id = caught.Item.Id,
			Name = caught.Item.Name,
			Rarity = caught.Item.Rarity,
			Color = caught.Item.Color,
		},
		value = caught.Value,
		coins = newBalance,
	})
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--[[
	Init
	Binds the RemoteEvent dispatcher and cleans up session state on leave.
	Called once by the server bootstrap.
]]
function FishingService:Init()
	FishingNetwork.OnServerEvent:Connect(function(player: Player, action: unknown, payload: unknown)
		if action == "RequestCast" then
			handleRequestCast(player)
		elseif action == "ResolveMinigame" then
			handleResolveMinigame(player, payload)
		end
		-- Unknown actions are ignored silently — no surface for probing.
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		sessions[player] = nil
		lastCastClock[player] = nil
	end)
end

return FishingService
