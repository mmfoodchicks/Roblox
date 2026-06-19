--!strict
--[[
	DataService
	-----------
	Server module (ServerScriptService.Services.DataService).

	Persistent, transactional player-data layer built on ProfileService
	(MadStudioRoblox/ProfileService). Responsibilities:

	  * Load a session-locked profile per player on join.
	  * Reconcile the profile against the latest template so newly-added fields
	    are back-filled safely for returning players.
	  * Expose narrow, validated mutators so no other system touches
	    Profile.Data directly.
	  * Replicate the authoritative data to the owning client (DataNetwork) and
	    raise a server-side Changed signal after every mutation.
	  * Release profiles cleanly on leave, kicking on a lost session lock.

	All public mutators are no-ops (returning nil/false) when the profile is
	absent, which keeps call-sites safe during the load window or after leave.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ProfileService = require(ReplicatedStorage.Packages.ProfileService)

local DataNetwork = ReplicatedStorage:WaitForChild("DataNetwork") :: RemoteEvent

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- A single stored inventory record. We persist the stable item id plus the
-- value at time of catch, so a later catalogue re-balance does not retroac-
-- tively change a player's recorded haul.
export type InventoryEntry = {
	Id: string,
	Name: string,
	Rarity: string,
	Value: number,
	CaughtAt: number, -- os.time() of the catch
}

export type PlayerStats = {
	TotalCaught: number,
	CoinsEarned: number,
}

export type PlayerData = {
	Coins: number,
	ActiveRod: string,
	LuckLevel: number,
	Inventory: { InventoryEntry },
	OwnedRods: { [string]: boolean },
	Stats: PlayerStats,
	-- Monetization: a cache of owned game passes (re-verified on join), the
	-- Premium flag, and a set of handled Developer Product receipt ids for
	-- idempotent granting across server restarts.
	Passes: { [string]: boolean },
	IsPremium: boolean,
	PurchaseHistory: { [string]: boolean },
	-- Gacha / pets / daily.
	Pets: { [string]: number },     -- petId -> count owned
	EquippedPets: { string },       -- ordered list of equipped pet ids
	Keys: number,                   -- premium crate currency
	LastDailyClaim: number,         -- os.time() of last daily claim
	DailyStreak: number,            -- current daily streak
}

-- The slice of the ProfileService Profile object we actually use.
type Profile = {
	Data: PlayerData,
	Reconcile: (self: Profile) -> (),
	ListenToRelease: (self: Profile, listener: (placeId: number, jobId: string) -> ()) -> (),
	Release: (self: Profile) -> (),
	AddUserId: (self: Profile, userId: number) -> (),
	IsActive: (self: Profile) -> boolean,
}

-- ---------------------------------------------------------------------------
-- Template & store
-- ---------------------------------------------------------------------------

local PROFILE_TEMPLATE: PlayerData = {
	Coins = 0,
	ActiveRod = "BasicRod",
	LuckLevel = 1,
	Inventory = {},
	OwnedRods = { BasicRod = true },
	Stats = {
		TotalCaught = 0,
		CoinsEarned = 0,
	},
	Passes = {},
	IsPremium = false,
	PurchaseHistory = {},
	Pets = {},
	EquippedPets = {},
	Keys = 0,
	LastDailyClaim = 0,
	DailyStreak = 0,
}

local STORE_KEY = if RunService:IsStudio() then "PlayerData_Studio" else "PlayerData_Live"

local ProfileStore = ProfileService.GetProfileStore(STORE_KEY, PROFILE_TEMPLATE)

-- ---------------------------------------------------------------------------
-- Service state
-- ---------------------------------------------------------------------------

local DataService = {}

local profiles: { [Player]: Profile } = {}

-- Server-side signal raised whenever a player's data changes (used by
-- LeaderstatsService and any other reactive system).
local changedBindable = Instance.new("BindableEvent")
DataService.Changed = changedBindable.Event :: RBXScriptSignal

local profileLoadedBindable = Instance.new("BindableEvent")
DataService.ProfileLoaded = profileLoadedBindable.Event :: RBXScriptSignal

-- ---------------------------------------------------------------------------
-- Replication
-- ---------------------------------------------------------------------------

-- Pushes the authoritative data to the owning client and raises Changed. Called
-- after every successful mutation so the UI and leaderstats stay in lock-step
-- with the server.
local function sync(player: Player, data: PlayerData)
	if player:IsDescendantOf(Players) then
		DataNetwork:FireClient(player, data)
	end
	changedBindable:Fire(player, data)
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function onProfileLoaded(player: Player, profile: Profile)
	profile:AddUserId(player.UserId)
	profile:Reconcile()

	profile:ListenToRelease(function()
		profiles[player] = nil
		player:Kick("Your data was loaded on another server. Please rejoin.")
	end)

	if player:IsDescendantOf(Players) then
		profiles[player] = profile
		profileLoadedBindable:Fire(player, profile.Data)
		sync(player, profile.Data) -- Initial snapshot.
	else
		profile:Release()
	end
end

local function loadProfileAsync(player: Player)
	local profile = ProfileStore:LoadProfileAsync("Player_" .. player.UserId, "ForceLoad") :: Profile?

	if profile ~= nil then
		onProfileLoaded(player, profile)
	else
		player:Kick("Unable to load your data. Please rejoin.")
	end
end

-- Returns a live, active profile for a player or nil. Centralises the guard.
local function activeProfile(player: Player): Profile?
	local profile = profiles[player]
	if profile == nil or not profile:IsActive() then
		return nil
	end
	return profile
end

-- ---------------------------------------------------------------------------
-- Read API
-- ---------------------------------------------------------------------------

function DataService:GetProfile(player: Player): Profile?
	return profiles[player]
end

function DataService:GetData(player: Player): PlayerData?
	local profile = profiles[player]
	return if profile ~= nil then profile.Data else nil
end

-- ---------------------------------------------------------------------------
-- Mutators (each replicates on success)
-- ---------------------------------------------------------------------------

--[[
	AwardCoins
	Adds `amount` coins (may be negative for spends; never drops below zero).
	Positive awards also accrue the lifetime CoinsEarned stat. Returns the new
	balance, or nil if the profile is unavailable.
]]
function DataService:AwardCoins(player: Player, amount: number): number?
	local profile = activeProfile(player)
	if profile == nil then
		return nil
	end

	if type(amount) ~= "number" or amount ~= amount or amount == math.huge or amount == -math.huge then
		return nil
	end

	profile.Data.Coins = math.max(0, profile.Data.Coins + amount)
	if amount > 0 then
		profile.Data.Stats.CoinsEarned += amount
	end

	sync(player, profile.Data)
	return profile.Data.Coins
end

-- Hard cap on stored unsold catches. Protects the profile from unbounded growth
-- (e.g. an AFK player with the Auto Fisher) blowing the DataStore size limit.
-- Far above normal play; sell at the market to make room.
local MAX_INVENTORY = 1500

--[[
	AddToInventory
	Appends a normalised caught-item record and bumps the TotalCaught stat. The
	catch always counts toward stats, but once the inventory is at MAX_INVENTORY
	the entry is not stored (the player must sell first). Returns the new inventory
	size, "full" (a flag), or nil if the profile is unavailable.
]]
function DataService:AddToInventory(player: Player, itemData: InventoryEntry): number?
	local profile = activeProfile(player)
	if profile == nil then
		return nil
	end

	-- The catch still counts as caught even if there's no room to store it.
	profile.Data.Stats.TotalCaught += 1

	if #profile.Data.Inventory >= MAX_INVENTORY then
		sync(player, profile.Data)
		return #profile.Data.Inventory -- full: not stored, but not an error
	end

	local entry: InventoryEntry = {
		Id = tostring(itemData.Id),
		Name = tostring(itemData.Name),
		Rarity = tostring(itemData.Rarity),
		Value = math.max(0, math.floor(tonumber(itemData.Value) or 0)),
		CaughtAt = os.time(),
	}

	table.insert(profile.Data.Inventory, entry)

	sync(player, profile.Data)
	return #profile.Data.Inventory
end

--[[
	ClearInventory
	Empties the inventory and returns the total resale value that was held
	(summed before clearing), or nil if unavailable. Used by the sell flow.
]]
function DataService:ClearInventory(player: Player): number?
	local profile = activeProfile(player)
	if profile == nil then
		return nil
	end

	local total = 0
	for _, entry in ipairs(profile.Data.Inventory) do
		total += entry.Value
	end
	profile.Data.Inventory = {}

	sync(player, profile.Data)
	return total
end

--[[
	SetActiveRod
	Equips a rod the player owns. Returns success.
]]
function DataService:SetActiveRod(player: Player, rodId: string): boolean
	local profile = activeProfile(player)
	if profile == nil then
		return false
	end
	if not profile.Data.OwnedRods[rodId] then
		return false
	end
	profile.Data.ActiveRod = rodId
	sync(player, profile.Data)
	return true
end

--[[
	SetOwnedRod
	Grants (or revokes) ownership of a rod. Returns success.
]]
function DataService:SetOwnedRod(player: Player, rodId: string, owned: boolean): boolean
	local profile = activeProfile(player)
	if profile == nil then
		return false
	end
	profile.Data.OwnedRods[rodId] = owned or nil
	sync(player, profile.Data)
	return true
end

--[[
	SetLuckLevel
	Sets the luck level (clamped to >= 1). Returns success.
]]
function DataService:SetLuckLevel(player: Player, level: number): boolean
	local profile = activeProfile(player)
	if profile == nil then
		return false
	end
	profile.Data.LuckLevel = math.max(1, math.floor(level))
	sync(player, profile.Data)
	return true
end

--[[
	SetPass
	Caches ownership of a game pass (re-verified against Roblox on join). Returns
	success. Replicates so the store/HUD reflect the perk immediately.
]]
function DataService:SetPass(player: Player, passKey: string, owned: boolean): boolean
	local profile = activeProfile(player)
	if profile == nil then
		return false
	end
	profile.Data.Passes[passKey] = owned or nil
	sync(player, profile.Data)
	return true
end

--[[
	SetPremium
	Records the player's Roblox Premium status. Returns success.
]]
function DataService:SetPremium(player: Player, isPremium: boolean): boolean
	local profile = activeProfile(player)
	if profile == nil then
		return false
	end
	profile.Data.IsPremium = isPremium
	sync(player, profile.Data)
	return true
end

--[[
	HasHandledPurchase / RecordPurchase
	Idempotency for Developer Product receipts. A receipt's PurchaseId is recorded
	once granted so a retried ProcessReceipt never double-grants. We do NOT sync
	these (the client has no use for receipt ids) — they ride along on the next
	natural sync and are persisted by ProfileService.
]]
function DataService:HasHandledPurchase(player: Player, purchaseId: string): boolean
	local profile = activeProfile(player)
	return profile ~= nil and profile.Data.PurchaseHistory[purchaseId] == true
end

function DataService:RecordPurchase(player: Player, purchaseId: string): boolean
	local profile = activeProfile(player)
	if profile == nil then
		return false
	end
	profile.Data.PurchaseHistory[purchaseId] = true
	return true
end

--[[
	AddPet
	Increments the owned count of a pet. Returns the new count, or nil if
	unavailable.
]]
function DataService:AddPet(player: Player, petId: string, amount: number?): number?
	local profile = activeProfile(player)
	if profile == nil then
		return nil
	end
	local count = (profile.Data.Pets[petId] or 0) + (amount or 1)
	profile.Data.Pets[petId] = count
	sync(player, profile.Data)
	return count
end

--[[
	SetEquippedPets
	Replaces the equipped-pet list wholesale (caller is responsible for
	validating ownership and slot limits). Returns success.
]]
function DataService:SetEquippedPets(player: Player, petIds: { string }): boolean
	local profile = activeProfile(player)
	if profile == nil then
		return false
	end
	profile.Data.EquippedPets = petIds
	sync(player, profile.Data)
	return true
end

--[[
	AddKeys
	Adds `amount` keys (may be negative for spends; never below zero). Returns the
	new balance, or nil if unavailable.
]]
function DataService:AddKeys(player: Player, amount: number): number?
	local profile = activeProfile(player)
	if profile == nil then
		return nil
	end
	profile.Data.Keys = math.max(0, profile.Data.Keys + amount)
	sync(player, profile.Data)
	return profile.Data.Keys
end

--[[
	SetDailyClaim
	Records the daily streak and claim timestamp. Returns success.
]]
function DataService:SetDailyClaim(player: Player, streak: number, claimTime: number): boolean
	local profile = activeProfile(player)
	if profile == nil then
		return false
	end
	profile.Data.DailyStreak = streak
	profile.Data.LastDailyClaim = claimTime
	sync(player, profile.Data)
	return true
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function DataService:Init()
	local function onPlayerAdded(player: Player)
		task.spawn(loadProfileAsync, player)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)

	Players.PlayerRemoving:Connect(function(player: Player)
		local profile = profiles[player]
		if profile ~= nil then
			profile:Release()
		end
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
end

return DataService
