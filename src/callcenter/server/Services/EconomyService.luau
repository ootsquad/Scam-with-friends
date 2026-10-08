--[[
	EconomyService (server, Call Center Place)
	Money and the work day. Every payout goes to the player (personal) and the crew (team). Each day has a
	quota; when the day timer runs out there's a performance review. Meet the quota and the next day starts
	with a bigger one. Miss it and the whole crew is fired and sent back to the lobby.

	The day clock starts when the first player logs in at a desk.

	ReplicatedStorage attributes: ShiftDay, ShiftQuota, ShiftTeam, ShiftDayEndsAt (server time, 0 = not
	running), ShiftFired.  Player attribute: ShiftPersonal.

	EconomyService.Start()
	EconomyService.StartClock()
	EconomyService.Award(player, amount)
	EconomyService.IsFired() -> boolean
	EconomyService.Progress() -> number   share of today's quota the crew has made (0 = nothing, 1 = quota met)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CallConfig = require(Shared.Config.CallConfig)
local LobbyConfig = require(Shared.Config.LobbyConfig)
local Shift = require(Shared:WaitForChild("Network")).Shift
local LeadService = require(script.Parent.LeadService)
local ShiftService = require(script.Parent.ShiftService)

local EconomyService = {}

local personal: { [Player]: number } = {}
local today: { [Player]: number } = {}
local team = 0
local day = 1
local running = false
local fired = false
local dayToken = 0

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
		if player.Parent and amount > bestAmount then
			best, bestAmount = player, amount
		end
	end
	return best, bestAmount
end

local function endOfDay(token: number)
	if token ~= dayToken then
		return
	end
	local quota = quotaFor(day)
	local passed = team >= quota
	local top, topAmount = topEarner()
	ReplicatedStorage:SetAttribute("ShiftDayEndsAt", 0)
	Shift.packets.Review.sendToList({
		Day = day,
		Team = team,
		Quota = quota,
		Passed = passed,
		TopName = if top then top.DisplayName else "",
		TopAmount = topAmount,
		NextQuota = if passed then quotaFor(day + 1) else 0,
	}, LeadService.ReadyPlayers())
	print(`[EconomyService] day {day}: ${team} of ${quota} -> {if passed then "passed" else "fired"}`)

	if passed then
		task.wait(CallConfig.ReviewTime)
		day += 1
		team = 0
		today = {}
		publish()
		startDay()
		return
	end

	fired = true
	publish()
	task.wait(CallConfig.FiredReturnDelay)
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
	ReplicatedStorage:SetAttribute("ShiftDayEndsAt", workspace:GetServerTimeNow() + CallConfig.DayLength)
	task.delay(CallConfig.DayLength, endOfDay, token)
end

function EconomyService.StartClock()
	if running then
		return
	end
	running = true
	startDay()
end

function EconomyService.Award(player: Player, amount: number)
	personal[player] = (personal[player] or 0) + amount
	today[player] = (today[player] or 0) + amount
	team += amount
	player:SetAttribute("ShiftPersonal", personal[player])
	ReplicatedStorage:SetAttribute("ShiftTeam", team)
end

function EconomyService.IsFired(): boolean
	return fired
end

function EconomyService.Progress(): number
	local quota = quotaFor(day)
	return if quota > 0 then team / quota else 0
end

function EconomyService.Start()
	publish()
	ReplicatedStorage:SetAttribute("ShiftDayEndsAt", 0)
	local function setup(player: Player)
		player:SetAttribute("ShiftPersonal", personal[player] or 0)
	end
	Players.PlayerAdded:Connect(setup)
	for _, player in Players:GetPlayers() do
		setup(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		personal[player] = nil
		-- today[player] is kept so the review can still credit them (cleared at the next day)
	end)
end

return EconomyService
