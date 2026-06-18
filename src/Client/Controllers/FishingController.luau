--!strict
--[[
	FishingController
	-----------------
	Client module (StarterPlayer.StarterPlayerScripts.Controllers.FishingController).

	Owns everything the *local* player sees and does while fishing. It never
	decides outcomes — it requests casts, plays the skill minigame, and reports
	the result; the server is authoritative for the catch itself.

	Flow:
	  1. Player activates their fishing rod Tool  -> fire "RequestCast", spawn water FX.
	  2. Server replies "FishBite"               -> show the slider minigame.
	  3. Player stops the slider (or it times out)-> fire "ResolveMinigame" {success}.
	  4. Server replies "CatchResult"            -> show reward UI + particle burst.

	The minigame is a moving-bar / target overlap: a marker sweeps left<->right;
	the player presses to stop it; success is overlap with the target zone. It is
	driven by RunService.RenderStepped for frame-smooth motion.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local FishingNetwork = ReplicatedStorage:WaitForChild("FishingNetwork") :: RemoteEvent

local LocalPlayer = Players.LocalPlayer

-- ---------------------------------------------------------------------------
-- Minigame tuning
-- ---------------------------------------------------------------------------

-- The green zone size is randomised each cast (bigger/smaller), but the sweep
-- speed is kept fairly steady and on the slower side so it stays readable.
local TARGET_MIN_SCALE = 0.16  -- smallest green zone (still fair)
local TARGET_MAX_SCALE = 0.30  -- largest green zone (easy)
local MARKER_WIDTH_SCALE = 0.035 -- Marker width as a fraction of the track.
local SWEEP_MIN_SPEED = 1.3     -- slowest sweep (full tracks / second)
local SWEEP_MAX_SPEED = 1.8     -- fastest sweep
local MINIGAME_TIMEOUT = 6      -- Auto-fail (miss) if the player never reacts.

-- ---------------------------------------------------------------------------
-- Controller state
-- ---------------------------------------------------------------------------

local FishingController = {}

-- Identifies the cast the current minigame belongs to, so a late server packet
-- for a previous cast cannot reopen the UI.
local activeCastId: number? = nil

-- True between firing RequestCast and the bite (or a rejection) arriving, so we
-- never spam the server with extra casts during the wait (which produced the
-- spurious "Casting too quickly" message).
local castPending = false

-- The current round's randomised difficulty, set in startMinigame and read by
-- the sweep + hit test so the green zone size and speed vary each cast.
local currentTargetWidth = TARGET_MAX_SCALE
local currentSweepSpeed = SWEEP_MIN_SPEED

-- The live RenderStepped connection for the sweeping marker, if any.
local sweepConnection: RBXScriptConnection? = nil

-- UI handles, created lazily once.
local gui: ScreenGui? = nil
local minigameFrame: Frame? = nil
local targetZone: Frame? = nil
local marker: Frame? = nil
local rewardLabel: TextLabel? = nil

-- ---------------------------------------------------------------------------
-- UI construction
-- ---------------------------------------------------------------------------

local function buildUi()
	if gui ~= nil then
		return
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "FishingGui"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Reward / status toast.
	local reward = Instance.new("TextLabel")
	reward.Name = "Reward"
	reward.AnchorPoint = Vector2.new(0.5, 0)
	reward.Position = UDim2.fromScale(0.5, 0.12)
	reward.Size = UDim2.fromScale(0.4, 0.07)
	reward.BackgroundTransparency = 1
	reward.Font = Enum.Font.GothamBold
	reward.TextScaled = true
	reward.TextColor3 = Color3.fromRGB(255, 255, 255)
	reward.TextStrokeTransparency = 0.4
	reward.Text = ""
	reward.Visible = false
	reward.Parent = screen

	-- Minigame container (hidden until a bite).
	local frame = Instance.new("Frame")
	frame.Name = "Minigame"
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Position = UDim2.fromScale(0.5, 0.88)
	frame.Size = UDim2.fromScale(0.42, 0.06)
	frame.BackgroundColor3 = Color3.fromRGB(24, 28, 34)
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = screen

	local frameCorner = Instance.new("UICorner")
	frameCorner.CornerRadius = UDim.new(0, 8)
	frameCorner.Parent = frame

	-- The target zone the player is trying to stop the marker inside.
	local target = Instance.new("Frame")
	target.Name = "Target"
	target.AnchorPoint = Vector2.new(0.5, 0.5)
	target.Position = UDim2.fromScale(0.5, 0.5)
	target.Size = UDim2.fromScale(currentTargetWidth, 0.8)
	target.BackgroundColor3 = Color3.fromRGB(88, 196, 120)
	target.BackgroundTransparency = 0.25
	target.BorderSizePixel = 0
	target.Parent = frame

	local targetCorner = Instance.new("UICorner")
	targetCorner.CornerRadius = UDim.new(0, 6)
	targetCorner.Parent = target

	-- The sweeping marker the player stops.
	local mark = Instance.new("Frame")
	mark.Name = "Marker"
	mark.AnchorPoint = Vector2.new(0.5, 0.5)
	mark.Position = UDim2.fromScale(0, 0.5)
	mark.Size = UDim2.fromScale(MARKER_WIDTH_SCALE, 1)
	mark.BackgroundColor3 = Color3.fromRGB(255, 230, 120)
	mark.BorderSizePixel = 0
	mark.ZIndex = 2
	mark.Parent = frame

	local markCorner = Instance.new("UICorner")
	markCorner.CornerRadius = UDim.new(0, 4)
	markCorner.Parent = mark

	-- Prompt text under the bar.
	local prompt = Instance.new("TextLabel")
	prompt.Name = "Prompt"
	prompt.AnchorPoint = Vector2.new(0.5, 0)
	prompt.Position = UDim2.fromScale(0.5, 1.1)
	prompt.Size = UDim2.fromScale(1, 0.7)
	prompt.BackgroundTransparency = 1
	prompt.Font = Enum.Font.Gotham
	prompt.TextScaled = true
	prompt.TextColor3 = Color3.fromRGB(235, 238, 242)
	prompt.Text = "Click / Tap to hook the fish!"
	prompt.Parent = frame

	gui = screen
	minigameFrame = frame
	targetZone = target
	marker = mark
	rewardLabel = reward

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	screen.Parent = playerGui
end

-- ---------------------------------------------------------------------------
-- Reward toast
-- ---------------------------------------------------------------------------

local function showToast(text: string, color: Color3)
	local label = rewardLabel
	if label == nil then
		return
	end
	label.Text = text
	label.TextColor3 = color
	label.TextTransparency = 0
	label.Visible = true

	local tween = TweenService:Create(
		label,
		TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, 0.6),
		{ TextTransparency = 1 }
	)
	tween:Play()
	tween.Completed:Once(function()
		if label.TextTransparency >= 1 then
			label.Visible = false
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Water particle effects (local, cosmetic)
-- ---------------------------------------------------------------------------

-- Builds a short-lived splash where the bobber lands. Purely cosmetic and local,
-- so it costs the server nothing. Positioned just in front of the character.
local function playWaterSplash()
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root == nil then
		return
	end

	local anchor = Instance.new("Part")
	anchor.Name = "FishingSplash"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = root.CFrame * CFrame.new(0, -1, -6)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Color = ColorSequence.new(Color3.fromRGB(120, 190, 255), Color3.fromRGB(210, 235, 255))
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new(0.6, 0.1)
	emitter.Lifetime = NumberRange.new(0.4, 0.8)
	emitter.Speed = NumberRange.new(4, 8)
	emitter.SpreadAngle = Vector2.new(35, 35)
	emitter.Acceleration = Vector3.new(0, -18, 0)
	emitter.Rate = 0
	emitter.Parent = anchor

	anchor.Parent = workspace
	emitter:Emit(28)
	Debris:AddItem(anchor, 1.2)
end

-- A celebratory burst tinted to the rarity colour of the caught item.
local function playCatchBurst(color: Color3)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root == nil then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Position = Vector3.new(0, 3, 0)
	attachment.Parent = root

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Color = ColorSequence.new(color)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new(0.8, 0.2)
	emitter.Lifetime = NumberRange.new(0.6, 1.1)
	emitter.Speed = NumberRange.new(6, 12)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = 0
	emitter.Parent = attachment

	emitter:Emit(40)
	Debris:AddItem(attachment, 1.4)
end

-- ---------------------------------------------------------------------------
-- The minigame
-- ---------------------------------------------------------------------------

-- Tears down any running minigame, disconnecting the sweep and hiding the UI.
local function stopMinigame()
	if sweepConnection ~= nil then
		sweepConnection:Disconnect()
		sweepConnection = nil
	end
	if minigameFrame ~= nil then
		minigameFrame.Visible = false
	end
end

-- Sends the result to the server exactly once per cast and tears down the UI.
local function resolve(castId: number, success: boolean)
	-- Guard against double-resolution (e.g. click landing on the same frame as
	-- the timeout).
	if activeCastId ~= castId then
		return
	end
	activeCastId = nil
	stopMinigame()
	FishingNetwork:FireServer("ResolveMinigame", { success = success })
end

-- Opens the slider minigame for a given cast.
local function startMinigame(castId: number)
	buildUi()
	local frame = minigameFrame :: Frame
	local mark = marker :: Frame

	activeCastId = castId
	castPending = false -- the bite arrived; stop blocking input

	-- Randomise difficulty for this round: a green zone somewhere between the
	-- min/max width, and a sweep speed somewhere between the min/max.
	currentTargetWidth = TARGET_MIN_SCALE + math.random() * (TARGET_MAX_SCALE - TARGET_MIN_SCALE)
	currentSweepSpeed = SWEEP_MIN_SPEED + math.random() * (SWEEP_MAX_SPEED - SWEEP_MIN_SPEED)

	-- Randomise the target zone position each round (kept fully on-track).
	local half = currentTargetWidth / 2
	local targetCenter = half + math.random() * (1 - currentTargetWidth)
	local target = targetZone :: Frame
	target.Size = UDim2.fromScale(currentTargetWidth, 0.8)
	target.Position = UDim2.fromScale(targetCenter, 0.5)

	frame.Visible = true

	local startClock = os.clock()

	-- Smooth sweep via RenderStepped. Marker oscillates 0..1 using a triangle
	-- wave so motion is linear and predictable for the player.
	sweepConnection = RunService.RenderStepped:Connect(function()
		if activeCastId ~= castId then
			return
		end

		local elapsed = os.clock() - startClock

		-- Triangle wave in [0, 1].
		local phase = (elapsed * currentSweepSpeed) % 2
		local position = if phase <= 1 then phase else 2 - phase
		mark.Position = UDim2.fromScale(position, 0.5)

		-- Auto-fail if the player never reacts.
		if elapsed >= MINIGAME_TIMEOUT then
			resolve(castId, false)
		end
	end)
end

-- Called when the player presses to stop the marker. Success = marker center
-- lies within the target zone.
local function attemptHook()
	local castId = activeCastId
	if castId == nil then
		return
	end

	local markPos = (marker :: Frame).Position.X.Scale
	local targetCenter = (targetZone :: Frame).Position.X.Scale
	local halfTarget = currentTargetWidth / 2

	local success = math.abs(markPos - targetCenter) <= halfTarget
	resolve(castId, success)
end

-- ---------------------------------------------------------------------------
-- Tool / rod activation
-- ---------------------------------------------------------------------------

-- Tools we have already wired, so re-parenting between Backpack and Character
-- on equip/unequip never double-binds the Activated handler.
local boundTools: { [Tool]: true } = setmetatable({}, { __mode = "k" }) :: any

-- Connects a fishing-rod Tool's Activated event to a cast request.
local function bindRodTool(tool: Tool)
	-- A simple convention: any Tool tagged/named as a rod can fish. Adjust the
	-- predicate to match your asset naming.
	if not (tool:GetAttribute("IsFishingRod") == true or string.find(string.lower(tool.Name), "rod")) then
		return
	end

	-- Bind each rod exactly once for its lifetime.
	if boundTools[tool] then
		return
	end
	boundTools[tool] = true

	tool.Activated:Connect(function()
		-- Ignore activation while a minigame is open OR a cast is already waiting
		-- for its bite — otherwise repeated clicks spam RequestCast and the server
		-- rightly rejects them ("Casting too quickly").
		if activeCastId ~= nil or castPending then
			return
		end
		castPending = true
		playWaterSplash()
		FishingNetwork:FireServer("RequestCast")

		-- Safety net: if the bite/rejection packet is ever missed, never leave the
		-- player permanently unable to cast. (Bite times are only a few seconds.)
		task.delay(12, function()
			castPending = false
		end)
	end)
end

local function watchCharacterTools(character: Model)
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") then
			bindRodTool(child)
		end
	end
	character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			bindRodTool(child)
		end
	end)

	-- Tools equipped from the backpack are parented to the character on equip;
	-- the ChildAdded handler above covers those. Also bind any already in the
	-- backpack so re-equips don't double-bind (Activated only fires when held).
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if backpack ~= nil then
		for _, child in ipairs(backpack:GetChildren()) do
			if child:IsA("Tool") then
				bindRodTool(child)
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Network handling
-- ---------------------------------------------------------------------------

local rarityColors: { [string]: Color3 } = {
	Common = Color3.fromRGB(170, 178, 184),
	Uncommon = Color3.fromRGB(88, 196, 120),
	Rare = Color3.fromRGB(64, 156, 255),
	Legendary = Color3.fromRGB(190, 96, 255),
}

local function onCatchResult(data: { [string]: any })
	if data.success ~= true then
		showToast("The fish got away!", Color3.fromRGB(220, 110, 110))
		return
	end

	local item = data.item or {}
	local color = (typeof(item.Color) == "Color3" and item.Color)
		or rarityColors[item.Rarity]
		or Color3.fromRGB(255, 255, 255)

	local prefix = if data.auto == true then "🤖 Auto-caught " else "Caught "
	showToast(string.format("%s%s!  (worth %d 🪙)", prefix, tostring(item.Name), tonumber(data.value) or 0), color)

	-- Auto-fisher catches are frequent; skip the big particle burst to avoid
	-- visual spam, but still flash the toast.
	if data.auto ~= true then
		playCatchBurst(color)
	end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--[[
	Init
	Builds UI, wires input + network handlers, and binds rod tools. Called once
	by the client bootstrap.
]]
function FishingController:Init()
	buildUi()

	-- Server -> client dispatch.
	FishingNetwork.OnClientEvent:Connect(function(action: string, payload: any)
		if action == "FishBite" then
			local castId = payload and payload.castId
			if type(castId) == "number" then
				startMinigame(castId)
			end
		elseif action == "CatchResult" then
			castPending = false
			onCatchResult(payload or {})
		elseif action == "CastRejected" then
			castPending = false
			local reason = payload and payload.reason
			showToast(tostring(reason or "Cast failed"), Color3.fromRGB(220, 180, 90))
		elseif action == "Notice" then
			-- Generic server notice (e.g. a Luck Potion activating).
			local text = payload and payload.text
			showToast(tostring(text or ""), Color3.fromRGB(190, 96, 255))
		end
	end)

	-- Player input to stop the marker (mouse, touch, or controller).
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or activeCastId == nil then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
			or input.KeyCode == Enum.KeyCode.Space
			or input.KeyCode == Enum.KeyCode.ButtonA
		then
			attemptHook()
		end
	end)

	-- Bind rod tools across respawns.
	if LocalPlayer.Character ~= nil then
		watchCharacterTools(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(watchCharacterTools)
end

return FishingController
