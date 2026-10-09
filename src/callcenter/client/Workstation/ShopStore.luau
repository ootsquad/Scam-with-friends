--[[
	ShopStore (client, Call Center Place)
	Robux items (ShopConfig) on the client: prices from Roblox, buying through Roblox's purchase prompts, what
	you own and have left (PerkService's player attributes), and office events and notes from the server.

	ShopStore.Start()
	ShopStore.Price(item) -> number?               Roblox's price (or ShopConfig's until it loads)
	ShopStore.BuyProduct(key)  /  ShopStore.BuyPass(key)
	ShopStore.PrankTarget(userId)                  who gets your next Prank Call (call before BuyProduct)
	ShopStore.UseCallSave()                        spend a call save on your last failed call
	ShopStore.CleanVirus()                         you closed every virus pop-up
	ShopStore.Owns(passKey) -> boolean
	ShopStore.TipsLeft() -> number   SavesLeft() -> number   BoostSeconds() -> number   Boosted() -> boolean
	ShopStore.Changed()        your perks changed (attributes)
	ShopStore.PricesLoaded()
	ShopStore.Event(event)     { Kind, By, Target, Seconds } something happened to the whole office
	ShopStore.Message(message) { Text, Kind } a note for you (1 info, 2 good news, 3 problem)
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShopConfig = require(Shared.Config.ShopConfig)
local Signal = require(Shared.Util.Signal)

local ATTRIBUTES = {
	"Passes", "BoostPermanent", "BoostSeconds", "TeamBonus", "TipsFree", "TipCredits", "SavesFree", "CallSaves",
	"VIP", "TeamLeader", "SaveableCall",
}

local player = Players.LocalPlayer

local ShopStore = {
	Changed = Signal.new(),
	PricesLoaded = Signal.new(),
	Event = Signal.new(),
	Message = Signal.new(),
}

local prices: { [number]: number } = {}

local function number(name: string): number
	local value = player:GetAttribute(name)
	return if type(value) == "number" then value else 0
end

function ShopStore.Price(item: ShopConfig.Item): number?
	return prices[item.Id] or item.Price
end

function ShopStore.Owns(key: string): boolean
	local passes = player:GetAttribute("Passes")
	if type(passes) ~= "string" then
		return false
	end
	return table.find(string.split(passes, ","), key) ~= nil
end

function ShopStore.TipsLeft(): number
	return number("TipsFree") + number("TipCredits")
end

function ShopStore.SavesLeft(): number
	return number("SavesFree") + number("CallSaves")
end

function ShopStore.BoostSeconds(): number
	return number("BoostSeconds")
end

function ShopStore.Boosted(): boolean
	return player:GetAttribute("BoostPermanent") == true or number("BoostSeconds") > 0
end

function ShopStore.BuyProduct(key: string)
	local item = ShopConfig.Product(key)
	if not item or item.ComingSoon then
		return
	end
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, item.Id)
	end)
	if not ok then
		warn(`[ShopStore] couldn't open the purchase prompt for {item.Name}: {err}`)
	end
end

function ShopStore.BuyPass(key: string)
	local item = ShopConfig.Pass(key)
	if not item or ShopStore.Owns(key) then
		return
	end
	local ok, err = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, item.Id)
	end)
	if not ok then
		warn(`[ShopStore] couldn't open the purchase prompt for {item.Name}: {err}`)
	end
end

local Shop: any

function ShopStore.PrankTarget(userId: number)
	Shop.packets.PrankTarget.send(userId)
end

function ShopStore.UseCallSave()
	Shop.packets.UseCallSave.send(nil)
end

function ShopStore.CleanVirus()
	Shop.packets.CleanVirus.send(nil)
end

local function loadPrices()
	local function fetch(item: ShopConfig.Item, infoType: Enum.InfoType)
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(item.Id, infoType)
		end)
		if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then
			prices[item.Id] = info.PriceInRobux
		end
	end
	for _, item in ShopConfig.Products do
		fetch(item, Enum.InfoType.Product)
	end
	for _, item in ShopConfig.Passes do
		fetch(item, Enum.InfoType.GamePass)
	end
	ShopStore.PricesLoaded:Fire()
end

function ShopStore.Start()
	Shop = require(Shared:WaitForChild("Network")).Shop
	Shop.packets.Event.listen(function(event)
		ShopStore.Event:Fire(event)
	end)
	Shop.packets.Message.listen(function(message)
		ShopStore.Message:Fire(message)
	end)
	for _, name in ATTRIBUTES do
		player:GetAttributeChangedSignal(name):Connect(function()
			ShopStore.Changed:Fire()
		end)
	end
	task.spawn(loadPrices)
end

return ShopStore
