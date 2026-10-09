--[[
	ChoreService (server, Call Center Place)
	Office chores that show up while the day clock runs. Anyone can do them: walk up and hold the prompt.
	Each one pays a small bonus (personal, team and career) and keeps the office running:

	  Trash          bags show up on the floor. Pick one up (and, if the floor has bins tagged "TrashBin",
	                 carry it to a bin). No trash and no messy desks = a tidy office: every caller starts
	                 with OfficeConfig.Chores.TidyTrust extra trust.
	  Messy desk     a desk gets covered in coffee cups and paper. Calls from a messy desk start with
	                 MessyTrust less trust until someone cleans it.
	  Broken gear    a desk's computer (or a part tagged "Equipment", like the floor's router) starts
	                 smoking. Trust gains at that desk (the whole floor, for tagged equipment) are cut to
	                 BrokenGain until someone fixes it.

	Where they show up: Parts tagged "TrashSpot" for trash (else next to desks), desks tagged "Computer",
	Parts tagged "Equipment". Only on the floor the crew works on; moving floors clears them.

	ReplicatedStorage attributes: OfficeTidy, OfficeChores (how many are waiting), EquipmentDown.
	Seat attributes: Messy, Broken.

	ChoreService.Start()
	ChoreService.CallModifiers(player) -> (startTrust, gainMultiplier)
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OfficeConfig = require(Shared.Config.OfficeConfig)
local Career = require(Shared:WaitForChild("Network")).Career
local CareerService = require(script.Parent.CareerService)
local CoachService = require(script.Parent.CoachService)
local DeskService = require(script.Parent.DeskService)
local EconomyService = require(script.Parent.EconomyService)
local OfficeService = require(script.Parent.OfficeService)

local Config = OfficeConfig.Chores

type Chore = {
	id: number,
	kind: string, -- "Trash" | "Desk" | "Fix"
	model: Instance, -- what was added to the world (removed when done)
	prompt: ProximityPrompt,
	seat: Seat?, -- the desk (Desk, or Fix at a desk)
	floorWide: boolean, -- Fix on tagged equipment: affects every desk
	home: CFrame?, -- Trash: where the bag sits when nobody carries it
	carriedBy: Player?,
	done: boolean,
}

local ChoreService = {}

local chores: { Chore } = {}
local folder: Folder
local nextId = 0
local random = Random.new()

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function count(kind: string): number
	local n = 0
	for _, chore in chores do
		if chore.kind == kind then
			n += 1
		end
	end
	return n
end

local function publish()
	local messy, broken = false, false
	for _, chore in chores do
		if chore.kind == "Desk" then
			messy = true
		elseif chore.kind == "Fix" and chore.floorWide then
			broken = true
		end
	end
	ReplicatedStorage:SetAttribute("OfficeTidy", count("Trash") == 0 and not messy)
	ReplicatedStorage:SetAttribute("OfficeChores", #chores)
	ReplicatedStorage:SetAttribute("EquipmentDown", broken)
end

local function part(name: string, size: Vector3, color: Color3, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	if shape then
		p.Shape = shape
	end
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

local function prompt(parent: Instance, action: string, object: string, hold: number): ProximityPrompt
	local p = Instance.new("ProximityPrompt")
	p.Name = "ChorePrompt"
	p.ActionText = action
	p.ObjectText = object
	p.HoldDuration = hold
	p.MaxActivationDistance = 9
	p.RequiresLineOfSight = false
	p.KeyboardKeyCode = Enum.KeyCode.E
	p.Parent = parent
	return p
end

local function activeSeats(): { Seat }
	local out = {}
	for _, seat in DeskService.Seats() do
		if seat:IsDescendantOf(workspace) and OfficeService.IsActive(seat) then
			table.insert(out, seat)
		end
	end
	return out
end

local function activeTagged(tag: string): { BasePart }
	local out = {}
	for _, instance in CollectionService:GetTagged(tag) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(workspace) and OfficeService.IsActive(instance) then
			table.insert(out, instance)
		end
	end
	return out
end

local function characters(): { Instance }
	local list: { Instance } = { folder }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(list, player.Character)
		end
	end
	return list
end

-- The floor under a point (ignoring players and chores), or nil.
local function groundBelow(position: Vector3, depth: number, ignore: { Instance }?): Vector3?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local list = characters()
	for _, extra in ignore or {} do
		table.insert(list, extra)
	end
	params.FilterDescendantsInstances = list
	local hit = workspace:Raycast(position, Vector3.new(0, -depth, 0), params)
	return hit and hit.Position
end

local function pick<T>(list: { T }): T?
	if #list == 0 then
		return nil
	end
	return list[random:NextInteger(1, #list)]
end

local function used(seat: Seat, kind: string): boolean
	for _, chore in chores do
		if chore.kind == kind and chore.seat == seat then
			return true
		end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Finishing
-- ---------------------------------------------------------------------------

local function remove(chore: Chore)
	local index = table.find(chores, chore)
	if index then
		table.remove(chores, index)
	end
	if chore.seat then
		if chore.kind == "Desk" then
			chore.seat:SetAttribute("Messy", nil)
		elseif chore.kind == "Fix" then
			chore.seat:SetAttribute("Broken", nil)
		end
	end
	if chore.carriedBy then
		chore.carriedBy:SetAttribute("CarryingTrash", nil)
	end
	chore.model:Destroy()
	publish()
end

local function complete(chore: Chore, player: Player)
	if chore.done then
		return
	end
	chore.done = true
	remove(chore)
	local reward = Config.Reward[chore.kind] or 0
	EconomyService.Award(player, reward)
	CareerService.Count(player, "Chores")
	CoachService.Note(player, "Chores")
	CareerService.CompleteStep(player, "Chore")
	if CareerService.IsReady(player) then
		Career.packets.Chore.sendTo({ Kind = chore.kind, Reward = reward }, player)
	end
end

local function new(kind: string, model: Instance, promptInstance: ProximityPrompt): Chore
	nextId += 1
	local chore: Chore = {
		id = nextId,
		kind = kind,
		model = model,
		prompt = promptInstance,
		seat = nil,
		floorWide = false,
		home = nil,
		carriedBy = nil,
		done = false,
	}
	table.insert(chores, chore)
	return chore
end

-- ---------------------------------------------------------------------------
-- Trash
-- ---------------------------------------------------------------------------

local function carriedTrash(player: Player): Chore?
	for _, chore in chores do
		if chore.kind == "Trash" and chore.carriedBy == player then
			return chore
		end
	end
	return nil
end

-- Puts a carried bag back where it was (the carrier dropped it: died, left, moved floors).
local function dropTrash(chore: Chore)
	local carrier = chore.carriedBy
	chore.carriedBy = nil
	if carrier then
		carrier:SetAttribute("CarryingTrash", nil)
	end
	local bag = chore.model:FindFirstChild("Bag") :: BasePart?
	if bag and chore.home then
		for _, weld in bag:GetChildren() do
			if weld:IsA("WeldConstraint") then
				weld:Destroy()
			end
		end
		for _, piece in chore.model:GetChildren() do
			if piece:IsA("BasePart") then
				piece.Anchored = true
			end
		end
		local model = chore.model :: Model
		model:PivotTo(chore.home)
	end
	chore.prompt.Enabled = true
end

local function carry(chore: Chore, player: Player): boolean
	local character = player.Character
	local hand = character
		and (character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")) :: BasePart?
	local bag = chore.model:FindFirstChild("Bag") :: BasePart?
	if not hand or not bag then
		return false
	end
	local model = chore.model :: Model
	model:PivotTo(hand.CFrame * CFrame.new(0, -1.1, 0))
	for _, piece in chore.model:GetChildren() do
		if piece:IsA("BasePart") then
			piece.Anchored = false
			piece.Massless = true
			if piece ~= bag then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = bag
				weld.Part1 = piece
				weld.Parent = bag
			end
		end
	end
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = bag
	weld.Parent = bag
	chore.carriedBy = player
	chore.prompt.Enabled = false
	player:SetAttribute("CarryingTrash", true)
	return true
end

local function spawnTrash(): boolean
	local position: Vector3? = nil
	local spot = pick(activeTagged(Config.TrashSpotTag))
	if spot then
		position = spot.Position + Vector3.new(random:NextNumber(-1, 1), spot.Size.Y / 2, random:NextNumber(-1, 1))
	else
		local seat = pick(activeSeats())
		if not seat then
			return false
		end
		local side = if random:NextNumber() < 0.5 then -1 else 1
		local around = seat.CFrame * CFrame.new(side * random:NextNumber(2.5, 4), 0, random:NextNumber(1.5, 3))
		position = groundBelow(around.Position + Vector3.new(0, 3, 0), 10, { seat })
			or (around.Position - Vector3.new(0, seat.Size.Y / 2 + 1, 0))
	end
	local model = Instance.new("Model")
	model.Name = "TrashBag"
	local bag = part("Bag", Vector3.new(1.7, 1.7, 1.7), Color3.fromRGB(32, 35, 40), Enum.PartType.Ball)
	local tie = part("Tie", Vector3.new(0.35, 0.5, 0.35), Color3.fromRGB(245, 205, 48))
	local home = CFrame.new((position :: Vector3) + Vector3.new(0, 0.75, 0))
		* CFrame.Angles(0, random:NextNumber(0, math.pi * 2), 0)
	bag.CFrame = home
	tie.CFrame = home * CFrame.new(0, 0.95, 0)
	bag.Parent = model
	tie.Parent = model
	model.PrimaryPart = bag
	local promptInstance = prompt(bag, "Pick up trash", "Trash bag", Config.HoldTime.Trash)
	model.Parent = folder
	local chore = new("Trash", model, promptInstance)
	chore.home = home
	promptInstance.Triggered:Connect(function(player: Player)
		if chore.done or chore.carriedBy then
			return
		end
		if #activeTagged(Config.TrashBinTag) == 0 then
			complete(chore, player) -- no bins on this floor: picking it up is enough
			return
		end
		if carriedTrash(player) then
			return -- one bag at a time
		end
		carry(chore, player)
	end)
	return true
end

local function wireBin(bin: Instance)
	if not bin:IsA("BasePart") or bin:FindFirstChild("ChorePrompt") then
		return
	end
	local promptInstance = prompt(bin, "Throw away trash", "Trash bin", 0)
	promptInstance.Triggered:Connect(function(player: Player)
		local chore = carriedTrash(player)
		if chore then
			complete(chore, player)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Messy desks
-- ---------------------------------------------------------------------------

-- The top of the desk in front of a seat.
local function deskTop(seat: Seat): CFrame
	local front = seat.CFrame * CFrame.new(0, 4, -2.2)
	local desk = DeskService.DeskModel(seat)
	local params = RaycastParams.new()
	if desk ~= seat then
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { desk }
	else
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = characters()
	end
	local hit = workspace:Raycast(front.Position, Vector3.new(0, -6, 0), params)
	if hit and hit.Instance ~= seat then
		return CFrame.new(hit.Position) * (seat.CFrame - seat.CFrame.Position)
	end
	return seat.CFrame * CFrame.new(0, 1.3, -2)
end

local function spawnMessy(): boolean
	local candidates = {}
	for _, seat in activeSeats() do
		if not used(seat, "Desk") then
			table.insert(candidates, seat)
		end
	end
	local seat = pick(candidates)
	if not seat then
		return false
	end
	local top = deskTop(seat)
	local model = Instance.new("Model")
	model.Name = "Clutter"
	local papers = part("Papers", Vector3.new(1.1, 0.12, 1.4), Color3.fromRGB(242, 243, 243))
	papers.CFrame = top * CFrame.new(-0.6, 0.06, 0) * CFrame.Angles(0, math.rad(random:NextNumber(-25, 25)), 0)
	papers.Parent = model
	local cup = part("Cup", Vector3.new(0.7, 0.5, 0.5), Color3.fromRGB(255, 255, 255), Enum.PartType.Cylinder)
	cup.CFrame = top * CFrame.new(0.7, 0.35, -0.2) * CFrame.Angles(0, 0, math.rad(90))
	cup.Parent = model
	local stain = part("Stain", Vector3.new(0.05, 0.9, 0.9), Color3.fromRGB(111, 78, 55), Enum.PartType.Cylinder)
	stain.CFrame = top * CFrame.new(0.2, 0.03, 0.4) * CFrame.Angles(0, 0, math.rad(90))
	stain.Parent = model
	for i = 1, 3 do
		local ball = part(`Crumple{i}`, Vector3.new(0.35, 0.35, 0.35), Color3.fromRGB(230, 230, 220), Enum.PartType.Ball)
		ball.CFrame = top * CFrame.new(random:NextNumber(-1.2, 1.2), 0.18, random:NextNumber(-0.6, 0.6))
		ball.Parent = model
	end
	model.PrimaryPart = papers
	local promptInstance = prompt(papers, "Clean desk", "Messy desk", Config.HoldTime.Desk)
	model.Parent = folder
	local chore = new("Desk", model, promptInstance)
	chore.seat = seat
	seat:SetAttribute("Messy", true)
	promptInstance.Triggered:Connect(function(player: Player)
		complete(chore, player)
	end)
	return true
end

-- ---------------------------------------------------------------------------
-- Broken equipment
-- ---------------------------------------------------------------------------

-- The desk's computer: a part named like one, else the tallest thing on the desk (usually the monitor).
local function computerOf(seat: Seat): BasePart
	local desk = DeskService.DeskModel(seat)
	local parts: { BasePart } = {}
	if desk ~= seat then
		for _, descendant in desk:GetDescendants() do
			if descendant:IsA("BasePart") then
				table.insert(parts, descendant)
			end
		end
	else
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = characters()
		local front = seat.CFrame * CFrame.new(0, 2, -2.5)
		parts = workspace:GetPartBoundsInRadius(front.Position, 2.5, params)
	end
	local best: BasePart = seat
	local bestTop = -math.huge
	for _, candidate in parts do
		if candidate ~= seat and not candidate:IsA("Seat") and candidate.Size.Magnitude < 12 then
			local name = string.lower(candidate.Name)
			if string.find(name, "monitor") or string.find(name, "computer") or string.find(name, "screen") then
				return candidate
			end
			local top = candidate.Position.Y + candidate.Size.Y / 2
			if top > bestTop then
				best, bestTop = candidate, top
			end
		end
	end
	return best
end

local function brokenEffects(target: BasePart, label: string): (Instance, ProximityPrompt)
	local attachment = Instance.new("Attachment")
	attachment.Name = "BrokenGear"
	attachment.Position = Vector3.new(0, target.Size.Y / 2 + 0.3, 0)
	local smoke = Instance.new("Smoke")
	smoke.Color = Color3.fromRGB(70, 70, 70)
	smoke.Opacity = 0.3
	smoke.RiseVelocity = 3
	smoke.Size = 0.8
	smoke.Parent = attachment
	local sign = Instance.new("BillboardGui")
	sign.Name = "FixMe"
	sign.Size = UDim2.fromOffset(84, 26)
	sign.StudsOffset = Vector3.new(0, 1.6, 0)
	sign.MaxDistance = 45
	sign.LightInfluence = 0
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundColor3 = Color3.fromRGB(214, 49, 59)
	text.TextColor3 = Color3.new(1, 1, 1)
	text.Font = Enum.Font.GothamBold
	text.TextScaled = true
	text.Text = "FIX ME"
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = text
	text.Parent = sign
	sign.Parent = attachment
	local promptInstance = prompt(attachment, "Fix equipment", label, Config.HoldTime.Fix)
	attachment.Parent = target
	return attachment, promptInstance
end

local function spawnBroken(): boolean
	-- Tagged equipment (routers, servers) breaks for the whole floor; otherwise a desk's computer.
	local equipment = {}
	for _, item in activeTagged(Config.EquipmentTag) do
		if not item:FindFirstChild("BrokenGear") then
			table.insert(equipment, item)
		end
	end
	local floorWide = #equipment > 0 and random:NextNumber() < 0.4
	if floorWide then
		local target = pick(equipment) :: BasePart
		local model, promptInstance = brokenEffects(target, target.Name)
		local chore = new("Fix", model, promptInstance)
		chore.floorWide = true
		promptInstance.Triggered:Connect(function(player: Player)
			complete(chore, player)
		end)
		return true
	end
	local candidates = {}
	for _, seat in activeSeats() do
		if not used(seat, "Fix") then
			table.insert(candidates, seat)
		end
	end
	local seat = pick(candidates)
	if not seat then
		return false
	end
	local target = computerOf(seat)
	if target:FindFirstChild("BrokenGear") then
		return false
	end
	local model, promptInstance = brokenEffects(target, `Computer at desk {seat:GetAttribute("DeskName") or seat.Name}`)
	local chore = new("Fix", model, promptInstance)
	chore.seat = seat
	seat:SetAttribute("Broken", true)
	promptInstance.Triggered:Connect(function(player: Player)
		complete(chore, player)
	end)
	return true
end

-- ---------------------------------------------------------------------------
-- Spawning
-- ---------------------------------------------------------------------------

local function spawnOne()
	local options = {}
	if count("Trash") < Config.MaxTrash then
		table.insert(options, spawnTrash)
		table.insert(options, spawnTrash) -- trash is the most common
	end
	if count("Desk") < Config.MaxMessy then
		table.insert(options, spawnMessy)
	end
	if count("Fix") < Config.MaxBroken then
		table.insert(options, spawnBroken)
	end
	while #options > 0 do
		local index = random:NextInteger(1, #options)
		local ok, spawned = pcall(options[index])
		if not ok then
			warn(`[ChoreService] couldn't set up a chore: {spawned}`)
		elseif spawned then
			publish()
			return
		end
		table.remove(options, index)
	end
end

local function clearAll()
	for _, chore in table.clone(chores) do
		chore.done = true
		remove(chore)
	end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function ChoreService.CallModifiers(player: Player): (number, number)
	local start, gain = 0, 1
	if ReplicatedStorage:GetAttribute("OfficeTidy") then
		start += Config.TidyTrust
	end
	local seat = DeskService.SeatOf(player)
	for _, chore in chores do
		if chore.kind == "Desk" and seat and chore.seat == seat then
			start += Config.MessyTrust
		elseif chore.kind == "Fix" and (chore.floorWide or (seat and chore.seat == seat)) then
			gain = Config.BrokenGain
		end
	end
	return start, gain
end

function ChoreService.Start()
	folder = Instance.new("Folder")
	folder.Name = "OfficeChores"
	folder.Parent = workspace
	publish()

	for _, bin in CollectionService:GetTagged(Config.TrashBinTag) do
		wireBin(bin)
	end
	CollectionService:GetInstanceAddedSignal(Config.TrashBinTag):Connect(wireBin)

	-- A new floor starts clean.
	OfficeService.OnFloorChanged(clearAll)

	-- Carried trash goes back down if the carrier dies or leaves.
	local function watchPlayer(player: Player)
		player.CharacterRemoving:Connect(function()
			local chore = carriedTrash(player)
			if chore then
				dropTrash(chore)
			end
		end)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		local chore = carriedTrash(player)
		if chore then
			dropTrash(chore)
		end
	end)

	if not Config.Enabled then
		return
	end
	task.spawn(function()
		while true do
			task.wait(random:NextNumber(Config.Every.Min, Config.Every.Max))
			if EconomyService.IsRunning() and #Players:GetPlayers() > 0 then
				spawnOne()
			end
		end
	end)
end

return ChoreService
