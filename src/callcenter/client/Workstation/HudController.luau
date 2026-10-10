--[[
	HudController (client, Call Center Place)
	The ShiftHud screen, shown while you're walking around the office (the workstation takes over when you
	sit at a desk):
	  top bar     day, time until the review, the crew's floor, and the team against today's quota
	  side card   your take this shift, your career cash, leads you can call, chores waiting
	  checklist   the first-shift checklist (Checklist)
	  flash       "+$10 · Trash taken out" after a chore, "Take the trash bag to a trash bin" when you pick one up
	  review      the performance review with your tips, if it comes while you're away from a desk
	  team bonus  a Team Leader's +10%, while you have one in the crew
	  banner      office events: a virus attack, office chaos (with flashing alarms), prank calls
	  store       the equipment store, opened by the vendor's Shop prompt (StoreApp)
	  elevator    full-screen card when the crew moves floors (shown over everything, desk or not)

	HudController.Start()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CallConfig = require(Shared.Config.CallConfig)
local OfficeConfig = require(Shared.Config.OfficeConfig)
local Format = require(Shared.Util.Format)
local Network = require(Shared:WaitForChild("Network"))

local Client = script.Parent.Parent
local Ui = Client:WaitForChild("Ui")
local Images = require(Ui.Images)
local Theme = require(Ui.Theme)
local UiScale = require(Ui.UiScale)
local CallStore = require(script.Parent.CallStore)
local CareerStore = require(script.Parent.CareerStore)
local Checklist = require(script.Parent.Checklist)
local Sfx = require(script.Parent.Sfx)
local ShopStore = require(script.Parent.ShopStore)
local StoreApp = require(script.Parent.StoreApp)

local CHORE_TEXT = {
	Trash = "Trash taken out",
	Desk = "Desk cleaned",
	Fix = "Equipment fixed",
}
local FLASH_TIME = 2.5

local player = Players.LocalPlayer

local HudController = {}

local gui: ScreenGui
local root: Frame
local flashToken = 0
local elevatorToken = 0
local reviewToken = 0
local bannerToken = 0
local ALARM_PULSE = 0.6 -- seconds per flash

local function openLeads(): number
	local count = 0
	for _, lead in CallStore.Leads do
		if lead.Status == CallConfig.LeadStatus.Available then
			count += 1
		end
	end
	return count
end

local function atDesk(): boolean
	local desk = player:GetAttribute("Desk")
	return type(desk) == "string" and desk ~= ""
end

local function update()
	local hidden = atDesk()
	root.Bar.Visible = not hidden
	root.Side.Visible = not hidden
	root.Checklist:SetAttribute("Allowed", not hidden)
	root.TeamBonus.Visible = not hidden and player:GetAttribute("TeamBonus") == true
	if hidden then
		root.Review.Visible = false -- the computer shows the review
		root.Banner.Visible = false
		return
	end

	local bar = root.Bar
	local day = ReplicatedStorage:GetAttribute("ShiftDay") or 1
	local quota = ReplicatedStorage:GetAttribute("ShiftQuota") or 0
	local team = ReplicatedStorage:GetAttribute("ShiftTeam") or 0
	local endsAt = ReplicatedStorage:GetAttribute("ShiftDayEndsAt") or 0
	local floor = ReplicatedStorage:GetAttribute("OfficeFloor") or 1
	bar.Day.Text = `DAY {day}`
	if endsAt > 0 then
		bar.Time.Text = Format.duration(endsAt - workspace:GetServerTimeNow())
		bar.TimeLabel.Text = "UNTIL REVIEW"
	elseif ReplicatedStorage:GetAttribute("ShiftReviewing") then
		bar.Time.Text = "--:--"
		bar.TimeLabel.Text = "REVIEW"
	else
		bar.Time.Text = Format.duration(CallConfig.DayLength)
		bar.TimeLabel.Text = "STARTS AT LOGIN"
	end
	bar.Floor.Text = `FLOOR {floor}`
	bar.FloorName.Text = string.upper(OfficeConfig.FloorInfo(floor).Name)
	bar.Quota.Label.Text = `TEAM {Format.money(team)} / {Format.money(quota)}`
	bar.Quota.Track.Fill.Size = UDim2.fromScale(if quota > 0 then math.clamp(team / quota, 0, 1) else 0, 1)
	bar.Quota.Track.Fill.BackgroundColor3 = if quota > 0 and team >= quota then Theme.GreenBar else Theme.Accent

	local side = root.Side
	local data = CareerStore.Data
	side.You.Text = `YOU {Format.money(player:GetAttribute("ShiftPersonal") or 0)}`
	side.Career.Text = `CAREER {Format.money(if data then data.Cash else 0)}`
	local leads = openLeads()
	side.Leads.Text = `{leads} {if leads == 1 then "LEAD" else "LEADS"} OPEN`
	local chores = ReplicatedStorage:GetAttribute("OfficeChores") or 0
	side.Chores.Text = if chores > 0 then `{chores} {if chores == 1 then "CHORE" else "CHORES"} WAITING` else "OFFICE TIDY"
	side.Chores.TextColor3 = if chores > 0 then Theme.Yellow else Theme.GreenText

end

local function flash(text: string, color: Color3?)
	flashToken += 1
	local token = flashToken
	local label = root.Flash
	label.Text = text
	label.BackgroundColor3 = color or Theme.Green
	label.Visible = true
	task.delay(FLASH_TIME, function()
		if flashToken == token then
			label.Visible = false
		end
	end)
end

local function showElevator(info: any)
	elevatorToken += 1
	local token = elevatorToken
	local card = root.Elevator
	local panel = card.Panel
	local floorInfo = OfficeConfig.FloorInfo(info.Floor)
	panel.Kicker.Text = if info.Promoted then "PROMOTED!" else "ELEVATOR"
	panel.Floor.Text = `FLOOR {info.Floor}`
	panel.FloorName.Text = string.upper(floorInfo.Name)
	panel.JobTitle.Text = if info.Promoted then `You're now a {floorInfo.Title}.` else floorInfo.Title
	panel.Perk.Text = floorInfo.Perk
	for index = 1, #OfficeConfig.Floors do
		local dot = panel.Dots:FindFirstChild(`Dot{index}`)
		if dot then
			dot.BackgroundColor3 = if index <= info.Floor then Theme.Accent else Theme.ChecklistTodo
		end
	end
	card.Visible = true
	card.GroupTransparency = 1
	TweenService:Create(card, TweenInfo.new(0.35), { GroupTransparency = 0 }):Play()
	Sfx.Play("Ding")
	task.delay(OfficeConfig.ElevatorTime, function()
		if elevatorToken ~= token then
			return
		end
		local tween = TweenService:Create(card, TweenInfo.new(0.4), { GroupTransparency = 1 })
		tween:Play()
		tween.Completed:Wait()
		if elevatorToken == token then
			card.Visible = false
		end
	end)
end

-- The review card, for players who aren't at a desk when the day ends.
local function showReview(review: any)
	reviewToken += 1
	local token = reviewToken
	local card = root.Review
	card.Result.Text = if review.Passed then "QUOTA MET" else "YOU'RE FIRED"
	local stroke = card:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = if review.Passed then Theme.Green else Theme.Red
	end
	card.Summary.Text = `Day {review.Day} · Team {Format.money(review.Team)} of {Format.money(review.Quota)}`
		.. (if review.Passed then " · Moving up a floor!" else "")
	local tips = card.Tips
	local list = review.Tips or {}
	tips.Visible = #list > 0
	tips.Title.Text = if review.Passed then "TIPS" else "TIPS FOR NEXT TIME"
	for index = 1, 3 do
		local label = tips:FindFirstChild(`Tip{index}`)
		if label then
			label.Text = list[index] or ""
			label.Visible = list[index] ~= nil
		end
	end
	card.Visible = not atDesk()
	local seconds = if review.Passed then CallConfig.ReviewTime else CallConfig.FiredReturnDelay
	task.delay(seconds + 2, function()
		if reviewToken == token then
			card.Visible = false
		end
	end)
end

-- What an office event says on the HUD banner (nil = no banner).
local function bannerText(event: any): (string?, string?)
	if event.Kind == "Virus" then
		return "VIRUS ATTACK!", `Set off by {event.By}. Close the pop-ups at a desk for a cleanup bonus.`
	elseif event.Kind == "Chaos" then
		return "OFFICE CHAOS!", `Set off by {event.By}. Clean up the mess: chores pay double for a while!`
	elseif event.Kind == "Prank" then
		if event.Target == player.DisplayName then
			return nil -- don't spoil it
		end
		return "PRANK CALL!", `{event.By} sent {event.Target} a prank call.`
	end
	return nil
end

local function showBanner(event: any)
	local title, sub = bannerText(event)
	if not title or atDesk() then
		return
	end
	bannerToken += 1
	local token = bannerToken
	local banner = root.Banner
	banner.Title.Text = title
	banner.Sub.Text = sub or ""
	banner.Visible = true
	Sfx.Play("Ding")
	task.delay(6, function()
		if bannerToken == token then
			banner.Visible = false
		end
	end)
end

-- Flashing red alarms while office chaos is on (ReplicatedStorage OfficeAlarmUntil).
local function runAlarm()
	local alarm = root.Alarm
	while gui.Parent do
		local untilTime = ReplicatedStorage:GetAttribute("OfficeAlarmUntil") or 0
		local on = workspace:GetServerTimeNow() < untilTime
		if on then
			alarm.Visible = true
			alarm.BackgroundTransparency = 0.78
			TweenService:Create(alarm, TweenInfo.new(ALARM_PULSE / 2), { BackgroundTransparency = 0.94 }):Play()
			task.wait(ALARM_PULSE)
		else
			alarm.Visible = false
			task.wait(0.5)
		end
	end
end

function HudController.Start()
	gui = player:WaitForChild("PlayerGui"):WaitForChild("ShiftHud") :: ScreenGui
	root = gui:WaitForChild("Root") :: Frame
	UiScale.virtual(gui, root)
	Images.bind(root)
	root.Elevator.Visible = false
	root.Flash.Visible = false
	root.Review.Visible = false
	root.Banner.Visible = false
	root.Alarm.Visible = false
	root.TeamBonus.Visible = false
	gui.Enabled = true
	StoreApp.Start(root.Store)
	ShopStore.Event:Connect(showBanner)
	ShopStore.Message:Connect(function(message)
		if not atDesk() then
			flash(message.Text, if message.Kind == 3 then Theme.Red elseif message.Kind == 2 then Theme.Green else Theme.Accent)
		end
	end)
	ShopStore.Changed:Connect(update)
	task.spawn(runAlarm)
	root.Review.CloseButton.MouseButton1Click:Connect(function()
		reviewToken += 1
		root.Review.Visible = false
	end)
	Network.Shift.packets.Review.listen(showReview)

	-- Phones and tablets: the thumbstick lives in the lower left, so the checklist moves up out of its way.
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		root.Checklist.AnchorPoint = Vector2.zero
		root.Checklist.Position = UDim2.fromOffset(16, 90)
	end
	Checklist.bind(root.Checklist)
	CareerStore.Elevator:Connect(showElevator)
	CareerStore.Chore:Connect(function(done)
		Sfx.Play("Chore")
		flash(`+{Format.money(done.Reward)} · {CHORE_TEXT[done.Kind] or "Chore done"}`)
	end)
	player:GetAttributeChangedSignal("CarryingTrash"):Connect(function()
		if player:GetAttribute("CarryingTrash") then
			flash("Take the trash bag to a trash bin.", Theme.Accent)
		end
	end)
	CareerStore.Changed:Connect(update)
	player:GetAttributeChangedSignal("Desk"):Connect(update)

	task.spawn(function()
		while gui.Parent do
			update()
			task.wait(0.5)
		end
	end)
end

return HudController
