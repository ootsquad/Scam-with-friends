--[[
	Network.Shift
	Messages inside a crew's Call Center Place server.

	Client:  Shift.packets.LeaveShift.send()              -- back to the lobby
	Server:  Shift.packets.Notice.sendTo(message, player)
	         Shift.packets.Review.sendToAll(review)        -- end-of-day performance review

	The shift itself (code, difficulty, day, quota, team money, day timer) is published as
	ReplicatedStorage attributes by ShiftService/EconomyService, so it's readable as soon as a client loads.
]]

local Namespace = require(script.Parent.Namespace)
local ByteNet = Namespace.ByteNet

export type Review = {
	Day: number,
	Team: number,
	Quota: number,
	Passed: boolean,
	TopName: string, -- top earner's display name ("" if nobody earned anything)
	TopAmount: number,
	NextQuota: number, -- 0 when the crew was fired
	Tips: { string }, -- for this player, based on how their day went
}

return Namespace.define("Shift", function()
	local Review = ByteNet.struct({
		Day = ByteNet.uint8,
		Team = ByteNet.uint32,
		Quota = ByteNet.uint32,
		Passed = ByteNet.bool,
		TopName = ByteNet.string,
		TopAmount = ByteNet.uint32,
		NextQuota = ByteNet.uint32,
		Tips = ByteNet.array(ByteNet.string),
	})

	return {
		packets = {
			-- client -> server
			LeaveShift = ByteNet.definePacket({ value = ByteNet.nothing }),

			-- server -> client
			Notice = ByteNet.definePacket({ value = ByteNet.string }),
			Review = ByteNet.definePacket({ value = Review }),
		},
		queries = {},
	}
end)
