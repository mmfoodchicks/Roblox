--!strict
--[[
	HudController
	-------------
	Client module (StarterPlayerScripts.Controllers.HudController).

	The always-on heads-up display: coin balance, keys, unsold value, luck level
	and active rod. Read-only — all shops/crates/selling are now done in person at
	the merchant stands in the market cavern (see MerchantController), so the HUD
	carries no action buttons.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.MonetizationConfig)
local CrateConfig = require(ReplicatedStorage.Shared.CrateConfig)
local UiUtil = require(script.Parent.UiUtil)
local DataController = require(script.Parent.DataController)

local LocalPlayer = Players.LocalPlayer

local HudController = {}

local coinsLabel: TextLabel? = nil
local rodLabel: TextLabel? = nil
local luckLabel: TextLabel? = nil
local valueLabel: TextLabel? = nil
local keysLabel: TextLabel? = nil
local rarestLabel: TextLabel? = nil

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

	-- Left-edge vertical stack — clear of the chat (top-left) and the hotbar.
	local stats = UiUtil.frame({
		Name = "Stats",
		Size = UDim2.fromOffset(170, 220),
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 40),
		Transparency = 1,
		Parent = screen,
	})
	local statsLayout = Instance.new("UIListLayout")
	statsLayout.FillDirection = Enum.FillDirection.Vertical
	statsLayout.Padding = UDim.new(0, 6)
	statsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	statsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	statsLayout.Parent = stats

	coinsLabel = statChip(stats, "Coins", 1)
	keysLabel = statChip(stats, "Keys", 2)
	valueLabel = statChip(stats, "Unsold", 3)
	luckLabel = statChip(stats, "Luck", 4)
	rodLabel = statChip(stats, "Rod", 5)
	rarestLabel = statChip(stats, "Rarest", 6)

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	screen.Parent = playerGui
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

-- Formats a probability (0..1) as a readable percentage.
local function formatChance(p: number): string
	local v = p * 100
	if v >= 10 then
		return string.format("%.0f%%", v)
	elseif v >= 1 then
		return string.format("%.1f%%", v)
	elseif v >= 0.01 then
		return string.format("%.2f%%", v)
	else
		return string.format("%.3f%%", v)
	end
end

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

	if rarestLabel ~= nil then
		local chance = data.Stats.RarestChance
		if chance > 0 then
			rarestLabel.Text = "🏆 " .. formatChance(chance)
			rarestLabel.TextColor3 = UiUtil.Rarity[data.Stats.RarestRarity] or UiUtil.Palette.Text
		else
			rarestLabel.Text = "🏆 Rarest: —"
			rarestLabel.TextColor3 = UiUtil.Palette.SubText
		end
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
end

return HudController
