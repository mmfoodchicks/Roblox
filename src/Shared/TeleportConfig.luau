--!strict
--[[
	TeleportConfig
	--------------
	Shared module (ReplicatedStorage.Shared.TeleportConfig).

	The destinations shown as portals in the spawn hub. Each entry teleports the
	player to one of YOUR other Roblox experiences.

	>>> SET YOUR PLACE IDS <<<
	A PlaceId is the number in a game's URL: roblox.com/games/<PlaceId>/...
	Paste each game's PlaceId below. A portal with PlaceId = 0 is shown as
	"Coming soon" and does nothing, so the hub works fine until you fill these in.
	Note: teleporting only works in a PUBLISHED game, not in Studio playtests.
]]

local TeleportConfig = {}

export type Destination = {
	Name: string,
	PlaceId: number,
	Color: Color3,
}

TeleportConfig.Destinations = {
	{ Name = "My Other Game", PlaceId = 0, Color = Color3.fromRGB(64, 156, 255) },
	{ Name = "Game Three", PlaceId = 0, Color = Color3.fromRGB(170, 96, 255) },
	{ Name = "Game Four", PlaceId = 0, Color = Color3.fromRGB(88, 196, 120) },
} :: { Destination }

return TeleportConfig
