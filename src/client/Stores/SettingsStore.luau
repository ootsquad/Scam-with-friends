--[[
	SettingsStore (client)
	The player's ChaOS settings (shared by the lobby and the call center). Changes apply instantly on this
	client and are sent to the server, which saves them (SettingsService).

	SettingsStore.Settings                 -- { Wallpaper, UiSize, Clock24, ReduceMotion, *Volume (0-100) }
	SettingsStore.Persistent               -- false when the server can't save (e.g. Studio)
	SettingsStore.Changed:Connect(function(settings) end)
	SettingsStore.Set("Wallpaper", 2)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Namespace = require(Shared.Network.Namespace)
local SettingsNet = require(Shared.Network.Settings)
local SettingsConfig = require(Shared.Config.SettingsConfig)
local Signal = require(Shared.Util.Signal)

type SettingsData = SettingsNet.SettingsData

local SettingsStore = {
	Settings = table.clone(SettingsConfig.Defaults) :: SettingsData,
	Persistent = false,
	Changed = Signal.new(),
}

function SettingsStore.Start()
	local loaded = Namespace.invoke(SettingsNet.queries.Load, nil)
	if type(loaded) == "table" and type(loaded.Settings) == "table" then
		SettingsStore.Settings = table.clone(loaded.Settings)
		SettingsStore.Persistent = loaded.Persistent == true
	end
	SettingsStore.Changed:Fire(SettingsStore.Settings)
end

function SettingsStore.Set(key: string, value: any)
	local settings = SettingsStore.Settings :: any
	if settings[key] == value then
		return
	end
	settings[key] = value
	SettingsStore.Changed:Fire(SettingsStore.Settings)
	SettingsNet.packets.Save.send(SettingsStore.Settings)
end

return SettingsStore
