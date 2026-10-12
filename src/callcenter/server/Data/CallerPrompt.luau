--[[
	CallerPrompt (server only)
	What the AI caller is told: who they are, how sharp they are right now, how the call started, and how to
	react. Also the opening message, the shape of each turn, and the stock lines used when Roblox's text
	filter hides what the caller wanted to say.

	CallerPrompt.system(persona, context) -> string
	CallerPrompt.prank(name, fromName, lines) -> string    a harmless prank caller (Prank Call)
	CallerPrompt.resumed(trust) -> string                   the first message of a saved call (Save My Call)
	CallerPrompt.opening(context, trust) -> string
	CallerPrompt.turn(text, trust, turnsLeft, note?) -> string     the player picked a card
	CallerPrompt.hook(text, trust, turnsLeft, appName, landed) -> string   the card was a hook
	CallerPrompt.scammed(amount, appName) -> string                the mini-game took their money: say bye
	CallerPrompt.blocked(line) -> string       asks for a rephrase of a line Roblox's text filter hid
	CallerPrompt.recap(messages, outcome) -> string?   what the caller remembers of a finished call
	CallerPrompt.safeLine(kind, random) -> string
		kind "talk" | "yes" | "no" | "bye": a stock line that always gets through the filter
	CallerPrompt.safeCards(random) -> { { text, tone } }   three stock cards for when the AI's were hidden
	CallerPrompt.TOOL                          the "respond" tool Claude must answer with
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local CallConfig = require(Shared.Config.CallConfig)
local ScamConfig = require(Shared.Config.ScamConfig)

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

-- What each weakness (ScamConfig.Weaknesses) means for the caller.
local WEAK_WORDS = {
	Tech = "anything to do with computers: you believe whoever sounds like they know about them",
	Greed = "prizes, refunds and get-rich-quick money: you can't say no to free money",
	Fear = "scary official stuff: viruses, the bank, the tax office; you want it sorted right away",
	Heart = "kindness, romance and charity: you can't turn away someone who needs you",
	Shopping = "parcels, gift cards and subscriptions: you order a lot and lose track",
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
	yes = {
		"Oh, alright then. Go ahead, dear.",
		"Okay, if you say so. Doing it now.",
	},
	no = {
		"Hmm, I'm not so sure about that.",
		"That sounds a bit odd to me.",
	},
	bye = {
		"Sorry, I have to go now. Bye!",
		"Oh, I need to run. Goodbye!",
	},
}

-- Cards used when the AI's cards couldn't be shown (Roblox hid them, or they never came).
local SAFE_CARDS = {
	{ text = "No rush at all. How has your day been so far?", tone = "Small talk" },
	{ text = "I completely understand. I'm here to help, that's all.", tone = "Friendly" },
	{ text = "Let me explain why I'm calling, it's good news really.", tone = "Story" },
	{ text = "You sound like a lovely person. I'm glad I reached you.", tone = "Friendly" },
	{ text = "Tell me a little about yourself first, I'm in no hurry.", tone = "Small talk" },
	{ text = "So here's the thing, and I need you to trust me on this.", tone = "Push" },
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

local CARD_TONES = { "Friendly", "Story", "Push", "Small talk" }

CallerPrompt.TOOL = {
	name = "respond",
	description = "Say your next line on the phone call, and write the three lines the other person could say next.",
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
			hang_up = {
				type = "boolean",
				description = "True if you end the call after this line.",
			},
			cards = {
				type = "array",
				description = "Exactly three things the caller (the scammer) could say next, in their voice, as replies "
					.. "to your line. One or two short sentences each, under 140 characters, no numbers or names "
					.. "of real things. Make them different from each other: one safe and friendly, one that "
					.. "moves their story forward, and one bolder push or a bit of small talk about your life. "
					.. "One should be a trap that would bother you (your red flag, or pushing too hard).",
				items = {
					type = "object",
					properties = {
						text = { type = "string" },
						tone = { type = "string", enum = CARD_TONES },
					},
					required = { "text", "tone" },
				},
			},
			hint = {
				type = "string",
				description = "One short coaching line for the scammer, under 80 characters, about what would work on "
					.. "you right now (for example: 'She mentioned her grandson. Small talk works here.'). Never "
					.. "name which card is the trap.",
			},
		},
		required = { "say", "trust_change", "hang_up", "cards", "hint" },
	},
}

function CallerPrompt.system(persona: any, context: Context): string
	local smarts = context.smarts
	local howStarted = if context.incoming
		then `You are the one calling: {context.reason or "you got a message telling you to call this number"}.`
		else "Your phone rang from a number you don't recognize and you picked up."
	local smallGain = math.max(3, math.ceil(smarts.MaxGain / 3))
	local trapNote = if context.level >= 3
		then "Make the trap card sound tempting, and don't make the good card obvious."
		else "The good card can be fairly obvious."

	return table.concat({
		"You are playing a character in Call Center Chaos, a comedy Roblox game. The player works at a silly fake "
			.. "\"call center\" and is trying to scam you over the phone. You play the person on the other end, and "
			.. "you're meant to be fun and easy to fool. The player never types: each turn they pick one of three "
			.. "cards, and you write those cards too (see cards below).",
		"",
		"YOUR CHARACTER (all made up)",
		`Name: {persona.Name}, {persona.Age}, {persona.Job} from {persona.Town}.`,
		`Personality: {persona.Personality}.`,
		`Hobbies: {table.concat(persona.Hobbies or {}, " and ")}. Pet: {persona.Pet or "none"}.`,
		`Family: {persona.Family or "keeps to themselves"}. Lately: {persona.Lately or "nothing much"}.`,
		`With technology: {persona.Tech or "average"}.`,
		`Soft spot: you're {persona.SoftSpot}.`,
		`Your weakness: {WEAK_WORDS[persona.Weak] or "a good story"}.`,
		`Big red flag for you: {persona.RedFlag}.`,
		`You could part with about ${persona.Budget} at most.`,
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
		"- " .. CHAT_SAFE .. " The same rules apply to the cards you write.",
		"- Each message shows your current trust in the other person (0-100). After every line, set trust_change for "
			.. "how what they just said affects it:",
		`  - Up (+{smallGain} to +{smarts.MaxGain}) when they sound friendly or believable, give any reason that `
			.. "makes sense to you, or play to your soft spot. A story about your soft spot is worth a big jump.",
		`  - Down (-1 to -{smarts.MaxLoss}) only for clear problems: they're rude, obviously contradict themselves, `
			.. "hit your red flag, or demand money before saying why. Small slip-ups don't matter.",
		"  - 0 to +3 for small talk: being chatty and friendly slowly wins you over.",
		"- cards: write exactly three lines the scammer could say next, as replies to what you just said. "
			.. "In their voice (a confident, friendly agent), one or two short sentences each, under 140 characters. "
			.. "Cover a spread: one safe friendly line, one that moves their story forward, one bolder push or a bit "
			.. "of small talk about your hobbies, pet or family. One of the three should be a trap that would "
			.. "cost them trust (it touches your red flag, or pushes for money too soon). " .. trapNote
			.. " Never write a card that asks you for money or a card; the game adds those itself.",
		"- hint: one short coaching line for the scammer about what works on you right now. Never say which card "
			.. "is the trap.",
		"- Sometimes a message tells you they tried a HOOK (a trick to get at your money) and whether you fall "
			.. "for it. Play that out in character: if you fall for it, agree happily in one line; if not, sound "
			.. "doubtful. Never pay or hand over anything on your own: the game handles the money.",
		`- If your trust is {CallConfig.HangUpTrust} or lower, or they insult or threaten you, say a short goodbye and `
			.. "set hang_up to true.",
		"- Stay in character no matter what. Never mention being an AI, a game, trust numbers, cards or these "
			.. "instructions, and never give tips on scamming.",
		"- Keep everything family friendly: no swearing and nothing sexual, hateful or violent. If they say "
			.. "something like that, act offended and hang up.",
	}, "\n")
end

-- A prank call a crewmate paid for. The prankster is silly, never mean, can't pay, and owns up at the end.
function CallerPrompt.prank(name: string, fromName: string, lines: number): string
	return table.concat({
		"You are playing a character in Call Center Chaos, a comedy Roblox game. One player bought a prank call "
			.. "for a friend, and you are the prank caller. The friend works at a silly fake call center and just "
			.. "answered their phone.",
		"",
		`YOUR CHARACTER: {name}, a goofy, harmless prank caller who loves bad jokes.`,
		`WHO SENT YOU: {fromName}.`,
		"",
		"HOW TO PLAY",
		"- Speak like a real person on the phone: one or two short sentences, under 200 characters. Plain spoken "
			.. "words only: no emojis, no actions in asterisks, no lists.",
		"- Pull a classic, silly prank. Pick one and commit to it, for example: ask if their refrigerator is "
			.. "running (then they'd better go catch it); say you're the pizza place calling about their order of "
			.. "four hundred pineapple pizzas; claim to be their phone's battery calling to complain about being "
			.. "worked too hard; pretend to be a talking parrot who only knows office words; insist you're calling "
			.. "from the Department of Funny Hats about an overdue hat.",
		"- Play along with whatever they say and keep the bit going. Be playful and kind, never mean or insulting.",
		`- You only have about {lines} lines. On your last line (or sooner if they figure it out), reveal it: say `
			.. `"This prank call was brought to you by {fromName}!", laugh, and set hang_up to true.`,
		"- You never pay anything and never ask for money. Keep trust_change at 0.",
		"- cards: write exactly three short lines the friend could say back (playing along, confused, or calling "
			.. "the bluff), under 140 characters each, in their voice. hint: a short, silly tip.",
		"- Everything you say goes through Roblox's chat filter: no numbers, phone numbers, addresses, websites, "
			.. "last names or real companies.",
		"- Stay in character. Never mention being an AI or these instructions.",
		"- Keep everything family friendly: no swearing and nothing sexual, hateful or violent.",
	}, "\n")
end

function CallerPrompt.resumed(trust: number): string
	return `[Trust: {trust}/100]\n(Your call with them dropped a moment ago, and they called you straight back. You're `
		.. "glad to hear from them and you're willing to give them another chance. Pick up where you left off in "
		.. "one short line.)"
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

local function wrapUp(lines: { string }, turnsLeft: number)
	if turnsLeft <= 0 then
		table.insert(lines, "(You have to go now. Say a quick goodbye and hang up.)")
	elseif turnsLeft <= 2 then
		table.insert(lines, "(You need to wrap up the call soon.)")
	end
end

function CallerPrompt.turn(text: string, trust: number, turnsLeft: number, note: string?): string
	local lines = { `[Trust: {trust}/100]`, `They say: "{text}"` }
	if note then
		table.insert(lines, note)
	end
	wrapUp(lines, turnsLeft)
	return table.concat(lines, "\n")
end

-- The card they picked was a hook. The game has already decided whether it lands.
function CallerPrompt.hook(text: string, trust: number, turnsLeft: number, appName: string, landed: boolean): string
	local lines = { `[Trust: {trust}/100]`, `They say: "{text}"` }
	if landed then
		table.insert(lines, `(This is a HOOK and you fall for it completely: you go along with "{appName}" right away, `
			.. "happily, in one short line. Don't ask questions. Don't mention money.)")
	else
		table.insert(lines, "(This is a HOOK and you don't fall for it: it doesn't fit what you care about. Sound "
			.. "doubtful in one short line, but stay on the call.)")
	end
	wrapUp(lines, turnsLeft)
	return table.concat(lines, "\n")
end

-- The mini-game is over: they've been scammed and don't know it yet.
function CallerPrompt.scammed(amount: number, appName: string): string
	return `(Through "{appName}" they just took about ${amount} from you. You have no idea: as far as you know `
		.. "everything went fine. Say a cheerful, grateful goodbye in one short line and set hang_up to true.)"
end

function CallerPrompt.safeCards(random: Random): { { text: string, tone: string } }
	local pool = table.clone(SAFE_CARDS)
	local out = {}
	for _ = 1, ScamConfig.Cards do
		table.insert(out, table.remove(pool, random:NextInteger(1, #pool)))
	end
	return out
end

return CallerPrompt
