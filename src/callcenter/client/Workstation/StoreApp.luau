--[[
	StoreApp (client, Call Center Place)
	The equipment store. It isn't an app on the computer: it's a room in the office with a vendor (tagged
	"StoreVendor"). Using the vendor's Shop prompt opens this screen (ShiftHud.Root.Store): headsets, computers
	and routers bought with career cash. Each column lists the tiers of one kind of gear; you always use the
	best one you own, and better gear unlocks once you've reached higher office floors. Gear lasts one shift.

	Each tier row's button shows its state: EQUIPPED (best you own), OWNED, a price (next one you can buy),
	or FLOOR n (not unlocked yet).

	Two more tabs sell Robux items (ShopConfig): ROBUX ITEMS (developer products, buy as often as you like)
	and GAME PASSES. Prank Call asks who should get the call first.

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
local ShopConfig = require(Shared.Config.ShopConfig)
local Format = require(Shared.Util.Format)

local Client = script.Parent.Parent
local Ui = Client:WaitForChild("Ui")
local ButtonFx = require(Ui.ButtonFx)
local Theme = require(Ui.Theme)
local CareerStore = require(script.Parent.CareerStore)
local Ledger = require(script.Parent.Ledger)
local Sfx = require(script.Parent.Sfx)
local ShopStore = require(script.Parent.ShopStore)

local TABS = { Equipment = "EquipmentTab", Robux = "RobuxTab", Passes = "PassesTab" }
local ROBUX_GREEN = Color3.fromHex("#00A651")

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
		else "Gear lasts until the shift ends. Everything you earn goes to your career cash. Walk away or press Esc to close."

	for _, kind in OfficeConfig.EquipmentOrder do
		local column = body.Equipment:FindFirstChild(kind)
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

-- ---------------------------------------------------------------------------
-- Robux items
-- ---------------------------------------------------------------------------

local function robuxLabel(item: ShopConfig.Item): string
	local price = ShopStore.Price(item)
	return if price then `R$ {price}` else "BUY"
end

local function fillCard(card: any, item: ShopConfig.Item)
	card.ItemName.Text = item.Name
	card.Blurb.Text = item.Blurb
	card.Tile.BackgroundColor3 = Color3.fromHex(item.Color)
end

local function productState(item: ShopConfig.Item): (string, boolean, string?)
	-- (state line, can buy, button text instead of the price)
	if item.ComingSoon then
		return "Coming soon", false, "COMING SOON"
	end
	local key = item.Key
	if key == "DoubleCash" then
		if ShopStore.Owns("CashForever") then
			return "You have Permanent 2x Cash", false, "OWNED"
		end
		local seconds = ShopStore.BoostSeconds()
		return if seconds > 0 then `2x for {Format.duration(seconds)} more` else "", true, nil
	elseif key == "ExtraTips" then
		local tips = ShopStore.TipsLeft()
		return `You have {tips} {if tips == 1 then "tip" else "tips"}`, true, nil
	elseif key == "SaveMyCall" then
		local saves = ShopStore.SavesLeft()
		return if saves > 0 then `{saves} {if saves == 1 then "save" else "saves"} ready` else "", true, nil
	elseif key == "PrankCall" then
		local line = ReplicatedStorage:GetAttribute("PhoneLine")
		if type(line) == "string" and line ~= "ok" then
			return "The phone line is down", false, "UNAVAILABLE"
		end
		local others, atDesks = 0, 0
		for _, other in Players:GetPlayers() do
			if other ~= player then
				others += 1
				if other:GetAttribute("LoggedIn") == true then
					atDesks += 1
				end
			end
		end
		if others > 0 and atDesks == 0 then
			return "Nobody's at a desk right now", false, "WAIT"
		end
	elseif key == "VirusAttack" or key == "OfficeChaos" then
		local endsAt = ReplicatedStorage:GetAttribute("ShiftDayEndsAt") or 0
		local closing = endsAt > 0 and endsAt - workspace:GetServerTimeNow() <= ShopConfig.DisasterCutoff
		if ReplicatedStorage:GetAttribute("ShiftReviewing") or ReplicatedStorage:GetAttribute("ShiftFired") or closing then
			return "Wait for the next day", false, "WAIT"
		end
	end
	return "", true, nil
end

local function paintBuy(button: TextButton, text: string, active: boolean, owned: boolean?)
	if owned then
		paint(button, text, Theme.StoreOwned, Theme.Green, false)
	elseif active then
		paint(button, text, ROBUX_GREEN, Theme.White, true)
	else
		paint(button, text, Theme.NativeLine, Theme.NativeMuted, false)
	end
end

local function renderRobux()
	for _, item in ShopConfig.Products do
		local card = body.Robux:FindFirstChild(`Card_{item.Key}`)
		if card then
			fillCard(card, item)
			local state, canBuy, buttonText = productState(item)
			card.State.Text = state
			card.State.TextColor3 = if canBuy then Theme.Green else Theme.NativeMuted
			paintBuy(card.BuyButton, buttonText or robuxLabel(item), canBuy, buttonText == "OWNED")
		end
	end
	for _, item in ShopConfig.Passes do
		local card = body.Passes:FindFirstChild(`Pass_{item.Key}`)
		if card then
			fillCard(card, item)
			local owned = ShopStore.Owns(item.Key)
			card.State.Text = if owned then "Owned" else ""
			card.State.TextColor3 = Theme.Green
			paintBuy(card.BuyButton, if owned then "OWNED" else robuxLabel(item), not owned, owned)
		end
	end
end

local function selectTab(name: string)
	for page, buttonName in TABS do
		local on = page == name
		body[page].Visible = on
		local button = body.Tabs[buttonName]
		button.BackgroundColor3 = if on then Theme.Accent else Theme.White
		button.TextColor3 = if on then Theme.White else Theme.NativeText
	end
	body.Picker.Visible = false
	Ledger.setStatus(body.Status, "")
	if name ~= "Equipment" then
		renderRobux()
	end
end

-- Prank Call: pick who gets it, then buy.
local function openPicker()
	local picker = body.Picker
	local others, anyone = {}, false
	for _, other in Players:GetPlayers() do
		if other ~= player then
			anyone = true
			if other:GetAttribute("LoggedIn") == true then
				table.insert(others, other) -- prank calls ring at a desk
			end
		end
	end
	local alone = not anyone
	if alone then
		others = { player }
	end
	for index = 1, 4 do
		local option = picker.Card:FindFirstChild(`Option{index}`)
		if option then
			local who = others[index]
			option.Visible = who ~= nil
			if who then
				option.Text = if alone then "Me (no one else is here)" else who.DisplayName
				option:SetAttribute("UserId", who.UserId)
			end
		end
	end
	picker.Visible = true
end

local function pickPrankTarget(index: number)
	local option = body.Picker.Card:FindFirstChild(`Option{index}`)
	local userId = option and option:GetAttribute("UserId")
	body.Picker.Visible = false
	if type(userId) == "number" then
		ShopStore.PrankTarget(userId)
		ShopStore.BuyProduct("PrankCall")
	end
end

local function buyProduct(item: ShopConfig.Item)
	local _, canBuy = productState(item)
	if not canBuy then
		Sfx.Play("Error")
		return
	end
	Sfx.Play("Click")
	if item.Key == "PrankCall" then
		openPicker()
	else
		ShopStore.BuyProduct(item.Key)
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
	renderRobux()
	body.Picker.Visible = false
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
		local ticks = 0
		while open and openToken == token do
			local distance = vendorDistance()
			if atDesk() or not distance or distance > OfficeConfig.ShopRange + CLOSE_MARGIN then
				StoreApp.Close()
				return
			end
			ticks += 1
			if ticks % 4 == 0 then
				renderRobux() -- who's at a desk, the day clock
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
		local column = body.Equipment:FindFirstChild(kind)
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

	-- Tabs and Robux items
	for page, buttonName in TABS do
		local button = body.Tabs:FindFirstChild(buttonName)
		if button then
			ButtonFx.attach(button, 1.03, 0.96)
			button.MouseButton1Click:Connect(function()
				Sfx.Play("Click")
				selectTab(page)
			end)
		end
	end
	for _, item in ShopConfig.Products do
		local card = body.Robux:FindFirstChild(`Card_{item.Key}`)
		if card then
			ButtonFx.attach(card.BuyButton, 1.04, 0.95)
			card.BuyButton.MouseButton1Click:Connect(function()
				buyProduct(item)
			end)
		else
			warn(`[StoreApp] the store screen has no card for {item.Name}`)
		end
	end
	for _, item in ShopConfig.Passes do
		local card = body.Passes:FindFirstChild(`Pass_{item.Key}`)
		if card then
			ButtonFx.attach(card.BuyButton, 1.04, 0.95)
			card.BuyButton.MouseButton1Click:Connect(function()
				if not ShopStore.Owns(item.Key) then
					Sfx.Play("Click")
					ShopStore.BuyPass(item.Key)
				end
			end)
		else
			warn(`[StoreApp] the store screen has no card for {item.Name}`)
		end
	end
	local picker = body.Picker
	for index = 1, 4 do
		local option = picker.Card:FindFirstChild(`Option{index}`)
		if option then
			ButtonFx.attach(option, 1.02, 0.97)
			option.MouseButton1Click:Connect(function()
				pickPrankTarget(index)
			end)
		end
	end
	picker.Card.CancelButton.MouseButton1Click:Connect(function()
		picker.Visible = false
	end)
	ShopStore.Changed:Connect(renderRobux)
	ShopStore.PricesLoaded:Connect(renderRobux)
	ShopStore.Message:Connect(function(message)
		if open then
			Ledger.setStatus(body.Status, message.Text, if message.Kind == 2 then true elseif message.Kind == 3 then false else nil)
		end
	end)
	selectTab("Equipment")
end

return StoreApp
