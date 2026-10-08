--[[
	OfficeService (server, Call Center Place)
	The office tower. Every shift starts on floor 1; each passed review moves the crew one floor up, ending
	at the Executive Penthouse (OfficeConfig.Floors). The floor's perk applies to every call.

	Floors are built in Studio (see OFFICE.md): a Model or Folder tagged "OfficeFloor" with a number
	attribute "Floor", holding that floor's Computer seats and a Part named "FloorSpawn". When the crew moves
	up, everyone sees the elevator screen and is moved to the new floor's spawn; desks on other floors can't
	be used. If the floor they're heading to isn't built yet, they stay on the highest built floor below it
	(the perks still go up). With no floors built at all, the whole place is one office.

	ReplicatedStorage attributes: OfficeFloor, OfficeFloorName, OfficeFloorTitle, OfficeFloorPerk,
	OfficeFloorsBuilt.

	OfficeService.Start()
	OfficeService.Floor() -> number                     the crew's floor (1-6)
	OfficeService.Perks() -> OfficeConfig.Floor
	OfficeService.SetFloor(floor, promoted)
	OfficeService.IsActive(instance) -> boolean         on the floor the crew works on (or not on any floor)
	OfficeService.FloorOf(instance) -> number?           the built floor it's on
	OfficeService.ActiveFloorInstance() -> Instance?
	OfficeService.OnFloorChanged(callback(floor))
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OfficeConfig = require(Shared.Config.OfficeConfig)
local Career = require(Shared:WaitForChild("Network")).Career
local CareerService = require(script.Parent.CareerService)

local ARRIVAL_SPACING = 3 -- studs between players arriving at a spawn

local OfficeService = {}

local floor = 1
local floorCallbacks: { (number) -> () } = {}

-- ---------------------------------------------------------------------------
-- Built floors
-- ---------------------------------------------------------------------------

local function floorNumber(instance: Instance): number?
	local value = instance:GetAttribute("Floor")
	if type(value) == "number" and value % 1 == 0 and value >= 1 then
		return value
	end
	return nil
end

-- Built floors by number.
local function builtFloors(): { [number]: Instance }
	local out = {}
	for _, instance in CollectionService:GetTagged(OfficeConfig.FloorTag) do
		local number = floorNumber(instance)
		if number and instance:IsDescendantOf(workspace) and not out[number] then
			out[number] = instance
		end
	end
	return out
end

-- The built floor the crew uses for floor `target`: the highest built one at or below it, else the lowest.
local function builtFor(target: number): (Instance?, number?)
	local built = builtFloors()
	local best, bestNumber, lowest, lowestNumber = nil, nil, nil, nil
	for number, instance in built do
		if number <= target and (not bestNumber or number > bestNumber) then
			best, bestNumber = instance, number
		end
		if not lowestNumber or number < lowestNumber then
			lowest, lowestNumber = instance, number
		end
	end
	if best then
		return best, bestNumber
	end
	return lowest, lowestNumber
end

function OfficeService.FloorOf(instance: Instance): number?
	local current: Instance? = instance
	while current and current ~= workspace do
		if CollectionService:HasTag(current, OfficeConfig.FloorTag) then
			return floorNumber(current)
		end
		current = current.Parent
	end
	return nil
end

function OfficeService.ActiveFloorInstance(): Instance?
	return (builtFor(floor))
end

function OfficeService.IsActive(instance: Instance): boolean
	local on = OfficeService.FloorOf(instance)
	if on == nil then
		return true -- not part of any floor (or no floors built): always usable
	end
	local _, activeNumber = builtFor(floor)
	return on == activeNumber
end

-- Where the crew arrives on a floor.
local function spawnOf(floorInstance: Instance): CFrame?
	for _, descendant in floorInstance:GetDescendants() do
		if
			descendant:IsA("BasePart")
			and (descendant.Name == OfficeConfig.SpawnName or CollectionService:HasTag(descendant, OfficeConfig.SpawnName))
		then
			return descendant.CFrame + Vector3.new(0, descendant.Size.Y / 2 + 3, 0)
		end
	end
	for _, descendant in floorInstance:GetDescendants() do
		if descendant:IsA("SpawnLocation") then
			return descendant.CFrame + Vector3.new(0, descendant.Size.Y / 2 + 3, 0)
		end
	end
	for _, descendant in floorInstance:GetDescendants() do
		if descendant:IsA("Seat") then
			return descendant.CFrame * CFrame.new(0, 2, 4)
		end
	end
	return nil
end

local function standUp(humanoid: Humanoid)
	local seat = humanoid.SeatPart
	if seat then
		local weld = seat:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
	end
	humanoid.Sit = false
end

local function moveTo(player: Player, target: CFrame, index: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or not character:FindFirstChild("HumanoidRootPart") then
		return
	end
	standUp(humanoid)
	local column = (index - 1) % 4 - 1.5
	local row = (index - 1) // 4
	character:PivotTo(target * CFrame.new(column * ARRIVAL_SPACING, 0, row * ARRIVAL_SPACING))
end

local function moveCrew(floorInstance: Instance)
	local target = spawnOf(floorInstance)
	if not target then
		warn(`[OfficeService] {floorInstance:GetFullName()} has no "{OfficeConfig.SpawnName}" part; the crew stays put`)
		return
	end
	for index, player in Players:GetPlayers() do
		moveTo(player, target, index)
	end
end

-- ---------------------------------------------------------------------------
-- Signs and attributes
-- ---------------------------------------------------------------------------

local function signText(number: number): string
	return `FLOOR {number} · {string.upper(OfficeConfig.FloorInfo(number).Name)}`
end

-- A sign on a floor shows that floor; a sign anywhere else (an elevator, a lobby) shows the crew's floor.
local function updateSign(sign: Instance)
	local text = signText(OfficeService.FloorOf(sign) or floor)
	local labels = if sign:IsA("TextLabel") then { sign } else sign:GetDescendants()
	for _, label in labels do
		if label:IsA("TextLabel") then
			label.Text = text
		end
	end
end

local function updateSigns()
	for _, sign in CollectionService:GetTagged(OfficeConfig.SignTag) do
		updateSign(sign)
	end
end

local function publish()
	local info = OfficeConfig.FloorInfo(floor)
	ReplicatedStorage:SetAttribute("OfficeFloor", floor)
	ReplicatedStorage:SetAttribute("OfficeFloorName", info.Name)
	ReplicatedStorage:SetAttribute("OfficeFloorTitle", info.Title)
	ReplicatedStorage:SetAttribute("OfficeFloorPerk", info.Perk)
	local count = 0
	for _ in builtFloors() do
		count += 1
	end
	ReplicatedStorage:SetAttribute("OfficeFloorsBuilt", count)
	updateSigns()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function OfficeService.Floor(): number
	return floor
end

function OfficeService.Perks(): OfficeConfig.Floor
	return OfficeConfig.FloorInfo(floor)
end

function OfficeService.OnFloorChanged(callback: (number) -> ())
	table.insert(floorCallbacks, callback)
end

function OfficeService.SetFloor(target: number, promoted: boolean)
	target = math.clamp(target, 1, #OfficeConfig.Floors)
	if target == floor then
		return
	end
	local before = builtFor(floor)
	floor = target
	for _, player in Players:GetPlayers() do
		CareerService.ReachedFloor(player, floor)
		if CareerService.IsReady(player) then
			Career.packets.Elevator.sendTo({ Floor = floor, Promoted = promoted }, player)
		end
	end
	print(`[OfficeService] the crew is on floor {floor} ({OfficeConfig.FloorInfo(floor).Name})`)

	-- Move everyone while the elevator screen covers the switch.
	local after = builtFor(floor)
	task.delay(OfficeConfig.ElevatorTime * 0.4, function()
		publish()
		if after and after ~= before then
			moveCrew(after)
		end
		for _, callback in floorCallbacks do
			task.spawn(callback, floor)
		end
	end)
end

function OfficeService.Start()
	publish()
	local function refresh()
		task.defer(publish)
	end
	CollectionService:GetInstanceAddedSignal(OfficeConfig.FloorTag):Connect(refresh)
	CollectionService:GetInstanceRemovedSignal(OfficeConfig.FloorTag):Connect(refresh)
	CollectionService:GetInstanceAddedSignal(OfficeConfig.SignTag):Connect(updateSign)

	-- Players spawn wherever the place's SpawnLocations are; with floors built, they arrive on the crew's floor.
	local function onCharacter(player: Player, character: Model)
		local floorInstance = builtFor(floor)
		if not floorInstance then
			return
		end
		local target = spawnOf(floorInstance)
		if not target then
			return
		end
		if not character:WaitForChild("HumanoidRootPart", 10) then
			return
		end
		task.wait(0.1)
		if character.Parent and player.Character == character then
			local index = table.find(Players:GetPlayers(), player) or 1
			moveTo(player, target, index)
		end
	end
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
		if player.Character then
			task.spawn(onCharacter, player, player.Character)
		end
		CareerService.ReachedFloor(player, floor)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
end

return OfficeService
