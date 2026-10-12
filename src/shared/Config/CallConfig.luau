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
	-- Most tokens one caller reply may use (the request's max_tokens). Clamped to what the model supports
	-- (ModelLimits); replies are short, so this is a ceiling, not a cost.
	MaxTokens = 128000,
	-- What each model supports (tokens). Unknown models get Default.
	ModelLimits = {
		Default = { Context = 200000, Output = 64000 },
		["claude-haiku-5-5"] = { Context = 1000000, Output = 128000 },
		["claude-sonnet-5-5"] = { Context = 1000000, Output = 128000 },
		["claude-opus-5-5"] = { Context = 1000000, Output = 128000 },
	} :: { [string]: { Context: number, Output: number } },
	PromptCaching = true, -- caches the caller's instructions between turns (cheaper, faster replies)
	CallMemory = 5, -- earlier calls with the same caller they remember (recap of each goes in their instructions)
	-- Print every line Roblox's text filter hid (any of) to the server output, with why. See TextFilter.
	LogFilter = true,

	UseRealAvatars = true, -- players look like their own Roblox avatars in the call center

	-- Trust (0-100). Every call starts at StartTrust; callers hang up at HangUpTrust or lower.
	StartTrust = 50,
	HangUpTrust = 5,
	MaxTurns = 12, -- cards you can pick per call before the caller has to go (ScamConfig.Picks is the same number)

	-- How sharp callers are. They start out dumber than rocks and get sharper the closer the crew gets to
	-- today's quota (From = share of the quota already made). Each level sets the trust a caller needs before
	-- they'll pay and how far one of your lines can move their trust. Pushover callers are reminded, once
	-- they're past the pay line, to pay when asked. The lobby difficulty gives the crew a head start (Intern)
	-- or a handicap (Senior) on that progress.
	Smarts = {
		{ Name = "Dumber than a rock", From = 0, PayTrust = 52, MaxGain = 30, MaxLoss = 3, Pushover = true },
		{ Name = "Gullible", From = 0.4, PayTrust = 56, MaxGain = 25, MaxLoss = 6, Pushover = true },
		{ Name = "Getting suspicious", From = 0.75, PayTrust = 65, MaxGain = 16, MaxLoss = 14, Pushover = false },
		{ Name = "Sharp", From = 1, PayTrust = 72, MaxGain = 12, MaxLoss = 18, Pushover = false },
	} :: { { Name: string, From: number, PayTrust: number, MaxGain: number, MaxLoss: number, Pushover: boolean } },
	SmartsHeadStart = { -0.15, 0, 0.15 }, -- added to quota progress for Intern, Associate, Senior

	MaxReplyLength = 280, -- caller lines stay under the 300-character text-to-speech limit
	MaxCardLength = 160, -- characters per choice card
	MaxHintLength = 90, -- characters for the hint under the cards
	-- Roblox's text filter can hide a whole caller line as ####. When at least this share of a line is hidden,
	-- the caller is asked to say it again in other words; if that's hidden too, they say a safe stock line
	-- ("Sorry, you're breaking up...") instead. A hidden line never costs you trust.
	BlockedLineShare = 0.5,

	-- Leads (the people in your Phone app)
	LeadsPerPlayer = 6,
	RingTime = { Min = 2, Max = 4 }, -- seconds an outgoing call rings
	NoAnswerChance = 0.15,
	IncomingEvery = { Min = 45, Max = 90 }, -- seconds between incoming calls while you're free
	IncomingRingTime = 15,
	ReplaceLeadAfter = 20, -- seconds before a scammed lead is replaced with a new one
	BlockedFor = 90, -- seconds a lead won't pick up after hanging up on you

	-- Work day
	DayLength = 15 * 60, -- seconds; the clock starts when the first player logs in
	ReviewTime = 12, -- seconds the performance review stays up before the next day
	FiredReturnDelay = 20, -- seconds before a fired crew is sent back to the lobby

	-- Fake caller avatars: a copy of ServerStorage.LeadRig dressed with random catalog items, a random skin tone
	-- and a random body shape. When the server starts it searches the Roblox catalog (every keyword below) to
	-- fill big item pools; the ID lists at the bottom are always in the pools too, even if the search fails.
	-- No two callers on the phones at the same time wear the same outfit, and the least-used items are
	-- picked first. Items that keep failing to load are dropped.
	Avatars = {
		SearchCatalog = true,
		-- Bodies come from catalog body bundles (the heads, torsos and limbs real players wear). The rest
		-- get the classic Roblox body with random proportions.
		BodyChance = 0.85,
		BodySearches = { "", "man", "woman", "boy", "girl", "classic" } :: { string },
		PageSize = 30, -- items per catalog page
		FirstPages = 3, -- pages for the plain search (no keyword) of each item type
		KeywordPages = 1, -- pages for each keyword search
		Searches = {
			Hair = { "", "curly", "braids", "ponytail", "bun", "messy", "spiky", "afro", "long", "short" },
			Hats = { "", "cap", "beanie", "cowboy", "bucket hat", "headphones" },
			FaceAccessories = { "", "glasses", "sunglasses", "beard" },
			NeckAccessories = { "", "scarf", "necklace", "tie" },
			ShoulderAccessories = { "" },
			BackAccessories = { "", "backpack", "wings", "guitar" },
			WaistAccessories = { "", "belt" },
			FrontAccessories = { "" },
			Shirts = { "", "hoodie", "jacket", "suit", "sweater", "flannel", "dress", "uniform", "vest", "jersey" },
			Pants = { "", "jeans", "shorts", "skirt", "sweatpants", "cargo", "overalls" },
			TShirts = { "" },
			Faces = { "" },
		} :: { [string]: { string } },
		-- Chance a caller wears something in each slot. Hair, a face, a shirt and pants are always picked.
		Chances = {
			Hats = 0.35,
			FaceAccessories = 0.25,
			NeckAccessories = 0.12,
			ShoulderAccessories = 0.08,
			BackAccessories = 0.15,
			WaistAccessories = 0.08,
			FrontAccessories = 0.06,
			TShirts = 0.3,
		} :: { [string]: number },
		-- Body shape: each HumanoidDescription scale is picked between these values.
		Scales = {
			HeightScale = { 0.9, 1.05 },
			WidthScale = { 0.75, 1 },
			DepthScale = { 0.85, 1 },
			HeadScale = { 0.95, 1 },
			BodyTypeScale = { 0, 0.3 },
			ProportionScale = { 0, 1 },
		} :: { [string]: { number } },
		-- Always in the pools.
		Hair = {
			11721248, 11721349, 11721354, 12314098, 12270336, 16131017, 11913660, 24910539, 26778066, 12519986,
			12819292, 12819326, 62234425, 13476917, 26658141,
		} :: { number },
		Hats = { 2551510151, 2535600138 } :: { number },
		FaceAccessories = { 2535420239 } :: { number },
		Faces = {
			144075659, 20418658, 7699174, 26424808, 7074764, 7074729, 7074786, 7074864, 12145366, 22877700, 20722130,
			226217449, 494291269, 4018627046,
		} :: { number },
		Shirts = {} :: { number },
		Pants = {} :: { number },
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

	-- What happened with the card you picked (Call YourLine.Status)
	LineStatus = table.freeze({
		Said = 1,
		HookLanded = 2, -- a hook card the caller went along with: the mini-game is up
		HookMissed = 3, -- a hook card the caller didn't fall for
	}),
}

return table.freeze(CallConfig)
