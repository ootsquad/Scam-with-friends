--[[
	ShopService (server, Call Center Place)
	Grants Robux developer products (ShopConfig.Products) through MarketplaceService.ProcessReceipt.

	Every purchase is granted exactly once: CareerService.ApplyReceipt remembers the purchase id in the buyer's
	saved career and saves it straight away, and Roblox keeps retrying a purchase until it's granted. If a
	purchase can't be granted right now (the buyer left, their career couldn't load, the phone line is down for
	a prank call), it's left for Roblox to retry.

	  Prank Call     a prank caller rings the crewmate the buyer picked (Shop PrankTarget), or a random one
	  Virus Attack   DisasterService.Virus
	  2x Cash        +15 minutes of 2x earnings (PerkService)
	  Save My Call   a call save; used right away if a failed call can still be saved
	  Office Chaos   DisasterService.Chaos
	  Extra Tips     +5 on-call tips
	  Boss Meltdown / Police Raid   coming soon: not granted until a handler is registered

	Game passes are handled by PerkService.

	ShopService.Start()
	ShopService.Register(productKey, grant(player, receipt) -> boolean)   adds or replaces a product's effect
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShopConfig = require(Shared.Config.ShopConfig)
local Shop = require(Shared:WaitForChild("Network")).Shop
local CallService = require(script.Parent.CallService)
local CareerService = require(script.Parent.CareerService)
local ClaudeClient = require(script.Parent.ClaudeClient)
local DeskService = require(script.Parent.DeskService)
local DisasterService = require(script.Parent.DisasterService)
local PerkService = require(script.Parent.PerkService)

type Grant = (Player, any) -> boolean

local ShopService = {}

local handlers: { [string]: Grant } = {}
local prankTargets: { [Player]: number } = {} -- UserId the buyer picked for their next prank call
local random = Random.new()

local function message(player: Player, text: string, kind: number)
	if player.Parent then
		Shop.packets.Message.sendTo({ Text = text, Kind = kind }, player)
	end
end

local function event(kind: string, by: string, target: string, seconds: number)
	for _, player in Players:GetPlayers() do
		Shop.packets.Event.sendTo({ Kind = kind, By = by, Target = target, Seconds = seconds }, player)
	end
end

local function plural(n: number, one: string, many: string): string
	return `{n} {if n == 1 then one else many}`
end

-- Who gets a prank call: the crewmate the buyer picked if they're at a desk, else a random crewmate at a desk.
-- Playing alone, it's the buyer (it rings once they sit down). nil if the crew is here but nobody's at a desk.
local function prankTarget(buyer: Player): Player?
	local picked = prankTargets[buyer]
	local target = if picked then Players:GetPlayerByUserId(picked) else nil
	if target == buyer then
		return buyer
	elseif target and DeskService.IsLoggedIn(target) then
		return target
	end
	local others, anyone = {}, false
	for _, player in Players:GetPlayers() do
		if player ~= buyer then
			anyone = true
			if DeskService.IsLoggedIn(player) then
				table.insert(others, player)
			end
		end
	end
	if #others > 0 then
		return others[random:NextInteger(1, #others)]
	end
	return if anyone then nil else buyer
end

-- ---------------------------------------------------------------------------
-- Products
-- ---------------------------------------------------------------------------

handlers.PrankCall = function(player)
	if not ClaudeClient.HasKey() then
		return false -- nobody to make the call; Roblox tries again later
	end
	local target = prankTarget(player)
	if not target then
		return false -- nobody's at a desk to take the call; Roblox tries again later
	end
	prankTargets[player] = nil
	CallService.QueuePrank(target, player.DisplayName, player.UserId)
	event("Prank", player.DisplayName, target.DisplayName, 0)
	message(player, if target == player
		then "Prank call on its way! Answer your phone at a desk."
		else `Prank call on its way to {target.DisplayName}!`, 2)
	return true
end

handlers.VirusAttack = function(player)
	if not DisasterService.CanStart() then
		return false -- the day is about to end; Roblox tries again later
	end
	if DisasterService.Virus(player.DisplayName) == 0 then
		return false -- no computers to infect
	end
	message(player, "Virus attack unleashed! Every computer is full of pop-ups.", 2)
	return true
end

handlers.OfficeChaos = function(player)
	if not DisasterService.CanStart() then
		return false
	end
	DisasterService.Chaos(player.DisplayName)
	message(player, "Office chaos! Cleanup pays double for a while.", 2)
	return true
end

handlers.DoubleCash = function(player)
	PerkService.AddBoost(player, ShopConfig.DoubleCashSeconds)
	if PerkService.Owns(player, "CashForever") then
		message(player, "2x cash time saved. (You already have Permanent 2x Cash.)", 1)
	else
		message(player, `2x cash for {math.round(ShopConfig.DoubleCashSeconds / 60)} more minutes!`, 2)
	end
	return true
end

handlers.ExtraTips = function(player)
	PerkService.AddTips(player, ShopConfig.TipsPerPurchase)
	message(player, `+{ShopConfig.TipsPerPurchase} tips! You have {plural(PerkService.TipsLeft(player), "tip", "tips")}.`, 2)
	return true
end

handlers.SaveMyCall = function(player)
	PerkService.AddSaves(player, 1)
	local used = if CallService.CanSave(player) and DeskService.IsLoggedIn(player) then PerkService.UseSave(player) else nil
	if used then
		task.defer(function()
			local ok, text = CallService.SaveCall(player)
			if not ok then
				PerkService.ReturnSave(player, used)
				message(player, "Call save kept for later: " .. text, 1)
			else
				message(player, text, 2)
			end
		end)
	else
		message(player, "Call save ready. Use it from the phone after a caller hangs up on you.", 2)
	end
	return true
end

function ShopService.Register(key: string, grant: Grant)
	handlers[key] = grant
end

-- ---------------------------------------------------------------------------
-- Receipts
-- ---------------------------------------------------------------------------

local function processReceipt(receipt: any): Enum.ProductPurchaseDecision
	local item = ShopConfig.ProductById(receipt.ProductId)
	if not item then
		warn(`[ShopService] a purchase of unknown product {receipt.ProductId}; add it to ShopConfig`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local grant = handlers[item.Key]
	if item.ComingSoon or not grant then
		warn(`[ShopService] {item.Name} isn't for sale yet; leaving purchase {receipt.PurchaseId} for later`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local ok, granted = pcall(CareerService.ApplyReceipt, player, tostring(receipt.PurchaseId), function()
		local grantOk, result = pcall(grant, player, receipt)
		if not grantOk then
			warn(`[ShopService] granting {item.Name} to {player.Name} failed: {result}`)
			return false
		end
		return result == true
	end)
	if ok and granted then
		print(`[ShopService] granted {item.Name} to {player.Name}`)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if not ok then
		warn(`[ShopService] purchase {receipt.PurchaseId} failed: {granted}`)
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

local function onPrankTarget(userId: number, player: Player)
	if type(userId) == "number" and userId == userId then
		prankTargets[player] = userId
	end
end

function ShopService.Start()
	MarketplaceService.ProcessReceipt = processReceipt
	Shop.packets.PrankTarget.listen(onPrankTarget)
	Players.PlayerRemoving:Connect(function(player)
		prankTargets[player] = nil
	end)
end

ShopService._processReceipt = processReceipt -- for tests

return ShopService
