--[[
	CallStore (client, Call Center Place)
	Client-side state for the workstation: your leads, the current call, payouts this session, and the
	requests that go to the server.

	CallStore.Start()                           loads your leads (also tells the server you're ready)
	CallStore.State / File / Leads / Payouts
	CallStore.Changed(state, previous)  FileChanged(file)  LeadsChanged(leads)  Line(line)  YourLine(line)
	CallStore.Payout(payout)  Notice(text)  Cards(cards)  Game(game)
	CallStore.Login(username) -> Result     (yields)
	CallStore.Logoff()
	CallStore.StartCall(leadId) -> Result   (yields)
	CallStore.Answer(accept) / Pick(cardId) / Refresh() / HangUp()
	CallStore.GameDone(callId, score, perfect)    the mini-game's result (score 0-1)
	CallStore.IsConnected() -> boolean
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CallConfig = require(Shared.Config.CallConfig)
local Namespace = require(Shared:WaitForChild("Network"):WaitForChild("Namespace"))
local Signal = require(Shared.Util.Signal)

local Phase = CallConfig.Phase
local MAX_PAYOUTS = 20

local CallStore = {
	State = nil :: any,
	File = nil :: any, -- the caller file of the latest call
	Leads = {} :: { any },
	Payouts = {} :: { any }, -- newest first
	Changed = Signal.new(),
	FileChanged = Signal.new(),
	LeadsChanged = Signal.new(),
	Line = Signal.new(),
	YourLine = Signal.new(),
	Payout = Signal.new(),
	Notice = Signal.new(),
	Cards = Signal.new(),
	Game = Signal.new(),
}

local Call: any

local function setState(state: any)
	local previous = CallStore.State
	CallStore.State = state
	CallStore.Changed:Fire(state, previous)
end

local function current(callId: number): boolean
	return CallStore.State ~= nil and CallStore.State.CallId == callId
end

function CallStore.IsConnected(): boolean
	local state = CallStore.State
	return state ~= nil and state.Phase == Phase.Connected
end

local function invoke(query: any, request: any)
	local result = Namespace.invoke(query, request)
	if type(result) ~= "table" then
		return { Ok = false, Message = "The server didn't answer. Try again." }
	end
	return result
end

function CallStore.Login(username: string)
	return invoke(Call.queries.Login, username)
end

function CallStore.Logoff()
	Call.packets.Logoff.send(nil)
end

function CallStore.StartCall(leadId: number)
	return invoke(Call.queries.StartCall, leadId)
end

function CallStore.Answer(accept: boolean)
	Call.packets.Answer.send(accept)
end

function CallStore.Pick(id: number)
	if CallStore.IsConnected() then
		Call.packets.Pick.send(id)
	end
end

function CallStore.Refresh()
	if CallStore.IsConnected() then
		Call.packets.Refresh.send(nil)
	end
end

function CallStore.GameDone(callId: number, score: number, perfect: boolean)
	Call.packets.GameDone.send({ CallId = callId, Score = math.clamp(score, 0, 1), Perfect = perfect == true })
end

function CallStore.HangUp()
	Call.packets.HangUp.send(nil)
end

function CallStore.Start()
	Call = require(Shared:WaitForChild("Network")).Call

	Call.packets.State.listen(setState)
	Call.packets.File.listen(function(file)
		CallStore.File = file
		CallStore.FileChanged:Fire(file)
	end)
	Call.packets.Leads.listen(function(leads)
		CallStore.Leads = leads
		CallStore.LeadsChanged:Fire(leads)
	end)
	Call.packets.Line.listen(function(line)
		if current(line.CallId) then
			CallStore.State.Trust = line.Trust
			CallStore.Line:Fire(line)
		end
	end)
	Call.packets.YourLine.listen(function(line)
		if current(line.CallId) then
			CallStore.YourLine:Fire(line)
		end
	end)
	Call.packets.Payout.listen(function(payout)
		table.insert(CallStore.Payouts, 1, payout)
		if #CallStore.Payouts > MAX_PAYOUTS then
			table.remove(CallStore.Payouts)
		end
		CallStore.Payout:Fire(payout)
	end)
	Call.packets.Notice.listen(function(text)
		CallStore.Notice:Fire(text)
	end)
	Call.packets.Cards.listen(function(cards)
		if current(cards.CallId) then
			CallStore.Cards:Fire(cards)
		end
	end)
	Call.packets.Game.listen(function(game)
		if current(game.CallId) then
			CallStore.Game:Fire(game)
		end
	end)

	-- Asking for leads also tells the server this client can receive call packets.
	local leads = Namespace.invoke(Call.queries.GetLeads, nil)
	if type(leads) == "table" then
		CallStore.Leads = leads
		CallStore.LeadsChanged:Fire(leads)
	end
end

return CallStore
