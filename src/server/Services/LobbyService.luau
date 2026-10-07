--[[
	LobbyService (server)
	Crew lobbies. Any player can create one (Play) and share its code; others join with the code.
	Each lobby has up to 4 desks, a host, a difficulty and ready states, and the host starts the shift.

	Clients only *request* changes; every request is validated here. After any change the whole
	lobby state is pushed to that lobby's members (Network.Lobby.packets.Update).

	When the host starts the shift and the countdown ends, ShiftLauncher teleports the crew into their
	own private server of the Call Center Place. If that fails (e.g. in Studio) the lobby reopens.

	Public API:
		LobbyService.Start()
		LobbyService.GetLobbyCode(player) -> string?
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Lobby = require(Shared.Network.Lobby)
local LobbyConfig = require(Shared.Config.LobbyConfig)
local LobbyDirectory = require(script.Parent.LobbyDirectory)
local ShiftLauncher = require(script.Parent.ShiftLauncher)

type LobbyState = Lobby.LobbyState
type Seat = Lobby.Seat
type Result = Lobby.Result

type LobbyData = {
	code: string,
	phase: number,
	host: Player?,
	difficulty: number,
	countdown: number,
	revision: number,
	seats: { [number]: Player }, -- desk index -> player
	ready: { [Player]: boolean },
}

local Phase = LobbyConfig.Phase

local LobbyService = {}

local lobbies: { [string]: LobbyData } = {}
local lobbyOf: { [Player]: LobbyData } = {}
local subscribers: { [Player]: boolean } = {} -- clients that finished booting and can receive packets
local arrivalCodes: { [Player]: string } = {} -- teleported in to join this code
local lastRequest: { [Player]: number } = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function ok(message: string): Result
	return { Ok = true, Message = message }
end

local function fail(message: string): Result
	return { Ok = false, Message = message }
end

local function makeCode(): string
	local alphabet = LobbyConfig.CodeAlphabet
	local rng = Random.new()
	while true do
		local chars = table.create(LobbyConfig.CodeLength)
		for i = 1, LobbyConfig.CodeLength do
			local n = rng:NextInteger(1, #alphabet)
			chars[i] = string.sub(alphabet, n, n)
		end
		local code = table.concat(chars)
		if not lobbies[code] then
			return code
		end
	end
end

local function members(lobby: LobbyData): { Player }
	local list = {}
	for desk = 1, LobbyConfig.MaxDesks do
		local player = lobby.seats[desk]
		if player then
			table.insert(list, player)
		end
	end
	return list
end

local function deskOf(lobby: LobbyData, player: Player): number?
	for desk, occupant in lobby.seats do
		if occupant == player then
			return desk
		end
	end
	return nil
end

local function firstFreeDesk(lobby: LobbyData): number?
	for desk = 1, LobbyConfig.MaxDesks do
		if lobby.seats[desk] == nil then
			return desk
		end
	end
	return nil
end

local function snapshot(lobby: LobbyData): LobbyState
	local seats: { Seat } = {}
	for desk = 1, LobbyConfig.MaxDesks do
		local player = lobby.seats[desk]
		if player then
			table.insert(seats, {
				Desk = desk,
				UserId = player.UserId,
				DisplayName = player.DisplayName,
				Username = player.Name,
				Ready = lobby.ready[player] == true,
			})
		end
	end
	return {
		Revision = lobby.revision,
		Code = lobby.code,
		Phase = lobby.phase,
		HostUserId = if lobby.host then lobby.host.UserId else 0,
		Difficulty = lobby.difficulty,
		Countdown = lobby.countdown,
		Seats = seats,
	}
end

-- Pushes the lobby's new state to its members. Call after every change.
local function publish(lobby: LobbyData)
	lobby.revision += 1
	local targets = {}
	for _, player in members(lobby) do
		if subscribers[player] then
			table.insert(targets, player)
		end
	end
	if #targets > 0 then
		Lobby.packets.Update.sendToList(snapshot(lobby), targets)
	end
end

local function notify(player: Player, message: string)
	if subscribers[player] then
		Lobby.packets.Notice.sendTo(message, player)
	end
end

local function notifyOthers(lobby: LobbyData, except: Player, message: string)
	for _, player in members(lobby) do
		if player ~= except then
			notify(player, message)
		end
	end
end

-- Per-player spam guard for every request.
local function throttle(player: Player): boolean
	local now = os.clock()
	if now - (lastRequest[player] or 0) < LobbyConfig.ActionCooldown then
		return false
	end
	lastRequest[player] = now
	return true
end

-- The caller's lobby, if they may change it right now.
local function editableLobby(player: Player): LobbyData?
	if not subscribers[player] or not throttle(player) then
		return nil
	end
	local lobby = lobbyOf[player]
	if not lobby then
		return nil
	end
	if lobby.phase ~= Phase.Lobby then
		notify(player, "Your shift already started.")
		return nil
	end
	return lobby
end

local function removeFromLobby(player: Player)
	local lobby = lobbyOf[player]
	if not lobby then
		return
	end
	lobbyOf[player] = nil
	local desk = deskOf(lobby, player)
	if desk then
		lobby.seats[desk] = nil
	end
	lobby.ready[player] = nil

	if #members(lobby) == 0 then
		lobbies[lobby.code] = nil
		LobbyDirectory.Unregister(lobby.code)
	else
		notifyOthers(lobby, player, `{player.DisplayName} left the lobby.`)
		if lobby.host == player then
			lobby.host = members(lobby)[1]
			if lobby.host then
				notify(lobby.host, "You're the host now.")
			end
		end
		publish(lobby)
	end

	if subscribers[player] then
		Lobby.packets.Update.sendTo(nil, player)
	end
end

local function addToLobby(player: Player, lobby: LobbyData): Result
	if lobbyOf[player] == lobby then
		return ok("You're already in this lobby.")
	end
	if lobby.phase ~= Phase.Lobby then
		return fail("That crew already started their shift.")
	end
	local desk = firstFreeDesk(lobby)
	if not desk then
		return fail(`Lobby {lobby.code} is full ({LobbyConfig.MaxDesks}/{LobbyConfig.MaxDesks}).`)
	end

	removeFromLobby(player)
	lobby.seats[desk] = player
	lobbyOf[player] = lobby
	if lobby.host == nil then
		lobby.host = player
	end
	notifyOthers(lobby, player, `{player.DisplayName} joined the lobby.`)
	publish(lobby)
	return ok(`Joined lobby {lobby.code}.`)
end

-- ---------------------------------------------------------------------------
-- Request handlers
-- ---------------------------------------------------------------------------

local function onGetLobby(_: nil, player: Player): LobbyState?
	subscribers[player] = true

	-- Teleported in from another server to join a friend: seat them now that their client is ready.
	local arrival = arrivalCodes[player]
	if arrival then
		arrivalCodes[player] = nil
		local lobby = lobbies[arrival]
		if lobby then
			local result = addToLobby(player, lobby)
			if not result.Ok then
				notify(player, result.Message)
			end
		else
			notify(player, `Lobby {arrival} closed before you arrived.`)
		end
	end

	local lobby = lobbyOf[player]
	return if lobby then snapshot(lobby) else nil
end

local function onCreateLobby(_: nil, player: Player): Result
	subscribers[player] = true
	if not throttle(player) then
		return fail("Slow down a little.")
	end

	local current = lobbyOf[player]
	if current then
		return ok(`You're already in lobby {current.code}.`)
	end

	local lobby: LobbyData = {
		code = makeCode(),
		phase = Phase.Lobby,
		host = player,
		difficulty = LobbyConfig.DefaultDifficulty,
		countdown = 0,
		revision = 0,
		seats = { [1] = player },
		ready = {},
	}
	lobbies[lobby.code] = lobby
	lobbyOf[player] = lobby
	LobbyDirectory.Register(lobby.code)
	publish(lobby)
	return ok(`Lobby {lobby.code} is open. Share the code with your crew.`)
end

local function onJoinLobby(rawCode: string, player: Player): Result
	subscribers[player] = true
	if not throttle(player) then
		return fail("Slow down a little.")
	end

	local code = string.upper(string.gsub(rawCode, "[^%w]", ""))
	if #code ~= LobbyConfig.CodeLength then
		return fail(`Codes are {LobbyConfig.CodeLength} letters or numbers.`)
	end

	local current = lobbyOf[player]
	if current and current.code == code then
		return ok("You're already in that lobby.")
	end
	if current and current.phase ~= Phase.Lobby then
		return fail("Finish your shift first.")
	end

	local lobby = lobbies[code]
	if lobby then
		return addToLobby(player, lobby)
	end

	local jobId = LobbyDirectory.Find(code)
	if jobId then
		local teleported = LobbyDirectory.TeleportTo(player, jobId, code)
		if teleported then
			return ok("That lobby is on another server. Teleporting you there…")
		end
		return fail("Couldn't teleport you to that lobby. Try again in a moment.")
	end

	return fail(`No lobby found with code {code}.`)
end

local function onLeaveLobby(_: nil, player: Player)
	if not subscribers[player] or not throttle(player) then
		return
	end
	local lobby = lobbyOf[player]
	if lobby and lobby.phase ~= Phase.Lobby then
		notify(player, "The shift is starting. Too late to leave!")
		return
	end
	removeFromLobby(player)
end

local function onPickDesk(desk: number, player: Player)
	local lobby = editableLobby(player)
	if not lobby or desk < 1 or desk > LobbyConfig.MaxDesks then
		return
	end
	local current = deskOf(lobby, player)
	if current == desk then
		return
	end
	if lobby.seats[desk] ~= nil then
		notify(player, "That desk is taken.")
		return
	end
	if current then
		lobby.seats[current] = nil
	end
	lobby.seats[desk] = player
	publish(lobby)
end

local function onSetReady(value: boolean, player: Player)
	local lobby = editableLobby(player)
	if not lobby or (lobby.ready[player] == true) == value then
		return
	end
	lobby.ready[player] = value
	publish(lobby)
end

local function onSetDifficulty(index: number, player: Player)
	local lobby = editableLobby(player)
	if not lobby then
		return
	end
	if lobby.host ~= player then
		notify(player, "Only the host can change that.")
		return
	end
	if LobbyConfig.Difficulties[index] == nil or lobby.difficulty == index then
		return
	end
	lobby.difficulty = index
	publish(lobby)
end

local function onStartShift(_: nil, player: Player)
	local lobby = editableLobby(player)
	if not lobby then
		return
	end
	if lobby.host ~= player then
		notify(player, "Only the host can start the shift.")
		return
	end

	local crew = members(lobby)
	local readyCount = 0
	for _, member in crew do
		if lobby.ready[member] then
			readyCount += 1
		end
	end
	if readyCount < #crew then
		notify(player, `Not everyone is ready yet ({readyCount}/{#crew}).`)
		return
	end

	lobby.phase = Phase.Starting
	lobby.countdown = LobbyConfig.StartCountdown
	LobbyDirectory.Unregister(lobby.code)
	publish(lobby)

	task.delay(LobbyConfig.StartCountdown, function()
		if lobbies[lobby.code] ~= lobby then
			return -- everyone left during the countdown
		end
		lobby.phase = Phase.Teleporting
		lobby.countdown = 0
		publish(lobby)

		local crewNow = members(lobby)
		local userIds = {}
		for _, member in crewNow do
			table.insert(userIds, member.UserId)
		end
		local launched, message = ShiftLauncher.Launch({
			LobbyCode = lobby.code,
			Difficulty = lobby.difficulty,
			HostUserId = if lobby.host then lobby.host.UserId else 0,
			Crew = userIds,
			ReturnPlaceId = game.PlaceId,
		}, crewNow)

		if not launched and lobbies[lobby.code] == lobby then
			-- Reopen the lobby so the crew can try again.
			lobby.phase = Phase.Lobby
			LobbyDirectory.Register(lobby.code)
			publish(lobby)
			for _, member in members(lobby) do
				notify(member, message)
			end
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	local code = LobbyDirectory.ArrivalCode(player)
	if code then
		arrivalCodes[player] = code
	end
end

local function onPlayerRemoving(player: Player)
	subscribers[player] = nil -- nothing more to send them
	removeFromLobby(player)
	arrivalCodes[player] = nil
	lastRequest[player] = nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function LobbyService.GetLobbyCode(player: Player): string?
	local lobby = lobbyOf[player]
	return lobby and lobby.code
end

function LobbyService.Start()
	Lobby.queries.GetLobby.listen(onGetLobby)
	Lobby.queries.CreateLobby.listen(onCreateLobby)
	Lobby.queries.JoinLobby.listen(onJoinLobby)
	Lobby.packets.LeaveLobby.listen(onLeaveLobby)
	Lobby.packets.PickDesk.listen(onPickDesk)
	Lobby.packets.SetReady.listen(onSetReady)
	Lobby.packets.SetDifficulty.listen(onSetDifficulty)
	Lobby.packets.StartShift.listen(onStartShift)

	-- A crew member whose teleport kept failing goes back to the desktop.
	ShiftLauncher.OnPlayerFailed(function(player, message)
		removeFromLobby(player)
		notify(player, message)
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return LobbyService
