--[[
	ScamStore (client, Call Center Place)
	The scam apps you own this shift and your shift cash balance, plus the Scamazon requests.

	ScamStore.Start()
	ScamStore.Owned -> { [appKey]: tier }      ScamStore.Tier(appKey) -> number (0 = not owned)
	ScamStore.Balance() -> number               shift cash you can spend (player attribute ShiftBalance)
	ScamStore.Buy(appKey, tier) -> Result       (yields) buy (tier 1) or upgrade
	ScamStore.Changed()                         owned apps or the balance changed
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Namespace = require(Shared:WaitForChild("Network"):WaitForChild("Namespace"))
local Signal = require(Shared.Util.Signal)

local player = Players.LocalPlayer

local ScamStore = {
	Owned = {} :: { [string]: number },
	Changed = Signal.new(),
}

local Scam: any

local function setOwned(list: { any })
	local owned = {}
	for _, entry in list do
		owned[entry.App] = entry.Tier
	end
	ScamStore.Owned = owned
	ScamStore.Changed:Fire()
end

function ScamStore.Tier(appKey: string): number
	return ScamStore.Owned[appKey] or 0
end

function ScamStore.Balance(): number
	local balance = player:GetAttribute("ShiftBalance")
	return if type(balance) == "number" then balance else 0
end

function ScamStore.Buy(appKey: string, tier: number)
	local result = Namespace.invoke(Scam.queries.Buy, { App = appKey, Tier = tier })
	if type(result) ~= "table" then
		return { Ok = false, Message = "The server didn't answer. Try again." }
	end
	return result
end

function ScamStore.Start()
	Scam = require(Shared:WaitForChild("Network")).Scam
	Scam.packets.Apps.listen(setOwned)
	player:GetAttributeChangedSignal("ShiftBalance"):Connect(function()
		ScamStore.Changed:Fire()
	end)
	local list = Namespace.invoke(Scam.queries.GetApps, nil)
	if type(list) == "table" then
		setOwned(list)
	end
end

return ScamStore
