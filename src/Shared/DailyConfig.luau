--!strict
--[[
	DailyConfig
	-----------
	Shared module (ReplicatedStorage.Shared.DailyConfig).

	The 7-day escalating daily-reward track (a top retention driver). Shared so
	the client can preview the whole week and the server can authoritatively
	grant. Streak advances once per claim window and resets if a day is missed.
]]

local DailyConfig = {}

-- Seconds between claims (a claim becomes available 20h after the last) and the
-- window after which a missed day resets the streak to 1.
DailyConfig.ClaimCooldown = 20 * 60 * 60   -- 20 hours
DailyConfig.ResetAfter = 48 * 60 * 60      -- miss ~2 days -> streak resets

export type DailyReward = {
	Day: number,
	Type: string,    -- "Coins" | "Keys" | "Pet" | "LuckPotion"
	Amount: number?,
	Ref: string?,    -- Pet id for Type == "Pet"
	Multiplier: number?,
	Duration: number?,
	Label: string,
}

-- A 7-entry cycle; day 8 wraps back to day 1 (keeping the streak going).
DailyConfig.Rewards = {
	{ Day = 1, Type = "Coins", Amount = 500, Label = "500 Coins" },
	{ Day = 2, Type = "Keys", Amount = 1, Label = "1 Key" },
	{ Day = 3, Type = "Coins", Amount = 1500, Label = "1,500 Coins" },
	{ Day = 4, Type = "LuckPotion", Multiplier = 2, Duration = 300, Label = "2x Luck (5m)" },
	{ Day = 5, Type = "Coins", Amount = 4000, Label = "4,000 Coins" },
	{ Day = 6, Type = "Keys", Amount = 3, Label = "3 Keys" },
	{ Day = 7, Type = "Pet", Ref = "Octopus", Label = "Octopus Pet!" },
} :: { DailyReward }

--[[
	GetReward
	Returns the reward for a given streak count (1-based), wrapping the 7-day
	cycle so long streaks keep paying out the day-7 jackpot weekly.
]]
function DailyConfig.GetReward(streak: number): DailyReward
	local count = #DailyConfig.Rewards
	local index = ((math.max(1, streak) - 1) % count) + 1
	return DailyConfig.Rewards[index]
end

return DailyConfig
