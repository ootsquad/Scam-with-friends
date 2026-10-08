--[[
	DeskService (server, Call Center Place)
	The desks. Any Seat tagged "Computer" (or a model tagged "Computer" with a Seat inside) is a workstation.
	Sit down, log in with your Roblox username, and you're on the clock. Standing up logs you out.

	Player attributes (read by the client):
		Desk       name of the desk you're sitting at ("" when not seated at one)
		LoggedIn   true once you've logged in at that desk

	DeskService.Start()
	DeskService.IsLoggedIn(player) -> boolean
	DeskService.OnLogin(callback(player))
	DeskService.OnLogout(callback(player))
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Call = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Network")).Call

local TAG = "Computer"

local DeskService = {}

local seatOf: { [Player]: Seat } = {}
local occupantOf: { [Seat]: Player } = {}
local loggedIn: { [Player]: boolean } = {}
local watched: { [Instance]: boolean } = {}
local loginCallbacks: { (Player) -> () } = {}
local logoutCallbacks: { (Player) -> () } = {}
local deskCount = 0

local function fire(callbacks: { (Player) -> () }, player: Player)
	for _, callback in callbacks do
		task.spawn(callback, player)
	end
end

local function result(ok: boolean, message: string)
	return { Ok = ok, Message = message }
end

local function setLoggedIn(player: Player, value: boolean)
	if (loggedIn[player] == true) == value then
		return
	end
	loggedIn[player] = if value then true else nil
	player:SetAttribute("LoggedIn", value)
	fire(if value then loginCallbacks else logoutCallbacks, player)
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
		end
	end
	if player and previous ~= player then
		occupantOf[seat] = player
		seatOf[player] = seat
		player:SetAttribute("Desk", seat:GetAttribute("DeskName") or seat.Name)
	end
end

local function watchSeat(seat: Seat)
	if watched[seat] then
		return
	end
	watched[seat] = true
	deskCount += 1
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		onOccupantChanged(seat)
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

function DeskService.IsLoggedIn(player: Player): boolean
	return loggedIn[player] == true
end

function DeskService.OnLogin(callback: (Player) -> ())
	table.insert(loginCallbacks, callback)
end

function DeskService.OnLogout(callback: (Player) -> ())
	table.insert(logoutCallbacks, callback)
end

function DeskService.Start()
	Call.queries.Login.listen(onLogin)
	Call.packets.Logoff.listen(onLogoff)

	CollectionService:GetInstanceAddedSignal(TAG):Connect(onTagged)
	for _, instance in CollectionService:GetTagged(TAG) do
		onTagged(instance)
	end
	if deskCount == 0 then
		warn(`[DeskService] no seats tagged "{TAG}" yet. Tag each desk's Seat with "{TAG}" so players can log in.`)
	end

	Players.PlayerAdded:Connect(function(player)
		player:SetAttribute("Desk", "")
		player:SetAttribute("LoggedIn", false)
	end)
	for _, player in Players:GetPlayers() do
		player:SetAttribute("Desk", "")
		player:SetAttribute("LoggedIn", false)
	end
	Players.PlayerRemoving:Connect(function(player)
		local seat = seatOf[player]
		if seat and occupantOf[seat] == player then
			occupantOf[seat] = nil
		end
		seatOf[player] = nil
		if loggedIn[player] then
			loggedIn[player] = nil
			fire(logoutCallbacks, player)
		end
	end)
end

return DeskService
