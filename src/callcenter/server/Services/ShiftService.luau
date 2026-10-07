--[[
	ShiftService (server, Call Center Place)
	Works out which crew this server belongs to and what shift they're running.

	Every crew arrives in its own reserved server (see the lobby's ShiftLauncher). The lobby leaves the
	shift details in MemoryStore under this server's PrivateServerId, which is the trusted copy. The
	crew's TeleportData carries the same details and is used if MemoryStore is unavailable.

	The result is published as ReplicatedStorage attributes for clients:
		ShiftCode, ShiftDifficulty, ShiftDifficultyName, ShiftQuota, ShiftHostUserId,
		ShiftCrewSize (crew that clocked in), ShiftCrewOnline (here right now), ShiftReady (set last)

	Server kinds:
		reserved server   a crew's shift (the normal case)
		Studio            a test shift so you can play the place directly
		anything else     someone opened the place without a crew; they're sent back to the lobby

	Roblox closes a reserved server once everyone has left, so there's nothing to clean up.

	ShiftService.Start()
	ShiftService.Get() -> ShiftInfo?
]]

local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared.Config.LobbyConfig)
local Places = require(Shared.Config.Places)
local Shift = require(Shared.Network).Shift

local MEMORY_READS = 6 -- the lobby writes right after the teleport starts, so the first read can miss
local MEMORY_READ_GAP = 2
local LEAVE_COOLDOWN = 3

export type ShiftInfo = {
	LobbyCode: string,
	Difficulty: number,
	HostUserId: number,
	Crew: { number },
	ReturnPlaceId: number,
}

local ShiftService = {}

local shift: ShiftInfo? = nil
local trusted = false -- came from MemoryStore (not from a client's TeleportData)
local stray = false -- not a crew server
local fallbackOpen = false -- MemoryStore gave up; take the first valid TeleportData
local lastLeave: { [Player]: number } = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function isReservedServer(): boolean
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
end

local function notice(player: Player, message: string)
	Shift.packets.Notice.sendTo(message, player)
end

-- Turns whatever arrived (MemoryStore value or TeleportData) into a clean ShiftInfo, or nil.
local function sanitize(raw: any): ShiftInfo?
	if type(raw) ~= "table" or type(raw.LobbyCode) ~= "string" or raw.LobbyCode == "" then
		return nil
	end
	local difficulty = tonumber(raw.Difficulty)
	if not difficulty or not LobbyConfig.Difficulties[difficulty] then
		difficulty = LobbyConfig.DefaultDifficulty
	end
	local crew = {}
	if type(raw.Crew) == "table" then
		for _, userId in raw.Crew do
			if type(userId) == "number" and #crew < LobbyConfig.MaxDesks and not table.find(crew, userId) then
				table.insert(crew, userId)
			end
		end
	end
	return {
		LobbyCode = string.upper(string.sub(raw.LobbyCode, 1, LobbyConfig.CodeLength)),
		Difficulty = difficulty :: number,
		HostUserId = tonumber(raw.HostUserId) or 0,
		Crew = crew,
		ReturnPlaceId = tonumber(raw.ReturnPlaceId) or 0,
	}
end

local function updateOnline()
	local online = #Players:GetPlayers()
	ReplicatedStorage:SetAttribute("ShiftCrewOnline", online)
	if shift and #shift.Crew == 0 then
		-- Studio / fallback without a crew list: whoever is here is the crew.
		ReplicatedStorage:SetAttribute("ShiftCrewSize", online)
	end
end

local function isCrew(player: Player): boolean
	return shift == nil or #shift.Crew == 0 or table.find(shift.Crew, player.UserId) ~= nil
end

-- Only a trusted crew list is enforced; nobody can reach a reserved server without its access code anyway.
local function checkCrew(player: Player)
	if trusted and not isCrew(player) then
		player:Kick("This call center belongs to another crew.")
	end
end

local function publish(info: ShiftInfo, source: string)
	if shift then
		return
	end
	shift = info
	local difficulty = LobbyConfig.Difficulties[info.Difficulty]
	ReplicatedStorage:SetAttribute("ShiftCode", info.LobbyCode)
	ReplicatedStorage:SetAttribute("ShiftDifficulty", info.Difficulty)
	ReplicatedStorage:SetAttribute("ShiftDifficultyName", difficulty.Name)
	ReplicatedStorage:SetAttribute("ShiftQuota", difficulty.Quota)
	ReplicatedStorage:SetAttribute("ShiftHostUserId", info.HostUserId)
	ReplicatedStorage:SetAttribute("ShiftCrewSize", #info.Crew)
	updateOnline()
	ReplicatedStorage:SetAttribute("ShiftReady", true)
	print(`[ShiftService] shift {info.LobbyCode} ({difficulty.Name}, crew of {#info.Crew}) from {source}`)

	for _, player in Players:GetPlayers() do
		checkCrew(player)
	end
end

local function readJoinData(player: Player): ShiftInfo?
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if ok and type(joinData) == "table" then
		return sanitize(joinData.TeleportData)
	end
	return nil
end

local function readMemoryStore(): any
	local map = MemoryStoreService:GetSortedMap(Places.ShiftInfoMap)
	for attempt = 1, MEMORY_READS do
		local ok, value = pcall(function()
			return map:GetAsync(game.PrivateServerId)
		end)
		if ok and value ~= nil then
			return value
		end
		if not ok then
			warn(`[ShiftService] MemoryStore read {attempt} failed: {value}`)
		end
		task.wait(MEMORY_READ_GAP)
	end
	return nil
end

-- Sends a player back to the lobby place (a normal public server).
local function sendToLobby(player: Player, kickMessage: string): boolean
	if RunService:IsStudio() then
		notice(player, "Teleports only work in the live game. Stop the test to leave.")
		return false
	end
	local target = if shift and shift.ReturnPlaceId ~= 0 then shift.ReturnPlaceId else Places.Lobby
	if target == 0 or target == game.PlaceId then
		player:Kick(kickMessage)
		return true
	end
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(target, { player })
	end)
	if not ok then
		warn(`[ShiftService] couldn't send {player.Name} to the lobby: {err}`)
		notice(player, "Couldn't reach the lobby. Try again in a moment.")
	end
	return ok
end

local function resolveShift()
	if not isReservedServer() then
		if RunService:IsStudio() then
			publish({
				LobbyCode = "STUDIO",
				Difficulty = LobbyConfig.DefaultDifficulty,
				HostUserId = 0,
				Crew = {},
				ReturnPlaceId = 0,
			}, "Studio test")
			return
		end
		stray = true
		warn("[ShiftService] not a crew server; sending players back to the lobby")
		for _, player in Players:GetPlayers() do
			task.spawn(sendToLobby, player, "Start a shift from the Call Center Chaos lobby.")
		end
		return
	end

	local stored = sanitize(readMemoryStore())
	if stored then
		trusted = true
		publish(stored, "MemoryStore")
		return
	end

	warn("[ShiftService] no shift info in MemoryStore; using the crew's TeleportData")
	fallbackOpen = true
	for _, player in Players:GetPlayers() do
		local fromJoin = readJoinData(player)
		if fromJoin then
			publish(fromJoin, `{player.Name}'s TeleportData`)
			return
		end
	end
end

-- ---------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	updateOnline()
	if stray then
		sendToLobby(player, "Start a shift from the Call Center Chaos lobby.")
		return
	end
	if shift then
		checkCrew(player)
	elseif fallbackOpen then
		local fromJoin = readJoinData(player)
		if fromJoin then
			publish(fromJoin, `{player.Name}'s TeleportData`)
		end
	end
end

local function onPlayerRemoving(player: Player)
	lastLeave[player] = nil
	task.defer(updateOnline)
end

local function onLeaveShift(_: nil, player: Player)
	local now = os.clock()
	if lastLeave[player] and now - lastLeave[player] < LEAVE_COOLDOWN then
		return
	end
	lastLeave[player] = now
	sendToLobby(player, "Shift over. Rejoin Call Center Chaos to start another.")
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function ShiftService.Get(): ShiftInfo?
	return shift
end

function ShiftService.Start()
	ReplicatedStorage:SetAttribute("ShiftReady", false)
	Shift.packets.LeaveShift.listen(onLeaveShift)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	task.spawn(resolveShift)
end

return ShiftService
