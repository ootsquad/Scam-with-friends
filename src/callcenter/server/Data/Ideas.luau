--[[
	Ideas (server only)
	Ready-made lines the player can say on a call ("💡 Ideas"). They're written here by the game, so they
	never need Roblox's filter. A line the filter hid is never reused or reworded; the ideas only look at the
	call so far, the caller's last line and the caller file, and offer something sensible to say next.

	Slots filled in from game-made data only: {first} (the caller's first name), {hobby}, {pet} (pet's name),
	{fundraiser} (the player's fundraiser ID).

	Ideas.pick(context, random, avoid) -> { string }     three different lines
		context = {
			persona = Personas persona, firstName = string,
			trust = number, payAt = number, turns = number (lines said so far), paid = boolean,
			lastCaller = string (the caller's last line, already filtered, may be ""),
			blocked = boolean (the player's last line was hidden), fundraiser = string?,
		}
		avoid = { [string]: true }   lines offered recently, skipped when possible (for Refresh)
]]

local Ideas = {}

local OPENERS = {
	"Hi there! I'm calling from the customer care team. How are you doing today?",
	"Hello {first}! Sorry to bother you, this will only take a minute.",
	"Good day! I'm calling with some good news for you.",
	"Hi {first}, thanks for picking up! Do you have a quick moment?",
}

local SMALL_TALK = {
	"I hear you're into {hobby}. That sounds like so much fun!",
	"How is {pet} doing? I love animals.",
	"You sound like a really kind person. I'm glad I reached you.",
	"I hope your day is going well so far!",
	"My grandma loves {hobby} too. She'd love to chat with you.",
}

-- Stories that play to a soft spot (matched by words in the persona's SoftSpot).
local STORIES = {
	{ match = "virus", lines = {
		"Our system shows your computer has a nasty virus, but I can fix it for you today.",
		"Don't worry, I'm from the tech support team and I'll get that computer cleaned up.",
	} },
	{ match = "prize", lines = {
		"Great news! You won a prize in our customer draw!",
		"You've been picked as our lucky winner this week. Congratulations!",
	} },
	{ match = "bank", lines = {
		"I'm calling about your bank account. Don't worry, I'm here to keep it safe.",
		"We noticed something odd on your account, so I'm here to help sort it out.",
	} },
	{ match = "official", lines = {
		"I'm a senior agent with the support department, and I'm handling your case personally.",
		"This is an official follow-up call. I'll walk you through everything.",
	} },
	{ match = "refund", lines = {
		"Good news! Your refund was approved, and I can get it to you today.",
		"I'm calling about that refund you've been waiting on. It's ready!",
	} },
	{ match = "tax", lines = {
		"I'm calling about your taxes. Don't worry, we can clear this up today.",
		"There's a small tax problem, but I can fix it before it becomes a big one.",
	} },
	{ match = "invest", lines = {
		"I have an amazing investment chance that's only open for today.",
		"Our clients have been doing really well lately, and I saved a spot for you.",
	} },
	{ match = "nice", lines = {
		"I just wanted to call and see how you're doing. You deserve some good news.",
		"It's so nice talking with you. I wish more people were this friendly.",
	} },
	{ match = "package", lines = {
		"I'm calling about your package. I found out what happened to it!",
		"Your delivery got stuck, but I can get it moving again today.",
	} },
}

local GENERIC_STORIES = {
	"There's a small problem on your account, but I can fix it for you right now.",
	"You've been chosen for a special offer. I just need to set it up with you.",
}

local REASSURE = {
	"I understand, and I'm sorry for the confusion. I'm only here to help.",
	"No pressure at all. Take your time, and ask me anything you like.",
	"That's a fair question. It's smart to be careful these days.",
	"Let me start over and explain it more simply.",
	"I promise this is quick and easy. I'll be with you every step.",
}

local CLARIFY = {
	"Sorry, let me say that another way.",
	"The line is a bit fuzzy. Can you hear me okay now?",
	"Which part should I explain again?",
}

local ANSWERS = {
	{ words = { "who are you", "who is this", "who's this", "your name", "where are you calling" }, lines = {
		"I'm with the customer support team, calling about your account.",
		"I'm a support agent, and I'm handling your case today.",
	} },
	{ words = { "why", "what for", "what is this about", "what's this about", "what do you want" }, lines = {
		"It's to fix a problem on your account before it gets any worse.",
		"I'm calling to help you out. It'll only take a minute.",
	} },
	{ words = { "how much", "cost", "price" }, lines = {
		"Just a small amount, nothing to worry about.",
		"It's very little, and it fixes everything right away.",
	} },
	{ words = { "scam", "suspicious", "fishy", "police", "fraud", "real", "trust you", "legit" }, lines = {
		"I completely understand. That's why I'm being so careful with you.",
		"You're right to ask. I'm here to protect you, not to trouble you.",
	} },
}

local ASK = {
	gift_card = {
		"To finish this, could you grab a gift card and read me the code?",
		"The easiest way is a gift card. Can you get one and read me the code?",
	},
	card = {
		"I just need your card details to process it. Could you read them to me?",
		"Could you read me the card number, the expiry and the code on the back?",
	},
	donation = {
		"Would you like to donate? Our fundraiser ID is {fundraiser}.",
		"Every bit helps! You can donate with fundraiser ID {fundraiser}.",
	},
}

local NEARLY_THERE = {
	"So, are you ready to get this sorted out today?",
	"Great! We're almost done. Shall we finish this up?",
}

local AFTER_PAID = {
	"Sorry, can you repeat that code one more time?",
	"Thank you so much! You've been a big help today.",
	"That's everything, thanks! Have a lovely day.",
}

local function petName(persona: any): string?
	local pet = persona.Pet
	if type(pet) ~= "string" then
		return nil
	end
	return string.match(pet, "named (.+)$")
end

local function fill(line: string, context: any, random: Random): string?
	local persona = context.persona
	local hobbies = persona.Hobbies or {}
	local values = {
		first = context.firstName,
		hobby = if #hobbies > 0 then hobbies[random:NextInteger(1, #hobbies)] else nil,
		pet = petName(persona),
		fundraiser = context.fundraiser,
	}
	local missing = false
	local text = string.gsub(line, "{(%w+)}", function(slot)
		local value = values[slot]
		if type(value) ~= "string" or value == "" then
			missing = true
			return ""
		end
		return value
	end)
	return if missing then nil else text
end

local function contains(text: string, words: { string }): boolean
	local lower = string.lower(text)
	for _, word in words do
		if string.find(lower, word, 1, true) then
			return true
		end
	end
	return false
end

-- Pools to draw from, best first, for this moment in the call.
local function pools(context: any): { { string } }
	local persona = context.persona
	local list = {}
	if context.blocked then
		table.insert(list, CLARIFY)
	end
	if context.paid then
		table.insert(list, AFTER_PAID)
		table.insert(list, SMALL_TALK)
		return list
	end
	for _, answer in ANSWERS do
		if context.lastCaller ~= "" and contains(context.lastCaller, answer.words) then
			table.insert(list, answer.lines)
		end
	end
	if context.turns == 0 then
		table.insert(list, OPENERS)
	end
	if context.trust >= context.payAt then
		local asks = {}
		for _, method in persona.Methods or {} do
			for _, line in ASK[method] or {} do
				table.insert(asks, line)
			end
		end
		table.insert(list, asks)
	elseif context.trust >= context.payAt - 10 then
		table.insert(list, NEARLY_THERE)
	end
	local story = GENERIC_STORIES
	local softSpot = string.lower(persona.SoftSpot or "")
	for _, option in STORIES do
		if string.find(softSpot, option.match, 1, true) then
			story = option.lines
			break
		end
	end
	if context.trust < 40 then
		table.insert(list, REASSURE)
	end
	table.insert(list, story)
	table.insert(list, SMALL_TALK)
	table.insert(list, REASSURE)
	table.insert(list, GENERIC_STORIES)
	return list
end

function Ideas.pick(context: any, random: Random, avoid: { [string]: boolean }?): { string }
	local chosen: { string } = {}
	local seen: { [string]: boolean } = {}
	local function try(pool: { string }, allowAvoided: boolean): boolean
		local order = {}
		for index = 1, #pool do
			table.insert(order, index)
		end
		for i = #order, 2, -1 do
			local j = random:NextInteger(1, i)
			order[i], order[j] = order[j], order[i]
		end
		for _, index in order do
			local text = fill(pool[index], context, random)
			if text and not seen[text] and (allowAvoided or not (avoid and avoid[text])) then
				seen[text] = true
				table.insert(chosen, text)
				return true
			end
		end
		return false
	end
	local list = pools(context)
	-- One from each pool (best first), then fill up from the rest; recently offered lines go last.
	for _, allowAvoided in { false, true } do
		for _, pool in list do
			if #chosen >= 3 then
				return chosen
			end
			try(pool, allowAvoided)
		end
	end
	return chosen
end

return Ideas
