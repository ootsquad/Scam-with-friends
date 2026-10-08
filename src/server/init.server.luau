--[[
	Server entry point, lobby place (ServerScriptService/Server)

	1. Require Shared.Network first: this publishes the ByteNet-Max packet ids that clients need.
	2. Start services. Each service lives in ./Services and exposes Start().
	   LobbyService runs this server's side of the cross-server parties (PartyCore, PartyBackend);
	   ShiftLauncher sends a party to the Call Center Place (see Shared.Config.Places).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Network"))

local Services = script:WaitForChild("Services")
local LobbyService = require(Services.LobbyService)
local SettingsService = require(Services.SettingsService)
local ShiftLauncher = require(Services.ShiftLauncher)

SettingsService.Start()
ShiftLauncher.Start()
LobbyService.Start()

print("[Call Center Chaos] Lobby server ready")
