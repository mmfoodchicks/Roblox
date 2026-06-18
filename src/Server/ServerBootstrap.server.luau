--!strict
--[[
	ServerBootstrap
	---------------
	The single server entry point (ServerScriptService.ServerBootstrap).

	Single Script Architecture: this is the only *Script* on the server. It
	requires each service module in dependency order and calls :Init() exactly
	once. Modules never run themselves — keeping all execution flowing from one
	place makes startup order explicit and debuggable.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Services = ServerScriptService:WaitForChild("Services")

-- MapBuilder runs first so the world (including the SpawnLocation) exists before
-- any player can spawn. DataService then loads profiles, and FishingService —
-- which reads those profiles — initialises last.
local MapBuilder = require(Services:WaitForChild("MapBuilder"))
local DataService = require(Services:WaitForChild("DataService"))
local FishingService = require(Services:WaitForChild("FishingService"))

MapBuilder:Init()
DataService:Init()
FishingService:Init()

print("[FishingSimulator] Server initialised.")
