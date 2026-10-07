--[[
	LobbyDirectory (server)
	Lets "Join with Code" reach lobbies hosted on a *different* server of the game.

	Each server lists its open lobby codes in a MemoryStore sorted map (code -> JobId). When a player
	enters a code that isn't on their server, we look it up and teleport them to the right server with
	the code in their TeleportData; that server seats them as soon as their client is ready.

	Only active in a live game. In Studio there is no JobId to teleport to, so codes only work for
	lobbies on the same server (which is how local multi-client tests run anyway).
]]

local MemoryStoreService = game:GetService("MemoryStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")

local LobbyConfig = require(ReplicatedStorage:WaitForChild("Shared").Config.LobbyConfig)

local LobbyDirectory = {}

local listed: { [string]: boolean } = {}
local sortedMap: MemoryStoreSortedMap? = nil

local function enabled(): boolean
	return game.JobId ~= "" and game.PlaceId ~= 0
end

local function getMap(): MemoryStoreSortedMap
	if not sortedMap then
		sortedMap = MemoryStoreService:GetSortedMap(LobbyConfig.DirectoryName)
	end
	return sortedMap :: MemoryStoreSortedMap
end

local function write(code: string)
	local ok, err = pcall(function()
		getMap():SetAsync(code, game.JobId, LobbyConfig.DirectoryTTL)
	end)
	if not ok then
		warn(`[LobbyDirectory] couldn't list {code}: {err}`)
	end
end

function LobbyDirectory.Register(code: string)
	listed[code] = true
	if enabled() then
		task.spawn(write, code)
	end
end

function LobbyDirectory.Unregister(code: string)
	listed[code] = nil
	if enabled() then
		task.spawn(pcall, function()
			getMap():RemoveAsync(code)
		end)
	end
end

-- Returns the JobId of another server hosting `code`, or nil. Yields.
function LobbyDirectory.Find(code: string): string?
	if not enabled() then
		return nil
	end
	local ok, jobId = pcall(function()
		return getMap():GetAsync(code)
	end)
	if ok and type(jobId) == "string" and jobId ~= game.JobId then
		return jobId
	end
	return nil
end

-- Sends `player` to the server `jobId`, carrying the lobby code. Yields.
function LobbyDirectory.TeleportTo(player: Player, jobId: string, code: string): (boolean, string?)
	local ok, err = pcall(function()
		local options = Instance.new("TeleportOptions")
		options.ServerInstanceId = jobId
		options:SetTeleportData({ LobbyCode = code })
		TeleportService:TeleportAsync(game.PlaceId, { player }, options)
	end)
	if not ok then
		warn(`[LobbyDirectory] teleport to {code} failed: {err}`)
	end
	return ok, if ok then nil else tostring(err)
end

-- The lobby code a player was teleported in with, if any.
function LobbyDirectory.ArrivalCode(player: Player): string?
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	local teleportData = ok and joinData and joinData.TeleportData
	if type(teleportData) == "table" and type(teleportData.LobbyCode) == "string" then
		return string.upper(teleportData.LobbyCode)
	end
	return nil
end

function LobbyDirectory.Start()
	if not enabled() then
		return
	end

	-- Keep our codes listed while their lobbies exist.
	task.spawn(function()
		while true do
			task.wait(LobbyConfig.DirectoryRefresh)
			for code in listed do
				write(code)
			end
		end
	end)

	game:BindToClose(function()
		for code in listed do
			pcall(function()
				getMap():RemoveAsync(code)
			end)
		end
	end)
end

return LobbyDirectory
