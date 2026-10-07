--[[
	Arrival (ReplicatedFirst, Call Center Place)
	The lobby hands its "clocking in" screen to TeleportService, so the crew sees it the whole way over.
	Pick that same screen back up here (or use the copy next to this script when testing in Studio)
	and keep it up until the client has loaded the shift.
]]

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local TeleportService = game:GetService("TeleportService")

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local function isBootScreen(gui: Instance?): boolean
	if not gui or not gui:IsA("ScreenGui") then
		return false
	end
	local root = gui:FindFirstChild("Root")
	return root ~= nil and root:FindFirstChild("Canvas") ~= nil
end

local ok, arriving = pcall(function()
	return TeleportService:GetArrivingTeleportGui()
end)

local screen: ScreenGui
if ok and isBootScreen(arriving) then
	screen = arriving
else
	screen = script.Parent:WaitForChild("LoadingScreen"):Clone()
end
screen.Name = "LoadingScreen"
screen.Enabled = true
screen.Parent = playerGui

ReplicatedFirst:RemoveDefaultLoadingScreen()
