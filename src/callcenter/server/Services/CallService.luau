--[[
	CallService (server, Call Center Place)
	Phone calls between players and AI callers. Each player has at most one call; any number of players can
	be on calls at the same time, and everything about a call is only ever sent to that player.

	Outgoing: you pick a lead in the Phone app -> it rings -> they pick up (or don't).
	Incoming: while you're logged in and free, leads call you every so often.

	Once connected, every line you say (typed, spoken or Roblox chat) goes through Roblox's text filter and
	then to Claude, which answers in character with a trust change. Callers pay once their trust reaches
	CallConfig.PayTrust and you've asked; they hang up if it drops to CallConfig.HangUpTrust.

	Paying is handled by PaymentService: for gift cards and credit cards the game makes up the code or card
	details and adds them to the caller's line, and you cash them in with the Gift Cards / Card Terminal
	apps. Donations only go through if you told the caller your fundraiser ID during the call.

	CallService.Start()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CallConfig = require(Shared.Config.CallConfig)
local Call = require(Shared:WaitForChild("Network")).Call

local Data = script.Parent.Parent.Data
local CallerPrompt = require(Data.CallerPrompt)
local Personas = require(Data.Personas)
local ClaudeClient = require(script.Parent.ClaudeClient)
local DeskService = require(script.Parent.DeskService)
local EconomyService = require(script.Parent.EconomyService)
local LeadService = require(script.Parent.LeadService)
local PaymentService = require(script.Parent.PaymentService)
local ShiftService = require(script.Parent.ShiftService)

local Phase = CallConfig.Phase
local Outcome = CallConfig.Outcome
local Status = CallConfig.LeadStatus

local ENDED_LINGER = 4 -- seconds the "call ended" screen stays before the phone is free again
local SAY_COOLDOWN = 0.25
local MAX_PENDING = 3 -- lines said while the caller is still thinking get sent together

type Session = {
	id: number,
	player: Player,
	lead: LeadService.LeadRecord,
	phase: number,
	trust: number,
	outcome: number,
	context: CallerPrompt.Context,
	system: string,
	messages: { ClaudeClient.Message },
	turns: number,
	thinking: boolean,
	pending: { string },
	heard: string, -- everything you've said this call (for the fundraiser ID check)
	note: string?, -- added to your next line for the caller (e.g. why their payment failed)
	paid: boolean,
	ended: boolean,
}

local CallService = {}

local sessions: { [Player]: Session } = {}
local incomingToken: { [Player]: number } = {}
local lastSay: { [Player]: number } = {}
local nextCallId = 0
local random = Random.new()

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function result(ok: boolean, message: string)
	return { Ok = ok, Message = message }
end

local function notice(player: Player, message: string)
	if player.Parent and LeadService.IsReady(player) then
		Call.packets.Notice.sendTo(message, player)
	end
end

local function stateOf(session: Session)
	return {
		CallId = session.id,
		Lead = LeadService.Public(session.lead),
		Phase = session.phase,
		Trust = session.trust,
		Outcome = session.outcome,
		VoiceId = session.lead.VoiceId,
		Thinking = session.thinking,
		Paid = session.paid,
	}
end

local function pushState(session: Session)
	if session.player.Parent then
		Call.packets.State.sendTo(stateOf(session), session.player)
	end
end

-- Trims, removes *stage directions* and control characters, and caps the length (UTF-8 safe).
local function clean(text: string, max: number): string
	text = string.gsub(text, "%*[^%*]*%*", "")
	text = string.gsub(text, "%c", " ")
	text = string.gsub(text, "%s+", " ")
	text = string.gsub(text, "^%s+", "")
	text = string.gsub(text, "%s+$", "")
	if #text <= max then
		return text
	end
	local cut = 0
	local ok = pcall(function()
		for position in utf8.codes(text) do
			if position - 1 > max - 3 then
				break
			end
			cut = position - 1
		end
	end)
	if not ok then
		cut = max - 3
	end
	return string.sub(text, 1, cut) .. "..."
end

-- Roblox's text filter, for text shown to (and only to) `player`. If the filter is unavailable, a player's
-- own words are still shown back to them, and in Studio (where test players can't always be filtered)
-- everything is shown as-is. Otherwise nil.
local warnedFilter = false
local function filterFor(player: Player, text: string, ownWords: boolean?): string?
	local ok, filtered = pcall(function()
		local filterResult = TextService:FilterStringAsync(text, player.UserId, Enum.TextFilterContext.PrivateChat)
		return filterResult:GetChatForUserAsync(player.UserId)
	end)
	if ok and type(filtered) == "string" then
		return filtered
	end
	if not warnedFilter then
		warnedFilter = true
		warn(`[CallService] Roblox's text filter failed ({filtered}); using fallbacks`)
	end
	if ownWords or RunService:IsStudio() then
		return text
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Call flow
-- ---------------------------------------------------------------------------

local scheduleIncoming: (Player) -> ()
local requestReply: (Session) -> ()

local function endCall(session: Session, outcome: number)
	if session.ended then
		return
	end
	session.ended = true
	session.phase = Phase.Ended
	session.thinking = false
	session.outcome = if session.paid then Outcome.Paid else outcome
	pushState(session)

	local player, lead = session.player, session.lead
	if session.paid then
		LeadService.MarkScammed(player, lead)
	elseif outcome == Outcome.TheyHungUp and session.trust < 50 then
		LeadService.Block(player, lead)
	else
		LeadService.SetStatus(player, lead, Status.Available)
	end

	task.delay(ENDED_LINGER, function()
		if sessions[player] ~= session then
			return
		end
		sessions[player] = nil
		if player.Parent then
			Call.packets.State.sendTo(nil, player)
			if DeskService.IsLoggedIn(player) then
				scheduleIncoming(player)
			end
		end
	end)
end

-- The caller agreed to pay. Returns what the caller reads out (code / card details), if anything.
local function tryPay(session: Session, pay: { Method: string, Amount: number }): string?
	local persona = session.lead.Persona
	local method = CallConfig.PaymentMethods[pay.Method]
	if session.trust < CallConfig.PayTrust or not method or not table.find(persona.Methods, pay.Method) then
		return nil
	end
	local player, leadName = session.player, session.lead.DisplayName
	local amount = math.clamp(math.floor(pay.Amount), 1, math.min(persona.Budget, method.Max))

	if pay.Method == "donation" then
		if not PaymentService.HeardFundraiser(player, session.heard) then
			session.note = "(Your donation didn't go through: you don't have their fundraiser ID yet. Ask for it.)"
			return nil
		end
		session.paid = true
		PaymentService.Donate(player, leadName, amount)
		return nil
	end

	session.paid = true
	if pay.Method == "gift_card" then
		return PaymentService.IssueGiftCard(player, leadName, amount)
	end
	-- Their card holds their whole budget; the agreed amount is just what they think you'll take.
	return PaymentService.IssueCard(player, leadName, math.min(persona.Budget, method.Max))
end

local function addTurn(session: Session, text: string)
	session.turns += 1
	local note = session.note
	session.note = nil
	table.insert(session.messages, {
		role = "user",
		content = CallerPrompt.turn(text, session.trust, CallConfig.MaxTurns - session.turns, note),
	})
	requestReply(session)
end

local function applyReply(session: Session, reply: ClaudeClient.Reply)
	local player = session.player
	local spoken = clean(reply.Say, CallConfig.MaxReplyLength)
	if spoken == "" then
		spoken = "..."
	end

	-- The greeting doesn't move trust; after that the caller decides.
	local delta = if session.turns == 0
		then 0
		else math.clamp(math.round(reply.TrustChange), -CallConfig.MaxTrustLoss, CallConfig.MaxTrustGain)
	local before = session.trust
	session.trust = math.clamp(session.trust + delta, 0, 100)

	-- Payment details are made up by the game, so they're added after the filtered line.
	local wasPaid = session.paid
	local details = if reply.Pay and not session.paid then tryPay(session, reply.Pay) else nil
	local method = if session.paid and not wasPaid and reply.Pay then reply.Pay.Method else ""
	table.insert(session.messages, {
		role = "assistant",
		content = if details then `{spoken} {details}` else spoken,
	})

	local shown = filterFor(player, spoken) or "(the line crackles)"
	if session.ended then
		return
	end
	Call.packets.Line.sendTo({
		CallId = session.id,
		Text = if details then `{shown} {details}` else shown,
		Trust = session.trust,
		Delta = session.trust - before,
		Method = method,
	}, player)

	if reply.HangUp or session.trust <= CallConfig.HangUpTrust or session.turns >= CallConfig.MaxTurns then
		endCall(session, Outcome.TheyHungUp)
		return
	end

	pushState(session)
	if #session.pending > 0 then
		local text = table.concat(session.pending, " ")
		session.pending = {}
		addTurn(session, text)
	end
end

requestReply = function(session: Session)
	session.thinking = true
	pushState(session)
	task.spawn(function()
		local reply, err, detail = ClaudeClient.Respond(session.system, session.messages)
		if session.ended then
			return
		end
		session.thinking = false
		if not reply then
			notice(session.player, ClaudeClient.Describe(err, detail))
			endCall(session, Outcome.LineDown)
			return
		end
		applyReply(session, reply)
	end)
end

local function connect(session: Session)
	session.phase = Phase.Connected
	table.insert(session.messages, { role = "user", content = CallerPrompt.opening(session.context, session.trust) })
	requestReply(session)
end

local function startSession(player: Player, lead: LeadService.LeadRecord, incoming: boolean): Session
	nextCallId += 1
	local shift = ShiftService.Get()
	local context: CallerPrompt.Context = {
		incoming = incoming,
		reason = if incoming then Personas.incomingReason(random) else nil,
		difficulty = if shift then shift.Difficulty else 2,
	}
	local session: Session = {
		id = nextCallId,
		player = player,
		lead = lead,
		phase = if incoming then Phase.Incoming else Phase.Ringing,
		trust = CallConfig.StartTrust,
		outcome = Outcome.None,
		context = context,
		system = CallerPrompt.system(lead.Persona, context),
		messages = {},
		turns = 0,
		thinking = false,
		pending = {},
		heard = "",
		note = nil,
		paid = false,
		ended = false,
	}
	sessions[player] = session
	incomingToken[player] = (incomingToken[player] or 0) + 1
	LeadService.SetStatus(player, lead, Status.OnCall)
	pushState(session)

	if incoming then
		task.delay(CallConfig.IncomingRingTime, function()
			if not session.ended and session.phase == Phase.Incoming then
				endCall(session, Outcome.Missed)
			end
		end)
	else
		task.delay(random:NextNumber(CallConfig.RingTime.Min, CallConfig.RingTime.Max), function()
			if session.ended or session.phase ~= Phase.Ringing then
				return
			end
			if random:NextNumber() < CallConfig.NoAnswerChance then
				endCall(session, Outcome.NoAnswer)
			else
				connect(session)
			end
		end)
	end
	return session
end

scheduleIncoming = function(player: Player)
	incomingToken[player] = (incomingToken[player] or 0) + 1
	local token = incomingToken[player]
	task.delay(random:NextNumber(CallConfig.IncomingEvery.Min, CallConfig.IncomingEvery.Max), function()
		if incomingToken[player] ~= token or not player.Parent then
			return
		end
		if not DeskService.IsLoggedIn(player) or EconomyService.IsFired() then
			return
		end
		local current = sessions[player]
		local lead = LeadService.RandomAvailable(player)
		if (current and not current.ended) or not lead or not LeadService.IsReady(player) or not ClaudeClient.HasKey() then
			scheduleIncoming(player)
			return
		end
		startSession(player, lead, true)
	end)
end

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

local function onStartCall(leadId: number, player: Player)
	if not DeskService.IsLoggedIn(player) then
		return result(false, "Log in at a desk first.")
	end
	if EconomyService.IsFired() then
		return result(false, "You've been fired. No more calls.")
	end
	local current = sessions[player]
	if current and not current.ended then
		return result(false, "You're already on a call.")
	end
	local lead = LeadService.Find(player, leadId)
	if not lead then
		return result(false, "That lead isn't in your list anymore.")
	end
	if lead.Status == Status.Scammed then
		return result(false, `You already got {lead.DisplayName}.`)
	elseif lead.Status == Status.Blocked then
		return result(false, `{lead.DisplayName} isn't picking up right now.`)
	elseif lead.Status ~= Status.Available then
		return result(false, `{lead.DisplayName} is busy.`)
	end
	if not ClaudeClient.HasKey() then
		return result(false, ClaudeClient.Describe("missing_key"))
	end
	startSession(player, lead, false)
	return result(true, `Calling {lead.DisplayName}...`)
end

local function onAnswer(accept: boolean, player: Player)
	local session = sessions[player]
	if not session or session.ended or session.phase ~= Phase.Incoming then
		return
	end
	if accept then
		connect(session)
	else
		endCall(session, Outcome.Declined)
	end
end

local function onSay(text: string, player: Player)
	local session = sessions[player]
	if not session or session.ended or session.phase ~= Phase.Connected or type(text) ~= "string" then
		return
	end
	local now = os.clock()
	if lastSay[player] and now - lastSay[player] < SAY_COOLDOWN then
		return
	end
	lastSay[player] = now

	local line = clean(text, CallConfig.MaxSayLength)
	if line == "" then
		return
	end
	local filtered = filterFor(player, line, true)
	if not filtered then
		notice(player, "Couldn't send that. Try saying it again.")
		return
	end
	if session.ended then
		return
	end
	Call.packets.YourLine.sendTo({ CallId = session.id, Text = filtered }, player)
	session.heard = string.sub(session.heard .. " " .. filtered, -2000)

	if session.thinking then
		if #session.pending < MAX_PENDING then
			table.insert(session.pending, filtered)
		end
		return
	end
	addTurn(session, filtered)
end

local function onHangUp(_: nil, player: Player)
	local session = sessions[player]
	if session and not session.ended then
		endCall(session, Outcome.YouHungUp)
	end
end

function CallService.Start()
	task.spawn(ClaudeClient.Check)
	Call.queries.StartCall.listen(onStartCall)
	Call.packets.Answer.listen(onAnswer)
	Call.packets.Say.listen(onSay)
	Call.packets.HangUp.listen(onHangUp)

	DeskService.OnLogin(function(player)
		EconomyService.StartClock()
		scheduleIncoming(player)
	end)
	DeskService.OnLogout(function(player)
		incomingToken[player] = (incomingToken[player] or 0) + 1
		local session = sessions[player]
		if session and not session.ended then
			endCall(session, Outcome.YouHungUp)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		local session = sessions[player]
		if session then
			session.ended = true
		end
		sessions[player] = nil
		incomingToken[player] = nil
		lastSay[player] = nil
	end)
end

return CallService
