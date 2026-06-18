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
export type Rarity = "Common" | "Uncommon" | "Rare" | "Legendary"

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

		Common Fish              Weight = 70    BaseValue = 15
		Uncommon Salmon          Weight = 20    BaseValue = 40
		Rare Golden Trout        Weight = 8.5   BaseValue = 120
		Legendary Kraken Tentacle Weight = 1.5  BaseValue = 750
]]
LootManager.Catalogue = {
	{
		Id = "common_fish",
		Name = "Common Fish",
		Rarity = "Common" :: Rarity,
		Weight = 70,
		BaseValue = 15,
		Color = Color3.fromRGB(170, 178, 184),
	},
	{
		Id = "uncommon_salmon",
		Name = "Uncommon Salmon",
		Rarity = "Uncommon" :: Rarity,
		Weight = 20,
		BaseValue = 40,
		Color = Color3.fromRGB(88, 196, 120),
	},
	{
		Id = "rare_golden_trout",
		Name = "Rare Golden Trout",
		Rarity = "Rare" :: Rarity,
		Weight = 8.5,
		BaseValue = 120,
		Color = Color3.fromRGB(64, 156, 255),
	},
	{
		Id = "legendary_kraken_tentacle",
		Name = "Legendary Kraken Tentacle",
		Rarity = "Legendary" :: Rarity,
		Weight = 1.5,
		BaseValue = 750,
		Color = Color3.fromRGB(190, 96, 255),
	},
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
	local cumulative: { number } = table.create(#catalogue)

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
