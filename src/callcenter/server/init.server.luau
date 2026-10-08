--[[
	Server entry point, Call Center Place (ServerScriptService/Server)

	Each crew plays in its own reserved server of this place.
		ShiftService     whose shift this is (code, difficulty, crew), Leave shift
		EconomyService   personal/team money, daily quota, day timer and performance review
		AvatarService    dresses ServerStorage.LeadRig with random catalog items for each fake caller
		PlayerLookService  players look like their own Roblox avatars
		LeadService      each player's list of made-up people to call
		PaymentService   gift card codes, card details and donations, and the apps that cash them in
		DeskService      seats tagged "Computer" and the username login
		CallService      phone calls with AI callers (Claude), trust and payouts
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Network"))

local Services = script:WaitForChild("Services")
local ShiftService = require(Services.ShiftService)
local EconomyService = require(Services.EconomyService)
local AvatarService = require(Services.AvatarService)
local PlayerLookService = require(Services.PlayerLookService)
local LeadService = require(Services.LeadService)
local PaymentService = require(Services.PaymentService)
local DeskService = require(Services.DeskService)
local CallService = require(Services.CallService)

ShiftService.Start()
EconomyService.Start()
AvatarService.Start()
PlayerLookService.Start()
LeadService.Start()
PaymentService.Start()
DeskService.Start()
CallService.Start()

print("[Call Center Chaos] Call center server ready")
