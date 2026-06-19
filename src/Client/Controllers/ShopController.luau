--!strict
--[[
	ShopController
	--------------
	Client module (StarterPlayerScripts.Controllers.ShopController).

	Builds the shop window (rods + luck upgrade) and routes purchase intents to
	the server through ReplicatedStorage.ShopFunction. It renders entirely from
	GameConfig + the cached DataController snapshot; the server validates and
	charges, then the new snapshot flows back and re-renders affordability.

	Public: ShopController:Open(), :Close(), :Toggle().
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.MonetizationConfig)
local CrateConfig = require(ReplicatedStorage.Shared.CrateConfig)
local LootManager = require(ReplicatedStorage.Shared.LootManager)
local UiUtil = require(script.Parent.UiUtil)
local DataController = require(script.Parent.DataController)

local ShopFunction = ReplicatedStorage:WaitForChild("ShopFunction") :: RemoteFunction
local LocalPlayer = Players.LocalPlayer

local ShopController = {}

local gui: ScreenGui? = nil
-- Per-row refresh callbacks, run whenever data changes while the window is open.
local rowRefreshers: { (data: DataController.PlayerData) -> () } = {}

-- ---------------------------------------------------------------------------
-- Server call
-- ---------------------------------------------------------------------------

local function invoke(action: string, payload: { [string]: any }?)
	task.spawn(function()
		local ok, result = pcall(function()
			return ShopFunction:InvokeServer(action, payload)
		end)
		if not ok then
			warn("[ShopController] invoke failed:", result)
		end
		-- Success/failure is reflected by the authoritative snapshot that follows;
		-- no optimistic UI needed. (result.reason is available for toasts.)
	end)
end

-- ---------------------------------------------------------------------------
-- Row builders
-- ---------------------------------------------------------------------------

local function buildRodRow(parent: Instance, rod: GameConfig.RodConfig, order: number)
	local row = UiUtil.frame({
		Name = rod.Id,
		Size = UDim2.new(1, 0, 0, 64),
		Color = UiUtil.Palette.PanelLight,
		Parent = parent,
	})
	row.LayoutOrder = order
	UiUtil.corner(row, 8)
	UiUtil.padding(row, 10)
	UiUtil.stroke(row, rod.Color, 1)

	UiUtil.label({
		Name = "Title",
		Size = UDim2.new(0.55, 0, 0, 20),
		Position = UDim2.fromScale(0, 0),
		Text = rod.Name,
		TextColor = rod.Color,
		Font = Enum.Font.GothamBold,
		TextSize = 17,
		Align = Enum.TextXAlignment.Left,
		Parent = row,
	})

	UiUtil.label({
		Name = "Stats",
		Size = UDim2.new(0.6, 0, 0, 18),
		Position = UDim2.fromScale(0, 0.55),
		Text = string.format(
			"Bite %.1fs  •  Luck x%.2g  •  Value x%.2g",
			rod.BiteTime,
			rod.LuckMultiplier,
			rod.ValueMultiplier
		),
		TextColor = UiUtil.Palette.SubText,
		TextSize = 13,
		Align = Enum.TextXAlignment.Left,
		Parent = row,
	})

	local button = UiUtil.button({
		Name = "Action",
		Size = UDim2.new(0, 120, 0, 40),
		Position = UDim2.new(1, -120, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		Text = "...",
		Parent = row,
	})

	button.Activated:Connect(function()
		invoke("BuyRod", { rodId = rod.Id })
	end)

	-- Refresh closure: reflects owned/equipped/affordable state.
	rowRefreshers[#rowRefreshers + 1] = function(data: DataController.PlayerData)
		local owned = data.OwnedRods[rod.Id] == true
		local equipped = data.ActiveRod == rod.Id

		if equipped then
			button.Text = "Equipped"
			button.BackgroundColor3 = UiUtil.Palette.Disabled
			button.AutoButtonColor = false
		elseif owned then
			button.Text = "Equip"
			button.BackgroundColor3 = UiUtil.Palette.Accent
			button.AutoButtonColor = true
		else
			button.Text = "Buy " .. UiUtil.comma(rod.Price)
			local affordable = data.Coins >= rod.Price
			button.BackgroundColor3 = if affordable then UiUtil.Palette.Positive else UiUtil.Palette.Disabled
			button.AutoButtonColor = affordable
		end
	end
end

local function buildLuckRow(parent: Instance, order: number)
	local row = UiUtil.frame({
		Name = "LuckUpgrade",
		Size = UDim2.new(1, 0, 0, 64),
		Color = UiUtil.Palette.PanelLight,
		Parent = parent,
	})
	row.LayoutOrder = order
	UiUtil.corner(row, 8)
	UiUtil.padding(row, 10)
	UiUtil.stroke(row, UiUtil.Palette.Warn, 1)

	UiUtil.label({
		Name = "Title",
		Size = UDim2.new(0.55, 0, 0, 20),
		Text = "Luck Upgrade",
		TextColor = UiUtil.Palette.Warn,
		Font = Enum.Font.GothamBold,
		TextSize = 17,
		Align = Enum.TextXAlignment.Left,
		Parent = row,
	})

	local desc = UiUtil.label({
		Name = "Desc",
		Size = UDim2.new(0.6, 0, 0, 18),
		Position = UDim2.fromScale(0, 0.55),
		Text = "",
		TextColor = UiUtil.Palette.SubText,
		TextSize = 13,
		Align = Enum.TextXAlignment.Left,
		Parent = row,
	})

	local button = UiUtil.button({
		Name = "Action",
		Size = UDim2.new(0, 120, 0, 40),
		Position = UDim2.new(1, -120, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		Text = "...",
		Color = UiUtil.Palette.Positive,
		Parent = row,
	})

	button.Activated:Connect(function()
		invoke("BuyLuck", nil)
	end)

	rowRefreshers[#rowRefreshers + 1] = function(data: DataController.PlayerData)
		local cost = GameConfig.GetLuckUpgradeCost(data.LuckLevel)
		desc.Text = string.format(
			"Level %d / %d  •  Luck x%.2f",
			data.LuckLevel,
			GameConfig.Luck.MaxLevel,
			GameConfig.GetLuckMultiplier(data.LuckLevel)
		)

		if cost == nil then
			button.Text = "MAXED"
			button.BackgroundColor3 = UiUtil.Palette.Disabled
			button.AutoButtonColor = false
		else
			button.Text = "Buy " .. UiUtil.comma(cost)
			local affordable = data.Coins >= cost
			button.BackgroundColor3 = if affordable then UiUtil.Palette.Positive else UiUtil.Palette.Disabled
			button.AutoButtonColor = affordable
		end
	end
end

-- ---------------------------------------------------------------------------
-- Live catch odds
-- ---------------------------------------------------------------------------

-- The player's persistent luck multiplier (luck level × rod × passes × pets),
-- mirroring BoostService/FishingService minus the temporary luck potion. Used
-- only to display the live odds.
local function effectiveLuck(data: DataController.PlayerData): number
	local luck = GameConfig.GetLuckMultiplier(data.LuckLevel)
	luck *= GameConfig.GetRod(data.ActiveRod).LuckMultiplier
	for _, pass in pairs(MonetizationConfig.GamePasses) do
		if pass.LuckMultiplier ~= nil and data.Passes[pass.Key] then
			luck *= pass.LuckMultiplier
		end
	end
	local petBonus = 0
	for _, petId in ipairs(data.EquippedPets) do
		local pet = CrateConfig.GetPet(petId)
		if pet ~= nil then
			petBonus += pet.LuckBonus
		end
	end
	return luck * (1 + petBonus)
end

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

-- A panel listing the live catch chance per rarity tier; refreshes with luck/rod.
local function buildOddsPanel(parent: Instance, order: number)
	local rows = #LootManager.Tiers
	local panel = UiUtil.frame({
		Name = "Odds",
		Size = UDim2.new(1, 0, 0, 26 + rows * 18),
		Color = UiUtil.Palette.PanelLight,
		Parent = parent,
	})
	panel.LayoutOrder = order
	UiUtil.corner(panel, 8)
	UiUtil.padding(panel, 8)

	UiUtil.label({
		Size = UDim2.new(1, 0, 0, 20),
		Text = "Your catch odds",
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		Align = Enum.TextXAlignment.Left,
		Parent = panel,
	})

	local valueLabels: { [string]: TextLabel } = {}
	for i, tier in ipairs(LootManager.Tiers) do
		local rarityColor = UiUtil.Rarity[tier] or UiUtil.Palette.Text
		UiUtil.label({
			Size = UDim2.new(0.5, 0, 0, 16),
			Position = UDim2.fromOffset(0, 24 + (i - 1) * 18),
			Text = tier,
			TextColor = rarityColor,
			Align = Enum.TextXAlignment.Left,
			TextSize = 13,
			Parent = panel,
		})
		valueLabels[tier] = UiUtil.label({
			Size = UDim2.new(0.5, 0, 0, 16),
			Position = UDim2.new(0.5, 0, 0, 24 + (i - 1) * 18),
			Text = "—",
			TextColor = rarityColor,
			Align = Enum.TextXAlignment.Right,
			Font = Enum.Font.GothamBold,
			TextSize = 13,
			Parent = panel,
		})
	end

	rowRefreshers[#rowRefreshers + 1] = function(data: DataController.PlayerData)
		local odds = LootManager.GetTierOdds(effectiveLuck(data))
		for tier, lbl in pairs(valueLabels) do
			lbl.Text = formatChance(odds[tier] or 0)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Window construction
-- ---------------------------------------------------------------------------

local function build()
	if gui ~= nil then
		return
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "ShopGui"
	screen.ResetOnSpawn = false
	screen.Enabled = false
	screen.IgnoreGuiInset = true
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.DisplayOrder = 5

	local panel = UiUtil.frame({
		Name = "Window",
		Size = UDim2.fromOffset(520, 460),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Parent = screen,
	})
	UiUtil.corner(panel, 12)
	UiUtil.stroke(panel, UiUtil.Palette.Accent, 1.5)

	UiUtil.label({
		Name = "Title",
		Size = UDim2.new(1, -20, 0, 40),
		Position = UDim2.fromOffset(16, 10),
		Text = "🎣 Shop",
		Font = Enum.Font.GothamBold,
		TextSize = 24,
		Align = Enum.TextXAlignment.Left,
		Parent = panel,
	})

	local close = UiUtil.button({
		Name = "Close",
		Size = UDim2.fromOffset(34, 34),
		Position = UDim2.new(1, -44, 0, 12),
		Text = "✕",
		Color = UiUtil.Palette.Negative,
		TextSize = 18,
		Parent = panel,
	})
	close.Activated:Connect(function()
		ShopController:Close()
	end)

	-- Scrolling list of rows.
	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Size = UDim2.new(1, -24, 1, -64)
	list.Position = UDim2.fromOffset(12, 56)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	local order = 0
	buildOddsPanel(list, order)
	for _, rod in ipairs(GameConfig.GetSortedRods()) do
		order += 1
		buildRodRow(list, rod, order)
	end
	order += 1
	buildLuckRow(list, order)

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	screen.Parent = playerGui

	gui = screen
end

-- Runs every row refresher with the latest data (no-op if data not yet synced).
local function refresh()
	local data = DataController:Get()
	if data == nil then
		return
	end
	for _, fn in ipairs(rowRefreshers) do
		fn(data)
	end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function ShopController:Open()
	build()
	refresh()
	;(gui :: ScreenGui).Enabled = true
end

function ShopController:Close()
	if gui ~= nil then
		gui.Enabled = false
	end
end

function ShopController:Toggle()
	if gui ~= nil and gui.Enabled then
		self:Close()
	else
		self:Open()
	end
end

function ShopController:Init()
	build()
	-- Keep the shop affordability live while it is open.
	DataController.Changed:Connect(function()
		if gui ~= nil and gui.Enabled then
			refresh()
		end
	end)
end

return ShopController
