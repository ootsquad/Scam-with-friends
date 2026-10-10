--!strict
--[[
	ImageConfig
	Every uploaded image the game shows, by name. Paste the id from Creator Hub > Development Items > Images
	(the "Asset ID" column). A decal id works too (the server turns it into its image id, see ImageService),
	but image ids load more reliably.

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
		Answer = 104887510379851,
		Hangup = 132905403711349,
		Send = 73756917132454,
		Ideas = 104536759849267,
		Microphone = 134573172488192,
		Voice = 79911660233792, -- callers' voices (TTS) on or off

		-- Apps and the Start menu
		Phone = 90160761975014,
		GiftCards = 97265208066985,
		GiveHope = 105569663206108,
		Play = 90489335398895, -- lobby
		JoinCode = 112438607759378, -- lobby
		Start = 98742327590082,
		Logo = 127166081442263, -- the green headset: Start button, boot and lock screens
		CardTerminal = 71920016258200,
		Settings = 120148893821590,
		Career = 139631024937514,
		File = 134559076951363,
		Wallet = 79342759209409,
		Training = 132127363845816,
		Standup = 114252127059131,
		LogOff = 104204673575882,
		LeaveShift = 128711239203550,

		-- Equipment store (OfficeConfig.EquipmentOrder)
		Headset = 86582253293959,
		Computer = 110305087291666,
		Router = 119559024526953,
	},

	-- Robux items, by ShopConfig Key
	Shop = {
		PrankCall = 84083949874531,
		BossMeltdown = 103030351161898,
		VirusAttack = 99934614954430,
		PoliceRaid = 123564731527479,
		DoubleCash = 80660311181632,
		SaveMyCall = 79976535442522,
		OfficeChaos = 105894232114018,
		ExtraTips = 136630586077500,
		Cash15 = 135833643389474,
		Cash60 = 135833643389474,
		CashForever = 95105848196260,
		TeamLeader = 121839625801496,
		VIP = 96772511493936,
	},

	-- Desktop wallpapers, by SettingsConfig.Wallpapers name (16:9 photos)
	Wallpapers = {
		Dusk = 133277557402270,
		Overcast = 72846499977449,
		Night = 88750524566442,
		Sunset = 81423211046964,
		Moonlight = 139794138508563,
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
