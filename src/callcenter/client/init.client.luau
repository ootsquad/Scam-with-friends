--[[
	Client entry point, Call Center Place (StarterPlayerScripts/Client)

	The boot screen is already up (ReplicatedFirst/Arrival picked it up from the teleport).
		1. Clocking in               build the ByteNet-Max namespaces
		2. Finding your desk         wait for ShiftService to publish this crew's shift
		3. Booting the workstations  leads, phone and apps (hidden until you sit at a Computer)

	Ui/ and Controllers/LoadingController are shared with the lobby place (see callcenter.project.json).
	Code that only exists here lives in Workstation/.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LoadingController = require(script:WaitForChild("Controllers"):WaitForChild("LoadingController"))
local Workstation = script:WaitForChild("Workstation")

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
		status = "Booting the workstations…",
		run = function()
			require(Workstation.CallStore).Start()
			require(Workstation.WorkstationController).Start()
		end,
	},
}, "Grab an empty desk and sit down.")

if booted then
	task.wait(1)
	LoadingController.Hide()
	print(`[Call Center Chaos] Clocked in to shift {ReplicatedStorage:GetAttribute("ShiftCode")}`)
end
