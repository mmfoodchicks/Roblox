--!strict
--[[
	InventoryController
	-------------------
	Client module (StarterPlayerScripts.Controllers.InventoryController).

	Renders the player's unsold catches (aggregated by species) and a "Sell All"
	action that routes to the server via ReplicatedStorage.ShopFunction. Re-renders
	from the cached DataController snapshot whenever data changes while open.

	Public: InventoryController:Open(), :Close(), :Toggle().
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local UiUtil = require(script.Parent.UiUtil)
local DataController = require(script.Parent.DataController)

local ShopFunction = ReplicatedStorage:WaitForChild("ShopFunction") :: RemoteFunction
local LocalPlayer = Players.LocalPlayer

local InventoryController = {}

local gui: ScreenGui? = nil
local listFrame: ScrollingFrame? = nil
local totalLabel: TextLabel? = nil
local sellButton: TextButton? = nil

type Aggregate = { Id: string, Name: string, Rarity: string, Count: number, Total: number }

-- ---------------------------------------------------------------------------
-- Aggregation
-- ---------------------------------------------------------------------------

local function aggregate(data: DataController.PlayerData): ({ Aggregate }, number)
	local byId: { [string]: Aggregate } = {}
	local grandTotal = 0

	for _, entry in ipairs(data.Inventory) do
		local agg = byId[entry.Id]
		if agg == nil then
			agg = { Id = entry.Id, Name = entry.Name, Rarity = entry.Rarity, Count = 0, Total = 0 }
			byId[entry.Id] = agg
		end
		agg.Count += 1
		agg.Total += entry.Value
		grandTotal += entry.Value
	end

	local list: { Aggregate } = {}
	for _, agg in pairs(byId) do
		table.insert(list, agg)
	end
	table.sort(list, function(a, b)
		return a.Total > b.Total
	end)

	return list, grandTotal
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function buildRow(parent: Instance, agg: Aggregate, order: number)
	local rarityColor = UiUtil.Rarity[agg.Rarity] or UiUtil.Palette.Text

	local row = UiUtil.frame({
		Name = agg.Id,
		Size = UDim2.new(1, 0, 0, 44),
		Color = UiUtil.Palette.PanelLight,
		Parent = parent,
	})
	row.LayoutOrder = order
	UiUtil.corner(row, 6)
	UiUtil.padding(row, 8)
	UiUtil.stroke(row, rarityColor, 1)

	UiUtil.label({
		Name = "Name",
		Size = UDim2.new(0.5, 0, 1, 0),
		Text = string.format("%s  x%d", agg.Name, agg.Count),
		TextColor = rarityColor,
		Align = Enum.TextXAlignment.Left,
		Font = Enum.Font.GothamMedium,
		TextSize = 15,
		Parent = row,
	})

	UiUtil.label({
		Name = "Value",
		Size = UDim2.new(0.45, 0, 1, 0),
		Position = UDim2.fromScale(0.55, 0),
		Text = UiUtil.comma(agg.Total) .. " 🪙",
		TextColor = UiUtil.Palette.Warn,
		Align = Enum.TextXAlignment.Right,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		Parent = row,
	})
end

local function refresh()
	local data = DataController:Get()
	if data == nil or listFrame == nil then
		return
	end

	-- Clear previous rows (everything except the layout).
	for _, child in ipairs(listFrame:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local list, grandTotal = aggregate(data)

	if #list == 0 then
		local empty = UiUtil.frame({
			Name = "_Empty",
			Size = UDim2.new(1, 0, 0, 44),
			Transparency = 1,
			Parent = listFrame,
		})
		empty.LayoutOrder = 1
		UiUtil.label({
			Size = UDim2.fromScale(1, 1),
			Text = "No fish yet — go cast your line!",
			TextColor = UiUtil.Palette.SubText,
			Parent = empty,
		})
	else
		for order, agg in ipairs(list) do
			buildRow(listFrame, agg, order)
		end
	end

	if totalLabel ~= nil then
		totalLabel.Text = "Total value: " .. UiUtil.comma(grandTotal) .. " 🪙"
	end
	if sellButton ~= nil then
		local has = grandTotal > 0
		sellButton.Text = if has then "Sell All (" .. UiUtil.comma(grandTotal) .. ")" else "Nothing to sell"
		sellButton.BackgroundColor3 = if has then UiUtil.Palette.Positive else UiUtil.Palette.Disabled
		sellButton.AutoButtonColor = has
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
	screen.Name = "InventoryGui"
	screen.ResetOnSpawn = false
	screen.Enabled = false
	screen.IgnoreGuiInset = true
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.DisplayOrder = 5

	local panel = UiUtil.frame({
		Name = "Window",
		Size = UDim2.fromOffset(460, 460),
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
		Text = "🐟 Inventory",
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
		InventoryController:Close()
	end)

	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Size = UDim2.new(1, -24, 1, -120)
	list.Position = UDim2.fromOffset(12, 56)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	local total = UiUtil.label({
		Name = "Total",
		Size = UDim2.new(1, -24, 0, 24),
		Position = UDim2.new(0, 12, 1, -56),
		Text = "Total value: 0 🪙",
		Align = Enum.TextXAlignment.Left,
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		Parent = panel,
	})

	local sell = UiUtil.button({
		Name = "SellAll",
		Size = UDim2.new(1, -24, 0, 40),
		Position = UDim2.new(0, 12, 1, -48),
		AnchorPoint = Vector2.new(0, 1),
		Text = "Sell All",
		Color = UiUtil.Palette.Positive,
		Parent = panel,
	})
	sell.Activated:Connect(function()
		task.spawn(function()
			pcall(function()
				ShopFunction:InvokeServer("SellAll", nil)
			end)
		end)
	end)

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	screen.Parent = playerGui

	gui = screen
	listFrame = list
	totalLabel = total
	sellButton = sell
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function InventoryController:Open()
	build()
	refresh()
	;(gui :: ScreenGui).Enabled = true
end

function InventoryController:Close()
	if gui ~= nil then
		gui.Enabled = false
	end
end

function InventoryController:Toggle()
	if gui ~= nil and gui.Enabled then
		self:Close()
	else
		self:Open()
	end
end

function InventoryController:Init()
	build()
	DataController.Changed:Connect(function()
		if gui ~= nil and gui.Enabled then
			refresh()
		end
	end)
end

return InventoryController
