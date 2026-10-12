--[[
	Network.Scam
	The scam apps and the Scamazon store, in the Call Center Place. Apps are bought with shift cash
	(the ShiftBalance player attribute) and reset every shift.

	Client -> server
		Scam.queries.Buy.invoke({ App = "PopUpPalace", Tier = 1 })  -> Result   buy (tier 1) or upgrade (2, 3)
		Scam.queries.GetApps.invoke()                                -> { Owned }  what you own right now

	Server -> client
		Apps      what you own changed ({ { App, Tier } })
]]

local Namespace = require(script.Parent.Namespace)
local ByteNet = Namespace.ByteNet

export type Owned = { App: string, Tier: number }

export type Result = { Ok: boolean, Message: string }

return Namespace.define("Scam", function()
	local Owned = ByteNet.struct({
		App = ByteNet.string,
		Tier = ByteNet.uint8,
	})
	local Purchase = ByteNet.struct({
		App = ByteNet.string,
		Tier = ByteNet.uint8,
	})
	local Result = ByteNet.struct({
		Ok = ByteNet.bool,
		Message = ByteNet.string,
	})
	return {
		packets = {
			Apps = ByteNet.definePacket({ value = ByteNet.array(Owned) }),
		},
		queries = {
			Buy = ByteNet.defineQuery({ request = Purchase, response = Result }),
			GetApps = ByteNet.defineQuery({ request = ByteNet.nothing, response = ByteNet.array(Owned) }),
		},
	}
end)
