--[[
	CareerStore (client, Call Center Place)
	Your saved career as the server last sent it (career cash, best floor, stats, equipment, first-shift
	checklist), plus the office events that come with it.

	CareerStore.Data                          -- Network.Career CareerData (nil until loaded)
	CareerStore.Changed:Connect(function(data) end)
	CareerStore.Elevator:Connect(function(info) end)     -- { Floor, Promoted }: the crew is moving floors
	CareerStore.Chore:Connect(function(done) end)        -- { Kind, Reward }: you finished a chore
	CareerStore.OpenStore:Connect(function() end)         -- you used the store vendor's Shop prompt
	CareerStore.OpenTechStore:Connect(function() end)     -- you talked to the Tech Store dealer
	CareerStore.Buy(kindIndex, tier) -> Result            (yields)
	CareerStore.SetTutorialHidden(hidden)
	CareerStore.StepDone(index) -> boolean
	CareerStore.TutorialHidden() -> boolean
	CareerStore.Owned(kind) -> number                     tier owned (1 = the starter item)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OfficeConfig = require(Shared.Config.OfficeConfig)
local Signal = require(Shared.Util.Signal)
local Namespace = require(Shared:WaitForChild("Network"):WaitForChild("Namespace"))

local CareerStore = {
	Data = nil :: any,
	Changed = Signal.new(),
	Elevator = Signal.new(),
	Chore = Signal.new(),
	OpenStore = Signal.new(),
	OpenTechStore = Signal.new(),
}

local Career: any

local function set(data: any)
	if type(data) ~= "table" then
		return
	end
	CareerStore.Data = data
	CareerStore.Changed:Fire(data)
end

function CareerStore.Start()
	Career = require(Shared.Network).Career
	Career.packets.Update.listen(set)
	Career.packets.Elevator.listen(function(info)
		CareerStore.Elevator:Fire(info)
	end)
	Career.packets.Chore.listen(function(done)
		CareerStore.Chore:Fire(done)
	end)
	Career.packets.OpenTechStore.listen(function()
		CareerStore.OpenTechStore:Fire()
	end)
	Career.packets.OpenStore.listen(function()
		CareerStore.OpenStore:Fire()
	end)
	-- Asking for the career also tells the server this client can receive career packets.
	set(Namespace.invoke(Career.queries.Get, nil))
end

function CareerStore.Buy(kindIndex: number, tier: number)
	local result = Namespace.invoke(Career.queries.Buy, { Kind = kindIndex, Tier = tier })
	if type(result) ~= "table" then
		return { Ok = false, Message = "The store didn't answer. Try again." }
	end
	return result
end

function CareerStore.SetTutorialHidden(hidden: boolean)
	Career.packets.HideTutorial.send(hidden)
end

function CareerStore.StepDone(index: number): boolean
	local data = CareerStore.Data
	return data ~= nil and bit32.btest(data.Tutorial, bit32.lshift(1, index))
end

function CareerStore.TutorialHidden(): boolean
	return CareerStore.StepDone(OfficeConfig.TutorialHiddenBit)
end

-- Steps done, out of how many.
function CareerStore.TutorialProgress(): (number, number)
	local done = 0
	for index in OfficeConfig.Tutorial do
		if CareerStore.StepDone(index) then
			done += 1
		end
	end
	return done, #OfficeConfig.Tutorial
end

function CareerStore.Owned(kind: string): number
	local data = CareerStore.Data
	return if data then data[kind] or 1 else 1
end

return CareerStore
