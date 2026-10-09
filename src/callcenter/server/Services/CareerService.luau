--[[
	CareerService (server, Call Center Place)
	Each player's saved career (DataStore OfficeConfig.Career.DataStore, shared by every shift):
	  career cash   everything you earn on shifts is added to it; spend it in the equipment store
	  best floor    the highest office floor you've reached; unlocks better equipment
	  stats         shifts, days passed, lifetime earnings, calls, callers who paid, chores
	  equipment     the best headset / computer / router tier you own (you always use the best one)
	  checklist     which first-shift steps you've done

	If DataStores aren't reachable (Studio without API access, a Studio test player), the career works for the
	session and the client is told it won't be saved.

	CareerService.Start()
	CareerService.Earned(player, amount)             personal earnings (EconomyService calls this)
	CareerService.Count(player, stat)                 "Calls" | "Scams" | "Chores" | "DaysPassed"
	CareerService.ReachedFloor(player, floor)
	CareerService.StartedShift(player)               once per shift, at their first login
	CareerService.CompleteStep(player, key)          OfficeConfig.Tutorial key
	CareerService.Tier(player, kind) -> Tier          the equipment they use ("Headset" | "Computer" | "Router")
	CareerService.IsReady(player) -> boolean          their client asked for the career (can receive packets)
	CareerService.SetShopCheck(check(player) -> boolean)   buying only works when this says yes (VendorService:
	                                                  next to the store's vendor)
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OfficeConfig = require(Shared.Config.OfficeConfig)
local Format = require(Shared.Util.Format)
local Namespace = require(Shared.Network.Namespace)
local Career = require(Shared:WaitForChild("Network")).Career
local CareerNet = require(Shared.Network.Career) -- types

type Record = {
	Cash: number,
	BestFloor: number,
	Shifts: number,
	DaysPassed: number,
	Earned: number,
	Calls: number,
	Scams: number,
	Chores: number,
	Headset: number,
	Computer: number,
	Router: number,
	Tutorial: number,
}

type Profile = {
	record: Record,
	persistent: boolean, -- loaded from (and saved to) the DataStore
	dirty: boolean,
	loaded: boolean,
	waiting: { thread },
}

local STATS = { "Cash", "BestFloor", "Shifts", "DaysPassed", "Earned", "Calls", "Scams", "Chores", "Tutorial" }
local LOAD_ATTEMPTS = 3
local MAX_NUMBER = 2 ^ 31 -- keeps values inside the network's uint32 fields

local CareerService = {}

local profiles: { [Player]: Profile } = {}
local ready: { [Player]: boolean } = {}
local startedShift: { [Player]: boolean } = {}
local store: DataStore? | false = nil
local shopCheck: ((Player) -> boolean)? = nil

-- ---------------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------------

local function getStore(): DataStore?
	if store == nil then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(OfficeConfig.Career.DataStore)
		end)
		store = if ok then result else false
	end
	return if store then store else nil
end

local function key(player: Player): string
	return `u_{player.UserId}`
end

-- Never trust stored data: whole numbers in range, known tiers only.
local function sanitize(raw: any): Record
	local data = if type(raw) == "table" then raw else {}
	local function count(value: any, min: number, max: number, default: number): number
		if type(value) == "number" and value == value then
			return math.clamp(math.floor(value), min, max)
		end
		return default
	end
	local record = {} :: any
	for _, stat in STATS do
		record[stat] = count(data[stat], 0, MAX_NUMBER, 0)
	end
	record.BestFloor = math.clamp(record.BestFloor, 1, #OfficeConfig.Floors)
	record.Tutorial = math.clamp(record.Tutorial, 0, 0xFFFF)
	for _, kind in OfficeConfig.EquipmentOrder do
		record[kind] = count(data[kind], 1, #OfficeConfig.Equipment[kind].Tiers, 1)
	end
	return record :: Record
end

local function snapshot(profile: Profile): CareerNet.CareerData
	local record = profile.record :: any
	local data = {} :: any
	for _, stat in STATS do
		data[stat] = record[stat]
	end
	for _, kind in OfficeConfig.EquipmentOrder do
		data[kind] = record[kind]
	end
	data.Persistent = profile.persistent
	return data
end

local function push(player: Player)
	local profile = profiles[player]
	if profile and ready[player] and player.Parent then
		Career.packets.Update.sendTo(snapshot(profile), player)
	end
end

local function save(player: Player)
	local profile = profiles[player]
	if not profile or not profile.persistent or not profile.dirty then
		return
	end
	local dataStore = getStore()
	if not dataStore then
		return
	end
	profile.dirty = false
	local record = table.clone(profile.record)
	local ok, err = pcall(function()
		dataStore:UpdateAsync(key(player), function()
			return record
		end, { player.UserId })
	end)
	if not ok then
		profile.dirty = true -- try again at the next autosave
		warn(`[CareerService] couldn't save {player.Name}'s career: {err}`)
	end
end

local function load(player: Player)
	local profile: Profile = { record = sanitize(nil), persistent = false, dirty = false, loaded = false, waiting = {} }
	profiles[player] = profile

	local dataStore = getStore()
	if dataStore and player.UserId > 0 then
		for attempt = 1, LOAD_ATTEMPTS do
			local ok, stored = pcall(function()
				return dataStore:GetAsync(key(player))
			end)
			if ok then
				profile.record = sanitize(stored)
				profile.persistent = true
				break
			end
			warn(`[CareerService] couldn't load {player.Name}'s career (attempt {attempt}): {stored}`)
			if attempt < LOAD_ATTEMPTS then
				task.wait(attempt * 2)
			end
		end
	end
	if profiles[player] ~= profile then
		return -- left while loading
	end
	profile.loaded = true
	for _, thread in profile.waiting do
		task.spawn(thread)
	end
	profile.waiting = {}
	push(player)
end

-- The player's profile once it has loaded (yields while it loads). nil if they left.
local function profileOf(player: Player): Profile?
	local profile = profiles[player]
	if profile and not profile.loaded then
		table.insert(profile.waiting, coroutine.running())
		coroutine.yield()
		profile = profiles[player]
	end
	return profile
end

-- Changes a loaded profile right away, or once it has loaded (without holding up the caller).
local function change(player: Player, edit: (Record) -> boolean?)
	local profile = profiles[player]
	if not profile then
		return
	end
	local function apply()
		local current = profiles[player]
		if current and edit(current.record) ~= false then
			current.dirty = true
			push(player)
		end
	end
	if profile.loaded then
		apply()
	else
		task.spawn(function()
			if profileOf(player) then
				apply()
			end
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function CareerService.Earned(player: Player, amount: number)
	if amount <= 0 then
		return
	end
	change(player, function(record)
		record.Cash = math.min(record.Cash + amount, MAX_NUMBER)
		record.Earned = math.min(record.Earned + amount, MAX_NUMBER)
		return true
	end)
end

function CareerService.Count(player: Player, stat: string)
	change(player, function(record: any)
		if type(record[stat]) ~= "number" then
			return false
		end
		record[stat] = math.min(record[stat] + 1, MAX_NUMBER)
		return true
	end)
end

function CareerService.ReachedFloor(player: Player, floor: number)
	change(player, function(record)
		if floor <= record.BestFloor then
			return false
		end
		record.BestFloor = math.clamp(floor, 1, #OfficeConfig.Floors)
		return true
	end)
end

function CareerService.StartedShift(player: Player)
	if startedShift[player] then
		return
	end
	startedShift[player] = true
	CareerService.Count(player, "Shifts")
end

function CareerService.CompleteStep(player: Player, stepKey: string)
	local index = OfficeConfig.StepIndex(stepKey)
	if not index then
		return
	end
	change(player, function(record)
		local bit = bit32.lshift(1, index)
		if bit32.btest(record.Tutorial, bit) then
			return false
		end
		record.Tutorial = bit32.bor(record.Tutorial, bit)
		return true
	end)
end

function CareerService.Tier(player: Player, kind: string): OfficeConfig.Tier
	local category = OfficeConfig.Equipment[kind]
	local profile = profiles[player]
	local owned = if profile then (profile.record :: any)[kind] else 1
	return category.Tiers[math.clamp(owned or 1, 1, #category.Tiers)]
end

function CareerService.IsReady(player: Player): boolean
	return ready[player] == true
end

function CareerService.Get(player: Player): CareerNet.CareerData?
	local profile = profiles[player]
	return if profile then snapshot(profile) else nil
end

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

local function onGet(_: nil, player: Player): CareerNet.CareerData
	local profile = profileOf(player)
	ready[player] = true
	if not profile then
		return snapshot({ record = sanitize(nil), persistent = false, dirty = false, loaded = true, waiting = {} })
	end
	return snapshot(profile)
end

local function result(ok: boolean, message: string): CareerNet.Result
	return { Ok = ok, Message = message }
end

local function onBuy(request: any, player: Player): CareerNet.Result
	if type(request) ~= "table" then
		return result(false, "Pick something to buy.")
	end
	local kind = OfficeConfig.EquipmentOrder[request.Kind]
	local category = kind and OfficeConfig.Equipment[kind]
	local tier = category and category.Tiers[request.Tier]
	if not kind or not category or not tier then
		return result(false, "That item isn't in the store.")
	end
	if shopCheck and not shopCheck(player) then
		return result(false, "Walk back to the equipment store to buy that.")
	end
	local profile = profileOf(player)
	if not profile then
		return result(false, "Your career hasn't loaded. Try again in a moment.")
	end
	local record = profile.record :: any
	local owned = record[kind]
	if request.Tier <= owned then
		return result(false, `You already have the {tier.Name}.`)
	elseif request.Tier > owned + 1 then
		local next = category.Tiers[owned + 1]
		return result(false, `Get the {next.Name} first.`)
	elseif record.BestFloor < tier.Floor then
		return result(false, `Unlocks once you've reached floor {tier.Floor}.`)
	elseif record.Cash < tier.Price then
		return result(false, `You need {Format.money(tier.Price - record.Cash)} more career cash.`)
	end
	record.Cash -= tier.Price
	record[kind] = request.Tier
	profile.dirty = true
	push(player)
	task.spawn(save, player) -- purchases are saved straight away
	return result(true, `Bought the {tier.Name}! {tier.Blurb}.`)
end

function CareerService.SetShopCheck(check: (Player) -> boolean)
	shopCheck = check
end

local function onHideTutorial(hidden: boolean, player: Player)
	change(player, function(record)
		local bit = bit32.lshift(1, OfficeConfig.TutorialHiddenBit)
		local new = if hidden then bit32.bor(record.Tutorial, bit) else bit32.band(record.Tutorial, bit32.bnot(bit))
		if new == record.Tutorial then
			return false
		end
		record.Tutorial = new
		return true
	end)
end

-- ---------------------------------------------------------------------------
-- Start
-- ---------------------------------------------------------------------------

function CareerService.Start()
	Namespace.listen(Career.queries.Get, onGet, function()
		return snapshot({ record = sanitize(nil), persistent = false, dirty = false, loaded = true, waiting = {} })
	end)
	Namespace.listen(Career.queries.Buy, onBuy, Namespace.busy)
	Career.packets.HideTutorial.listen(onHideTutorial)

	Players.PlayerAdded:Connect(load)
	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		ready[player] = nil
		startedShift[player] = nil
		save(player)
		local profile = profiles[player]
		profiles[player] = nil
		if profile then
			for _, thread in profile.waiting do
				task.spawn(thread)
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(OfficeConfig.Career.AutosaveEvery)
			for player in profiles do
				task.spawn(save, player)
			end
		end
	end)

	game:BindToClose(function()
		local pending = 0
		for player in profiles do
			pending += 1
			task.spawn(function()
				save(player)
				pending -= 1
			end)
		end
		local deadline = os.clock() + 20
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return CareerService
