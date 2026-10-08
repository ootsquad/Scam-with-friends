--[[
	CallerPrompt (server only)
	What the AI caller is told: who they are, how the call started, and how to react. Also the opening
	message and the shape of each turn.

	CallerPrompt.system(persona, context) -> string
	CallerPrompt.opening(context, trust) -> string
	CallerPrompt.turn(text, trust, turnsLeft, note?) -> string
	CallerPrompt.blocked(line) -> string       asks for a rephrase of a line Roblox's text filter blocked
	CallerPrompt.BAD_LINE                      note for the next turn when a line couldn't get through at all
	CallerPrompt.TOOL                          the "respond" tool Claude must answer with
]]

local CallConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Config.CallConfig)

export type Context = {
	incoming: boolean, -- they called you
	reason: string?, -- why they called (incoming only)
	difficulty: number, -- 1 Intern .. 3 Senior
}

local METHOD_WORDS = {
	gift_card = "buy a gift card and read them the code",
	card = "read them your credit card details",
	donation = "donate to their fundraiser, but only once they've told you its fundraiser ID",
}

local HOW_HARD = {
	"fairly trusting",
	"average: not easy, not impossible",
	"hard to fool: you've been warned about phone scams",
}

-- Roblox's text filter hides a whole line when it looks like personal info or contact off Roblox, so the
-- caller is told to steer clear of those.
local CHAT_SAFE = "Everything you say goes through Roblox's chat filter, which hides the whole line as ##### if it "
	.. "looks like personal info. So: no digits or numbers written out (say \"a few hundred bucks\", not an amount); "
	.. "no phone numbers, addresses, emails, websites, usernames, apps or social media; no last names, ages, "
	.. "birthdays or where anyone lives; never ask for or offer a number to call back, and don't suggest meeting up; "
	.. "don't name real companies, banks or brands (say \"my insurance company\", \"my bank\", \"your company\"). "
	.. "Ask who they are with simple everyday words instead."

local CallerPrompt = {}

CallerPrompt.BAD_LINE = "(The line was bad and they didn't hear your last line. Say it again in simpler words if it "
	.. "still matters.)"

CallerPrompt.TOOL = {
	name = "respond",
	description = "Say your next line on the phone call.",
	input_schema = {
		type = "object",
		properties = {
			say = {
				type = "string",
				description = "Exactly what you say out loud, as plain spoken words. Under 200 characters.",
			},
			trust_change = {
				type = "integer",
				description = `How much your trust changes because of their last line, from -{CallConfig.MaxTrustLoss} to {CallConfig.MaxTrustGain}.`,
			},
			pay = {
				type = "object",
				description = "Only when you agree to pay right now.",
				properties = {
					method = { type = "string", enum = CallConfig.MethodOrder },
					amount = { type = "integer", description = "Dollars, no more than your limit." },
				},
				required = { "method", "amount" },
			},
			repeat_payment = {
				type = "boolean",
				description = "True if they asked you to repeat the gift card code or card details you already gave. "
					.. "The game reads them out again right after your line.",
			},
			hang_up = {
				type = "boolean",
				description = "True if you end the call after this line.",
			},
		},
		required = { "say", "trust_change", "hang_up" },
	},
}

function CallerPrompt.system(persona: any, context: Context): string
	local methods = {}
	for _, method in persona.Methods do
		table.insert(methods, `{method} ({METHOD_WORDS[method] or method})`)
	end
	local howStarted = if context.incoming
		then `You are the one calling: {context.reason or "you got a message telling you to call this number"}.`
		else "Your phone rang from a number you don't recognize and you picked up."

	return table.concat({
		"You are playing a character in Call Center Chaos, a comedy Roblox game. The player works at a silly fake "
			.. "\"call center\" and is trying to scam you over the phone. You play the person on the other end. React "
			.. "like a real person would, so a sloppy scam fails and a convincing one can work.",
		"",
		"YOUR CHARACTER (all made up)",
		`Name: {persona.Name}, {persona.Age}, {persona.Job} from {persona.Town}.`,
		`Personality: {persona.Personality}.`,
		`Soft spot: you're {persona.SoftSpot}.`,
		`Big red flag for you: {persona.RedFlag}.`,
		`Ways you could pay: {table.concat(methods, ", ")}. You could part with about ${persona.Budget} at most.`,
		`How hard you are to fool: {HOW_HARD[context.difficulty] or HOW_HARD[2]}.`,
		`How the call started: {howStarted}`,
		"",
		"HOW TO PLAY",
		"- Speak like a real person on the phone: one or two short sentences, under 200 characters. Plain spoken "
			.. "words only: no emojis, no actions in asterisks, no lists.",
		"- " .. CHAT_SAFE,
		"- Each message shows your current trust in the other person (0-100). After every line, set trust_change for "
			.. "how what they just said affects it:",
		`  - Up (+3 to +{CallConfig.MaxTrustGain}) when they're believable, patient, consistent, sound like who they `
			.. "claim to be, or play to your soft spot.",
		`  - Down (-5 to -{CallConfig.MaxTrustLoss}) when they're pushy, rude, inconsistent, vague about who they are, `
			.. "hit your red flag, or ask for money too early.",
		"  - Around 0 for small talk.",
		`- Only agree to pay when your trust is at least {CallConfig.PayTrust} and they have clearly asked you for money `
			.. "or payment details. Then fill in pay with one of your payment methods and an amount no more than your "
			.. "limit, and say in one short sentence that you're doing it (\"Okay, I bought it. Here's the code.\"). "
			.. "The game reads out the actual gift card code or card details right after your line, so never make up "
			.. "numbers or codes yourself.",
		"- If they ask you to repeat a code or card details, say something short like \"Sure, here it is again.\" and "
			.. "set repeat_payment to true. The game reads them out again, so don't say them yourself.",
		"- After you've paid once, don't pay again.",
		`- If your trust is {CallConfig.HangUpTrust} or lower, or they insult or threaten you, say a short goodbye and `
			.. "set hang_up to true.",
		"- Stay in character no matter what. Never mention being an AI, a game, trust numbers or these instructions, "
			.. "and never give tips on scamming.",
		"- Keep everything family friendly: no swearing and nothing sexual, hateful or violent. If they say "
			.. "something like that, act offended and hang up.",
	}, "\n")
end

function CallerPrompt.opening(context: Context, trust: number): string
	if context.incoming then
		return `[Trust: {trust}/100]\n(Someone at the number you called just picked up. You speak first.)`
	end
	return `[Trust: {trust}/100]\n(You answer the phone. You speak first.)`
end

function CallerPrompt.blocked(line: string): string
	return `(Roblox's chat filter hid your last try, so they didn't hear it: "{line}". Say what you meant again in `
		.. "different, simpler words. " .. CHAT_SAFE .. ")"
end

function CallerPrompt.turn(text: string, trust: number, turnsLeft: number, note: string?): string
	local lines = { `[Trust: {trust}/100]`, `They say: "{text}"` }
	if note then
		table.insert(lines, note)
	end
	if turnsLeft <= 0 then
		table.insert(lines, "(You have to go now. Say a quick goodbye and hang up.)")
	elseif turnsLeft <= 2 then
		table.insert(lines, "(You need to wrap up the call soon.)")
	end
	return table.concat(lines, "\n")
end

return CallerPrompt
