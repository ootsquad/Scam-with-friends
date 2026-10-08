--[[
	LobbyService (server, lobby place)
	Parties for this lobby server's players. The party logic itself is PartyCore (shared across servers through
	MemoryStore and MessagingService); this connects it to Roblox:

	  - the client's requests (Network.Lobby): create, join with a code, leave, pick a desk, ready, difficulty,
	    remove a member, start the shift
	  - pushing each player their party (Lobby.packets.Update) and messages (Lobby.packets.Notice)
	  - arrivals: someone who accepted a party invite (LaunchData) or was moved to a solo lobby joins the party
	    automatically once their client is ready
	  - solo lobbies: with LobbyConfig.SoloLobbies, a player who lands in a lobby server that already has
	    someone in it is moved to a lobby server of their own (setting the place's Max Players to 1 does the
	    same thing without the extra hop)
	  - launching: ShiftLauncher teleports this server's members into the party's call center server

	LobbyService.Start()
	LobbyService.GetLobbyCode(player) -> string?
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Lobby = require(Shared.Network.Lobby)
local LobbyConfig = require(Shared.Config.LobbyConfig)
local PartyBackend = require(script.Parent.PartyBackend)
local PartyCore = require(script.Parent.PartyCore)
local ShiftLauncher = require(script.Parent.ShiftLauncher)

type Result = Lobby.Result

local SOLO_MOVE_TIMEOUT = 30 -- seconds before a move to a solo lobby that never happened counts as failed

local LobbyService = {}

local core: any
local subscribers: { [Player]: boolean } = {} -- clients that finished booting and can receive packets
local arrivalCodes: { [Player]: string } = {} -- arrived to join this party
local movingSolo: { [Player]: boolean } = {} -- on their way to a lobby server of their own
local lastRequest: { [Player]: number } = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function notify(player: Player, message: string)
	if subscribers[player] and player.Parent then
		Lobby.packets.Notice.sendTo(message, player)
	end
end

local function push(player: Player, party: any)
	if subscribers[player] and player.Parent then
		Lobby.packets.Update.sendTo(if party then core:Snapshot(party) else nil, player)
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

local function slowDown(): Result
	return { Ok = false, Message = "Slow down a little." }
end

local function unixNow(): number
	return DateTime.now().UnixTimestampMillis / 1000
end

-- The party code a player arrived with: from a party invite (LaunchData) or a solo-lobby move (TeleportData).
local function arrivalCode(player: Player): string?
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if not ok or type(joinData) ~= "table" then
		return nil
	end
	local teleportData = joinData.TeleportData
	if type(teleportData) == "table" and type(teleportData.LobbyCode) == "string" then
		return string.upper(teleportData.LobbyCode)
	end
	local launchData = joinData.LaunchData
	if type(launchData) == "string" and #launchData > 0 then
		local code = string.upper((string.gsub(launchData, "[^%w]", "")))
		if #code == LobbyConfig.CodeLength then
			return code
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Solo lobbies
-- ---------------------------------------------------------------------------

local function isReservedServer(): boolean
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
end

-- Moves a player who isn't alone in this public lobby server to a lobby server of their own. Returns true if
-- they're on their way.
local function moveToSoloLobby(player: Player): boolean
	if not LobbyConfig.SoloLobbies or RunService:IsStudio() or isReservedServer() then
		return false
	end
	if #Players:GetPlayers() <= 1 then
		return false
	end
	local options = Instance.new("TeleportOptions")
	options.ShouldReserveServer = true
	options:SetTeleportData({ Solo = true, LobbyCode = arrivalCode(player) })
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, { player }, options)
	end)
	if not ok then
		warn(`[LobbyService] couldn't move {player.Name} to a solo lobby (they'll stay here): {err}`)
	end
	return ok
end

-- ---------------------------------------------------------------------------
-- Launching
-- ---------------------------------------------------------------------------

local function launch(players: { Player }, party: any)
	local crew = {}
	for _, member in party.Members do
		table.insert(crew, member.UserId)
	end
	ShiftLauncher.Send(players, party.Launch.AccessCode, {
		LobbyCode = party.Code,
		Difficulty = party.Difficulty,
		HostUserId = party.Leader,
		Crew = crew,
		ReturnPlaceId = game.PlaceId,
	})
end

local function storeShift(privateServerId: string, info: any)
	info.ReturnPlaceId = game.PlaceId
	ShiftLauncher.StoreShift(privateServerId, info)
end

-- ---------------------------------------------------------------------------
-- Request handlers
-- ---------------------------------------------------------------------------

local function joinOnArrival(player: Player, code: string)
	task.spawn(function()
		local result = core:Join(player, code)
		notify(player, if result.Ok then result.Message else `Couldn't join party {code}: {result.Message}`)
	end)
end

local function onGetLobby(_: nil, player: Player)
	subscribers[player] = true

	-- Arrived from an invite or a solo-lobby move: join that party now that the client is ready.
	local arrival = arrivalCodes[player]
	if arrival then
		arrivalCodes[player] = nil
		joinOnArrival(player, arrival)
	end

	local party = core:PartyOf(player)
	return if party then core:Snapshot(party) else nil
end

local function movingResult(): Result
	return { Ok = false, Message = "Moving you to a lobby of your own. One moment…" }
end

local function onCreateLobby(_: nil, player: Player): Result
	subscribers[player] = true
	if not throttle(player) then
		return slowDown()
	elseif movingSolo[player] then
		return movingResult()
	end
	return core:Create(player)
end

local function onJoinLobby(rawCode: string, player: Player): Result
	subscribers[player] = true
	if not throttle(player) then
		return slowDown()
	elseif movingSolo[player] then
		return movingResult()
	end
	return core:Join(player, rawCode)
end

local function guarded(handler: (Player, any) -> ()): (any, Player) -> ()
	return function(value: any, player: Player)
		if subscribers[player] and throttle(player) then
			handler(player, value)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------

local onTeleportInitFailed: (Player, Enum.TeleportResult, string, number) -> ()

local function onPlayerAdded(player: Player)
	core:PlayerAdded(player)
	if moveToSoloLobby(player) then
		movingSolo[player] = true -- the party code (if any) travels with them
		-- Nothing happened (no arrival, no failure): let them play here after all.
		task.delay(SOLO_MOVE_TIMEOUT, function()
			if movingSolo[player] and player.Parent then
				onTeleportInitFailed(player, Enum.TeleportResult.Failure, "timed out", game.PlaceId)
			end
		end)
		return
	end
	local code = arrivalCode(player)
	if code then
		arrivalCodes[player] = code
	end
end

-- The move to a lobby of their own failed: they play the lobby here instead.
function onTeleportInitFailed(player: Player, _result: Enum.TeleportResult, message: string, placeId: number)
	if placeId ~= game.PlaceId or not movingSolo[player] then
		return
	end
	movingSolo[player] = nil
	warn(`[LobbyService] couldn't move {player.Name} to a solo lobby (they'll stay here): {message}`)
	local code = arrivalCode(player)
	if not code then
		return
	end
	if subscribers[player] then
		joinOnArrival(player, code)
	else
		arrivalCodes[player] = code
	end
end

local function onPlayerRemoving(player: Player)
	subscribers[player] = nil -- nothing more to send them
	core:PlayerRemoving(player)
	arrivalCodes[player] = nil
	movingSolo[player] = nil
	lastRequest[player] = nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function LobbyService.GetLobbyCode(player: Player): string?
	return core and core:CodeOf(player)
end

function LobbyService.Start()
	core = PartyCore.new({
		store = PartyBackend.store(LobbyConfig.PartyStore),
		bus = PartyBackend.bus(),
		jobId = if game.JobId ~= "" then game.JobId else `studio-{math.random(1, 1e9)}`,
		now = unixNow,
		config = LobbyConfig,
		push = push,
		notice = notify,
		launch = launch,
		reserve = ShiftLauncher.Reserve,
		storeShift = storeShift,
		random = Random.new(),
	})

	Lobby.queries.GetLobby.listen(onGetLobby)
	Lobby.queries.CreateLobby.listen(onCreateLobby)
	Lobby.queries.JoinLobby.listen(onJoinLobby)
	Lobby.packets.LeaveLobby.listen(guarded(function(player)
		core:Leave(player)
	end))
	Lobby.packets.PickDesk.listen(guarded(function(player, desk)
		core:PickDesk(player, desk)
	end))
	Lobby.packets.SetReady.listen(guarded(function(player, ready)
		core:SetReady(player, ready)
	end))
	Lobby.packets.SetDifficulty.listen(guarded(function(player, index)
		core:SetDifficulty(player, index)
	end))
	Lobby.packets.KickMember.listen(guarded(function(player, userId)
		core:Kick(player, userId)
	end))
	Lobby.packets.StartShift.listen(guarded(function(player)
		core:Start(player)
	end))

	-- A member whose teleport kept failing goes back to the desktop, out of the party.
	ShiftLauncher.OnPlayerFailed(function(player, message)
		core:LaunchFailed(player, message)
	end)

	TeleportService.TeleportInitFailed:Connect(onTeleportInitFailed)
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	-- Heartbeats, polling and countdowns.
	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(core.Tick, core)
			if not ok then
				warn(`[LobbyService] party tick failed: {err}`)
			end
		end
	end)

	-- Server shutting down: take our players out of their parties so the others aren't left waiting.
	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			pcall(core.PlayerRemoving, core, player)
		end
	end)
end

return LobbyService
