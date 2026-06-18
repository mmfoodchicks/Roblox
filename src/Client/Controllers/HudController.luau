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
local UiUtil = require(script.Parent.UiUtil)
local DataController = require(script.Parent.DataController)
local ShopController = require(script.Parent.ShopController)
local InventoryController = require(script.Parent.InventoryController)

local LocalPlayer = Players.LocalPlayer

local HudController = {}

local coinsLabel: TextLabel? = nil
local rodLabel: TextLabel? = nil
local luckLabel: TextLabel? = nil
local valueLabel: TextLabel? = nil

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

	-- Top-left stat row.
	local stats = UiUtil.frame({
		Name = "Stats",
		Size = UDim2.fromOffset(700, 36),
		Position = UDim2.fromOffset(12, 12),
		Transparency = 1,
		Parent = screen,
	})
	local statsLayout = Instance.new("UIListLayout")
	statsLayout.FillDirection = Enum.FillDirection.Horizontal
	statsLayout.Padding = UDim.new(0, 8)
	statsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	statsLayout.Parent = stats

	coinsLabel = statChip(stats, "Coins", 1)
	valueLabel = statChip(stats, "Unsold", 2)
	luckLabel = statChip(stats, "Luck", 3)
	rodLabel = statChip(stats, "Rod", 4)

	-- Bottom-right action buttons.
	local actions = UiUtil.frame({
		Name = "Actions",
		Size = UDim2.fromOffset(150, 96),
		Position = UDim2.new(1, -162, 1, -108),
		Transparency = 1,
		Parent = screen,
	})
	local actionsLayout = Instance.new("UIListLayout")
	actionsLayout.Padding = UDim.new(0, 8)
	actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	actionsLayout.Parent = actions

	local shopBtn = UiUtil.button({
		Name = "Shop",
		Size = UDim2.fromOffset(150, 44),
		Text = "🎣 Shop",
		Color = UiUtil.Palette.Accent,
		TextSize = 18,
		Parent = actions,
	})
	shopBtn.LayoutOrder = 1
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
	invBtn.LayoutOrder = 2
	invBtn.Activated:Connect(function()
		InventoryController:Toggle()
	end)

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	screen.Parent = playerGui
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

local function refresh(data: DataController.PlayerData)
	if coinsLabel ~= nil then
		coinsLabel.Text = "🪙 " .. UiUtil.comma(data.Coins)
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
