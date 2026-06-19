--!strict
--[[
	LeaderboardService
	------------------
	Server module (ServerScriptService.Services.LeaderboardService).

	A global "Top Anglers by Coins" board, displayed on a physical panel in the
	market cavern under the mountain. Scores live in an OrderedDataStore so the
	ranking persists across servers; the panel refreshes on a timer.

	Everything DataStore-related is pcall-guarded so a Studio session without API
	access (or a transient DataStore error) degrades gracefully to "no data yet"
	instead of erroring.
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ServerScriptService = game:GetService("ServerScriptService")

local DataService = require(ServerScriptService.Services.DataService)

local LeaderboardService = {}

local STORE_NAME = "FishingTopCoins_v1"
local TOP_N = 10
local WRITE_INTERVAL = 120 -- push online players' scores this often (seconds)
local REFRESH_INTERVAL = 45 -- re-read + redraw the board this often

-- Board sits in the NW of the cavern, pulled ~5 studs off every wall (terrain
-- carving snaps to a 4-stud grid, so flush placement gets buried in rock) and
-- clear of the centre tunnel mouth at x∈[-12,12]. Faces +Z into the room.
local BOARD_POS = Vector3.new(-24, 11, -33)
local BOARD_W = 18
local BOARD_H = 14

local store: OrderedDataStore? = nil
local entriesFrame: Frame? = nil
local nameCache: { [number]: string } = {}

-- ---------------------------------------------------------------------------
-- Board geometry
-- ---------------------------------------------------------------------------

local function buildBoard()
	local existing = workspace:FindFirstChild("Leaderboard")
	if existing ~= nil then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "Leaderboard"
	folder.Parent = workspace

	local panel = Instance.new("Part")
	panel.Name = "TopBoard"
	panel.Anchored = true
	panel.CanCollide = false
	panel.Size = Vector3.new(BOARD_W, BOARD_H, 1)
	panel.CFrame = CFrame.new(BOARD_POS)
	panel.Color = Color3.fromRGB(20, 24, 30)
	panel.Material = Enum.Material.SmoothPlastic
	panel.Parent = folder

	-- A glowing frame BEHIND the panel so its edges glow without covering the
	-- display (the board faces +Z, so "behind" is -Z).
	local trim = Instance.new("Part")
	trim.Name = "Trim"
	trim.Anchored = true
	trim.CanCollide = false
	trim.Size = Vector3.new(BOARD_W + 1.5, BOARD_H + 1.5, 0.6)
	trim.CFrame = CFrame.new(BOARD_POS + Vector3.new(0, 0, -0.5))
	trim.Color = Color3.fromRGB(240, 200, 90)
	trim.Material = Enum.Material.Neon
	trim.Parent = folder

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 235, 200)
	light.Range = 26
	light.Brightness = 2
	light.Parent = panel

	local surface = Instance.new("SurfaceGui")
	surface.Name = "Display"
	surface.Face = Enum.NormalId.Back -- +Z face, toward the cavern centre
	surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surface.PixelsPerStud = 28
	surface.LightInfluence = 0
	surface.Brightness = 1.4
	surface.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0.12, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 220, 130)
	title.Text = "🏆 TOP ANGLERS"
	title.Parent = surface

	local list = Instance.new("Frame")
	list.Name = "Entries"
	list.Size = UDim2.new(1, -20, 0.85, 0)
	list.Position = UDim2.new(0, 10, 0.14, 0)
	list.BackgroundTransparency = 1
	list.Parent = surface

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	entriesFrame = list
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function getName(userId: number): string
	local cached = nameCache[userId]
	if cached ~= nil then
		return cached
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local resolved = if ok and type(name) == "string" then name else ("Player " .. userId)
	nameCache[userId] = resolved
	return resolved
end

local function comma(n: number): string
	local s = tostring(math.floor(n))
	while true do
		local replaced: number
		s, replaced = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2")
		if replaced == 0 then
			break
		end
	end
	return s
end

local function setMessage(text: string)
	local list = entriesFrame
	if list == nil then
		return
	end
	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	local msg = Instance.new("TextLabel")
	msg.Size = UDim2.new(1, 0, 0, 40)
	msg.BackgroundTransparency = 1
	msg.Font = Enum.Font.Gotham
	msg.TextColor3 = Color3.fromRGB(180, 190, 200)
	msg.TextScaled = true
	msg.Text = text
	msg.Parent = list
end

local function renderEntries(entries: { { key: string, value: number } })
	local list = entriesFrame
	if list == nil then
		return
	end
	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end

	if #entries == 0 then
		setMessage("No scores yet — be the first!")
		return
	end

	for rank, entry in ipairs(entries) do
		local userId = tonumber(entry.key) or 0
		local row = Instance.new("TextLabel")
		row.Size = UDim2.new(1, 0, 0, 34)
		row.BackgroundTransparency = 1
		row.Font = Enum.Font.GothamBold
		row.TextScaled = true
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.LayoutOrder = rank
		row.TextColor3 = if rank == 1 then Color3.fromRGB(255, 215, 110)
			elseif rank == 2 then Color3.fromRGB(220, 226, 232)
			elseif rank == 3 then Color3.fromRGB(214, 158, 110)
			else Color3.fromRGB(225, 232, 240)
		row.Text = string.format("#%d  %s   —   %s 🪙", rank, getName(userId), comma(entry.value))
		row.Parent = list
	end
end

-- ---------------------------------------------------------------------------
-- DataStore I/O (all guarded)
-- ---------------------------------------------------------------------------

local function pushScore(player: Player)
	if store == nil then
		return
	end
	local data = DataService:GetData(player)
	if data == nil then
		return
	end
	pcall(function()
		(store :: OrderedDataStore):SetAsync(tostring(player.UserId), math.floor(data.Coins))
	end)
end

local function refreshBoard()
	if store == nil then
		setMessage("Leaderboard offline (enable API Services).")
		return
	end
	local ok, pages = pcall(function()
		return (store :: OrderedDataStore):GetSortedAsync(false, TOP_N)
	end)
	if not ok or pages == nil then
		setMessage("No scores yet — be the first!")
		return
	end
	local page = (pages :: DataStorePages):GetCurrentPage()
	renderEntries(page :: any)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function LeaderboardService:Init()
	buildBoard()

	local ok, opened = pcall(function()
		return DataStoreService:GetOrderedDataStore(STORE_NAME)
	end)
	store = if ok then opened else nil

	-- Write a leaving player's final score immediately.
	Players.PlayerRemoving:Connect(function(player: Player)
		task.spawn(pushScore, player)
	end)

	-- Periodically push online scores.
	task.spawn(function()
		while true do
			task.wait(WRITE_INTERVAL)
			for _, player in ipairs(Players:GetPlayers()) do
				pushScore(player)
			end
		end
	end)

	-- Periodically redraw the board.
	task.spawn(function()
		while true do
			refreshBoard()
			task.wait(REFRESH_INTERVAL)
		end
	end)
end

return LeaderboardService
