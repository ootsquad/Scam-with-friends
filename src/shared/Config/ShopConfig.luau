--!strict
--[[
	ShopConfig
	Robux items sold at the equipment store (the brick or vendor tagged "StoreVendor", see OFFICE.md):
	developer products, which can be bought again and again, and game passes, which are bought once and kept
	forever. Ids come from the Creator Dashboard. The store shows Roblox's own price for each item
	(GetProductInfo); Price here is only shown while that loads.

	ComingSoon = true lists an item in the store without selling it. Boss Meltdown and Police Raid wait for the
	boss and the cops: give ShopService a handler for them (ShopService.Register) and turn ComingSoon off.
]]

export type Item = {
	Key: string,
	Id: number,
	Name: string,
	Price: number?, -- Robux, shown until Roblox's price has loaded
	Symbol: string, -- big text on the item's tile in the store
	Color: string, -- the tile's colour (hex)
	Blurb: string,
	ComingSoon: boolean?,
	BoostSeconds: number?, -- 2x cash passes: 2x for this long at the start of every shift
}

local ShopConfig = {
	-- Developer products (repeat purchases)
	Products = {
		{
			Key = "PrankCall",
			Id = 3717492927,
			Name = "Prank Call",
			Price = 29,
			Symbol = "HA!",
			Color = "#F59E0B",
			Blurb = "A silly caller rings a crewmate you pick. Totally harmless.",
		},
		{
			Key = "BossMeltdown",
			Id = 3717492971,
			Name = "Boss Meltdown",
			Price = 49,
			Symbol = "BOSS",
			Color = "#7C3AED",
			Blurb = "The boss goes crazy.",
			ComingSoon = true,
		},
		{
			Key = "VirusAttack",
			Id = 3717493057,
			Name = "Virus Attack",
			Price = 59,
			Symbol = "X_X",
			Color = "#65A30D",
			Blurb = "Every computer catches a (fake) virus. Close the pop-ups for cash.",
		},
		{
			Key = "PoliceRaid",
			Id = 3717493106,
			Name = "Police Raid",
			Price = 79,
			Symbol = "COPS",
			Color = "#2563EB",
			Blurb = "A chaotic (fictional) raid on the office.",
			ComingSoon = true,
		},
		{
			Key = "DoubleCash",
			Id = 3717493144,
			Name = "2x Cash",
			Price = 49,
			Symbol = "2x",
			Color = "#16A34A",
			Blurb = "Double your earnings for 15 minutes. Buy more to add time.",
		},
		{
			Key = "SaveMyCall",
			Id = 3717493175,
			Name = "Save My Call",
			Price = 39,
			Symbol = "SOS",
			Color = "#0EA5E9",
			Blurb = "A caller hung up on you? They call right back, where you left off.",
		},
		{
			Key = "OfficeChaos",
			Id = 3717493231,
			Name = "Office Chaos",
			Price = 149,
			Symbol = "!!!",
			Color = "#DC2626",
			Blurb = "Alarms, trash everywhere, viruses on every computer. Cleanup pays double.",
		},
		{
			Key = "ExtraTips",
			Id = 3717493275,
			Name = "Extra Tips",
			Price = 50,
			Symbol = "+5",
			Color = "#EAB308",
			Blurb = "5 more on-call tips (the IDEAS button). Unused tips are saved.",
		},
	} :: { Item },

	-- Game passes (one purchase, kept forever)
	Passes = {
		{
			Key = "Cash15",
			Id = 2022824526,
			Name = "2x Cash (15 min)",
			Symbol = "2x",
			Color = "#16A34A",
			Blurb = "2x earnings for the first 15 minutes of every shift.",
			BoostSeconds = 15 * 60,
		},
		{
			Key = "Cash60",
			Id = 2021606510,
			Name = "2x Cash (1 hour)",
			Symbol = "2x",
			Color = "#15803D",
			Blurb = "2x earnings for the first hour of every shift.",
			BoostSeconds = 60 * 60,
		},
		{
			Key = "CashForever",
			Id = 2021570508,
			Name = "Permanent 2x Cash",
			Symbol = "2x",
			Color = "#166534",
			Blurb = "2x earnings, every shift, forever.",
		},
		{
			Key = "TeamLeader",
			Id = 2023490509,
			Name = "Team Leader",
			Price = 249,
			Symbol = "+10%",
			Color = "#0891B2",
			Blurb = "Your teammates earn 10% more while you play together.",
		},
		{
			Key = "VIP",
			Id = 2024906475,
			Name = "VIP Employee",
			Price = 199,
			Symbol = "VIP",
			Color = "#CA8A04",
			Blurb = "VIP nametag and chat tag, 5 free tips and a free call save every shift.",
		},
	} :: { Item },

	CashMultiplier = 2, -- 2x cash (passes and the product don't stack with each other)
	DoubleCashSeconds = 15 * 60, -- per 2x Cash product
	TeamLeaderBonus = 0.1, -- teammates of a Team Leader earn this much more (one bonus, however many leaders)

	-- On-call tips (the IDEAS button). Ideas that pop up when Roblox hides your line are always free.
	FreeTipsPerShift = 3,
	VipFreeTips = 5, -- instead of FreeTipsPerShift
	TipsPerPurchase = 5,

	-- Save My Call
	VipFreeSaves = 1, -- free saves per shift for VIPs
	SaveWindow = 5 * 60, -- seconds after a call fails that it can still be saved
	SaveMinLines = 8, -- a saved call has at least this many lines left

	-- Prank Call
	PrankLines = 8, -- lines in a prank call before the prankster has to go

	-- Virus Attack: every computer on the crew's floor gets pop-ups. Close them all for a small reward.
	Virus = {
		Duration = 90, -- seconds before an untouched computer cleans itself
		Popups = 6,
		MaxPopups = 10, -- the "Claim prize" buttons open more pop-ups, up to this many
		CleanReward = 15,
	},

	-- Virus Attack and Office Chaos can't be bought during the review or this close to the end of a day
	-- (moving up a floor clears the office).
	DisasterCutoff = 60,

	-- Office Chaos: a virus attack, a pile of chores, flashing alarms, and double pay for cleaning up.
	Chaos = {
		AlarmTime = 45, -- seconds of alarms and flashing lights
		Trash = 6,
		Messy = 3,
		Broken = 2,
		ChoreMultiplier = 2,
		ChoreBoostTime = 120, -- seconds chores pay double
	},

	-- VIP Employee extras. Fill in catalog ids to give VIPs an outfit in the office (0 = their own clothes)
	-- and emotes on their emote wheel ({ ["Dance"] = emote asset id }).
	Vip = {
		Shirt = 0,
		Pants = 0,
		Emotes = {} :: { [string]: number },
		NametagColor = "#F5C518",
	},
}

function ShopConfig.Product(key: string): Item?
	for _, item in ShopConfig.Products do
		if item.Key == key then
			return item
		end
	end
	return nil
end

function ShopConfig.Pass(key: string): Item?
	for _, item in ShopConfig.Passes do
		if item.Key == key then
			return item
		end
	end
	return nil
end

function ShopConfig.ProductById(id: number): Item?
	for _, item in ShopConfig.Products do
		if item.Id == id then
			return item
		end
	end
	return nil
end

function ShopConfig.PassById(id: number): Item?
	for _, item in ShopConfig.Passes do
		if item.Id == id then
			return item
		end
	end
	return nil
end

return table.freeze(ShopConfig)
