--!strict
--[[
	HudController
	-------------
	Client module (StarterPlayerScripts.Controllers.HudController).

	The always-on heads-up display: coin balance, active rod, luck level and the
	current unsold inventory value, plus buttons that open the shop and inventory
	windows. Reads exclusively from the cached DataController snapshot.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.MonetizationConfig)
local CrateConfig = require(ReplicatedStorage.Shared.CrateConfig)
local UiUtil = require(script.Parent.UiUtil)
local DataController = require(script.Parent.DataController)
local ShopController = require(script.Parent.ShopController)
local InventoryController = require(script.Parent.InventoryController)
local StoreController = require(script.Parent.StoreController)
local CrateController = require(script.Parent.CrateController)
local DailyController = require(script.Parent.DailyController)

local LocalPlayer = Players.LocalPlayer

local HudController = {}

local coinsLabel: TextLabel? = nil
local rodLabel: TextLabel? = nil
local luckLabel: TextLabel? = nil
local valueLabel: TextLabel? = nil
local keysLabel: TextLabel? = nil

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

local function statChip(parent: Instance, name: string, order: number): TextLabel
	local chip = UiUtil.frame({
		Name = name,
		Size = UDim2.fromOffset(160, 36),
		Color = UiUtil.Palette.Panel,
		Transparency = 0.1,
		Parent = parent,
	})
	chip.LayoutOrder = order
	UiUtil.corner(chip, 8)
	UiUtil.stroke(chip, UiUtil.Palette.PanelLight, 1)

	return UiUtil.label({
		Name = "Value",
		Size = UDim2.fromScale(1, 1),
		Text = "…",
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		Parent = chip,
	})
end

local function build()
	local screen = Instance.new("ScreenGui")
	screen.Name = "HudGui"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.DisplayOrder = 2

	-- Bottom-left stat row — clear of the Roblox chat (top-left) and the action
	-- buttons (bottom-right).
	local stats = UiUtil.frame({
		Name = "Stats",
		Size = UDim2.fromOffset(900, 36),
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -12),
		Transparency = 1,
		Parent = screen,
	})
	local statsLayout = Instance.new("UIListLayout")
	statsLayout.FillDirection = Enum.FillDirection.Horizontal
	statsLayout.Padding = UDim.new(0, 8)
	statsLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	statsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	statsLayout.Parent = stats

	coinsLabel = statChip(stats, "Coins", 1)
	keysLabel = statChip(stats, "Keys", 2)
	valueLabel = statChip(stats, "Unsold", 3)
	luckLabel = statChip(stats, "Luck", 4)
	rodLabel = statChip(stats, "Rod", 5)

	-- Bottom-right action buttons.
	local actions = UiUtil.frame({
		Name = "Actions",
		Size = UDim2.fromOffset(150, 256),
		Position = UDim2.new(1, -162, 1, -268),
		Transparency = 1,
		Parent = screen,
	})
	local actionsLayout = Instance.new("UIListLayout")
	actionsLayout.Padding = UDim.new(0, 8)
	actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	actionsLayout.Parent = actions

	local storeBtn = UiUtil.button({
		Name = "Store",
		Size = UDim2.fromOffset(150, 44),
		Text = "💎 Store",
		Color = UiUtil.Palette.Warn,
		TextColor = Color3.fromRGB(40, 32, 10),
		TextSize = 18,
		Parent = actions,
	})
	storeBtn.LayoutOrder = 1
	storeBtn.Activated:Connect(function()
		StoreController:Toggle()
	end)

	local crateBtn = UiUtil.button({
		Name = "Crates",
		Size = UDim2.fromOffset(150, 44),
		Text = "🎁 Crates",
		Color = UiUtil.Palette.Negative,
		TextSize = 18,
		Parent = actions,
	})
	crateBtn.LayoutOrder = 2
	crateBtn.Activated:Connect(function()
		CrateController:Toggle()
	end)

	local dailyBtn = UiUtil.button({
		Name = "Daily",
		Size = UDim2.fromOffset(150, 44),
		Text = "📅 Daily",
		Color = UiUtil.Palette.Positive,
		TextSize = 18,
		Parent = actions,
	})
	dailyBtn.LayoutOrder = 3
	dailyBtn.Activated:Connect(function()
		DailyController:Toggle()
	end)

	local shopBtn = UiUtil.button({
		Name = "Shop",
		Size = UDim2.fromOffset(150, 44),
		Text = "🎣 Shop",
		Color = UiUtil.Palette.Accent,
		TextSize = 18,
		Parent = actions,
	})
	shopBtn.LayoutOrder = 4
	shopBtn.Activated:Connect(function()
		ShopController:Toggle()
	end)

	local invBtn = UiUtil.button({
		Name = "Inventory",
		Size = UDim2.fromOffset(150, 44),
		Text = "🐟 Inventory",
		Color = UiUtil.Palette.PanelLight,
		TextSize = 18,
		Parent = actions,
	})
	invBtn.LayoutOrder = 5
	invBtn.Activated:Connect(function()
		InventoryController:Toggle()
	end)

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	screen.Parent = playerGui
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

-- Mirrors BoostService:GetCoinMultiplier for display only (passes + Premium +
-- equipped pets). The server remains authoritative for the actual payout.
local function coinMultiplier(data: DataController.PlayerData): number
	local multiplier = 1
	for _, pass in pairs(MonetizationConfig.GamePasses) do
		if pass.CoinMultiplier ~= nil and data.Passes[pass.Key] then
			multiplier *= pass.CoinMultiplier
		end
	end
	if data.IsPremium then
		multiplier *= MonetizationConfig.PremiumCoinMultiplier
	end
	local petBonus = 0
	for _, petId in ipairs(data.EquippedPets) do
		local pet = CrateConfig.GetPet(petId)
		if pet ~= nil then
			petBonus += pet.CoinBonus
		end
	end
	multiplier *= (1 + petBonus)
	return multiplier
end

local function refresh(data: DataController.PlayerData)
	if coinsLabel ~= nil then
		local mult = coinMultiplier(data)
		local suffix = if mult > 1 then string.format("  (x%.2g)", mult) else ""
		coinsLabel.Text = "🪙 " .. UiUtil.comma(data.Coins) .. suffix
	end

	if keysLabel ~= nil then
		keysLabel.Text = "🔑 " .. UiUtil.comma(data.Keys)
	end

	if valueLabel ~= nil then
		local total = 0
		for _, entry in ipairs(data.Inventory) do
			total += entry.Value
		end
		valueLabel.Text = "Unsold: " .. UiUtil.comma(total)
	end

	if luckLabel ~= nil then
		luckLabel.Text = string.format("Luck Lv %d", data.LuckLevel)
	end

	if rodLabel ~= nil then
		local rod = GameConfig.GetRod(data.ActiveRod)
		rodLabel.Text = rod.Name
		rodLabel.TextColor3 = rod.Color
	end
end

function HudController:Init()
	build()

	DataController.Changed:Connect(refresh)

	-- If a snapshot already arrived before we connected, render it now.
	local existing = DataController:Get()
	if existing ~= nil then
		refresh(existing)
	end

	-- Keyboard shortcuts on desktop.
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.E then
			ShopController:Toggle()
		elseif input.KeyCode == Enum.KeyCode.Q then
			InventoryController:Toggle()
		end
	end)
end

return HudController
