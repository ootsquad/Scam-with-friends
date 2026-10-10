--!strict
--[[
	ImageConfig
	Every uploaded image the game shows, by name. Paste the id from the Creator Dashboard: a decal id works
	(the server turns it into its image id, see ImageService) and so does an image id.

	Icons are white pictures on a see-through background. They sit on the coloured app tiles and buttons, which
	keep their old drawn icon underneath in case an image can't load (for example while Roblox is still
	reviewing a new upload). Shop pictures are keyed by the item's ShopConfig Key, wallpapers by their
	SettingsConfig name.

	ImageConfig.Lookup() -> { [key]: id }   every image under one key:
	                                         Icons.<Name> -> "<Name>", Shop.<Key> -> "Shop_<Key>",
	                                         Wallpapers.<Name> -> "Wallpaper_<Name>"
]]

local ImageConfig = {
	Icons = {
		-- Phone
		Answer = 123777038688551, -- also the Phone app's icon
		Hangup = 100783332728972,
		Send = 101886206945643,
		Ideas = 74145142478738,
		Microphone = 99715143368493,
		Voice = 131454196717418, -- callers' voices (TTS) on or off

		-- Apps and the Start menu
		Start = 118681225072089,
		Settings = 129568295036420,
		Career = 135685818958126,
		File = 119615315810667,
		Wallet = 116288766487749,
		Training = 79968072220210,
		Standup = 116278323485213,
		LogOff = 116558406149681,
		LeaveShift = 76595181142314,

		-- Equipment store (OfficeConfig.EquipmentOrder)
		Headset = 77097949651497,
		Computer = 131373140071430,
		Router = 83975522827519,
	},

	-- Robux items, by ShopConfig Key
	Shop = {
		PrankCall = 72404182004665,
		BossMeltdown = 111311622338155,
		VirusAttack = 114858221418012,
		PoliceRaid = 127307948484614,
		DoubleCash = 78304860828669,
		SaveMyCall = 126954729248113,
		OfficeChaos = 88982914072941,
		ExtraTips = 116180879915060,
		Cash15 = 134402110990556,
		Cash60 = 134402110990556,
		CashForever = 122335295401963,
		TeamLeader = 125131557003996,
		VIP = 120178421839749,
	},

	-- Desktop wallpapers, by SettingsConfig.Wallpapers name (16:9 photos)
	Wallpapers = {
		Dusk = 125809759926045,
		Overcast = 72238794026245,
		Night = 89903488650155,
		Sunset = 78346367906573,
		Moonlight = 76993092624288,
	},
}

local lookup: { [string]: number } = {}
for name, id in ImageConfig.Icons do
	lookup[name] = id
end
for key, id in ImageConfig.Shop do
	lookup["Shop_" .. key] = id
end
for name, id in ImageConfig.Wallpapers do
	lookup["Wallpaper_" .. name] = id
end
table.freeze(lookup)

function ImageConfig.Lookup(): { [string]: number }
	return lookup
end

return table.freeze(ImageConfig)
