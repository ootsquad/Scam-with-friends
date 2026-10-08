--[[
	Network.Career
	Your saved career (career cash, best floor, stats, equipment, first-shift checklist) and the office
	tower, in the Call Center Place.

	Client -> server
		Career.queries.Get.invoke()                        -> CareerData   (also: start sending me updates)
		Career.queries.Buy.invoke({ Kind = 1, Tier = 2 })  -> Result       Kind: index in OfficeConfig.EquipmentOrder
		Career.packets.HideTutorial.send(true)

	Server -> client
		Update     your career changed
		Elevator   the crew is moving to another floor (shown as the elevator screen)
		Chore      you finished a chore ({ Kind, Reward })
]]

local Namespace = require(script.Parent.Namespace)
local ByteNet = Namespace.ByteNet

export type CareerData = {
	Cash: number,
	BestFloor: number,
	Shifts: number,
	DaysPassed: number,
	Earned: number, -- everything you've ever earned
	Calls: number,
	Scams: number, -- callers who paid
	Chores: number,
	Headset: number, -- tier owned (OfficeConfig.Equipment)
	Computer: number,
	Router: number,
	Tutorial: number, -- bit i set = step i done (bit OfficeConfig.TutorialHiddenBit = checklist hidden)
	Persistent: boolean, -- false when the career can't be saved (e.g. Studio without API access)
}

export type Elevator = {
	Floor: number,
	Promoted: boolean, -- moved up after a review (false: just arriving)
}

export type ChoreDone = {
	Kind: string, -- "Trash" | "Desk" | "Fix"
	Reward: number,
}

export type Result = { Ok: boolean, Message: string }

return Namespace.define("Career", function()
	local CareerData = ByteNet.struct({
		Cash = ByteNet.uint32,
		BestFloor = ByteNet.uint8,
		Shifts = ByteNet.uint32,
		DaysPassed = ByteNet.uint32,
		Earned = ByteNet.uint32,
		Calls = ByteNet.uint32,
		Scams = ByteNet.uint32,
		Chores = ByteNet.uint32,
		Headset = ByteNet.uint8,
		Computer = ByteNet.uint8,
		Router = ByteNet.uint8,
		Tutorial = ByteNet.uint16,
		Persistent = ByteNet.bool,
	})
	local Purchase = ByteNet.struct({
		Kind = ByteNet.uint8,
		Tier = ByteNet.uint8,
	})
	local Result = ByteNet.struct({
		Ok = ByteNet.bool,
		Message = ByteNet.string,
	})
	local Elevator = ByteNet.struct({
		Floor = ByteNet.uint8,
		Promoted = ByteNet.bool,
	})
	local ChoreDone = ByteNet.struct({
		Kind = ByteNet.string,
		Reward = ByteNet.uint16,
	})

	return {
		packets = {
			-- client -> server
			HideTutorial = ByteNet.definePacket({ value = ByteNet.bool }),

			-- server -> client
			Update = ByteNet.definePacket({ value = CareerData }),
			Elevator = ByteNet.definePacket({ value = Elevator }),
			Chore = ByteNet.definePacket({ value = ChoreDone }),
		},
		queries = {
			Get = ByteNet.defineQuery({ request = ByteNet.nothing, response = CareerData }),
			Buy = ByteNet.defineQuery({ request = Purchase, response = Result }),
		},
	}
end)
