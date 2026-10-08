--[[
	LeadAvatar (client)
	Shows a lead's avatar in a ViewportFrame, framed on the head and shoulders like a profile picture, with
	Roblox's default idle animation playing so the caller looks alive.

	The server dresses a rig for every lead (AvatarService) and puts it in ReplicatedStorage.LeadAvatars/<id>.
	Until it shows up, the plain R15 rig (ReplicatedStorage.LeadAvatarBase) is shown in the lead's skin tone,
	and the dressed rig is swapped in as soon as it arrives, however long that takes.

	The picture is a WorldModel named "Avatar" holding the rig (named "Rig"); its "Loaded" attribute is true
	once it's the dressed avatar.

	LeadAvatar.render(viewport, lead)     lead = { Id, Look = { Skin, ... } }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IDLE_ANIMATION = "rbxassetid://507766666" -- Roblox's default R15 idle
local ANIMATE = true
local HEAD_HEIGHT = 1.2 -- a classic head; bigger heads (Rthro) get the camera pulled back

local LeadAvatar = {}

local watchers: { [ViewportFrame]: RBXScriptConnection } = {}
local random = Random.new()

local function stopWatching(viewport: ViewportFrame)
	local connection = watchers[viewport]
	if connection then
		connection:Disconnect()
		watchers[viewport] = nil
	end
end

local function clear(viewport: ViewportFrame)
	for _, child in viewport:GetChildren() do
		if child.Name == "Avatar" or child.Name == "AvatarCamera" then
			child:Destroy()
		end
	end
end

local function useCamera(viewport: ViewportFrame, from: Vector3, at: Vector3, fov: number)
	local camera = Instance.new("Camera")
	camera.Name = "AvatarCamera"
	camera.FieldOfView = fov
	camera.CFrame = CFrame.lookAt(from, at)
	camera.Parent = viewport
	viewport.CurrentCamera = camera
end

local function tint(model: Model, skin: Color3)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" and not part:FindFirstAncestorOfClass("Accessory") then
			part.Color = skin
		end
	end
end

-- Plays the idle animation. Parts are unanchored (except the root) so the joints can move; a WorldModel
-- in a ViewportFrame doesn't simulate physics, so nothing falls.
local function animate(model: Model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not root then
		return
	end
	pcall(function()
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				part.Anchored = part == root
			end
		end
		local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator")
		animator.Parent = humanoid
		local animation = Instance.new("Animation")
		animation.AnimationId = IDLE_ANIMATION
		local track = (animator :: Animator):LoadAnimation(animation)
		track.Looped = true
		track:Play(0)
		track.TimePosition = random:NextNumber(0, 2) -- callers side by side don't breathe in sync
	end)
end

-- Puts a copy of `source` in the viewport. False if it has no head to frame.
local function show(viewport: ViewportFrame, source: Model, skin: Color3?, loaded: boolean): boolean
	local model = source:Clone()
	model.Name = "Rig"
	local head = model:FindFirstChild("Head") :: BasePart?
	if not head then
		model:Destroy()
		return false
	end
	if skin then
		pcall(tint, model, skin)
	end
	local world = Instance.new("WorldModel")
	world.Name = "Avatar"
	world:SetAttribute("Loaded", loaded)
	model.Parent = world
	world.Parent = viewport

	local root = (model:FindFirstChild("HumanoidRootPart") or head) :: BasePart
	local forward = root.CFrame.LookVector
	local target = head.Position - Vector3.new(0, 0.15, 0)
	local headHeight = (head.Size :: any).Y
	local distance = 4.4 * math.max((if type(headHeight) == "number" then headHeight else HEAD_HEIGHT) / HEAD_HEIGHT, 1)
	useCamera(viewport, target + forward * distance + Vector3.new(0, 0.3, 0), target, 36)
	if ANIMATE then
		animate(model)
	end
	return true
end

local function showPlaceholder(viewport: ViewportFrame, lead: any)
	local base = ReplicatedStorage:FindFirstChild("LeadAvatarBase")
	if base and base:IsA("Model") then
		show(viewport, base, lead.Look and lead.Look.Skin, false)
	end
end

function LeadAvatar.render(viewport: ViewportFrame, lead: any)
	stopWatching(viewport)
	clear(viewport)
	if not lead then
		viewport:SetAttribute("LeadId", 0)
		return
	end
	viewport:SetAttribute("LeadId", lead.Id)

	local folder = ReplicatedStorage:FindFirstChild("LeadAvatars")
	local source = folder and folder:FindFirstChild(tostring(lead.Id))
	if source and show(viewport, source :: Model, nil, true) then
		return
	end
	showPlaceholder(viewport, lead)

	-- Swap in the dressed rig when the server finishes it (until this picture shows someone else).
	local wanted = tostring(lead.Id)
	local function arrived(dressed: Instance)
		if dressed.Name ~= wanted or viewport:GetAttribute("LeadId") ~= lead.Id then
			return
		end
		stopWatching(viewport)
		clear(viewport)
		if not show(viewport, dressed :: Model, nil, true) then
			showPlaceholder(viewport, lead)
		end
	end
	task.spawn(function()
		local avatars = folder or ReplicatedStorage:WaitForChild("LeadAvatars")
		if viewport:GetAttribute("LeadId") ~= lead.Id then
			return
		end
		watchers[viewport] = avatars.ChildAdded:Connect(arrived)
		local already = avatars:FindFirstChild(wanted)
		if already then
			arrived(already)
		end
	end)
end

return LeadAvatar
