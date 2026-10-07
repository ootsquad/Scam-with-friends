--[[
	SettingsStore (client)
	The player's ChaOS settings. Changes apply instantly on this client and are sent to the server,
	which saves them (SettingsService).

	SettingsStore.Settings                 -- { Wallpaper, UiSize, Clock24, ReduceMotion }
	SettingsStore.Persistent               -- false when the server can't save (e.g. Studio)
	SettingsStore.Changed:Connect(function(settings) end)
	SettingsStore.Set("Wallpaper", 2)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
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
	local loaded = SettingsNet.queries.Load.invoke(nil)
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
