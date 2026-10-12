--[[
	CoachService (server, Call Center Place)
	Keeps a few numbers about how each player's day is going, and turns them into tips for the performance
	review ("You asked for money before the caller trusted you...").

	CoachService.Note(player, what, amount?)
		what: "Calls" (got through), "HungUp" (the caller hung up on you), "Picks" (cards picked),
		      "Refreshes", "HookMatched" / "HookLanded" / "HookMissed" (hooks tried), "Paid" (a mini-game
		      paid out), "Perfect" (a perfect mini-game), "Bought" / "Upgraded" (Scamazon), "Chores"
	CoachService.Tips(player, passed) -> { string }     up to three, most useful first
	CoachService.NewDay()
]]

local Players = game:GetService("Players")

local CoachService = {}

local days: { [Player]: { [string]: number } } = {}

function CoachService.Note(player: Player, what: string, amount: number?)
	local day = days[player]
	if not day then
		day = {}
		days[player] = day
	end
	day[what] = (day[what] or 0) + (amount or 1)
end

local function plural(n: number, one: string, many: string): string
	return `{n} {if n == 1 then one else many}`
end

function CoachService.Tips(player: Player, passed: boolean): { string }
	local day = days[player] or {}
	local function get(what: string): number
		return day[what] or 0
	end
	local tips = {}
	local hooks = get("HookMatched") + get("HookLanded") + get("HookMissed")
	if get("HookMissed") >= 2 then
		table.insert(tips, `{plural(get("HookMissed"), "hook", "hooks")} didn't land. Check what the caller is `
			.. "WEAK TO in their file and pick the hook with the same badge.")
	end
	if get("HungUp") >= 2 then
		table.insert(tips, `{plural(get("HungUp"), "caller", "callers")} hung up on you. Start with small talk and `
			.. "their soft spot (see FILE), and watch out for the trap card.")
	end
	if get("Calls") < 4 then
		table.insert(tips, `You only reached {plural(get("Calls"), "caller", "callers")}. Call the next lead as soon `
			.. "as a call ends, and answer incoming calls.")
	elseif get("Paid") == 0 then
		table.insert(tips, if hooks == 0
			then "Nobody paid you today. Once trust passes the pay line, a gold HOOK card shows up: pick it."
			else "Nobody paid you today. A hook lands when it matches what the caller is weak to.")
	end
	if get("Bought") + get("Upgraded") == 0 and get("Paid") > 0 then
		table.insert(tips, "You never shopped in Scamazon. More apps mean a hook for every caller, and upgrades "
			.. "pay more for the same mini-game.")
	end
	if get("Refreshes") >= 6 then
		table.insert(tips, "You refreshed a lot. Refreshes past the free ones cost a tip, then a pick: trust the "
			.. "hint under the cards instead.")
	end
	if not passed and get("Chores") == 0 then
		table.insert(tips, "Chores pay a little, and a tidy office makes every caller start a bit warmer.")
	end
	if #tips == 0 then
		table.insert(tips, if passed
			then (if get("Perfect") > 0
				then "Nice work! A perfect mini-game pays 20% extra, so keep those runs clean."
				else "Nice work! Callers get sharper as the team nears quota, so make the easy money early.")
			else "So close! Split up the leads so everyone is on a call at the same time.")
	end
	while #tips > 3 do
		table.remove(tips)
	end
	return tips
end

function CoachService.NewDay()
	days = {}
end

function CoachService.Start()
	Players.PlayerRemoving:Connect(function(player)
		days[player] = nil
	end)
end

return CoachService
