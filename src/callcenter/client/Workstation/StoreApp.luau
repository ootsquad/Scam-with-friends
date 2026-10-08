--[[
	StoreApp (client, Call Center Place)
	The Equipment Store window: headsets, computers and routers bought with career cash. Each column lists
	the tiers of one kind of gear; you always use the best one you own, and better gear unlocks once you've
	reached higher office floors.

	Each tier row's button shows its state: EQUIPPED (best you own), OWNED, a price (next one you can buy),
	or FLOOR n (not unlocked yet).

	StoreApp.Start(window)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OfficeConfig = require(Shared.Config.OfficeConfig)
local Format = require(Shared.Util.Format)

local Client = script.Parent.Parent
local Ui = Client:WaitForChild("Ui")
local ButtonFx = require(Ui.ButtonFx)
local Notify = require(Ui.Notify)
local Theme = require(Ui.Theme)
local CareerStore = require(script.Parent.CareerStore)
local Ledger = require(script.Parent.Ledger)
local Sfx = require(script.Parent.Sfx)

local StoreApp = {}

local body: any
local busy = false

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
		then "Purchases aren't saved in Studio test sessions."
		else "Everything you earn on shifts goes to your career cash."

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
		Notify.show("Store", result.Message, Theme.Green)
	else
		Sfx.Play("Error")
	end
end

function StoreApp.Start(window: Frame)
	body = window:WaitForChild("Body")
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
			warn(`[StoreApp] the Store window has no {kind} column`)
		end
	end
	CareerStore.Changed:Connect(render)
	render()
end

return StoreApp
