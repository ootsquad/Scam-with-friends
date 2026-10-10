--!strict
--[[
	Theme
	ChaOS colors used at runtime for UI states. Matches the palette baked into the GUI models.
	Flat and Windows-like: white native apps, dark phone-style apps, one blue accent.
]]

local hex = Color3.fromHex

local function vertical(stops: { { number | string } }): ColorSequence
	local points = {}
	for _, stop in stops do
		table.insert(points, ColorSequenceKeypoint.new(stop[1] :: number, hex(stop[2] :: string)))
	end
	return ColorSequence.new(points)
end

local Theme = {
	White = hex("#FFFFFF"),
	Accent = hex("#2F80ED"),
	Green = hex("#1E8E3E"),
	GreenText = hex("#4ADE80"),
	GreenBar = hex("#22C55E"),
	Red = hex("#D6313B"),
	RedHover = hex("#E81123"),
	Yellow = hex("#FFD54A"),

	-- window chrome
	TitleText = hex("#1A1A1A"),
	TitleHover = hex("#E5E5E5"),
	BorderFocused = hex("#2F80ED"),
	BorderIdle = hex("#7A7A7A"),

	-- native (white) apps
	NativeText = hex("#1A1A1A"),
	NativeMuted = hex("#5F6368"),
	NativeFaint = hex("#8A9096"),
	ToggleOff = hex("#333333"),

	-- dark (phone-style) apps
	DarkBg = hex("#0E0F11"),
	DarkPanel = hex("#15181C"),
	DarkHead = hex("#22262C"),
	DarkLine = hex("#3A3F47"),
	DarkText = hex("#EDEFF2"),
	DarkMuted = hex("#9AA3AD"),
	DarkFaint = hex("#6B7280"),
	DarkStrip = hex("#0A0B0D"),
	Portrait = hex("#7FA19E"),
	PortraitLine = hex("#9DBDBA"),
	PortraitEmpty = hex("#22272E"),
	PortraitEmptyLine = hex("#2C323A"),
	PortraitInitial = hex("#2B3A39"),
	HoverOutline = hex("#8A93A0"),

	-- taskbar tray
	TrayIdle = hex("#A0A0A0"),
	TrayReview = hex("#FF9F7A"),

	-- call center phone (softer dark)
	PhonePanel = hex("#1E2128"),
	PhoneHead = hex("#282C35"),
	PhoneLine = hex("#353A45"),
	TrustLow = hex("#EF4444"),
	TrustMid = hex("#F59E0B"),
	TrustHigh = hex("#22C55E"),
	LeadAvailableBg = hex("#1F3B2A"),
	LeadOnCallBg = hex("#1E3354"),
	LeadOnCallText = hex("#7FB2FF"),
	LeadScammedBg = hex("#3A3320"),
	LeadBlockedBg = hex("#3F2024"),
	LeadBlockedText = hex("#FF8A8A"),
	PaymentGiftCard = hex("#7C3AED"),
	PaymentCard = hex("#0F766E"),
	PaymentDonation = hex("#E11D48"),

	-- Training app
	Training = hex("#EA580C"),
	LessonIdle = hex("#F6F7F9"),

	-- Store, Career and Settings apps (call center)
	NativePanel = hex("#F6F7F9"),
	NativeLine = hex("#E5E7EB"),
	StoreOwned = hex("#E8F5EC"),
	LadderCurrent = hex("#E8F0FD"),
	LadderLocked = hex("#B8BEC6"),
	SliderTrack = hex("#E5E7EB"),

	-- In-world HUD (call center)
	HudPanel = hex("#111318"),
	HudText = hex("#F3F4F6"),
	HudMuted = hex("#A3AAB5"),
	ChecklistDone = hex("#22C55E"),
	ChecklistTodo = hex("#4B5563"),

	-- The drawn stand-in for each wallpaper photo (shown until the photo loads). Index matches
	-- SettingsConfig.Wallpapers: Dusk, Overcast, Night, Sunset, Moonlight
	Wallpapers = {
		{
			Sky = vertical({ { 0, "#1B2440" }, { 0.55, "#4B4F7A" }, { 1, "#E9915A" } }),
			Sun = hex("#FFD08A"), SunTransparency = 0, HaloTransparency = 0.78,
			Back = hex("#3C3550"), Front = hex("#241F33"),
			Water = vertical({ { 0, "#3A3150" }, { 1, "#121222" } }),
			Shine = hex("#F2A65A"), ShineTransparency = 0.5,
		},
		{
			Sky = vertical({ { 0, "#56626E" }, { 0.6, "#8793A0" }, { 1, "#B7C0C8" } }),
			Sun = hex("#EEF1F4"), SunTransparency = 0.55, HaloTransparency = 0.9,
			Back = hex("#5E6A74"), Front = hex("#3B454E"),
			Water = vertical({ { 0, "#56626C" }, { 1, "#262D33" } }),
			Shine = hex("#D5DCE2"), ShineTransparency = 0.75,
		},
		{
			Sky = vertical({ { 0, "#03060E" }, { 0.6, "#0C1630" }, { 1, "#1B2C52" } }),
			Sun = hex("#E8EDF7"), SunTransparency = 0, HaloTransparency = 0.86,
			Back = hex("#141D33"), Front = hex("#0A1022"),
			Water = vertical({ { 0, "#0F1A35" }, { 1, "#04070F" } }),
			Shine = hex("#9FB3E0"), ShineTransparency = 0.65,
		},
		{
			Sky = vertical({ { 0, "#3A3F5C" }, { 0.55, "#8C6A7A" }, { 1, "#F0A070" } }),
			Sun = hex("#FFD9A0"), SunTransparency = 0.2, HaloTransparency = 0.74,
			Back = hex("#4A4560"), Front = hex("#262536"),
			Water = vertical({ { 0, "#4A4258" }, { 1, "#16162A" } }),
			Shine = hex("#F0A070"), ShineTransparency = 0.45,
		},
		{
			Sky = vertical({ { 0, "#0A1024" }, { 0.6, "#18234A" }, { 1, "#2C3D66" } }),
			Sun = hex("#F2EAD0"), SunTransparency = 0, HaloTransparency = 0.8,
			Back = hex("#1C2642"), Front = hex("#0B101C"),
			Water = vertical({ { 0, "#18223F" }, { 1, "#060A14" } }),
			Shine = hex("#E8DDB5"), ShineTransparency = 0.55,
		},
	},
}

return table.freeze(Theme)
