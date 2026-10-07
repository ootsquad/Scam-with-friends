--[[
	ShiftLauncher (server, lobby place)
	Sends a crew to their own private server of the Call Center Place.

	TeleportAsync with ShouldReserveServer = true creates a fresh reserved server and moves the whole
	crew into it together. Nobody else can join it (no access code), and Roblox shuts it down once the
	crew leaves, so every crew gets its own instance.

	The shift details travel two ways:
	  - MemoryStore, keyed by the new server's PrivateServerId (trusted; read by the call center server)
	  - TeleportData (instant, used as a fallback)

	ShiftLauncher.Launch(info, players) -> (ok, message)   (yields)
	ShiftLauncher.OnPlayerFailed(callback)                   callback(player, message) after all retries
]]

local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Places = require(ReplicatedStorage:WaitForChild("Shared").Config.Places)

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
}

local ShiftLauncher = {}

local pending: { [Player]: Pending } = {}
local failedCallbacks: { (Player, string) -> () } = {}

local function storeShiftInfo(privateServerId: string, info: ShiftInfo)
	local ok, err = pcall(function()
		MemoryStoreService:GetSortedMap(Places.ShiftInfoMap):SetAsync(privateServerId, info, Places.ShiftInfoTTL)
	end)
	if not ok then
		warn(`[ShiftLauncher] couldn't store shift info (TeleportData fallback will be used): {err}`)
	end
end

local function reportFailure(player: Player, message: string)
	pending[player] = nil
	for _, callback in failedCallbacks do
		task.spawn(callback, player, message)
	end
end

-- A player whose teleport failed after the crew's server was created: retry them into that same server.
local function onTeleportInitFailed(player: Player, _result: Enum.TeleportResult, message: string, placeId: number)
	local entry = pending[player]
	if not entry or placeId ~= Places.CallCenter then
		return
	end
	entry.attempts += 1
	if entry.attempts > Places.TeleportAttempts then
		warn(`[ShiftLauncher] giving up on {player.Name}: {message}`)
		reportFailure(player, "Couldn't get you into your crew's call center. Start a new lobby to try again.")
		return
	end

	task.wait(entry.attempts * 2)
	if not player.Parent then
		return
	end
	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = entry.accessCode
	options:SetTeleportData(entry.info)
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(Places.CallCenter, { player }, options)
	end)
	if not ok then
		onTeleportInitFailed(player, Enum.TeleportResult.Failure, tostring(err), placeId)
	end
end

function ShiftLauncher.Launch(info: ShiftInfo, players: { Player }): (boolean, string)
	if RunService:IsStudio() then
		return false, "Teleports only work in the live game. Publish, then test from the Roblox app."
	end
	if #players == 0 then
		return false, "Nobody left to clock in."
	end

	local options = Instance.new("TeleportOptions")
	options.ShouldReserveServer = true
	options:SetTeleportData(info)

	for attempt = 1, Places.TeleportAttempts do
		local ok, result = pcall(function()
			return TeleportService:TeleportAsync(Places.CallCenter, players, options)
		end)
		if ok then
			for _, player in players do
				pending[player] = { accessCode = result.ReservedServerAccessCode, info = info, attempts = 0 }
			end
			task.spawn(storeShiftInfo, result.PrivateServerId, info)
			print(`[ShiftLauncher] lobby {info.LobbyCode}: sent {#players} player(s) to server {result.PrivateServerId}`)
			return true, ""
		end
		warn(`[ShiftLauncher] attempt {attempt} for lobby {info.LobbyCode} failed: {result}`)
		if attempt < Places.TeleportAttempts then
			task.wait(attempt * 2)
		end
	end
	return false, "Couldn't reach the call center. Try starting again."
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
