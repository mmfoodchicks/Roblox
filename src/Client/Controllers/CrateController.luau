--!strict
--[[
	CrateController
	---------------
	Client module (StarterPlayerScripts.Controllers.CrateController).

	The gacha UI: open crates (paid in coins/keys), watch a reveal animation, and
	manage the pet collection (equip/unequip for stacked boosts). Opens are
	requested through ReplicatedStorage.CrateFunction; Robux-purchased opens push
	a reveal over ReplicatedStorage.CrateNetwork.

	Public: CrateController:Open(), :Close(), :Toggle().
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local CrateConfig = require(ReplicatedStorage.Shared.CrateConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.MonetizationConfig)
local UiUtil = require(script.Parent.UiUtil)
local DataController = require(script.Parent.DataController)

local CrateFunction = ReplicatedStorage:WaitForChild("CrateFunction") :: RemoteFunction
local CrateNetwork = ReplicatedStorage:WaitForChild("CrateNetwork") :: RemoteEvent
local PetFunction = ReplicatedStorage:WaitForChild("PetFunction") :: RemoteFunction
local LocalPlayer = Players.LocalPlayer

local CrateController = {}

local gui: ScreenGui? = nil
local petsList: ScrollingFrame? = nil
local slotsLabel: TextLabel? = nil
local revealOverlay: Frame? = nil
local crateRefreshers: { (data: DataController.PlayerData) -> () } = {}
local isRevealing = false

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Client-side mirror of PetService:GetEquipSlots for display.
local function equipSlots(data: DataController.PlayerData): number
	local slots = 3
	for _, pass in pairs(MonetizationConfig.GamePasses) do
		if pass.PetSlots ~= nil and data.Passes[pass.Key] then
			slots += pass.PetSlots
		end
	end
	return slots
end

local function isEquipped(data: DataController.PlayerData, petId: string): boolean
	for _, id in ipairs(data.EquippedPets) do
		if id == petId then
			return true
		end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Reveal animation
-- ---------------------------------------------------------------------------

local function playReveal(crateKey: string, reward: { [string]: any })
	local overlay = revealOverlay
	if overlay == nil then
		return
	end
	isRevealing = true
	overlay.Visible = true

	local card = overlay:FindFirstChild("Card") :: Frame
	local nameLabel = card:FindFirstChild("Name") :: TextLabel
	local rarityLabel = card:FindFirstChild("Rarity") :: TextLabel
	local stroke = card:FindFirstChildOfClass("UIStroke")

	local crate = CrateConfig.GetCrate(crateKey)
	local pool = if crate ~= nil then crate.Pool else {}

	-- Spin: rapidly flash through random pool entries, easing out.
	task.spawn(function()
		local steps = 22
		for i = 1, steps do
			local entry = pool[math.random(1, math.max(1, #pool))]
			local color = UiUtil.Palette.Accent
			local label = "?"
			if entry ~= nil then
				if entry.Type == "Pet" and entry.Ref ~= nil then
					local pet = CrateConfig.GetPet(entry.Ref)
					if pet ~= nil then
						color = pet.Color
						label = pet.Name
					end
				elseif entry.Type == "Coins" then
					color = Color3.fromRGB(240, 200, 90)
					label = "Coins"
				elseif entry.Type == "Keys" then
					color = Color3.fromRGB(120, 220, 240)
					label = "Keys"
				else
					color = Color3.fromRGB(190, 96, 255)
					label = "Potion"
				end
			end
			nameLabel.Text = label
			rarityLabel.Text = ""
			if stroke ~= nil then
				stroke.Color = color
			end
			card.BackgroundColor3 = color:Lerp(UiUtil.Palette.Panel, 0.8)
			task.wait(0.04 + (i / steps) * 0.08) -- ease out
		end

		-- Settle on the actual reward.
		local finalColor = (typeof(reward.Color) == "Color3" and reward.Color) or UiUtil.Palette.Accent
		nameLabel.Text = "🎉 " .. tostring(reward.Name)
		rarityLabel.Text = reward.Rarity ~= nil and ("✦ " .. tostring(reward.Rarity)) or "Reward"
		if stroke ~= nil then
			stroke.Color = finalColor
		end
		card.BackgroundColor3 = finalColor:Lerp(UiUtil.Palette.Panel, 0.65)
		isRevealing = false
	end)
end

-- ---------------------------------------------------------------------------
-- Opening
-- ---------------------------------------------------------------------------

local function requestOpen(crateKey: string)
	if isRevealing then
		return
	end
	task.spawn(function()
		local ok, result = pcall(function()
			return CrateFunction:InvokeServer("Open", { crateKey = crateKey })
		end)
		if ok and type(result) == "table" and result.success and result.reward ~= nil then
			playReveal(crateKey, result.reward :: { [string]: any })
		end
		-- Failures (e.g. not enough currency) surface via the button state on the
		-- next data sync; no blocking error dialog needed.
	end)
end

-- ---------------------------------------------------------------------------
-- Crate rows
-- ---------------------------------------------------------------------------

local function buildCrateRow(parent: Instance, crate: CrateConfig.Crate, order: number)
	local row = UiUtil.frame({
		Size = UDim2.new(1, 0, 0, 64),
		Color = UiUtil.Palette.PanelLight,
		Parent = parent,
	})
	row.LayoutOrder = order
	UiUtil.corner(row, 8)
	UiUtil.padding(row, 10)
	UiUtil.stroke(row, crate.Accent, 1)

	UiUtil.label({
		Size = UDim2.new(0.55, 0, 0, 22),
		Text = "📦 " .. crate.Name,
		TextColor = crate.Accent,
		Font = Enum.Font.GothamBold,
		TextSize = 17,
		Align = Enum.TextXAlignment.Left,
		Parent = row,
	})
	UiUtil.label({
		Size = UDim2.new(0.55, 0, 0, 16),
		Position = UDim2.fromScale(0, 0.6),
		Text = "Win pets, coins & potions",
		TextColor = UiUtil.Palette.SubText,
		TextSize = 12,
		Align = Enum.TextXAlignment.Left,
		Parent = row,
	})

	local button = UiUtil.button({
		Size = UDim2.new(0, 130, 0, 40),
		Position = UDim2.new(1, -130, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		Text = "...",
		Parent = row,
	})
	button.Activated:Connect(function()
		requestOpen(crate.Key)
	end)

	local unit = if crate.CostType == "Keys" then "🔑" else "🪙"
	crateRefreshers[#crateRefreshers + 1] = function(data: DataController.PlayerData)
		local balance = if crate.CostType == "Keys" then data.Keys else data.Coins
		local affordable = balance >= crate.Cost
		button.Text = string.format("Open %s %s", UiUtil.comma(crate.Cost), unit)
		button.BackgroundColor3 = if affordable then UiUtil.Palette.Positive else UiUtil.Palette.Disabled
		button.AutoButtonColor = affordable
	end
end

-- ---------------------------------------------------------------------------
-- Pet collection
-- ---------------------------------------------------------------------------

local function petAction(action: string, petId: string)
	task.spawn(function()
		pcall(function()
			PetFunction:InvokeServer(action, { petId = petId })
		end)
	end)
end

local function refreshPets()
	local data = DataController:Get()
	if data == nil or petsList == nil then
		return
	end

	for _, child in ipairs(petsList:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	-- Sorted owned pets (by config order via the Pets table iteration).
	local owned: { CrateConfig.Pet } = {}
	for petId, count in pairs(data.Pets) do
		local pet = CrateConfig.GetPet(petId)
		if pet ~= nil and count > 0 then
			table.insert(owned, pet)
		end
	end
	table.sort(owned, function(a, b)
		return a.LuckBonus + a.CoinBonus > b.LuckBonus + b.CoinBonus
	end)

	if slotsLabel ~= nil then
		slotsLabel.Text = string.format("Pets equipped: %d / %d", #data.EquippedPets, equipSlots(data))
	end

	if #owned == 0 then
		local empty = UiUtil.frame({
			Size = UDim2.new(1, 0, 0, 40),
			Transparency = 1,
			Parent = petsList,
		})
		empty.LayoutOrder = 1
		UiUtil.label({
			Size = UDim2.fromScale(1, 1),
			Text = "No pets yet — open a crate!",
			TextColor = UiUtil.Palette.SubText,
			Parent = empty,
		})
		return
	end

	for order, pet in ipairs(owned) do
		local count = data.Pets[pet.Id] or 0
		local equipped = isEquipped(data, pet.Id)

		local row = UiUtil.frame({
			Size = UDim2.new(1, 0, 0, 46),
			Color = UiUtil.Palette.PanelLight,
			Parent = petsList,
		})
		row.LayoutOrder = order
		UiUtil.corner(row, 6)
		UiUtil.padding(row, 8)
		UiUtil.stroke(row, pet.Color, 1)

		UiUtil.label({
			Size = UDim2.new(0.5, 0, 0, 18),
			Text = string.format("%s  x%d", pet.Name, count),
			TextColor = pet.Color,
			Align = Enum.TextXAlignment.Left,
			Font = Enum.Font.GothamBold,
			TextSize = 14,
			Parent = row,
		})
		UiUtil.label({
			Size = UDim2.new(0.5, 0, 0, 14),
			Position = UDim2.fromScale(0, 0.6),
			Text = string.format("+%d%% luck  +%d%% coins", math.floor(pet.LuckBonus * 100 + 0.5), math.floor(pet.CoinBonus * 100 + 0.5)),
			TextColor = UiUtil.Palette.SubText,
			Align = Enum.TextXAlignment.Left,
			TextSize = 11,
			Parent = row,
		})

		local button = UiUtil.button({
			Size = UDim2.new(0, 96, 0, 32),
			Position = UDim2.new(1, -96, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			Text = if equipped then "Unequip" else "Equip",
			Color = if equipped then UiUtil.Palette.Disabled else UiUtil.Palette.Accent,
			TextSize = 13,
			Parent = row,
		})
		button.Activated:Connect(function()
			petAction(if equipped then "Unequip" else "Equip", pet.Id)
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Window construction
-- ---------------------------------------------------------------------------

local function buildReveal(parent: Instance): Frame
	local overlay = UiUtil.frame({
		Name = "Reveal",
		Size = UDim2.fromScale(1, 1),
		Color = Color3.fromRGB(0, 0, 0),
		Transparency = 0.35,
		Parent = parent,
	})
	overlay.Visible = false
	overlay.ZIndex = 10

	local card = UiUtil.frame({
		Name = "Card",
		Size = UDim2.fromOffset(280, 200),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Color = UiUtil.Palette.Panel,
		Parent = overlay,
	})
	card.ZIndex = 11
	UiUtil.corner(card, 14)
	UiUtil.stroke(card, UiUtil.Palette.Accent, 2)

	UiUtil.label({
		Name = "Name",
		Size = UDim2.new(1, -20, 0, 40),
		Position = UDim2.fromScale(0.5, 0.42),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Text = "",
		Font = Enum.Font.GothamBold,
		TextSize = 22,
		Parent = card,
	}).ZIndex = 12

	UiUtil.label({
		Name = "Rarity",
		Size = UDim2.new(1, -20, 0, 22),
		Position = UDim2.fromScale(0.5, 0.66),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Text = "",
		TextColor = UiUtil.Palette.SubText,
		TextSize = 15,
		Parent = card,
	}).ZIndex = 12

	local close = UiUtil.button({
		Name = "Continue",
		Size = UDim2.new(0, 140, 0, 36),
		Position = UDim2.new(0.5, 0, 1, -16),
		AnchorPoint = Vector2.new(0.5, 1),
		Text = "Continue",
		Color = UiUtil.Palette.Positive,
		Parent = card,
	})
	close.ZIndex = 12
	close.Activated:Connect(function()
		if not isRevealing then
			overlay.Visible = false
		end
	end)

	return overlay
end

local function build()
	if gui ~= nil then
		return
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "CrateGui"
	screen.ResetOnSpawn = false
	screen.Enabled = false
	screen.IgnoreGuiInset = true
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.DisplayOrder = 7

	local panel = UiUtil.frame({
		Name = "Window",
		Size = UDim2.fromOffset(560, 540),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Parent = screen,
	})
	UiUtil.corner(panel, 12)
	UiUtil.stroke(panel, UiUtil.Palette.Accent, 1.5)

	UiUtil.label({
		Size = UDim2.new(1, -20, 0, 40),
		Position = UDim2.fromOffset(16, 10),
		Text = "🎁 Crates & Pets",
		Font = Enum.Font.GothamBold,
		TextSize = 24,
		Align = Enum.TextXAlignment.Left,
		Parent = panel,
	})

	local close = UiUtil.button({
		Size = UDim2.fromOffset(34, 34),
		Position = UDim2.new(1, -44, 0, 12),
		Text = "✕",
		Color = UiUtil.Palette.Negative,
		TextSize = 18,
		Parent = panel,
	})
	close.Activated:Connect(function()
		CrateController:Close()
	end)

	-- Crates section.
	UiUtil.label({
		Size = UDim2.new(1, -24, 0, 22),
		Position = UDim2.fromOffset(16, 54),
		Text = "Crates",
		Font = Enum.Font.GothamBold,
		TextSize = 17,
		Align = Enum.TextXAlignment.Left,
		Parent = panel,
	})

	local crateHolder = Instance.new("Frame")
	crateHolder.Name = "Crates"
	crateHolder.Size = UDim2.new(1, -24, 0, 220)
	crateHolder.Position = UDim2.fromOffset(12, 80)
	crateHolder.BackgroundTransparency = 1
	crateHolder.Parent = panel
	local crateLayout = Instance.new("UIListLayout")
	crateLayout.Padding = UDim.new(0, 8)
	crateLayout.SortOrder = Enum.SortOrder.LayoutOrder
	crateLayout.Parent = crateHolder

	local order = 0
	for _, crate in ipairs(CrateConfig.GetSortedCrates()) do
		order += 1
		buildCrateRow(crateHolder, crate, order)
	end

	-- Pets section.
	slotsLabel = UiUtil.label({
		Size = UDim2.new(1, -24, 0, 22),
		Position = UDim2.fromOffset(16, 312),
		Text = "Pets equipped: 0 / 3",
		Font = Enum.Font.GothamBold,
		TextSize = 17,
		Align = Enum.TextXAlignment.Left,
		Parent = panel,
	})

	local pets = Instance.new("ScrollingFrame")
	pets.Name = "Pets"
	pets.Size = UDim2.new(1, -24, 1, -348)
	pets.Position = UDim2.fromOffset(12, 338)
	pets.BackgroundTransparency = 1
	pets.BorderSizePixel = 0
	pets.ScrollBarThickness = 6
	pets.CanvasSize = UDim2.new()
	pets.AutomaticCanvasSize = Enum.AutomaticSize.Y
	pets.Parent = panel
	local petLayout = Instance.new("UIListLayout")
	petLayout.Padding = UDim.new(0, 6)
	petLayout.SortOrder = Enum.SortOrder.LayoutOrder
	petLayout.Parent = pets
	petsList = pets

	revealOverlay = buildReveal(panel)

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	screen.Parent = playerGui
	gui = screen
end

local function refresh()
	local data = DataController:Get()
	if data == nil then
		return
	end
	for _, fn in ipairs(crateRefreshers) do
		fn(data)
	end
	refreshPets()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function CrateController:Open()
	build()
	refresh()
	;(gui :: ScreenGui).Enabled = true
end

function CrateController:Close()
	if gui ~= nil then
		gui.Enabled = false
	end
end

function CrateController:Toggle()
	if gui ~= nil and gui.Enabled then
		self:Close()
	else
		self:Open()
	end
end

function CrateController:Init()
	build()

	DataController.Changed:Connect(function()
		if gui ~= nil and gui.Enabled then
			refresh()
		end
	end)

	-- Robux-purchased crate opens push their reveal here.
	CrateNetwork.OnClientEvent:Connect(function(action: string, payload: any)
		if action == "Reveal" and type(payload) == "table" then
			build()
			;(gui :: ScreenGui).Enabled = true
			playReveal(tostring(payload.crateKey), payload.reward or {})
		end
	end)
end

return CrateController
