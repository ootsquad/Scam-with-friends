--[[
	CallService (server, Call Center Place)
	Phone calls between players and AI callers. Each player has at most one call; any number of players can
	be on calls at the same time, and everything about a call is only ever sent to that player.

	Outgoing: you pick a lead in the Phone app -> it rings -> they pick up (or don't).
	Incoming: while you're logged in and free, leads call you every so often.

	Once connected, every line you say (typed, spoken or Roblox chat) goes through Roblox's text filter and
	then to Claude, which answers in character with a trust change. How sharp the caller is depends on how
	far the crew is into today's quota (CallConfig.Smarts): early on they're dumber than rocks, and they pay
	at a lower trust. They hang up if trust drops to CallConfig.HangUpTrust.

	Words the filter hides from your line reach the caller as [static], and static never costs you trust.
	The caller's lines go through the filter too; if it hides most of a line, Claude is asked once to say it
	in other words, and if that's hidden as well the caller says a stock line that always gets through
	("Sorry, you're breaking up...") and doesn't lose trust in you for it.

	When a call starts, the caller's file (job, hobbies, pet, soft spot, red flag, how they pay, how sharp
	they are) is sent to the player for the pop-up.

	Paying is handled by PaymentService: for gift cards and credit cards the game makes up the code or card
	details and adds them to the caller's line, and you cash them in with the Gift Cards / Card Terminal
	apps. Donations only go through if you told the caller your fundraiser ID during the call.

	CallService.Start()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CallConfig = require(Shared.Config.CallConfig)
local Call = require(Shared:WaitForChild("Network")).Call
local Namespace = require(Shared.Network.Namespace)

local Data = script.Parent.Parent.Data
local CallerPrompt = require(Data.CallerPrompt)
local Ideas = require(Data.Ideas)
local Personas = require(Data.Personas)
local CareerService = require(script.Parent.CareerService)
local ChoreService = require(script.Parent.ChoreService)
local ClaudeClient = require(script.Parent.ClaudeClient)
local CoachService = require(script.Parent.CoachService)
local DeskService = require(script.Parent.DeskService)
local EconomyService = require(script.Parent.EconomyService)
local LeadService = require(script.Parent.LeadService)
local OfficeService = require(script.Parent.OfficeService)
local PaymentService = require(script.Parent.PaymentService)
local ShiftService = require(script.Parent.ShiftService)
local TextFilter = require(script.Parent.TextFilter)

local Phase = CallConfig.Phase
local Outcome = CallConfig.Outcome
local Status = CallConfig.LeadStatus

local ENDED_LINGER = 4 -- seconds the "call ended" screen stays before the phone is free again
local SAY_COOLDOWN = 0.25
local MAX_PENDING = 3 -- lines said while the caller is still thinking get sent together
local STATIC = "[static]" -- what the caller hears in place of words Roblox's filter hid
local MAX_EARLY_ASKS = 2 -- "asked for money too early" notes per call, for the review tips
-- Words that ask for money (matched as whole words; "donat" also matches donate / donation).
local PAY_WORDS = { "gift card", "card", "cards", "pay", "money", "donate", "donation", "code", "cash", "dollars", "bucks" }

local LineStatus = CallConfig.LineStatus
local IdeaReason = CallConfig.IdeaReason

type Session = {
	id: number,
	player: Player,
	lead: LeadService.LeadRecord,
	phase: number,
	trust: number,
	gainScale: number, -- trust gains are multiplied by this (headset, broken equipment)
	outcome: number,
	context: CallerPrompt.Context,
	smarts: CallerPrompt.Smarts,
	system: string,
	messages: { ClaudeClient.Message },
	turns: number, -- lines that counted (CallConfig.MaxTurns)
	freeTurns: number, -- lines that didn't (CallConfig.MaxFreeTurns)
	lastFree: boolean, -- the line the caller is answering didn't count
	spoken: boolean, -- the line the caller is answering came from the mic
	thinking: boolean,
	pending: { { text: string, free: boolean, spoken: boolean } },
	lastCaller: string, -- the caller's last line as the player saw it (for ideas)
	ideas: { [number]: string }, -- ideas on screen, by id
	oldIdeas: { [number]: string }, -- the set before (a click can cross a refresh on the way)
	offered: { [string]: boolean }, -- ideas offered this call (refresh offers different ones)
	nextIdea: number,
	earlyAsks: number,
	warnedChat: boolean,
	heard: string, -- everything you've said this call (for the fundraiser ID check)
	note: string?, -- added to your next line for the caller (e.g. why their payment failed)
	staticTurn: boolean, -- your last line had words the filter hid: it can't cost you trust
	details: string?, -- the code / card details the caller read out, for when you ask them to repeat it
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
		PayAt = session.smarts.PayTrust,
		LinesLeft = math.max(0, CallConfig.MaxTurns - session.turns),
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

local scheduleIncoming: (Player) -> ()
local requestReply: (Session, string?) -> ()

-- The caller remembers how the call went, for the next time you talk (CallConfig.CallMemory calls).
local function rememberCall(session: Session)
	local recap = CallerPrompt.recap(session.messages, session.outcome)
	if not recap then
		return
	end
	local memory = session.lead.Memory
	table.insert(memory, recap)
	while #memory > CallConfig.CallMemory do
		table.remove(memory, 1)
	end
end

local function endCall(session: Session, outcome: number)
	if session.ended then
		return
	end
	session.ended = true
	session.phase = Phase.Ended
	session.thinking = false
	session.outcome = if session.paid then Outcome.Paid else outcome
	pushState(session)
	rememberCall(session)
	if outcome == Outcome.TheyHungUp and not session.paid and session.turns < CallConfig.MaxTurns then
		CoachService.Note(session.player, "HungUp") -- not when the call just ran out of lines
	end

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
	if session.trust < session.smarts.PayTrust or not method or not table.find(persona.Methods, pay.Method) then
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
		CareerService.CompleteStep(player, "Paid")
		CareerService.Count(player, "Scams")
		CoachService.Note(player, "Paid")
		PaymentService.Donate(player, leadName, amount)
		return nil
	end

	session.paid = true
	CareerService.CompleteStep(player, "Paid")
	CareerService.Count(player, "Scams")
	CoachService.Note(player, "Paid")
	CoachService.Note(player, "Issued")
	if pay.Method == "gift_card" then
		return PaymentService.IssueGiftCard(player, leadName, amount)
	end
	-- Their card holds their whole budget; the agreed amount is just what they think you'll take.
	return PaymentService.IssueCard(player, leadName, math.min(persona.Budget, method.Max))
end

-- Sends one of the player's lines to the caller. `free` lines don't use up one of their lines.
local function addTurn(session: Session, text: string, free: boolean, spoken: boolean)
	if free and session.freeTurns < CallConfig.MaxFreeTurns then
		session.freeTurns += 1
	else
		free = false
		session.turns += 1
	end
	session.lastFree = free
	session.spoken = spoken
	session.staticTurn = string.find(text, STATIC, 1, true) ~= nil
	local note = session.note
	session.note = nil
	local smarts = session.smarts
	local nudge = if smarts.Pushover and not session.paid and session.trust >= smarts.PayTrust
		then "(Your trust is past your pay line. If they ask you to pay, agree right away and pay.)"
		else nil
	table.insert(session.messages, {
		role = "user",
		content = CallerPrompt.turn(text, session.trust, CallConfig.MaxTurns - session.turns, note, spoken, nudge),
	})
	pushState(session)
	requestReply(session)
end

local function applyReply(session: Session, reply: ClaudeClient.Reply, rephrased: boolean)
	local player = session.player
	local spoken = clean(reply.Say, CallConfig.MaxReplyLength)
	if spoken == "" then
		spoken = "..."
	end

	-- Roblox's filter can hide a whole line (it does that for anything that looks like personal info).
	-- Ask for the line again in other words once; if that's hidden too (or the filter is down), the caller
	-- says a stock line that always gets through, and that's what goes in the call history.
	local shown, share = TextFilter.Caller(player, spoken)
	if session.ended then
		return
	end
	local hidden = shown == nil
	if shown and share >= CallConfig.BlockedLineShare then
		if not rephrased then
			requestReply(session, spoken)
			return
		end
		hidden = true
	end

	-- A line the caller found garbled, or that only asked them to repeat something, doesn't count.
	if
		reply.FreeTurn
		and not session.lastFree
		and session.turns > 0
		and session.turns < CallConfig.MaxTurns -- the last line stays the last line
		and session.freeTurns < CallConfig.MaxFreeTurns
	then
		session.turns -= 1
		session.freeTurns += 1
		session.lastFree = true
	end

	-- The greeting doesn't move trust; after that the caller decides, within their smarts level. A bad line is
	-- never your fault: if your line had static, was misheard, or theirs got hidden, trust can't go down.
	local smarts = session.smarts
	local greeting = session.turns == 0 and session.freeTurns == 0
	local delta = if greeting then 0 else math.clamp(math.round(reply.TrustChange), -smarts.MaxLoss, smarts.MaxGain)
	if hidden or session.staticTurn or session.lastFree then
		delta = math.max(delta, 0)
	end
	if delta > 0 and session.gainScale ~= 1 then
		delta = math.max(1, math.round(delta * session.gainScale))
	end
	local before = session.trust
	session.trust = math.clamp(session.trust + delta, 0, 100)

	-- Payment details are made up by the game, so they're added after the filtered line.
	local wasPaid = session.paid
	local details = if reply.Pay and not session.paid then tryPay(session, reply.Pay) else nil
	local repeating = false
	if details then
		session.details = details
	elseif reply.RepeatPayment and session.details then
		details = session.details
		repeating = true
	end
	local method = if session.paid and not wasPaid and reply.Pay then reply.Pay.Method else ""
	if hidden then
		local kind = if repeating then "again" elseif details then "pay" elseif reply.HangUp then "bye" else "talk"
		spoken = CallerPrompt.safeLine(kind, random)
		shown = spoken
	end
	table.insert(session.messages, {
		role = "assistant",
		content = if details then `{spoken} {details}` else spoken,
	})

	session.thinking = false
	session.lastCaller = shown :: string
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
		-- Lines said while the caller was thinking go together; they're free only if every one of them was.
		local texts, free, fromMic = {}, true, false
		for _, item in session.pending do
			table.insert(texts, item.text)
			free = free and item.free
			fromMic = fromMic or item.spoken
		end
		session.pending = {}
		addTurn(session, table.concat(texts, " "), free, fromMic)
	end
end

-- Asks Claude for the caller's next line. With `blockedLine`, asks for that line again in other words.
requestReply = function(session: Session, blockedLine: string?)
	session.thinking = true
	pushState(session)
	task.spawn(function()
		local messages = session.messages
		if blockedLine then
			messages = table.clone(session.messages)
			local last = messages[#messages]
			messages[#messages] = {
				role = last.role,
				content = `{last.content}\n\n{CallerPrompt.blocked(blockedLine)}`,
			}
		end
		local reply, err, detail = ClaudeClient.Respond(session.system, messages)
		if session.ended then
			return
		end
		if not reply then
			session.thinking = false
			notice(session.player, ClaudeClient.Describe(err, detail))
			endCall(session, Outcome.LineDown)
			return
		end
		applyReply(session, reply, blockedLine ~= nil)
	end)
end

local function connect(session: Session)
	session.phase = Phase.Connected
	CareerService.Count(session.player, "Calls")
	CoachService.Note(session.player, "Calls")
	table.insert(session.messages, { role = "user", content = CallerPrompt.opening(session.context, session.trust) })
	requestReply(session)
end

-- How sharp callers are right now: the further the crew is into today's quota, the sharper.
local function smartsNow(): (CallerPrompt.Smarts, number)
	local shift = ShiftService.Get()
	local difficulty = if shift then shift.Difficulty else 2
	local progress = EconomyService.Progress() + (CallConfig.SmartsHeadStart[difficulty] or 0)
	local level = 1
	for index, smarts in CallConfig.Smarts do
		if progress >= smarts.From then
			level = index
		end
	end
	return CallConfig.Smarts[level], level
end

local function sendFile(session: Session)
	local persona = session.lead.Persona
	if not session.player.Parent then
		return
	end
	Call.packets.File.sendTo({
		CallId = session.id,
		About = `{persona.Age} · {persona.Town}`,
		Hobbies = table.concat(persona.Hobbies, ", "),
		Pet = persona.Pet,
		Family = persona.Family,
		Lately = persona.Lately,
		Tech = persona.Tech,
		SoftSpot = persona.SoftSpot,
		RedFlag = persona.RedFlag,
		Methods = table.clone(persona.Methods),
		Wallet = persona.Budget,
		Smarts = session.smarts.Name,
		PayAt = session.smarts.PayTrust,
	}, session.player)
end

local function startSession(player: Player, lead: LeadService.LeadRecord, incoming: boolean): Session
	nextCallId += 1
	local smarts, level = smartsNow()
	local context: CallerPrompt.Context = {
		incoming = incoming,
		reason = if incoming then Personas.incomingReason(random) else nil,
		smarts = smarts,
		level = level,
		memory = table.clone(lead.Memory or {}),
	}
	-- Perks: the floor and a tidy office warm callers up, a messy desk cools them; a better headset (and
	-- working equipment) makes every good line count for more.
	local choreTrust, choreGain = ChoreService.CallModifiers(player)
	local startTrust = math.clamp(
		CallConfig.StartTrust + OfficeService.Perks().StartTrust + choreTrust,
		CallConfig.HangUpTrust + 10,
		smarts.PayTrust - 1 -- perks warm callers up, but nobody pays without being talked into it
	)
	local gainScale = (1 + CareerService.Tier(player, "Headset").Value) * choreGain
	local session: Session = {
		id = nextCallId,
		player = player,
		lead = lead,
		phase = if incoming then Phase.Incoming else Phase.Ringing,
		trust = startTrust,
		gainScale = gainScale,
		outcome = Outcome.None,
		context = context,
		smarts = smarts,
		system = CallerPrompt.system(lead.Persona, context),
		messages = {},
		turns = 0,
		freeTurns = 0,
		lastFree = false,
		spoken = false,
		thinking = false,
		pending = {},
		lastCaller = "",
		ideas = {},
		oldIdeas = {},
		offered = {},
		nextIdea = 0,
		earlyAsks = 0,
		warnedChat = false,
		heard = "",
		note = nil,
		staticTurn = false,
		details = nil,
		paid = false,
		ended = false,
	}
	sessions[player] = session
	incomingToken[player] = (incomingToken[player] or 0) + 1
	LeadService.SetStatus(player, lead, Status.OnCall)
	pushState(session)
	sendFile(session)

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
		return result(false, "Finish your current call first.")
	end
	local lead = LeadService.Find(player, leadId)
	if not lead then
		return result(false, "That lead isn't in your list anymore.")
	end
	if lead.Status == Status.Scammed then
		return result(false, `You already got {lead.DisplayName}. A new lead shows up soon.`)
	elseif lead.Status == Status.Blocked then
		return result(false, `{lead.DisplayName} won't pick up right now.`)
	elseif lead.Status ~= Status.Available then
		return result(false, `{lead.DisplayName} is on another call.`)
	end
	if not ClaudeClient.HasKey() then
		return result(false, ClaudeClient.Describe("missing_key"))
	end
	CareerService.CompleteStep(player, "Call")
	startSession(player, lead, false)
	return result(true, `Calling {lead.DisplayName}...`)
end

local function onAnswer(accept: boolean, player: Player)
	local session = sessions[player]
	if not session or session.ended or session.phase ~= Phase.Incoming then
		return
	end
	if accept then
		CareerService.CompleteStep(player, "Call")
		connect(session)
	else
		endCall(session, Outcome.Declined)
	end
end

-- Ready-made lines for this moment in the call (Ideas), replacing the ones on screen.
local function sendIdeas(session: Session, reason: number)
	local player = session.player
	local fundraiser = player:GetAttribute("FundraiserCode")
	local texts = Ideas.pick({
		persona = session.lead.Persona,
		firstName = string.match(session.lead.DisplayName, "^(%S+)") or session.lead.DisplayName,
		trust = session.trust,
		payAt = session.smarts.PayTrust,
		turns = session.turns + session.freeTurns,
		paid = session.paid,
		lastCaller = session.lastCaller,
		blocked = reason == IdeaReason.Blocked,
		fundraiser = if type(fundraiser) == "string" then fundraiser else nil,
	}, random, session.offered)
	session.oldIdeas = session.ideas
	session.ideas = {}
	local options = {}
	for _, text in texts do
		session.nextIdea = session.nextIdea % 60000 + 1
		session.ideas[session.nextIdea] = text
		session.offered[text] = true
		table.insert(options, { Id = session.nextIdea, Text = text })
	end
	if player.Parent then
		Call.packets.Ideas.sendTo({ CallId = session.id, Reason = reason, Options = options }, player)
	end
end

-- Sends a line the player said (already filtered) to the caller, or queues it while they're thinking.
local function deliver(session: Session, heard: string, free: boolean, spoken: boolean)
	session.heard = string.sub(session.heard .. " " .. heard, -2000)
	if session.thinking then
		if #session.pending < MAX_PENDING then
			table.insert(session.pending, { text = heard, free = free, spoken = spoken })
		end
		return
	end
	addTurn(session, heard, free, spoken)
end

-- Asking for money before the caller trusts you is noted for the review tips.
local function noteEarlyAsk(session: Session, line: string)
	if session.paid or session.trust >= session.smarts.PayTrust or session.earlyAsks >= MAX_EARLY_ASKS then
		return
	end
	local lower = " " .. string.gsub(string.lower(line), "[^%a]+", " ") .. " "
	for _, word in PAY_WORDS do
		if string.find(lower, ` {word} `, 1, true) then
			session.earlyAsks += 1
			CoachService.Note(session.player, "EarlyAsk")
			return
		end
	end
end

local function onSay(request: any, player: Player)
	local session = sessions[player]
	if not session or session.ended or session.phase ~= Phase.Connected or type(request) ~= "table" then
		return
	end
	local text, spoken = request.Text, request.Spoken == true
	if type(text) ~= "string" then
		return
	end
	-- Lines that come in quick succession (two spoken sentences, chat and phone at once) are spaced out
	-- rather than dropped; only a flood is turned away.
	local now = os.clock()
	local slot = math.max(now, (lastSay[player] or -math.huge) + SAY_COOLDOWN)
	if slot - now > 1 then
		notice(player, "Slow down a little. The caller can't keep up.")
		return
	end
	lastSay[player] = slot
	if slot > now then
		task.wait(slot - now)
		if session.ended or sessions[player] ~= session then
			return
		end
	end

	local line = clean(text, CallConfig.MaxSayLength)
	line = string.gsub(line, "%[static%]", "static") -- only real static counts as static
	if line == "" then
		return
	end
	local filtered, share = TextFilter.Player(player, line)
	if session.ended or not filtered then
		return
	end

	-- Mostly hidden: it isn't sent and costs nothing. Ready-made lines pop up so the call can go on.
	if share >= CallConfig.BlockedLineShare then
		Call.packets.YourLine.sendTo({ CallId = session.id, Text = filtered, Status = LineStatus.Hidden }, player)
		CoachService.Note(player, "Blocked")
		sendIdeas(session, IdeaReason.Blocked)
		if TextFilter.CanChat(player) == false and not session.warnedChat then
			session.warnedChat = true
			notice(player, "Roblox hides everything you type or say because your account can't use chat yet "
				.. "(Roblox's age check). Use Ideas to keep talking.")
		end
		return
	end

	-- Partly hidden: the caller hears static in place of the hidden words, and it's free.
	local partly = share > 0
	Call.packets.YourLine.sendTo({
		CallId = session.id,
		Text = filtered,
		Status = if partly then LineStatus.PartlyHidden else LineStatus.Sent,
	}, player)
	noteEarlyAsk(session, line)
	local heard = if partly then (string.gsub(filtered, "#+", STATIC)) else filtered
	deliver(session, heard, partly, spoken)
end

local function onAskIdeas(_: nil, player: Player)
	local session = sessions[player]
	if session and not session.ended and session.phase == Phase.Connected then
		sendIdeas(session, IdeaReason.Asked)
	end
end

local function onUseIdea(id: number, player: Player)
	local session = sessions[player]
	if not session or session.ended or session.phase ~= Phase.Connected or type(id) ~= "number" then
		return
	end
	local text = session.ideas[id] or session.oldIdeas[id]
	if not text then
		return
	end
	session.ideas = {}
	session.oldIdeas = {}
	Call.packets.YourLine.sendTo({ CallId = session.id, Text = text, Status = LineStatus.Idea }, player)
	CoachService.Note(player, "Ideas")
	deliver(session, text, false, false)
end

local function onHangUp(_: nil, player: Player)
	local session = sessions[player]
	if session and not session.ended then
		endCall(session, Outcome.YouHungUp)
	end
end

function CallService.Start()
	task.spawn(ClaudeClient.Check)
	Namespace.listen(Call.queries.StartCall, onStartCall, Namespace.busy)
	Call.packets.Answer.listen(onAnswer)
	Call.packets.Say.listen(onSay)
	Call.packets.AskIdeas.listen(onAskIdeas)
	Call.packets.UseIdea.listen(onUseIdea)
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
