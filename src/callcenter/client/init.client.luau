--[[
	Client entry point, Call Center Place (StarterPlayerScripts/Client)

	The boot screen is already up (ReplicatedFirst/Arrival picked it up from the teleport).
		1. Clocking in            build the ByteNet-Max namespaces
		2. Finding your desk      wait for ShiftService to publish this crew's shift
		3. Opening the phones     shift HUD

	Ui/ and Controllers/LoadingController are shared with the lobby place (see callcenter.project.json).
	Code that only exists here lives in Shift/.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LoadingController = require(script:WaitForChild("Controllers"):WaitForChild("LoadingController"))
local Shift = script:WaitForChild("Shift")

local SHIFT_TIMEOUT = 30

local function waitForShift()
	local started = os.clock()
	while ReplicatedStorage:GetAttribute("ShiftReady") ~= true do
		if os.clock() - started > SHIFT_TIMEOUT then
			error("the shift details never arrived")
		end
		task.wait(0.25)
	end
end

LoadingController.Start()

local booted = LoadingController.RunSteps({
	{
		status = "Clocking in…",
		run = function()
			require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Network"))
		end,
	},
	{
		status = "Finding your desk…",
		run = waitForShift,
	},
	{
		status = "Opening the phones…",
		run = function()
			require(Shift.ShiftHud).Start()
		end,
	},
}, "Shift started. Good luck.")

if booted then
	LoadingController.Hide()
	print(`[Call Center Chaos] Clocked in to shift {ReplicatedStorage:GetAttribute("ShiftCode")}`)
end
