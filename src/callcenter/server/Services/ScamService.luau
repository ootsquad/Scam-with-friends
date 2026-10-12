--[[
	ScamService (server, Call Center Place)
	The scam apps and the Scamazon store, and the money a mini-game takes.

	Every player starts a shift with the free apps (ScamConfig: price 0) at tier 1 and buys the rest, or
	upgrades, in Scamazon with shift cash (EconomyService.Spend). Nothing is saved: a new shift starts fresh.

	On a call, each owned app is a hook (CallService). When a hook lands, its mini-game runs on the client
	and sends back a score; the payout is
	  caller's Can-spare x score x tier bonus x weakness match, plus the floor's and the router's share
	(EconomyService.Award adds 2x cash and the Team Leader bonus). The server never trusts the client's
	score beyond clamping it (CallService).

	ScamService.Start()
	ScamService.Tier(player, appKey) -> number          0 = not owned
	ScamService.Owned(player) -> { { App, Tier } }
	ScamService.Hooks(player, weak) -> { App }          owned apps, the ones that fit `weak` first
	ScamService.Expect(app, tier, budget, matched) -> number    what a 1.0 score pays, before perks
	ScamService.Payout(player, app, tier, budget, matched, score, leadName) -> number   pays it (returns the total)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ScamConfig = require(Shared.Config.ScamConfig)
local Format = require(Shared.Util.Format)
local Network = require(Shared:WaitForChild("Network"))
local Call = Network.Call
local Scam = Network.Scam
local Namespace = require(Shared.Network.Namespace)
local CareerService = require(script.Parent.CareerService)
local CoachService = require(script.Parent.CoachService)
local EconomyService = require(script.Parent.EconomyService)
local OfficeService = require(script.Parent.OfficeService)

local ScamService = {}

local owned: { [Player]: { [string]: number } } = {} -- app key -> tier

local function result(ok: boolean, message: string)
	return { Ok = ok, Message = message }
end

local function appsOf(player: Player): { [string]: number }
	local apps = owned[player]
	if not apps then
		apps = {}
		for _, app in ScamConfig.Apps do
			if app.Price == 0 then
				apps[app.Key] = 1
			end
		end
		owned[player] = apps
	end
	return apps
end

function ScamService.Tier(player: Player, appKey: string): number
	return appsOf(player)[appKey] or 0
end

function ScamService.Owned(player: Player): { { App: string, Tier: number } }
	local out = {}
	for _, app in ScamConfig.Apps do
		local tier = appsOf(player)[app.Key]
		if tier then
			table.insert(out, { App = app.Key, Tier = tier })
		end
	end
	return out
end

local function publish(player: Player)
	if player.Parent then
		Scam.packets.Apps.sendTo(ScamService.Owned(player), player)
	end
end

-- Owned apps in hook order: matching the caller's weakness first (dearest first), then the rest.
function ScamService.Hooks(player: Player, weak: string): { ScamConfig.App }
	local apps = appsOf(player)
	local matching, others = {}, {}
	for _, app in ScamConfig.Apps do
		if apps[app.Key] then
			table.insert(if app.Weak == weak then matching else others, app)
		end
	end
	local function byPrice(a: ScamConfig.App, b: ScamConfig.App)
		return a.Price > b.Price
	end
	table.sort(matching, byPrice)
	table.sort(others, byPrice)
	for _, app in others do
		table.insert(matching, app)
	end
	return matching
end

function ScamService.Expect(app: ScamConfig.App, tier: number, budget: number, matched: boolean): number
	local tierInfo = ScamConfig.Tiers[math.clamp(tier, 1, #ScamConfig.Tiers)]
	local amount = budget * tierInfo.Bonus * (if matched then 1 + ScamConfig.MatchBonus else 1)
	return math.max(1, math.round(amount))
end

function ScamService.Payout(
	player: Player,
	app: ScamConfig.App,
	tier: number,
	budget: number,
	matched: boolean,
	score: number,
	leadName: string
): number
	local base = math.max(1, math.round(ScamService.Expect(app, tier, budget, matched) * score))
	local share = OfficeService.Perks().PayoutBonus + CareerService.Tier(player, "Router").Value
	local total = EconomyService.Award(player, base + math.max(0, math.round(base * share)))
	local bonus = math.max(0, total - base)
	local tierInfo = ScamConfig.Tiers[math.clamp(tier, 1, #ScamConfig.Tiers)]
	local detail = `{app.Name} {tierInfo.Name}` .. (if matched then " · matched" else "")
		.. (if score >= ScamConfig.PerfectScore then " · perfect" else "")
	if player.Parent then
		Call.packets.Payout.sendTo({
			App = app.Key,
			Label = app.Name,
			Detail = detail,
			Amount = total,
			Bonus = bonus,
			LeadName = leadName,
		}, player)
	end
	return total
end

-- ---------------------------------------------------------------------------
-- Scamazon
-- ---------------------------------------------------------------------------

local function onBuy(request: any, player: Player)
	if type(request) ~= "table" then
		return result(false, "Pick an app.")
	end
	local app = ScamConfig.App(tostring(request.App))
	local tier = math.floor(tonumber(request.Tier) or 0)
	if not app then
		return result(false, "Scamazon doesn't sell that.")
	end
	local have = ScamService.Tier(player, app.Key)
	if tier ~= have + 1 then
		if tier <= have then
			return result(false, `You already have {app.Name}{if have > 1 then " " .. ScamConfig.Tiers[have].Name else ""}.`)
		end
		return result(false, `Get {app.Name}{if have == 0 then "" else " " .. ScamConfig.Tiers[have + 1].Name} first.`)
	end
	if tier > #ScamConfig.Tiers then
		return result(false, `{app.Name} is maxed out.`)
	end
	local cost = ScamConfig.Cost(app, tier)
	if not EconomyService.Spend(player, cost) then
		return result(false, `You need {Format.money(cost - EconomyService.Balance(player))} more shift cash.`)
	end
	appsOf(player)[app.Key] = tier
	CoachService.Note(player, if tier == 1 then "Bought" else "Upgraded")
	CareerService.CompleteStep(player, "Scamazon")
	publish(player)
	local tierInfo = ScamConfig.Tiers[tier]
	return result(true, if tier == 1
		then `{app.Name} is on your desktop. Its hook shows up on your next call.`
		else `{app.Name} is now {tierInfo.Name}: {tierInfo.Help}.`)
end

local function onGetApps(_: nil, player: Player)
	return ScamService.Owned(player)
end

function ScamService.Start()
	Namespace.listen(Scam.queries.Buy, onBuy, Namespace.busy)
	Namespace.listen(Scam.queries.GetApps, onGetApps, function(_: nil, player: Player)
		task.delay(2, publish, player) -- the list follows in an Apps packet
		return {}
	end)
	Players.PlayerRemoving:Connect(function(player)
		owned[player] = nil
	end)
end

return ScamService
