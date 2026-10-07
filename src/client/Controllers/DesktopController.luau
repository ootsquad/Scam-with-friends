--[[
	DesktopController (client)
	Runs the ChaOS desktop: wallpaper, desktop icons, taskbar (apps, lobby status, clock), Start menu,
	notifications, and the three apps (Play / Join with Code / Settings).

	When the host starts the shift it shows the "clocking in" screen and hands it to TeleportService so
	it stays up while the crew teleports into their private Call Center Place server.

	DesktopController.Start()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared.Config.LobbyConfig)
local SettingsConfig = require(Shared.Config.SettingsConfig)

local Client = script.Parent.Parent
local LobbyStore = require(Client.Stores.LobbyStore)
local SettingsStore = require(Client.Stores.SettingsStore)
local Ui = Client.Ui
local Avatar = require(Ui.Avatar)
local ButtonFx = require(Ui.ButtonFx)
local Motion = require(Ui.Motion)
local Notify = require(Ui.Notify)
local Theme = require(Ui.Theme)
local UiScale = require(Ui.UiScale)
local WindowManager = require(Ui.WindowManager)
local Apps = Client.Apps
local JoinApp = require(Apps.JoinApp)
local LobbyApp = require(Apps.LobbyApp)
local SettingsApp = require(Apps.SettingsApp)
local LoadingController = require(script.Parent.LoadingController)

local Phase = LobbyConfig.Phase
local player = Players.LocalPlayer

local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local DesktopController = {}

local gui: ScreenGui
local root: Frame
local clock24 = false
local shownPhase = Phase.Lobby
local launching = false

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function setControlsEnabled(enabled: boolean)
	-- Keep the character still while the desktop covers the screen.
	local ok, controls = pcall(function()
		local playerModule = player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 5)
		return playerModule and require(playerModule):GetControls()
	end)
	if ok and controls then
		if enabled then
			controls:Enable()
		else
			controls:Disable()
		end
	end
end

-- Play: open your lobby, or create one if you're not in one.
local function launchPlay()
	if LobbyStore.InLobby() then
		WindowManager.open("Lobby")
		return
	end
	if launching then
		return
	end
	launching = true
	local result = LobbyStore.Create()
	launching = false
	if result.Ok then
		if LobbyStore.InLobby() then
			WindowManager.open("Lobby")
		end
	else
		Notify.show("Couldn't open a lobby", result.Message, Theme.Red)
	end
end

local function updateClock()
	local now = os.date("*t")
	local timeText
	if clock24 then
		timeText = string.format("%02d:%02d", now.hour, now.min)
	else
		local hour = now.hour % 12
		timeText = string.format("%d:%02d %s", if hour == 0 then 12 else hour, now.min, if now.hour < 12 then "AM" else "PM")
	end
	local clock = root.Taskbar.Tray.Clock
	clock.Time.Text = timeText
	clock.Date.Text = string.format("%s, %s %d, %d", WEEKDAYS[now.wday], MONTHS[now.month], now.day, now.year)
end

local function applyWallpaper(index: number)
	local theme = Theme.Wallpapers[index] or Theme.Wallpapers[1]
	local wallpaper = root.Wallpaper
	wallpaper.Sky.Gradient.Color = theme.Sky
	wallpaper.Water.Gradient.Color = theme.Water
	wallpaper.Sun.BackgroundColor3 = theme.Sun
	wallpaper.Sun.BackgroundTransparency = theme.SunTransparency
	wallpaper.Halo.BackgroundColor3 = theme.Sun
	wallpaper.Halo.BackgroundTransparency = theme.HaloTransparency
	for _, peak in wallpaper.RidgeBack:GetChildren() do
		peak.BackgroundColor3 = theme.Back
	end
	for _, peak in wallpaper.RidgeFront:GetChildren() do
		peak.BackgroundColor3 = theme.Front
	end
	for _, child in wallpaper:GetChildren() do
		if string.sub(child.Name, 1, 5) == "Shine" then
			child.BackgroundColor3 = theme.Shine
			child.BackgroundTransparency = theme.ShineTransparency
		end
	end
end

local function applySettings(settings: any)
	applyWallpaper(settings.Wallpaper)

	local size = SettingsConfig.UiSizes[settings.UiSize] or SettingsConfig.UiSizes[2]
	UiScale.SetMultiplier(size.Scale)

	Motion.Enabled = not settings.ReduceMotion

	clock24 = settings.Clock24
	updateClock()
end

-- ---------------------------------------------------------------------------
-- Desktop pieces
-- ---------------------------------------------------------------------------

local function wireIcons()
	local icons = root.Icons
	local actions = {
		PlayIcon = launchPlay,
		JoinIcon = function()
			WindowManager.open("Join")
		end,
		SettingsIcon = function()
			WindowManager.open("Settings")
		end,
	}
	for name, action in actions do
		local icon = icons:FindFirstChild(name)
		if icon then
			icon.BackgroundColor3 = Theme.White
			ButtonFx.highlight(icon, 0.8)
			icon.MouseButton1Click:Connect(action)
		end
	end
end

local function wireStartMenu()
	local menu = root.StartMenu
	local dismiss = root.MenuDismiss
	local startButton = root.Taskbar.Apps.Start

	local function setOpen(open: boolean)
		menu.Visible = open
		dismiss.Visible = open
	end
	setOpen(false)

	Avatar.apply(menu.Avatar, player.UserId, 150)
	menu.DisplayName.Text = player.DisplayName
	menu.Username.Text = `@{player.Name}`

	startButton.BackgroundColor3 = Theme.White
	ButtonFx.highlight(startButton, 0.88)
	startButton.MouseButton1Click:Connect(function()
		setOpen(not menu.Visible)
	end)
	dismiss.MouseButton1Click:Connect(function()
		setOpen(false)
	end)

	local actions = {
		Play = launchPlay,
		JoinCode = function()
			WindowManager.open("Join")
		end,
		Settings = function()
			WindowManager.open("Settings")
		end,
		LeaveLobby = LobbyStore.Leave,
	}
	for name, action in actions do
		local item = menu.Items:FindFirstChild(name)
		if item then
			item.BackgroundColor3 = Theme.White
			ButtonFx.highlight(item, 0.9)
			item.MouseButton1Click:Connect(function()
				setOpen(false)
				action()
			end)
		end
	end
end

local function startClock()
	task.spawn(function()
		while gui.Parent do
			updateClock()
			task.wait(1)
		end
	end)
end

local function updateTray(state: any)
	local info = root.Taskbar.Tray.Info
	if state then
		local readyCount = 0
		for _, seat in state.Seats do
			if seat.Ready then
				readyCount += 1
			end
		end
		info.Line1.Text = `LOBBY {state.Code}`
		info.Line1.TextColor3 = Theme.GreenText
		info.Line2.Text = `CREW {#state.Seats}/{LobbyConfig.MaxDesks} · {readyCount} READY`
		info.Line2.TextColor3 = Theme.Yellow
	else
		info.Line1.Text = `@{string.upper(player.Name)}`
		info.Line1.TextColor3 = Theme.White
		info.Line2.Text = "NOT IN A LOBBY"
		info.Line2.TextColor3 = Theme.TrayIdle
	end
end

local function onLobbyChanged(state: any)
	updateTray(state)
	root.StartMenu.Items.LeaveLobby.Visible = state ~= nil and state.Phase == Phase.Lobby

	local phase = if state then state.Phase else Phase.Lobby
	if phase == shownPhase then
		return
	end
	local previous = shownPhase
	shownPhase = phase

	if phase == Phase.Starting then
		LoadingController.PlayShiftIntro(state.Countdown)
	elseif phase == Phase.Teleporting then
		LoadingController.SetStatus("Heading to the call center…")
		-- Keep the boot screen up during the teleport; the Call Center Place picks it up on arrival.
		local screen = LoadingController.GetGui()
		if screen then
			pcall(TeleportService.SetTeleportGui, TeleportService, screen)
		end
	elseif phase == Phase.Lobby and previous ~= Phase.Lobby then
		-- The shift didn't start (e.g. teleport failed): back to the desktop.
		task.spawn(LoadingController.Hide)
	end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function DesktopController.Start()
	local playerGui = player:WaitForChild("PlayerGui")
	gui = playerGui:WaitForChild("Desktop") :: ScreenGui
	root = gui:WaitForChild("Root") :: Frame
	UiScale.virtual(gui, root)

	local windows = root.Windows
	local apps = root.Taskbar.Apps
	WindowManager.init(root, windows)
	Notify.init(root.Notifications)

	WindowManager.register("Lobby", windows.LobbyWindow, apps.PlayTask, launchPlay)
	WindowManager.register("Join", windows.JoinWindow, apps.JoinTask)
	WindowManager.register("Settings", windows.SettingsWindow, apps.SettingsTask)

	-- Apply settings before the apps start so they render with the right motion/scale from the first frame.
	startClock()
	SettingsStore.Changed:Connect(applySettings)
	applySettings(SettingsStore.Settings)

	LobbyApp.Start(windows.LobbyWindow, launchPlay)
	JoinApp.Start(windows.JoinWindow)
	SettingsApp.Start(windows.SettingsWindow)

	wireIcons()
	wireStartMenu()

	LobbyStore.Changed:Connect(onLobbyChanged)
	onLobbyChanged(LobbyStore.State)
	LobbyStore.Notice:Connect(function(message: string)
		Notify.show("Lobby", message)
	end)

	task.spawn(setControlsEnabled, false)
	gui.Enabled = true
end

return DesktopController
