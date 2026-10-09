--[[
	VendorService (server, Call Center Place)
	The equipment store is a room in the office with a vendor you walk up to. Anything tagged "StoreVendor"
	(OfficeConfig.VendorTag: a Model with a Humanoid, or any Part such as a counter) gets a "Shop" prompt that
	opens the store on that player's screen. Vendors on another floor than the crew's are switched off;
	vendors outside the floors (a store room in the lobby, say) always work. Buying only works within
	OfficeConfig.ShopRange studs of a working vendor.

	Until the office has a working vendor, a stand-in counter shows up next to where the crew arrives so the
	store can still be used. It disappears as soon as a real vendor is tagged.

	VendorService.Start()
	VendorService.InRange(player) -> boolean
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OfficeConfig = require(Shared.Config.OfficeConfig)
local Career = require(Shared:WaitForChild("Network")).Career
local CareerService = require(script.Parent.CareerService)
local OfficeService = require(script.Parent.OfficeService)

local PROMPT_NAME = "ShopPrompt"
local STAND_IN_NAME = "EquipmentStore (stand-in)"
local STAND_IN_OFFSET = CFrame.new(10, 0, -4) -- from the arrival point
local COUNTER_SIZE = Vector3.new(7, 3.5, 2.5)
local LAG_MARGIN = 4 -- extra studs allowed when buying (the player's position on the server lags a little)

local VendorService = {}

local standIn: Model? = nil
local refreshQueued = false
local warnedNoSpot = false

-- The part the prompt hangs on (and distances are measured from).
local function partOf(vendor: Instance): BasePart?
	if vendor:IsA("BasePart") then
		return vendor
	elseif vendor:IsA("Model") then
		local model = vendor :: Model
		local root = model.PrimaryPart
			or model:FindFirstChild("HumanoidRootPart")
			or model:FindFirstChild("Head")
			or model:FindFirstChildWhichIsA("BasePart", true)
		if root and root:IsA("BasePart") then
			return root
		end
	end
	return nil
end

local function isWorking(vendor: Instance): boolean
	return vendor:IsDescendantOf(workspace) and OfficeService.IsActive(vendor)
end

local function atDesk(player: Player): boolean
	local desk = player:GetAttribute("Desk")
	return type(desk) == "string" and desk ~= ""
end

function VendorService.InRange(player: Player): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	for _, vendor in CollectionService:GetTagged(OfficeConfig.VendorTag) do
		local part = partOf(vendor)
		if
			part
			and isWorking(vendor)
			and (part.Position - root.Position).Magnitude <= OfficeConfig.ShopRange + LAG_MARGIN
		then
			return true
		end
	end
	return false
end

local function onShop(player: Player, vendor: Instance)
	if not isWorking(vendor) or atDesk(player) or not CareerService.IsReady(player) then
		return
	end
	Career.packets.OpenStore.sendTo(nil, player)
end

local function attach(vendor: Instance)
	local part = partOf(vendor)
	if not part then
		warn(`[VendorService] {vendor:GetFullName()} is tagged "{OfficeConfig.VendorTag}" but has no part to stand at`)
		return
	end
	if part:FindFirstChild(PROMPT_NAME) then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = PROMPT_NAME
	prompt.ActionText = "Shop"
	prompt.ObjectText = "Equipment Store"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Enabled = isWorking(vendor)
	prompt.Triggered:Connect(function(player)
		onShop(player, vendor)
	end)
	prompt.Parent = part
end

-- Where the stand-in counter goes: next to the arrival point, standing on the floor, facing the crew.
local function standInSpot(): CFrame?
	local arrival = OfficeService.ArrivalPoint()
	if not arrival then
		return nil
	end
	local above = (arrival * STAND_IN_OFFSET).Position
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = {}
	if standIn then
		table.insert(exclude, standIn)
	end
	params.FilterDescendantsInstances = exclude
	local hit = workspace:Raycast(above + Vector3.new(0, 2, 0), Vector3.new(0, -25, 0), params)
	local groundY = if hit then hit.Position.Y else arrival.Position.Y - 3
	local position = Vector3.new(above.X, groundY + COUNTER_SIZE.Y / 2, above.Z)
	local facing = Vector3.new(arrival.Position.X, position.Y, arrival.Position.Z)
	if (facing - position).Magnitude < 0.1 then
		return CFrame.new(position)
	end
	return CFrame.lookAt(position, facing)
end

local function makeStandIn(spot: CFrame): Model
	local model = Instance.new("Model")
	model.Name = STAND_IN_NAME
	model:SetAttribute("StandIn", true)

	local counter = Instance.new("Part")
	counter.Name = "Counter"
	counter.Anchored = true
	counter.Size = COUNTER_SIZE
	counter.Material = Enum.Material.WoodPlanks
	counter.Color = Color3.fromRGB(150, 105, 70)
	counter.CFrame = spot
	counter.Parent = model

	local top = Instance.new("Part")
	top.Name = "Top"
	top.Anchored = true
	top.CanCollide = false
	top.Size = Vector3.new(COUNTER_SIZE.X + 0.4, 0.3, COUNTER_SIZE.Z + 0.4)
	top.Material = Enum.Material.SmoothPlastic
	top.Color = Color3.fromRGB(40, 44, 52)
	top.CFrame = spot * CFrame.new(0, COUNTER_SIZE.Y / 2 + 0.15, 0)
	top.Parent = model

	local sign = Instance.new("BillboardGui")
	sign.Name = "Sign"
	sign.Size = UDim2.fromOffset(220, 60)
	sign.StudsOffset = Vector3.new(0, 4, 0)
	sign.MaxDistance = 80
	sign.Parent = counter
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0.6, 0)
	title.BackgroundColor3 = Color3.fromRGB(31, 111, 235)
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.Text = "EQUIPMENT STORE"
	title.Parent = sign
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = title
	local note = Instance.new("TextLabel")
	note.Name = "Note"
	note.Position = UDim2.fromScale(0, 0.62)
	note.Size = UDim2.new(1, 0, 0.38, 0)
	note.BackgroundTransparency = 1
	note.TextColor3 = Color3.new(1, 1, 1)
	note.TextStrokeTransparency = 0.4
	note.Font = Enum.Font.GothamMedium
	note.TextScaled = true
	note.Text = "Headsets · Computers · Routers"
	note.Parent = sign

	model.PrimaryPart = counter
	model.Parent = workspace
	CollectionService:AddTag(model, OfficeConfig.VendorTag)
	return model
end

local function refresh()
	refreshQueued = false
	local realOne = false
	for _, vendor in CollectionService:GetTagged(OfficeConfig.VendorTag) do
		local working = isWorking(vendor)
		local part = partOf(vendor)
		local prompt = part and part:FindFirstChild(PROMPT_NAME)
		if prompt and prompt:IsA("ProximityPrompt") then
			prompt.Enabled = working
		end
		if working and vendor ~= standIn then
			realOne = true
		end
	end

	if realOne then
		if standIn then
			standIn:Destroy()
			standIn = nil
		end
		return
	end
	local spot = standInSpot()
	if not spot then
		if not warnedNoSpot then
			warnedNoSpot = true
			warn(`[VendorService] no "{OfficeConfig.VendorTag}" vendor and nowhere to put a stand-in; the store can't be used`)
		end
		return
	end
	if standIn and standIn.Parent then
		standIn:PivotTo(spot)
	else
		standIn = makeStandIn(spot)
		print(`[VendorService] no "{OfficeConfig.VendorTag}" vendor on this floor yet; put a stand-in store counter by the spawn`)
	end
end

local function queueRefresh()
	if not refreshQueued then
		refreshQueued = true
		task.defer(refresh)
	end
end

function VendorService.Start()
	CareerService.SetShopCheck(VendorService.InRange)
	CollectionService:GetInstanceAddedSignal(OfficeConfig.VendorTag):Connect(function(vendor)
		attach(vendor)
		queueRefresh()
	end)
	CollectionService:GetInstanceRemovedSignal(OfficeConfig.VendorTag):Connect(queueRefresh)
	CollectionService:GetInstanceAddedSignal(OfficeConfig.FloorTag):Connect(queueRefresh)
	CollectionService:GetInstanceRemovedSignal(OfficeConfig.FloorTag):Connect(queueRefresh)
	OfficeService.OnFloorChanged(function()
		queueRefresh()
	end)
	for _, vendor in CollectionService:GetTagged(OfficeConfig.VendorTag) do
		attach(vendor)
	end
	-- Let the place finish loading (and the crew's floor settle) before deciding on a stand-in.
	task.delay(1, refresh)
end

return VendorService
