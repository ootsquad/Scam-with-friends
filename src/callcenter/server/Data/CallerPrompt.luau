--[[
	CallerPrompt (server only)
	What the AI caller is told: who they are, how sharp they are right now, how the call started, and how to
	react. Also the opening message, the shape of each turn, and the stock lines used when Roblox's text
	filter hides what the caller wanted to say.

	CallerPrompt.system(persona, context) -> string
	CallerPrompt.opening(context, trust) -> string
	CallerPrompt.turn(text, trust, turnsLeft, note?, spoken?, payNudge?) -> string
	CallerPrompt.blocked(line) -> string       asks for a rephrase of a line Roblox's text filter hid
	CallerPrompt.recap(messages, outcome) -> string?   what the caller remembers of a finished call
	CallerPrompt.safeLine(kind, random) -> string
		kind "talk" | "pay" | "again" | "bye": a stock line that always gets through the filter
	CallerPrompt.TOOL                          the "respond" tool Claude must answer with
]]

local CallConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Config.CallConfig)

export type Smarts = {
	Name: string,
	From: number,
	PayTrust: number,
	MaxGain: number,
	MaxLoss: number,
	Pushover: boolean,
}

export type Context = {
	incoming: boolean, -- they called you
	reason: string?, -- why they called (incoming only)
	smarts: Smarts, -- CallConfig.Smarts level for this call
	level: number, -- its index in CallConfig.Smarts
	memory: { string }?, -- recaps of earlier calls with this call center, oldest first
}

local METHOD_WORDS = {
	gift_card = "buy a gift card and read them the code",
	card = "read them your credit card details",
	donation = "donate to their fundraiser, but only once they've told you its fundraiser ID",
}

-- One per CallConfig.Smarts level, dumbest first.
local SMARTS_WORDS = {
	"You are dumber than a rock. You believe absolutely anything anyone tells you, you get mixed up easily, "
		.. "you never notice when a story doesn't add up, and you happily go along with whatever they say. Any "
		.. "story at all wins you over fast, and when they ask for money you hand it over without a fuss.",
	"You're very gullible. You believe nearly every story and go along with it; only something really "
		.. "obviously fishy makes you stop and ask a question, and a friendly answer is enough to win you back.",
	"You're getting a little suspicious. You'll go along with a story that mostly makes sense, but you notice "
		.. "when something doesn't add up and ask about it.",
	"You're sharp. You've heard about phone scams lately and want a story that makes sense before you hand "
		.. "anything over, but a smooth, friendly talker can still win you over.",
}

-- Roblox's text filter hides a whole line when it looks like personal info or contact off Roblox, so the
-- caller is told to steer clear of those.
local CHAT_SAFE = "Everything you say goes through Roblox's chat filter, which hides the whole line as ##### if it "
	.. "looks like personal info. So: no digits or numbers written out (say \"a few hundred bucks\", not an amount); "
	.. "no phone numbers, addresses, emails, websites, usernames, apps or social media; no last names, ages, "
	.. "birthdays or where anyone lives; never ask for or offer a number to call back, and don't suggest meeting up; "
	.. "don't name real companies, banks or brands (say \"my insurance company\", \"my bank\", \"your company\"). "
	.. "Ask who they are with simple everyday words instead."

-- Said instead of a line the filter hid twice. Written to always get through, and to keep the call
-- moving (never "I can't hear you": the player's line was fine, it was the caller's that got hidden).
local SAFE_LINES = {
	talk = {
		"Mm-hm, I'm listening. Go on.",
		"Okay... and then what?",
		"Oh, really? Tell me more.",
		"Right, right. Go on, dear.",
		"Hmm, okay. What happens next?",
	},
	pay = {
		"Okay, I did it. Here you go.",
		"Alright, here it is.",
	},
	again = {
		"Sure, here it is again.",
	},
	bye = {
		"Sorry, I have to go now. Bye!",
		"Oh, I need to run. Goodbye!",
	},
}

local CallerPrompt = {}

local function memorySection(memory: { string }?): string
	if not memory or #memory == 0 then
		return ""
	end
	return "EARLIER CALLS WITH THIS CALL CENTER (you remember them; bring them up naturally when it fits and "
		.. "stay consistent with them):\n"
		.. table.concat(memory, "\n")
		.. "\n"
end

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
				description = "How much your trust changes because of their last line, within the ranges in your instructions.",
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
			free_turn = {
				type = "boolean",
				description = "True if their last line was garbled or made no sense (likely misheard by speech-to-text), "
					.. "or only asked you to repeat or explain something. It won't count against them.",
			},
		},
		required = { "say", "trust_change", "hang_up" },
	},
}

function CallerPrompt.system(persona: any, context: Context): string
	local smarts = context.smarts
	local methods = {}
	for _, method in persona.Methods do
		table.insert(methods, `{method} ({METHOD_WORDS[method] or method})`)
	end
	local howStarted = if context.incoming
		then `You are the one calling: {context.reason or "you got a message telling you to call this number"}.`
		else "Your phone rang from a number you don't recognize and you picked up."
	local smallGain = math.max(3, math.ceil(smarts.MaxGain / 3))

	return table.concat({
		"You are playing a character in Call Center Chaos, a comedy Roblox game. The player works at a silly fake "
			.. "\"call center\" and is trying to scam you over the phone. You play the person on the other end, and "
			.. "you're meant to be fun and easy to fool.",
		"",
		"YOUR CHARACTER (all made up)",
		`Name: {persona.Name}, {persona.Age}, {persona.Job} from {persona.Town}.`,
		`Personality: {persona.Personality}.`,
		`Hobbies: {table.concat(persona.Hobbies or {}, " and ")}. Pet: {persona.Pet or "none"}.`,
		`Family: {persona.Family or "keeps to themselves"}. Lately: {persona.Lately or "nothing much"}.`,
		`With technology: {persona.Tech or "average"}.`,
		`Soft spot: you're {persona.SoftSpot}.`,
		`Big red flag for you: {persona.RedFlag}.`,
		`Ways you could pay: {table.concat(methods, ", ")}. You could part with about ${persona.Budget} at most.`,
		`How sharp you are: {SMARTS_WORDS[context.level] or SMARTS_WORDS[1]}`,
		`How the call started: {howStarted}`,
		"",
		memorySection(context.memory),
		"HOW TO PLAY",
		"- Speak like a real person on the phone: one or two short sentences, under 200 characters. Plain spoken "
			.. "words only: no emojis, no actions in asterisks, no lists. Chat about your hobbies, pet and family "
			.. "when it fits.",
		"- Remember everything said earlier in the call and stay consistent: who they said they are, what they "
			.. "told you, what you've said about yourself and what you agreed to. Never ask something they already "
			.. "answered, never repeat a question you already asked, and don't repeat yourself word for word. Answer "
			.. "what they actually said and keep the same personality the whole call.",
		"- " .. CHAT_SAFE,
		"- Many of their lines come from speech-to-text, marked (spoken). Speech-to-text mishears words, drops "
			.. "punctuation and mixes up words that sound alike. Work out what they most likely meant from the "
			.. "conversation so far and answer that. Never point out typos or odd wording.",
		"- Their lines can contain [static] where the bad phone line cut out a word or two. Guess what they meant "
			.. "from the rest and carry on; that's never their fault and never costs trust. Only if almost "
			.. "nothing came through, say you missed that and ask them to say it again. Never say you can't hear "
			.. "them otherwise.",
		"- Set free_turn to true when their last line was garbled or made no sense (probably misheard), or when "
			.. "they were only asking you to repeat or explain something. Those lines don't count against them.",
		"- Each message shows your current trust in the other person (0-100). After every line, set trust_change for "
			.. "how what they just said affects it:",
		`  - Up (+{smallGain} to +{smarts.MaxGain}) when they sound friendly or believable, give any reason that `
			.. "makes sense to you, or play to your soft spot. A story about your soft spot is worth a big jump.",
		`  - Down (-1 to -{smarts.MaxLoss}) only for clear problems: they're rude, obviously contradict themselves, `
			.. "hit your red flag, or demand money before saying why. Small slip-ups don't matter.",
		"  - 0 to +3 for small talk: being chatty and friendly slowly wins you over.",
		`- Only agree to pay when your trust is at least {smarts.PayTrust} and they have asked you for money `
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

-- How each CallConfig.Outcome reads from the caller's side.
local OUTCOME_WORDS = {
	[1] = "you paid them",
	[2] = "you hung up on them",
	[3] = "you didn't pick up",
	[4] = "you called them and they didn't pick up",
	[5] = "you called them and they declined",
	[6] = "they hung up on you",
	[7] = "the line went dead",
}

-- A short recap of a finished call for the caller to remember next time: how it ended and the last few
-- lines. nil if nothing was said.
function CallerPrompt.recap(messages: { { role: string, content: string } }, outcome: number): string?
	local lines = {}
	for _, message in messages do
		if message.role == "assistant" then
			table.insert(lines, `You: {message.content}`)
		else
			local said = string.match(message.content, 'They say[^:\n]*: "(.*)"')
			if said then
				table.insert(lines, `Them: {said}`)
			end
		end
	end
	if #lines <= 1 then
		return nil
	end
	local recent = {}
	for i = math.max(1, #lines - 9), #lines do
		table.insert(recent, lines[i])
	end
	local text = `- A call where {OUTCOME_WORDS[outcome] or "the call ended"}. It ended like this: `
		.. table.concat(recent, " / ")
	if #text > 1200 then
		text = string.sub(text, 1, 1197) .. "..."
	end
	return text
end

function CallerPrompt.safeLine(kind: string, random: Random): string
	local lines = SAFE_LINES[kind] or SAFE_LINES.talk
	return lines[random:NextInteger(1, #lines)]
end

-- payNudge: for the dumbest callers, a reminder that past the pay line they pay when asked.
function CallerPrompt.turn(
	text: string,
	trust: number,
	turnsLeft: number,
	note: string?,
	spoken: boolean?,
	payNudge: string?
): string
	local lines = { `[Trust: {trust}/100]`, `They say{if spoken then " (spoken)" else ""}: "{text}"` }
	if note then
		table.insert(lines, note)
	end
	if payNudge then
		table.insert(lines, payNudge)
	end
	if turnsLeft <= 0 then
		table.insert(lines, "(You have to go now. Say a quick goodbye and hang up.)")
	elseif turnsLeft <= 2 then
		table.insert(lines, "(You need to wrap up the call soon.)")
	end
	return table.concat(lines, "\n")
end

return CallerPrompt
