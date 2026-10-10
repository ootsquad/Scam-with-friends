--[[
	PhoneApp (client)
	The Phone window: your leads on the left, the call on the right (caller card with the trust meter, the
	conversation, and a talk bar with mic / text / ideas / send / caller voice).

	What the mic hears goes in the text box first (Settings: "Check mic lines"), so you can fix it before the
	caller hears it; press Send or Enter. Lines Roblox hides aren't sent and don't use a line, and three
	ready-made lines (Ideas) pop up so the call can go on. Ideas also work any time from the IDEAS button, and
	change with what the caller just said. Asking uses an on-call tip (the number on the button): 3 free per
	shift, then Extra Tips (Robux). Out of tips, the button offers Extra Tips.

	After a caller hangs up on you, the idle screen offers to save the call (Save My Call).

	PhoneApp.Start(window)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CallConfig = require(Shared.Config.CallConfig)
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

local Phase = CallConfig.Phase
local Outcome = CallConfig.Outcome
local Status = CallConfig.LeadStatus
local LineStatus = CallConfig.LineStatus
local IdeaReason = CallConfig.IdeaReason

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

-- Chat bubbles are sized from the measured text (Roblox's AutomaticSize collapses wrapped text to nothing).
local BUBBLE_MAX_WIDTH = 320
local BUBBLE_PAD_X = 28 -- matches the bubble's UIPadding (14 left + 14 right)
local BUBBLE_PAD_Y = 20 -- 10 top + 10 bottom
local CAPTION_HEIGHT = 18 -- the note under one of your lines ("Not sent", "Idea")

-- Notes under your own lines, by YourLine.Status.
local STATUS_CAPTION = {
	[LineStatus.Hidden] = { "Not sent: Roblox hid this line. No line used.", "TrustLow" },
	[LineStatus.PartlyHidden] = { "Some words were hidden, so it's free.", "TrustMid" },
	[LineStatus.Idea] = { "Idea", "DarkMuted" },
}

local PhoneApp = {}

local player = Players.LocalPlayer

local ui: any
local rowLeads: { [number]: number } = {} -- slot -> lead id currently drawn
local shownCallId = 0
local connectedAt = 0
local order = 0
local lastPaid = 0
local sending = false
local payAt = 70 -- the current caller's pay line (it depends on how sharp they are)
local micDraft: string? = nil -- what the mic heard, waiting in the text box to be checked and sent
local ideasOpen = false
local ideasWanted = false -- asked for ideas and still want them (false once closed, used or a line is sent)

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
	if status == LineStatus.Hidden then
		label.BackgroundColor3 = Theme.PhoneHead -- greyed out: it never reached the caller
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

local function updateTalkBar(state: any)
	local connected = state ~= nil and state.Phase == Phase.Connected
	local talk = ui.talk
	talk.InputBox.TextEditable = connected
	talk.InputBox.PlaceholderText = if connected then "Say something..." else "Waiting for the call..."
	talk.SendButton.BackgroundColor3 = if connected then Theme.Accent else Theme.PhoneHead
	talk.SendButton.TextColor3 = if connected then Theme.White else Theme.DarkFaint

	local thinking = ui.thinking
	local drafting = connected and micDraft ~= nil and talk.InputBox.Text ~= ""
	local stroke = talk.InputBox:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = if drafting then Theme.Yellow else Theme.PhoneLine
	end
	if state and connected and state.Thinking then
		thinking.Text = `{firstName(state.Lead.DisplayName)} is thinking...`
			.. (if drafting then " Check your mic line, then Send." else "")
	elseif drafting then
		thinking.Text = "Your mic heard this. Fix it if it's wrong, then press Send or Enter."
	elseif connected and CallVoice.MicOn then
		thinking.Text = if CallVoice.Hearing then "Hearing you..." else "Listening. Just talk."
	else
		thinking.Text = ""
	end
end

-- The mic and caller-voice buttons are light circles with icon images: blue (green while it hears you) when
-- the mic is on, faded when the caller's voice is off.
local ICON_BUTTON = Color3.fromHex("#D9DCE2")
local VOICE_OFF = Color3.fromHex("#8B9099")

local function paintVoiceButtons()
	local talk = ui.talk
	local micOn = CallVoice.MicOn
	talk.MicButton.BackgroundColor3 = if micOn then (if CallVoice.Hearing then Theme.TrustHigh else Theme.Accent) else ICON_BUTTON
	talk.VoiceButton.BackgroundColor3 = if CallVoice.VoiceEnabled then ICON_BUTTON else VOICE_OFF
	local voiceIcon = talk.VoiceButton:FindFirstChild("Icon")
	if voiceIcon then
		voiceIcon.ImageTransparency = if CallVoice.VoiceEnabled then 0 else 0.55
	end
	updateTalkBar(CallStore.State)
end

-- ---------------------------------------------------------------------------
-- Ideas (ready-made lines)
-- ---------------------------------------------------------------------------

local function closeIdeas()
	ideasOpen = false
	ideasWanted = false
	ui.ideas.Visible = false
end

local function askIdeas()
	if ShopStore.TipsLeft() <= 0 then
		closeIdeas()
		Notify.show("Out of tips", `You've used your free tips this shift. Get {ShopConfig.TipsPerPurchase} more?`, Theme.Yellow)
		ShopStore.BuyProduct("ExtraTips")
		return
	end
	ideasWanted = true
	CallStore.AskIdeas()
end

-- The number of tips left, on the IDEAS button.
local function renderTips()
	local count = ui.talk.IdeasButton:FindFirstChild("Count")
	if not count then
		return
	end
	local tips = ShopStore.TipsLeft()
	count.Text = if tips <= 0 then "+" elseif tips > 99 then "99+" else tostring(tips)
	count.BackgroundColor3 = if tips > 0 then Theme.Yellow else Theme.Red
	count.TextColor3 = if tips > 0 then Theme.NativeText else Theme.White
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

local function showIdeas(ideas: any)
	if not CallStore.IsConnected() then
		return
	end
	-- Ideas the player asked for, but closed (or answered) before they arrived, stay closed. Ideas for a
	-- hidden line always show.
	if ideas.Reason ~= IdeaReason.Blocked and not ideasWanted then
		return
	end
	ideasWanted = true
	local panel = ui.ideas
	panel.Reason.Text = if ideas.Reason == IdeaReason.Blocked
		then "Roblox hid your last line, so it wasn't sent and didn't use a line. Try one of these:"
		else `Tap a line to say it. {ShopStore.TipsLeft()} {if ShopStore.TipsLeft() == 1 then "tip" else "tips"} left.`
	for index = 1, 3 do
		local button = panel:FindFirstChild(`Option{index}`)
		if button then
			local option = ideas.Options[index]
			button.Visible = option ~= nil
			if option then
				button.Text = option.Text
				button:SetAttribute("IdeaId", option.Id)
			end
		end
	end
	panel.Visible = true
	ideasOpen = true
end

local function useIdea(index: number)
	local button = ui.ideas:FindFirstChild(`Option{index}`)
	local id = button and button:GetAttribute("IdeaId")
	if type(id) == "number" and CallStore.IsConnected() then
		closeIdeas()
		CallStore.UseIdea(id)
	end
end

-- Clears what the mic heard (a new call, the call ended, or the line was sent).
local function clearDraft()
	if micDraft ~= nil then
		micDraft = nil
		if ui.talk.InputBox.Text ~= "" and not ui.talk.InputBox:IsFocused() then
			ui.talk.InputBox.Text = ""
		end
	end
end

-- A sentence the mic heard: straight to the caller, or into the text box to check first.
local function onHeard(text: string)
	if not CallStore.IsConnected() then
		return
	end
	if SettingsStore.Settings.MicReview == false then
		closeIdeas()
		CallStore.Say(text, true)
		return
	end
	local box = ui.talk.InputBox
	local current = box.Text
	local untouched = current == "" or current == micDraft
	local combined = if current == "" then text else `{current} {text}`
	combined = string.sub(combined, 1, CallConfig.MaxSayLength)
	box.Text = combined
	-- Only a draft nobody has edited counts as the mic's own words (the caller allows for misheard words).
	micDraft = if untouched then combined else nil
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
		CallVoice.StopSpeaking() -- the last caller's backlog doesn't spill into this call
		lastPaid = 0
		clearTranscript()
		closeIdeas()
		clearDraft()
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
		closeIdeas()
		clearDraft()
	end

	payAt = state.PayAt or payAt
	renderTrust(state.Trust)
	local lines = card.Trust:FindFirstChild("Lines")
	if lines then
		local left = state.LinesLeft or CallConfig.MaxTurns
		lines.Visible = state.Phase == Phase.Connected
		lines.Text = `{left} {if left == 1 then "LINE" else "LINES"} LEFT`
		lines.TextColor3 = if left <= 5 then Theme.TrustLow else Theme.DarkMuted
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
	local spoken = micDraft ~= nil and text == micDraft
	micDraft = nil
	box.Text = ""
	closeIdeas()
	CallStore.Say(text, spoken)
	updateTalkBar(CallStore.State)
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
		ideas = convo:WaitForChild("Ideas"),
	}
	ui.ideas.Visible = false
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
	CallVoice.Heard:Connect(onHeard)
	paintVoiceButtons()
	talk.InputBox:GetPropertyChangedSignal("Text"):Connect(function()
		if micDraft ~= nil and talk.InputBox.Text ~= micDraft then
			micDraft = nil -- they edited what the mic heard
		end
		updateTalkBar(CallStore.State)
	end)
	-- Enter sends a mic line waiting in the box without clicking into it first.
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or input.KeyCode ~= Enum.KeyCode.Return then
			return
		end
		if micDraft ~= nil and window.Visible and CallStore.IsConnected() then
			send()
		end
	end)

	-- Ideas
	local ideas = ui.ideas
	ButtonFx.attach(talk.IdeasButton, 1.06, 0.94)
	talk.IdeasButton.MouseButton1Click:Connect(function()
		if ideasOpen then
			closeIdeas()
		elseif CallStore.IsConnected() then
			askIdeas()
		else
			Notify.show("Phone", "Ideas show up once the call connects.", Theme.Yellow)
		end
	end)
	ButtonFx.attach(ideas.RefreshButton, 1.04, 0.95)
	ideas.RefreshButton.MouseButton1Click:Connect(askIdeas)
	ideas.CloseButton.MouseButton1Click:Connect(closeIdeas)
	for index = 1, 3 do
		local button = ideas:FindFirstChild(`Option{index}`)
		if button then
			ButtonFx.attach(button, 1.02, 0.97)
			button.MouseButton1Click:Connect(function()
				useIdea(index)
			end)
		end
	end
	CallStore.Ideas:Connect(showIdeas)

	-- Tips left and Save My Call
	local saveBar = ui.idle:FindFirstChild("SaveCall")
	if saveBar then
		saveBar.Visible = false
		ButtonFx.attach(saveBar.SaveButton, 1.03, 0.96)
		saveBar.SaveButton.MouseButton1Click:Connect(saveCall)
	end
	ShopStore.Changed:Connect(function()
		renderTips()
		renderSave()
	end)
	ShopStore.PricesLoaded:Connect(renderSave)
	CallStore.Changed:Connect(renderSave)
	renderTips()
	renderSave()

	CallStore.LeadsChanged:Connect(renderLeads)
	CallStore.Changed:Connect(renderCall)
	CallStore.Line:Connect(function(line)
		addBubble(line.Text, false)
		renderTrust(line.Trust)
		showDelta(line.Delta)
		if ideasOpen then
			ideasWanted = true
			CallStore.AskIdeas(true) -- fresh ideas for what the caller just said (free while they're open)
		end
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
