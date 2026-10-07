--[[
	Server entry point, lobby place (ServerScriptService/Server)

	1. Require Shared.Network first: this publishes the ByteNet-Max packet ids that clients need.
	2. Start services. Each service lives in ./Services and exposes Start().
	   ShiftLauncher sends crews to the Call Center Place (see Shared.Config.Places).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Network"))

local Services = script:WaitForChild("Services")
local LobbyDirectory = require(Services.LobbyDirectory)
local LobbyService = require(Services.LobbyService)
local SettingsService = require(Services.SettingsService)
local ShiftLauncher = require(Services.ShiftLauncher)

LobbyDirectory.Start()
SettingsService.Start()
ShiftLauncher.Start()
LobbyService.Start()

print("[Call Center Chaos] Lobby server ready")
