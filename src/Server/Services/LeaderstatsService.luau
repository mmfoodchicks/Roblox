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

-- Returns an existing StringValue child or creates one. Always non-nil.
local function ensureString(parent: Instance, name: string): StringValue
	local existing = parent:FindFirstChild(name)
	if existing ~= nil and existing:IsA("StringValue") then
		return existing
	end
	local value = Instance.new("StringValue")
	value.Name = name
	value.Parent = parent
	return value
end

-- Formats a probability (0..1) as a percentage string.
local function formatChance(p: number): string
	local v = p * 100
	if v >= 10 then
		return string.format("%.0f%%", v)
	elseif v >= 1 then
		return string.format("%.1f%%", v)
	elseif v >= 0.01 then
		return string.format("%.2f%%", v)
	else
		return string.format("%.3f%%", v)
	end
end

-- Ensures a player has a leaderstats folder with our values.
local function ensureStats(player: Player): (IntValue, IntValue, StringValue)
	local existingFolder = player:FindFirstChild("leaderstats")
	local folder: Folder
	if existingFolder ~= nil and existingFolder:IsA("Folder") then
		folder = existingFolder
	else
		folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		folder.Parent = player
	end

	return ensureInt(folder, "Coins"), ensureInt(folder, "Caught"), ensureString(folder, "Rarest")
end

local function update(player: Player, data: PlayerData)
	local coins, caught, rarest = ensureStats(player)
	coins.Value = data.Coins
	caught.Value = data.Stats.TotalCaught
	rarest.Value = if data.Stats.RarestChance > 0 then formatChance(data.Stats.RarestChance) else "—"
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
