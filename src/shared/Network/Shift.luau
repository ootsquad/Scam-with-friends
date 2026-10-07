--[[
	Network.Shift
	Messages inside a crew's Call Center Place server.

	Client:  Shift.packets.LeaveShift.send()              -- back to the lobby
	Server:  Shift.packets.Notice.sendTo(message, player)

	The shift details themselves (code, difficulty, quota, crew size) are ReplicatedStorage attributes
	set by ShiftService, so they're readable the moment a client loads.
]]

local Namespace = require(script.Parent.Namespace)
local ByteNet = Namespace.ByteNet

return Namespace.define("Shift", function()
	return {
		packets = {
			-- client -> server
			LeaveShift = ByteNet.definePacket({ value = ByteNet.nothing }),

			-- server -> client
			Notice = ByteNet.definePacket({ value = ByteNet.string }),
		},
		queries = {},
	}
end)
