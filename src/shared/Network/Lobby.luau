--[[
	Network.Lobby
	Everything parties send over the wire, defined once for both sides. A party spans several servers (see
	PartyCore); each player's own lobby server sends them their party.

	Client -> server packets:   Lobby.packets.PickDesk.send(3)
	Server -> client packets:   Lobby.packets.Update.sendTo(state, player)   (nil = you're not in a lobby)
	Queries (client asks, server answers):   local result = Lobby.queries.JoinLobby.invoke("7KX2QD")
]]

local Namespace = require(script.Parent.Namespace)
local ByteNet = Namespace.ByteNet

export type Seat = {
	Desk: number,
	UserId: number,
	DisplayName: string,
	Username: string,
	Ready: boolean,
}

export type LobbyState = {
	Revision: number, -- increases on every change; clients drop anything older than what they have
	Code: string,
	Phase: number, -- LobbyConfig.Phase
	HostUserId: number,
	Difficulty: number, -- index into LobbyConfig.Difficulties
	Countdown: number,
	Seats: { Seat }, -- occupied desks only
}

export type Result = {
	Ok: boolean,
	Message: string,
}

return Namespace.define("Lobby", function()
	-- Structs must be created in the same order on server and client, so they live inside this callback.
	local Seat = ByteNet.struct({
		Desk = ByteNet.uint8,
		-- float64 rather than uint32: Studio test players have negative ids and real ids keep growing.
		UserId = ByteNet.float64,
		DisplayName = ByteNet.string,
		Username = ByteNet.string,
		Ready = ByteNet.bool,
	})

	local LobbyState = ByteNet.struct({
		Revision = ByteNet.uint32,
		Code = ByteNet.string,
		Phase = ByteNet.uint8,
		HostUserId = ByteNet.float64,
		Difficulty = ByteNet.uint8,
		Countdown = ByteNet.uint8,
		Seats = ByteNet.array(Seat),
	})

	local Result = ByteNet.struct({
		Ok = ByteNet.bool,
		Message = ByteNet.string,
	})

	return {
		packets = {
			-- client -> server
			LeaveLobby = ByteNet.definePacket({ value = ByteNet.nothing }),
			PickDesk = ByteNet.definePacket({ value = ByteNet.uint8 }),
			SetReady = ByteNet.definePacket({ value = ByteNet.bool }),
			SetDifficulty = ByteNet.definePacket({ value = ByteNet.uint8 }),
			StartShift = ByteNet.definePacket({ value = ByteNet.nothing }),
			KickMember = ByteNet.definePacket({ value = ByteNet.float64 }), -- leader removes this user

			-- server -> client
			Update = ByteNet.definePacket({ value = ByteNet.optional(LobbyState) }),
			Notice = ByteNet.definePacket({ value = ByteNet.string }),
		},
		queries = {
			-- Current lobby (or nil). Also subscribes the caller to Update packets.
			GetLobby = ByteNet.defineQuery({ request = ByteNet.nothing, response = ByteNet.optional(LobbyState) }),
			CreateLobby = ByteNet.defineQuery({ request = ByteNet.nothing, response = Result }),
			JoinLobby = ByteNet.defineQuery({ request = ByteNet.string, response = Result }),
		},
	}
end)
