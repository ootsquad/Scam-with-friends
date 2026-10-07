--[[
	Server entry point, Call Center Place (ServerScriptService/Server)

	Each crew plays in its own reserved server of this place. ShiftService figures out whose shift
	this is and publishes it for clients. Gameplay services (calls, payouts, quota) go next to it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Network"))

local Services = script:WaitForChild("Services")
local ShiftService = require(Services.ShiftService)

ShiftService.Start()

print("[Call Center Chaos] Call center server ready")
