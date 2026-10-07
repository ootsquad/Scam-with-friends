--!strict
--[[
	Places
	The places that make up Call Center Chaos and how shifts move between them.

	Lobby       the start place (this project's default.project.json). Players boot into ChaOS here.
	CallCenter  "Call Center Place" (callcenter.project.json). Each crew gets its own private (reserved)
	            server of it; Roblox shuts that server down once the crew has left.
]]

local Places = {
	-- Start place id. Shifts already know where they came from, so this is only used to send back players
	-- who reach the Call Center Place without a crew. Fill it in from the Creator Dashboard
	-- (0 = kick them with a message instead).
	Lobby = 0,
	CallCenter = 120521915270020,

	-- MemoryStore map where the lobby server leaves each crew's shift details, keyed by the
	-- reserved server's PrivateServerId, so the call center server can read them securely.
	ShiftInfoMap = "ShiftInfo",
	ShiftInfoTTL = 60 * 60,

	TeleportAttempts = 3,
}

return table.freeze(Places)
