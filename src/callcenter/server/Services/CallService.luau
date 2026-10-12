--[[
	CallService (server, Call Center Place)
	Phone calls between players and AI callers. Each player has at most one call; any number of players can
	be on calls at the same time, and everything about a call is only ever sent to that player.

	Outgoing: you pick a lead in the Phone app -> it rings -> they pick up (or don't).
	Incoming: while you're logged in and free, leads call you every so often.

	Nobody types. Every turn the caller (Claude) answers in character with a trust change AND writes the
	three cards the player can pick from next. Picking a card says it. Once trust is past the caller's pay
	line (CallConfig.Smarts), the cards also include a HOOK for every scam app the player owns
	(ScamService): a line that gets at the caller's money. A hook lands when it matches what the caller is
	weak to (or trust is well past the line); then the app's mini-game runs on the player's screen and the
	score decides the payout (ScamService.Payout). A hook that misses costs a little trust and the call
	goes on. One hook per call: after the money the caller says goodbye.

	Refresh swaps the cards for new ones (the caller says a tiny filler line): free a couple of times per
	call, then it uses an on-call tip (PerkService), then it costs a pick.

	Everything the caller says, and every card, goes through Roblox's text filter; a line the filter hides
	is asked for again in other words, and if that's hidden too a stock line that always gets through is
	used instead (cards: stock cards).

	When a call starts, the caller's file (job, hobbies, pet, soft spot, red flag, what they're weak to,
	how sharp they are) is sent to the player for the pop-up.

	Robux extras (ShopService / PerkService):
	  Prank Call     a silly prank caller rings a player (queued until they're at a desk with no call)
	  Save My Call   a call that failed (they hung up, or the line dropped) can be brought back for a while:
	                 the caller calls straight back with their trust from before it went wrong. Player
	                 attribute SaveableCall = the caller's name while there's one to save.
	  On-call tips   refreshes past the free ones use a tip.

	CallService.Start()
	CallService.QueuePrank(target, fromName)
	CallService.CanSave(player) -> boolean
	CallService.SaveCall(player) -> (ok, message)       brings the last failed call back (the save is paid for)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CallConfig = require(Shared.Config.CallConfig)
local ScamConfig = require(Shared.Config.ScamConfig)
local Call = require(Shared:WaitForChild("Network")).Call
local Shop = require(Shared:WaitForChild("Network")).Shop
local ShopConfig = require(Shared.Config.ShopConfig)
local Namespace = require(Shared.Network.Namespace)

local Data = script.Parent.Parent.Data
local CallerPrompt = require(Data.CallerPrompt)
local Personas = require(Data.Personas)
local CareerService = require(script.Parent.CareerService)
local ChoreService = require(script.Parent.ChoreService)
local ClaudeClient = require(script.Parent.ClaudeClient)
local CoachService = require(script.Parent.CoachService)
local DeskService = require(script.Parent.DeskService)
local EconomyService = require(script.Parent.EconomyService)
local LeadService = require(script.Parent.LeadService)
local OfficeService = require(script.Parent.OfficeService)
local PerkService = require(script.Parent.PerkService)
local ScamService = require(script.Parent.ScamService)
local ShiftService = require(script.Parent.ShiftService)
local TextFilter = require(script.Parent.TextFilter)

local Phase = CallConfig.Phase
local Outcome = CallConfig.Outcome
local Status = CallConfig.LeadStatus
local LineStatus = CallConfig.LineStatus

local ENDED_LINGER = 4 -- seconds the "call ended" screen stays before the phone is free again
local PICK_COOLDOWN = 0.25
local HOOK_HINT = "Trust is over the pay line. Try a hook!"
local HOOK_NONE_HINT = "Trust is over the pay line, but you have no app for it. Buy one in Scamazon."

local PRANK_NAMES = {
	"Justin Case", "Al Beback", "Paige Turner", "Anita Sandwich", "Chris P. Bacon", "Ella Vader", "Noah Fence",
	"Olive Yew", "Rick O'Shea", "Barb Dwyer", "Teddy Bear", "Will Power", "Bill Board", "Sandy Beach",
}
-- The prank caller's "smarts": they never pay and trust never moves.
local PRANKSTER: CallerPrompt.Smarts = {
	Name = "Prank caller",
	From = 0,
	PayTrust = 101,
	MaxGain = 0,
	MaxLoss = 0,
	Pushover = false,
}

type Card = { text: string, tone: string, app: string }

type Hook = {
	app: ScamConfig.App,
	tier: number,
	matched: boolean,
	expect: number, -- what a full score pays, before perks
	started: number, -- os.clock() when the mini-game was sent
	seconds: number,
	seed: number,
	done: boolean,
}

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
	turns: number, -- cards picked (maxTurns)
	maxTurns: number, -- CallConfig.MaxTurns (ShopConfig.PrankLines for a prank call)
	prank: string?, -- a prank call: who sent it
	trustBefore: number, -- trust before the caller's last answer (what Save My Call goes back to)
	thinking: boolean,
	cards: { [number]: Card }, -- the cards on screen, by id
	nextCard: number,
	freeRefreshes: number,
	refreshing: boolean, -- the reply being waited for is a refresh (its trust change doesn't count)
	hook: Hook?, -- a hook landed: the mini-game is up (or just finished)
	paid: boolean,
	ended: boolean,
}

local CallService = {}

local sessions: { [Player]: Session } = {}
local incomingToken: { [Player]: number } = {}
local pranks: { [Player]: { { from: string, fromUserId: number } } } = {} -- prank calls waiting to ring
local failed: { [Player]: { session: Session, at: number } } = {} -- the last call that failed (Save My Call)
local lastPick: { [Player]: number } = {}
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
	local hook = session.hook
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
		LinesLeft = math.max(0, session.maxTurns - session.turns),
		Hook = if hook and not hook.done then hook.app.Key else "",
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
local requeuePranks: (Player, boolean?) -> ()

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
	local player, lead = session.player, session.lead

	if session.prank then
		task.delay(ENDED_LINGER + 10, LeadService.Release, lead) -- the prankster's avatar, once the phone is done with it
	else
		rememberCall(session)
		if outcome == Outcome.TheyHungUp and not session.paid and session.turns < session.maxTurns then
			CoachService.Note(player, "HungUp") -- not when the call just ran out of picks
		end
		-- A call that went wrong (not one you ended) can be saved for a while.
		if not session.paid and (outcome == Outcome.TheyHungUp or outcome == Outcome.LineDown) then
			failed[player] = { session = session, at = os.clock() }
			player:SetAttribute("SaveableCall", lead.DisplayName)
			local entry = failed[player]
			task.delay(ShopConfig.SaveWindow, function()
				if failed[player] == entry then
					failed[player] = nil
					if player.Parent then
						player:SetAttribute("SaveableCall", nil)
					end
				end
			end)
		end
	end

	if session.prank then
		-- nothing to update in the player's leads
	elseif session.paid then
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
				task.defer(CallService.TryPrank, player)
			end
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Cards
-- ---------------------------------------------------------------------------

-- The hooks the player can try right now: one card per owned app, the ones that fit this caller first.
local function hookCards(session: Session): { Card }
	local out = {}
	if session.prank or session.paid or session.trust < session.smarts.PayTrust then
		return out
	end
	for _, app in ScamService.Hooks(session.player, session.lead.Persona.Weak) do
		table.insert(out, { text = app.Hook, tone = "Hook", app = app.Key })
	end
	return out
end

-- Puts the cards on the player's screen (the AI's, filtered, plus any hooks) and the hint under them.
local function sendCards(session: Session, offered: { ClaudeClient.Card }, hint: string)
	local player = session.player
	local cards: { Card } = {}
	local safe = CallerPrompt.safeCards(random)
	for index = 1, ScamConfig.Cards do
		local card = offered[index]
		local text = if card then clean(card.text, CallConfig.MaxCardLength) else ""
		local tone = if card and table.find(ScamConfig.Tones, card.tone) and card.tone ~= "Hook" then card.tone else "Friendly"
		if text ~= "" then
			local shown, share = TextFilter.Caller(player, text)
			if session.ended then
				return
			end
			if not shown or share >= CallConfig.BlockedLineShare then
				text = ""
			end
		end
		if text == "" then
			local stock = safe[index]
			text, tone = stock.text, stock.tone
		end
		table.insert(cards, { text = text, tone = tone, app = "" })
	end
	local hooks = hookCards(session)
	if #hooks > 0 then
		cards[#cards] = nil -- the hook takes the third slot (the client cycles through the rest)
		for _, hook in hooks do
			table.insert(cards, hook)
		end
		hint = HOOK_HINT
	elseif not session.prank and not session.paid and session.trust >= session.smarts.PayTrust then
		hint = HOOK_NONE_HINT
	end

	session.cards = {}
	local options = {}
	for _, card in cards do
		session.nextCard = session.nextCard % 60000 + 1
		session.cards[session.nextCard] = card
		table.insert(options, { Id = session.nextCard, Text = card.text, Tone = card.tone, App = card.app })
	end
	if player.Parent then
		Call.packets.Cards.sendTo({
			CallId = session.id,
			Options = options,
			Hint = clean(hint, CallConfig.MaxHintLength),
			FreeLeft = session.freeRefreshes,
		}, player)
	end
end

-- ---------------------------------------------------------------------------
-- The caller's replies
-- ---------------------------------------------------------------------------

local function startGame(session: Session)
	local hook = session.hook
	if not hook or session.ended then
		return
	end
	hook.started = os.clock()
	pushState(session)
	Call.packets.Game.sendTo({
		CallId = session.id,
		App = hook.app.Key,
		Tier = hook.tier,
		Seconds = hook.seconds,
		Seed = hook.seed,
		Expect = hook.expect,
	}, session.player)
	-- If the score never comes (closed the window, lost connection), the game still pays its minimum.
	task.delay(math.min(hook.seconds + 10, ScamConfig.MaxGameSeconds), function()
		if not session.ended and session.hook == hook and not hook.done then
			CallService.FinishGame(session.player, 0, false)
		end
	end)
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

	-- The greeting, a refresh filler and a hook reply don't move trust (the game already settled the hook);
	-- after that the caller decides, within their smarts level. A hidden caller line is never your fault.
	local smarts = session.smarts
	local hook = session.hook
	local greeting = session.turns == 0 and not session.refreshing
	local settled = session.refreshing or (hook ~= nil and not hook.done) or session.paid
	local delta = if greeting or settled then 0 else math.clamp(math.round(reply.TrustChange), -smarts.MaxLoss, smarts.MaxGain)
	if hidden then
		delta = math.max(delta, 0)
	end
	if delta > 0 and session.gainScale ~= 1 then
		delta = math.max(1, math.round(delta * session.gainScale))
	end
	local before = session.trust
	session.trustBefore = before
	session.trust = math.clamp(session.trust + delta, 0, 100)
	session.refreshing = false

	if hidden then
		local kind = if hook and not hook.done then "yes" elseif reply.HangUp then "bye" else "talk"
		spoken = CallerPrompt.safeLine(kind, random)
		shown = spoken
	end
	table.insert(session.messages, { role = "assistant", content = spoken })

	session.thinking = false
	Call.packets.Line.sendTo({
		CallId = session.id,
		Text = shown :: string,
		Trust = session.trust,
		Delta = session.trust - before,
	}, player)

	-- The caller just agreed to a hook: the mini-game starts; no cards until the money's in.
	if hook and not hook.done and hook.started == 0 then
		startGame(session)
		return
	end

	if session.paid or reply.HangUp or session.trust <= CallConfig.HangUpTrust or session.turns >= session.maxTurns then
		endCall(session, Outcome.TheyHungUp)
		return
	end

	pushState(session)
	sendCards(session, reply.Cards, reply.Hint)
end

-- Asks Claude for the caller's next line. With `blockedLine`, asks for that line again in other words.
requestReply = function(session: Session, blockedLine: string?)
	session.thinking = true
	session.cards = {}
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
	if not session.prank then
		CareerService.Count(session.player, "Calls")
		CoachService.Note(session.player, "Calls")
		-- Talking to someone new: the last failed call can't be saved anymore.
		failed[session.player] = nil
		session.player:SetAttribute("SaveableCall", nil)
	end
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
	if session.prank then
		Call.packets.File.sendTo({
			CallId = session.id,
			About = "Unknown number",
			Hobbies = "bad jokes, silly voices",
			Pet = "a parrot that laughs at everything",
			Family = "a long line of pranksters",
			Lately = "calling people for a laugh",
			Tech = "knows exactly one phone trick",
			SoftSpot = "a good laugh",
			RedFlag = "nothing, they're just having fun",
			Weak = "",
			Wallet = 0,
			Smarts = session.smarts.Name,
			PayAt = 0, -- won't pay
		}, session.player)
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
		Weak = persona.Weak,
		Wallet = persona.Budget,
		Smarts = session.smarts.Name,
		PayAt = session.smarts.PayTrust,
	}, session.player)
end

local function startSession(player: Player, lead: LeadService.LeadRecord, incoming: boolean, prankFrom: string?): Session
	nextCallId += 1
	local smarts, level = smartsNow()
	if prankFrom then
		smarts, level = PRANKSTER, 1
	end
	local context: CallerPrompt.Context = {
		incoming = incoming,
		reason = if incoming then Personas.incomingReason(random) else nil,
		smarts = smarts,
		level = level,
		memory = table.clone(lead.Memory or {}),
	}
	-- Perks: the floor and a tidy office warm callers up, a messy desk cools them; a better headset (and
	-- working equipment) makes every good card count for more.
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
		system = if prankFrom
			then CallerPrompt.prank(lead.DisplayName, prankFrom, ShopConfig.PrankLines)
			else CallerPrompt.system(lead.Persona, context),
		messages = {},
		turns = 0,
		maxTurns = if prankFrom then ShopConfig.PrankLines else CallConfig.MaxTurns,
		prank = prankFrom,
		trustBefore = startTrust,
		thinking = false,
		cards = {},
		nextCard = 0,
		freeRefreshes = ScamConfig.FreeRefreshes,
		refreshing = false,
		hook = nil,
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

-- A session that can take a pick or a refresh right now.
local function talking(player: Player): Session?
	local session = sessions[player]
	if not session or session.ended or session.phase ~= Phase.Connected or session.thinking then
		return nil
	end
	if session.hook and not session.hook.done then
		return nil -- the mini-game is up
	end
	local now = os.clock()
	if now - (lastPick[player] or -math.huge) < PICK_COOLDOWN then
		return nil
	end
	lastPick[player] = now
	return session
end

-- The player tried a hook. Whether it lands is the game's call, not the AI's.
local function tryHook(session: Session, card: Card)
	local player = session.player
	local app = ScamConfig.App(card.app)
	local tier = ScamService.Tier(player, card.app)
	local persona = session.lead.Persona
	local smarts = session.smarts
	local matched = app ~= nil and app.Weak == persona.Weak
	local landed = app ~= nil
		and tier > 0
		and session.trust >= smarts.PayTrust
		and (matched or session.trust >= smarts.PayTrust + ScamConfig.HookMargin)
	if landed and app then
		local seconds = app.Seconds + (if tier >= 2 then ScamConfig.ExtraSeconds else 0)
		session.hook = {
			app = app,
			tier = tier,
			matched = matched,
			expect = ScamService.Expect(app, tier, persona.Budget, matched),
			started = 0,
			seconds = seconds,
			seed = random:NextInteger(1, 2 ^ 31 - 1),
			done = false,
		}
		CoachService.Note(player, if matched then "HookMatched" else "HookLanded")
		Call.packets.YourLine.sendTo({ CallId = session.id, Text = card.text, Status = LineStatus.HookLanded }, player)
		table.insert(session.messages, {
			role = "user",
			content = CallerPrompt.hook(card.text, session.trust, session.maxTurns - session.turns, app.Name, true),
		})
	else
		session.trust = math.clamp(session.trust + ScamConfig.HookMismatchTrust, 0, 100)
		CoachService.Note(player, "HookMissed")
		Call.packets.YourLine.sendTo({ CallId = session.id, Text = card.text, Status = LineStatus.HookMissed }, player)
		table.insert(session.messages, {
			role = "user",
			content = CallerPrompt.hook(card.text, session.trust, session.maxTurns - session.turns,
				if app then app.Name else "that", false),
		})
	end
	pushState(session)
	requestReply(session)
end

local function onPick(id: number, player: Player)
	local session = talking(player)
	if not session or type(id) ~= "number" then
		return
	end
	local card = session.cards[id]
	if not card then
		return
	end
	session.cards = {}
	session.turns += 1
	if card.app ~= "" then
		tryHook(session, card)
		return
	end
	Call.packets.YourLine.sendTo({ CallId = session.id, Text = card.text, Status = LineStatus.Said }, player)
	CoachService.Note(player, "Picks")
	table.insert(session.messages, {
		role = "user",
		content = CallerPrompt.turn(card.text, session.trust, session.maxTurns - session.turns),
	})
	pushState(session)
	requestReply(session)
end

-- New cards: the caller says a tiny filler line and the AI writes three different ones. Free a couple of
-- times per call, then it uses a tip, then it costs a pick.
local function onRefresh(_: nil, player: Player)
	local session = talking(player)
	if not session or session.turns >= session.maxTurns then
		return
	end
	if session.freeRefreshes > 0 then
		session.freeRefreshes -= 1
	elseif not PerkService.UseTip(player) then
		session.turns += 1
		notice(player, "Out of free refreshes: that one cost a pick.")
	end
	session.cards = {}
	session.refreshing = true
	CoachService.Note(player, "Refreshes")
	table.insert(session.messages, {
		role = "user",
		content = `[Trust: {session.trust}/100]\n(They went quiet for a moment, thinking. Say a tiny filler line, like `
			.. "checking they're still there, and write three NEW cards, different from the last ones. trust_change 0.)",
	})
	requestReply(session)
end

-- The mini-game is over: pay out and let the caller say goodbye. raw = 0..1 performance.
function CallService.FinishGame(player: Player, raw: number, perfect: boolean)
	local session = sessions[player]
	local hook = session and session.hook
	if not session or session.ended or not hook or hook.done or hook.started == 0 then
		return
	end
	hook.done = true
	raw = math.clamp(if type(raw) == "number" and raw == raw then raw else 0, 0, 1)
	local score = if perfect and raw >= ScamConfig.PerfectAt
		then ScamConfig.PerfectScore
		else ScamConfig.MinScore + (1 - ScamConfig.MinScore) * raw
	local amount = ScamService.Payout(player, hook.app, hook.tier, session.lead.Persona.Budget, hook.matched, score,
		session.lead.DisplayName)
	session.paid = true
	CareerService.CompleteStep(player, "Paid")
	CareerService.Count(player, "Scams")
	CoachService.Note(player, "Paid")
	if score >= ScamConfig.PerfectScore then
		CoachService.Note(player, "Perfect")
	end
	pushState(session)
	table.insert(session.messages, { role = "user", content = CallerPrompt.scammed(amount, hook.app.Name) })
	requestReply(session)
end

local function onGameDone(request: any, player: Player)
	if type(request) ~= "table" then
		return
	end
	local session = sessions[player]
	if not session or request.CallId ~= session.id then
		return
	end
	CallService.FinishGame(player, tonumber(request.Score) or 0, request.Perfect == true)
end

-- ---------------------------------------------------------------------------
-- Prank calls
-- ---------------------------------------------------------------------------

-- Rings a waiting prank call if the player is at a desk with nothing else going on.
function CallService.TryPrank(player: Player)
	local queue = pranks[player]
	if not queue or #queue == 0 or not player.Parent then
		return
	end
	if sessions[player] or not DeskService.IsLoggedIn(player) then
		return -- on a call (or one just ended)
	end
	if not LeadService.IsReady(player) or not ClaudeClient.HasKey() then
		return
	end
	local prank = table.remove(queue, 1)
	local name = PRANK_NAMES[random:NextInteger(1, #PRANK_NAMES)]
	local lead = LeadService.Temporary(name, "Prank caller")
	startSession(player, lead, true, prank.from)
end

-- Prank calls waiting for a player who left their desk (or the game) go to someone else at a desk. If nobody
-- is, they keep waiting for this player (unless they left).
function requeuePranks(player: Player, leaving: boolean?)
	local waiting = pranks[player]
	if not waiting or #waiting == 0 then
		return
	end
	local others, fallback = {}, {}
	for _, other in Players:GetPlayers() do
		if other ~= player and DeskService.IsLoggedIn(other) then
			table.insert(fallback, other)
			if other.UserId ~= waiting[1].fromUserId then
				table.insert(others, other)
			end
		end
	end
	if #others == 0 then
		others = fallback
	end
	if #others == 0 and not leaving then
		return
	end
	pranks[player] = nil
	for _, prank in waiting do
		local target = if #others > 0 then others[random:NextInteger(1, #others)] else nil
		if target then
			CallService.QueuePrank(target, prank.from, prank.fromUserId)
		else
			warn(`[CallService] a prank call from {prank.from} had nobody left to ring`)
		end
	end
end

function CallService.QueuePrank(target: Player, fromName: string, fromUserId: number?)
	pranks[target] = pranks[target] or {}
	table.insert(pranks[target], { from = fromName, fromUserId = fromUserId or 0 })
	CallService.TryPrank(target)
end

-- ---------------------------------------------------------------------------
-- Save My Call
-- ---------------------------------------------------------------------------

function CallService.CanSave(player: Player): boolean
	local entry = failed[player]
	if not entry then
		return false
	end
	local lead = entry.session.lead
	local current = sessions[player]
	return LeadService.Find(player, lead.Id) == lead
		and lead.Status ~= Status.Scammed
		and lead.Status ~= Status.OnCall
		and not (current and not current.ended)
end

-- The caller of the last failed call rings straight back: same conversation, trust from before it went
-- wrong, and at least ShopConfig.SaveMinLines picks to go. Call only once the save is paid for.
function CallService.SaveCall(player: Player): (boolean, string)
	if not CallService.CanSave(player) then
		return false, "There's no call to save right now."
	end
	if not DeskService.IsLoggedIn(player) then
		return false, "Sit down and log in at a desk first."
	end
	local old = failed[player].session
	failed[player] = nil
	player:SetAttribute("SaveableCall", nil)
	local trust = math.clamp(math.max(old.trustBefore, CallConfig.StartTrust), CallConfig.HangUpTrust + 10, 100)
	local session: Session = table.clone(old)
	session.phase = Phase.Connected
	session.trust = trust
	session.trustBefore = trust
	session.outcome = Outcome.None
	session.messages = table.clone(old.messages)
	session.turns = math.min(old.turns, old.maxTurns - ShopConfig.SaveMinLines)
	session.thinking = false
	session.cards = {}
	session.refreshing = false
	session.hook = nil
	session.ended = false
	sessions[player] = session
	incomingToken[player] = (incomingToken[player] or 0) + 1
	LeadService.SetStatus(player, session.lead, Status.OnCall)
	table.insert(session.messages, { role = "user", content = CallerPrompt.resumed(trust) })
	pushState(session)
	sendFile(session)
	requestReply(session)
	return true, `{session.lead.DisplayName} is back on the line!`
end

local function onUseCallSave(_: nil, player: Player)
	if not CallService.CanSave(player) then
		notice(player, "There's no call to save right now.")
		return
	end
	if not DeskService.IsLoggedIn(player) then
		return
	end
	local used = PerkService.UseSave(player)
	if not used then
		notice(player, "You don't have any call saves. Get Save My Call at the store (or from the phone).")
		return
	end
	local ok, message = CallService.SaveCall(player)
	if not ok then
		PerkService.ReturnSave(player, used) -- give it back
	end
	notice(player, message)
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
	Call.packets.Pick.listen(onPick)
	Call.packets.Refresh.listen(onRefresh)
	Call.packets.GameDone.listen(onGameDone)
	Call.packets.HangUp.listen(onHangUp)
	Shop.packets.UseCallSave.listen(onUseCallSave)

	DeskService.OnLogin(function(player)
		EconomyService.StartClock()
		scheduleIncoming(player)
		task.delay(2, CallService.TryPrank, player)
	end)
	DeskService.OnLogout(function(player)
		incomingToken[player] = (incomingToken[player] or 0) + 1
		requeuePranks(player)
		local session = sessions[player]
		if session and not session.ended then
			endCall(session, Outcome.YouHungUp)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		local session = sessions[player]
		if session then
			session.ended = true
			if session.prank then
				LeadService.Release(session.lead)
			end
		end
		sessions[player] = nil
		incomingToken[player] = nil
		lastPick[player] = nil
		failed[player] = nil
		requeuePranks(player, true)
	end)
end

return CallService
