--!strict
--[[
	ClientBootstrap
	---------------
	The single client entry point
	(StarterPlayer.StarterPlayerScripts.ClientBootstrap).

	Single Script Architecture: the only *LocalScript* the client runs. It
	requires each controller module and calls :Init() once, in dependency order.
	Controllers contain no top-level side effects, so all client startup is
	sequenced here. (UiUtil is a pure helper and is intentionally not Init'd.)
]]

local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer
local PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts")
local Controllers = PlayerScripts:WaitForChild("Controllers")

-- DataController first so the cache + Changed signal exist before any UI
-- subscribes. Window controllers next, then the HUD (which references them),
-- then the fishing/minigame controller.
local DataController = require(Controllers:WaitForChild("DataController"))
local ShopController = require(Controllers:WaitForChild("ShopController"))
local InventoryController = require(Controllers:WaitForChild("InventoryController"))
local StoreController = require(Controllers:WaitForChild("StoreController"))
local CrateController = require(Controllers:WaitForChild("CrateController"))
local DailyController = require(Controllers:WaitForChild("DailyController"))
local SprintController = require(Controllers:WaitForChild("SprintController"))
local HudController = require(Controllers:WaitForChild("HudController"))
local FishingController = require(Controllers:WaitForChild("FishingController"))

DataController:Init()
ShopController:Init()
InventoryController:Init()
StoreController:Init()
CrateController:Init()
DailyController:Init()
SprintController:Init()
HudController:Init()
FishingController:Init()

print("[FishingSimulator] Client initialised.")
