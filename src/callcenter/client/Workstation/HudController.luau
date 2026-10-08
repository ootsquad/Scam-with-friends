--[[
	HudController (client, Call Center Place)
	The ShiftHud screen, shown while you're walking around the office (the workstation takes over when you
	sit at a desk):
	  top bar     day, time until the review, the crew's floor, and the team against today's quota
	  side card   your take this shift, your career cash, leads you can call, chores waiting
	  hint        what to do next ("Sit down at a free computer", "Take the trash to a bin", ...)
	  checklist   the first-shift checklist (Checklist)
	  flash       "+$10 · Trash taken out" after a chore
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

local Client = script.Parent.Parent
local Ui = Client:WaitForChild("Ui")
local Theme = require(Ui.Theme)
local UiScale = require(Ui.UiScale)
local CallStore = require(script.Parent.CallStore)
local CareerStore = require(script.Parent.CareerStore)
local Checklist = require(script.Parent.Checklist)
local Sfx = require(script.Parent.Sfx)

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

local function hintText(): string
	if ReplicatedStorage:GetAttribute("ShiftFired") then
		return "You're fired! Heading back to the lobby…"
	elseif ReplicatedStorage:GetAttribute("ShiftReviewing") then
		return "Performance review in progress…"
	elseif player:GetAttribute("CarryingTrash") then
		return "Take the trash bag to a trash bin."
	end
	local chores = ReplicatedStorage:GetAttribute("OfficeChores") or 0
	local loggedInOnce = CareerStore.StepDone(OfficeConfig.StepIndex("Login") or 0)
	if not loggedInOnce then
		return "Find a free computer and use the Sit down prompt to start your shift."
	elseif chores > 0 then
		return `{chores} {if chores == 1 then "chore needs" else "chores need"} doing. Look for prompts around the office.`
	end
	return "Sit at a computer to keep calling."
end

local function update()
	local hidden = atDesk()
	root.Bar.Visible = not hidden
	root.Side.Visible = not hidden
	root.Hint.Visible = not hidden
	root.Checklist:SetAttribute("Allowed", not hidden)
	if hidden then
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

	root.Hint.Text = hintText()
end

local function flash(text: string)
	flashToken += 1
	local token = flashToken
	local label = root.Flash
	label.Text = text
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

function HudController.Start()
	gui = player:WaitForChild("PlayerGui"):WaitForChild("ShiftHud") :: ScreenGui
	root = gui:WaitForChild("Root") :: Frame
	UiScale.virtual(gui, root)
	root.Elevator.Visible = false
	root.Flash.Visible = false
	gui.Enabled = true

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
