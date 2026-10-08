--[[
	Client entry point (StarterPlayerScripts/Client)

	Boot order, shown on the ChaOS boot screen:
		1. Starting ChaOS          preload the desktop GUI
		2. Dialing the server      build the ByteNet-Max namespaces the server published
		3. Loading your settings   SettingsStore
		4. Checking on your crew   LobbyStore (are you already in a lobby?)
		5. Opening your desktop    DesktopController (icons, taskbar, apps)

	Layout: Controllers/ run screens, Apps/ are the desktop windows, Stores/ hold client state,
	Ui/ has shared UI helpers.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Controllers = script:WaitForChild("Controllers")
local Stores = script:WaitForChild("Stores")
local LoadingController = require(Controllers.LoadingController)

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

LoadingController.Start()

local booted = LoadingController.RunSteps({
	{
		status = "Starting ChaOS…",
		run = function()
			local desktop = playerGui:WaitForChild("Desktop") :: ScreenGui
			desktop.Enabled = false -- stays hidden until it has real data
			ContentProvider:PreloadAsync({ desktop })
		end,
	},
	{
		status = "Dialing the server…",
		run = function()
			require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Network"))
		end,
	},
	{
		status = "Loading your settings…",
		run = function()
			require(Stores.SettingsStore).Start()
		end,
	},
	{
		status = "Checking on your crew…",
		run = function()
			require(Stores.LobbyStore).Start()
		end,
	},
	{
		status = "Opening your desktop…",
		run = function()
			require(Controllers.DesktopController).Start()
		end,
	},
}, nil, "ChaOS couldn't start. Try rejoining.")

if booted then
	LoadingController.Hide()
	print("[Call Center Chaos] Client ready")
end
