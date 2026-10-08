--[[
	AvatarService (server, Call Center Place)
	Makes the fake players' avatars: a copy of ServerStorage.LeadRig (the R15 rig) dressed through a
	HumanoidDescription with a random skin tone, body shape, face, hair, shirt and pants, and sometimes a
	hat, glasses, a scarf, a backpack, a T-shirt and so on.

	Item pools: when the server starts, the Roblox catalog is searched for every item type and keyword in
	CallConfig.Avatars.Searches (a few pages each), so there are hundreds of items to pick from. The ID lists
	in CallConfig.Avatars are always in the pools too, so avatars still work if the search fails. The Output
	says how many items were found.

	No lookalikes: every outfit is checked against the avatars currently in use, and items that fewer
	avatars are wearing are picked first. If an avatar fails to load (an item that won't load, say), it's
	tried again with different items; items that keep failing are dropped from the pools.

	Finished avatars go to ReplicatedStorage.LeadAvatars/<leadId>, scripts removed, ready for the Phone app's
	ViewportFrames.

	AvatarService.Start()
	AvatarService.Generate(leadId, skinColor)   queued; returns immediately
	AvatarService.Remove(leadId)
	AvatarService.PoolSizes() -> { [slot]: number }
	AvatarService.LookOf(leadId) -> Look?        the outfit an avatar is wearing (for tests)
]]

local AvatarEditorService = game:GetService("AvatarEditorService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local CallConfig = require(ReplicatedStorage:WaitForChild("Shared").Config.CallConfig)

local SETTINGS = CallConfig.Avatars
local WORKERS = 4
local ATTEMPTS = 3 -- outfits tried per avatar before falling back to a plain one
local STRIKES = 2 -- failed outfits an item can be part of before it's dropped (unless it has worked before)
local POOL_WAIT = 15 -- seconds the first avatars wait for the catalog search
local READY_COUNT = 15 -- items each essential pool needs before avatars start without waiting longer
local RIG_NAME = "LeadRig"
local WORK_SPOT = CFrame.new(0, 4000, 0) -- out of sight while accessories settle onto the rig
local BODY_COLORS = { "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" }

-- Pool name -> catalog asset type and the HumanoidDescription property it goes in.
local SLOTS: { [string]: { asset: string, property: string, accessory: boolean } } = {
	Hair = { asset = "HairAccessory", property = "HairAccessory", accessory = true },
	Hats = { asset = "Hat", property = "HatAccessory", accessory = true },
	FaceAccessories = { asset = "FaceAccessory", property = "FaceAccessory", accessory = true },
	NeckAccessories = { asset = "NeckAccessory", property = "NeckAccessory", accessory = true },
	ShoulderAccessories = { asset = "ShoulderAccessory", property = "ShouldersAccessory", accessory = true },
	BackAccessories = { asset = "BackAccessory", property = "BackAccessory", accessory = true },
	WaistAccessories = { asset = "WaistAccessory", property = "WaistAccessory", accessory = true },
	FrontAccessories = { asset = "FrontAccessory", property = "FrontAccessory", accessory = true },
	Shirts = { asset = "Shirt", property = "Shirt", accessory = false },
	Pants = { asset = "Pants", property = "Pants", accessory = false },
	TShirts = { asset = "TShirt", property = "GraphicTShirt", accessory = false },
	Faces = { asset = "Face", property = "Face", accessory = false },
}
-- Picked in this order; the first four are always worn, the rest by CallConfig.Avatars.Chances.
local SLOT_ORDER = {
	"Hair", "Faces", "Shirts", "Pants", "Hats", "FaceAccessories", "TShirts", "NeckAccessories", "BackAccessories",
	"ShoulderAccessories", "WaistAccessories", "FrontAccessories",
}
local ALWAYS = { Hair = true, Faces = true, Shirts = true, Pants = true }
local ESSENTIAL = { "Hair", "Shirts", "Pants" }

export type Look = {
	skin: Color3,
	items: { [string]: number },
	scales: { [string]: number },
	signature: string,
}

local AvatarService = {}

local random = Random.new()
local pools: { [string]: { number } } = {}
local inPool: { [string]: { [number]: boolean } } = {}
local usage: { [number]: number } = {} -- item -> avatars wearing it right now
local strikes: { [number]: number } = {}
local good: { [number]: boolean } = {} -- items that have loaded fine at least once
local worn: { [string]: number } = {} -- outfit signature -> lead wearing it
local looks: { [number]: Look } = {} -- lead -> outfit
local queue: { { id: number, skin: Color3 } } = {}
local removed: { [number]: boolean } = {}
local busy = 0
local output: Folder
local workspaceFolder: Folder -- in the Workspace so welds/joints settle while dressing
local warnedRig = false
local searching = 0
local searchStarted = 0
local searchFailures = 0
local lastSearchError = ""

-- ---------------------------------------------------------------------------
-- Pools
-- ---------------------------------------------------------------------------

local function addToPool(slot: string, id: number)
	if id > 0 and not inPool[slot][id] then
		inPool[slot][id] = true
		table.insert(pools[slot], id)
	end
end

local function dropFromPool(slot: string, id: number)
	local pool = pools[slot]
	local index = table.find(pool, id)
	if index then
		table.remove(pool, index)
	end
	inPool[slot][id] = nil
end

local function poolsReady(): boolean
	if searching == 0 then
		return true
	end
	for _, slot in ESSENTIAL do
		if #pools[slot] < READY_COUNT then
			return false
		end
	end
	return true
end

local function waitForPools()
	local deadline = os.clock() + POOL_WAIT
	while not poolsReady() and os.clock() < deadline do
		task.wait(0.25)
	end
end

local function search(slot: string, keyword: string, pages: number)
	local ok, err = pcall(function()
		local params = CatalogSearchParams.new()
		params.AssetTypes = { (Enum.AvatarAssetType :: any)[SLOTS[slot].asset] }
		params.Limit = SETTINGS.PageSize
		if keyword ~= "" then
			params.SearchKeyword = keyword
		end
		local results = AvatarEditorService:SearchCatalogAsync(params)
		for page = 1, pages do
			for _, item in results:GetCurrentPage() do
				if type(item.Id) == "number" and item.ItemType ~= "Bundle" then
					addToPool(slot, item.Id)
				end
			end
			if page == pages or results.IsFinished then
				break
			end
			results:AdvanceToNextPageAsync()
		end
	end)
	if not ok then
		searchFailures += 1
		lastSearchError = tostring(err)
	end
end

local function summary(): string
	local parts = {}
	for _, slot in SLOT_ORDER do
		table.insert(parts, `{#pools[slot]} {slot}`)
	end
	return table.concat(parts, ", ")
end

local function searchCatalog()
	searchStarted = os.clock()
	local slots = {}
	for _, slot in SLOT_ORDER do
		local keywords = SETTINGS.Searches[slot]
		if keywords and #keywords > 0 then
			table.insert(slots, slot)
		end
	end
	-- Counted up front so "ready" can't be reported while searches are still to start.
	searching = #slots
	for _, slot in slots do
		local keywords = SETTINGS.Searches[slot]
		task.spawn(function()
			for _, keyword in keywords do
				search(slot, keyword, if keyword == "" then SETTINGS.FirstPages else SETTINGS.KeywordPages)
			end
			searching -= 1
			if searching == 0 then
				local seconds = math.floor((os.clock() - searchStarted) * 10) / 10
				print(`[AvatarService] avatar items ready in {seconds}s: {summary()}`)
				if searchFailures > 0 then
					warn(`[AvatarService] {searchFailures} catalog searches failed (last: {lastSearchError}). `
						.. "Avatars use whatever was found plus the lists in CallConfig.Avatars.")
				end
			end
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Outfits
-- ---------------------------------------------------------------------------

-- A random item from the pool, preferring ones fewer avatars are wearing right now.
local function pickFresh(slot: string): number?
	local pool = pools[slot]
	if #pool == 0 then
		return nil
	end
	local best, bestUse = nil, math.huge
	for _ = 1, math.min(10, #pool) do
		local id = pool[random:NextInteger(1, #pool)]
		local use = usage[id] or 0
		if use < bestUse then
			best, bestUse = id, use
			if use == 0 then
				break
			end
		end
	end
	return best
end

local function signatureOf(skin: Color3, items: { [string]: number }): string
	local parts = { skin:ToHex() }
	for _, slot in SLOT_ORDER do
		table.insert(parts, tostring(items[slot] or 0))
	end
	return table.concat(parts, "|")
end

local function newLook(skin: Color3): Look
	local look: Look
	for _ = 1, 12 do
		local items = {}
		for _, slot in SLOT_ORDER do
			if ALWAYS[slot] or random:NextNumber() < (SETTINGS.Chances[slot] or 0) then
				items[slot] = pickFresh(slot)
			end
		end
		local scales = {}
		for name, range in SETTINGS.Scales do
			scales[name] = math.round(random:NextNumber(range[1], range[2]) * 100) / 100
		end
		look = { skin = skin, items = items, scales = scales, signature = signatureOf(skin, items) }
		if not worn[look.signature] then
			break
		end
	end
	return look
end

local function claim(id: number, look: Look)
	looks[id] = look
	worn[look.signature] = id
	for _, item in look.items do
		usage[item] = (usage[item] or 0) + 1
	end
end

local function release(id: number)
	local look = looks[id]
	if not look then
		return
	end
	looks[id] = nil
	if worn[look.signature] == id then
		worn[look.signature] = nil
	end
	for _, item in look.items do
		usage[item] = math.max((usage[item] or 1) - 1, 0)
	end
end

-- The outfit didn't load. Items that haven't worked before get a strike; too many and they're dropped.
local function strike(look: Look)
	for slot, item in look.items do
		if not good[item] then
			strikes[item] = (strikes[item] or 0) + 1
			if strikes[item] >= STRIKES then
				dropFromPool(slot, item)
			end
		end
	end
end

local function describe(look: Look, plain: boolean): HumanoidDescription
	local description = Instance.new("HumanoidDescription")
	for _, property in BODY_COLORS do
		(description :: any)[property] = look.skin
	end
	for name, value in look.scales do
		(description :: any)[name] = value
	end
	for slot, item in look.items do
		local info = SLOTS[slot]
		if not plain or slot == "Faces" then
			(description :: any)[info.property] = if info.accessory then tostring(item) else item
		end
	end
	return description
end

-- ---------------------------------------------------------------------------
-- Building
-- ---------------------------------------------------------------------------

-- Accessories are welded on; joints only settle in the Workspace, so the rig is dressed there (root
-- anchored, far away) and frozen afterwards.
local function placeForDressing(model: Model)
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.Anchored = true
	end
	pcall(function()
		model:PivotTo(WORK_SPOT)
	end)
	model.Parent = workspaceFolder
end

local function settle()
	for _ = 1, 3 do
		RunService.Heartbeat:Wait()
	end
end

local function dress(description: HumanoidDescription): Model?
	local base = ServerStorage:FindFirstChild(RIG_NAME)
	if base and base:FindFirstChildOfClass("Humanoid") then
		local rig = base:Clone()
		placeForDressing(rig)
		local humanoid = rig:FindFirstChildOfClass("Humanoid") :: Humanoid
		local ok = pcall(function()
			humanoid:ApplyDescriptionAsync(description, Enum.AssetTypeVerification.ClientOnly)
		end)
		if not ok then
			ok = pcall(function()
				(humanoid :: any):ApplyDescription(description, Enum.AssetTypeVerification.ClientOnly)
			end)
		end
		if ok then
			settle()
			return rig
		end
		rig:Destroy()
		return nil
	elseif not warnedRig then
		warnedRig = true
		warn(`[AvatarService] ServerStorage.{RIG_NAME} is missing; building default R15 avatars instead`)
	end

	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15, Enum.AssetTypeVerification.ClientOnly)
	end)
	if not ok or not model then
		return nil
	end
	placeForDressing(model)
	settle()
	return model
end

-- Strips scripts and physics so the model can sit in a ViewportFrame.
local function prepare(model: Model, id: number)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("LuaSourceContainer") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	model.Name = tostring(id)
	model.Parent = output
end

local function finish(id: number, model: Model): boolean
	if removed[id] then
		removed[id] = nil
		release(id)
		model:Destroy()
		return false
	end
	prepare(model, id)
	return true
end

local function build(id: number, skin: Color3)
	waitForPools()
	for _ = 1, ATTEMPTS do
		if removed[id] then
			removed[id] = nil
			return
		end
		local look = newLook(skin)
		claim(id, look)
		local model = dress(describe(look, false))
		if model then
			for _, item in look.items do
				good[item] = true
			end
			finish(id, model)
			return
		end
		release(id)
		strike(look)
	end

	-- Every outfit failed (the catalog may be down): skin, body shape and face only.
	local look = newLook(skin)
	local model = dress(describe(look, true))
	if not model then
		warn(`[AvatarService] couldn't build an avatar for lead {id}`)
		return
	end
	claim(id, look)
	finish(id, model)
end

local function pump()
	while busy < WORKERS and #queue > 0 do
		local job = table.remove(queue, 1) :: any
		busy += 1
		task.spawn(function()
			if not removed[job.id] then
				build(job.id, job.skin)
			else
				removed[job.id] = nil
			end
			busy -= 1
			pump()
		end)
	end
end

function AvatarService.Generate(id: number, skin: Color3)
	removed[id] = nil
	table.insert(queue, { id = id, skin = skin })
	pump()
end

function AvatarService.Remove(id: number)
	release(id)
	local existing = output:FindFirstChild(tostring(id))
	if existing then
		existing:Destroy()
	else
		removed[id] = true
	end
end

function AvatarService.PoolSizes(): { [string]: number }
	local sizes = {}
	for slot, pool in pools do
		sizes[slot] = #pool
	end
	return sizes
end

function AvatarService.LookOf(id: number): Look?
	return looks[id]
end

function AvatarService.Start()
	for slot in SLOTS do
		pools[slot] = {}
		inPool[slot] = {}
		for _, id in (SETTINGS :: any)[slot] or {} do
			addToPool(slot, id)
		end
	end

	output = Instance.new("Folder")
	output.Name = "LeadAvatars"
	output.Parent = ReplicatedStorage
	workspaceFolder = Instance.new("Folder")
	workspaceFolder.Name = "LeadAvatarWork"
	workspaceFolder.Parent = workspace

	if SETTINGS.SearchCatalog then
		searchCatalog()
	end
end

return AvatarService
