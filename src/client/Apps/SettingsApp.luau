--[[
	SettingsApp (client)
	The ChaOS "Settings" window: wallpaper, interface size, 24-hour clock and reduce motion.
	Edits go through SettingsStore (applied instantly, saved by the server).

	SettingsApp.Start(window)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SettingsConfig = require(ReplicatedStorage:WaitForChild("Shared").Config.SettingsConfig)

local Client = script.Parent.Parent
local SettingsStore = require(Client.Stores.SettingsStore)
local Ui = Client.Ui
local ButtonFx = require(Ui.ButtonFx)
local Motion = require(Ui.Motion)
local Theme = require(Ui.Theme)

local SIZE_NAMES = {}
for index, size in SettingsConfig.UiSizes do
	SIZE_NAMES[index] = size.Name
end

local SettingsApp = {}

local ui: any

local function renderToggle(toggle: TextButton, on: boolean)
	-- Windows-style switch: filled blue when on, outlined when off.
	toggle.BackgroundColor3 = if on then Theme.Accent else Theme.White
	local outline = toggle:FindFirstChildOfClass("UIStroke")
	if outline then
		outline.Transparency = if on then 1 else 0
	end
	local knob = toggle:FindFirstChild("Knob") :: Frame
	knob.BackgroundColor3 = if on then Theme.White else Theme.ToggleOff
	Motion.tween(knob, Motion.FAST, { Position = UDim2.fromOffset(if on then 28 else 4, 4) })
end

local function render(settings: any)
	for index, name in SettingsConfig.Wallpapers do
		local swatch = ui.wallpapers:FindFirstChild(name)
		if swatch then
			local selected = index == settings.Wallpaper
			swatch.Ring.Stroke.Transparency = if selected then 0 else 1
			swatch.Label.TextColor3 = if selected then Theme.NativeText else Theme.NativeMuted
		end
	end

	for index, name in SIZE_NAMES do
		local button = ui.uiSize:FindFirstChild(name)
		if button then
			local on = index == settings.UiSize
			button.BackgroundColor3 = if on then Theme.Accent else Theme.White
			button.TextColor3 = if on then Theme.White else Theme.NativeText
		end
	end

	renderToggle(ui.clockToggle, settings.Clock24)
	renderToggle(ui.motionToggle, settings.ReduceMotion)

	ui.saveStatus.Text = if SettingsStore.Persistent
		then "Settings are saved to your Roblox account"
		else "Settings reset when you leave (saving works in the published game)"
end

function SettingsApp.Start(window: Frame)
	local body = window:WaitForChild("Body")
	ui = {
		wallpapers = body:WaitForChild("Wallpapers"),
		uiSize = body:WaitForChild("UiSize"),
		clockToggle = body:WaitForChild("ClockRow"):WaitForChild("Toggle"),
		motionToggle = body:WaitForChild("MotionRow"):WaitForChild("Toggle"),
		saveStatus = body:WaitForChild("SaveStatus"),
	}

	for index, name in SettingsConfig.Wallpapers do
		local swatch = ui.wallpapers:FindFirstChild(name)
		if swatch then
			ButtonFx.attach(swatch, 1.02, 0.97)
			swatch.MouseButton1Click:Connect(function()
				SettingsStore.Set("Wallpaper", index)
			end)
		end
	end

	for index, name in SIZE_NAMES do
		local button = ui.uiSize:FindFirstChild(name)
		if button then
			button.MouseButton1Click:Connect(function()
				SettingsStore.Set("UiSize", index)
			end)
		end
	end

	ui.clockToggle.MouseButton1Click:Connect(function()
		SettingsStore.Set("Clock24", not SettingsStore.Settings.Clock24)
	end)
	ui.motionToggle.MouseButton1Click:Connect(function()
		SettingsStore.Set("ReduceMotion", not SettingsStore.Settings.ReduceMotion)
	end)

	SettingsStore.Changed:Connect(render)
	render(SettingsStore.Settings)
end

return SettingsApp
