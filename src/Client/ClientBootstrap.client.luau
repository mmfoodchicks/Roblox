--!strict
--[[
	ClientBootstrap
	---------------
	The single client entry point
	(StarterPlayer.StarterPlayerScripts.ClientBootstrap).

	Single Script Architecture: the only *LocalScript* the client runs. It
	requires each controller module and calls :Init() once. Controllers contain
	no top-level side effects, so all client startup is sequenced here.
]]

local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer
local PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts")
local Controllers = PlayerScripts:WaitForChild("Controllers")

local FishingController = require(Controllers:WaitForChild("FishingController"))

FishingController:Init()

print("[FishingSimulator] Client initialised.")
