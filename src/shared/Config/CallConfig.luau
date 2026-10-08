--!strict
--[[
	CallConfig
	Tunables for the Call Center Place: the AI callers, trust, leads, payouts and the work day.
]]

local CallConfig = {
	-- Claude (server only). The API key lives in a StringValue in ServerStorage with this name.
	Model = "claude-haiku-5-5",
	ApiKeyValue = "claude-haiku-5-5 API",
	Endpoint = "https://api.anthropic.com/v1/messages",
	ApiVersion = "2023-06-01",
	MaxTokens = 300,

	-- Trust (0-100). Every call starts at StartTrust; callers only pay at PayTrust or above.
	StartTrust = 50,
	PayTrust = 70,
	HangUpTrust = 10,
	MaxTrustGain = 15, -- per line
	MaxTrustLoss = 25, -- per line
	MaxTurns = 20, -- your lines per call before the caller has to go

	MaxSayLength = 300, -- characters per line you say
	MaxReplyLength = 280, -- caller lines stay under the 300-character text-to-speech limit

	-- Your mic (speech-to-text). What it hears only becomes a line if it sounds like you really talked, so
	-- mouse clicks, desk bumps and the caller's voice coming out of your speakers don't put words in your mouth.
	-- In Studio, the Output window says why each ignored transcript was dropped.
	Mic = {
		MinVoiceSeconds = 0.4, -- Roblox has to detect a voice for at least this long
		MaxWordsPerSecond = 6, -- more words than this per second of voice means the transcriber is guessing
		ExtraWords = 3, -- slack on top of MaxWordsPerSecond for short lines
		MinWordsUnchecked = 2, -- on a device that never reports a voice, lines need at least this many words
		EchoTail = 3, -- seconds after the caller's voice stops that their words still count as echo
		EchoShare = 0.75, -- share of your words matching the caller's line for it to count as echo
	},

	-- Leads (the people in your Phone app)
	LeadsPerPlayer = 6,
	RingTime = { Min = 2, Max = 4 }, -- seconds an outgoing call rings
	NoAnswerChance = 0.15,
	IncomingEvery = { Min = 45, Max = 90 }, -- seconds between incoming calls while you're free
	IncomingRingTime = 15,
	ReplaceLeadAfter = 20, -- seconds before a scammed lead is replaced with a new one
	BlockedFor = 90, -- seconds a lead won't pick up after hanging up on you

	-- Work day
	DayLength = 8 * 60, -- seconds; the clock starts when the first player logs in
	ReviewTime = 12, -- seconds the performance review stays up before the next day
	FiredReturnDelay = 20, -- seconds before a fired crew is sent back to the lobby

	-- How callers can pay. Label is shown in the apps; Max caps one payment.
	--   gift_card  they buy a gift card and read you the code -> redeem it in the Gift Cards app
	--   card       they read you their card details           -> charge it in the Card Terminal app
	--   donation   they donate to your fake fundraiser        -> they need your fundraiser ID first
	PaymentMethods = {
		gift_card = { Label = "Gift card", Max = 500 },
		card = { Label = "Credit card", Max = 2000 },
		donation = { Label = "Donation", Max = 800 },
	} :: { [string]: { Label: string, Max: number } },
	MethodOrder = { "gift_card", "card", "donation" },
	DeclinesBeforeFreeze = 2, -- declined charges before a card is frozen

	-- Fake caller avatars: a copy of ServerStorage.LeadRig dressed with random catalog items.
	-- These lists are always used; with SearchCatalog on, the server also pulls more from the Roblox catalog.
	Avatars = {
		SearchCatalog = true,
		Hair = {
			11721248, 11721349, 11721354, 12314098, 12270336, 16131017, 11913660, 24910539, 26778066, 12519986,
			12819292, 12819326, 62234425, 13476917, 26658141,
		},
		Hats = { 2551510151, 2535600138 },
		FaceAccessories = { 2535420239 },
		Faces = {
			144075659, 20418658, 7699174, 26424808, 7074764, 7074729, 7074786, 7074864, 12145366, 22877700, 20722130,
			226217449, 494291269, 4018627046,
		},
		Shirts = {} :: { number },
		Pants = {} :: { number },
		HatChance = 0.35,
		FaceAccessoryChance = 0.15,
	},

	LeadStatus = table.freeze({
		Available = 1,
		OnCall = 2,
		Scammed = 3,
		Blocked = 4, -- hung up on you; won't pick up for a while
	}),

	Phase = table.freeze({
		Ringing = 1, -- you're calling them
		Incoming = 2, -- they're calling you
		Connected = 3,
		Ended = 4,
	}),

	Outcome = table.freeze({
		None = 0,
		Paid = 1,
		TheyHungUp = 2,
		NoAnswer = 3,
		Missed = 4,
		Declined = 5,
		YouHungUp = 6,
		LineDown = 7, -- the AI couldn't be reached
	}),
}

return table.freeze(CallConfig)
