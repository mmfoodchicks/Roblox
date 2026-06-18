--!strict
--[[
	PetService
	----------
	Server module (ServerScriptService.Services.PetService).

	Authoritative pet equipping. Pets are won from crates (CrateService) and
	grant passive luck/coin bonuses while equipped — those bonuses are summed by
	BoostService, so this service only owns ownership/slot validation and the
	equipped list.

	Exposed via ReplicatedStorage.PetFunction:
	  "Equip"   {petId}
	  "Unequip" {petId}
	Returns { success: boolean, reason: string? }.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage.Shared.MonetizationConfig)
local CrateConfig = require(ReplicatedStorage.Shared.CrateConfig)
local DataService = require(script.Parent.DataService)

local PetFunction = ReplicatedStorage:WaitForChild("PetFunction") :: RemoteFunction

local BASE_PET_SLOTS = 3

local PetService = {}

type Response = { success: boolean, reason: string? }

local function fail(reason: string): Response
	return { success = false, reason = reason }
end

--[[
	GetEquipSlots
	Base slots plus any granted by owned game passes (the +2 Pet Slots pass).
]]
function PetService:GetEquipSlots(player: Player): number
	local data = DataService:GetData(player)
	if data == nil then
		return BASE_PET_SLOTS
	end
	local slots = BASE_PET_SLOTS
	for _, pass in pairs(MonetizationConfig.GamePasses) do
		if pass.PetSlots ~= nil and data.Passes[pass.Key] then
			slots += pass.PetSlots
		end
	end
	return slots
end

local function indexOf(list: { string }, value: string): number?
	for i, v in ipairs(list) do
		if v == value then
			return i
		end
	end
	return nil
end

local function equip(player: Player, petId: string): Response
	if CrateConfig.GetPet(petId) == nil then
		return fail("Unknown pet.")
	end

	local data = DataService:GetData(player)
	if data == nil then
		return fail("Data unavailable.")
	end
	if (data.Pets[petId] or 0) <= 0 then
		return fail("You don't own that pet.")
	end

	-- Copy the list so we never mutate the live profile table directly.
	local equipped = table.clone(data.EquippedPets)

	if indexOf(equipped, petId) ~= nil then
		return fail("Already equipped.")
	end
	if #equipped >= PetService:GetEquipSlots(player) then
		return fail("No free pet slots.")
	end

	table.insert(equipped, petId)
	DataService:SetEquippedPets(player, equipped)
	return { success = true }
end

local function unequip(player: Player, petId: string): Response
	local data = DataService:GetData(player)
	if data == nil then
		return fail("Data unavailable.")
	end

	local equipped = table.clone(data.EquippedPets)
	local index = indexOf(equipped, petId)
	if index == nil then
		return fail("Not equipped.")
	end

	table.remove(equipped, index)
	DataService:SetEquippedPets(player, equipped)
	return { success = true }
end

local function onInvoke(player: Player, action: unknown, payload: unknown): Response
	local safePayload: { [string]: any } = if type(payload) == "table" then payload :: any else {}
	local petId = tostring(safePayload.petId)

	if action == "Equip" then
		return equip(player, petId)
	elseif action == "Unequip" then
		return unequip(player, petId)
	end
	return fail("Unknown action.")
end

function PetService:Init()
	PetFunction.OnServerInvoke = function(player: Player, action: unknown, payload: unknown)
		local ok, result = pcall(onInvoke, player, action, payload)
		if ok then
			return result
		end
		warn("[PetService] action failed:", result)
		return fail("Internal error.")
	end
end

return PetService
