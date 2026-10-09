--[[
	CareerApp (client, Call Center Place)
	The Career window: your job title, career cash and lifetime stats on the left, and the office tower on
	the right (floor 6, the Penthouse, at the top). Each floor row shows its perk; the crew's
	current floor and your best floor are marked.

	CareerApp.Start(window)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OfficeConfig = require(Shared.Config.OfficeConfig)
local Format = require(Shared.Util.Format)

local Client = script.Parent.Parent
local Ui = Client:WaitForChild("Ui")
local Avatar = require(Ui.Avatar)
local Theme = require(Ui.Theme)
local CareerStore = require(script.Parent.CareerStore)

local player = Players.LocalPlayer

local CareerApp = {}

local body: any

local function number(value: number): string
	return string.sub(Format.money(value), 2) -- "1,234"
end

local function render()
	local data = CareerStore.Data
	local best = if data then data.BestFloor else 1
	local current = ReplicatedStorage:GetAttribute("OfficeFloor") or 1
	local floorInfo = OfficeConfig.FloorInfo(current)

	local profile = body.Profile
	profile.DisplayName.Text = player.DisplayName
	profile.JobTitle.Text = floorInfo.Title
	profile.Floors.Text = `On floor {current} today · best floor {best}`
	profile.Cash.Text = `Career cash {Format.money(if data then data.Cash else 0)}`

	local stats = body.Stats
	local values = {
		Shifts = if data then number(data.Shifts) else "0",
		Days = if data then number(data.DaysPassed) else "0",
		Earned = Format.money(if data then data.Earned else 0),
		Calls = if data then number(data.Calls) else "0",
		Scams = if data then number(data.Scams) else "0",
		Chores = if data then number(data.Chores) else "0",
	}
	for name, value in values do
		local cell = stats:FindFirstChild(name)
		if cell then
			cell.Value.Text = value
		end
	end

	for index, info in OfficeConfig.Floors do
		local row = body.Ladder:FindFirstChild(`Floor{index}`)
		if row then
			row.FloorName.Text = info.Name
			row.Perk.Text = `{info.Title} · {info.Perk}`
			local here = index == current
			row.BackgroundColor3 = if here then Theme.LadderCurrent else Theme.NativePanel
			row.Number.BackgroundColor3 = if index <= best then Theme.Accent else Theme.LadderLocked
			local tag = row.Tag
			if here then
				tag.Text = "CREW IS HERE"
				tag.BackgroundColor3 = Theme.Accent
				tag.Visible = true
			elseif index == best then
				tag.Text = "YOUR BEST"
				tag.BackgroundColor3 = Theme.Green
				tag.Visible = true
			else
				tag.Visible = false
			end
		end
	end

	body.Note.Text = if data and not data.Persistent
		then "Your career isn't saved in Studio test sessions."
		else "Saved to your account. Pass reviews to climb the tower."
end

function CareerApp.Start(window: Frame)
	body = window:WaitForChild("Body")
	Avatar.apply(body.Profile.Avatar, player.UserId, 150)
	CareerStore.Changed:Connect(render)
	ReplicatedStorage:GetAttributeChangedSignal("OfficeFloor"):Connect(render)
	render()
end

return CareerApp
