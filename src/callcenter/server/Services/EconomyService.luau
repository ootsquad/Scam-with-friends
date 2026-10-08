--[[
	EconomyService (server, Call Center Place)
	Money and the work day. Every payout goes to the player (personal, and their saved career cash) and the
	crew (team). Each day has a quota; when the day timer runs out there's a performance review. Meet the
	quota and the crew moves up a floor and the next day starts with a bigger quota. Miss it and the whole
	crew is fired and sent back to the lobby.

	The day clock starts when the first player logs in at a desk. Money made while the review is on screen
	counts toward the next day.

	ReplicatedStorage attributes: ShiftDay, ShiftQuota, ShiftTeam, ShiftDayEndsAt (server time, 0 = not
	running), ShiftReviewing, ShiftFired.  Player attribute: ShiftPersonal.

	EconomyService.Start()
	EconomyService.StartClock()
	EconomyService.Award(player, amount)
	EconomyService.IsFired() -> boolean
	EconomyService.IsRunning() -> boolean          the day clock is ticking (not before login, not in a review)
	EconomyService.Day() -> number
	EconomyService.Progress() -> number   share of today's quota the crew has made (0 = nothing, 1 = quota met)
	EconomyService.OnDayStart(callback(day))
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CallConfig = require(Shared.Config.CallConfig)
local LobbyConfig = require(Shared.Config.LobbyConfig)
local Shift = require(Shared:WaitForChild("Network")).Shift
local CareerService = require(script.Parent.CareerService)
local LeadService = require(script.Parent.LeadService)
local ShiftService = require(script.Parent.ShiftService)

local EconomyService = {}

local personal: { [Player]: number } = {}
local today: { [Player]: number } = {} -- kept for players who left today, so the review can still credit them
local team = 0
local day = 1
local running = false -- the day clock has started at least once
local ticking = false -- a day is in progress right now
local fired = false
local dayToken = 0
local dayStartCallbacks: { (number) -> () } = {}

local function quotaFor(dayNumber: number): number
	local shift = ShiftService.Get()
	local difficulty = LobbyConfig.Difficulties[shift and shift.Difficulty or LobbyConfig.DefaultDifficulty]
	return math.round(difficulty.Quota * (1 + difficulty.Growth) ^ (dayNumber - 1) / 10) * 10
end

local function publish()
	ReplicatedStorage:SetAttribute("ShiftDay", day)
	ReplicatedStorage:SetAttribute("ShiftQuota", quotaFor(day))
	ReplicatedStorage:SetAttribute("ShiftTeam", team)
	ReplicatedStorage:SetAttribute("ShiftFired", fired)
end

local startDay: () -> ()

local function topEarner(): (Player?, number)
	local best, bestAmount = nil, 0
	for player, amount in today do
		if amount > bestAmount then
			best, bestAmount = player, amount
		end
	end
	return best, bestAmount
end

local function endOfDay(token: number)
	if token ~= dayToken then
		return
	end
	ticking = false
	local quota = quotaFor(day)
	local reviewed = team
	local passed = reviewed >= quota
	local top, topAmount = topEarner()
	ReplicatedStorage:SetAttribute("ShiftDayEndsAt", 0)
	ReplicatedStorage:SetAttribute("ShiftReviewing", true)
	Shift.packets.Review.sendToList({
		Day = day,
		Team = reviewed,
		Quota = quota,
		Passed = passed,
		TopName = if top then top.DisplayName else "",
		TopAmount = topAmount,
		NextQuota = if passed then quotaFor(day + 1) else 0,
	}, LeadService.ReadyPlayers())
	print(`[EconomyService] day {day}: ${reviewed} of ${quota} -> {if passed then "passed" else "fired"}`)

	if passed then
		for _, player in Players:GetPlayers() do
			CareerService.Count(player, "DaysPassed")
		end
		task.wait(CallConfig.ReviewTime)
		day += 1
		team -= reviewed -- money made during the review counts toward the new day
		today = {}
		ReplicatedStorage:SetAttribute("ShiftReviewing", false)
		publish()
		startDay()
		return
	end

	fired = true
	publish()
	task.wait(CallConfig.FiredReturnDelay)
	ReplicatedStorage:SetAttribute("ShiftReviewing", false)
	if RunService:IsStudio() then
		-- Studio can't teleport: start over at day 1 so testing can continue.
		fired = false
		day = 1
		team = 0
		today = {}
		publish()
		startDay()
		return
	end
	for _, player in Players:GetPlayers() do
		task.spawn(ShiftService.SendToLobby, player, "You were fired! Start a new shift from the lobby.")
	end
end

startDay = function()
	dayToken += 1
	local token = dayToken
	ticking = true
	ReplicatedStorage:SetAttribute("ShiftDayEndsAt", workspace:GetServerTimeNow() + CallConfig.DayLength)
	task.delay(CallConfig.DayLength, endOfDay, token)
	for _, callback in dayStartCallbacks do
		task.spawn(callback, day)
	end
end

function EconomyService.StartClock()
	if running then
		return
	end
	running = true
	startDay()
end

function EconomyService.Award(player: Player, amount: number)
	amount = math.max(0, math.floor(amount))
	if amount == 0 then
		return
	end
	personal[player] = (personal[player] or 0) + amount
	today[player] = (today[player] or 0) + amount
	team += amount
	player:SetAttribute("ShiftPersonal", personal[player])
	ReplicatedStorage:SetAttribute("ShiftTeam", team)
	CareerService.Earned(player, amount)
end

function EconomyService.IsFired(): boolean
	return fired
end

function EconomyService.IsRunning(): boolean
	return ticking and not fired
end

function EconomyService.Day(): number
	return day
end

function EconomyService.Progress(): number
	local quota = quotaFor(day)
	return if quota > 0 then team / quota else 0
end

function EconomyService.OnDayStart(callback: (number) -> ())
	table.insert(dayStartCallbacks, callback)
end

function EconomyService.Start()
	publish()
	ReplicatedStorage:SetAttribute("ShiftDayEndsAt", 0)
	ReplicatedStorage:SetAttribute("ShiftReviewing", false)
	local function setup(player: Player)
		player:SetAttribute("ShiftPersonal", personal[player] or 0)
	end
	Players.PlayerAdded:Connect(setup)
	for _, player in Players:GetPlayers() do
		setup(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		personal[player] = nil
		-- today[player] stays until the next day so the review can still credit them
	end)
end

return EconomyService
