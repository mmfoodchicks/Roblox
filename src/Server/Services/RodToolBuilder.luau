--!strict
--[[
	RodToolBuilder
	--------------
	Server module (ServerScriptService.Services.RodToolBuilder).

	Builds the fishing-rod Tool procedurally (no binary assets) and places a copy
	in StarterPack so every player spawns holding a rod. The Tool is recognised
	by FishingController via its name ("Fishing Rod") and the IsFishingRod
	attribute. A single generic rod is used for all tiers — the active rod's
	stats come from the player's server-side data, so no per-rod model is needed.
]]

local StarterPack = game:GetService("StarterPack")

local RodToolBuilder = {}

local GRIP_COLOR = Color3.fromRGB(70, 50, 35)
local SHAFT_COLOR = Color3.fromRGB(150, 110, 70)
local TIP_COLOR = Color3.fromRGB(220, 220, 220)
local LINE_COLOR = Color3.fromRGB(240, 240, 240)

-- Welds `part` to `handle` at their current relative CFrames and parents it.
local function attach(part: BasePart, handle: BasePart, parent: Instance)
	part.Anchored = false
	part.CanCollide = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = part
	weld.Parent = handle

	part.Parent = parent
end

-- Constructs a fresh Tool instance.
local function buildTool(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Fishing Rod"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = "Equip and click to cast your line!"
	tool:SetAttribute("IsFishingRod", true)

	-- Handle = the cork grip the character holds.
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.5, 0.5, 1.6)
	handle.Color = GRIP_COLOR
	handle.Material = Enum.Material.Wood
	handle.Anchored = false
	handle.CanCollide = false
	handle.Massless = true
	handle.TopSurface = Enum.SurfaceType.Smooth
	handle.BottomSurface = Enum.SurfaceType.Smooth
	handle.CFrame = CFrame.new(0, 0, 0)
	handle.Parent = tool

	-- Shaft = the long thin pole extending forward from the grip.
	local shaft = Instance.new("Part")
	shaft.Name = "Shaft"
	shaft.Size = Vector3.new(0.22, 0.22, 6)
	shaft.Color = SHAFT_COLOR
	shaft.Material = Enum.Material.Wood
	shaft.CFrame = handle.CFrame * CFrame.new(0, 0, -3.6)
	attach(shaft, handle, tool)

	-- Tip = a small marker at the far end of the shaft (line origin).
	local tip = Instance.new("Part")
	tip.Name = "Tip"
	tip.Shape = Enum.PartType.Ball
	tip.Size = Vector3.new(0.3, 0.3, 0.3)
	tip.Color = TIP_COLOR
	tip.Material = Enum.Material.SmoothPlastic
	tip.CFrame = handle.CFrame * CFrame.new(0, 0, -6.7)
	attach(tip, handle, tool)

	-- A thin "fishing line" hanging from the tip, purely cosmetic.
	local line = Instance.new("Part")
	line.Name = "Line"
	line.Size = Vector3.new(0.04, 2.2, 0.04)
	line.Color = LINE_COLOR
	line.Material = Enum.Material.Neon
	line.Transparency = 0.2
	line.CFrame = handle.CFrame * CFrame.new(0, -1.1, -6.7)
	attach(line, handle, tool)

	return tool
end

function RodToolBuilder:Build(): Tool
	return buildTool()
end

function RodToolBuilder:Init()
	-- Remove any stale copy (e.g. from a previous hot reload) then seed
	-- StarterPack so Roblox hands the rod to every player on spawn.
	local existing = StarterPack:FindFirstChild("Fishing Rod")
	if existing ~= nil then
		existing:Destroy()
	end
	buildTool().Parent = StarterPack
end

return RodToolBuilder
