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

-- World first, so the SpawnLocation exists before any player can spawn.
local MapBuilder = require(Services:WaitForChild("MapBuilder"))
local RodToolBuilder = require(Services:WaitForChild("RodToolBuilder"))

-- Data layer next; everything below reads from it.
local DataService = require(Services:WaitForChild("DataService"))
local LeaderstatsService = require(Services:WaitForChild("LeaderstatsService"))

-- Monetization, which FishingService and ShopService consult for multipliers.
local MonetizationService = require(Services:WaitForChild("MonetizationService"))

-- Gameplay + economy, which depend on the data + monetization layers.
local FishingService = require(Services:WaitForChild("FishingService"))
local ShopService = require(Services:WaitForChild("ShopService"))

MapBuilder:Init()
RodToolBuilder:Init()

DataService:Init()
LeaderstatsService:Init()
MonetizationService:Init()

FishingService:Init()
ShopService:Init()

print("[FishingSimulator] Server initialised.")
