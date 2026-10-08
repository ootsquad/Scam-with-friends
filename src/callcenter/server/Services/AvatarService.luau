--[[
	AvatarService (server, Call Center Place)
	Makes the fake players' avatars so they look like people you'd see on Roblox: a copy of
	ServerStorage.LeadRig (the R15 rig) dressed through a HumanoidDescription with a body from a catalog body
	bundle (head, torso, arms and legs, like the bodies real players wear), a skin tone, face, hair, shirt and
	pants, and sometimes a hat, glasses, a scarf, a backpack, a T-shirt and so on.

	Item pools: when the server starts, the Roblox catalog is searched for every item type and keyword in
	CallConfig.Avatars.Searches (a few pages each), plus body bundles (CallConfig.Avatars.BodySearches), so
	there are hundreds of things to pick from. The ID lists in CallConfig.Avatars are always in the pools too,
	so avatars still work if the search fails. The Output says how many items were found.

	No lookalikes: every outfit is checked against the avatars currently in use, and items fewer avatars are
	wearing are picked first. If an outfit fails to load it's tried again with different items; items that
	keep failing are dropped. If nothing loads, the caller still gets a proper R15 avatar (the rig in their
	skin tone), never nothing.

	Finished avatars go to ReplicatedStorage.LeadAvatars/<leadId>, scripts removed, ready for the Phone app's
	pictures. ReplicatedStorage.LeadAvatarBase is the plain rig the Phone shows while an avatar is loading.

	AvatarService.Start()
	AvatarService.Generate(leadId, skinColor)   queued; returns immediately
	AvatarService.Remove(leadId)
	AvatarService.PoolSizes() -> { [slot]: number }
	AvatarService.LookOf(leadId) -> Look?        the outfit an avatar is wearing (for tests)
]]

local AssetService = game:GetService("AssetService")
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
local BASE_NAME = "LeadAvatarBase"
local WORK_SPOT = CFrame.new(0, 4000, 0) -- out of sight while accessories settle onto the rig
local BODY_COLORS = { "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" }
local BODY_PARTS = { "Head", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg" }
local SCALE_NAMES = { "HeightScale", "WidthScale", "DepthScale", "HeadScale", "BodyTypeScale", "ProportionScale" }

-- Pool name -> catalog asset type and the HumanoidDescription property it goes in. "Bodies" holds body
-- bundles: their parts are looked up when one is picked.
local SLOTS: { [string]: { asset: string?, property: string?, accessory: boolean } } = {
	Bodies = { asset = nil, property = nil, accessory = false },
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
-- Picked in this order; Hair, Faces, Shirts and Pants are always worn, Bodies by BodyChance, the rest by
-- CallConfig.Avatars.Chances.
local SLOT_ORDER = {
	"Bodies", "Hair", "Faces", "Shirts", "Pants", "Hats", "FaceAccessories", "TShirts", "NeckAccessories",
	"BackAccessories", "ShoulderAccessories", "WaistAccessories", "FrontAccessories",
}
local ALWAYS = { Hair = true, Faces = true, Shirts = true, Pants = true }
local ESSENTIAL = { "Hair", "Shirts", "Pants" }

export type Look = {
	skin: Color3,
	items: { [string]: number },
	scales: { [string]: number },
	signature: string,
}

type Body = { parts: { [string]: number }, scales: { [string]: number } }

local AvatarService = {}

local random = Random.new()
local pools: { [string]: { number } } = {}
local inPool: { [string]: { [number]: boolean } } = {}
local usage: { [number]: number } = {} -- item -> avatars wearing it right now
local strikes: { [number]: number } = {}
local good: { [number]: boolean } = {} -- items that have loaded fine at least once
local bodies: { [number]: Body | false } = {} -- body bundle -> its parts (false = couldn't be read)
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
		local asset = SLOTS[slot].asset
		if asset then
			params.AssetTypes = { (Enum.AvatarAssetType :: any)[asset] }
		else
			params.BundleTypes = { Enum.BundleType.BodyParts }
		end
		params.Limit = SETTINGS.PageSize
		if keyword ~= "" then
			params.SearchKeyword = keyword
		end
		local results = AvatarEditorService:SearchCatalogAsync(params)
		for page = 1, pages do
			for _, item in results:GetCurrentPage() do
				local isBundle = item.ItemType == "Bundle"
				if type(item.Id) == "number" and isBundle == (asset == nil) then
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
	local jobs = {}
	for _, slot in SLOT_ORDER do
		local keywords = if slot == "Bodies" then SETTINGS.BodySearches else SETTINGS.Searches[slot]
		if keywords and #keywords > 0 then
			table.insert(jobs, { slot = slot, keywords = keywords })
		end
	end
	-- Counted up front so "ready" can't be reported while searches are still to start.
	searching = #jobs
	for _, job in jobs do
		task.spawn(function()
			for _, keyword in job.keywords do
				search(job.slot, keyword, if keyword == "" then SETTINGS.FirstPages else SETTINGS.KeywordPages)
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

-- The head, torso, arms, legs and body scales of a body bundle, from the outfit that comes with it. Yields
-- the first time; nil if the bundle can't be read.
local function bodyOf(bundleId: number): Body?
	local cached = bodies[bundleId]
	if cached ~= nil then
		return cached or nil
	end
	local ok, result = pcall(function(): Body?
		local details = AssetService:GetBundleDetailsAsync(bundleId)
		for _, item in details.Items do
			if item.Type == "UserOutfit" then
				local outfit = Players:GetHumanoidDescriptionFromOutfitId(item.Id)
				local parts = {}
				for _, name in BODY_PARTS do
					local id = (outfit :: any)[name]
					if type(id) == "number" and id > 0 then
						parts[name] = id
					end
				end
				local scales = {}
				for _, name in SCALE_NAMES do
					scales[name] = (outfit :: any)[name]
				end
				outfit:Destroy()
				if next(parts) then
					return { parts = parts, scales = scales }
				end
			end
		end
		return nil
	end)
	local body = if ok then result else nil
	bodies[bundleId] = body or false
	if not body then
		dropFromPool("Bodies", bundleId)
	end
	return body
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

local function randomScales(): { [string]: number }
	local scales = {}
	for name, range in SETTINGS.Scales do
		scales[name] = math.round(random:NextNumber(range[1], range[2]) * 100) / 100
	end
	return scales
end

local function newLook(skin: Color3): Look
	local look: Look
	for _ = 1, 12 do
		local items = {}
		for _, slot in SLOT_ORDER do
			local chance = if slot == "Bodies" then SETTINGS.BodyChance else SETTINGS.Chances[slot] or 0
			if ALWAYS[slot] or random:NextNumber() < chance then
				items[slot] = pickFresh(slot)
			end
		end
		look = { skin = skin, items = items, scales = randomScales(), signature = signatureOf(skin, items) }
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

-- Builds the description. A body bundle brings its own parts and proportions (nudged a little so two
-- people in the same body aren't twins); otherwise the classic body gets random proportions.
-- plain = skin and proportions only, nothing from the catalog.
local function describe(look: Look, body: Body?, plain: boolean): HumanoidDescription
	local description = Instance.new("HumanoidDescription")
	for _, property in BODY_COLORS do
		(description :: any)[property] = look.skin
	end
	if body and not plain then
		for name, id in body.parts do
			(description :: any)[name] = id
		end
		for name, value in body.scales do
			if type(value) == "number" then
				-- Height and width vary per caller; the bundle's own shape (body type, proportions) is kept.
				local vary = if name == "HeightScale" or name == "WidthScale" then look.scales[name] or 1 else 1
				(description :: any)[name] = math.round(value * vary * 100) / 100
			end
		end
	else
		for name, value in look.scales do
			(description :: any)[name] = value
		end
	end
	if plain then
		return description
	end
	for slot, item in look.items do
		local info = SLOTS[slot]
		if info.property then
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

local function baseRig(): Model?
	local base = ServerStorage:FindFirstChild(RIG_NAME)
	if base and base:IsA("Model") and base:FindFirstChildOfClass("Humanoid") then
		return base
	end
	if not warnedRig then
		warnedRig = true
		warn(`[AvatarService] ServerStorage.{RIG_NAME} is missing; building default R15 avatars instead`)
	end
	return nil
end

local function dress(description: HumanoidDescription): Model?
	local base = baseRig()
	if base then
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

-- Last resort: the plain rig in the caller's skin tone. Needs nothing to load.
local function bareRig(skin: Color3): Model?
	local base = baseRig()
	if not base then
		return nil
	end
	local rig = base:Clone()
	for _, part in rig:GetDescendants() do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" and not part:FindFirstAncestorOfClass("Accessory") then
			part.Color = skin
		end
	end
	placeForDressing(rig)
	return rig
end

-- Strips scripts and physics so the model can sit in a ViewportFrame.
local function prepare(model: Model, name: string, parent: Instance)
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
	model.Name = name
	model.Parent = parent
end

local function finish(id: number, model: Model)
	if removed[id] then
		removed[id] = nil
		release(id)
		model:Destroy()
		return
	end
	prepare(model, tostring(id), output)
end

local function build(id: number, skin: Color3)
	waitForPools()
	for _ = 1, ATTEMPTS do
		if removed[id] then
			removed[id] = nil
			return
		end
		local look = newLook(skin)
		local body = nil
		if look.items.Bodies then
			body = bodyOf(look.items.Bodies)
			if not body then
				look.items.Bodies = nil
				look.signature = signatureOf(skin, look.items)
			end
		end
		claim(id, look)
		local model = dress(describe(look, body, false))
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

	-- Every outfit failed (the catalog may be down): skin and proportions only, then the bare rig.
	local look = newLook(skin)
	look.items = {}
	look.signature = signatureOf(skin, look.items) .. `|{id}`
	local model = dress(describe(look, nil, true)) or bareRig(skin)
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
				-- A build that errors must not take its worker down with it.
				local ok, err = pcall(build, job.id, job.skin)
				if not ok then
					warn(`[AvatarService] building lead {job.id}'s avatar failed: {err}`)
				end
			else
				removed[job.id] = nil
			end
			busy -= 1
			pump()
		end)
	end
end

-- The plain rig the Phone shows while a caller's avatar is still loading.
local function publishBase()
	local base = baseRig()
	if not base or ReplicatedStorage:FindFirstChild(BASE_NAME) then
		return
	end
	prepare(base:Clone(), BASE_NAME, ReplicatedStorage)
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
	publishBase()

	if SETTINGS.SearchCatalog then
		searchCatalog()
	end
end

return AvatarService
