--!strict
--[[
	LootManager
	-----------
	Shared module (ReplicatedStorage.Shared.LootManager).

	Owns the catchable-item catalogue, the rarity definitions, and the
	weighted-random selection algorithm used by the server to resolve a catch.

	The selection is intentionally pure and deterministic-given-rng so it can be
	unit tested and re-used identically on client (for previews) and server (for
	the authoritative roll). Only the server result is ever trusted.
]]

local LootManager = {}

-- Stable identifiers for each rarity tier. Kept as string constants so they
-- serialise cleanly across the RemoteEvent and into the player's inventory.
export type Rarity = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic"

-- One shared colour per rarity tier (matches the client UiUtil.Rarity palette).
local RARITY_COLOR: { [string]: Color3 } = {
	Common = Color3.fromRGB(170, 178, 184),
	Uncommon = Color3.fromRGB(88, 196, 120),
	Rare = Color3.fromRGB(64, 156, 255),
	Epic = Color3.fromRGB(170, 96, 255),
	Legendary = Color3.fromRGB(240, 180, 70),
	Mythic = Color3.fromRGB(255, 90, 140),
}

-- The canonical data structure for a single catchable item.
export type LootItem = {
	Id: string,        -- Unique, stable key (used for inventory + asset lookup)
	Name: string,      -- Display name
	Rarity: Rarity,    -- Tier bucket
	Weight: number,    -- Base selection weight (pre-luck)
	BaseValue: number, -- Coin value awarded on catch
	Color: Color3,     -- UI / particle tint for client feedback
}

-- A caught item enriched with the roll metadata the client needs to render.
export type CaughtLoot = {
	Item: LootItem,
	Value: number, -- Final coin value (may differ from BaseValue via multipliers)
}

--[[
	Master catalogue.

	Weights are RELATIVE, not percentages — the selector normalises them at
	runtime, so new entries can be appended without re-balancing the others.
	Multiple species share each rarity tier; the per-tier weights roughly sum to
	the old single-fish weights, so overall odds are unchanged while the variety
	is much richer. Each fish takes its tier's colour.
]]
local function fish(id: string, name: string, rarity: Rarity, weight: number, value: number): LootItem
	return {
		Id = id,
		Name = name,
		Rarity = rarity,
		Weight = weight,
		BaseValue = value,
		Color = RARITY_COLOR[rarity],
	}
end

LootManager.Catalogue = {
	-- Common (~70)
	fish("anchovy", "Anchovy", "Common", 18, 10),
	fish("sardine", "Sardine", "Common", 16, 12),
	fish("carp", "Carp", "Common", 14, 16),
	fish("bluegill", "Bluegill", "Common", 12, 14),
	fish("perch", "Perch", "Common", 10, 20),
	-- Uncommon (~20)
	fish("salmon", "Salmon", "Uncommon", 7, 40),
	fish("rainbow_trout", "Rainbow Trout", "Uncommon", 5, 48),
	fish("bass", "Largemouth Bass", "Uncommon", 5, 42),
	fish("catfish", "Catfish", "Uncommon", 3, 55),
	-- Rare (~8.5)
	fish("golden_trout", "Golden Trout", "Rare", 3, 120),
	fish("swordfish", "Swordfish", "Rare", 2.5, 150),
	fish("pufferfish", "Pufferfish", "Rare", 2, 110),
	fish("mahi_mahi", "Mahi-Mahi", "Rare", 1, 185),
	-- Epic (~3)
	fish("anglerfish", "Anglerfish", "Epic", 1.5, 300),
	fish("electric_eel", "Electric Eel", "Epic", 1, 360),
	fish("giant_squid", "Giant Squid", "Epic", 0.6, 480),
	-- Legendary (~1.5)
	fish("kraken_tentacle", "Kraken Tentacle", "Legendary", 0.7, 750),
	fish("megalodon_tooth", "Megalodon Tooth", "Legendary", 0.45, 1050),
	fish("leviathan_scale", "Leviathan Scale", "Legendary", 0.3, 1300),
	-- Mythic (~0.2) — the jackpot tier
	fish("ancient_coelacanth", "Ancient Coelacanth", "Mythic", 0.16, 3000),
	fish("golden_dragonfish", "Golden Dragon Fish", "Mythic", 0.05, 6000),
} :: { LootItem }

-- Fast Id -> LootItem lookup, built once at require time.
local catalogueById: { [string]: LootItem } = {}
for _, item in ipairs(LootManager.Catalogue) do
	catalogueById[item.Id] = item
end

--[[
	GetItemById
	Returns the catalogue entry for an id, or nil if unknown. Used by the server
	when re-hydrating / validating an inventory entry.
]]
function LootManager.GetItemById(id: string): LootItem?
	return catalogueById[id]
end

--[[
	SelectLoot
	Weighted-random selection.

	  modifiedWeight = baseWeight * luck

	`luck` is a multiplier (>= 1) derived from the player's LuckLevel. Because
	luck scales every weight by the same factor, raw luck alone does not change
	the relative odds — so we additionally bias luck toward the rarer tiers via
	a gentle rarity exponent, which is the behaviour players expect from a
	"luck" stat in an incremental game. With luck = 1 the distribution is exactly
	the base weights.

	The function:
	  1. Computes each item's modified weight and the running total.
	  2. Draws a single uniform sample in [0, total).
	  3. Walks the cumulative distribution to pick the winning item.

	Returns the selected LootItem. Never returns nil for a non-empty catalogue.
]]
function LootManager.SelectLoot(luck: number?): LootItem
	local catalogue = LootManager.Catalogue
	assert(#catalogue > 0, "LootManager.SelectLoot: catalogue is empty")

	-- Clamp luck to a sane lower bound; a non-positive multiplier would zero out
	-- the whole distribution.
	local effectiveLuck = math.max(luck or 1, 1)

	-- 1) Build the modified-weight distribution and normalise the total.
	local totalWeight = 0
	-- Pre-size a parallel array of cumulative weights for the walk in step 3.
	local cumulative: { number } = table.create(#catalogue, 0)

	for index, item in ipairs(catalogue) do
		-- Rarer items (lower base weight) benefit more from luck. The exponent
		-- is small so the effect is meaningful but not degenerate.
		local rarityBias = math.max(1, (100 / math.max(item.Weight, 0.0001)) ^ 0.12)
		local modifiedWeight = item.Weight * (1 + (effectiveLuck - 1) * (rarityBias - 1) * 0.25)

		totalWeight += modifiedWeight
		cumulative[index] = totalWeight
	end

	-- 2) Single uniform draw across the normalised range.
	--    math.random() returns [0, 1); scale to [0, totalWeight).
	local roll = math.random() * totalWeight

	-- 3) Walk the cumulative distribution.
	for index, ceiling in ipairs(cumulative) do
		if roll < ceiling then
			return catalogue[index]
		end
	end

	-- Floating-point fallback: if rounding pushed `roll` to the very top, the
	-- last item is the correct, mathematically-safe choice.
	return catalogue[#catalogue]
end

--[[
	RollCatch
	Convenience wrapper used by the server: selects an item and computes its
	final coin value, applying an optional value multiplier (e.g. from rods,
	gamepasses or events). Returns the CaughtLoot payload sent to the client.
]]
function LootManager.RollCatch(luck: number?, valueMultiplier: number?): CaughtLoot
	local item = LootManager.SelectLoot(luck)
	local multiplier = math.max(valueMultiplier or 1, 0)
	local value = math.floor(item.BaseValue * multiplier + 0.5)

	return {
		Item = item,
		Value = value,
	}
end

return LootManager
