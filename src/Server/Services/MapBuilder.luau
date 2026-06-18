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

-- Parkour course tuning — a long, hard spiral climb. Jumps are wide so it can't
-- be cheesed; players must discover and master it.
local PARKOUR_REWARD = 250     -- Coins for reaching the summit...
local PARKOUR_COOLDOWN = 90    -- ...claimable at most once per this many seconds.
local PARKOUR_STEP_UP = 3.4    -- Height gained per ledge.
local PARKOUR_CHORD = 11       -- Horizontal jump distance between ledges (harder).
local PARKOUR_LEDGE_OUT = 2.5  -- How far ledges jut from the rock slope.

-- The mountain dominates the island. Sculpted from Terrain rock, it is steep and
-- smooth (so it can't be free-climbed — see SprintController's MaxSlopeAngle),
-- with a walk-through tunnel + market cavern carved underneath.
local MOUNTAIN_X = 0
local MOUNTAIN_Z = 0
local MOUNTAIN_HEIGHT = 175
local MOUNTAIN_BASE_R = 115
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
	-- Many steps so the slope is smooth (few footholds) — climbing is blocked by
	-- the steep angle, not by relying on bumps.
	local steps = 90
	for i = 0, steps do
		local h = (i / steps) * MOUNTAIN_HEIGHT
		terrain:FillBall(Vector3.new(MOUNTAIN_X, h, MOUNTAIN_Z), coneRadius(h), Enum.Material.Rock)
	end
end

-- Cavern / tunnel constants (shared by the carve + the chest placement).
local CAVERN_HEIGHT = 22 -- head-room of the carved space
local CAVERN_HALF = 38   -- half-width of the central cavern room

-- Carves a walk-through tunnel along Z through the base of the mountain, opening
-- into a central cavern (where the chests live). MUST run AFTER buildMountain so
-- it removes the rock that was just placed.
local function buildTunnel()
	local terrain = Workspace.Terrain
	-- Main corridor, south <-> north, at ground level.
	terrain:FillBlock(
		CFrame.new(MOUNTAIN_X, CAVERN_HEIGHT / 2, MOUNTAIN_Z),
		Vector3.new(24, CAVERN_HEIGHT, (MOUNTAIN_BASE_R + 40) * 2),
		Enum.Material.Air
	)
	-- A west <-> east corridor too, so the tunnel is a crossroads.
	terrain:FillBlock(
		CFrame.new(MOUNTAIN_X, CAVERN_HEIGHT / 2, MOUNTAIN_Z),
		Vector3.new((MOUNTAIN_BASE_R + 40) * 2, CAVERN_HEIGHT, 24),
		Enum.Material.Air
	)
	-- The central cavern room.
	terrain:FillBlock(
		CFrame.new(MOUNTAIN_X, CAVERN_HEIGHT / 2 + 1, MOUNTAIN_Z),
		Vector3.new(CAVERN_HALF * 2, CAVERN_HEIGHT + 2, CAVERN_HALF * 2),
		Enum.Material.Air
	)
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
		local radius = ISLAND_RADIUS * 0.88 + rng:NextNumber(-10, 10)
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

-- A small fishing dock jutting from the island edge into the water at `angle`.
local function buildMiniDock(parent: Instance, angle: number)
	local dirX, dirZ = math.cos(angle), math.sin(angle)
	local innerR = ISLAND_RADIUS - 12
	local length = 38
	local midR = innerR + length / 2
	local center = Vector3.new(dirX * midR, 0.6, dirZ * midR)
	local outward = Vector3.new(dirX * (midR + 10), 0.6, dirZ * (midR + 10))

	makePart({
		Name = "MiniDeck",
		Size = Vector3.new(7, 1, length),
		CFrame = CFrame.lookAt(center, outward),
		Color = COLORS.Wood,
		Material = Enum.Material.WoodPlanks,
		Parent = parent,
	})

	-- Posts at the far (water) end.
	local perp = Vector3.new(-dirZ, 0, dirX)
	local farEnd = Vector3.new(dirX * (innerR + length), 0, dirZ * (innerR + length))
	for _, side in ipairs({ -1, 1 }) do
		makePart({
			Name = "Post",
			Size = Vector3.new(1, 12, 1),
			CFrame = CFrame.new(farEnd + perp * (side * 2.6) + Vector3.new(0, -3, 0)),
			Color = COLORS.WoodDark,
			Material = Enum.Material.Wood,
			Parent = parent,
		})
	end
end

local function buildMiniDocks(parent: Instance)
	local model = Instance.new("Model")
	model.Name = "MiniDocks"
	model.Parent = parent
	-- Spread around the coast; the +Z (pi/2) wedge is left for the main dock.
	local angles = { 0, math.pi * 0.33, math.pi * 0.95, math.pi * 1.25, math.pi * 1.55, math.pi * 1.85 }
	for _, a in ipairs(angles) do
		buildMiniDock(model, a)
	end
end

-- The market under the mountain: merchant stands the player walks up to. Each
-- carries a ProximityPrompt that opens the matching shop UI (handled client-side
-- by MerchantController via the "OpenUI" attribute). The prompt itself only shows
-- when the player is close, so the cavern stays clean until you approach a stand.
local MERCHANTS = {
	{ x = -24, z = -18, ui = "Inventory", title = "Fish Market", action = "Sell Fish", color = Color3.fromRGB(88, 196, 120) },
	{ x = 24, z = -18, ui = "Shop", title = "Rod & Luck Smith", action = "Upgrade", color = Color3.fromRGB(64, 156, 255) },
	{ x = -24, z = 18, ui = "Crates", title = "Crate Trader", action = "Open Crates", color = Color3.fromRGB(220, 110, 110) },
	{ x = 24, z = 18, ui = "Store", title = "Premium Bazaar", action = "Browse", color = Color3.fromRGB(232, 196, 96) },
}

local function buildMerchantStand(parent: Instance, m: { x: number, z: number, ui: string, title: string, action: string, color: Color3 })
	-- Face the stand toward the cavern centre.
	local toCenter = Vector3.new(-m.x, 0, -m.z)
	local facing = if toCenter.Magnitude > 0.1 then toCenter.Unit else Vector3.new(0, 0, 1)
	local base = CFrame.lookAt(Vector3.new(m.x, 0, m.z), Vector3.new(m.x, 0, m.z) + facing)

	-- Counter.
	local counter = makePart({
		Name = "Counter",
		Size = Vector3.new(8, 3.5, 2),
		CFrame = base * CFrame.new(0, 1.75, 0),
		Color = COLORS.Wood,
		Material = Enum.Material.WoodPlanks,
		Parent = parent,
	})
	-- Posts + a colored awning so each stand reads at a glance.
	for _, side in ipairs({ -1, 1 }) do
		makePart({
			Name = "Post",
			Size = Vector3.new(0.6, 8, 0.6),
			CFrame = base * CFrame.new(side * 3.7, 4, -0.5),
			Color = COLORS.WoodDark,
			Material = Enum.Material.Wood,
			Parent = parent,
		})
	end
	makePart({
		Name = "Awning",
		Size = Vector3.new(9, 0.6, 4),
		CFrame = base * CFrame.new(0, 8, -1.2) * CFrame.Angles(math.rad(-14), 0, 0),
		Color = m.color,
		Material = Enum.Material.SmoothPlastic,
		Parent = parent,
	})
	-- A glowing sign block in the awning colour, lighting the stall.
	local sign = makePart({
		Name = "Sign",
		Size = Vector3.new(7, 1.4, 0.4),
		CFrame = base * CFrame.new(0, 6, -0.4),
		Color = m.color,
		Material = Enum.Material.Neon,
		CanCollide = false,
		Parent = parent,
	})
	local light = Instance.new("PointLight")
	light.Color = m.color
	light.Range = 18
	light.Brightness = 2
	light.Parent = sign

	-- The interaction. Only visible when the player is near; opens the UI.
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = m.action
	prompt.ObjectText = m.title
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute("OpenUI", m.ui)
	prompt.Parent = counter
end

-- Lays the cave floor + lighting under the mountain and places the merchant stands.
local function buildUnderMountain(parent: Instance)
	local model = Instance.new("Model")
	model.Name = "UnderMountain"
	model.Parent = parent

	local corridorLen = (MOUNTAIN_BASE_R + 40) * 2

	-- Slate floors for the cavern + both corridors.
	makePart({
		Name = "CavernFloor",
		Size = Vector3.new(CAVERN_HALF * 2, 1, CAVERN_HALF * 2),
		CFrame = CFrame.new(MOUNTAIN_X, 0.3, MOUNTAIN_Z),
		Color = COLORS.Cliff,
		Material = Enum.Material.Slate,
		Parent = model,
	})
	makePart({
		Name = "CorridorFloorNS",
		Size = Vector3.new(24, 1, corridorLen),
		CFrame = CFrame.new(MOUNTAIN_X, 0.3, MOUNTAIN_Z),
		Color = COLORS.Cliff,
		Material = Enum.Material.Slate,
		Parent = model,
	})
	makePart({
		Name = "CorridorFloorEW",
		Size = Vector3.new(corridorLen, 1, 24),
		CFrame = CFrame.new(MOUNTAIN_X, 0.3, MOUNTAIN_Z),
		Color = COLORS.Cliff,
		Material = Enum.Material.Slate,
		Parent = model,
	})

	-- Glowing lamps near the ceiling so the corridors aren't pitch black.
	for d = -MOUNTAIN_BASE_R + 12, MOUNTAIN_BASE_R - 12, 34 do
		for _, pos in ipairs({
			Vector3.new(MOUNTAIN_X, CAVERN_HEIGHT - 3, MOUNTAIN_Z + d),
			Vector3.new(MOUNTAIN_X + d, CAVERN_HEIGHT - 3, MOUNTAIN_Z),
		}) do
			local lamp = makePart({
				Name = "Lamp",
				Size = Vector3.new(1.2, 1.2, 1.2),
				CFrame = CFrame.new(pos),
				Color = Color3.fromRGB(255, 235, 200),
				Material = Enum.Material.Neon,
				CanCollide = false,
				Parent = model,
			})
			local lampLight = Instance.new("PointLight")
			lampLight.Range = 30
			lampLight.Brightness = 1.6
			lampLight.Color = Color3.fromRGB(255, 235, 200)
			lampLight.Parent = lamp
		end
	end

	for _, m in ipairs(MERCHANTS) do
		buildMerchantStand(model, m)
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

	-- No signpost: the climb is meant to be discovered, not advertised.
	while h <= topH and index < 240 do
		index += 1
		local r = coneRadius(h) + PARKOUR_LEDGE_OUT
		local pos = Vector3.new(MOUNTAIN_X + math.cos(angle) * r, h, MOUNTAIN_Z + math.sin(angle) * r)

		-- Smaller pads (harder, tighter landings), shrinking further with height.
		local frac = (h - startH) / (topH - startH)
		local dim = math.max(2.5, 4 - math.floor(frac * 2 + 0.5))

		makePart({
			Name = "Ledge" .. index,
			Size = Vector3.new(dim, 1, dim + 1),
			CFrame = CFrame.new(pos),
			Color = COLORS.LedgeRock,
			Material = Enum.Material.Slate,
			Parent = model,
		})

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

	-- Floating call-out — only visible once you're near the summit (discovery).
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(180, 44)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 35
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
	-- On the beach beside spawn (west), clear of the mountain footprint.
	local startX = -72 - ((count - 1) * spacing) / 2
	local hubZ = SPAWN_Z + 12

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

		-- Walk-up prompt (only shows when the player is close); press E to travel.
		local prompt = Instance.new("ProximityPrompt")
		prompt.ObjectText = dest.Name
		prompt.ActionText = if dest.PlaceId == 0 then "Coming soon" else "Travel"
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.HoldDuration = 0.4
		prompt.MaxActivationDistance = 9
		prompt.RequiresLineOfSight = false
		prompt.Enabled = dest.PlaceId ~= 0
		prompt.Parent = surface

		prompt.Triggered:Connect(function(player: Player)
			if dest.PlaceId == 0 or teleporting[player] then
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
	buildMiniDocks(mapFolder)
	buildUnderMountain(mapFolder) -- cave floor, lamps + chests
	buildParkour(mapFolder)
	buildHub(mapFolder)

	mapFolder.Parent = Workspace

	-- Cosmetic, environment-dependent steps run guarded so a failure on any
	-- given Studio/runtime configuration can never abort map creation (and with
	-- it the rest of server startup). The island + spawn above always succeed.
	pcall(buildWater)    -- Fill the lake first...
	pcall(buildMountain) -- ...then punch the huge rock mountain up through it...
	pcall(buildTunnel)   -- ...then carve the walk-through tunnel + cavern.
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
