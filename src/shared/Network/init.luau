--[[
	Network
	Every ByteNet-Max namespace in the game, in one place. Both places (lobby and Call Center Place)
	load all of them so packet ids always line up.

	The server must require this at startup (before players can use it) so packet ids get published.
	The client requires it during boot. Add new namespaces as sibling modules and list them here.
]]

return {
	Lobby = require(script.Lobby),
	Settings = require(script.Settings),
	Shift = require(script.Shift),
	Call = require(script.Call),
	Career = require(script.Career),
	Shop = require(script.Shop),
}
