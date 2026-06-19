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

-- Data layer; everything below reads from it.
local DataService = require(Services:WaitForChild("DataService"))

-- Boosts hub + the systems that grant rewards into it.
local BoostService = require(Services:WaitForChild("BoostService"))
local PetService = require(Services:WaitForChild("PetService"))
local CrateService = require(Services:WaitForChild("CrateService"))
local DailyRewardService = require(Services:WaitForChild("DailyRewardService"))

-- Monetization (consults BoostService + CrateService), then leaderboards.
local MonetizationService = require(Services:WaitForChild("MonetizationService"))
local LeaderstatsService = require(Services:WaitForChild("LeaderstatsService"))
local LeaderboardService = require(Services:WaitForChild("LeaderboardService"))

-- Core gameplay + economy, which depend on the data + boosts layers.
local FishingService = require(Services:WaitForChild("FishingService"))
local ShopService = require(Services:WaitForChild("ShopService"))

-- Each service is initialised in isolation: a failure in one (e.g. a cosmetic
-- map step on an unusual Studio configuration) is logged but can never abort the
-- others, so core gameplay (rod, data, fishing, economy) always comes up.
local function safeInit(name: string, service: { Init: (any) -> () })
	local ok, err = pcall(function()
		service:Init()
	end)
	if not ok then
		warn(string.format("[FishingSimulator] %s:Init() failed: %s", name, tostring(err)))
	end
end

safeInit("MapBuilder", MapBuilder)
safeInit("RodToolBuilder", RodToolBuilder)

safeInit("DataService", DataService)

safeInit("BoostService", BoostService)
safeInit("PetService", PetService)
safeInit("CrateService", CrateService)
safeInit("DailyRewardService", DailyRewardService)

safeInit("MonetizationService", MonetizationService)
safeInit("LeaderstatsService", LeaderstatsService)
safeInit("LeaderboardService", LeaderboardService)

safeInit("FishingService", FishingService)
safeInit("ShopService", ShopService)

print("[FishingSimulator] Server initialised.")
