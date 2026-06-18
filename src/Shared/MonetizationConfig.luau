--!strict
--[[
	MonetizationConfig
	------------------
	Shared module (ReplicatedStorage.Shared.MonetizationConfig).

	Declares the game's Robux monetization catalogue — Game Passes (one-time
	perks) and Developer Products (repeatable purchases) — plus Premium benefits.
	Required by the server (authoritative granting) and the client (store UI).

	>>> IMPORTANT: SET YOUR ASSET IDS <<<
	Game Passes and Developer Products are created on the Roblox Creator
	Dashboard (Monetization tab) and each gets a numeric Id. Paste those Ids in
	below. Until an Id is non-zero it is treated as "not configured": the store
	shows it as unavailable and the server skips it. The game runs fine with
	zeros — you just won't sell anything until the Ids are real.
]]

local MonetizationConfig = {}

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

export type GamePass = {
	Key: string,
	Id: number,             -- Roblox Game Pass Id (0 = not configured).
	Name: string,
	Desc: string,
	Order: number,
	CoinMultiplier: number?, -- Multiplies coins earned from selling.
	LuckMultiplier: number?, -- Multiplies luck on every catch.
	AutoFish: boolean?,      -- Grants the server-side auto-fisher.
}

export type Product = {
	Key: string,
	Id: number,             -- Roblox Developer Product Id (0 = not configured).
	Name: string,
	Desc: string,
	Order: number,
	Coins: number?,         -- Instantly granted coins.
	LuckMultiplier: number?, -- Temporary luck multiplier...
	LuckDuration: number?,   -- ...for this many seconds.
}

-- ---------------------------------------------------------------------------
-- Premium
-- ---------------------------------------------------------------------------

-- Roblox Premium members earn a passive coin bonus (and you receive Premium
-- Payouts based on their engagement time — a second revenue stream).
MonetizationConfig.PremiumCoinMultiplier = 1.25

-- How often the Auto Fisher pass reels in a fish (seconds).
MonetizationConfig.AutoFishInterval = 3.0

-- ---------------------------------------------------------------------------
-- Game Passes (one-time purchases)
-- ---------------------------------------------------------------------------

MonetizationConfig.GamePasses = {
	VIP = {
		Key = "VIP",
		Id = 0, -- TODO: paste your VIP game pass id
		Name = "VIP",
		Desc = "Sell fish for 2x coins, plus a permanent luck boost.",
		Order = 1,
		CoinMultiplier = 2,
		LuckMultiplier = 1.15,
	},
	LuckyCharm = {
		Key = "LuckyCharm",
		Id = 0, -- TODO: paste your Lucky Charm game pass id
		Name = "Lucky Charm",
		Desc = "Doubles your luck on every single catch, forever.",
		Order = 2,
		LuckMultiplier = 2,
	},
	AutoFisher = {
		Key = "AutoFisher",
		Id = 0, -- TODO: paste your Auto Fisher game pass id
		Name = "Auto Fisher",
		Desc = "Automatically reels in fish for you — even while AFK.",
		Order = 3,
		AutoFish = true,
	},
} :: { [string]: GamePass }

-- ---------------------------------------------------------------------------
-- Developer Products (repeatable purchases)
-- ---------------------------------------------------------------------------

MonetizationConfig.Products = {
	Coins1k = {
		Key = "Coins1k",
		Id = 0, -- TODO: paste your 1,000 coins product id
		Name = "1,000 Coins",
		Desc = "A quick top-up of 1,000 coins.",
		Order = 1,
		Coins = 1000,
	},
	Coins10k = {
		Key = "Coins10k",
		Id = 0, -- TODO: paste your 10,000 coins product id
		Name = "10,000 Coins",
		Desc = "A hearty pile of 10,000 coins.",
		Order = 2,
		Coins = 10000,
	},
	Coins100k = {
		Key = "Coins100k",
		Id = 0, -- TODO: paste your 100,000 coins product id
		Name = "100,000 Coins",
		Desc = "Go big: 100,000 coins instantly.",
		Order = 3,
		Coins = 100000,
	},
	LuckPotion = {
		Key = "LuckPotion",
		Id = 0, -- TODO: paste your Luck Potion product id
		Name = "Luck Potion",
		Desc = "Triple luck for 10 minutes — stack it before a big session!",
		Order = 4,
		LuckMultiplier = 3,
		LuckDuration = 600,
	},
} :: { [string]: Product }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function MonetizationConfig.GetSortedPasses(): { GamePass }
	local list: { GamePass } = {}
	for _, pass in pairs(MonetizationConfig.GamePasses) do
		table.insert(list, pass)
	end
	table.sort(list, function(a, b)
		return a.Order < b.Order
	end)
	return list
end

function MonetizationConfig.GetSortedProducts(): { Product }
	local list: { Product } = {}
	for _, product in pairs(MonetizationConfig.Products) do
		table.insert(list, product)
	end
	table.sort(list, function(a, b)
		return a.Order < b.Order
	end)
	return list
end

function MonetizationConfig.GetPassById(id: number): GamePass?
	if id == 0 then
		return nil
	end
	for _, pass in pairs(MonetizationConfig.GamePasses) do
		if pass.Id == id then
			return pass
		end
	end
	return nil
end

function MonetizationConfig.GetProductById(id: number): Product?
	if id == 0 then
		return nil
	end
	for _, product in pairs(MonetizationConfig.Products) do
		if product.Id == id then
			return product
		end
	end
	return nil
end

return MonetizationConfig
