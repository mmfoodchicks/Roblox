--!strict
--[[
	DataController
	--------------
	Client module (StarterPlayerScripts.Controllers.DataController).

	Receives authoritative data snapshots from the server (ReplicatedStorage.
	DataNetwork) and caches them locally. The HUD, shop and inventory subscribe to
	its Changed signal rather than touching the network directly, so there is one
	client-side source of truth that always mirrors the server.

	This controller never writes data — purchases/sells go through ShopFunction,
	and the resulting authoritative snapshot arrives back over DataNetwork.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataNetwork = ReplicatedStorage:WaitForChild("DataNetwork") :: RemoteEvent

-- Mirror of the server PlayerData shape (kept loose; the server is canonical).
export type InventoryEntry = {
	Id: string,
	Name: string,
	Rarity: string,
	Value: number,
	CaughtAt: number,
}

export type PlayerData = {
	Coins: number,
	ActiveRod: string,
	LuckLevel: number,
	Inventory: { InventoryEntry },
	OwnedRods: { [string]: boolean },
	Stats: { TotalCaught: number, CoinsEarned: number },
	Passes: { [string]: boolean },
	IsPremium: boolean,
	PurchaseHistory: { [string]: boolean },
}

local DataController = {}

local current: PlayerData? = nil

local changedBindable = Instance.new("BindableEvent")
-- Fires (data: PlayerData) whenever a fresh snapshot arrives.
DataController.Changed = changedBindable.Event :: RBXScriptSignal

--[[
	Get
	Returns the latest cached snapshot, or nil before the first one arrives.
]]
function DataController:Get(): PlayerData?
	return current
end

function DataController:Init()
	DataNetwork.OnClientEvent:Connect(function(data: PlayerData)
		current = data
		changedBindable:Fire(data)
	end)
end

return DataController
