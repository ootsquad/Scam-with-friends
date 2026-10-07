--[[
	LobbyStore (client)
	The client's copy of "which lobby am I in, and what does it look like". The server is the source of
	truth: actions here only send requests; the state changes when the server pushes an Update.

	LobbyStore.State                      -- LobbyState? (nil = not in a lobby)
	LobbyStore.Changed:Connect(function(state, previous) end)
	LobbyStore.Notice:Connect(function(message) end)
	LobbyStore.Create() / Join(code) -> Result     (yield)
	LobbyStore.Leave() / PickDesk(n) / SetReady(bool) / SetDifficulty(i) / StartShift()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Lobby = require(Shared.Network.Lobby)
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
		LobbyStore.Notice:Fire(message)
	end)

	local initial = Lobby.queries.GetLobby.invoke(nil)
	if not receivedPush then
		apply(initial)
	end
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
	local result = query.invoke(request)
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

function LobbyStore.StartShift()
	Lobby.packets.StartShift.send(nil)
end

return LobbyStore
