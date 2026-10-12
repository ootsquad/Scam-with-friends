--!strict
--[[
	ScamConfig
	The scamming part of the game: the choice cards on calls, the hooks that turn a call into money, the scam
	apps (each with a short, easy mini-game) and the Scamazon store that sells them.

	A call goes: pick a card each turn (three ready-made lines from the AI) -> once trust is past the pay
	line a HOOK card shows up for every app you own -> the caller says yes -> the app's mini-game takes the
	money. Nothing is ever typed, and nothing in here is real: every "site" is an obviously silly fake.

	Mini-game scores run from MinScore (you can't lose) to 1, or PerfectScore for a perfect run:
	  payout = caller's Can-spare x score x app tier bonus x weakness match x floor perk x router perk

	ScamConfig.App(key) -> App?
	ScamConfig.Weakness(key) -> Weakness?
]]

export type Weakness = { Key: string, Label: string, Blurb: string, Color: string }

export type Tier = { Name: string, Bonus: number, Help: string }

export type App = {
	Key: string,
	Name: string,
	Pitch: string, -- one line on the store card
	Hook: string, -- what you say to get them in (the hook card)
	Weak: string, -- Weakness key this hook plays on
	Price: number, -- tier 1, shift cash (0 = everyone starts with it)
	Game: string, -- which mini-game (ScamGames on the client)
	HowTo: string, -- one sentence, shown before the mini-game
	Seconds: number, -- how long the mini-game runs (Pro adds ExtraSeconds)
	Color: string, -- the app tile
	Reviews: { string },
}

local ScamConfig = {
	Cards = 3, -- choice cards per turn
	Picks = 12, -- cards you can pick per call (your lines)
	FreeRefreshes = 2, -- free card refreshes per call; after that a refresh uses an on-call tip, then a pick
	HookMargin = 10, -- a hook that doesn't match still lands when trust is this far past the pay line
	HookMismatchTrust = -8, -- trust lost when a hook doesn't land
	MatchBonus = 0.25, -- +25% when the hook matches the caller's weakness
	MinScore = 0.4, -- a mini-game always pays at least this share
	PerfectScore = 1.2,
	PerfectAt = 0.98, -- raw performance that counts as perfect
	ExtraSeconds = 3, -- Pro and Elite get this much longer
	MaxGameSeconds = 40, -- the server stops waiting for a score after this
	Tones = { "Friendly", "Story", "Push", "Small talk", "Hook" },

	Weaknesses = {
		{ Key = "Tech", Label = "Tech", Blurb = "believes anything about computers", Color = "#2563EB" },
		{ Key = "Greed", Label = "Greed", Blurb = "prizes, crypto and refunds", Color = "#CA8A04" },
		{ Key = "Fear", Label = "Fear", Blurb = "viruses, the tax office, the bank", Color = "#DC2626" },
		{ Key = "Heart", Label = "Heart", Blurb = "romance and charity", Color = "#DB2777" },
		{ Key = "Shopping", Label = "Shopping", Blurb = "parcels, gift cards, subscriptions", Color = "#059669" },
	} :: { Weakness },

	Tiers = {
		{ Name = "Basic", Bonus = 1, Help = "" },
		{ Name = "Pro", Bonus = 1.2, Help = "+20% payout, a little longer and easier" },
		{ Name = "Elite", Bonus = 1.5, Help = "+50% payout and a helper that plays along" },
	} :: { Tier },
	UpgradeCost = { 2, 4 }, -- Pro and Elite cost the buy price x this

	-- Starter apps are free; everything else is bought in Scamazon with shift cash and reset each shift.
	Apps = {
		{
			Key = "CardSwiper", Name = "Card Swiper", Pitch = "Swipe. Smile. Steal.",
			Hook = "Just swipe your card so I can confirm it's you.", Weak = "Shopping", Price = 0,
			Game = "Swipe", HowTo = "Drag the card through the slot: smooth and straight scores best.",
			Seconds = 15, Color = "#0F766E",
			Reviews = { "Swiped my own card by accident. Still 5 stars. — Doris, 71", "Works great, very smooth. — a satisfied swiper" },
		},
		{
			Key = "WalletDrop", Name = "WalletDrop", Pitch = "Tap to pay. Tap to take.",
			Hook = "Tap your card on the phone to link it.", Weak = "Shopping", Price = 0,
			Game = "Drop", HowTo = "Drag the card into the wallet three times. The wallet likes to move.",
			Seconds = 15, Color = "#7C3AED",
			Reviews = { "The wallet keeps moving. Is that a feature? — Gary", "My grandson set this up for me. — Doris, 71" },
		},
		{
			Key = "RemoteDesk", Name = "RemoteDesk", Pitch = "Their laptop, your mouse.",
			Hook = "Let me into your laptop and I'll fix it for you.", Weak = "Tech", Price = 180,
			Game = "Clicker", HowTo = "Cash icons pop up on their desktop. Click as many as you can.",
			Seconds = 15, Color = "#1D4ED8",
			Reviews = { "Clicked so much my mouse needs a holiday. — Pat", "10/10 would remote again. — Kevin from IT" },
		},
		{
			Key = "PopUpPalace", Name = "PopUp Palace", Pitch = "Your PC has 47 viruses! (It doesn't.)",
			Hook = "Your computer's infected. I'm sending the cleaner over now.", Weak = "Fear", Price = 90,
			Game = "PopUps", HowTo = "Fake virus warnings keep popping up. Click the X on each one.",
			Seconds = 15, Color = "#B91C1C",
			Reviews = { "So many pop-ups. So much money. — Linda", "Scared me and I'm the scammer. — Raj" },
		},
		{
			Key = "Worm", Name = "Worm", Pitch = "One tiny update. One hungry worm.",
			Hook = "Install this tiny update. It's one click, I promise.", Weak = "Tech", Price = 140,
			Game = "Snake", HowTo = "Steer the worm through their files and eat the coins. Walls just slow you down.",
			Seconds = 18, Color = "#15803D",
			Reviews = { "Finally, snake but for crime. — Nokia fan", "The worm is adorable. — Doris, 71" },
		},
		{
			Key = "ScratchIt", Name = "ScratchIt", Pitch = "Every card's a winner. For you.",
			Hook = "Read me the code under the silver bit on the back.", Weak = "Shopping", Price = 60,
			Game = "Scratch", HowTo = "Scratch off the silver to reveal the code. It redeems itself.",
			Seconds = 15, Color = "#A16207",
			Reviews = { "Satisfying scratchy noises. — Mo", "Found a code AND a coupon. — Pat" },
		},
		{
			Key = "PrizeWheelz", Name = "PrizeWheelz", Pitch = "You've won! Pay here to collect.",
			Hook = "Congratulations, you've won! There's just a small processing fee.", Weak = "Greed", Price = 120,
			Game = "Wheel", HowTo = "Hold to charge, release to spin. The wedge it lands on is the payout.",
			Seconds = 15, Color = "#C026D3",
			Reviews = { "Spun it 40 times. Still winning. — Gary", "Wheel of fortune, hold the fortune. — Linda" },
		},
		{
			Key = "CryptoCoinz", Name = "CryptoCoinz", Pitch = "To the moon! (Your moon.)",
			Hook = "I'll get you in before the price takes off. Trust me.", Weak = "Greed", Price = 250,
			Game = "Crypto", HowTo = "The price climbs and dips. Click once to sell: closer to the top pays more.",
			Seconds = 15, Color = "#EA580C",
			Reviews = { "Sold at the top. Felt like a wizard. — Raj", "My coin is called DorisCoin now. — Doris, 71" },
		},
		{
			Key = "RefundMe", Name = "RefundMe", Pitch = "We owe you money. Sign here.",
			Hook = "Good news, we owe you a refund! I'll just need the form stamped.", Weak = "Greed", Price = 100,
			Game = "Stamp", HowTo = "Forms slide by. Click when the stamp is over the box.",
			Seconds = 15, Color = "#4F46E5",
			Reviews = { "STAMP STAMP STAMP. — Mo", "Very official. Too official. — Pat" },
		},
		{
			Key = "ParcelPal", Name = "ParcelPal", Pitch = "Your parcel is stuck. Pay the fee.",
			Hook = "Your parcel's held at customs. There's a small release fee.", Weak = "Shopping", Price = 80,
			Game = "Parcels", HowTo = "Swipe each parcel left or right into the truck of the same colour.",
			Seconds = 15, Color = "#B45309",
			Reviews = { "I sorted 30 parcels and none were mine. — Kevin", "Trucks go vroom. — Gary" },
		},
		{
			Key = "LoveLetter", Name = "LoveLetter", Pitch = "Darling, my flight got cancelled...",
			Hook = "Darling, my flight home got cancelled. Could you help with the ticket?", Weak = "Heart", Price = 160,
			Game = "Memory", HowTo = "Flip the cards and match the pairs of hearts.",
			Seconds = 20, Color = "#DB2777",
			Reviews = { "Matched all the hearts. Still single. — Raj", "Romance AND memory training. — Doris, 71" },
		},
		{
			Key = "GiveHope", Name = "GiveHope", Pitch = "Every dollar goes to the puppies.",
			Hook = "Every dollar goes straight to the puppies. Can I count on you?", Weak = "Heart", Price = 70,
			Game = "Hearts", HowTo = "Hearts float up the screen. Tap them before they float away.",
			Seconds = 15, Color = "#E11D48",
			Reviews = { "The puppies thank you. (There are no puppies.) — Linda", "Very wholesome crime. — Mo" },
		},
		{
			Key = "BankOfNowhere", Name = "BankOfNowhere", Pitch = "Secure login. Insecure bank.",
			Hook = "This is your bank's fraud team. Log in on our secure site so I can check.", Weak = "Fear", Price = 220,
			Game = "Padlocks", HowTo = "Padlocks light up in order. Click them back in the same order.",
			Seconds = 20, Color = "#334155",
			Reviews = { "Most secure site I've ever broken into. — Kevin from IT", "Lovely padlocks. — Pat" },
		},
		{
			Key = "TechSupportPro", Name = "TechSupport Pro", Pitch = "Have you tried turning it off and on?",
			Hook = "Plug the cable where I tell you and we'll have this fixed in no time.", Weak = "Tech", Price = 110,
			Game = "Cables", HowTo = "Drag each coloured cable to the port of the same colour.",
			Seconds = 15, Color = "#0E7490",
			Reviews = { "Plugged everything in. Nothing works. 5 stars. — Gary", "Cable management goals. — Raj" },
		},
	} :: { App },
}

local byKey: { [string]: App } = {}
for _, app in ScamConfig.Apps do
	byKey[app.Key] = app
end
local weaknesses: { [string]: Weakness } = {}
for _, weakness in ScamConfig.Weaknesses do
	weaknesses[weakness.Key] = weakness
end

function ScamConfig.App(key: string): App?
	return byKey[key]
end

function ScamConfig.Weakness(key: string): Weakness?
	return weaknesses[key]
end

-- What an app costs at a tier (1 = buy).
function ScamConfig.Cost(app: App, tier: number): number
	if tier <= 1 then
		return app.Price
	end
	return math.max(app.Price, 50) * (ScamConfig.UpgradeCost[tier - 1] or 4)
end

-- Weak to -> apps that play on it, in config order.
function ScamConfig.AppsFor(weak: string): { App }
	local out = {}
	for _, app in ScamConfig.Apps do
		if app.Weak == weak then
			table.insert(out, app)
		end
	end
	return out
end

return table.freeze(ScamConfig)
