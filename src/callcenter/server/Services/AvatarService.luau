--[[
	AvatarService (server, Call Center Place)
	Makes the fake players' avatars: a copy of ServerStorage.LeadRig (the R15 rig) dressed through a
	HumanoidDescription with a random skin tone, face, hair, maybe a hat or face accessory, and clothes.

	Item IDs come from CallConfig.Avatars. With Avatars.SearchCatalog on, the pools are topped up from the
	Roblox catalog when the server starts, so callers don't all look alike.

	Finished avatars go to ReplicatedStorage.LeadAvatars/<leadId>, scripts removed, ready for the Phone app's
	ViewportFrames. If dressing fails (bad ID, catalog down) the client draws a simple blocky stand-in.

	AvatarService.Start()
	AvatarService.Generate(leadId, skinColor)   queued; returns immediately
	AvatarService.Remove(leadId)
]]

local AvatarEditorService = game:GetService("AvatarEditorService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local CallConfig = require(ReplicatedStorage:WaitForChild("Shared").Config.CallConfig)

local SETTINGS = CallConfig.Avatars
local WORKERS = 2
local RIG_NAME = "LeadRig"
local WORK_SPOT = CFrame.new(0, 4000, 0) -- out of sight while accessories settle onto the rig
local BODY_COLORS = { "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" }

local AvatarService = {}

local random = Random.new()
local pools = {
	Hair = table.clone(SETTINGS.Hair),
	Hats = table.clone(SETTINGS.Hats),
	FaceAccessories = table.clone(SETTINGS.FaceAccessories),
	Faces = table.clone(SETTINGS.Faces),
	Shirts = table.clone(SETTINGS.Shirts),
	Pants = table.clone(SETTINGS.Pants),
}
local queue: { { id: number, skin: Color3 } } = {}
local removed: { [number]: boolean } = {}
local busy = 0
local output: Folder
local workspaceFolder: Folder -- in the Workspace so welds/joints settle while dressing
local warnedRig = false

local function pick(list: { number }): number?
	if #list == 0 then
		return nil
	end
	return list[random:NextInteger(1, #list)]
end

-- ---------------------------------------------------------------------------
-- Catalog
-- ---------------------------------------------------------------------------

local function topUp(pool: { number }, assetTypeName: string)
	local ok, err = pcall(function()
		local params = CatalogSearchParams.new()
		params.AssetTypes = { (Enum.AvatarAssetType :: any)[assetTypeName] }
		params.Limit = 30
		local pages = AvatarEditorService:SearchCatalogAsync(params)
		for _, item in pages:GetCurrentPage() do
			if type(item.Id) == "number" and item.ItemType ~= "Bundle" and not table.find(pool, item.Id) then
				table.insert(pool, item.Id)
			end
		end
	end)
	if not ok then
		warn(`[AvatarService] couldn't search the catalog for {assetTypeName} (using CallConfig.Avatars only): {err}`)
	end
end

-- ---------------------------------------------------------------------------
-- Building
-- ---------------------------------------------------------------------------

local function describe(skin: Color3, plain: boolean): HumanoidDescription
	local description = Instance.new("HumanoidDescription")
	for _, property in BODY_COLORS do
		(description :: any)[property] = skin
	end
	local face = pick(pools.Faces)
	if face then
		description.Face = face
	end
	if plain then
		return description
	end
	local hair = pick(pools.Hair)
	if hair then
		description.HairAccessory = tostring(hair)
	end
	if random:NextNumber() < SETTINGS.HatChance then
		local hat = pick(pools.Hats)
		if hat then
			description.HatAccessory = tostring(hat)
		end
	end
	if random:NextNumber() < SETTINGS.FaceAccessoryChance then
		local accessory = pick(pools.FaceAccessories)
		if accessory then
			description.FaceAccessory = tostring(accessory)
		end
	end
	description.Shirt = pick(pools.Shirts) or 0
	description.Pants = pick(pools.Pants) or 0
	return description
end

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

local function build(id: number, skin: Color3)
	local model = dress(describe(skin, false))
	if not model then
		-- One of the items probably failed to load: try again with just skin and face.
		model = dress(describe(skin, true))
	end
	if not model then
		warn(`[AvatarService] couldn't build an avatar for lead {id}`)
		return
	end
	if removed[id] then
		removed[id] = nil
		model:Destroy()
		return
	end
	prepare(model, id)
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
	local existing = output:FindFirstChild(tostring(id))
	if existing then
		existing:Destroy()
	else
		removed[id] = true
	end
end

function AvatarService.Start()
	output = Instance.new("Folder")
	output.Name = "LeadAvatars"
	output.Parent = ReplicatedStorage
	workspaceFolder = Instance.new("Folder")
	workspaceFolder.Name = "LeadAvatarWork"
	workspaceFolder.Parent = workspace

	if SETTINGS.SearchCatalog then
		task.spawn(function()
			topUp(pools.Hair, "HairAccessory")
			topUp(pools.Hats, "Hat")
			topUp(pools.FaceAccessories, "FaceAccessory")
			topUp(pools.Shirts, "Shirt")
			topUp(pools.Pants, "Pants")
		end)
	end
end

return AvatarService
