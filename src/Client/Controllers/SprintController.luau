--!strict
--[[
	SprintController
	----------------
	Client module (StarterPlayerScripts.Controllers.SprintController).

	Hold Shift to sprint. Raises the local character's WalkSpeed while held and
	restores it on release (and on respawn). Touch devices get a small on-screen
	Sprint toggle button.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local WALK_SPEED = 16
local SPRINT_SPEED = 28

local SprintController = {}

local sprinting = false

local function currentHumanoid(): Humanoid?
	local character = LocalPlayer.Character
	if character == nil then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function apply()
	local humanoid = currentHumanoid()
	if humanoid ~= nil then
		humanoid.WalkSpeed = if sprinting then SPRINT_SPEED else WALK_SPEED
	end
end

local function setSprinting(on: boolean)
	sprinting = on
	apply()
end

local function buildTouchButton()
	local gui = Instance.new("ScreenGui")
	gui.Name = "SprintGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	local button = Instance.new("TextButton")
	button.Name = "Sprint"
	button.Size = UDim2.fromOffset(96, 96)
	button.Position = UDim2.new(0, 30, 1, -180)
	button.AnchorPoint = Vector2.new(0, 1)
	button.BackgroundColor3 = Color3.fromRGB(40, 46, 56)
	button.BackgroundTransparency = 0.2
	button.Text = "Sprint"
	button.TextColor3 = Color3.fromRGB(236, 240, 245)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 16
	button.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = button

	-- Toggle on tap (mobile has no Shift key).
	button.Activated:Connect(function()
		setSprinting(not sprinting)
		button.BackgroundColor3 = if sprinting then Color3.fromRGB(64, 156, 255) else Color3.fromRGB(40, 46, 56)
	end)
end

function SprintController:Init()
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
			setSprinting(true)
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
			setSprinting(false)
		end
	end)

	-- Reset speed each spawn (and re-apply if mid-sprint).
	LocalPlayer.CharacterAdded:Connect(function()
		task.defer(apply)
	end)

	-- Only show the touch button on touch-primary devices without a keyboard.
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		buildTouchButton()
	end
end

return SprintController
