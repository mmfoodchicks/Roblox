--!strict
--[[
	MapBuilder
	----------
	Server module (ServerScriptService.Services.MapBuilder).

	Procedurally constructs the entire fishing map at server start so the game
	ships with zero binary assets — everything is code, version-controlled, and
	reproducible. Built geometry lives under a single Workspace folder
	("GeneratedMap") which is cleared and rebuilt idempotently, so a hot reload
	never leaves duplicates behind.

	Scene layout (studs, world origin at the island centre):
	  * A grass island sitting at y = 0.
	  * A surrounding sand beach ring.
	  * A real Terrain water lake carved around the island for swimming/casting.
	  * A wooden dock extending out over the water with railing posts.
	  * A SpawnLocation on the island.
	  * Scattered rocks and low-poly trees for set dressing.
	  * Tuned Lighting + Atmosphere + Sky for a bright outdoor mood.
]]

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(script.Parent.DataService)

local FishingNetwork = ReplicatedStorage:WaitForChild("FishingNetwork") :: RemoteEvent

local MapBuilder = {}

-- ---------------------------------------------------------------------------
-- Tuning
-- ---------------------------------------------------------------------------

local MAP_FOLDER_NAME = "GeneratedMap"

local ISLAND_RADIUS = 90       -- Grass island radius.
local BEACH_WIDTH = 16         -- Sand ring width beyond the grass.
local WATER_RADIUS = 300       -- Outer radius of the terrain water lake.
local WATER_DEPTH = 40         -- How deep the lake is carved below y = 0.
local DOCK_LENGTH = 80         -- Dock reach out over the water (+Z).
local DOCK_WIDTH = 12
local DOCK_HEIGHT = 6          -- Deck height above water level.

-- Parkour course tuning.
local PARKOUR_PLATFORMS = 11   -- Number of jumps.
local PARKOUR_REWARD = 1500    -- Coins for reaching the top...
local PARKOUR_COOLDOWN = 120   -- ...claimable at most once per this many seconds.

-- A small, fixed palette so the scene reads cleanly.
local COLORS = {
	Grass = Color3.fromRGB(91, 154, 76),
	Sand = Color3.fromRGB(224, 207, 150),
	Wood = Color3.fromRGB(122, 84, 52),
	WoodDark = Color3.fromRGB(92, 62, 38),
	Rock = Color3.fromRGB(120, 124, 128),
	Trunk = Color3.fromRGB(104, 72, 44),
	Leaves = Color3.fromRGB(64, 138, 70),
	Reward = Color3.fromRGB(240, 200, 90),
}

-- Rotating platform palette for the parkour.
local PARKOUR_COLORS = {
	Color3.fromRGB(88, 196, 120),
	Color3.fromRGB(64, 156, 255),
	Color3.fromRGB(170, 96, 255),
	Color3.fromRGB(240, 180, 70),
	Color3.fromRGB(255, 90, 140),
}

-- ---------------------------------------------------------------------------
-- Build helpers
-- ---------------------------------------------------------------------------

-- Creates an anchored, non-colliding-by-default-configurable Part with sensible
-- defaults and parents it. Keeps the rest of the file terse.
local function makePart(props: {
	Name: string,
	Size: Vector3,
	CFrame: CFrame,
	Color: Color3,
	Material: Enum.Material,
	Shape: Enum.PartType?,
	CanCollide: boolean?,
	Transparency: number?,
	Parent: Instance,
}): BasePart
	local part: BasePart
	if props.Shape ~= nil then
		local p = Instance.new("Part")
		p.Shape = props.Shape
		part = p
	else
		part = Instance.new("Part")
	end

	part.Name = props.Name
	part.Anchored = true
	part.Size = props.Size
	part.CFrame = props.CFrame
	part.Color = props.Color
	part.Material = props.Material
	part.CanCollide = if props.CanCollide == nil then true else props.CanCollide
	part.Transparency = props.Transparency or 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = props.Parent
	return part
end

-- ---------------------------------------------------------------------------
-- Section builders
-- ---------------------------------------------------------------------------

local function buildIsland(parent: Instance)
	-- Grass disc (a flat cylinder reads as a round island).
	local island = makePart({
		Name = "Island",
		Size = Vector3.new(ISLAND_RADIUS * 2, 8, ISLAND_RADIUS * 2),
		CFrame = CFrame.new(0, -4, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Color = COLORS.Grass,
		Material = Enum.Material.Grass,
		Shape = Enum.PartType.Cylinder,
		Parent = parent,
	})
	island.Name = "Island"

	-- Sand beach ring, slightly lower and wider, sitting at the waterline.
	makePart({
		Name = "Beach",
		Size = Vector3.new((ISLAND_RADIUS + BEACH_WIDTH) * 2, 6, (ISLAND_RADIUS + BEACH_WIDTH) * 2),
		CFrame = CFrame.new(0, -5, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Color = COLORS.Sand,
		Material = Enum.Material.Sand,
		Shape = Enum.PartType.Cylinder,
		Parent = parent,
	})
end

local function buildWater()
	-- Carve a real Terrain water lake. We first clear a generous block of any
	-- existing terrain around the island, then fill a shallower block with
	-- water. FillBlock uses a CFrame centre + size.
	local terrain = Workspace.Terrain

	local clearCenter = CFrame.new(0, -WATER_DEPTH / 2 - 2, 0)
	local clearSize = Vector3.new(WATER_RADIUS * 2, WATER_DEPTH + 4, WATER_RADIUS * 2)
	terrain:FillBlock(clearCenter, clearSize, Enum.Material.Air)

	-- Fill water up to y = 0 (the island/beach waterline).
	local waterCenter = CFrame.new(0, -WATER_DEPTH / 2, 0)
	local waterSize = Vector3.new(WATER_RADIUS * 2, WATER_DEPTH, WATER_RADIUS * 2)
	terrain:FillBlock(waterCenter, waterSize, Enum.Material.Water)
end

local function buildDock(parent: Instance)
	local dock = Instance.new("Model")
	dock.Name = "Dock"
	dock.Parent = parent

	-- The deck starts at the island edge and runs out over the water (+Z).
	local startZ = ISLAND_RADIUS - 4
	local plankCount = 14
	local plankDepth = DOCK_LENGTH / plankCount

	for i = 0, plankCount - 1 do
		local z = startZ + plankDepth * (i + 0.5)
		makePart({
			Name = "Plank",
			Size = Vector3.new(DOCK_WIDTH, 1, plankDepth - 0.15),
			CFrame = CFrame.new(0, DOCK_HEIGHT, z),
			Color = if i % 2 == 0 then COLORS.Wood else COLORS.WoodDark,
			Material = Enum.Material.WoodPlanks,
			Parent = dock,
		})
	end

	-- Support posts + railing along both sides.
	local postZs = { startZ + 4, startZ + DOCK_LENGTH * 0.5, startZ + DOCK_LENGTH - 2 }
	for _, z in ipairs(postZs) do
		for _, side in ipairs({ -1, 1 }) do
			local x = side * (DOCK_WIDTH / 2 - 0.5)
			-- Vertical support down into the water bed.
			makePart({
				Name = "Post",
				Size = Vector3.new(1, DOCK_HEIGHT + WATER_DEPTH, 1),
				CFrame = CFrame.new(x, DOCK_HEIGHT - (DOCK_HEIGHT + WATER_DEPTH) / 2 + 0.5, z),
				Color = COLORS.WoodDark,
				Material = Enum.Material.Wood,
				Parent = dock,
			})
			-- Railing cap.
			makePart({
				Name = "Rail",
				Size = Vector3.new(1, 3, 1),
				CFrame = CFrame.new(x, DOCK_HEIGHT + 2.5, z),
				Color = COLORS.Wood,
				Material = Enum.Material.Wood,
				Parent = dock,
			})
		end
	end

	-- A marker part at the dock end so other systems (or designers) can find the
	-- canonical "fishing spot". Tagged via an attribute, invisible, no collision.
	local spot = makePart({
		Name = "FishingSpot",
		Size = Vector3.new(DOCK_WIDTH, 1, 2),
		CFrame = CFrame.new(0, DOCK_HEIGHT + 1, startZ + DOCK_LENGTH - 2),
		Color = COLORS.Wood,
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		Transparency = 1,
		Parent = dock,
	})
	spot:SetAttribute("IsFishingSpot", true)

	dock.PrimaryPart = spot
end

local function buildSpawn(parent: Instance)
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "FishingSpawn"
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.CFrame = CFrame.new(0, 0.5, -ISLAND_RADIUS * 0.4)
	spawn.Anchored = true
	spawn.Color = COLORS.Wood
	spawn.Material = Enum.Material.WoodPlanks
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.Neutral = true
	spawn.Duration = 0 -- No forcefield; this is a peaceful sim.
	spawn.Parent = parent
end

-- A simple low-poly tree: trunk + two stacked leaf blocks.
local function buildTree(parent: Instance, position: Vector3)
	local tree = Instance.new("Model")
	tree.Name = "Tree"
	tree.Parent = parent

	local trunk = makePart({
		Name = "Trunk",
		Size = Vector3.new(2, 10, 2),
		CFrame = CFrame.new(position + Vector3.new(0, 5, 0)),
		Color = COLORS.Trunk,
		Material = Enum.Material.Wood,
		Parent = tree,
	})

	makePart({
		Name = "Leaves",
		Size = Vector3.new(10, 8, 10),
		CFrame = CFrame.new(position + Vector3.new(0, 12, 0)),
		Color = COLORS.Leaves,
		Material = Enum.Material.Grass,
		Parent = tree,
	})
	makePart({
		Name = "LeavesTop",
		Size = Vector3.new(7, 6, 7),
		CFrame = CFrame.new(position + Vector3.new(0, 17, 0)),
		Color = COLORS.Leaves,
		Material = Enum.Material.Grass,
		Parent = tree,
	})

	tree.PrimaryPart = trunk
end

local function buildScenery(parent: Instance)
	local scenery = Instance.new("Folder")
	scenery.Name = "Scenery"
	scenery.Parent = parent

	-- Deterministic placement (seeded) so the map looks identical every boot.
	local rng = Random.new(20240618)

	-- Ring of trees set back from the beach, leaving the dock side (+Z) open.
	local treeCount = 9
	for i = 1, treeCount do
		local angle = (i / treeCount) * math.pi * 2
		-- Skip the wedge facing the dock so it stays clear.
		if math.abs(angle - math.pi / 2) < 0.6 then
			continue
		end
		local radius = ISLAND_RADIUS * 0.7 + rng:NextNumber(-6, 6)
		local x = math.cos(angle) * radius
		local z = math.sin(angle) * radius
		buildTree(scenery, Vector3.new(x, 0, z))
	end

	-- A handful of shoreline rocks for variety.
	for _ = 1, 8 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local radius = ISLAND_RADIUS + BEACH_WIDTH + rng:NextNumber(0, 10)
		local x = math.cos(angle) * radius
		local z = math.sin(angle) * radius
		local size = rng:NextNumber(4, 9)
		makePart({
			Name = "Rock",
			Size = Vector3.new(size, size * 0.7, size),
			CFrame = CFrame.new(x, -1, z) * CFrame.Angles(
				rng:NextNumber(0, 0.4),
				rng:NextNumber(0, math.pi * 2),
				rng:NextNumber(0, 0.4)
			),
			Color = COLORS.Rock,
			Material = Enum.Material.Slate,
			Parent = scenery,
		})
	end
end

-- Builds an ascending floating-platform parkour off the island's -X side, with a
-- glowing coin reward at the top. The reward grants coins (server-authoritative)
-- with a per-player cooldown so it can't be farmed.
local function buildParkour(parent: Instance)
	local model = Instance.new("Model")
	model.Name = "Parkour"
	model.Parent = parent

	-- Start just off the island edge, ascending outward over the water.
	local pos = Vector3.new(-(ISLAND_RADIUS - 10), 4, -14)
	local lastPlatformPos = pos

	for i = 1, PARKOUR_PLATFORMS do
		local isLast = i == PARKOUR_PLATFORMS
		local size = if isLast then Vector3.new(14, 1, 14) else Vector3.new(6, 1, 6)
		local color = if isLast then COLORS.Reward else PARKOUR_COLORS[((i - 1) % #PARKOUR_COLORS) + 1]

		makePart({
			Name = if isLast then "Summit" else "Platform" .. i,
			Size = size,
			CFrame = CFrame.new(pos),
			Color = color,
			Material = if isLast then Enum.Material.WoodPlanks else Enum.Material.SmoothPlastic,
			Parent = model,
		})

		lastPlatformPos = pos

		-- Next platform: step outward (-X) and up, zig-zagging in Z so jumps
		-- alternate direction. Gaps are tuned to be reachable with a default jump.
		local dz = if i % 2 == 0 then 6 else -6
		pos += Vector3.new(-7.5, 3.6, dz)
	end

	-- Glowing reward beacon on the summit (walk into it to claim).
	local reward = makePart({
		Name = "ParkourReward",
		Size = Vector3.new(4, 4, 4),
		CFrame = CFrame.new(lastPlatformPos + Vector3.new(0, 4, 0)),
		Color = COLORS.Reward,
		Material = Enum.Material.Neon,
		CanCollide = false,
		Parent = model,
	})
	reward:SetAttribute("IsParkourReward", true)

	local light = Instance.new("PointLight")
	light.Color = COLORS.Reward
	light.Range = 18
	light.Brightness = 3
	light.Parent = reward

	-- Floating call-out.
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(180, 44)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = reward
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 240, 180)
	label.TextStrokeTransparency = 0.3
	label.Text = string.format("🏆 +%d Coins", PARKOUR_REWARD)
	label.Parent = billboard

	-- Server-authoritative reward grant with a per-player cooldown.
	local lastClaim: { [Player]: number } = {}
	reward.Touched:Connect(function(hit: BasePart)
		local character = hit.Parent
		if character == nil then
			return
		end
		local player = Players:GetPlayerFromCharacter(character)
		if player == nil then
			return
		end

		local now = os.clock()
		local previous = lastClaim[player]
		if previous ~= nil and (now - previous) < PARKOUR_COOLDOWN then
			return
		end
		lastClaim[player] = now

		local newBalance = DataService:AwardCoins(player, PARKOUR_REWARD)
		if newBalance ~= nil then
			FishingNetwork:FireClient(player, "Notice", {
				text = string.format("🏆 Parkour complete!  +%d coins", PARKOUR_REWARD),
			})
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastClaim[player] = nil
	end)
end

local function tuneLighting()
	-- NOTE: Lighting.Technology is a protected property that game scripts cannot
	-- write at runtime (it raises "lacking capability RobloxScript"). It is set
	-- instead in default.project.json so the place ships on Future lighting.
	-- Everything below is freely writable at runtime.
	Lighting.Ambient = Color3.fromRGB(120, 125, 130)
	Lighting.OutdoorAmbient = Color3.fromRGB(140, 150, 160)
	Lighting.Brightness = 2.5
	Lighting.ClockTime = 14.5
	Lighting.GeographicLatitude = 30
	Lighting.ExposureCompensation = 0.15
	Lighting.EnvironmentDiffuseScale = 0.6
	Lighting.EnvironmentSpecularScale = 0.6

	-- Light haze over the water for depth.
	local existingAtmos = Lighting:FindFirstChildOfClass("Atmosphere")
	local atmosphere = existingAtmos or Instance.new("Atmosphere")
	atmosphere.Density = 0.32
	atmosphere.Offset = 0.1
	atmosphere.Color = Color3.fromRGB(199, 215, 230)
	atmosphere.Decay = Color3.fromRGB(106, 134, 150)
	atmosphere.Glare = 0.2
	atmosphere.Haze = 1.6
	atmosphere.Parent = Lighting

	-- A clear-ish sky.
	local existingSky = Lighting:FindFirstChildOfClass("Sky")
	if existingSky == nil then
		local sky = Instance.new("Sky")
		sky.Name = "FishingSky"
		sky.SunAngularSize = 11
		sky.MoonAngularSize = 11
		sky.Parent = Lighting
	end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--[[
	Build
	(Re)builds the entire map. Idempotent: any previous GeneratedMap folder and
	stray default Baseplate are removed first. Returns the map folder.
]]
function MapBuilder:Build(): Folder
	-- Remove a previous generation.
	local previous = Workspace:FindFirstChild(MAP_FOLDER_NAME)
	if previous ~= nil then
		previous:Destroy()
	end

	-- Remove the default template baseplate if one exists; our island replaces it.
	local baseplate = Workspace:FindFirstChild("Baseplate")
	if baseplate ~= nil then
		baseplate:Destroy()
	end

	local mapFolder = Instance.new("Folder")
	mapFolder.Name = MAP_FOLDER_NAME

	buildIsland(mapFolder)
	buildDock(mapFolder)
	buildSpawn(mapFolder)
	buildScenery(mapFolder)
	buildParkour(mapFolder)

	mapFolder.Parent = Workspace

	-- Cosmetic, environment-dependent steps run guarded so a failure on any
	-- given Studio/runtime configuration can never abort map creation (and with
	-- it the rest of server startup). The island + spawn above always succeed.
	pcall(buildWater)   -- Terrain is a singleton under Workspace.
	pcall(tuneLighting)

	return mapFolder
end

--[[
	Init
	Called once by the server bootstrap. Builds the map immediately.
]]
function MapBuilder:Init()
	self:Build()
end

return MapBuilder
