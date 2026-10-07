--[[
	Boot (ReplicatedFirst)
	ReplicatedFirst loads before anything else, so this runs first: it puts the ChaOS boot screen up
	in place of Roblox's default loading screen. StarterPlayerScripts/Client -> LoadingController
	then drives it and fades it out when the desktop is ready.

	The LoadingScreen template lives next to this script. To preview it in the editor, copy it into
	StarterGui (ScreenGuis don't render inside ReplicatedFirst).
]]

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

local screen = script.Parent:WaitForChild("LoadingScreen"):Clone()
screen.Enabled = true
screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

ReplicatedFirst:RemoveDefaultLoadingScreen()
