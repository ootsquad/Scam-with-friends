--[[
	PhoneApp (client)
	The Phone window: your leads on the left, the call on the right (caller card with the trust meter, the
	conversation, and the three choice cards under it).

	You never type. Each turn the caller's reply comes with three cards (lines you could say next); click one
	to say it, or press 1 / 2 / 3. Once trust is past the pay line the third slot holds a gold HOOK card, one
	per scam app you own (the › button cycles through them). A hook that lands opens the app's mini-game
	(ScamGameApp); when it's over the money shows up and the caller says goodbye. REFRESH (R) swaps the
	cards: free twice per call, then it uses an on-call tip, then it costs a pick. A short hint under the
	cards says what works on this caller (Settings: Hints on calls).

	After a caller hangs up on you, the idle screen offers to save the call (Save My Call).

	PhoneApp.Start(window)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CallConfig = require(Shared.Config.CallConfig)
local ScamConfig = require(Shared.Config.ScamConfig)
local Format = require(Shared.Util.Format)

local Client = script.Parent.Parent
local Ui = Client:WaitForChild("Ui")
local ButtonFx = require(Ui.ButtonFx)
local Motion = require(Ui.Motion)
local Notify = require(Ui.Notify)
local Theme = require(Ui.Theme)
local SettingsStore = require(Client:WaitForChild("Stores"):WaitForChild("SettingsStore"))

local ShopConfig = require(Shared.Config.ShopConfig)
local CallStore = require(script.Parent.CallStore)
local ShopStore = require(script.Parent.ShopStore)
local CallVoice = require(script.Parent.CallVoice)
local LeadAvatar = require(script.Parent.LeadAvatar)
local ScamGameApp = require(script.Parent.ScamGameApp)
local Sfx = require(script.Parent.Sfx)

local Phase = CallConfig.Phase
local Outcome = CallConfig.Outcome
local Status = CallConfig.LeadStatus
local LineStatus = CallConfig.LineStatus

local STATUS_LOOK = {
	[Status.Available] = { "AVAILABLE", "LeadAvailableBg", "GreenText" },
	[Status.OnCall] = { "ON CALL", "LeadOnCallBg", "LeadOnCallText" },
	[Status.Scammed] = { "GOT 'EM", "LeadScammedBg", "Yellow" },
	[Status.Blocked] = { "BLOCKED", "LeadBlockedBg", "LeadBlockedText" },
}

local CALL_LABEL = {
	[Status.Available] = "CALL",
	[Status.OnCall] = "BUSY",
	[Status.Scammed] = "DONE",
	[Status.Blocked] = "WAIT",
}

local OUTCOME_TEXT = {
	[Outcome.Paid] = { "THEY PAID UP", "GreenText" },
	[Outcome.TheyHungUp] = { "THEY HUNG UP", "TrustLow" },
	[Outcome.NoAnswer] = { "NO ANSWER", "DarkMuted" },
	[Outcome.Missed] = { "MISSED CALL", "DarkMuted" },
	[Outcome.Declined] = { "DECLINED", "DarkMuted" },
	[Outcome.YouHungUp] = { "CALL ENDED", "DarkMuted" },
	[Outcome.LineDown] = { "LINE DROPPED", "TrustLow" },
	[Outcome.None] = { "CALL ENDED", "DarkMuted" },
}

local TONE_COLOR = {
	Friendly = Theme.ToneFriendly,
	Story = Theme.ToneStory,
	Push = Theme.TonePush,
	["Small talk"] = Theme.ToneSmallTalk,
	Hook = Theme.Gold,
}

-- Chat bubbles are sized from the measured text (Roblox's AutomaticSize collapses wrapped text to nothing).
local BUBBLE_MAX_WIDTH = 320
local BUBBLE_PAD_X = 28 -- matches the bubble's UIPadding (14 left + 14 right)
local BUBBLE_PAD_Y = 20 -- 10 top + 10 bottom
local CAPTION_HEIGHT = 18 -- the note under one of your lines ("The hook landed!")

-- Notes under your own lines, by YourLine.Status.
local STATUS_CAPTION = {
	[LineStatus.HookLanded] = { "The hook landed!", "GreenText" },
	[LineStatus.HookMissed] = { "They didn't fall for it.", "TrustLow" },
}

local PICK_KEYS = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.KeypadOne] = 1,
	[Enum.KeyCode.KeypadTwo] = 2,
	[Enum.KeyCode.KeypadThree] = 3,
	[Enum.KeyCode.DPadUp] = 1,
	[Enum.KeyCode.DPadLeft] = 2,
	[Enum.KeyCode.DPadDown] = 3,
}

local PhoneApp = {}

local player = Players.LocalPlayer

local ui: any
local window: Frame
local rowLeads: { [number]: number } = {} -- slot -> lead id currently drawn
local shownCallId = 0
local connectedAt = 0
local order = 0
local lastPaid = 0
local payAt = 70 -- the current caller's pay line (it depends on how sharp they are)
local normals: { any } = {} -- the cards on screen that aren't hooks
local hooks: { any } = {} -- the hook cards (one per owned app)
local hookIndex = 1
local freeLeft = ScamConfig.FreeRefreshes

local function firstName(name: string): string
	return string.match(name, "^(%S+)") or name
end

local money = Format.money

local function trustColor(trust: number): Color3
	if trust >= payAt then
		return Theme.TrustHigh
	elseif trust >= 40 then
		return Theme.TrustMid
	end
	return Theme.TrustLow
end

-- ---------------------------------------------------------------------------
-- Transcript
-- ---------------------------------------------------------------------------

local function scrollToBottom()
	task.defer(function()
		local transcript = ui.transcript
		transcript.CanvasPosition = Vector2.new(0, 1e6)
	end)
end

local function clearTranscript()
	for _, child in ui.transcript:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	order = 0
end

-- Width and height the text needs inside a bubble, wrapping at the bubble's max width.
local function measure(label: TextLabel, text: string): (number, number)
	local inner = BUBBLE_MAX_WIDTH - BUBBLE_PAD_X
	local ok, bounds = pcall(function()
		local params = Instance.new("GetTextBoundsParams")
		params.Text = text
		params.Font = label.FontFace
		params.Size = label.TextSize
		params.Width = inner
		return TextService:GetTextBoundsAsync(params)
	end)
	if ok and typeof(bounds) == "Vector2" and bounds.X > 0 and bounds.Y > 0 then
		return math.min(math.ceil(bounds.X) + 2, inner), math.ceil(bounds.Y)
	end
	-- Rough estimate if measuring isn't available.
	local charWidth = label.TextSize * 0.52
	local lines = math.max(1, math.ceil(#text * charWidth / inner))
	return math.min(inner, math.ceil(#text * charWidth) + 2), math.ceil(lines * label.TextSize * 1.25)
end

local function addBubble(text: string, mine: boolean, status: number?)
	order += 1
	local row = (if mine then ui.templates.YouTemplate else ui.templates.ThemTemplate):Clone()
	local label = row.Bubble :: TextLabel
	row.Name = if mine then "You" else "Them"
	label.Text = text
	label.TextWrapped = true
	label.AutomaticSize = Enum.AutomaticSize.None
	row.AutomaticSize = Enum.AutomaticSize.None
	row.LayoutOrder = order
	row.Visible = true
	row.Parent = ui.transcript

	local width, height = measure(label, text)
	label.Size = UDim2.fromOffset(width + BUBBLE_PAD_X, height + BUBBLE_PAD_Y)
	local rowHeight = height + BUBBLE_PAD_Y
	local caption = row:FindFirstChild("Caption") :: TextLabel?
	local note = if mine and status then STATUS_CAPTION[status] else nil
	if caption then
		caption.Visible = note ~= nil
		if note then
			caption.Text = note[1]
			caption.TextColor3 = Theme[note[2]]
			rowHeight += CAPTION_HEIGHT
		end
	end
	if status == LineStatus.HookLanded or status == LineStatus.HookMissed then
		label.BackgroundColor3 = if status == LineStatus.HookLanded then Theme.Gold else Theme.PhoneHead
		label.TextColor3 = if status == LineStatus.HookLanded then Theme.NativeText else Theme.White
	end
	row.Size = UDim2.new(1, 0, 0, rowHeight)
	scrollToBottom()
end

local function addSystem(text: string)
	order += 1
	local row = ui.templates.SystemTemplate:Clone()
	row.Name = "System"
	row.Label.Text = text
	row.LayoutOrder = order
	row.Visible = true
	row.Parent = ui.transcript
	scrollToBottom()
end

-- ---------------------------------------------------------------------------
-- Leads
-- ---------------------------------------------------------------------------

local function renderLeads()
	local leads = CallStore.Leads
	local busy = CallStore.State ~= nil and CallStore.State.Phase ~= Phase.Ended
	local open = 0
	for _, lead in leads do
		if lead.Status == Status.Available then
			open += 1
		end
	end
	local hint = ui.leads:FindFirstChild("Hint")
	if hint then
		hint.Text = if #leads == 0 then "loading…" else `{open} of {#leads} open`
	end
	for slot = 1, CallConfig.LeadsPerPlayer do
		local row = ui.leads:FindFirstChild(`Lead{slot}`)
		if row then
			local lead = leads[slot]
			row.Visible = lead ~= nil
			if lead then
				row.DisplayName.Text = lead.DisplayName
				row.Tag.Text = lead.Tag
				local look = STATUS_LOOK[lead.Status] or STATUS_LOOK[Status.Available]
				row.Status.Text = look[1]
				row.Status.BackgroundColor3 = Theme[look[2]]
				row.Status.TextColor3 = Theme[look[3]]
				local canCall = lead.Status == Status.Available and not busy
				row.CallButton.Text = if lead.Status == Status.Available then "CALL" else CALL_LABEL[lead.Status] or "WAIT"
				row.CallButton.BackgroundColor3 = if canCall then Theme.Green else Theme.PhoneHead
				row.CallButton.TextColor3 = if canCall then Theme.White else Theme.DarkFaint
				if rowLeads[slot] ~= lead.Id then
					rowLeads[slot] = lead.Id
					LeadAvatar.render(row.Portrait.View, lead)
				end
			end
		end
	end
end

local dialing = false

local function callLead(slot: number)
	local lead = CallStore.Leads[slot]
	if not lead or dialing then
		return
	end
	if CallStore.State and CallStore.State.Phase ~= Phase.Ended then
		Notify.show("Phone", "Finish your current call first.", Theme.Yellow)
		return
	end
	if lead.Status ~= Status.Available then
		local reasons = {
			[Status.OnCall] = `{firstName(lead.DisplayName)} is on another call.`,
			[Status.Scammed] = `You already got {firstName(lead.DisplayName)}. A new lead shows up soon.`,
			[Status.Blocked] = `{firstName(lead.DisplayName)} won't pick up right now.`,
		}
		Notify.show("Phone", reasons[lead.Status] or "They can't take a call right now.", Theme.Yellow)
		return
	end
	dialing = true
	local result = CallStore.StartCall(lead.Id)
	dialing = false
	if not result.Ok then
		Notify.show("Phone", result.Message, Theme.Red)
	end
end

-- ---------------------------------------------------------------------------
-- Call view
-- ---------------------------------------------------------------------------

local function renderTrust(trust: number)
	local panel = ui.card.Trust
	local mark = panel.Bar:FindFirstChild("PayMark")
	if mark then
		mark.Position = UDim2.new(math.clamp(payAt / 100, 0, 1), -1, 0, 0)
	end
	local color = trustColor(trust)
	panel.Value.Text = `{math.floor(trust)}%`
	panel.Value.TextColor3 = color
	panel.Bar.Fill.BackgroundColor3 = color
	Motion.tween(panel.Bar.Fill, Motion.MEDIUM, { Size = UDim2.fromScale(math.clamp(trust / 100, 0, 1), 1) })
end

local function showDelta(delta: number)
	local label = ui.card.Trust.Delta
	if delta == 0 then
		label.Text = ""
		return
	end
	label.Text = if delta > 0 then `+{delta} trust` else `{delta} trust`
	label.TextColor3 = if delta > 0 then Theme.GreenText else Theme.TrustLow
	local text = label.Text
	task.delay(3, function()
		if label.Text == text then
			label.Text = ""
		end
	end)
end

local function updateStatusStrip(state: any)
	local strip = ui.card.Status
	if state.Phase == Phase.Ringing then
		strip.Text = "CALLING..."
		strip.TextColor3 = Theme.DarkMuted
	elseif state.Phase == Phase.Incoming then
		strip.Text = "INCOMING CALL"
		strip.TextColor3 = Theme.GreenText
	elseif state.Phase == Phase.Connected then
		local elapsed = math.floor(math.max(0, os.clock() - connectedAt))
		strip.Text = string.format("ON CALL  %02d:%02d", elapsed // 60, elapsed % 60)
		strip.TextColor3 = Theme.GreenText
	else
		local outcome = OUTCOME_TEXT[state.Outcome] or OUTCOME_TEXT[Outcome.None]
		strip.Text = outcome[1]
		strip.TextColor3 = Theme[outcome[2]]
	end
end

-- ---------------------------------------------------------------------------
-- Cards
-- ---------------------------------------------------------------------------

local function paintCard(slot: number, card: any?)
	local button = ui.cards:FindFirstChild(`Card{slot}`)
	if not button then
		return
	end
	button.Visible = card ~= nil
	if not card then
		return
	end
	local hook = card.App ~= ""
	button.Text = card.Text
	button:SetAttribute("CardId", card.Id)
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = if hook then Theme.Gold else Theme.PhoneLine
		stroke.Thickness = if hook then 2 else 1
	end
	local tag = button:FindFirstChild("Tag")
	if tag then
		tag.Text = string.upper(card.Tone)
		tag.BackgroundColor3 = TONE_COLOR[card.Tone] or Theme.ToneFriendly
		tag.TextColor3 = if hook then Theme.NativeText else Theme.White
	end
	local cycle = button:FindFirstChild("CycleButton")
	if cycle then
		cycle.Visible = hook and #hooks > 1
		if cycle.Visible then
			cycle.Text = `{hookIndex}/{#hooks} ›`
		end
	end
end

local function paintCards()
	for slot = 1, ScamConfig.Cards do
		local card
		if slot == ScamConfig.Cards and #hooks > 0 then
			card = hooks[hookIndex]
		else
			card = normals[slot]
		end
		paintCard(slot, card)
	end
end

local function hideCards()
	normals, hooks = {}, {}
	hookIndex = 1
	ui.cards.Visible = false
end

local function showCards(cards: any)
	if not CallStore.IsConnected() then
		return
	end
	normals, hooks = {}, {}
	for _, card in cards.Options do
		table.insert(if card.App ~= "" then hooks else normals, card)
	end
	hookIndex = 1
	freeLeft = cards.FreeLeft
	paintCards()
	ui.cards.Visible = true
	local hint = ui.hint
	local wanted = SettingsStore.Settings.CallHints ~= false and cards.Hint ~= ""
	hint.Visible = wanted
	hint.Hint.Text = cards.Hint
	hint.Hint.TextColor3 = if #hooks > 0 then Theme.Gold else Theme.Yellow
	PhoneApp.renderTalk()
end

local function pick(slot: number)
	local button = ui.cards:FindFirstChild(`Card{slot}`)
	local id = button and button.Visible and button:GetAttribute("CardId")
	if type(id) == "number" and CallStore.IsConnected() and ui.cards.Visible then
		Sfx.Play("Click")
		hideCards()
		CallStore.Pick(id)
	end
end

local function cycleHook()
	if #hooks > 1 then
		hookIndex = hookIndex % #hooks + 1
		paintCards()
	end
end

local function refresh()
	if not CallStore.IsConnected() or not ui.cards.Visible then
		return
	end
	local state = CallStore.State
	if freeLeft <= 0 and ShopStore.TipsLeft() <= 0 and state and (state.LinesLeft or 0) <= 1 then
		Notify.show("Phone", "No free refreshes and no picks to spare. Pick a card.", Theme.Yellow)
		return
	end
	Sfx.Play("Click")
	hideCards()
	CallStore.Refresh()
end

-- The refresh button's badge and the picks left.
function PhoneApp.renderTalk()
	local state = CallStore.State
	local connected = state ~= nil and state.Phase == Phase.Connected
	local talk = ui.talk
	local count = talk.RefreshButton:FindFirstChild("Count")
	if count then
		local tips = ShopStore.TipsLeft()
		if not connected then
			count.Text = ""
		elseif freeLeft > 0 then
			count.Text = `{freeLeft} FREE`
			count.BackgroundColor3 = Theme.Yellow
		elseif tips > 0 then
			count.Text = `{tips} {if tips == 1 then "TIP" else "TIPS"}`
			count.BackgroundColor3 = Theme.Yellow
		else
			count.Text = "1 PICK"
			count.BackgroundColor3 = Theme.Red
		end
		count.TextColor3 = if count.BackgroundColor3 == Theme.Red then Theme.White else Theme.NativeText
		count.Visible = count.Text ~= ""
	end
	local lines = talk:FindFirstChild("Lines")
	if lines then
		local left = if state then (state.LinesLeft or CallConfig.MaxTurns) else 0
		lines.Text = if connected then `{left} {if left == 1 then "PICK" else "PICKS"} LEFT` else ""
		lines.TextColor3 = if left <= 3 then Theme.TrustLow else Theme.DarkMuted
	end
	talk.RefreshButton.BackgroundColor3 = if connected and ui.cards.Visible then Theme.PhoneHead else Theme.PhonePanel
	local thinking = ui.thinking
	if state and connected and state.Thinking then
		thinking.Text = `{firstName(state.Lead.DisplayName)} is thinking...`
	elseif state and connected and state.Hook ~= "" then
		thinking.Text = "The hook landed. Take the money!"
	else
		thinking.Text = ""
	end
end

-- The caller-voice button: a grey circle with a white icon; dark with a faded icon when voices are off.
local ICON_BUTTON = Color3.fromHex("#3A404C")

local function paintVoiceButton()
	local talk = ui.talk
	talk.VoiceButton.BackgroundColor3 = if CallVoice.VoiceEnabled then ICON_BUTTON else Theme.PhoneHead
	local voiceIcon = talk.VoiceButton:FindFirstChild("Icon")
	if voiceIcon then
		voiceIcon.ImageTransparency = if CallVoice.VoiceEnabled then 0 else 0.6
	end
end

-- "Save the call" on the idle screen after a caller hung up on you.
local function renderSave()
	local bar = ui.idle:FindFirstChild("SaveCall")
	if not bar then
		return
	end
	local name = player:GetAttribute("SaveableCall")
	local idle = CallStore.State == nil
	bar.Visible = idle and type(name) == "string" and name ~= ""
	if not bar.Visible then
		return
	end
	bar.Label.Text = `Lost the call with {name}.`
	local saves = ShopStore.SavesLeft()
	if saves > 0 then
		bar.SaveButton.Text = `SAVE CALL ({saves} {if saves == 1 then "SAVE" else "SAVES"} LEFT)`
	else
		local item = ShopConfig.Product("SaveMyCall")
		local price = item and ShopStore.Price(item)
		bar.SaveButton.Text = if price then `SAVE CALL · R$ {price}` else "SAVE CALL"
	end
end

local function saveCall()
	if ShopStore.SavesLeft() > 0 then
		ShopStore.UseCallSave()
	else
		ShopStore.BuyProduct("SaveMyCall")
	end
end

local function renderCall(state: any, previous: any)
	if not state then
		ui.idle.Visible = true
		ui.call.Visible = false
		renderLeads()
		return
	end
	ui.idle.Visible = false
	ui.call.Visible = true

	local card = ui.card
	if state.CallId ~= shownCallId then
		shownCallId = state.CallId
		CallVoice.StopSpeaking() -- the last caller's backlog doesn't spill into this call
		lastPaid = 0
		freeLeft = ScamConfig.FreeRefreshes
		clearTranscript()
		hideCards()
		ui.hint.Visible = false
		LeadAvatar.render(card.Portrait.View, state.Lead)
		card.NameBar.DisplayName.Text = string.upper(state.Lead.DisplayName)
		card.Username.Text = `@{state.Lead.Username}`
		card.Tag.Text = string.upper(state.Lead.Tag)
		card.Trust.Delta.Text = ""
		addSystem(if state.Phase == Phase.Incoming
			then `Incoming call from {state.Lead.DisplayName}`
			else `Calling {state.Lead.DisplayName}...`)
	end
	local wasConnected = previous ~= nil and previous.CallId == state.CallId and previous.Phase == Phase.Connected
	if state.Phase == Phase.Connected and not wasConnected then
		connectedAt = os.clock()
		addSystem(`Connected · {os.date("%I:%M %p")}`)
	end
	local justEnded = state.Phase == Phase.Ended
		and not (previous ~= nil and previous.CallId == state.CallId and previous.Phase == Phase.Ended)
	if justEnded then
		addSystem((OUTCOME_TEXT[state.Outcome] or OUTCOME_TEXT[Outcome.None])[1])
		hideCards()
		ui.hint.Visible = false
	end
	if state.Thinking then
		hideCards()
	end

	payAt = state.PayAt or payAt
	renderTrust(state.Trust)
	local lines = card.Trust:FindFirstChild("Lines")
	if lines then
		local left = state.LinesLeft or CallConfig.MaxTurns
		lines.Visible = state.Phase == Phase.Connected
		lines.Text = `{left} {if left == 1 then "PICK" else "PICKS"} LEFT`
		lines.TextColor3 = if left <= 3 then Theme.TrustLow else Theme.DarkMuted
	end
	card.PaidBadge.Visible = state.Paid
	if state.Paid and lastPaid > 0 then
		card.PaidBadge.Text = `PAID {money(lastPaid)}`
	elseif state.Paid then
		card.PaidBadge.Text = "PAID"
	end
	card.HangUpButton.Visible = state.Phase == Phase.Ringing or state.Phase == Phase.Connected
	ui.answer.Visible = state.Phase == Phase.Incoming
	ui.talk.Visible = state.Phase ~= Phase.Incoming
	updateStatusStrip(state)
	PhoneApp.renderTalk()
	renderLeads()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function PhoneApp.Start(phoneWindow: Frame)
	window = phoneWindow
	local body = window:WaitForChild("Body")
	local call = body:WaitForChild("CallView")
	local convo = call:WaitForChild("Conversation")
	ui = {
		leads = body:WaitForChild("Leads"),
		idle = body:WaitForChild("Idle"),
		call = call,
		card = call:WaitForChild("CallerCard"),
		transcript = convo:WaitForChild("Transcript"),
		templates = convo:WaitForChild("Templates"),
		thinking = convo:WaitForChild("Thinking"),
		hint = convo:WaitForChild("HintStrip"),
		cards = convo:WaitForChild("Cards"),
		talk = convo:WaitForChild("Talk"),
		answer = convo:WaitForChild("Answer"),
	}
	ui.cards.Visible = false
	ui.hint.Visible = false
	ui.card.Status.Text = ""

	-- If the server can't reach Claude (no key, key rejected, HTTP off), say so where calls start.
	local defaultHint = ui.idle.Hint.Text
	local function renderPhoneLine()
		local status = ReplicatedStorage:GetAttribute("PhoneLine")
		local down = type(status) == "string" and status ~= "ok"
		ui.idle.Heading.Text = if down then "Phone line down" else "Nobody on the line"
		ui.idle.Hint.Text = if down then status else defaultHint
		ui.idle.Hint.TextColor3 = if down then Theme.LeadBlockedText else Theme.DarkMuted
	end
	ReplicatedStorage:GetAttributeChangedSignal("PhoneLine"):Connect(renderPhoneLine)
	renderPhoneLine()

	for slot = 1, CallConfig.LeadsPerPlayer do
		local row = ui.leads:FindFirstChild(`Lead{slot}`)
		if row then
			ButtonFx.attach(row.CallButton, 1.04, 0.95)
			row.CallButton.MouseButton1Click:Connect(function()
				callLead(slot)
			end)
		else
			warn(`[PhoneApp] GUI has no Lead{slot}; CallConfig.LeadsPerPlayer and the GUI are out of sync`)
		end
	end

	ButtonFx.attach(ui.card.HangUpButton, 1.03, 0.96)
	ui.card.HangUpButton.MouseButton1Click:Connect(CallStore.HangUp)
	ButtonFx.attach(ui.answer.AcceptButton, 1.03, 0.96)
	ui.answer.AcceptButton.MouseButton1Click:Connect(function()
		CallStore.Answer(true)
	end)
	ButtonFx.attach(ui.answer.DeclineButton, 1.03, 0.96)
	ui.answer.DeclineButton.MouseButton1Click:Connect(function()
		CallStore.Answer(false)
	end)

	-- The cards
	for slot = 1, ScamConfig.Cards do
		local button = ui.cards:FindFirstChild(`Card{slot}`)
		if button then
			ButtonFx.attach(button, 1.02, 0.98)
			button.MouseButton1Click:Connect(function()
				pick(slot)
			end)
			local cycle = button:FindFirstChild("CycleButton")
			if cycle then
				cycle.MouseButton1Click:Connect(cycleHook)
			end
		end
	end
	local talk = ui.talk
	ButtonFx.attach(talk.RefreshButton, 1.04, 0.95)
	talk.RefreshButton.MouseButton1Click:Connect(refresh)
	ButtonFx.attach(talk.VoiceButton, 1.06, 0.94)
	talk.VoiceButton.MouseButton1Click:Connect(function()
		CallVoice.SetVoiceEnabled(not CallVoice.VoiceEnabled)
		Notify.show("Phone", if CallVoice.VoiceEnabled then "Caller voice on." else "Caller voice off. Lines still show as text.")
	end)
	CallVoice.Changed:Connect(paintVoiceButton)
	paintVoiceButton()
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or not window.Visible or not CallStore.IsConnected() or ScamGameApp.IsOpen() then
			return
		end
		local slot = PICK_KEYS[input.KeyCode]
		if slot then
			pick(slot)
		elseif input.KeyCode == Enum.KeyCode.R or input.KeyCode == Enum.KeyCode.ButtonY then
			refresh()
		elseif input.KeyCode == Enum.KeyCode.Tab or input.KeyCode == Enum.KeyCode.DPadRight then
			cycleHook()
		end
	end)
	SettingsStore.Changed:Connect(function(settings)
		if ui.hint.Hint.Text ~= "" and ui.cards.Visible then
			ui.hint.Visible = settings.CallHints ~= false
		end
	end)

	-- Save My Call
	local saveBar = ui.idle:FindFirstChild("SaveCall")
	if saveBar then
		saveBar.Visible = false
		ButtonFx.attach(saveBar.SaveButton, 1.03, 0.96)
		saveBar.SaveButton.MouseButton1Click:Connect(saveCall)
	end
	ShopStore.Changed:Connect(function()
		PhoneApp.renderTalk()
		renderSave()
	end)
	ShopStore.PricesLoaded:Connect(renderSave)
	CallStore.Changed:Connect(renderSave)
	renderSave()

	CallStore.LeadsChanged:Connect(renderLeads)
	CallStore.Changed:Connect(renderCall)
	CallStore.Cards:Connect(showCards)
	CallStore.Line:Connect(function(line)
		addBubble(line.Text, false)
		renderTrust(line.Trust)
		showDelta(line.Delta)
		local state = CallStore.State
		if state then
			-- Don't read out "(The line crackles.)" or words the filter hid.
			local speech = string.gsub(line.Text, "%b()", " ")
			speech = string.gsub(speech, "#+", " ")
			speech = string.gsub(string.gsub(speech, "%s+", " "), "^%s*(.-)%s*$", "%1")
			if string.find(speech, "%w") then
				CallVoice.Speak(speech, state.VoiceId)
			end
		end
	end)
	CallStore.YourLine:Connect(function(line)
		addBubble(line.Text, true, line.Status)
	end)
	CallStore.Game:Connect(function(game)
		ScamGameApp.Play(game)
	end)
	CallStore.Payout:Connect(function(payout)
		lastPaid = payout.Amount
		addSystem(`{firstName(payout.LeadName)} paid {money(payout.Amount)} · {payout.Label}`)
		local state = CallStore.State
		if state then
			ui.card.PaidBadge.Visible = true
			ui.card.PaidBadge.Text = `PAID {money(payout.Amount)}`
		end
	end)

	-- Call timer
	task.spawn(function()
		while window.Parent do
			local state = CallStore.State
			if state and state.Phase == Phase.Connected then
				updateStatusStrip(state)
			end
			task.wait(0.5)
		end
	end)

	renderLeads()
	renderCall(CallStore.State, nil)
end

PhoneApp.money = money
PhoneApp.firstName = firstName

return PhoneApp
