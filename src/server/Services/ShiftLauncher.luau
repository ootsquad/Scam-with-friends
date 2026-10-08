--[[
	ShiftLauncher (server, lobby place)
	Gets a party into its own private server of the Call Center Place. Party members are spread over many
	lobby servers, so it works in two halves:

	  1. The leader's server reserves one call center server (TeleportService:ReserveServer) and stores the
	     shift details under its PrivateServerId in MemoryStore (the trusted copy the call center reads).
	  2. Every member's server teleports its own players there with the same access code. The shift details
	     also travel in TeleportData as a fallback.

	A failed teleport is retried into the same server; after Places.TeleportAttempts tries (or if nothing
	happens for TeleportTimeout seconds) the OnPlayerFailed callbacks run so the player can try again.

	ShiftLauncher.Start()
	ShiftLauncher.Reserve() -> (ok, accessCode?, privateServerId?, error?)   yields
	ShiftLauncher.StoreShift(privateServerId, info)
	ShiftLauncher.Send(players, accessCode, info)
	ShiftLauncher.OnPlayerFailed(callback(player, message))
]]

local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Places = require(ReplicatedStorage:WaitForChild("Shared").Config.Places)

local TELEPORT_TIMEOUT = 60 -- seconds before a teleport that never finished counts as failed

export type ShiftInfo = {
	LobbyCode: string,
	Difficulty: number,
	HostUserId: number,
	Crew: { number },
	ReturnPlaceId: number,
}

type Pending = {
	accessCode: string,
	info: ShiftInfo,
	attempts: number,
	token: number,
}

local ShiftLauncher = {}

local pending: { [Player]: Pending } = {}
local failedCallbacks: { (Player, string) -> () } = {}
local nextToken = 0

local function reportFailure(player: Player, message: string)
	pending[player] = nil
	for _, callback in failedCallbacks do
		task.spawn(callback, player, message)
	end
end

local function teleport(player: Player, entry: Pending): (boolean, string?)
	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = entry.accessCode
	options:SetTeleportData(entry.info)
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(Places.CallCenter, { player }, options)
	end)
	return ok, if ok then nil else tostring(err)
end

-- A teleport failed: try again into the same server, or give up after enough tries.
local function retry(player: Player, message: string)
	local entry = pending[player]
	if not entry then
		return
	end
	entry.attempts += 1
	if entry.attempts >= Places.TeleportAttempts then
		warn(`[ShiftLauncher] giving up on {player.Name}: {message}`)
		reportFailure(player, "Couldn't get you into your crew's call center. Join or start a new party to try again.")
		return
	end
	task.wait(entry.attempts * 2)
	if not player.Parent or pending[player] ~= entry then
		return
	end
	local ok, err = teleport(player, entry)
	if not ok then
		retry(player, err or "teleport failed")
	end
end

local function onTeleportInitFailed(player: Player, _result: Enum.TeleportResult, message: string, placeId: number)
	if placeId == Places.CallCenter and pending[player] then
		task.spawn(retry, player, message)
	end
end

function ShiftLauncher.Reserve(): (boolean, string?, string?, string?)
	if RunService:IsStudio() then
		return false, nil, nil, "Teleports only work in the live game. Publish, then test from the Roblox app."
	end
	for attempt = 1, Places.TeleportAttempts do
		local ok, accessCode, privateServerId = pcall(function()
			return TeleportService:ReserveServer(Places.CallCenter)
		end)
		if ok and type(accessCode) == "string" and type(privateServerId) == "string" then
			return true, accessCode, privateServerId, nil
		end
		warn(`[ShiftLauncher] couldn't reserve a call center server (attempt {attempt}): {accessCode}`)
		if attempt < Places.TeleportAttempts then
			task.wait(attempt)
		end
	end
	return false, nil, nil, "Couldn't reach the call center. Try starting again."
end

function ShiftLauncher.StoreShift(privateServerId: string, info: ShiftInfo)
	local ok, err = pcall(function()
		MemoryStoreService:GetSortedMap(Places.ShiftInfoMap):SetAsync(privateServerId, info, Places.ShiftInfoTTL)
	end)
	if not ok then
		warn(`[ShiftLauncher] couldn't store shift info (TeleportData fallback will be used): {err}`)
	end
end

function ShiftLauncher.Send(players: { Player }, accessCode: string, info: ShiftInfo)
	for _, player in players do
		nextToken += 1
		local entry: Pending = { accessCode = accessCode, info = info, attempts = 0, token = nextToken }
		pending[player] = entry
		task.spawn(function()
			local ok, err = teleport(player, entry)
			if not ok then
				retry(player, err or "teleport failed")
			end
		end)
		-- Nothing happened at all (no arrival, no failure event): let them try again.
		task.delay(TELEPORT_TIMEOUT, function()
			if player.Parent and pending[player] == entry then
				reportFailure(player, "The call center didn't answer. Join or start a new party to try again.")
			end
		end)
	end
	print(`[ShiftLauncher] party {info.LobbyCode}: sending {#players} player(s) from this server`)
end

function ShiftLauncher.OnPlayerFailed(callback: (Player, string) -> ())
	table.insert(failedCallbacks, callback)
end

function ShiftLauncher.Start()
	TeleportService.TeleportInitFailed:Connect(onTeleportInitFailed)
	Players.PlayerRemoving:Connect(function(player)
		pending[player] = nil -- left for the call center (or quit)
	end)
end

return ShiftLauncher
