--[[
	Server entry point, Call Center Place (ServerScriptService/Server)

	Each crew plays in its own reserved server of this place.
		ShiftService     whose shift this is (code, difficulty, crew), Leave shift
		CareerService    each player's saved career: career cash, best floor, stats, equipment, checklist, credits
		PerkService      game passes and bought perks: 2x cash, Team Leader, VIP, on-call tips, call saves
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
		DisasterService  Virus Attack and Office Chaos
		ShopService      Robux developer products (ProcessReceipt)
		SettingsService  (shared with the lobby) sound and display settings
		ImageService     (shared with the lobby) the game's images, decal ids turned into image ids
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Network"))
local OfficeConfig = require(ReplicatedStorage.Shared.Config.OfficeConfig)

local Services = script:WaitForChild("Services")
local ShiftService = require(Services.ShiftService)
local CareerService = require(Services.CareerService)
local PerkService = require(Services.PerkService)
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
local DisasterService = require(Services.DisasterService)
local ShopService = require(Services.ShopService)
local SettingsService = require(ServerScriptService:WaitForChild("Common"):WaitForChild("SettingsService"))
local ImageService = require(ServerScriptService.Common:WaitForChild("ImageService"))

ImageService.Start() -- first, so the players' screens get their images as soon as possible

ShiftService.Start()
CareerService.Start()
PerkService.Start()
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
DisasterService.Start()
ShopService.Start()
SettingsService.Start()

-- Day N of a shift is worked on floor N (up to the penthouse).
EconomyService.OnDayStart(function(day)
	OfficeService.SetFloor(math.min(day, #OfficeConfig.Floors), day > 1)
end)

print("[Call Center Chaos] Call center server ready")
