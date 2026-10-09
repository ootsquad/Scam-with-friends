--!strict
--[[
	SettingsConfig
	Player settings shown in the ChaOS Settings apps (lobby and call center). Saved per player by
	SettingsService; both places share them.
]]

export type Settings = {
	Wallpaper: number, -- index into Wallpapers
	UiSize: number, -- index into UiSizes
	Clock24: boolean,
	ReduceMotion: boolean,
	MicReview: boolean, -- call center: what the mic heard goes in the text box to check before it's sent
	MasterVolume: number, -- 0-100
	VoiceVolume: number, -- 0-100, callers' voices
	EffectsVolume: number, -- 0-100, rings, pings and other sound effects
}

local SettingsConfig = {
	Wallpapers = { "Dusk", "Overcast", "Night" },
	UiSizes = {
		{ Name = "Small", Scale = 0.9 },
		{ Name = "Normal", Scale = 1 },
		{ Name = "Large", Scale = 1.12 },
	},
	Defaults = table.freeze({
		Wallpaper = 1,
		UiSize = 2,
		Clock24 = false,
		ReduceMotion = false,
		MicReview = true,
		MasterVolume = 80,
		VoiceVolume = 100,
		EffectsVolume = 70,
	}) :: Settings,
	VolumeKeys = { "MasterVolume", "VoiceVolume", "EffectsVolume" },

	DataStoreName = "PlayerSettings_v1",
	SaveDelay = 4, -- seconds of no changes before writing to the DataStore
}

return table.freeze(SettingsConfig)
