--[[
	Server entry point, Call Center Place (ServerScriptService/Server)

	Each crew plays in its own reserved server of this place.
		ShiftService     whose shift this is (code, difficulty, crew), Leave shift
		CareerService    each player's saved career: career cash, best floor, stats, equipment, checklist
		EconomyService   personal/team money, daily quota, day timer and performance review
		OfficeService    the office tower: the crew moves up a floor after each passed review
		VendorService    the equipment store's vendor ("Shop" prompt); buying only works next to it
		AvatarService    dresses ServerStorage.LeadRig with random catalog items for each fake caller
		PlayerLookService  players look like their own Roblox avatars
		LeadService      each player's list of made-up people to call
		PaymentService   gift card codes, card details and donations, and the apps that cash them in
		DeskService      seats tagged "Computer", the "Sit down" prompts and the username login
		ChoreService     trash, messy desks and broken equipment around the office
		TextFilter       Roblox text filtering for what players say and what callers say back
		CoachService     how each player's day went, for the tips in the performance review
		CallService      phone calls with AI callers (Claude), trust and payouts, ready-made lines (Ideas)
		SettingsService  (shared with the lobby) sound and display settings
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Network"))
local OfficeConfig = require(ReplicatedStorage.Shared.Config.OfficeConfig)

local Services = script:WaitForChild("Services")
local ShiftService = require(Services.ShiftService)
local CareerService = require(Services.CareerService)
local EconomyService = require(Services.EconomyService)
local OfficeService = require(Services.OfficeService)
local VendorService = require(Services.VendorService)
local AvatarService = require(Services.AvatarService)
local PlayerLookService = require(Services.PlayerLookService)
local LeadService = require(Services.LeadService)
local PaymentService = require(Services.PaymentService)
local DeskService = require(Services.DeskService)
local ChoreService = require(Services.ChoreService)
local TextFilter = require(Services.TextFilter)
local CoachService = require(Services.CoachService)
local CallService = require(Services.CallService)
local SettingsService = require(ServerScriptService:WaitForChild("Common"):WaitForChild("SettingsService"))

ShiftService.Start()
CareerService.Start()
EconomyService.Start()
OfficeService.Start()
VendorService.Start()
AvatarService.Start()
PlayerLookService.Start()
LeadService.Start()
PaymentService.Start()
DeskService.Start()
ChoreService.Start()
TextFilter.Start()
CoachService.Start()
CallService.Start()
SettingsService.Start()

-- Day N of a shift is worked on floor N (up to the penthouse).
EconomyService.OnDayStart(function(day)
	OfficeService.SetFloor(math.min(day, #OfficeConfig.Floors), day > 1)
end)

print("[Call Center Chaos] Call center server ready")
