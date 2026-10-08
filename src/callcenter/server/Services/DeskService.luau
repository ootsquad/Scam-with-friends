--[[
	DeskService (server, Call Center Place)
	The desks. Any Seat tagged "Computer" (or a model tagged "Computer" with a Seat inside) is a workstation.
	Walk up and use the "Sit down" prompt (or just sit), log in with your Roblox username, and you're on the
	clock. After your first login, sitting at any desk logs you straight in. Standing up logs you out.
	With office floors built, only desks on the crew's floor can be used (OfficeService).

	Player attributes (read by the client):
		Desk       name of the desk you're sitting at ("" when not seated at one)
		LoggedIn   true once you've logged in at that desk

	DeskService.Start()
	DeskService.IsLoggedIn(player) -> boolean
	DeskService.SeatOf(player) -> Seat?
	DeskService.Seats() -> { Seat }               every desk seat
	DeskService.DeskModel(seat) -> Instance        the desk around a seat: the model tagged "Computer", else the
	                                               seat's own small model, else the seat
	DeskService.OnLogin(callback(player))
	DeskService.OnLogout(callback(player))       not called for players leaving the game
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Call = require(Shared:WaitForChild("Network")).Call
local Namespace = require(Shared.Network.Namespace)
local CareerService = require(script.Parent.CareerService)
local OfficeService = require(script.Parent.OfficeService)

local TAG = "Computer"
local PROMPT_NAME = "SitPrompt"

local DeskService = {}

local seatOf: { [Player]: Seat } = {}
local occupantOf: { [Seat]: Player } = {}
local loggedIn: { [Player]: boolean } = {}
local everLoggedIn: { [Player]: boolean } = {} -- logged in once this shift: later sits log in by themselves
local watched: { [Seat]: boolean } = {}
local seats: { Seat } = {}
local loginCallbacks: { (Player) -> () } = {}
local logoutCallbacks: { (Player) -> () } = {}

local function fire(callbacks: { (Player) -> () }, player: Player)
	for _, callback in callbacks do
		task.spawn(callback, player)
	end
end

local function result(ok: boolean, message: string)
	return { Ok = ok, Message = message }
end

local function notice(player: Player, message: string)
	if player.Parent and CareerService.IsReady(player) then
		Call.packets.Notice.sendTo(message, player)
	end
end

local function deskName(seat: Seat): string
	local name = seat:GetAttribute("DeskName")
	if type(name) == "string" and name ~= "" then
		return name
	end
	local model = seat:FindFirstAncestorWhichIsA("Model")
	return if model and CollectionService:HasTag(model, TAG) then model.Name else seat.Name
end

local function setLoggedIn(player: Player, value: boolean, quiet: boolean?)
	if (loggedIn[player] == true) == value then
		return
	end
	loggedIn[player] = if value then true else nil
	player:SetAttribute("LoggedIn", value)
	if value then
		everLoggedIn[player] = true
		CareerService.StartedShift(player)
		CareerService.CompleteStep(player, "Login")
	end
	if not quiet then
		fire(if value then loginCallbacks else logoutCallbacks, player)
	end
end

-- Shift lock would grab the mouse while you're using the desktop, so it's off while you sit at a desk.
local function setShiftLock(player: Player, allowed: boolean)
	pcall(function()
		player.DevEnableMouseLock = allowed and game:GetService("StarterPlayer").EnableMouseLockOption
	end)
end

-- The "Sit down" prompt shows on free desks on the crew's floor.
local function updatePrompt(seat: Seat)
	local prompt = seat:FindFirstChild(PROMPT_NAME) :: ProximityPrompt?
	if prompt then
		prompt.Enabled = seat.Occupant == nil and OfficeService.IsActive(seat)
		prompt.ObjectText = `Desk {deskName(seat)}`
	end
end

local function onOccupantChanged(seat: Seat)
	local previous = occupantOf[seat]
	local humanoid = seat.Occupant
	local player = humanoid and Players:GetPlayerFromCharacter(humanoid.Parent)

	if previous and previous ~= player then
		occupantOf[seat] = nil
		if seatOf[previous] == seat then
			seatOf[previous] = nil
			previous:SetAttribute("Desk", "")
			setLoggedIn(previous, false)
			setShiftLock(previous, true)
		end
	end
	if player and previous ~= player then
		occupantOf[seat] = player
		seatOf[player] = seat
		player:SetAttribute("Desk", deskName(seat))
		setShiftLock(player, false)
		CareerService.CompleteStep(player, "Sit")
		if not OfficeService.IsActive(seat) then
			notice(player, `This desk is on another floor. Your crew works on floor {OfficeService.Floor()} now.`)
		elseif everLoggedIn[player] then
			setLoggedIn(player, true) -- already logged in once this shift
		end
	end
	updatePrompt(seat)
end

local function addPrompt(seat: Seat)
	if seat:FindFirstChild(PROMPT_NAME) then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = PROMPT_NAME
	prompt.ActionText = "Sit down"
	prompt.ObjectText = `Desk {deskName(seat)}`
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Triggered:Connect(function(player: Player)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 or seat.Occupant ~= nil then
			return
		end
		if not OfficeService.IsActive(seat) then
			notice(player, `This desk is on another floor. Your crew works on floor {OfficeService.Floor()} now.`)
			return
		end
		seat:Sit(humanoid)
	end)
	prompt.Parent = seat
end

local function watchSeat(seat: Seat)
	if watched[seat] then
		return
	end
	watched[seat] = true
	table.insert(seats, seat)
	addPrompt(seat)
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		onOccupantChanged(seat)
	end)
	seat.Destroying:Connect(function()
		watched[seat] = nil
		local index = table.find(seats, seat)
		if index then
			table.remove(seats, index)
		end
		occupantOf[seat] = nil
	end)
	onOccupantChanged(seat)
end

local function onTagged(instance: Instance)
	if instance:IsA("Seat") or instance:IsA("VehicleSeat") then
		watchSeat(instance :: Seat)
		return
	end
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("Seat") or descendant:IsA("VehicleSeat") then
			watchSeat(descendant :: Seat)
		end
	end
end

local function normalize(name: string): string
	local trimmed = string.gsub(name, "^%s+", "")
	trimmed = string.gsub(trimmed, "%s+$", "")
	trimmed = string.gsub(trimmed, "^@", "")
	return string.lower(trimmed)
end

local function onLogin(username: string, player: Player)
	local seat = seatOf[player]
	if not seat or occupantOf[seat] ~= player then
		return result(false, "Sit down at a computer first.")
	end
	if not OfficeService.IsActive(seat) then
		return result(false, `This desk is on another floor. Your crew works on floor {OfficeService.Floor()} now.`)
	end
	if type(username) ~= "string" or normalize(username) == "" then
		return result(false, "Type your Roblox username.")
	end
	if normalize(username) ~= string.lower(player.Name) then
		return result(false, "That's not your username. Check your spelling.")
	end
	setLoggedIn(player, true)
	return result(true, `Welcome back, {player.DisplayName}.`)
end

local function onLogoff(_: nil, player: Player)
	setLoggedIn(player, false)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function DeskService.IsLoggedIn(player: Player): boolean
	return loggedIn[player] == true
end

function DeskService.SeatOf(player: Player): Seat?
	return seatOf[player]
end

function DeskService.Seats(): { Seat }
	return table.clone(seats)
end

local DESK_SIZE = 16 -- a model bigger than this across is a room or a floor, not a desk

function DeskService.DeskModel(seat: Seat): Instance
	local current = seat.Parent
	while current and current ~= workspace do
		if current:IsA("Model") and CollectionService:HasTag(current, TAG) then
			return current
		end
		current = current.Parent
	end
	local parent = seat.Parent
	if parent and parent:IsA("Model") then
		local _, size = parent:GetBoundingBox()
		if math.max(size.X, size.Z) <= DESK_SIZE then
			return parent
		end
	end
	return seat
end

function DeskService.OnLogin(callback: (Player) -> ())
	table.insert(loginCallbacks, callback)
end

function DeskService.OnLogout(callback: (Player) -> ())
	table.insert(logoutCallbacks, callback)
end

function DeskService.Start()
	Namespace.listen(Call.queries.Login, onLogin, Namespace.busy)
	Call.packets.Logoff.listen(onLogoff)

	CollectionService:GetInstanceAddedSignal(TAG):Connect(onTagged)
	for _, instance in CollectionService:GetTagged(TAG) do
		onTagged(instance)
	end
	if #seats == 0 then
		warn(`[DeskService] no seats tagged "{TAG}" yet. Tag each desk's Seat with "{TAG}" so players can log in.`)
	end

	-- The crew moved floors: prompts follow, and anyone left at a desk on another floor is logged out.
	OfficeService.OnFloorChanged(function()
		for _, seat in seats do
			updatePrompt(seat)
			local player = occupantOf[seat]
			if player and not OfficeService.IsActive(seat) then
				setLoggedIn(player, false)
			end
		end
	end)

	local function setup(player: Player)
		player:SetAttribute("Desk", "")
		player:SetAttribute("LoggedIn", false)
	end
	Players.PlayerAdded:Connect(setup)
	for _, player in Players:GetPlayers() do
		setup(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		local seat = seatOf[player]
		if seat and occupantOf[seat] == player then
			occupantOf[seat] = nil
			updatePrompt(seat)
		end
		seatOf[player] = nil
		everLoggedIn[player] = nil
		-- No logout callbacks: the other services clean up leaving players themselves.
		loggedIn[player] = nil
	end)
end

return DeskService
