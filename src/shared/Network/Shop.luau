--[[
	Network.Shop
	Robux items (ShopConfig) and what they set off, in the Call Center Place. Buying itself goes through
	Roblox (MarketplaceService); these are the messages around it.

	Client -> server
		Shop.packets.PrankTarget.send(userId)   who gets your next Prank Call (send before prompting it)
		Shop.packets.CleanVirus.send(nil)        you closed every virus pop-up at your desk
		Shop.packets.UseCallSave.send(nil)       spend a call save on your last failed call

	Server -> client
		Event     something happened to the whole office ({ Kind, By, Target, Seconds })
		          Kind: "Virus" | "Chaos" | "Prank" | "VirusOver" | "ChaosOver"
		Message   a note just for you ({ Text, Kind }) Kind: 1 info, 2 good news, 3 problem

	Your perks are player attributes (set by PerkService): Passes ("VIP,TeamLeader"), BoostPermanent,
	BoostSeconds, TeamBonus, TipsFree, TipCredits, SavesFree, CallSaves, VIP, TeamLeader, SaveableCall
	(the name of a caller you can still save, or nil).
]]

local Namespace = require(script.Parent.Namespace)
local ByteNet = Namespace.ByteNet

export type Event = {
	Kind: string,
	By: string, -- display name of who set it off
	Target: string, -- display name of who it's aimed at ("" for everyone)
	Seconds: number, -- how long it lasts (0 = until it's dealt with)
}

export type Message = {
	Text: string,
	Kind: number,
}

return Namespace.define("Shop", function()
	local Event = ByteNet.struct({
		Kind = ByteNet.string,
		By = ByteNet.string,
		Target = ByteNet.string,
		Seconds = ByteNet.uint16,
	})
	local Message = ByteNet.struct({
		Text = ByteNet.string,
		Kind = ByteNet.uint8,
	})

	return {
		packets = {
			-- client -> server
			PrankTarget = ByteNet.definePacket({ value = ByteNet.float64 }), -- UserIds can be bigger than uint32
			CleanVirus = ByteNet.definePacket({ value = ByteNet.nothing }),
			UseCallSave = ByteNet.definePacket({ value = ByteNet.nothing }),

			-- server -> client
			Event = ByteNet.definePacket({ value = Event }),
			Message = ByteNet.definePacket({ value = Message }),
		},
		queries = {},
	}
end)
