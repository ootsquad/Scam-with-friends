--!strict
--[[
	OfficeConfig
	The office tower, your career, the equipment store, office chores and the first-shift checklist.

	Floors: every shift starts on floor 1, Rock Bottom. Each passed performance review (one per 15-minute
	day) moves the crew one floor up, until the Penthouse on floor 6. Each floor gives every desk on it a small perk. Your best floor is
	saved and unlocks better equipment in the store.

	Building the floors (in Studio): see OFFICE.md. In short, put each floor in a Model or Folder tagged
	"OfficeFloor" with a number attribute "Floor" (1-6), with its Computer seats and a Part named
	"FloorSpawn" inside. Until floors are built, the crew stays in whatever office has Computer seats and
	the perks still apply.
]]

export type Floor = {
	Name: string,
	Title: string, -- your job title on this floor
	StartTrust: number, -- added to every caller's starting trust
	PayoutBonus: number, -- 0.05 = +5% on every payout
	Perk: string, -- shown in the Career app and the elevator
}

export type Tier = {
	Name: string,
	Price: number, -- career cash
	Floor: number, -- best floor you need to have reached to buy it
	Value: number, -- the effect (see the category's Effect)
	Blurb: string,
}

export type Category = {
	Label: string,
	Effect: string, -- what Value means, for the store
	Tiers: { Tier }, -- tier 1 is what everyone starts with
}

local OfficeConfig = {
	Floors = {
		{
			Name = "Rock Bottom",
			Title = "Cold Caller",
			StartTrust = 0,
			PayoutBonus = 0,
			Perk = "No perks yet. Pass the review to move up.",
		},
		{
			Name = "Getting Started",
			Title = "Junior Agent",
			StartTrust = 3,
			PayoutBonus = 0,
			Perk = "Callers start at +3 trust.",
		},
		{
			Name = "Established",
			Title = "Senior Agent",
			StartTrust = 3,
			PayoutBonus = 0.05,
			Perk = "Callers start at +3 trust. Payouts +5%.",
		},
		{
			Name = "Corporate",
			Title = "Account Manager",
			StartTrust = 5,
			PayoutBonus = 0.05,
			Perk = "Callers start at +5 trust. Payouts +5%.",
		},
		{
			Name = "Executive",
			Title = "Executive",
			StartTrust = 5,
			PayoutBonus = 0.1,
			Perk = "Callers start at +5 trust. Payouts +10%.",
		},
		{
			Name = "Penthouse",
			Title = "CEO",
			StartTrust = 8,
			PayoutBonus = 0.15,
			Perk = "Callers start at +8 trust. Payouts +15%. You made it to the top.",
		},
	} :: { Floor },

	-- Building tags (see OFFICE.md)
	FloorTag = "OfficeFloor", -- a Model or Folder per floor, with a number attribute "Floor"
	SpawnName = "FloorSpawn", -- a Part inside a floor (named or tagged) where the crew arrives
	SignTag = "FloorSign", -- TextLabels inside it show the floor's number and name
	ElevatorTime = 3.5, -- seconds the elevator screen stays up when the crew moves floors

	-- Equipment store, run by a vendor in a store room. Tag the vendor (a Model with a Humanoid, or any
	-- Part such as a counter) "StoreVendor"; its "Shop" prompt opens the store. Floors without a vendor get
	-- a stand-in vendor next to the floor's spawn. You always use the best tier you own. Gear lasts one shift
	-- (it isn't saved with the career), so prices are per shift.
	VendorTag = "StoreVendor",
	ShopRange = 16, -- studs from a vendor where buying works (the store closes if you walk further)
	EquipmentOrder = { "Headset", "Computer", "Router" },
	Equipment = {
		Headset = {
			Label = "Headsets",
			Effect = "more trust from every good line",
			Tiers = {
				{ Name = "Tangled Earbuds", Price = 0, Floor = 1, Value = 0, Blurb = "One side works. Mostly." },
				{ Name = "Office Headset", Price = 150, Floor = 1, Value = 0.1, Blurb = "+10% trust gains" },
				{ Name = "Noise-Cancel Pro", Price = 500, Floor = 3, Value = 0.2, Blurb = "+20% trust gains" },
				{ Name = "Golden Earpiece", Price = 1200, Floor = 5, Value = 0.3, Blurb = "+30% trust gains" },
			},
		},
		Computer = {
			Label = "Computers",
			Effect = "new leads show up sooner",
			Tiers = {
				{ Name = "Beige Tower", Price = 0, Floor = 1, Value = 0, Blurb = "Still runs Solitaire." },
				{ Name = "Office PC", Price = 200, Floor = 1, Value = 0.25, Blurb = "Leads refresh 25% faster" },
				{ Name = "Gaming Rig", Price = 600, Floor = 3, Value = 0.45, Blurb = "Leads refresh 45% faster" },
				{ Name = "Quantum Workstation", Price = 1400, Floor = 5, Value = 0.65, Blurb = "Leads refresh 65% faster" },
			},
		},
		Router = {
			Label = "Routers",
			Effect = "bigger payouts",
			Tiers = {
				{ Name = "Dusty Router", Price = 0, Floor = 1, Value = 0, Blurb = "Blinks a lot." },
				{ Name = "Dual-Band Router", Price = 180, Floor = 1, Value = 0.05, Blurb = "Payouts +5%" },
				{ Name = "Mesh Pro", Price = 550, Floor = 3, Value = 0.1, Blurb = "Payouts +10%" },
				{ Name = "Fiber Beast", Price = 1300, Floor = 5, Value = 0.15, Blurb = "Payouts +15%" },
			},
		},
	} :: { [string]: Category },

	-- Office chores: trash, messy desks and broken equipment show up while the day clock runs. Anyone can
	-- do them (hold the prompt) for a small bonus that counts toward the quota.
	Chores = {
		Enabled = true,
		Every = { Min = 25, Max = 50 }, -- seconds between new chores
		MaxTrash = 3,
		MaxMessy = 2,
		MaxBroken = 2,
		Reward = { Trash = 10, Desk = 15, Fix = 20 },
		HoldTime = { Trash = 0.4, Desk = 1.5, Fix = 2.5 },
		TidyTrust = 2, -- extra starting trust on every call while there's no trash and no messy desk
		MessyTrust = -3, -- starting trust for calls made from a messy desk
		BrokenGain = 0.75, -- trust gains are multiplied by this at a desk with broken equipment
		-- Optional building tags. Without them, trash shows up next to desks and the desk computers break.
		TrashSpotTag = "TrashSpot", -- Parts where trash can appear
		TrashBinTag = "TrashBin", -- Parts to throw trash into (then trash has to be carried there)
		EquipmentTag = "Equipment", -- Parts (routers, servers, printers) that can break; affects the whole floor
	},

	-- Saved per player
	Career = {
		DataStore = "Career_v1",
		AutosaveEvery = 90, -- seconds
	},

	-- First-shift checklist. Each step is ticked off by the server as it happens.
	Tutorial = {
		{ Key = "Sit", Text = "Sit down at a free computer" },
		{ Key = "Login", Text = "Log in with your Roblox username" },
		{ Key = "Call", Text = "Call a lead from the Phone app" },
		{ Key = "Paid", Text = "Get a caller to pay you" },
		{ Key = "CashIn", Text = "Cash it in (Gift Cards, Card Terminal or GiveHope)" },
		{ Key = "Chore", Text = "Do an office chore (look for prompts)" },
	} :: { { Key: string, Text: string } },
	TutorialHiddenBit = 7, -- set when the player hides the checklist

	-- Sound effects (Effects volume). Swap in your own sound ids.
	Sounds = {
		Notify = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.4, Speed = 1.2 },
		Ring = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.6, Speed = 0.9 },
		Payout = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.6, Speed = 1.6 },
		Ding = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.7, Speed = 0.7 },
		Chore = { Id = "rbxasset://sounds/swoosh.wav", Volume = 0.5, Speed = 1 },
		Error = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.35, Speed = 0.6 },
		Click = { Id = "rbxasset://sounds/clickfast.wav", Volume = 0.3, Speed = 1 },
	} :: { [string]: { Id: string, Volume: number, Speed: number } },
}

-- Index of a tutorial step by key.
function OfficeConfig.StepIndex(key: string): number?
	for index, step in OfficeConfig.Tutorial do
		if step.Key == key then
			return index
		end
	end
	return nil
end

function OfficeConfig.FloorInfo(floor: number): Floor
	local floors = OfficeConfig.Floors
	return floors[math.clamp(floor, 1, #floors)]
end

return table.freeze(OfficeConfig)
