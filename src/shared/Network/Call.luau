--[[
	Network.Call
	Desks, leads and phone calls in the Call Center Place.

	Client -> server
		Call.queries.Login.invoke("username")      -> Result   (must be sitting at a Computer seat)
		Call.packets.Logoff.send()
		Call.queries.GetLeads.invoke()             -> { Lead }
		Call.queries.StartCall.invoke(leadId)      -> Result
		Call.packets.Answer.send(true/false)       -- pick up / decline an incoming call
		Call.packets.Say.send("text")              -- typed, spoken (speech-to-text) or Roblox chat
		Call.packets.HangUp.send()
		Call.queries.RedeemGiftCard.invoke("K7Q2-9XMB-4RTA")              -> Result
		Call.queries.ChargeCard.invoke({ Number, Exp, Cvv, Amount })     -> Result

	Server -> client (only ever sent to the player on the call)
		State     the current call (nil = no call)
		File      the caller's file, sent when a call starts (shown in a pop-up)
		Line      something the caller said, with their new trust
		YourLine  what you said, after Roblox's text filter
		Payout    the caller paid
		Leads     your lead list changed
		Notice    a message for the desktop
]]

local Namespace = require(script.Parent.Namespace)
local ByteNet = Namespace.ByteNet

export type Look = {
	Skin: Color3,
	Shirt: Color3,
	Pants: Color3,
	Hat: number, -- 0 = none, see LeadAvatar
	HatColor: Color3,
}

export type Lead = {
	Id: number,
	DisplayName: string,
	Username: string,
	Tag: string, -- e.g. "Retired teacher"
	Status: number, -- CallConfig.LeadStatus
	Look: Look,
}

export type CallState = {
	CallId: number,
	Lead: Lead,
	Phase: number, -- CallConfig.Phase
	Trust: number,
	Outcome: number, -- CallConfig.Outcome
	VoiceId: string,
	Thinking: boolean, -- the caller is working out what to say
	Paid: boolean,
	PayAt: number, -- trust this caller needs before they'll pay
	LinesLeft: number, -- your lines left before the caller has to go
}

export type CallerFile = {
	CallId: number,
	About: string, -- "71 · Dayton, Ohio"
	Hobbies: string,
	Pet: string,
	Family: string,
	Lately: string,
	Tech: string,
	SoftSpot: string,
	RedFlag: string,
	Methods: { string }, -- "gift_card" | "card" | "donation"
	Wallet: number, -- about how much they could part with
	Smarts: string, -- CallConfig.Smarts name
	PayAt: number,
}

export type Line = {
	CallId: number,
	Text: string,
	Trust: number,
	Delta: number,
	Method: string, -- payment handed over in this line ("gift_card" | "card" | "donation"), "" if none
}

export type Payout = {
	Method: string,
	Label: string,
	Detail: string,
	Amount: number, -- what you got, bonus included
	Bonus: number, -- floor and router bonus included in Amount
	LeadName: string,
}

export type Result = {
	Ok: boolean,
	Message: string,
}

return Namespace.define("Call", function()
	local Look = ByteNet.struct({
		Skin = ByteNet.color3,
		Shirt = ByteNet.color3,
		Pants = ByteNet.color3,
		Hat = ByteNet.uint8,
		HatColor = ByteNet.color3,
	})

	local Lead = ByteNet.struct({
		Id = ByteNet.uint16,
		DisplayName = ByteNet.string,
		Username = ByteNet.string,
		Tag = ByteNet.string,
		Status = ByteNet.uint8,
		Look = Look,
	})

	local CallState = ByteNet.struct({
		CallId = ByteNet.uint32,
		Lead = Lead,
		Phase = ByteNet.uint8,
		Trust = ByteNet.uint8,
		Outcome = ByteNet.uint8,
		VoiceId = ByteNet.string,
		Thinking = ByteNet.bool,
		Paid = ByteNet.bool,
		PayAt = ByteNet.uint8,
		LinesLeft = ByteNet.uint8,
	})

	local CallerFile = ByteNet.struct({
		CallId = ByteNet.uint32,
		About = ByteNet.string,
		Hobbies = ByteNet.string,
		Pet = ByteNet.string,
		Family = ByteNet.string,
		Lately = ByteNet.string,
		Tech = ByteNet.string,
		SoftSpot = ByteNet.string,
		RedFlag = ByteNet.string,
		Methods = ByteNet.array(ByteNet.string),
		Wallet = ByteNet.uint32,
		Smarts = ByteNet.string,
		PayAt = ByteNet.uint8,
	})

	local Line = ByteNet.struct({
		CallId = ByteNet.uint32,
		Text = ByteNet.string,
		Trust = ByteNet.uint8,
		Delta = ByteNet.int8,
		Method = ByteNet.string,
	})

	local YourLine = ByteNet.struct({
		CallId = ByteNet.uint32,
		Text = ByteNet.string,
	})

	local Payout = ByteNet.struct({
		Method = ByteNet.string,
		Label = ByteNet.string,
		Detail = ByteNet.string,
		Amount = ByteNet.uint32,
		Bonus = ByteNet.uint32,
		LeadName = ByteNet.string,
	})

	local Result = ByteNet.struct({
		Ok = ByteNet.bool,
		Message = ByteNet.string,
	})

	local Charge = ByteNet.struct({
		Number = ByteNet.string,
		Exp = ByteNet.string,
		Cvv = ByteNet.string,
		Amount = ByteNet.uint32,
	})

	return {
		packets = {
			-- client -> server
			Logoff = ByteNet.definePacket({ value = ByteNet.nothing }),
			Answer = ByteNet.definePacket({ value = ByteNet.bool }),
			Say = ByteNet.definePacket({ value = ByteNet.string }),
			HangUp = ByteNet.definePacket({ value = ByteNet.nothing }),

			-- server -> client
			State = ByteNet.definePacket({ value = ByteNet.optional(CallState) }),
			File = ByteNet.definePacket({ value = CallerFile }),
			Line = ByteNet.definePacket({ value = Line }),
			YourLine = ByteNet.definePacket({ value = YourLine }),
			Payout = ByteNet.definePacket({ value = Payout }),
			Leads = ByteNet.definePacket({ value = ByteNet.array(Lead) }),
			Notice = ByteNet.definePacket({ value = ByteNet.string }),
		},
		queries = {
			Login = ByteNet.defineQuery({ request = ByteNet.string, response = Result }),
			GetLeads = ByteNet.defineQuery({ request = ByteNet.nothing, response = ByteNet.array(Lead) }),
			StartCall = ByteNet.defineQuery({ request = ByteNet.uint16, response = Result }),
			RedeemGiftCard = ByteNet.defineQuery({ request = ByteNet.string, response = Result }),
			ChargeCard = ByteNet.defineQuery({ request = Charge, response = Result }),
		},
	}
end)
