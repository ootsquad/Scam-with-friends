--[[
	Network.Call
	Desks, leads and phone calls in the Call Center Place.

	Client -> server
		Call.queries.Login.invoke("username")      -> Result   (must be sitting at a Computer seat)
		Call.packets.Logoff.send()
		Call.queries.GetLeads.invoke()             -> { Lead }
		Call.queries.StartCall.invoke(leadId)      -> Result
		Call.packets.Answer.send(true/false)       -- pick up / decline an incoming call
		Call.packets.Pick.send(cardId)             -- say one of the cards on screen
		Call.packets.Refresh.send()                -- three new cards (free twice, then a tip, then a pick)
		Call.packets.GameDone.send({ CallId, Score, Perfect })   -- the mini-game is over (Score 0-1)
		Call.packets.HangUp.send()

	Server -> client (only ever sent to the player on the call)
		State     the current call (nil = no call). Hook = the app whose mini-game is up ("" if none)
		File      the caller's file, sent when a call starts (shown in a pop-up)
		Line      something the caller said, with their new trust
		YourLine  the card you picked (Status: 1 said, 2 a hook that landed, 3 a hook that didn't)
		Cards     the three cards to pick from (Tone: ScamConfig.Tones; App: the hook's app, "" otherwise),
		          the hint under them, and how many free refreshes are left
		Game      a hook landed: play this app's mini-game (Seed for the layout, Expect = a full score's payout)
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
	LinesLeft: number, -- your picks left before the caller has to go
	Hook: string, -- the app whose mini-game is up, "" if none
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
	Weak: string, -- ScamConfig.Weaknesses key
	Wallet: number, -- about how much they could part with
	Smarts: string, -- CallConfig.Smarts name
	PayAt: number,
}

export type Line = {
	CallId: number,
	Text: string,
	Trust: number,
	Delta: number,
}

export type YourLine = {
	CallId: number,
	Text: string,
	Status: number,
}

export type Card = { Id: number, Text: string, Tone: string, App: string }

export type Cards = {
	CallId: number,
	Options: { Card },
	Hint: string,
	FreeLeft: number, -- free refreshes left this call
}

export type Game = {
	CallId: number,
	App: string,
	Tier: number,
	Seconds: number,
	Seed: number,
	Expect: number, -- what a full (1.0) score pays, before perks
}

export type GameDone = { CallId: number, Score: number, Perfect: boolean }

export type Payout = {
	App: string, -- ScamConfig app key
	Label: string, -- the app's name
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
		Hook = ByteNet.string,
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
		Weak = ByteNet.string,
		Wallet = ByteNet.uint32,
		Smarts = ByteNet.string,
		PayAt = ByteNet.uint8,
	})

	local Line = ByteNet.struct({
		CallId = ByteNet.uint32,
		Text = ByteNet.string,
		Trust = ByteNet.uint8,
		Delta = ByteNet.int8,
	})

	local YourLine = ByteNet.struct({
		CallId = ByteNet.uint32,
		Text = ByteNet.string,
		Status = ByteNet.uint8,
	})

	local Card = ByteNet.struct({
		Id = ByteNet.uint16,
		Text = ByteNet.string,
		Tone = ByteNet.string,
		App = ByteNet.string,
	})

	local Cards = ByteNet.struct({
		CallId = ByteNet.uint32,
		Options = ByteNet.array(Card),
		Hint = ByteNet.string,
		FreeLeft = ByteNet.uint8,
	})

	local Game = ByteNet.struct({
		CallId = ByteNet.uint32,
		App = ByteNet.string,
		Tier = ByteNet.uint8,
		Seconds = ByteNet.uint8,
		Seed = ByteNet.uint32,
		Expect = ByteNet.uint32,
	})

	local GameDone = ByteNet.struct({
		CallId = ByteNet.uint32,
		Score = ByteNet.float32,
		Perfect = ByteNet.bool,
	})

	local Payout = ByteNet.struct({
		App = ByteNet.string,
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

	return {
		packets = {
			-- client -> server
			Logoff = ByteNet.definePacket({ value = ByteNet.nothing }),
			Answer = ByteNet.definePacket({ value = ByteNet.bool }),
			Pick = ByteNet.definePacket({ value = ByteNet.uint16 }),
			Refresh = ByteNet.definePacket({ value = ByteNet.nothing }),
			GameDone = ByteNet.definePacket({ value = GameDone }),
			HangUp = ByteNet.definePacket({ value = ByteNet.nothing }),

			-- server -> client
			State = ByteNet.definePacket({ value = ByteNet.optional(CallState) }),
			File = ByteNet.definePacket({ value = CallerFile }),
			Line = ByteNet.definePacket({ value = Line }),
			YourLine = ByteNet.definePacket({ value = YourLine }),
			Cards = ByteNet.definePacket({ value = Cards }),
			Game = ByteNet.definePacket({ value = Game }),
			Payout = ByteNet.definePacket({ value = Payout }),
			Leads = ByteNet.definePacket({ value = ByteNet.array(Lead) }),
			Notice = ByteNet.definePacket({ value = ByteNet.string }),
		},
		queries = {
			Login = ByteNet.defineQuery({ request = ByteNet.string, response = Result }),
			GetLeads = ByteNet.defineQuery({ request = ByteNet.nothing, response = ByteNet.array(Lead) }),
			StartCall = ByteNet.defineQuery({ request = ByteNet.uint16, response = Result }),
		},
	}
end)
