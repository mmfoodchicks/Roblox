--!strict
--[[
	GameConfig
	----------
	Shared module (ReplicatedStorage.Shared.GameConfig).

	Single source of truth for tunable progression data — rods and the luck
	upgrade curve. Required by both the server (authoritative pricing / stats)
	and the client (shop UI), so the two can never disagree.
]]

local GameConfig = {}

-- ---------------------------------------------------------------------------
-- Rods
-- ---------------------------------------------------------------------------

export type RodConfig = {
	Id: string,
	Name: string,
	Price: number,           -- Coin cost to unlock (0 = owned from the start).
	BiteTime: number,        -- Seconds from cast to bite (lower = faster).
	LuckMultiplier: number,  -- Multiplies the player's luck on the roll.
	ValueMultiplier: number, -- Multiplies caught item BaseValue.
	Order: number,           -- Display / progression order.
	Color: Color3,           -- UI accent.
}

GameConfig.DefaultRod = "BasicRod"

GameConfig.Rods = {
	BasicRod = {
		Id = "BasicRod",
		Name = "Basic Rod",
		Price = 0,
		BiteTime = 2.0,
		LuckMultiplier = 1.0,
		ValueMultiplier = 1.0,
		Order = 1,
		Color = Color3.fromRGB(150, 150, 150),
	},
	SilverRod = {
		Id = "SilverRod",
		Name = "Silver Rod",
		Price = 750,
		BiteTime = 1.5,
		LuckMultiplier = 1.25,
		ValueMultiplier = 1.5,
		Order = 2,
		Color = Color3.fromRGB(190, 198, 206),
	},
	GoldRod = {
		Id = "GoldRod",
		Name = "Gold Rod",
		Price = 4000,
		BiteTime = 1.1,
		LuckMultiplier = 1.6,
		ValueMultiplier = 2.25,
		Order = 3,
		Color = Color3.fromRGB(240, 200, 90),
	},
	DiamondRod = {
		Id = "DiamondRod",
		Name = "Diamond Rod",
		Price = 18000,
		BiteTime = 0.8,
		LuckMultiplier = 2.1,
		ValueMultiplier = 3.5,
		Order = 4,
		Color = Color3.fromRGB(120, 220, 240),
	},
} :: { [string]: RodConfig }

--[[
	GetRod
	Returns the config for a rod id, falling back to the default rod for an
	unknown id so callers never get nil.
]]
function GameConfig.GetRod(rodId: string): RodConfig
	return GameConfig.Rods[rodId] or GameConfig.Rods[GameConfig.DefaultRod]
end

--[[
	GetSortedRods
	Returns rods as an array sorted by their Order field (stable display order).
]]
function GameConfig.GetSortedRods(): { RodConfig }
	local list: { RodConfig } = {}
	for _, rod in pairs(GameConfig.Rods) do
		table.insert(list, rod)
	end
	table.sort(list, function(a, b)
		return a.Order < b.Order
	end)
	return list
end

-- ---------------------------------------------------------------------------
-- Luck upgrade curve
-- ---------------------------------------------------------------------------

GameConfig.Luck = {
	MaxLevel = 25,
	BasePrice = 150,    -- Cost of the first upgrade (level 1 -> 2).
	PriceGrowth = 1.55, -- Geometric price growth per level.
	PerLevel = 0.08,    -- Added luck multiplier per level above 1.
}

--[[
	GetLuckMultiplier
	Converts a stored LuckLevel into the multiplier passed to LootManager.
	Level 1 returns exactly 1.0 (base odds).
]]
function GameConfig.GetLuckMultiplier(level: number): number
	local clamped = math.clamp(level, 1, GameConfig.Luck.MaxLevel)
	return 1 + (clamped - 1) * GameConfig.Luck.PerLevel
end

--[[
	GetLuckUpgradeCost
	Coin cost to advance FROM `level` to `level + 1`. Returns nil when the level
	is already at (or above) the cap.
]]
function GameConfig.GetLuckUpgradeCost(level: number): number?
	if level >= GameConfig.Luck.MaxLevel then
		return nil
	end
	local cost = GameConfig.Luck.BasePrice * (GameConfig.Luck.PriceGrowth ^ (level - 1))
	return math.floor(cost + 0.5)
end

return GameConfig
