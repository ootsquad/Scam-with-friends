--[[
	PaymentService (server, Call Center Place)
	What callers hand over, and the apps you cash it in with. Nothing is paid out until you do the work:

	  Gift cards   the caller reads out a code -> type it into the Gift Cards app to redeem it
	  Credit card  the caller reads out number, expiry and security code -> charge it in the Card Terminal.
	               Charge more than the card holds and it's declined; too many declines freeze it.
	  Donations    every player has a fake fundraiser with an ID (Donations app). Tell the caller the ID;
	               when they donate, the money lands straight in your fundraiser.

	All codes and card numbers are made up by the game.

	Player attributes: FundraiserTitle, FundraiserCode, FundraiserRaised

	PaymentService.Start()
	PaymentService.IssueGiftCard(player, leadName, amount) -> spokenText
	PaymentService.IssueCard(player, leadName, limit) -> spokenText
	PaymentService.HeardFundraiser(player, text) -> boolean
	PaymentService.Donate(player, leadName, amount)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CallConfig = require(Shared.Config.CallConfig)
local Format = require(Shared.Util.Format)
local Call = require(Shared:WaitForChild("Network")).Call
local Namespace = require(Shared.Network.Namespace)
local CareerService = require(script.Parent.CareerService)
local CoachService = require(script.Parent.CoachService)
local EconomyService = require(script.Parent.EconomyService)
local OfficeService = require(script.Parent.OfficeService)

local CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
local ATTEMPT_COOLDOWN = 0.4

local GIFT_BRANDS = { "Scamazon", "GooglyPlay", "Stoam", "Bloxbuster", "iTunez" }
local CARD_BRANDS = { { "Fisa", "4" }, { "MasterCart", "5" }, { "Discoveree", "6" } }
local CAUSES = {
	"Save the Office Goldfish",
	"Hats for Hamsters",
	"Help Grandma Buy a Jet Ski",
	"Free Wi-Fi for Penguins",
	"Rescue the Lost Socks",
	"Pizza for Tired Firefighters",
	"Sunglasses for Snowmen",
	"A New Roof for the Duck Pond",
}
local CODE_WORDS_A = { "SUNNY", "HAPPY", "BRAVE", "LUCKY", "GOLDEN", "GENTLE", "MIGHTY", "COZY", "JOLLY", "SWIFT" }
local CODE_WORDS_B = { "OTTER", "PANDA", "TULIP", "COMET", "MAPLE", "BADGER", "HARBOR", "MEADOW", "PEBBLE", "FALCON" }

type GiftCard = { Code: string, Brand: string, Amount: number, LeadName: string, Redeemed: boolean }
type Card = {
	Number: string,
	Exp: string,
	Cvv: string,
	Brand: string,
	Limit: number,
	LeadName: string,
	Declines: number,
	Used: boolean,
	Frozen: boolean,
}
type Fundraiser = { Title: string, Code: string, Key: string, Raised: number }

local PaymentService = {}

local random = Random.new()
local giftCards: { [Player]: { [string]: GiftCard } } = {}
local cards: { [Player]: { [string]: Card } } = {}
local fundraisers: { [Player]: Fundraiser } = {}
local lastAttempt: { [Player]: { [string]: number } } = {}

local function result(ok: boolean, message: string)
	return { Ok = ok, Message = message }
end

local function pick<T>(list: { T }): T
	return list[random:NextInteger(1, #list)]
end

local lettersAndDigits = Format.code

local function onlyDigits(text: string): string
	return (string.gsub(text, "%D", ""))
end

local function onlyLetters(text: string): string
	return string.upper((string.gsub(text, "[^%a]", "")))
end

local money = Format.money

-- Per app ("redeem" / "charge"), so cashing in a gift card and then a credit card quickly is fine.
local function throttled(player: Player, app: string): boolean
	local now = os.clock()
	local times = lastAttempt[player]
	if not times then
		times = {}
		lastAttempt[player] = times
	end
	if times[app] and now - times[app] < ATTEMPT_COOLDOWN then
		return true
	end
	times[app] = now
	return false
end

-- Pays out what a caller handed over, plus the floor's and the player's router bonus (and 2x cash or a Team
-- Leader's bonus, through EconomyService). Returns the bonus.
local function pay(player: Player, method: string, detail: string, amount: number, leadName: string): number
	local share = OfficeService.Perks().PayoutBonus + CareerService.Tier(player, "Router").Value
	local total = EconomyService.Award(player, amount + math.max(0, math.round(amount * share)))
	local bonus = math.max(0, total - amount)
	if method ~= "donation" then
		CoachService.Note(player, "Cashed")
	end
	CareerService.CompleteStep(player, "CashIn")
	Call.packets.Payout.sendTo({
		Method = method,
		Label = CallConfig.PaymentMethods[method].Label,
		Detail = detail,
		Amount = total,
		Bonus = bonus,
		LeadName = leadName,
	}, player)
	return bonus
end

local function withBonus(text: string, bonus: number): string
	return if bonus > 0 then `{text} (+{money(bonus)} bonus)` else text
end

-- ---------------------------------------------------------------------------
-- Gift cards
-- ---------------------------------------------------------------------------

local function newCode(): string
	local groups = {}
	for g = 1, 3 do
		local chars = {}
		for i = 1, 4 do
			local index = random:NextInteger(1, #CODE_ALPHABET)
			chars[i] = string.sub(CODE_ALPHABET, index, index)
		end
		groups[g] = table.concat(chars)
	end
	return table.concat(groups, "-")
end

function PaymentService.IssueGiftCard(player: Player, leadName: string, amount: number): string
	local owned = giftCards[player] or {}
	giftCards[player] = owned
	local code = newCode()
	while owned[lettersAndDigits(code)] do
		code = newCode()
	end
	local card: GiftCard = { Code = code, Brand = pick(GIFT_BRANDS), Amount = amount, LeadName = leadName, Redeemed = false }
	owned[lettersAndDigits(code)] = card
	return `It's a {money(amount)} {card.Brand} card. The code is {code}.`
end

local function onRedeem(code: string, player: Player)
	if type(code) ~= "string" then
		return result(false, "Type the code the caller read out.")
	elseif throttled(player, "redeem") then
		return result(false, "Slow down a little.")
	end
	local key = lettersAndDigits(code)
	if #key == 0 then
		return result(false, "Type the code the caller read out.")
	end
	local card = (giftCards[player] or {})[key]
	if not card then
		return result(false, "That code didn't work. Check every letter.")
	end
	if card.Redeemed then
		return result(false, "That card was already redeemed.")
	end
	card.Redeemed = true
	local bonus = pay(player, "gift_card", `{card.Brand} gift card ····{string.sub(key, -4)}`, card.Amount, card.LeadName)
	return result(true, withBonus(`Redeemed a {money(card.Amount)} {card.Brand} card.`, bonus))
end

-- ---------------------------------------------------------------------------
-- Credit cards
-- ---------------------------------------------------------------------------

function PaymentService.IssueCard(player: Player, leadName: string, limit: number): string
	local owned = cards[player] or {}
	cards[player] = owned
	local brand = pick(CARD_BRANDS)
	local digits = brand[2]
	for _ = 2, 16 do
		digits ..= tostring(random:NextInteger(0, 9))
	end
	local number = `{string.sub(digits, 1, 4)} {string.sub(digits, 5, 8)} {string.sub(digits, 9, 12)} {string.sub(digits, 13, 16)}`
	local exp = string.format("%02d/%02d", random:NextInteger(1, 12), random:NextInteger(27, 31))
	local cvv = string.format("%03d", random:NextInteger(0, 999))
	owned[digits] = {
		Number = number,
		Exp = exp,
		Cvv = cvv,
		Brand = brand[1],
		Limit = limit,
		LeadName = leadName,
		Declines = 0,
		Used = false,
		Frozen = false,
	}
	return `The card number is {number}, it expires {exp}, and the code on the back is {cvv}.`
end

local function onCharge(request: any, player: Player)
	if type(request) ~= "table" then
		return result(false, "Enter the card details the caller read out.")
	elseif throttled(player, "charge") then
		return result(false, "Slow down a little.")
	end
	local digits = onlyDigits(tostring(request.Number or ""))
	local card = (cards[player] or {})[digits]
	if #digits < 15 then
		return result(false, "Enter the full card number.")
	elseif not card then
		return result(false, "The bank doesn't recognize that card number.")
	elseif card.Frozen then
		return result(false, "This card is frozen. Too many declines.")
	elseif card.Used then
		return result(false, "This card was already charged.")
	end
	if onlyDigits(tostring(request.Exp or "")) ~= onlyDigits(card.Exp) then
		return result(false, "Declined: wrong expiry date.")
	end
	if onlyDigits(tostring(request.Cvv or "")) ~= card.Cvv then
		return result(false, "Declined: wrong security code.")
	end
	local amount = math.floor(tonumber(request.Amount) or 0)
	if amount <= 0 then
		return result(false, "Enter how much to charge.")
	end
	if amount > card.Limit then
		card.Declines += 1
		if card.Declines >= CallConfig.DeclinesBeforeFreeze then
			card.Frozen = true
			return result(false, "Declined: insufficient funds. The bank froze the card.")
		end
		return result(false, "Declined: insufficient funds. Try a smaller amount before the bank gets suspicious.")
	end
	card.Used = true
	local bonus = pay(player, "card", `{card.Brand} ending in {string.sub(digits, -4)}`, amount, card.LeadName)
	return result(true, withBonus(`Charged {money(amount)} to the {card.Brand} card.`, bonus))
end

-- ---------------------------------------------------------------------------
-- Donations
-- ---------------------------------------------------------------------------

local function fundraiserOf(player: Player): Fundraiser
	local fundraiser = fundraisers[player]
	if not fundraiser then
		local code = `{pick(CODE_WORDS_A)}-{pick(CODE_WORDS_B)}`
		fundraiser = { Title = pick(CAUSES), Code = code, Key = onlyLetters(code), Raised = 0 }
		fundraisers[player] = fundraiser
		player:SetAttribute("FundraiserTitle", fundraiser.Title)
		player:SetAttribute("FundraiserCode", fundraiser.Code)
		player:SetAttribute("FundraiserRaised", 0)
	end
	return fundraiser
end

-- Did the player tell the caller their fundraiser ID somewhere in `text` (spaces and dashes don't matter)?
function PaymentService.HeardFundraiser(player: Player, text: string): boolean
	return string.find(onlyLetters(text), fundraiserOf(player).Key, 1, true) ~= nil
end

function PaymentService.Donate(player: Player, leadName: string, amount: number)
	local fundraiser = fundraiserOf(player)
	fundraiser.Raised += amount
	player:SetAttribute("FundraiserRaised", fundraiser.Raised)
	pay(player, "donation", `Donation to "{fundraiser.Title}"`, amount, leadName)
end

function PaymentService.Start()
	Namespace.listen(Call.queries.RedeemGiftCard, onRedeem, Namespace.busy)
	Namespace.listen(Call.queries.ChargeCard, onCharge, Namespace.busy)
	Players.PlayerAdded:Connect(fundraiserOf)
	for _, player in Players:GetPlayers() do
		fundraiserOf(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		giftCards[player] = nil
		cards[player] = nil
		fundraisers[player] = nil
		lastAttempt[player] = nil
	end)
end

return PaymentService
