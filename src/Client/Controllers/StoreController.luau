--!strict
--[[
	StoreController
	---------------
	Client module (StarterPlayerScripts.Controllers.StoreController).

	The Robux store window: lists Game Passes and Developer Products from
	MonetizationConfig and prompts purchases through MarketplaceService. Ownership
	state comes from the cached DataController snapshot; Robux prices are fetched
	lazily via GetProductInfo. Unconfigured items (Id == 0) render as "Unavailable"
	so the developer can see exactly what still needs an asset id.

	Public: StoreController:Open(), :Close(), :Toggle().
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local MonetizationConfig = require(ReplicatedStorage.Shared.MonetizationConfig)
local UiUtil = require(script.Parent.UiUtil)
local DataController = require(script.Parent.DataController)

local LocalPlayer = Players.LocalPlayer

local StoreController = {}

local gui: ScreenGui? = nil
local passRefreshers: { (data: DataController.PlayerData) -> () } = {}

-- ---------------------------------------------------------------------------
-- Price fetching (async, best-effort)
-- ---------------------------------------------------------------------------

-- Fetches a Robux price into the given label without blocking construction.
local function fetchPrice(label: TextLabel, assetId: number, infoType: Enum.InfoType)
	if assetId == 0 then
		return
	end
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(assetId, infoType)
		end)
		if ok and typeof(info) == "table" and info.PriceInRobux ~= nil then
			label.Text = "R$ " .. UiUtil.comma(info.PriceInRobux)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Row builders
-- ---------------------------------------------------------------------------

local function makeRow(parent: Instance, order: number, accent: Color3): Frame
	local row = UiUtil.frame({
		Size = UDim2.new(1, 0, 0, 70),
		Color = UiUtil.Palette.PanelLight,
		Parent = parent,
	})
	row.LayoutOrder = order
	UiUtil.corner(row, 8)
	UiUtil.padding(row, 10)
	UiUtil.stroke(row, accent, 1)
	return row
end

local function buildPassRow(parent: Instance, pass: MonetizationConfig.GamePass, order: number)
	local accent = UiUtil.Palette.Warn
	local row = makeRow(parent, order, accent)

	UiUtil.label({
		Size = UDim2.new(0.62, 0, 0, 20),
		Text = "⭐ " .. pass.Name,
		TextColor = accent,
		Font = Enum.Font.GothamBold,
		TextSize = 17,
		Align = Enum.TextXAlignment.Left,
		Parent = row,
	})
	UiUtil.label({
		Size = UDim2.new(0.62, 0, 0, 30),
		Position = UDim2.fromScale(0, 0.5),
		Text = pass.Desc,
		TextColor = UiUtil.Palette.SubText,
		TextSize = 13,
		Align = Enum.TextXAlignment.Left,
		Parent = row,
	}).TextWrapped = true

	local button = UiUtil.button({
		Name = "Action",
		Size = UDim2.new(0, 120, 0, 40),
		Position = UDim2.new(1, -120, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		Text = "...",
		Color = UiUtil.Palette.Positive,
		Parent = row,
	})

	if pass.Id == 0 then
		button.Text = "Unavailable"
		button.BackgroundColor3 = UiUtil.Palette.Disabled
		button.AutoButtonColor = false
	else
		fetchPrice(button, pass.Id, Enum.InfoType.GamePass)
		button.Activated:Connect(function()
			MarketplaceService:PromptGamePassPurchase(LocalPlayer, pass.Id)
		end)
	end

	-- Reflect owned state on every data change.
	passRefreshers[#passRefreshers + 1] = function(data: DataController.PlayerData)
		if data.Passes[pass.Key] then
			button.Text = "Owned ✓"
			button.BackgroundColor3 = UiUtil.Palette.Disabled
			button.AutoButtonColor = false
		elseif pass.Id ~= 0 then
			button.AutoButtonColor = true
			button.BackgroundColor3 = UiUtil.Palette.Positive
			-- Leave the fetched price text in place.
		end
	end
end

local function buildProductRow(parent: Instance, product: MonetizationConfig.Product, order: number)
	local accent = UiUtil.Palette.Accent
	local row = makeRow(parent, order, accent)

	UiUtil.label({
		Size = UDim2.new(0.62, 0, 0, 20),
		Text = "💰 " .. product.Name,
		TextColor = accent,
		Font = Enum.Font.GothamBold,
		TextSize = 17,
		Align = Enum.TextXAlignment.Left,
		Parent = row,
	})
	UiUtil.label({
		Size = UDim2.new(0.62, 0, 0, 30),
		Position = UDim2.fromScale(0, 0.5),
		Text = product.Desc,
		TextColor = UiUtil.Palette.SubText,
		TextSize = 13,
		Align = Enum.TextXAlignment.Left,
		Parent = row,
	}).TextWrapped = true

	local button = UiUtil.button({
		Name = "Action",
		Size = UDim2.new(0, 120, 0, 40),
		Position = UDim2.new(1, -120, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		Text = "...",
		Color = UiUtil.Palette.Accent,
		Parent = row,
	})

	if product.Id == 0 then
		button.Text = "Unavailable"
		button.BackgroundColor3 = UiUtil.Palette.Disabled
		button.AutoButtonColor = false
	else
		fetchPrice(button, product.Id, Enum.InfoType.Product)
		button.Activated:Connect(function()
			MarketplaceService:PromptProductPurchase(LocalPlayer, product.Id)
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Window construction
-- ---------------------------------------------------------------------------

local function sectionHeader(parent: Instance, text: string, order: number)
	local header = UiUtil.label({
		Size = UDim2.new(1, 0, 0, 26),
		Text = text,
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		Align = Enum.TextXAlignment.Left,
		Parent = parent,
	})
	header.LayoutOrder = order
end

local function build()
	if gui ~= nil then
		return
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "StoreGui"
	screen.ResetOnSpawn = false
	screen.Enabled = false
	screen.IgnoreGuiInset = true
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.DisplayOrder = 6

	local panel = UiUtil.frame({
		Name = "Window",
		Size = UDim2.fromOffset(540, 520),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Parent = screen,
	})
	UiUtil.corner(panel, 12)
	UiUtil.stroke(panel, UiUtil.Palette.Warn, 1.5)

	UiUtil.label({
		Name = "Title",
		Size = UDim2.new(1, -20, 0, 40),
		Position = UDim2.fromOffset(16, 10),
		Text = "💎 Store",
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
		StoreController:Close()
	end)

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

	order += 1
	sectionHeader(list, "Game Passes", order)
	for _, pass in ipairs(MonetizationConfig.GetSortedPasses()) do
		order += 1
		buildPassRow(list, pass, order)
	end

	order += 1
	sectionHeader(list, "Coins & Boosts", order)
	for _, product in ipairs(MonetizationConfig.GetSortedProducts()) do
		order += 1
		buildProductRow(list, product, order)
	end

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	screen.Parent = playerGui

	gui = screen
end

local function refresh()
	local data = DataController:Get()
	if data == nil then
		return
	end
	for _, fn in ipairs(passRefreshers) do
		fn(data)
	end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function StoreController:Open()
	build()
	refresh()
	;(gui :: ScreenGui).Enabled = true
end

function StoreController:Close()
	if gui ~= nil then
		gui.Enabled = false
	end
end

function StoreController:Toggle()
	if gui ~= nil and gui.Enabled then
		self:Close()
	else
		self:Open()
	end
end

function StoreController:Init()
	build()
	DataController.Changed:Connect(function()
		if gui ~= nil and gui.Enabled then
			refresh()
		end
	end)
end

return StoreController
