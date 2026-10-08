--[[
	SettingsService (server)
	Loads and saves each player's ChaOS settings in a DataStore.

	If DataStores aren't reachable (Studio with "Enable Studio Access to API Services" off, or a Studio
	test player), settings still work for the session and the client is told they won't be saved.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Namespace = require(Shared.Network.Namespace)
local SettingsNet = require(Shared.Network.Settings)
local SettingsConfig = require(Shared.Config.SettingsConfig)

type SettingsData = SettingsNet.SettingsData

local SettingsService = {}

local cache: { [Player]: SettingsData } = {}
local persistent: { [Player]: boolean } = {}
local dirtySince: { [Player]: number } = {}
local store: DataStore? | false = nil

local function getStore(): DataStore?
	if store == nil then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(SettingsConfig.DataStoreName)
		end)
		store = if ok then result else false
	end
	return if store then store else nil
end

local function key(player: Player): string
	return `u_{player.UserId}`
end

-- Never trust stored or client data: clamp everything to valid values.
local function sanitize(raw: any): SettingsData
	local defaults = SettingsConfig.Defaults
	local data = if type(raw) == "table" then raw else {}
	local function index(value: any, count: number, default: number): number
		if type(value) == "number" and value % 1 == 0 and value >= 1 and value <= count then
			return value
		end
		return default
	end
	local function volume(value: any, default: number): number
		if type(value) == "number" and value == value then
			return math.clamp(math.round(value), 0, 100)
		end
		return default
	end
	return {
		MasterVolume = volume(data.MasterVolume, defaults.MasterVolume),
		VoiceVolume = volume(data.VoiceVolume, defaults.VoiceVolume),
		EffectsVolume = volume(data.EffectsVolume, defaults.EffectsVolume),
		Wallpaper = index(data.Wallpaper, #SettingsConfig.Wallpapers, defaults.Wallpaper),
		UiSize = index(data.UiSize, #SettingsConfig.UiSizes, defaults.UiSize),
		Clock24 = if type(data.Clock24) == "boolean" then data.Clock24 else defaults.Clock24,
		ReduceMotion = if type(data.ReduceMotion) == "boolean" then data.ReduceMotion else defaults.ReduceMotion,
	}
end

local function load(player: Player): SettingsData
	if cache[player] then
		return cache[player]
	end

	local data = sanitize(nil)
	local saved = false
	local dataStore = getStore()
	if dataStore and player.UserId > 0 then
		local ok, stored = pcall(function()
			return dataStore:GetAsync(key(player))
		end)
		if ok then
			saved = true
			if stored ~= nil then
				data = sanitize(stored)
			end
		end
	end

	if not player.Parent then
		return data -- left while we were loading; don't keep anything for them
	end
	cache[player] = data
	persistent[player] = saved
	return data
end

local function save(player: Player)
	dirtySince[player] = nil
	local data = cache[player]
	local dataStore = getStore()
	if not data or not persistent[player] or not dataStore then
		return
	end
	local ok, err = pcall(function()
		dataStore:SetAsync(key(player), data, { player.UserId })
	end)
	if not ok then
		warn(`[SettingsService] couldn't save {player.Name}: {err}`)
	end
end

local function onLoad(_: nil, player: Player): SettingsNet.Loaded
	local data = load(player)
	return { Settings = data, Persistent = persistent[player] == true }
end

local function onSave(raw: SettingsData, player: Player)
	if not cache[player] then
		return -- hasn't loaded yet
	end
	cache[player] = sanitize(raw)

	-- Debounce: write once the player stops fiddling.
	local stamp = os.clock()
	dirtySince[player] = stamp
	task.delay(SettingsConfig.SaveDelay, function()
		if dirtySince[player] == stamp then
			save(player)
		end
	end)
end

local function onPlayerRemoving(player: Player)
	if dirtySince[player] then
		save(player)
	end
	cache[player] = nil
	persistent[player] = nil
	dirtySince[player] = nil
end

function SettingsService.Get(player: Player): SettingsData
	return load(player)
end

function SettingsService.Start()
	Namespace.listen(SettingsNet.queries.Load, onLoad, function()
		return { Settings = sanitize(nil), Persistent = false }
	end)
	SettingsNet.packets.Save.listen(onSave)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	game:BindToClose(function()
		for player in dirtySince do
			save(player)
		end
	end)
end

return SettingsService
