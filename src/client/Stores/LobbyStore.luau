--[[
	LobbyStore (client)
	The client's copy of "which party am I in, and what does it look like". A party spans several servers;
	this player's lobby server keeps it in sync and pushes every change here (Update). Actions only send
	requests; the state changes when the server pushes.

	LobbyStore.State                      -- LobbyState? (nil = not in a lobby)
	LobbyStore.Changed:Connect(function(state, previous) end)
	LobbyStore.ListenForNotices(function(message) end)   -- also gets notices sent before the desktop was up
	LobbyStore.Create() / Join(code) -> Result     (yield)
	LobbyStore.Leave() / PickDesk(n) / SetReady(bool) / SetDifficulty(i) / Kick(userId) / StartShift()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Lobby = require(Shared.Network.Lobby)
local Namespace = require(Shared.Network.Namespace)
local Signal = require(Shared.Util.Signal)

type LobbyState = Lobby.LobbyState
type Seat = Lobby.Seat
type Result = Lobby.Result

local player = Players.LocalPlayer

local LobbyStore = {
	State = nil :: LobbyState?,
	Changed = Signal.new(),
	Notice = Signal.new(),
}

local receivedPush = false
-- Notices that arrived before anything listened (e.g. "Joined party ..." for an invite, sent while the desktop
-- was still loading). nil once handed over.
local pendingNotices: { string }? = {}

local function apply(state: LobbyState?)
	local current = LobbyStore.State
	-- Pushes and query replies can arrive out of order; ignore older revisions of the same lobby.
	if state and current and state.Code == current.Code and state.Revision < current.Revision then
		return
	end
	LobbyStore.State = state
	LobbyStore.Changed:Fire(state, current)
end

function LobbyStore.Start()
	Lobby.packets.Update.listen(function(state: LobbyState?)
		receivedPush = true
		apply(state)
	end)
	Lobby.packets.Notice.listen(function(message: string)
		if pendingNotices then
			table.insert(pendingNotices, message)
		else
			LobbyStore.Notice:Fire(message)
		end
	end)

	local initial = Namespace.invoke(Lobby.queries.GetLobby, nil)
	if not receivedPush then
		apply(initial)
	end
end

function LobbyStore.ListenForNotices(handler: (string) -> ())
	local connection = LobbyStore.Notice:Connect(handler)
	local pending = pendingNotices
	pendingNotices = nil
	for _, message in pending or {} do
		task.spawn(handler, message)
	end
	return connection
end

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

function LobbyStore.InLobby(): boolean
	return LobbyStore.State ~= nil
end

function LobbyStore.MySeat(): Seat?
	local state = LobbyStore.State
	if state then
		for _, seat in state.Seats do
			if seat.UserId == player.UserId then
				return seat
			end
		end
	end
	return nil
end

function LobbyStore.IsHost(): boolean
	local state = LobbyStore.State
	return state ~= nil and state.HostUserId == player.UserId
end

function LobbyStore.SeatAt(desk: number): Seat?
	local state = LobbyStore.State
	if state then
		for _, seat in state.Seats do
			if seat.Desk == desk then
				return seat
			end
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

local function invoke(query: any, request: any): Result
	local result = Namespace.invoke(query, request)
	if type(result) ~= "table" then
		return { Ok = false, Message = "The server didn't answer. Try again." }
	end
	return result
end

function LobbyStore.Create(): Result
	return invoke(Lobby.queries.CreateLobby, nil)
end

function LobbyStore.Join(code: string): Result
	return invoke(Lobby.queries.JoinLobby, code)
end

function LobbyStore.Leave()
	Lobby.packets.LeaveLobby.send(nil)
end

function LobbyStore.PickDesk(desk: number)
	Lobby.packets.PickDesk.send(desk)
end

function LobbyStore.SetReady(ready: boolean)
	Lobby.packets.SetReady.send(ready)
end

function LobbyStore.SetDifficulty(index: number)
	Lobby.packets.SetDifficulty.send(index)
end

function LobbyStore.Kick(userId: number)
	Lobby.packets.KickMember.send(userId)
end

function LobbyStore.StartShift()
	Lobby.packets.StartShift.send(nil)
end

return LobbyStore
