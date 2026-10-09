--[[
	Client entry point, Call Center Place (StarterPlayerScripts/Client)

	The boot screen is already up (ReplicatedFirst/Arrival picked it up from the teleport).
		1. Clocking in               build the ByteNet-Max namespaces
		2. Finding your desk         wait for ShiftService to publish this crew's shift
		3. Loading your career       settings (sound, display) and your saved career
		4. Booting the workstations  leads, phone and apps (hidden until you sit at a Computer), sounds,
		                             and the HUD you see while walking around the office

	Ui/, Controllers/LoadingController and Stores/SettingsStore are shared with the lobby place (see
	callcenter.project.json). Code that only exists here lives in Workstation/.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LoadingController = require(script:WaitForChild("Controllers"):WaitForChild("LoadingController"))
local Workstation = script:WaitForChild("Workstation")

-- The server may take a while: it reads the shift from MemoryStore with retries before falling back.
local SHIFT_TIMEOUT = 75

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
		status = "Loading your career…",
		run = function()
			require(script:WaitForChild("Stores"):WaitForChild("SettingsStore")).Start()
			require(Workstation.CareerStore).Start()
		end,
	},
	{
		status = "Booting the workstations…",
		run = function()
			require(Workstation.CallStore).Start()
			require(Workstation.ShopStore).Start()
			require(Workstation.ChatTags).Start()
			require(Workstation.Sfx).Start()
			require(Workstation.WorkstationController).Start()
			require(Workstation.HudController).Start()
		end,
	},
}, "Grab an empty desk and sit down.", "Couldn't reach the call center. Try rejoining.")

if booted then
	task.wait(1)
	LoadingController.Hide()
	print(`[Call Center Chaos] Clocked in to shift {ReplicatedStorage:GetAttribute("ShiftCode")}`)
end
