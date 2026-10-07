--!strict
--[[
	SettingsConfig
	Player settings shown in the ChaOS Settings app. Saved per player by SettingsService.
]]

export type Settings = {
	Wallpaper: number, -- index into Wallpapers
	UiSize: number, -- index into UiSizes
	Clock24: boolean,
	ReduceMotion: boolean,
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
	}) :: Settings,

	DataStoreName = "PlayerSettings_v1",
	SaveDelay = 4, -- seconds of no changes before writing to the DataStore
}

return table.freeze(SettingsConfig)
