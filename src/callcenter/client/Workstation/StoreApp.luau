--[[
	StoreApp (client, Call Center Place)
	The equipment store. It isn't an app on the computer: it's a room in the office with a vendor (tagged
	"StoreVendor"). Using the vendor's Shop prompt opens this screen (ShiftHud.Root.Store): headsets, computers
	and routers bought with career cash. Each column lists the tiers of one kind of gear; you always use the
	best one you own, and better gear unlocks once you've reached higher office floors.

	Each tier row's button shows its state: EQUIPPED (best you own), OWNED, a price (next one you can buy),
	or FLOOR n (not unlocked yet).

	It closes with the X, Esc (or the gamepad's B), sitting down at a desk, or walking away from the vendor.
	While it's open the mouse stays free (shift lock and first person can't grab it).

	StoreApp.Start(screen)      ShiftHud.Root.Store
	StoreApp.Open() / StoreApp.Close() / StoreApp.IsOpen() -> boolean
]]

local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OfficeConfig = require(Shared.Config.OfficeConfig)
local Format = require(Shared.Util.Format)

local Client = script.Parent.Parent
local Ui = Client:WaitForChild("Ui")
local ButtonFx = require(Ui.ButtonFx)
local Theme = require(Ui.Theme)
local CareerStore = require(script.Parent.CareerStore)
local Ledger = require(script.Parent.Ledger)
local Sfx = require(script.Parent.Sfx)

local BIND_NAME = "ChaosStoreMouse"
local CLOSE_MARGIN = 1 -- studs past OfficeConfig.ShopRange before walking away closes the store (the server
-- allows a little more, so the store always closes before buying stops working)

local player = Players.LocalPlayer

local StoreApp = {}

local screen: Frame
local body: any
local busy = false
local open = false
local openToken = 0

local function paint(button: TextButton, text: string, background: Color3, color: Color3, active: boolean)
	button.Text = text
	button.BackgroundColor3 = background
	button.TextColor3 = color
	button.AutoButtonColor = active
	button.Active = active
end

local function render()
	local data = CareerStore.Data
	local cash = if data then data.Cash else 0
	local best = if data then data.BestFloor else 1
	body.Cash.Value.Text = Format.money(cash)
	body.Note.Text = if data and not data.Persistent
		then "Purchases aren't saved in Studio test sessions. Walk away or press Esc to close."
		else "Everything you earn on shifts goes to your career cash. Walk away or press Esc to close."

	for _, kind in OfficeConfig.EquipmentOrder do
		local column = body:FindFirstChild(kind)
		local category = OfficeConfig.Equipment[kind]
		if column then
			column.Title.Text = string.upper(category.Label)
			column.Effect.Text = `Better {string.lower(category.Label)}: {category.Effect}.`
			local owned = CareerStore.Owned(kind)
			for tierIndex, tier in category.Tiers do
				local row = column:FindFirstChild(`Tier{tierIndex}`)
				if row then
					row.ItemName.Text = tier.Name
					row.Blurb.Text = tier.Blurb
					local button = row.BuyButton
					if tierIndex == owned then
						paint(button, "EQUIPPED", Theme.Green, Theme.White, false)
					elseif tierIndex < owned then
						paint(button, "OWNED", Theme.NativeLine, Theme.NativeMuted, false)
					elseif best < tier.Floor then
						paint(button, `FLOOR {tier.Floor}`, Theme.NativeLine, Theme.NativeMuted, true)
					elseif tierIndex == owned + 1 then
						local affordable = cash >= tier.Price
						paint(button, Format.money(tier.Price), if affordable then Theme.Accent else Theme.NativeLine,
							if affordable then Theme.White else Theme.NativeMuted, true)
					else
						paint(button, Format.money(tier.Price), Theme.NativeLine, Theme.NativeMuted, true)
					end
					row.BackgroundColor3 = if tierIndex == owned then Theme.StoreOwned else Theme.NativePanel
				end
			end
		end
	end
end

local function buy(kindIndex: number, tierIndex: number)
	if busy then
		return
	end
	local kind = OfficeConfig.EquipmentOrder[kindIndex]
	local tier = OfficeConfig.Equipment[kind].Tiers[tierIndex]
	local owned = CareerStore.Owned(kind)
	if tierIndex <= owned then
		return
	end
	busy = true
	Ledger.setStatus(body.Status, `Buying the {tier.Name}…`)
	local result = CareerStore.Buy(kindIndex, tierIndex)
	busy = false
	Ledger.setStatus(body.Status, result.Message, result.Ok)
	if result.Ok then
		Sfx.Play("Payout")
	else
		Sfx.Play("Error")
	end
end

-- ---------------------------------------------------------------------------
-- Opening and closing
-- ---------------------------------------------------------------------------

local function vendorPart(vendor: Instance): BasePart?
	if vendor:IsA("BasePart") then
		return vendor
	elseif vendor:IsA("Model") then
		local root = (vendor :: Model).PrimaryPart
			or vendor:FindFirstChild("HumanoidRootPart")
			or vendor:FindFirstChild("Head")
			or vendor:FindFirstChildWhichIsA("BasePart", true)
		if root and root:IsA("BasePart") then
			return root
		end
	end
	return nil
end

-- Studs to the nearest vendor (nil without a character or vendors).
local function vendorDistance(): number?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local best: number? = nil
	for _, vendor in CollectionService:GetTagged(OfficeConfig.VendorTag) do
		local part = vendorPart(vendor)
		if part and part:IsDescendantOf(workspace) then
			local distance = (part.Position - root.Position).Magnitude
			if not best or distance < best then
				best = distance
			end
		end
	end
	return best
end

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
end

function StoreApp.IsOpen(): boolean
	return open
end

function StoreApp.Close()
	if not open then
		return
	end
	open = false
	openToken += 1
	screen.Visible = false
	pcall(function()
		RunService:UnbindFromRenderStep(BIND_NAME)
	end)
end

function StoreApp.Open()
	if atDesk() then
		return
	end
	Ledger.setStatus(body.Status, "")
	render()
	if open then
		return
	end
	open = true
	openToken += 1
	local token = openToken
	screen.Visible = true
	Sfx.Play("Click")
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, keepMouseFree)
	-- Walking away (or sitting down, or dying) closes it.
	task.spawn(function()
		while open and openToken == token do
			local distance = vendorDistance()
			if atDesk() or not distance or distance > OfficeConfig.ShopRange + CLOSE_MARGIN then
				StoreApp.Close()
				return
			end
			task.wait(0.25)
		end
	end)
end

function StoreApp.Start(storeScreen: Frame)
	screen = storeScreen
	screen.Visible = false
	body = screen:WaitForChild("Panel"):WaitForChild("Body")
	local close = screen.Panel:FindFirstChild("CloseButton")
	if close then
		ButtonFx.attach(close, 1.06, 0.94)
		close.MouseButton1Click:Connect(StoreApp.Close)
	end
	UserInputService.InputBegan:Connect(function(input: InputObject)
		if open and (input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB) then
			StoreApp.Close()
		end
	end)
	pcall(function()
		GuiService.MenuOpened:Connect(StoreApp.Close)
	end)
	player:GetAttributeChangedSignal("Desk"):Connect(function()
		if atDesk() then
			StoreApp.Close()
		end
	end)
	CareerStore.OpenStore:Connect(StoreApp.Open)
	Ledger.setStatus(body.Status, "")
	for kindIndex, kind in OfficeConfig.EquipmentOrder do
		local column = body:FindFirstChild(kind)
		if column then
			for tierIndex in OfficeConfig.Equipment[kind].Tiers do
				local row = column:FindFirstChild(`Tier{tierIndex}`)
				if row then
					ButtonFx.attach(row.BuyButton, 1.04, 0.95)
					row.BuyButton.MouseButton1Click:Connect(function()
						buy(kindIndex, tierIndex)
					end)
				end
			end
		else
			warn(`[StoreApp] the store screen has no {kind} column`)
		end
	end
	CareerStore.Changed:Connect(render)
	render()
end

return StoreApp
