--[[
	CoachService (server, Call Center Place)
	Keeps a few numbers about how each player's day is going, and turns them into tips for the performance
	review ("You asked for money before the caller trusted you...").

	CoachService.Note(player, what, amount?)
		what: "Calls" (got through), "HungUp" (the caller hung up on you), "Blocked" (Roblox hid your line),
		      "EarlyAsk" (asked for money below the pay line), "Paid" (a caller paid), "Issued" (a caller read
		      out a code or card), "Cashed" (you cashed a code or card in), "Chores", "Ideas"
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
	local unclaimed = get("Issued") - get("Cashed")
	if unclaimed > 0 then
		table.insert(tips, `You got {plural(unclaimed, "payment", "payments")} you never cashed in. Redeem gift `
			.. "cards in Gift Cards and charge cards in Card Terminal right away.")
	end
	if get("EarlyAsk") >= 2 then
		table.insert(tips, `You asked for money {plural(get("EarlyAsk"), "time", "times")} before the caller `
			.. "trusted you. Wait until their trust passes the white pay line, then ask.")
	end
	if get("HungUp") >= 2 then
		table.insert(tips, `{plural(get("HungUp"), "caller", "callers")} hung up on you. Start with small talk and `
			.. "their soft spot (see FILE), and don't rush to the money.")
	end
	if get("Calls") < 4 then
		table.insert(tips, `You only reached {plural(get("Calls"), "caller", "callers")}. Call the next lead as soon `
			.. "as a call ends, and answer incoming calls.")
	elseif get("Paid") == 0 then
		table.insert(tips, "Nobody paid you today. Once trust passes the pay line, ask for the payment method "
			.. "listed in their caller file.")
	end
	if get("Blocked") >= 3 then
		table.insert(tips, `Roblox hid {get("Blocked")} of your lines. Skip numbers, names, places and links, or `
			.. "tap Ideas for a ready-made line.")
	end
	if not passed and get("Chores") == 0 then
		table.insert(tips, "Chores pay a little, and a tidy office makes every caller start a bit warmer.")
	end
	if #tips == 0 then
		table.insert(tips, if passed
			then "Nice work! Callers get sharper as the team nears quota, so make the easy money early."
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
