--[[
	TechStoreApp (client, Call Center Place)
	The Tech Store: a room with a dealer and three shelves (routers, headsets, PC upgrades). Talking to the
	dealer (its "Talk" prompt, Career OpenTechStore) freezes you where you stand and flies the camera around the
	room instead of opening a window:

	  StoreOverview  -> the dealer's welcome and three shelf buttons (ROUTERS, HEADSETS, PC UPGRADES)
	  shelf overview -> the shelf's items; click one (or hover for its name)
	  item camera    -> a small card: the item, its effect, and one button (price / EQUIPPED / OWNED / FLOOR n)

	Cameras and item markers are Parts under workspace.TechStore (OfficeConfig.TechStore). The items on the
	shelves are yours: each marker Part (and anything inside it) gets a ClickDetector, nothing is added to the
	room. The dealer is hidden from you while the store is open so it never blocks a shot; its lines show on
	screen. Buying goes through CareerStore.Buy (the same rules as ever). The camera drifts a little toward the
	mouse so each shot feels alive.

	BACK goes up one step; LEAVE, Esc or the gamepad's B puts the camera back and unfreezes you.

	TechStoreApp.Start(gui)                ScreenGui "TechStore"
	TechStoreApp.Open() / Close() / IsOpen()
	TechStoreApp.Shelf(kind) / TechStoreApp.Select(kind, tier) / TechStoreApp.Back()   (what the clicks do)
]]

local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OfficeConfig = require(Shared.Config.OfficeConfig)
local Format = require(Shared.Util.Format)

local Client = script.Parent.Parent
local Ui = Client:WaitForChild("Ui")
local ButtonFx = require(Ui.ButtonFx)
local Theme = require(Ui.Theme)
local CareerStore = require(script.Parent.CareerStore)
local Sfx = require(script.Parent.Sfx)

local Config = OfficeConfig.TechStore
local BIND_NAME = "ChaosTechStoreCamera"
local LEFTOVERS = { "StandIn", "StoreTag" } -- things an older version of this script put in the slots
local BUBBLE_TIME = 4 -- seconds a dealer reaction stays up before the welcome comes back
local KINDS = OfficeConfig.EquipmentOrder -- the shelves in button order: Headset, Computer, Router

local player = Players.LocalPlayer

local TechStoreApp = {}

local gui: ScreenGui
local root: any
local open = false
local busy = false
local depth = 0 -- 0 overview, 1 shelf, 2 item
local shelfKind: string? = nil
local selected: number? = nil
local baseCFrame: CFrame? = nil
local returnCFrame: CFrame? = nil
local returnType: Enum.CameraType? = nil
local frozen: { walk: number, jump: number, humanoid: Humanoid }? = nil
local bubbleToken = 0
local hiddenDealer: { parts: { [BasePart]: number }, decals: { [Decal]: number }, guis: { BillboardGui } }? = nil
local highlights: { [BasePart]: Highlight } = {}
local hovered: { kind: string, tier: number }? = nil
local warned: { [string]: boolean } = {}

-- ---------------------------------------------------------------------------
-- The room
-- ---------------------------------------------------------------------------

local function folder(): Instance?
	return workspace:FindFirstChild(Config.Folder)
end

local function missing(what: string)
	if not warned[what] then
		warned[what] = true
		warn(`[TechStore] workspace.{Config.Folder} has no {what}; check the names in OfficeConfig.TechStore`)
	end
end

-- A Part under TechStore.Cameras or TechStore.Items by its "Sub/Name" path.
local function find(group: string, path: string): BasePart?
	local room = folder()
	local node: Instance? = room and room:FindFirstChild(group)
	for piece in string.gmatch(path, "[^/]+") do
		node = node and node:FindFirstChild(piece)
	end
	if node and node:IsA("BasePart") then
		return node
	end
	missing(`{group}/{path}`)
	return nil
end

local function cameraAt(path: string): CFrame?
	local part = find("Cameras", path)
	return if part then part.CFrame else nil
end

local function slotPart(kind: string, tier: number): BasePart?
	local shelf = Config.Shelves[kind]
	local slot = shelf and shelf.Slots[tier]
	return if slot then find("Items", slot.Item) else nil
end

local function tierOf(kind: string, tier: number)
	return OfficeConfig.Equipment[kind].Tiers[tier]
end

local function kindIndex(kind: string): number
	return table.find(KINDS, kind) or 1
end

-- Clicks and hovers on the marker Part itself and everything inside it.
local function wireSlot(kind: string, tier: number)
	local part = slotPart(kind, tier)
	if not part then
		return
	end
	for _, name in LEFTOVERS do
		local leftover = part:FindFirstChild(name)
		if leftover then
			leftover:Destroy()
		end
	end
	local parts = { part }
	for _, thing in part:GetDescendants() do
		if thing:IsA("BasePart") then
			table.insert(parts, thing)
		end
	end
	for _, thing in parts do
		if thing:FindFirstChildOfClass("ClickDetector") then
			continue
		end
		local click = Instance.new("ClickDetector")
		click.MaxActivationDistance = 1000
		click.Parent = thing
		click.MouseHoverEnter:Connect(function()
			if open and depth == 1 and shelfKind == kind then
				hovered = { kind = kind, tier = tier }
				local info = tierOf(kind, tier)
				root.Hover.Text = if info then info.Name else ""
				root.Hover.Visible = true
				local outline = highlights[thing]
				if not outline then
					outline = Instance.new("Highlight")
					outline.FillTransparency = 1
					outline.OutlineColor = Theme.White
					outline.OutlineTransparency = 0.1
					outline.Enabled = false
					outline.Parent = thing
					highlights[thing] = outline
				end
				outline.Enabled = true
			end
		end)
		click.MouseHoverLeave:Connect(function()
			if hovered and hovered.kind == kind and hovered.tier == tier then
				hovered = nil
				root.Hover.Visible = false
			end
			local outline = highlights[thing]
			if outline then
				outline.Enabled = false
			end
		end)
		click.MouseClick:Connect(function()
			if not open then
				return
			end
			if depth == 0 then
				TechStoreApp.Shelf(kind) -- clicking a shelf on the overview opens it
			elseif depth == 1 and shelfKind == kind then
				TechStoreApp.Select(kind, tier)
			end
		end)
	end
end

local function dressRoom()
	local room = folder()
	if not room then
		missing("folder")
		return
	end
	local cameras = room:FindFirstChild("Cameras")
	if cameras then
		for _, part in cameras:GetDescendants() do
			if part:IsA("BasePart") then
				part.Transparency = 1
				part.CanCollide = false
				part.CanQuery = false
			end
		end
	end
	for kind, shelf in Config.Shelves do
		for tier in shelf.Slots do
			wireSlot(kind, tier)
		end
	end
end

-- ---------------------------------------------------------------------------
-- The dealer
-- ---------------------------------------------------------------------------

local function dealers(): { Instance }
	local found = {}
	for _, dealer in CollectionService:GetTagged(Config.DealerTag) do
		if dealer:IsDescendantOf(workspace) then
			table.insert(found, dealer)
		end
	end
	return found
end

-- Only you stop seeing the dealer (LocalTransparencyModifier); everyone else still sees it standing there.
local function hideDealer()
	if hiddenDealer then
		return
	end
	local hidden = { parts = {}, decals = {}, guis = {} }
	for _, dealer in dealers() do
		local things = dealer:GetDescendants()
		table.insert(things, dealer)
		for _, thing in things do
			if thing:IsA("BasePart") then
				hidden.parts[thing] = thing.LocalTransparencyModifier
				thing.LocalTransparencyModifier = 1
			elseif thing:IsA("Decal") then
				hidden.decals[thing] = thing.Transparency
				thing.Transparency = 1
			elseif thing:IsA("BillboardGui") and thing.Enabled then
				thing.Enabled = false
				table.insert(hidden.guis, thing)
			end
		end
	end
	hiddenDealer = hidden
end

local function showDealer()
	local hidden = hiddenDealer
	if not hidden then
		return
	end
	hiddenDealer = nil
	for part, before in hidden.parts do
		part.LocalTransparencyModifier = before
	end
	for decal, before in hidden.decals do
		decal.Transparency = before
	end
	for _, billboard in hidden.guis do
		billboard.Enabled = true
	end
end

local WELCOME = "Welcome to the Tech Store! What are you after?"

-- The dealer's line, shown at the top of the screen (the dealer itself is hidden while you shop).
local function say(text: string, holdFor: number?)
	root.Dealer.Text = text
	bubbleToken += 1
	if holdFor then
		local token = bubbleToken
		task.delay(holdFor, function()
			if open and token == bubbleToken then
				say(WELCOME)
			end
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Camera
-- ---------------------------------------------------------------------------

local function camera(): Camera?
	return workspace.CurrentCamera
end

local function drift()
	local cam = camera()
	if not cam or not baseCFrame then
		return
	end
	local dx, dy = 0, 0
	if UserInputService.MouseEnabled and not UserInputService.TouchEnabled then
		local position = UserInputService:GetMouseLocation()
		local size = cam.ViewportSize
		if size.X > 0 and size.Y > 0 then
			dx = math.clamp(position.X / size.X * 2 - 1, -1, 1)
			dy = math.clamp(position.Y / size.Y * 2 - 1, -1, 1)
		end
	elseif UserInputService.GamepadEnabled then
		for _, input in UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1) do
			if input.KeyCode == Enum.KeyCode.Thumbstick2 then
				dx, dy = input.Position.X, -input.Position.Y
			end
		end
	end
	local yaw = -dx * math.rad(Config.DriftYaw)
	local pitch = -dy * math.rad(Config.DriftPitch)
	local target = baseCFrame * CFrame.Angles(pitch, yaw, 0)
	cam.CFrame = cam.CFrame:Lerp(target, 0.12)
end

local function flyTo(cframe: CFrame, fov: number)
	local cam = camera()
	if not cam then
		return
	end
	baseCFrame = nil -- no drift while flying
	cam.CameraType = Enum.CameraType.Scriptable
	local tween = TweenService:Create(cam, TweenInfo.new(Config.FlyTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = cframe, FieldOfView = fov })
	tween.Completed:Once(function()
		if open then
			baseCFrame = cframe
		end
	end)
	tween:Play()
end

local function freeze()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and not frozen then
		frozen = { walk = humanoid.WalkSpeed, jump = humanoid.JumpPower, humanoid = humanoid }
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
	end
end

local function unfreeze()
	if frozen then
		frozen.humanoid.WalkSpeed = frozen.walk
		frozen.humanoid.JumpPower = frozen.jump
		frozen = nil
	end
end

-- ---------------------------------------------------------------------------
-- Screens
-- ---------------------------------------------------------------------------

local function paintCard()
	if not shelfKind or not selected then
		root.Card.Visible = false
		return
	end
	local info = tierOf(shelfKind, selected)
	if not info then
		root.Card.Visible = false
		return
	end
	local data = CareerStore.Data
	local best = if data then data.BestFloor else 1
	local cash = if data then data.Cash else 0
	local owned = CareerStore.Owned(shelfKind)
	local button = root.Card.BuyButton
	root.Card.ItemName.Text = info.Name
	root.Card.Effect.Text = info.Blurb
	local label, colour, textColour, active
	if selected == owned then
		label, colour, textColour, active = "EQUIPPED", Theme.Green, Theme.White, false
	elseif selected < owned then
		label, colour, textColour, active = "OWNED", Theme.NativeLine, Theme.NativeMuted, false
	elseif best < info.Floor then
		label, colour, textColour, active = `FLOOR {info.Floor}`, Theme.NativeLine, Theme.NativeMuted, false
	else
		label = Format.money(info.Price)
		local affordable = cash >= info.Price and selected == owned + 1
		colour = if affordable then Theme.Accent else Theme.NativeLine
		textColour = if affordable then Theme.White else Theme.NativeMuted
		active = true
	end
	button.Text = label
	button.BackgroundColor3 = colour
	button.TextColor3 = textColour
	button.Active = active
	root.Card.Visible = true
end

local function paintButtons()
	root.Shelves.Visible = depth == 0
	root.BackButton.Visible = depth > 0
	root.Hover.Visible = false
	hovered = nil
	for _, outline in highlights do
		outline.Enabled = false
	end
	paintCard()
end

function TechStoreApp.Shelf(kind: string)
	local shelf = Config.Shelves[kind]
	if not open or not shelf then
		return
	end
	shelfKind = kind
	selected = nil
	depth = 1
	Sfx.Play("Click")
	flyTo(cameraAt(shelf.Overview) or cameraAt(Config.Overview) or baseCFrame or CFrame.identity, Config.OverviewFov)
	paintButtons()
end

function TechStoreApp.Select(kind: string, tier: number)
	local shelf = Config.Shelves[kind]
	local slot = shelf and shelf.Slots[tier]
	if not open or not slot or not tierOf(kind, tier) then
		return
	end
	shelfKind = kind
	selected = tier
	depth = 2
	Sfx.Play("Click")
	flyTo(cameraAt(slot.Camera) or cameraAt(shelf.Overview) or baseCFrame or CFrame.identity, Config.ItemFov)
	paintButtons()
end

function TechStoreApp.Back()
	if not open then
		return
	end
	if depth == 2 and shelfKind then
		TechStoreApp.Shelf(shelfKind)
	elseif depth >= 1 then
		depth = 0
		shelfKind = nil
		selected = nil
		Sfx.Play("Click")
		flyTo(cameraAt(Config.Overview) or baseCFrame or CFrame.identity, Config.OverviewFov)
		paintButtons()
	end
end

local function buy()
	if busy or not open or not shelfKind or not selected then
		return
	end
	local kind, tier = shelfKind, selected
	local info = tierOf(kind, tier)
	local owned = CareerStore.Owned(kind)
	if not info or tier <= owned then
		return
	end
	busy = true
	say(`One {info.Name}, coming up...`)
	local result = CareerStore.Buy(kindIndex(kind), tier)
	busy = false
	if result.Ok then
		Sfx.Play("Payout")
		say(`Nice choice! {info.Blurb}.`, BUBBLE_TIME)
	else
		Sfx.Play("Error")
		say(result.Message, BUBBLE_TIME)
	end
	paintCard()
end

-- ---------------------------------------------------------------------------
-- Opening and closing
-- ---------------------------------------------------------------------------

local function atDesk(): boolean
	local desk = player:GetAttribute("Desk")
	return type(desk) == "string" and desk ~= ""
end

local function keepMouseFree()
	if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
	if not UserInputService.MouseIconEnabled then
		UserInputService.MouseIconEnabled = true
	end
	drift()
end

function TechStoreApp.IsOpen(): boolean
	return open
end

function TechStoreApp.Open()
	if open or atDesk() then
		return
	end
	local cam = camera()
	local overview = cameraAt(Config.Overview)
	if not cam or not overview then
		missing(`Cameras/{Config.Overview}`)
		return
	end
	open = true
	depth = 0
	shelfKind = nil
	selected = nil
	dressRoom()
	hideDealer()
	returnCFrame = cam.CFrame
	returnType = cam.CameraType
	freeze()
	local hud = player:FindFirstChild("PlayerGui") and player.PlayerGui:FindFirstChild("ShiftHud")
	if hud then
		hud.Enabled = false
	end
	root.Visible = true
	Sfx.Play("Click")
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, keepMouseFree)
	flyTo(overview, Config.OverviewFov)
	paintButtons()
	say(WELCOME)
end

function TechStoreApp.Close()
	if not open then
		return
	end
	open = false
	bubbleToken += 1
	root.Visible = false
	pcall(function()
		RunService:UnbindFromRenderStep(BIND_NAME)
	end)
	showDealer()
	for _, outline in highlights do
		outline.Enabled = false
	end
	local cam = camera()
	if cam then
		baseCFrame = nil
		local back = returnCFrame or cam.CFrame
		local tween = TweenService:Create(cam, TweenInfo.new(Config.FlyTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = back, FieldOfView = 70 })
		tween.Completed:Once(function()
			if not open then
				cam.CameraType = returnType or Enum.CameraType.Custom
			end
		end)
		tween:Play()
	end
	local hud = player:FindFirstChild("PlayerGui") and player.PlayerGui:FindFirstChild("ShiftHud")
	if hud then
		hud.Enabled = true
	end
	unfreeze()
end

function TechStoreApp.Start(screenGui: ScreenGui)
	gui = screenGui
	root = gui:WaitForChild("Root")
	root.Visible = false

	for _, kind in KINDS do
		local button = root.Shelves:FindFirstChild(kind .. "Button")
		if button then
			ButtonFx.attach(button, 1.04, 0.96)
			button.MouseButton1Click:Connect(function()
				TechStoreApp.Shelf(kind)
			end)
		end
	end
	ButtonFx.attach(root.BackButton, 1.04, 0.96)
	root.BackButton.MouseButton1Click:Connect(TechStoreApp.Back)
	ButtonFx.attach(root.LeaveButton, 1.04, 0.96)
	root.LeaveButton.MouseButton1Click:Connect(TechStoreApp.Close)
	ButtonFx.attach(root.Card.BuyButton, 1.04, 0.96)
	root.Card.BuyButton.MouseButton1Click:Connect(buy)

	UserInputService.InputBegan:Connect(function(input: InputObject)
		if open and (input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB) then
			TechStoreApp.Close()
		end
	end)
	pcall(function()
		GuiService.MenuOpened:Connect(TechStoreApp.Close)
	end)
	player:GetAttributeChangedSignal("Desk"):Connect(function()
		if atDesk() then
			TechStoreApp.Close()
		end
	end)
	player.CharacterRemoving:Connect(function()
		frozen = nil
		TechStoreApp.Close()
	end)
	CareerStore.Changed:Connect(function()
		if open then
			paintCard()
		end
	end)
	CareerStore.OpenTechStore:Connect(TechStoreApp.Open)
end

return TechStoreApp
