--[[
	PhoneApp (client)
	The Phone window: your leads on the left, the call on the right (caller card with the trust meter, the
	conversation, and a talk bar with mic / text / send / caller voice).

	PhoneApp.Start(window)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CallConfig = require(Shared.Config.CallConfig)

local Client = script.Parent.Parent
local Ui = Client:WaitForChild("Ui")
local ButtonFx = require(Ui.ButtonFx)
local Motion = require(Ui.Motion)
local Notify = require(Ui.Notify)
local Theme = require(Ui.Theme)

local CallStore = require(script.Parent.CallStore)
local CallVoice = require(script.Parent.CallVoice)
local LeadAvatar = require(script.Parent.LeadAvatar)

local Phase = CallConfig.Phase
local Outcome = CallConfig.Outcome
local Status = CallConfig.LeadStatus

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

local PhoneApp = {}

local ui: any
local rowLeads: { [number]: number } = {} -- slot -> lead id currently drawn
local shownCallId = 0
local connectedAt = 0
local order = 0
local lastPaid = 0
local sending = false

local function firstName(name: string): string
	return string.match(name, "^(%S+)") or name
end

local function money(amount: number): string
	local text = tostring(math.floor(amount))
	while true do
		local replaced, count = string.gsub(text, "^(%d+)(%d%d%d)", "%1,%2")
		text = replaced
		if count == 0 then
			break
		end
	end
	return "$" .. text
end

local function trustColor(trust: number): Color3
	if trust >= CallConfig.PayTrust then
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

local function addBubble(text: string, mine: boolean)
	order += 1
	local row = (if mine then ui.templates.YouTemplate else ui.templates.ThemTemplate):Clone()
	row.Name = if mine then "You" else "Them"
	row.Bubble.Text = text
	row.LayoutOrder = order
	row.Visible = true
	row.Parent = ui.transcript
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

local function callLead(slot: number)
	local lead = CallStore.Leads[slot]
	if not lead then
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
	local result = CallStore.StartCall(lead.Id)
	if not result.Ok then
		Notify.show("Phone", result.Message, Theme.Red)
	end
end

-- ---------------------------------------------------------------------------
-- Call view
-- ---------------------------------------------------------------------------

local function renderTrust(trust: number)
	local panel = ui.card.Trust
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

local function updateTalkBar(state: any)
	local connected = state ~= nil and state.Phase == Phase.Connected
	local talk = ui.talk
	talk.InputBox.TextEditable = connected
	talk.InputBox.PlaceholderText = if connected then "Say something..." else "Waiting for the call..."
	talk.SendButton.BackgroundColor3 = if connected then Theme.Accent else Theme.PhoneHead
	talk.SendButton.TextColor3 = if connected then Theme.White else Theme.DarkFaint

	local thinking = ui.thinking
	if state and connected and state.Thinking then
		thinking.Text = `{firstName(state.Lead.DisplayName)} is thinking...`
	elseif connected and CallVoice.MicOn then
		thinking.Text = if CallVoice.Hearing then "Hearing you..." else "Listening. Just talk."
	else
		thinking.Text = ""
	end
end

local function paintVoiceButtons()
	local talk = ui.talk
	local micOn = CallVoice.MicOn
	talk.MicButton.BackgroundColor3 = if micOn then (if CallVoice.Hearing then Theme.TrustHigh else Theme.Accent) else Theme.PhoneHead
	for _, piece in talk.VoiceButton:GetChildren() do
		if piece:IsA("Frame") then
			local stroke = piece:FindFirstChildOfClass("UIStroke")
			local color = if CallVoice.VoiceEnabled then Theme.DarkText else Theme.DarkFaint
			if stroke then
				stroke.Color = color
			else
				piece.BackgroundColor3 = color
			end
		end
	end
	talk.VoiceButton.BackgroundColor3 = if CallVoice.VoiceEnabled then Theme.PhoneHead else Theme.LeadBlockedBg
	updateTalkBar(CallStore.State)
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
		lastPaid = 0
		clearTranscript()
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
		if CallVoice.MicOn then
			CallVoice.SetMic(false)
		end
	end

	renderTrust(state.Trust)
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
	updateTalkBar(state)
	renderLeads()
end

local function send()
	if sending then
		return
	end
	local box = ui.talk.InputBox
	local text = box.Text
	if not CallStore.IsConnected() or not string.find(text, "%S") then
		return
	end
	sending = true
	box.Text = ""
	CallStore.Say(text)
	sending = false
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function PhoneApp.Start(window: Frame)
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
		talk = convo:WaitForChild("Talk"),
		answer = convo:WaitForChild("Answer"),
	}
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

	local talk = ui.talk
	ButtonFx.attach(talk.SendButton, 1.04, 0.95)
	talk.SendButton.MouseButton1Click:Connect(send)
	talk.InputBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			send()
			if CallStore.IsConnected() then
				task.defer(function()
					talk.InputBox:CaptureFocus()
				end)
			end
		end
	end)
	ButtonFx.attach(talk.MicButton, 1.06, 0.94)
	talk.MicButton.MouseButton1Click:Connect(function()
		if not CallVoice.MicOn and not CallStore.IsConnected() then
			Notify.show("Phone", "Turn the mic on once the call connects.", Theme.Yellow)
			return
		end
		local ok, message = CallVoice.SetMic(not CallVoice.MicOn)
		if not ok and message then
			Notify.show("Voice", message, Theme.Yellow)
		end
	end)
	ButtonFx.attach(talk.VoiceButton, 1.06, 0.94)
	talk.VoiceButton.MouseButton1Click:Connect(function()
		CallVoice.SetVoiceEnabled(not CallVoice.VoiceEnabled)
		Notify.show("Phone", if CallVoice.VoiceEnabled then "Caller voice on." else "Caller voice off. Lines still show as text.")
	end)
	CallVoice.Changed:Connect(paintVoiceButtons)
	CallVoice.Heard:Connect(function(text)
		CallStore.Say(text)
	end)
	paintVoiceButtons()

	CallStore.LeadsChanged:Connect(renderLeads)
	CallStore.Changed:Connect(renderCall)
	CallStore.Line:Connect(function(line)
		addBubble(line.Text, false)
		renderTrust(line.Trust)
		showDelta(line.Delta)
		local state = CallStore.State
		if state then
			CallVoice.Speak(line.Text, state.VoiceId)
		end
	end)
	CallStore.YourLine:Connect(function(line)
		addBubble(line.Text, true)
	end)
	CallStore.Payout:Connect(function(payout)
		lastPaid = payout.Amount
		addSystem(`{firstName(payout.LeadName)} paid {money(payout.Amount)} · {string.lower(payout.Label)}`)
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
