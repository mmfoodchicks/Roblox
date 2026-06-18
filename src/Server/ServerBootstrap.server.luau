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

-- DataService must initialise first: FishingService reads loaded profiles.
local DataService = require(Services:WaitForChild("DataService"))
local FishingService = require(Services:WaitForChild("FishingService"))

DataService:Init()
FishingService:Init()

print("[FishingSimulator] Server initialised.")
