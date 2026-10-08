--[[
	Network.Settings
	Loading and saving the player's ChaOS settings.

	Client:  local loaded = Settings.queries.Load.invoke(nil)      -- { Settings = {...}, Persistent = true }
	         Settings.packets.Save.send(settings)
]]

local Namespace = require(script.Parent.Namespace)
local ByteNet = Namespace.ByteNet

export type SettingsData = {
	Wallpaper: number,
	UiSize: number,
	Clock24: boolean,
	ReduceMotion: boolean,
	MasterVolume: number,
	VoiceVolume: number,
	EffectsVolume: number,
}

export type Loaded = {
	Settings: SettingsData,
	Persistent: boolean, -- false when saving isn't available (e.g. Studio without API access)
}

return Namespace.define("Settings", function()
	local SettingsData = ByteNet.struct({
		Wallpaper = ByteNet.uint8,
		UiSize = ByteNet.uint8,
		Clock24 = ByteNet.bool,
		ReduceMotion = ByteNet.bool,
		MasterVolume = ByteNet.uint8,
		VoiceVolume = ByteNet.uint8,
		EffectsVolume = ByteNet.uint8,
	})

	local Loaded = ByteNet.struct({
		Settings = SettingsData,
		Persistent = ByteNet.bool,
	})

	return {
		packets = {
			Save = ByteNet.definePacket({ value = SettingsData }),
		},
		queries = {
			Load = ByteNet.defineQuery({ request = ByteNet.nothing, response = Loaded }),
		},
	}
end)
