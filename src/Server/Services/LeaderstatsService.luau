--!strict
--[[
	LeaderstatsService
	------------------
	Server module (ServerScriptService.Services.LeaderstatsService).

	Mirrors a couple of player-data fields into the Roblox leaderboard
	(player.leaderstats). Purely reactive: it listens to DataService.Changed and
	never owns data itself, so the persisted profile remains the single source of
	truth.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local DataService = require(ServerScriptService.Services.DataService)

local LeaderstatsService = {}

type PlayerData = DataService.PlayerData

-- Returns an existing IntValue child or creates one. Always non-nil.
local function ensureInt(parent: Instance, name: string): IntValue
	local existing = parent:FindFirstChild(name)
	if existing ~= nil and existing:IsA("IntValue") then
		return existing
	end
	local value = Instance.new("IntValue")
	value.Name = name
	value.Parent = parent
	return value
end

-- Ensures a player has a leaderstats folder with our values, returning them.
local function ensureStats(player: Player): (IntValue, IntValue)
	local existingFolder = player:FindFirstChild("leaderstats")
	local folder: Folder
	if existingFolder ~= nil and existingFolder:IsA("Folder") then
		folder = existingFolder
	else
		folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		folder.Parent = player
	end

	return ensureInt(folder, "Coins"), ensureInt(folder, "Caught")
end

local function update(player: Player, data: PlayerData)
	local coins, caught = ensureStats(player)
	coins.Value = data.Coins
	caught.Value = data.Stats.TotalCaught
end

function LeaderstatsService:Init()
	-- React to every data change for the relevant player.
	DataService.Changed:Connect(function(player: Player, data: PlayerData)
		update(player, data)
	end)

	-- Back-fill the board the moment a profile finishes loading (Changed also
	-- fires here, but this covers the explicit load event too).
	DataService.ProfileLoaded:Connect(function(player: Player, data: PlayerData)
		update(player, data)
	end)
end

return LeaderstatsService
