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
local TeleportService = game:GetService("TeleportService")

local DataService = require(script.Parent.DataService)
local TeleportConfig = require(ReplicatedStorage.Shared.TeleportConfig)

local FishingNetwork = ReplicatedStorage:WaitForChild("FishingNetwork") :: RemoteEvent

local MapBuilder = {}

-- ---------------------------------------------------------------------------
-- Tuning
-- ---------------------------------------------------------------------------

local MAP_FOLDER_NAME = "GeneratedMap"

local ISLAND_RADIUS = 180      -- Grass island radius (a huge island to explore).
local BEACH_WIDTH = 20         -- Sand ring width beyond the grass.
local WATER_RADIUS = 520       -- Outer radius of the terrain water lake.
local WATER_DEPTH = 50         -- How deep the lake is carved below y = 0.
local DOCK_LENGTH = 90         -- Dock reach out over the water (+Z).
local DOCK_WIDTH = 14
local DOCK_HEIGHT = 6          -- Deck height above water level.

-- Spawn near the dock so fishing is immediate; the mountain/parkour sits across
-- the island as an area to discover.
local SPAWN_Z = ISLAND_RADIUS - 34

-- Parkour course tuning — a long spiral climb wrapping the mountain to the top.
local PARKOUR_REWARD = 250     -- Coins for reaching the summit...
local PARKOUR_COOLDOWN = 90    -- ...claimable at most once per this many seconds.
local PARKOUR_STEP_UP = 2.8    -- Height gained per ledge.
local PARKOUR_CHORD = 9        -- Horizontal jump distance between ledges.
local PARKOUR_LEDGE_OUT = 3    -- How far ledges jut from the rock slope.

-- The mountain the parkour climbs (sculpted from Terrain rock so it meshes with
-- the world). Positioned on the island's -X side, clear of the dock (+Z).
local MOUNTAIN_X = -70
local MOUNTAIN_Z = 0
local MOUNTAIN_HEIGHT = 130
local MOUNTAIN_BASE_R = 55
local MOUNTAIN_TOP_R = 9

-- A small, fixed palette so the scene reads cleanly.
local COLORS = {
	Grass = Color3.fromRGB(91, 154, 76),
	Sand = Color3.fromRGB(224, 207, 150),
	Wood = Color3.fromRGB(122, 84, 52),
	WoodDark = Color3.fromRGB(92, 62, 38),
	Rock = Color3.fromRGB(120, 124, 128),
	LedgeRock = Color3.fromRGB(96, 100, 104),
	Cliff = Color3.fromRGB(112, 106, 96),
	Path = Color3.fromRGB(156, 130, 96),
	Trunk = Color3.fromRGB(104, 72, 44),
	Leaves = Color3.fromRGB(64, 138, 70),
	Reward = Color3.fromRGB(240, 200, 90),
}

-- Radius of the mountain cone at a given height (used by both the terrain
-- sculptor and the ledge placement so the ledges hug the slope).
local function coneRadius(h: number): number
	return MOUNTAIN_BASE_R + (MOUNTAIN_TOP_R - MOUNTAIN_BASE_R) * (h / MOUNTAIN_HEIGHT)
end


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
	-- Grass disc. A Roblox Cylinder's round axis is its local X, so Size.X is the
	-- DISC THICKNESS and Size.Y/Z are the diameter; rotating 90° about Z stands
	-- that thickness up vertically to lie the disc flat. (Getting this order
	-- wrong builds a tall pillar instead of an island.)
	local island = makePart({
		Name = "Island",
		Size = Vector3.new(8, ISLAND_RADIUS * 2, ISLAND_RADIUS * 2),
		CFrame = CFrame.new(0, -4, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Color = COLORS.Grass,
		Material = Enum.Material.Grass,
		Shape = Enum.PartType.Cylinder,
		Parent = parent,
	})
	island.Name = "Island"

	-- Sand beach ring, just above the waterline so the shoreline reads cleanly
	-- (grass top y=0  >  sand top y=-0.5  >  water surface y=-2).
	makePart({
		Name = "Beach",
		Size = Vector3.new(6, (ISLAND_RADIUS + BEACH_WIDTH) * 2, (ISLAND_RADIUS + BEACH_WIDTH) * 2),
		CFrame = CFrame.new(0, -3.5, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Color = COLORS.Sand,
		Material = Enum.Material.Sand,
		Shape = Enum.PartType.Cylinder,
		Parent = parent,
	})
end

-- The water surface sits a couple of studs BELOW the grass top so the lake and
-- the island never Z-fight / bleed into each other at the shoreline.
local WATER_SURFACE = -2

local function buildWater()
	-- Carve a real Terrain water lake. We first clear a generous block of any
	-- existing terrain around the island, then fill a shallower block with
	-- water. FillBlock uses a CFrame centre + size.
	local terrain = Workspace.Terrain

	local clearCenter = CFrame.new(0, -WATER_DEPTH / 2, 0)
	local clearSize = Vector3.new(WATER_RADIUS * 2, WATER_DEPTH + 8, WATER_RADIUS * 2)
	terrain:FillBlock(clearCenter, clearSize, Enum.Material.Air)

	-- Fill water up to WATER_SURFACE (below the island/beach so they don't merge).
	local fillTop = WATER_SURFACE
	local fillCenter = CFrame.new(0, fillTop - WATER_DEPTH / 2, 0)
	local fillSize = Vector3.new(WATER_RADIUS * 2, WATER_DEPTH, WATER_RADIUS * 2)
	terrain:FillBlock(fillCenter, fillSize, Enum.Material.Water)
end

-- Sculpts the mountain from Terrain rock by stacking balls of decreasing radius
-- up a vertical axis, so it blends naturally into the world.
local function buildMountain()
	local terrain = Workspace.Terrain
	local steps = 38
	for i = 0, steps do
		local h = (i / steps) * MOUNTAIN_HEIGHT
		terrain:FillBall(Vector3.new(MOUNTAIN_X, h, MOUNTAIN_Z), coneRadius(h), Enum.Material.Rock)
	end
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
	spawn.CFrame = CFrame.new(0, 0.5, SPAWN_Z)
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
	local treeCount = 18
	for i = 1, treeCount do
		local angle = (i / treeCount) * math.pi * 2
		-- Skip the wedge facing the dock so it stays clear.
		if math.abs(angle - math.pi / 2) < 0.5 then
			continue
		end
		local radius = ISLAND_RADIUS * 0.72 + rng:NextNumber(-12, 12)
		local x = math.cos(angle) * radius
		local z = math.sin(angle) * radius
		-- Skip any tree that would land inside the mountain footprint.
		local dx, dz = x - MOUNTAIN_X, z - MOUNTAIN_Z
		if (dx * dx + dz * dz) < (MOUNTAIN_BASE_R + 12) ^ 2 then
			continue
		end
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

-- A vertical rock cylinder (the cliff body) capped with grass — a "mesa" you can
-- climb. Returns the world-space top centre so callers can place things on it.
local function buildMesaBody(parent: Instance, x: number, z: number, radius: number, height: number): Vector3
	-- Rock body: a Cylinder's round axis is local X, so rotating 90° about Z
	-- stands it up vertically. Size.X is the height; Size.Y/Z the diameter.
	makePart({
		Name = "Cliff",
		Size = Vector3.new(height, radius * 2, radius * 2),
		CFrame = CFrame.new(x, height / 2, z) * CFrame.Angles(0, 0, math.rad(90)),
		Color = COLORS.Cliff,
		Material = Enum.Material.Rock,
		Shape = Enum.PartType.Cylinder,
		Parent = parent,
	})
	-- Grass cap on top.
	makePart({
		Name = "Top",
		Size = Vector3.new(3, radius * 2, radius * 2),
		CFrame = CFrame.new(x, height, z) * CFrame.Angles(0, 0, math.rad(90)),
		Color = COLORS.Grass,
		Material = Enum.Material.Grass,
		Shape = Enum.PartType.Cylinder,
		Parent = parent,
	})
	return Vector3.new(x, height + 1.5, z)
end

-- A sloped walk-path ramp from a ground point up to a high point.
local function buildRamp(parent: Instance, fromPos: Vector3, toPos: Vector3, width: number)
	local length = (toPos - fromPos).Magnitude
	local mid = (fromPos + toPos) / 2
	makePart({
		Name = "Path",
		Size = Vector3.new(width, 1, length),
		CFrame = CFrame.lookAt(mid, toPos),
		Color = COLORS.Path,
		Material = Enum.Material.Ground,
		Parent = parent,
	})
	-- Low rock kerbs along both edges so the path reads as carved into the cliff.
	for _, side in ipairs({ -1, 1 }) do
		local kerb = makePart({
			Name = "Kerb",
			Size = Vector3.new(0.6, 1.6, length),
			CFrame = CFrame.lookAt(mid, toPos) * CFrame.new(side * (width / 2), 0.6, 0),
			Color = COLORS.Cliff,
			Material = Enum.Material.Rock,
			Parent = parent,
		})
		kerb.Name = "Kerb"
	end
end

-- The mesas (raised "areas") and shoreline cliff outcrops. The flat island stays
-- the walkable ground; these add the cliffs + ramp walk-paths up to each area.
local MESAS = {
	{ x = 72, z = -52, r = 34, h = 24 },
	{ x = 8, z = -132, r = 42, h = 32 },
	{ x = -122, z = 78, r = 30, h = 20 },
	{ x = 120, z = 74, r = 28, h = 18 },
}

local function buildCliffs(parent: Instance)
	local model = Instance.new("Model")
	model.Name = "Cliffs"
	model.Parent = parent

	for _, m in ipairs(MESAS) do
		local top = buildMesaBody(model, m.x, m.z, m.r, m.h)

		-- A tree on top so each mesa reads as its own little area to discover.
		buildTree(model, Vector3.new(m.x, m.h + 1.5, m.z))

		-- Ramp up the side that faces the island centre (toward where players walk
		-- from spawn). Runs from the ground up onto the grass cap.
		local center = Vector3.new(m.x, 0, m.z)
		local toward = if center.Magnitude > 0.1 then -center.Unit else Vector3.new(0, 0, 1)
		local run = m.h * 1.7
		local fromPos = center + toward * (m.r + run) + Vector3.new(0, 0.5, 0)
		local toPos = Vector3.new(top.X, m.h, top.Z) + toward * (m.r - 3)
		buildRamp(model, fromPos, toPos, 10)
	end

	-- Shoreline cliff outcrops around the coast (skipping the dock/beach side) so
	-- there are cliffsides all around the island.
	local rng = Random.new(778899)
	for i = 1, 8 do
		local angle = (i / 8) * math.pi * 2
		if math.abs(angle - math.pi / 2) < 0.7 then
			continue -- keep the beach/dock side open
		end
		local radius = ISLAND_RADIUS * 0.86
		local x = math.cos(angle) * radius
		local z = math.sin(angle) * radius
		local r = rng:NextNumber(9, 16)
		local h = rng:NextNumber(14, 30)
		makePart({
			Name = "Outcrop",
			Size = Vector3.new(h, r * 2, r * 2),
			CFrame = CFrame.new(x, h / 2 - 2, z)
				* CFrame.Angles(0, 0, math.rad(90))
				* CFrame.Angles(rng:NextNumber(-0.08, 0.08), 0, rng:NextNumber(-0.08, 0.08)),
			Color = COLORS.Cliff,
			Material = Enum.Material.Rock,
			Shape = Enum.PartType.Cylinder,
			Parent = model,
		})
	end
end

-- Builds the parkour as a long spiral of rocky ledges wrapping the mountain all
-- the way to a glowing coin reward on the summit. The reward grants coins
-- (server-authoritative) with a per-player cooldown so it can't be farmed.
--
-- The spiral keeps each jump reachable: at a given height the cone has radius r,
-- so to step ~PARKOUR_CHORD studs around the circle we advance the angle by
-- 2*asin(chord / 2r). As the cone narrows toward the top, that angle grows, so
-- the path naturally winds tighter near the summit.
local function buildParkour(parent: Instance)
	local model = Instance.new("Model")
	model.Name = "Parkour"
	model.Parent = parent

	local startH = 4
	local topH = MOUNTAIN_HEIGHT - 8
	local h = startH
	local angle = 0
	local index = 0
	local lastPos = Vector3.new(MOUNTAIN_X + coneRadius(startH) + PARKOUR_LEDGE_OUT, startH, MOUNTAIN_Z)

	-- A small signpost at the base so players discover the climb.
	makePart({
		Name = "ClimbSign",
		Size = Vector3.new(1, 7, 1),
		CFrame = CFrame.new(lastPos + Vector3.new(3, 3, 0)),
		Color = COLORS.WoodDark,
		Material = Enum.Material.Wood,
		Parent = model,
	})

	while h <= topH and index < 200 do
		index += 1
		local r = coneRadius(h) + PARKOUR_LEDGE_OUT
		local pos = Vector3.new(MOUNTAIN_X + math.cos(angle) * r, h, MOUNTAIN_Z + math.sin(angle) * r)

		-- Pads shrink with height for tighter landings near the top.
		local frac = (h - startH) / (topH - startH)
		local dim = math.max(3, 5 - math.floor(frac * 2 + 0.5))

		makePart({
			Name = "Ledge" .. index,
			Size = Vector3.new(dim, 1, dim + 1),
			CFrame = CFrame.new(pos),
			Color = COLORS.LedgeRock,
			Material = Enum.Material.Slate,
			Parent = model,
		})
		lastPos = pos

		-- Advance: around the circle by a reachable chord, and up one step.
		local ratio = math.clamp(PARKOUR_CHORD / (2 * r), 0, 1)
		angle += 2 * math.asin(ratio)
		h += PARKOUR_STEP_UP
	end

	-- Summit: continue the spiral one more (reachable) step into a big landing
	-- pad that caps the climb, with the reward beacon above it.
	local sr = coneRadius(topH) + PARKOUR_LEDGE_OUT
	local summitPos = Vector3.new(MOUNTAIN_X + math.cos(angle) * sr, topH + 3, MOUNTAIN_Z + math.sin(angle) * sr)
	makePart({
		Name = "Summit",
		Size = Vector3.new(10, 1, 10),
		CFrame = CFrame.new(summitPos),
		Color = COLORS.Reward,
		Material = Enum.Material.WoodPlanks,
		Parent = model,
	})

	-- Glowing reward beacon above the summit ledge (walk into it to claim).
	local reward = makePart({
		Name = "ParkourReward",
		Size = Vector3.new(4, 4, 4),
		CFrame = CFrame.new(summitPos + Vector3.new(0, 4, 0)),
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

-- Builds a row of teleport portals near spawn. Each portal sends the player to
-- one of the games configured in TeleportConfig (fill in the PlaceIds). Portals
-- with PlaceId == 0 are shown as "Coming soon" and do nothing.
local function buildHub(parent: Instance)
	local model = Instance.new("Model")
	model.Name = "Hub"
	model.Parent = parent

	local destinations = TeleportConfig.Destinations
	local count = #destinations
	if count == 0 then
		return
	end

	local spacing = 18
	local startX = -((count - 1) * spacing) / 2
	local hubZ = SPAWN_Z - 22 -- just behind the spawn pad

	local teleporting: { [Player]: boolean } = {}

	for i, dest in ipairs(destinations) do
		local x = startX + (i - 1) * spacing
		local base = Vector3.new(x, 0, hubZ)

		-- Two pillars + a top bar form the frame.
		for _, side in ipairs({ -1, 1 }) do
			makePart({
				Name = "Pillar",
				Size = Vector3.new(1.2, 12, 1.2),
				CFrame = CFrame.new(base + Vector3.new(side * 4, 6, 0)),
				Color = COLORS.WoodDark,
				Material = Enum.Material.Wood,
				Parent = model,
			})
		end
		makePart({
			Name = "Lintel",
			Size = Vector3.new(10, 1.2, 1.2),
			CFrame = CFrame.new(base + Vector3.new(0, 12.5, 0)),
			Color = COLORS.WoodDark,
			Material = Enum.Material.Wood,
			Parent = model,
		})

		-- The glowing portal surface is the touch trigger.
		local surface = makePart({
			Name = "Portal_" .. dest.Name,
			Size = Vector3.new(7.6, 11, 0.6),
			CFrame = CFrame.new(base + Vector3.new(0, 6, 0)),
			Color = dest.Color,
			Material = Enum.Material.Neon,
			Transparency = 0.4,
			CanCollide = false,
			Parent = model,
		})

		local light = Instance.new("PointLight")
		light.Color = dest.Color
		light.Range = 16
		light.Brightness = 2
		light.Parent = surface

		-- Label above the portal.
		local billboard = Instance.new("BillboardGui")
		billboard.Size = UDim2.fromOffset(220, 50)
		billboard.StudsOffset = Vector3.new(0, 8, 0)
		billboard.AlwaysOnTop = true
		billboard.Parent = surface
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextScaled = true
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextStrokeTransparency = 0.3
		label.Text = if dest.PlaceId == 0 then dest.Name .. "\n(Coming soon)" else "▶ " .. dest.Name
		label.Parent = billboard

		surface.Touched:Connect(function(hit: BasePart)
			local character = hit.Parent
			if character == nil then
				return
			end
			local player = Players:GetPlayerFromCharacter(character)
			if player == nil or teleporting[player] then
				return
			end

			if dest.PlaceId == 0 then
				FishingNetwork:FireClient(player, "Notice", {
					text = dest.Name .. " isn't set up yet.",
				})
				return
			end

			teleporting[player] = true
			FishingNetwork:FireClient(player, "Notice", { text = "Teleporting to " .. dest.Name .. "..." })
			local ok, err = pcall(function()
				TeleportService:Teleport(dest.PlaceId, player)
			end)
			if not ok then
				teleporting[player] = false
				warn("[MapBuilder] Teleport failed:", err)
				FishingNetwork:FireClient(player, "Notice", { text = "Teleport failed (try in the live game)." })
			end
		end)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		teleporting[player] = nil
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
	buildCliffs(mapFolder)
	buildParkour(mapFolder)
	buildHub(mapFolder)

	mapFolder.Parent = Workspace

	-- Cosmetic, environment-dependent steps run guarded so a failure on any
	-- given Studio/runtime configuration can never abort map creation (and with
	-- it the rest of server startup). The island + spawn above always succeed.
	pcall(buildWater)    -- Fill the lake first...
	pcall(buildMountain) -- ...then punch the rock mountain up through it.
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
