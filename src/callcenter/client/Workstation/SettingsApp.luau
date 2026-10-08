--[[
	SettingsApp (client, Call Center Place)
	The workstation's Settings window: master / caller voice / sound effect volumes, wallpaper, interface
	size, 24-hour clock and reduce motion. Settings are shared with the lobby's Settings app, applied
	instantly and saved by the server (SettingsService).

	Volume sliders work with a mouse drag, a finger, or the - / + buttons (steps of 5%).

	SettingsApp.Start(window)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local SettingsConfig = require(ReplicatedStorage:WaitForChild("Shared").Config.SettingsConfig)

local Client = script.Parent.Parent
local SettingsStore = require(Client:WaitForChild("Stores"):WaitForChild("SettingsStore"))
local Ui = Client:WaitForChild("Ui")
local ButtonFx = require(Ui.ButtonFx)
local Motion = require(Ui.Motion)
local Theme = require(Ui.Theme)

local STEP = 5
local SLIDERS = {
	{ Row = "MasterRow", Key = "MasterVolume" },
	{ Row = "VoiceRow", Key = "VoiceVolume" },
	{ Row = "EffectsRow", Key = "EffectsVolume" },
}

local SettingsApp = {}

local body: any
local dragging: { key: string, track: GuiObject, input: InputObject? }? = nil

local function snap(value: number): number
	return math.clamp(math.round(value / STEP) * STEP, 0, 100)
end

local function renderSlider(row: any, value: number)
	row.Value.Text = `{value}%`
	row.Track.Fill.Size = UDim2.fromScale(value / 100, 1)
	row.Track.Knob.Position = UDim2.new(value / 100, 0, 0.5, 0)
end

local function renderToggle(toggle: TextButton, on: boolean)
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
	for _, slider in SLIDERS do
		local row = body:FindFirstChild(slider.Row)
		if row and not (dragging and dragging.key == slider.Key) then
			renderSlider(row, settings[slider.Key])
		end
	end
	for index, name in SettingsConfig.Wallpapers do
		local swatch = body.Wallpapers:FindFirstChild(name)
		if swatch then
			local selected = index == settings.Wallpaper
			swatch.BackgroundColor3 = if selected then Theme.Accent else Theme.White
			swatch.TextColor3 = if selected then Theme.White else Theme.NativeText
		end
	end
	for index, size in SettingsConfig.UiSizes do
		local button = body.UiSize:FindFirstChild(size.Name)
		if button then
			local on = index == settings.UiSize
			button.BackgroundColor3 = if on then Theme.Accent else Theme.White
			button.TextColor3 = if on then Theme.White else Theme.NativeText
		end
	end
	renderToggle(body.ClockRow.Toggle, settings.Clock24)
	renderToggle(body.MotionRow.Toggle, settings.ReduceMotion)
	body.SaveStatus.Text = if SettingsStore.Persistent
		then "Saved to your Roblox account (the lobby uses them too)"
		else "Settings reset when you leave (saving works in the published game)"
end

-- Slider value under a screen position.
local function valueAt(track: GuiObject, x: number): number
	local width = math.max(track.AbsoluteSize.X, 1)
	return snap((x - track.AbsolutePosition.X) / width * 100)
end

local function setVolume(key: string, value: number)
	if SettingsStore.Settings[key] ~= value then
		SettingsStore.Set(key, value)
	end
end

local function wireSlider(slider: { Row: string, Key: string })
	local row = body:FindFirstChild(slider.Row)
	if not row then
		warn(`[SettingsApp] no {slider.Row} in the Settings window`)
		return
	end
	local track = row.Track
	track.InputBegan:Connect(function(input: InputObject)
		local isMouse = input.UserInputType == Enum.UserInputType.MouseButton1
		if not isMouse and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		dragging = { key = slider.Key, track = track, input = if isMouse then nil else input }
		local value = valueAt(track, input.Position.X)
		renderSlider(row, value)
		setVolume(slider.Key, value)
	end)
	for _, pair in { { row.Minus, -STEP }, { row.Plus, STEP } } do
		local button, delta = pair[1], pair[2]
		ButtonFx.attach(button, 1.08, 0.92)
		button.MouseButton1Click:Connect(function()
			setVolume(slider.Key, snap(SettingsStore.Settings[slider.Key] + delta))
		end)
	end
end

function SettingsApp.Start(window: Frame)
	body = window:WaitForChild("Body")
	for _, slider in SLIDERS do
		wireSlider(slider)
	end

	UserInputService.InputChanged:Connect(function(input: InputObject)
		local current = dragging
		if not current then
			return
		end
		if current.input then
			if input ~= current.input then
				return
			end
		elseif input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		local value = valueAt(current.track, input.Position.X)
		local row = current.track.Parent :: any
		renderSlider(row, value)
		setVolume(current.key, value)
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		local current = dragging
		if current and (input.UserInputType == Enum.UserInputType.MouseButton1 or input == current.input) then
			dragging = nil
		end
	end)
	UserInputService.WindowFocusReleased:Connect(function()
		dragging = nil
	end)

	for index, name in SettingsConfig.Wallpapers do
		local swatch = body.Wallpapers:FindFirstChild(name)
		if swatch then
			ButtonFx.attach(swatch, 1.03, 0.96)
			swatch.MouseButton1Click:Connect(function()
				SettingsStore.Set("Wallpaper", index)
			end)
		end
	end
	for index, size in SettingsConfig.UiSizes do
		local button = body.UiSize:FindFirstChild(size.Name)
		if button then
			button.MouseButton1Click:Connect(function()
				SettingsStore.Set("UiSize", index)
			end)
		end
	end
	body.ClockRow.Toggle.MouseButton1Click:Connect(function()
		SettingsStore.Set("Clock24", not SettingsStore.Settings.Clock24)
	end)
	body.MotionRow.Toggle.MouseButton1Click:Connect(function()
		SettingsStore.Set("ReduceMotion", not SettingsStore.Settings.ReduceMotion)
	end)

	SettingsStore.Changed:Connect(render)
	render(SettingsStore.Settings)
end

return SettingsApp
