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
	  * Expose narrow, validated mutators (AwardCoins / AddToInventory) so no
	    other system touches Profile.Data directly.
	  * Release profiles cleanly on leave, and handle ProfileService's
	    session-lock steal callback by kicking the affected player.

	All public mutators are no-ops (returning false) when the profile is absent,
	which makes call-sites safe during the brief load window or after a player
	has already left.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ProfileService = require(ReplicatedStorage.Packages.ProfileService)

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

export type PlayerData = {
	Coins: number,
	ActiveRod: string,
	LuckLevel: number,
	Inventory: { InventoryEntry },
}

-- ProfileService is untyped at the module boundary; we describe the slice of
-- the Profile object we actually use so the rest of the file stays strict.
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

-- The default data template. ProfileService deep-copies this for new players,
-- and :Reconcile() uses it to back-fill missing keys for existing players.
local PROFILE_TEMPLATE: PlayerData = {
	Coins = 0,
	ActiveRod = "BasicRod",
	LuckLevel = 1,
	Inventory = {},
}

-- Use a distinct store key in Studio so test play sessions never collide with
-- live production data.
local STORE_KEY = if RunService:IsStudio() then "PlayerData_Studio" else "PlayerData_Live"

local ProfileStore = ProfileService.GetProfileStore(STORE_KEY, PROFILE_TEMPLATE)

-- ---------------------------------------------------------------------------
-- Service state
-- ---------------------------------------------------------------------------

local DataService = {}

-- Live profiles, keyed by Player. Cleared on release.
local profiles: { [Player]: Profile } = {}

-- Fired when a profile finishes loading, so dependent services can react.
local profileLoadedBindable = Instance.new("BindableEvent")
DataService.ProfileLoaded = profileLoadedBindable.Event :: RBXScriptSignal

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function onProfileLoaded(player: Player, profile: Profile)
	profile:AddUserId(player.UserId) -- GDPR-compliant association for erasure.
	profile:Reconcile() -- Safely add any newly-introduced template fields.

	-- If the session lock is lost (the profile is loaded elsewhere, or the
	-- server is shutting down), drop our reference and remove the player.
	profile:ListenToRelease(function()
		profiles[player] = nil
		player:Kick("Your data was loaded on another server. Please rejoin.")
	end)

	if player:IsDescendantOf(Players) then
		profiles[player] = profile
		profileLoadedBindable:Fire(player, profile.Data)
	else
		-- Player left before the async load finished — release immediately.
		profile:Release()
	end
end

local function loadProfileAsync(player: Player)
	-- "ForceLoad" steals the session lock from a dead/other server after a
	-- short retry window, which is the standard single-place configuration.
	local profile = ProfileStore:LoadProfileAsync("Player_" .. player.UserId, "ForceLoad") :: Profile?

	if profile ~= nil then
		onProfileLoaded(player, profile)
	else
		-- The lock could not be acquired (rare). Kick so the player can retry on
		-- a fresh server rather than play with unsaved data.
		player:Kick("Unable to load your data. Please rejoin.")
	end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--[[
	GetProfile
	Returns the live profile for a player, or nil if it is not (yet) loaded or
	has been released. Callers that need the data slice should prefer the
	dedicated mutators below.
]]
function DataService:GetProfile(player: Player): Profile?
	return profiles[player]
end

--[[
	GetData
	Convenience accessor returning the mutable PlayerData table, or nil.
]]
function DataService:GetData(player: Player): PlayerData?
	local profile = profiles[player]
	return if profile ~= nil then profile.Data else nil
end

--[[
	AwardCoins
	Transactionally adds `amount` coins (may be negative for spends, but never
	below zero). Returns the new balance, or nil if the profile is unavailable.
]]
function DataService:AwardCoins(player: Player, amount: number): number?
	local profile = profiles[player]
	if profile == nil or not profile:IsActive() then
		return nil
	end

	-- Reject non-finite / NaN inputs that would corrupt the saved balance.
	if type(amount) ~= "number" or amount ~= amount or amount == math.huge or amount == -math.huge then
		return nil
	end

	local newBalance = math.max(0, profile.Data.Coins + amount)
	profile.Data.Coins = newBalance
	return newBalance
end

--[[
	AddToInventory
	Appends a caught-item record to the player's inventory and returns the new
	inventory size, or nil if the profile is unavailable. The entry is normalised
	here so persisted data is always well-formed regardless of caller.
]]
function DataService:AddToInventory(player: Player, itemData: InventoryEntry): number?
	local profile = profiles[player]
	if profile == nil or not profile:IsActive() then
		return nil
	end

	local entry: InventoryEntry = {
		Id = tostring(itemData.Id),
		Name = tostring(itemData.Name),
		Rarity = tostring(itemData.Rarity),
		Value = math.max(0, math.floor(tonumber(itemData.Value) or 0)),
		CaughtAt = os.time(),
	}

	table.insert(profile.Data.Inventory, entry)
	return #profile.Data.Inventory
end

--[[
	SetActiveRod / SetLuckLevel
	Small validated setters kept here so progression systems never poke Data
	directly. Both return success.
]]
function DataService:SetActiveRod(player: Player, rodId: string): boolean
	local profile = profiles[player]
	if profile == nil or not profile:IsActive() then
		return false
	end
	profile.Data.ActiveRod = tostring(rodId)
	return true
end

function DataService:SetLuckLevel(player: Player, level: number): boolean
	local profile = profiles[player]
	if profile == nil or not profile:IsActive() then
		return false
	end
	profile.Data.LuckLevel = math.max(1, math.floor(level))
	return true
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--[[
	Init
	Wires player join/leave. Called once by the server bootstrap. Players who
	are already present (e.g. on a hot script reload) are handled too.
]]
function DataService:Init()
	local function onPlayerAdded(player: Player)
		task.spawn(loadProfileAsync, player)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)

	Players.PlayerRemoving:Connect(function(player: Player)
		local profile = profiles[player]
		if profile ~= nil then
			profile:Release() -- Triggers ListenToRelease -> clears `profiles`.
		end
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
end

return DataService
