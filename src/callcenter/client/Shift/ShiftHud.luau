--[[
	ShiftHud (client, Call Center Place)
	The ChaOS taskbar for a running shift: shift code and difficulty, quota, who's clocked in, the
	clock, and a "Leave shift" button that sends you back to the lobby after a confirm dialog.

	Reads the shift from the ReplicatedStorage attributes ShiftService publishes.

	ShiftHud.Start()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shift = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Network")).Shift

local Ui = script.Parent.Parent:WaitForChild("Ui")
local ButtonFx = require(Ui.ButtonFx)
local Notify = require(Ui.Notify)
local Theme = require(Ui.Theme)
local UiScale = require(Ui.UiScale)

local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local LEAVE_RESET = 8 -- seconds before "Leaving…" gives up waiting for the teleport

local ShiftHud = {}

local gui: ScreenGui
local root: Frame
local leaving = false

local function attr(name: string, default: any): any
	local value = ReplicatedStorage:GetAttribute(name)
	return if value == nil then default else value
end

local function render()
	local info = root.Taskbar.Tray.Info
	local online = attr("ShiftCrewOnline", 1)
	local size = math.max(attr("ShiftCrewSize", 0), online)
	info.Line1.Text = `SHIFT {attr("ShiftCode", "—")} · {string.upper(attr("ShiftDifficultyName", ""))}`
	info.Line1.TextColor3 = Theme.GreenText
	info.Line2.Text = `QUOTA ${attr("ShiftQuota", 0)} · CREW {online}/{size}`
	info.Line2.TextColor3 = if online < size then Theme.Yellow else Theme.White
end

local function updateClock()
	local now = os.date("*t")
	local hour = now.hour % 12
	local clock = root.Taskbar.Tray.Clock
	clock.Time.Text =
		string.format("%d:%02d %s", if hour == 0 then 12 else hour, now.min, if now.hour < 12 then "AM" else "PM")
	clock.Date.Text = string.format("%s, %s %d, %d", WEEKDAYS[now.wday], MONTHS[now.month], now.day, now.year)
end

local function setLeaving(value: boolean)
	leaving = value
	local button = root.Windows.LeaveWindow.Body.Footer.LeaveButton
	button.Text = if value then "Leaving…" else "Leave shift"
	button.BackgroundColor3 = if value then Theme.NativeFaint else Theme.Red
end

local function wireLeaveDialog()
	local window = root.Windows.LeaveWindow
	local taskButton = root.Taskbar.Apps.LeaveTask
	local footer = window.Body.Footer
	local close = window.TitleBar.Close

	local function setOpen(open: boolean)
		window.Visible = open
		taskButton.Indicator.Visible = open
		ButtonFx.setIdle(taskButton, if open then 0.82 else 1)
	end
	setOpen(false)

	taskButton.BackgroundColor3 = Theme.White
	ButtonFx.highlight(taskButton, 0.88)
	taskButton.MouseButton1Click:Connect(function()
		setOpen(not window.Visible)
	end)

	-- Windows-style close button: red fill and white cross on hover.
	local function paintClose(hover: boolean)
		close.BackgroundColor3 = Theme.RedHover
		close.BackgroundTransparency = if hover then 0 else 1
		close.BarA.BackgroundColor3 = if hover then Theme.White else Theme.Red
		close.BarB.BackgroundColor3 = if hover then Theme.White else Theme.Red
	end
	paintClose(false)
	close.MouseEnter:Connect(function()
		paintClose(true)
	end)
	close.MouseLeave:Connect(function()
		paintClose(false)
	end)
	close.MouseButton1Click:Connect(function()
		paintClose(false)
		setOpen(false)
	end)

	ButtonFx.attach(footer.StayButton, 1.02, 0.97)
	footer.StayButton.MouseButton1Click:Connect(function()
		setOpen(false)
	end)

	ButtonFx.attach(footer.LeaveButton, 1.02, 0.97)
	footer.LeaveButton.MouseButton1Click:Connect(function()
		if leaving then
			return
		end
		setLeaving(true)
		Shift.packets.LeaveShift.send()
		task.delay(LEAVE_RESET, function()
			if leaving then
				setLeaving(false)
			end
		end)
	end)
end

function ShiftHud.Start()
	gui = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("ShiftHud") :: ScreenGui
	root = gui:WaitForChild("Root") :: Frame
	UiScale.virtual(gui, root)
	Notify.init(root.Notifications)

	wireLeaveDialog()

	render()
	for _, name in { "ShiftCode", "ShiftDifficultyName", "ShiftQuota", "ShiftCrewSize", "ShiftCrewOnline" } do
		ReplicatedStorage:GetAttributeChangedSignal(name):Connect(render)
	end

	Shift.packets.Notice.listen(function(message: string)
		setLeaving(false)
		Notify.show("Shift", message, Theme.Yellow)
	end)

	task.spawn(function()
		while gui.Parent do
			updateClock()
			task.wait(1)
		end
	end)

	gui.Enabled = true
end

return ShiftHud
