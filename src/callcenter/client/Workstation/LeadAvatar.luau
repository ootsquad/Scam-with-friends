--[[
	LeadAvatar (client)
	Shows a lead's avatar in a ViewportFrame, framed on the head and shoulders like a profile picture.

	The server dresses a rig for every lead (AvatarService) and puts it in ReplicatedStorage.LeadAvatars/<id>.
	Until it shows up (or if dressing failed) a simple blocky stand-in is drawn from the lead's colors.

	LeadAvatar.render(viewport, lead)     lead = { Id, Look = { Skin, Shirt, Pants, Hat, HatColor } }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WAIT_FOR_AVATAR = 20 -- seconds
local FACE = "rbxasset://textures/face.png"

local LeadAvatar = {}

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

-- ---------------------------------------------------------------------------
-- Blocky stand-in
-- ---------------------------------------------------------------------------

local function part(model: Model, name: string, size: Vector3, position: Vector3, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = CFrame.new(position)
	p.Color = color
	p.Anchored = true
	p.CanCollide = false
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

local function addHat(model: Model, style: number, color: Color3)
	if style == 1 then -- cap
		part(model, "Crown", Vector3.new(1.26, 0.32, 1.26), Vector3.new(0, 5.36, 0), color)
		part(model, "Brim", Vector3.new(1.26, 0.08, 0.55), Vector3.new(0, 5.24, -0.86), color)
	elseif style == 2 then -- beanie
		part(model, "Beanie", Vector3.new(1.3, 0.55, 1.3), Vector3.new(0, 5.27, 0), color)
	elseif style == 3 then -- top hat
		part(model, "Brim", Vector3.new(1.7, 0.08, 1.7), Vector3.new(0, 5.24, 0), color)
		part(model, "Crown", Vector3.new(1.0, 0.9, 1.0), Vector3.new(0, 5.73, 0), color)
	elseif style == 4 then -- hair
		part(model, "HairTop", Vector3.new(1.3, 0.28, 1.3), Vector3.new(0, 5.3, 0.02), color)
		part(model, "HairBack", Vector3.new(1.3, 0.9, 0.22), Vector3.new(0, 4.85, 0.6), color)
	end
end

local function drawStandIn(viewport: ViewportFrame, look: any)
	local model = Instance.new("Model")
	model.Name = "Avatar"
	local head = part(model, "Head", Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 4.6, 0), look.Skin)
	local face = Instance.new("Decal")
	face.Name = "Face"
	face.Texture = FACE
	face.Face = Enum.NormalId.Front
	face.Parent = head
	part(model, "Torso", Vector3.new(2, 2, 1), Vector3.new(0, 3, 0), look.Shirt)
	part(model, "LeftArm", Vector3.new(1, 2, 1), Vector3.new(-1.5, 3, 0), look.Skin)
	part(model, "RightArm", Vector3.new(1, 2, 1), Vector3.new(1.5, 3, 0), look.Skin)
	addHat(model, look.Hat, look.HatColor)
	model.Parent = viewport
	useCamera(viewport, Vector3.new(0, 4.45, -5.4), Vector3.new(0, 4.1, 0), 34)
end

-- ---------------------------------------------------------------------------
-- Dressed rig
-- ---------------------------------------------------------------------------

local function drawRig(viewport: ViewportFrame, source: Model): boolean
	local model = source:Clone()
	model.Name = "Avatar"
	local head = model:FindFirstChild("Head") :: BasePart?
	if not head then
		model:Destroy()
		return false
	end
	local root = (model:FindFirstChild("HumanoidRootPart") or head) :: BasePart
	local forward = root.CFrame.LookVector
	local target = head.Position - Vector3.new(0, 0.15, 0)
	model.Parent = viewport
	useCamera(viewport, target + forward * 4.4 + Vector3.new(0, 0.3, 0), target, 36)
	return true
end

function LeadAvatar.render(viewport: ViewportFrame, lead: any)
	clear(viewport)
	if not lead then
		viewport:SetAttribute("LeadId", 0)
		return
	end
	viewport:SetAttribute("LeadId", lead.Id)

	local folder = ReplicatedStorage:FindFirstChild("LeadAvatars")
	local source = folder and folder:FindFirstChild(tostring(lead.Id))
	if source and drawRig(viewport, source :: Model) then
		return
	end
	if lead.Look then
		drawStandIn(viewport, lead.Look)
	end

	-- Swap in the dressed rig when the server finishes it.
	task.spawn(function()
		local avatars = folder or ReplicatedStorage:WaitForChild("LeadAvatars", WAIT_FOR_AVATAR)
		local arrived = avatars and avatars:WaitForChild(tostring(lead.Id), WAIT_FOR_AVATAR)
		if arrived and viewport.Parent and viewport:GetAttribute("LeadId") == lead.Id then
			clear(viewport)
			if not drawRig(viewport, arrived :: Model) and lead.Look then
				drawStandIn(viewport, lead.Look)
			end
		end
	end)
end

return LeadAvatar
