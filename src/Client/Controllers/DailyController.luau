--!strict
--[[
	DailyController
	---------------
	Client module (StarterPlayerScripts.Controllers.DailyController).

	The daily-reward popup: previews the 7-day track, highlights the next reward,
	and claims through ReplicatedStorage.DailyFunction. Auto-opens once on join
	when a claim is available (a gentle retention nudge).

	Public: DailyController:Open(), :Close(), :Toggle().
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local DailyConfig = require(ReplicatedStorage.Shared.DailyConfig)
local UiUtil = require(script.Parent.UiUtil)
local DataController = require(script.Parent.DataController)

local DailyFunction = ReplicatedStorage:WaitForChild("DailyFunction") :: RemoteFunction
local LocalPlayer = Players.LocalPlayer

local DailyController = {}

local gui: ScreenGui? = nil
local claimButton: TextButton? = nil
local statusLabel: TextLabel? = nil
local dayCards: { Frame } = {}
local autoShown = false

-- ---------------------------------------------------------------------------
-- Availability
-- ---------------------------------------------------------------------------

local function canClaim(data: DataController.PlayerData): boolean
	if data.LastDailyClaim == 0 then
		return true
	end
	return (os.time() - data.LastDailyClaim) >= DailyConfig.ClaimCooldown
end

-- The streak day the NEXT claim will award (1-based into the cycle).
local function nextStreakDay(data: DataController.PlayerData): number
	local count = #DailyConfig.Rewards
	local sinceLast = os.time() - data.LastDailyClaim
	local streak: number
	if data.LastDailyClaim == 0 or sinceLast > DailyConfig.ResetAfter then
		streak = 1
	else
		streak = data.DailyStreak + 1
	end
	return ((streak - 1) % count) + 1
end

-- ---------------------------------------------------------------------------
-- Claim
-- ---------------------------------------------------------------------------

local function doClaim()
	task.spawn(function()
		local ok, result = pcall(function()
			return DailyFunction:InvokeServer("Claim")
		end)
		if ok and type(result) == "table" then
			if result.success and statusLabel ~= nil then
				statusLabel.Text = "Claimed: " .. tostring(result.label) .. "  🎉"
				statusLabel.TextColor3 = UiUtil.Palette.Positive
			elseif statusLabel ~= nil then
				statusLabel.Text = tostring(result.reason or "Cannot claim yet.")
				statusLabel.TextColor3 = UiUtil.Palette.Warn
			end
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function refresh()
	local data = DataController:Get()
	if data == nil then
		return
	end

	local available = canClaim(data)
	local highlightDay = nextStreakDay(data)

	for index, card in ipairs(dayCards) do
		local isNext = available and index == highlightDay
		card.BackgroundColor3 = if isNext then UiUtil.Palette.Accent else UiUtil.Palette.PanelLight
	end

	if claimButton ~= nil then
		claimButton.Text = if available then "Claim Reward" else "Come back later"
		claimButton.BackgroundColor3 = if available then UiUtil.Palette.Positive else UiUtil.Palette.Disabled
		claimButton.AutoButtonColor = available
	end
	if statusLabel ~= nil and statusLabel.Text == "" then
		statusLabel.Text = string.format("Current streak: %d", data.DailyStreak)
		statusLabel.TextColor3 = UiUtil.Palette.SubText
	end
end

local function build()
	if gui ~= nil then
		return
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "DailyGui"
	screen.ResetOnSpawn = false
	screen.Enabled = false
	screen.IgnoreGuiInset = true
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.DisplayOrder = 8

	local panel = UiUtil.frame({
		Name = "Window",
		Size = UDim2.fromOffset(520, 320),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Parent = screen,
	})
	UiUtil.corner(panel, 12)
	UiUtil.stroke(panel, UiUtil.Palette.Warn, 1.5)

	UiUtil.label({
		Size = UDim2.new(1, -20, 0, 40),
		Position = UDim2.fromOffset(16, 10),
		Text = "🎁 Daily Reward",
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
		DailyController:Close()
	end)

	-- The 7-day track.
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Size = UDim2.new(1, -24, 0, 130)
	track.Position = UDim2.fromOffset(12, 60)
	track.BackgroundTransparency = 1
	track.Parent = panel
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(64, 90)
	layout.CellPadding = UDim2.fromOffset(6, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = track

	dayCards = {}
	for _, reward in ipairs(DailyConfig.Rewards) do
		local card = UiUtil.frame({
			Name = "Day" .. reward.Day,
			Size = UDim2.fromOffset(64, 90),
			Color = UiUtil.Palette.PanelLight,
			Parent = track,
		})
		card.LayoutOrder = reward.Day
		UiUtil.corner(card, 6)
		UiUtil.label({
			Size = UDim2.new(1, 0, 0, 16),
			Position = UDim2.fromOffset(0, 4),
			Text = "Day " .. reward.Day,
			Font = Enum.Font.GothamBold,
			TextSize = 12,
			Parent = card,
		})
		local desc = UiUtil.label({
			Size = UDim2.new(1, -6, 1, -24),
			Position = UDim2.fromOffset(3, 22),
			Text = reward.Label,
			TextColor = UiUtil.Palette.Text,
			TextSize = 11,
			Parent = card,
		})
		desc.TextWrapped = true
		table.insert(dayCards, card)
	end

	statusLabel = UiUtil.label({
		Size = UDim2.new(1, -24, 0, 24),
		Position = UDim2.fromOffset(16, 200),
		Text = "",
		Align = Enum.TextXAlignment.Left,
		TextSize = 15,
		Parent = panel,
	})

	claimButton = UiUtil.button({
		Size = UDim2.new(1, -24, 0, 44),
		Position = UDim2.new(0.5, 0, 1, -16),
		AnchorPoint = Vector2.new(0.5, 1),
		Text = "Claim Reward",
		Color = UiUtil.Palette.Positive,
		TextSize = 18,
		Parent = panel,
	})
	claimButton.Activated:Connect(doClaim)

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	screen.Parent = playerGui
	gui = screen
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function DailyController:Open()
	build()
	refresh()
	;(gui :: ScreenGui).Enabled = true
end

function DailyController:Close()
	if gui ~= nil then
		gui.Enabled = false
	end
end

function DailyController:Toggle()
	if gui ~= nil and gui.Enabled then
		self:Close()
	else
		self:Open()
	end
end

function DailyController:Init()
	build()

	DataController.Changed:Connect(function(data: DataController.PlayerData)
		if gui ~= nil and gui.Enabled then
			refresh()
		end

		-- Auto-open once on join if a reward is waiting.
		if not autoShown then
			autoShown = true
			if canClaim(data) then
				self:Open()
			end
		end
	end)
end

return DailyController
