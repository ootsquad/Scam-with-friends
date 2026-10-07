--!strict
--[[
	LobbyConfig
	Rules for crew lobbies. The server enforces them; the client uses them for labels.
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
		{ Name = "Intern", Quota = 450, Growth = 0.3 },
		{ Name = "Associate", Quota = 600, Growth = 0.4 },
		{ Name = "Senior", Quota = 800, Growth = 0.5 },
	} :: { Difficulty },
	DefaultDifficulty = 2,

	Phase = table.freeze({
		Lobby = 1, -- picking desks / readying up
		Starting = 2, -- host pressed start, countdown running
		Teleporting = 3, -- crew is being sent to their private Call Center Place server
	}),
	StartCountdown = 3, -- seconds between "Start shift" and the shift beginning
	ActionCooldown = 0.2, -- min seconds between lobby requests from one player

	CodeLength = 6,
	CodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789", -- no 0/O or 1/I to avoid misreads

	-- Cross-server "Join with Code" (live game only; Studio has no JobId to teleport to)
	DirectoryName = "LobbyCodes",
	DirectoryTTL = 120, -- seconds a code stays listed without a refresh
	DirectoryRefresh = 60,
}

return table.freeze(LobbyConfig)
