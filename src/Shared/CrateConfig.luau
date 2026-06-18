--!strict
--[[
	CrateConfig
	-----------
	Shared module (ReplicatedStorage.Shared.CrateConfig).

	Defines the gacha system: collectible **Pets** (equippable, grant passive
	luck/coin bonuses) and the **Crates** that drop them via weighted rolls.
	Required by the server (authoritative rolls + grants) and the client (store
	UI + reveal animation reel).

	Reward descriptors in a crate pool can be a Pet, a Coins bundle, Keys, or a
	timed Luck Potion. Weights are relative and normalised at roll time.
]]

local CrateConfig = {}

-- ---------------------------------------------------------------------------
-- Pets
-- ---------------------------------------------------------------------------

export type Pet = {
	Id: string,
	Name: string,
	Rarity: string,
	LuckBonus: number, -- Added to the luck multiplier while equipped.
	CoinBonus: number, -- Added to the coin multiplier while equipped.
	Color: Color3,
}

CrateConfig.Pets = {
	Minnow = { Id = "Minnow", Name = "Minnow", Rarity = "Common", LuckBonus = 0.03, CoinBonus = 0.0, Color = Color3.fromRGB(170, 178, 184) },
	Tadpole = { Id = "Tadpole", Name = "Tadpole", Rarity = "Common", LuckBonus = 0.0, CoinBonus = 0.03, Color = Color3.fromRGB(150, 168, 150) },
	Crab = { Id = "Crab", Name = "Crab", Rarity = "Uncommon", LuckBonus = 0.08, CoinBonus = 0.0, Color = Color3.fromRGB(88, 196, 120) },
	Frog = { Id = "Frog", Name = "Frog", Rarity = "Uncommon", LuckBonus = 0.0, CoinBonus = 0.08, Color = Color3.fromRGB(96, 200, 110) },
	Pufferfish = { Id = "Pufferfish", Name = "Pufferfish", Rarity = "Rare", LuckBonus = 0.15, CoinBonus = 0.05, Color = Color3.fromRGB(64, 156, 255) },
	Octopus = { Id = "Octopus", Name = "Octopus", Rarity = "Epic", LuckBonus = 0.25, CoinBonus = 0.15, Color = Color3.fromRGB(170, 96, 255) },
	Shark = { Id = "Shark", Name = "Shark", Rarity = "Legendary", LuckBonus = 0.5, CoinBonus = 0.3, Color = Color3.fromRGB(240, 180, 70) },
	Leviathan = { Id = "Leviathan", Name = "Leviathan", Rarity = "Mythic", LuckBonus = 1.0, CoinBonus = 0.6, Color = Color3.fromRGB(255, 90, 140) },
} :: { [string]: Pet }

function CrateConfig.GetPet(id: string): Pet?
	return CrateConfig.Pets[id]
end

-- ---------------------------------------------------------------------------
-- Crates
-- ---------------------------------------------------------------------------

-- A single possible reward in a crate's pool.
export type Reward = {
	Type: string,       -- "Pet" | "Coins" | "Keys" | "LuckPotion"
	Weight: number,
	Ref: string?,       -- Pet id, for Type == "Pet".
	Amount: number?,    -- For "Coins" / "Keys".
	Multiplier: number?, -- For "LuckPotion".
	Duration: number?,  -- For "LuckPotion".
}

export type Crate = {
	Key: string,
	Name: string,
	Order: number,
	CostType: string,   -- "Coins" | "Keys"
	Cost: number,
	Accent: Color3,
	Pool: { Reward },
}

CrateConfig.Crates = {
	WoodenCrate = {
		Key = "WoodenCrate",
		Name = "Wooden Crate",
		Order = 1,
		CostType = "Coins",
		Cost = 500,
		Accent = Color3.fromRGB(150, 110, 70),
		Pool = {
			{ Type = "Pet", Ref = "Minnow", Weight = 35 },
			{ Type = "Pet", Ref = "Tadpole", Weight = 35 },
			{ Type = "Pet", Ref = "Crab", Weight = 12 },
			{ Type = "Pet", Ref = "Frog", Weight = 12 },
			{ Type = "Coins", Amount = 250, Weight = 4 },
			{ Type = "Pet", Ref = "Pufferfish", Weight = 2 },
		},
	},
	GoldenCrate = {
		Key = "GoldenCrate",
		Name = "Golden Crate",
		Order = 2,
		CostType = "Coins",
		Cost = 5000,
		Accent = Color3.fromRGB(240, 200, 90),
		Pool = {
			{ Type = "Pet", Ref = "Crab", Weight = 28 },
			{ Type = "Pet", Ref = "Frog", Weight = 28 },
			{ Type = "Pet", Ref = "Pufferfish", Weight = 20 },
			{ Type = "Pet", Ref = "Octopus", Weight = 10 },
			{ Type = "LuckPotion", Multiplier = 2, Duration = 300, Weight = 8 },
			{ Type = "Coins", Amount = 2500, Weight = 5 },
			{ Type = "Pet", Ref = "Shark", Weight = 1 },
		},
	},
	MythicCrate = {
		Key = "MythicCrate",
		Name = "Mythic Crate",
		Order = 3,
		CostType = "Keys",
		Cost = 1,
		Accent = Color3.fromRGB(255, 90, 140),
		Pool = {
			{ Type = "Pet", Ref = "Pufferfish", Weight = 30 },
			{ Type = "Pet", Ref = "Octopus", Weight = 30 },
			{ Type = "Pet", Ref = "Shark", Weight = 18 },
			{ Type = "LuckPotion", Multiplier = 3, Duration = 600, Weight = 10 },
			{ Type = "Coins", Amount = 25000, Weight = 8 },
			{ Type = "Pet", Ref = "Leviathan", Weight = 4 },
		},
	},
} :: { [string]: Crate }

function CrateConfig.GetCrate(key: string): Crate?
	return CrateConfig.Crates[key]
end

function CrateConfig.GetSortedCrates(): { Crate }
	local list: { Crate } = {}
	for _, crate in pairs(CrateConfig.Crates) do
		table.insert(list, crate)
	end
	table.sort(list, function(a, b)
		return a.Order < b.Order
	end)
	return list
end

--[[
	RollCrate
	Weighted-random selection from a crate's pool. Normalises weights at runtime,
	draws one math.random() sample, and walks the cumulative distribution.
	Returns the chosen Reward, or nil for an unknown crate key.
]]
function CrateConfig.RollCrate(crateKey: string): Reward?
	local crate = CrateConfig.Crates[crateKey]
	if crate == nil then
		return nil
	end

	local total = 0
	for _, reward in ipairs(crate.Pool) do
		total += reward.Weight
	end

	local roll = math.random() * total
	local cumulative = 0
	for _, reward in ipairs(crate.Pool) do
		cumulative += reward.Weight
		if roll < cumulative then
			return reward
		end
	end
	return crate.Pool[#crate.Pool]
end

return CrateConfig
