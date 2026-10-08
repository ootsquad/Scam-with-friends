--[[
	Personas (server only)
	Makes up the people your crew calls: a Roblox-style display name and @username, a made-up life (job,
	town, hobbies, pet, family, what they've been up to, how good they are with tech), how they behave on the
	phone, how they can pay, a voice, and a random blocky avatar.

	Personas.new(random) -> Generated
	Personas.incomingReason(random) -> string

	Everything here is fictional. Callers are always adults.
]]

local CallConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Config.CallConfig)

export type Persona = {
	Name: string,
	Age: number,
	Job: string,
	Town: string,
	Personality: string,
	Hobbies: { string },
	Pet: string,
	Family: string,
	Lately: string,
	Tech: string,
	SoftSpot: string,
	RedFlag: string,
	Methods: { string },
	Budget: number,
}

export type Look = {
	Skin: Color3,
	Shirt: Color3,
	Pants: Color3,
	Hat: number,
	HatColor: Color3,
}

export type Generated = {
	DisplayName: string,
	Username: string,
	Tag: string,
	VoiceId: string,
	Persona: Persona,
	Look: Look,
}

local hex = Color3.fromHex

-- Text-to-speech voices by accent (Roblox VoiceIds): British 1/2, US 3-6, Australian 7/8.
local ACCENTS = {
	{
		voices = { male = { "3", "5" }, female = { "4", "6" } },
		towns = { "Dayton, Ohio", "Tulsa, Oklahoma", "Fresno, California", "Boise, Idaho", "Macon, Georgia", "Duluth, Minnesota" },
		weight = 3,
	},
	{
		voices = { male = { "1" }, female = { "2" } },
		towns = { "Leeds", "Bristol", "Norwich", "Swindon", "Plymouth" },
		weight = 1,
	},
	{
		voices = { male = { "7" }, female = { "8" } },
		towns = { "Brisbane", "Geelong", "Perth", "Hobart" },
		weight = 1,
	},
}

local FIRST_NAMES = {
	male = { "Gary", "Doug", "Frank", "Steve", "Marcus", "Walter", "Kevin", "Dale", "Ray", "Tony", "Phil", "Benny", "Hank", "Lloyd" },
	female = { "Linda", "Karen", "Brenda", "Patty", "Denise", "Gloria", "Tina", "Rosa", "Marge", "Sheila", "Diane", "Joy", "Bev", "Wanda" },
}

local LAST_NAMES = {
	"Parker", "Hughes", "Miller", "Okafor", "Romero", "Fischer", "Nguyen", "Baxter", "Pruitt", "Delgado", "Whitlock",
	"Sutton", "Kowalski", "Brennan", "Abbott", "Lindqvist", "Moreau", "Haddad",
}

-- Tag shown in the Phone app, age range, and how much money they could part with.
local JOBS = {
	{ tag = "Retired teacher", age = { 64, 79 }, budget = { 300, 1200 } },
	{ tag = "Dentist", age = { 35, 60 }, budget = { 900, 2400 } },
	{ tag = "College student", age = { 19, 23 }, budget = { 100, 400 } },
	{ tag = "Truck driver", age = { 30, 58 }, budget = { 300, 1000 } },
	{ tag = "Bakery owner", age = { 33, 61 }, budget = { 500, 1600 } },
	{ tag = "Night-shift nurse", age = { 26, 55 }, budget = { 300, 1100 } },
	{ tag = "Accountant", age = { 30, 62 }, budget = { 700, 2000 } },
	{ tag = "Grandparent of six", age = { 67, 84 }, budget = { 400, 1500 } },
	{ tag = "Gym coach", age = { 24, 45 }, budget = { 200, 800 } },
	{ tag = "Real estate agent", age = { 29, 57 }, budget = { 800, 2400 } },
	{ tag = "Florist", age = { 27, 60 }, budget = { 250, 900 } },
	{ tag = "Influencer", age = { 21, 38 }, budget = { 400, 2000 } },
	{ tag = "Farmer", age = { 40, 70 }, budget = { 400, 1400 } },
	{ tag = "Hair stylist", age = { 22, 50 }, budget = { 200, 800 } },
}

local PERSONALITIES = {
	"chatty and friendly, loves to go off on tangents",
	"polite but careful, asks a lot of questions",
	"grumpy and impatient, wants you to get to the point",
	"anxious and easily worried",
	"cheerful and a bit naive",
	"sharp and skeptical, has heard about phone scams",
	"distracted, doing three things at once while on the phone",
	"proud and stubborn, hates being told what to do",
	"lonely and happy anyone called",
}

local SOFT_SPOTS = {
	"worried their computer has a virus",
	"loves winning prizes and sweepstakes",
	"nervous about anything wrong with their bank account",
	"trusts anyone who sounds official and confident",
	"has been waiting on a refund for something they bought online",
	"afraid of getting in trouble with the tax office",
	"excited about getting rich from investments",
	"just wants someone to be nice to them",
	"worried about a package that never arrived",
}

local RED_FLAGS = {
	"being rushed or pressured",
	"being asked to pay with gift cards",
	"callers who won't say who they are or where they work",
	"being told to keep the call a secret",
	"anything that sounds too good to be true",
	"stories that change halfway through",
	"being threatened",
	"callers who don't know basic details they should know",
}

local HOBBIES = {
	"bowling", "knitting", "bird watching", "collecting spoons", "karaoke", "gardening", "model trains", "fishing",
	"baking pies", "crossword puzzles", "line dancing", "cooking shows", "bingo night", "fixing old cars",
	"jigsaw puzzles", "yard sales", "pickleball", "scrapbooking", "ghost hunting shows", "competitive yo-yo",
}

local PET_KINDS = { "dog", "cat", "parrot", "goldfish", "hamster", "tortoise", "rabbit", "very old cat" }
local PET_NAMES = {
	"Biscuit", "Mr. Whiskers", "Pickles", "Duke", "Peanut", "Captain", "Noodle", "Muffin", "Ziggy", "Chester",
	"Princess", "Sir Fluffington", "Tater", "Waffles",
}
local NO_PETS = { "no pets, just a houseplant named Steve", "no pets (allergic to everything)", "a pet rock named Gerald" }

local FAMILY = {
	"lives with their sister",
	"has three grandkids who never call",
	"married for thirty years",
	"just moved in with their cousin",
	"two teenagers at home",
	"lives alone and likes it that way",
	"takes care of their mom",
	"just got married",
	"has a twin who always borrows money",
	"kid just left for college",
}

local LATELY = {
	"just bought a new laptop",
	"waiting on a package that never showed up",
	"keeps getting weird pop-ups on their computer",
	"got a new phone and can't figure it out",
	"booked a cruise for next month",
	"just retired",
	"lost their wallet last week",
	"ordered a blender online that never came",
	"started selling candles online",
	"got a scary-looking letter they didn't really read",
	"entered a radio contest last week",
	"had their card declined at the grocery store",
}

local TECH = {
	"thinks the cloud is the weather",
	"calls every computer problem a virus",
	"writes passwords on sticky notes",
	"still uses a flip phone",
	"pretty good with computers",
	"asks the grandkids to fix everything",
	"clicks on every pop-up",
	"just learned how to text",
}

local INCOMING_REASONS = {
	"a scary pop-up on your computer said you have a virus and to call this number",
	"you got a text saying your package couldn't be delivered and to call this number",
	"a voicemail said there's a problem with your bank account and to call back",
	"an ad said you won a free gift card and to call this number to claim it",
	"a letter said you're owed a refund and to call this number",
}

local USERNAME_A = {
	"Bacon", "Noob", "Pizza", "Shadow", "Epic", "Lucky", "Sunny", "Frosty", "Turbo", "Pixel", "Mega", "Happy",
	"Sneaky", "Golden", "Cosmic", "Spicy", "Sleepy", "Crispy", "Mighty", "Fuzzy",
}
local USERNAME_B = {
	"Gamer", "Builder", "Cat", "Dog", "Wolf", "Fox", "Ninja", "Panda", "Dragon", "Star", "Rider", "Chef", "Toast",
	"Beans", "Llama", "Pickle", "Waffle", "Gecko",
}

local SKIN = {
	"#F5CD30", "#FDEA8D", "#FFE0BD", "#FFCC99", "#F1C27D", "#EAB892", "#E0AC69", "#D7C59A", "#CC8E69", "#C68642",
	"#A0715A", "#8D5524", "#7C5C46", "#5C3A21", "#5A4031", "#3D2B1F",
}
local SHIRTS = { "#0D69AC", "#C4281C", "#287F47", "#6B327C", "#E8AB2D", "#1B2A35", "#FF66CC", "#E5E4DF", "#2B8CBE", "#8A5A2B" }
local PANTS = { "#A4BD47", "#1B2A35", "#27466B", "#635F62", "#5A3C24", "#0D69AC", "#2D2D2D" }
local HAT_COLORS = { "#1B2A35", "#C4281C", "#0D69AC", "#E8AB2D", "#287F47", "#F2F3F3", "#6B327C" }
local HAT_STYLES = 4 -- 0 = none, 1 = cap, 2 = beanie, 3 = top hat, 4 = hair

local Personas = {}

local function pick<T>(random: Random, list: { T }): T
	return list[random:NextInteger(1, #list)]
end

local function pickAccent(random: Random)
	local total = 0
	for _, accent in ACCENTS do
		total += accent.weight
	end
	local roll = random:NextInteger(1, total)
	for _, accent in ACCENTS do
		roll -= accent.weight
		if roll <= 0 then
			return accent
		end
	end
	return ACCENTS[1]
end

local function makeUsername(random: Random, first: string): string
	local style = random:NextInteger(1, 4)
	if style == 1 then
		return `{pick(random, USERNAME_A)}{pick(random, USERNAME_B)}{random:NextInteger(1, 999)}`
	elseif style == 2 then
		return `xX_{pick(random, USERNAME_A)}{pick(random, USERNAME_B)}_Xx`
	elseif style == 3 then
		return `{first}{pick(random, USERNAME_B)}_{random:NextInteger(1970, 2015)}`
	end
	return `{string.lower(first)}_the_{string.lower(pick(random, USERNAME_B))}`
end

-- `count` different items from `list`.
local function pickSome(random: Random, list: { string }, count: number): { string }
	local pool = table.clone(list)
	local out = {}
	for _ = 1, math.min(count, #pool) do
		table.insert(out, table.remove(pool, random:NextInteger(1, #pool)) :: string)
	end
	return out
end

local function pickPet(random: Random): string
	if random:NextNumber() < 0.2 then
		return pick(random, NO_PETS)
	end
	return `a {pick(random, PET_KINDS)} named {pick(random, PET_NAMES)}`
end

local function pickMethods(random: Random, job: string): { string }
	local methods = {}
	for _, method in CallConfig.MethodOrder do
		local chance = if method == "donation" then (if job == "Grandparent of six" then 0.9 else 0.45) else 0.65
		if random:NextNumber() < chance then
			table.insert(methods, method)
		end
	end
	if #methods == 0 then
		table.insert(methods, pick(random, { "gift_card", "card" }))
	end
	return methods
end

function Personas.new(random: Random): Generated
	local gender = if random:NextNumber() < 0.5 then "male" else "female"
	local first = pick(random, FIRST_NAMES[gender])
	local last = pick(random, LAST_NAMES)
	local job = pick(random, JOBS)
	local accent = pickAccent(random)
	local budget = math.round(random:NextInteger(job.budget[1], job.budget[2]) / 50) * 50

	local hat = random:NextInteger(0, HAT_STYLES)
	local look: Look = {
		Skin = hex(pick(random, SKIN)),
		Shirt = hex(pick(random, SHIRTS)),
		Pants = hex(pick(random, PANTS)),
		Hat = hat,
		HatColor = hex(pick(random, HAT_COLORS)),
	}

	return {
		DisplayName = `{first} {last}`,
		Username = makeUsername(random, first),
		Tag = job.tag,
		VoiceId = pick(random, accent.voices[gender]),
		Persona = {
			Name = `{first} {last}`,
			Age = random:NextInteger(job.age[1], job.age[2]),
			Job = string.lower(job.tag),
			Town = pick(random, accent.towns),
			Personality = pick(random, PERSONALITIES),
			Hobbies = pickSome(random, HOBBIES, 2),
			Pet = pickPet(random),
			Family = pick(random, FAMILY),
			Lately = pick(random, LATELY),
			Tech = pick(random, TECH),
			SoftSpot = pick(random, SOFT_SPOTS),
			RedFlag = pick(random, RED_FLAGS),
			Methods = pickMethods(random, job.tag),
			Budget = budget,
		},
		Look = look,
	}
end

function Personas.incomingReason(random: Random): string
	return pick(random, INCOMING_REASONS)
end

return Personas
