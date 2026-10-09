--!strict
--[[
	LobbyConfig
	Rules for crew parties. The server enforces them; the client uses them for labels.

	Parties work across servers: every player plays the lobby in their own server, a party lives in
	MemoryStore, and MessagingService tells members' servers when it changes (see PartyCore).
]]

export type Difficulty = {
	Name: string,
	Quota: number, -- day 1 quota in dollars
	Growth: number, -- quota growth per day (0.4 = +40%)
}

local LobbyConfig = {
	MaxDesks = 4,
	DeskNames = { "Window", "Printer", "Coffee", "Boss's door" },

	Difficulties = {
		{ Name = "Intern", Quota = 700, Growth = 0.3 },
		{ Name = "Associate", Quota = 900, Growth = 0.4 },
		{ Name = "Senior", Quota = 1200, Growth = 0.5 },
	} :: { Difficulty },
	DefaultDifficulty = 2,

	Phase = table.freeze({
		Lobby = 1, -- picking desks / readying up
		Starting = 2, -- host pressed start, countdown running
		Teleporting = 3, -- crew is being sent to their private Call Center Place server
	}),
	StartCountdown = 5, -- seconds between "Start shift" and the shift beginning
	ActionCooldown = 0.2, -- min seconds between lobby requests from one player

	CodeLength = 6,
	CodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789", -- no 0/O or 1/I to avoid misreads

	-- Cross-server parties
	PartyStore = "Parties", -- MemoryStore HashMap holding every party, keyed by code
	PartyTopicPrefix = "Party_", -- MessagingService topic per party
	PartyTTL = 600, -- seconds a party record lives if no member's server touches it (everyone gone)
	HeartbeatInterval = 15, -- each member's server checks in this often
	PollInterval = 5, -- and re-reads the party this often, in case a message was lost
	StaleAfter = 45, -- a member whose server hasn't checked in for this long is dropped
	KickCooldown = 300, -- seconds before a removed player can rejoin that party
	LaunchTimeout = 20, -- a countdown the leader's server never launched is cancelled after this
	-- Move a player who lands in a lobby server with someone else in it to a lobby of their own. Setting the
	-- lobby place's Max Players to 1 (Creator Dashboard) does this without the extra teleport.
	SoloLobbies = true,
}

return table.freeze(LobbyConfig)
