--[[
	WorkstationController (client, Call Center Place)
	The computer at your desk. Nothing shows until you sit in a seat tagged "Computer"; then the ChaOS login
	screen appears (after your first login of the shift, sitting down logs you straight in). Logged in, you
	get the desktop: Phone, Gift Cards, Card Terminal, GiveHope, Wallet, Training, Career and Settings,
	a taskbar with your take / the team against the quota / the floor / your career cash / open leads / the
	review timer, a Start menu, incoming call pop-ups, the caller file pop-up, the first-shift checklist and
	the end-of-day performance review (with tips). Stand up (or Log off) and it goes away. The equipment store
	isn't on the computer: it's a vendor in the office (StoreApp).

	While you're seated the mouse works like a computer's: DeskInput stops the camera from zooming or turning
	(and locking the mouse) and keeps the cursor free. Stand up is on the login screen and in the Start menu,
	since touch screens have no Space key.

	WorkstationController.Start()
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CallConfig = require(Shared.Config.CallConfig)
local OfficeConfig = require(Shared.Config.OfficeConfig)
local SettingsConfig = require(Shared.Config.SettingsConfig)
local Format = require(Shared.Util.Format)
local Network = require(Shared:WaitForChild("Network"))

local Client = script.Parent.Parent
local Ui = Client:WaitForChild("Ui")
local Avatar = require(Ui.Avatar)
local ButtonFx = require(Ui.ButtonFx)
local Motion = require(Ui.Motion)
local Notify = require(Ui.Notify)
local Theme = require(Ui.Theme)
local UiScale = require(Ui.UiScale)
local Wallpaper = require(Ui.Wallpaper)
local WindowManager = require(Ui.WindowManager)
local SettingsStore = require(Client:WaitForChild("Stores"):WaitForChild("SettingsStore"))

local CallStore = require(script.Parent.CallStore)
local CareerApp = require(script.Parent.CareerApp)
local CareerStore = require(script.Parent.CareerStore)
local Checklist = require(script.Parent.Checklist)
local DeskInput = require(script.Parent.DeskInput)
local CallerFileApp = require(script.Parent.CallerFileApp)
local CallVoice = require(script.Parent.CallVoice)
local CashApps = require(script.Parent.CashApps)
local LeadAvatar = require(script.Parent.LeadAvatar)
local Ledger = require(script.Parent.Ledger)
local PhoneApp = require(script.Parent.PhoneApp)
local SettingsApp = require(script.Parent.SettingsApp)
local Sfx = require(script.Parent.Sfx)
local ShopStore = require(script.Parent.ShopStore)
local TrainingApp = require(script.Parent.TrainingApp)
local VirusApp = require(script.Parent.VirusApp)
local WalletApp = require(script.Parent.WalletApp)

local Phase = CallConfig.Phase
local TAG = "Computer"

local APPS = {
	-- window name, window frame, taskbar slot (false = none), desktop icon, start menu item
	{ "Phone", "PhoneWindow", "PhoneTask", "PhoneIcon", "Phone" },
	{ "GiftCards", "GiftCardsWindow", "GiftCardsTask", "GiftCardsIcon", "GiftCards" },
	{ "Terminal", "TerminalWindow", "TerminalTask", "TerminalIcon", "Terminal" },
	{ "Donations", "DonationsWindow", "DonationsTask", "DonationsIcon", "Donations" },
	{ "Wallet", "WalletWindow", "WalletTask", "WalletIcon", "Wallet" },
	{ "Training", "TrainingWindow", "TrainingTask", "TrainingIcon", "Training" },
	{ "Career", "CareerWindow", false, "CareerIcon", "Career" },
	{ "Settings", "SettingsWindow", false, "SettingsIcon", "Settings" },
}

local PAID_HINT = {
	gift_card = { "GiftCards", "Gift card code received. Type it into Gift Cards to redeem it." },
	card = { "Terminal", "Card details received. Charge the card in Card Terminal." },
}

local player = Players.LocalPlayer

local WorkstationController = {}

local gui: ScreenGui
local root: Frame
local desktop: Frame
local login: Frame
local seated = false
local loggedIn = false
local everLoggedIn = false
local clock24 = false
local humanoidConnection: RBXScriptConnection? = nil

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function isComputerSeat(seat: Instance?): boolean
	if not seat then
		return false
	end
	if CollectionService:HasTag(seat, TAG) then
		return true
	end
	local model = seat:FindFirstAncestorWhichIsA("Model")
	return model ~= nil and CollectionService:HasTag(model, TAG)
end

-- Dialogs open above every app window.
local function showDialog(window: Frame)
	window.Visible = true
	WindowManager.raise(window)
end

local function wireDialogClose(window: Frame, onClose: () -> ())
	local close = window.TitleBar.Close
	WindowManager.styleClose(close)
	close.MouseButton1Click:Connect(onClose)
end

local function openLeads(): number
	local count = 0
	for _, lead in CallStore.Leads do
		if lead.Status == CallConfig.LeadStatus.Available then
			count += 1
		end
	end
	return count
end

-- ---------------------------------------------------------------------------
-- Visibility: seat -> login -> desktop
-- ---------------------------------------------------------------------------

local setMenuOpen: (boolean) -> ()

local function refresh()
	local wasLoggedIn = loggedIn
	loggedIn = seated and player:GetAttribute("LoggedIn") == true

	gui.Enabled = seated
	login.Visible = seated and not loggedIn
	desktop.Visible = loggedIn
	if seated then
		DeskInput.Enter(gui)
	else
		DeskInput.Exit()
	end

	if seated and not loggedIn then
		local card = login.Card
		card.Desk.Text = `DESK {string.upper(tostring(player:GetAttribute("Desk") or ""))} · CALL CENTER CHAOS`
	end
	if loggedIn and not wasLoggedIn then
		if not everLoggedIn then
			everLoggedIn = true
			WindowManager.open("Phone")
			Notify.show("Training", "New here? Open Training on the desktop to learn the basics.", Theme.Training)
		end
	elseif wasLoggedIn and not loggedIn then
		setMenuOpen(false)
		if CallVoice.MicOn then
			CallVoice.SetMic(false)
		end
		login.Card.UsernameBox.Text = ""
		Ledger.setStatus(login.Card.Status, "")
	end
end

local function standUp()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Sit = false
		humanoid.Jump = true
	end
end

local function watchCharacter(character: Model)
	if humanoidConnection then
		humanoidConnection:Disconnect()
		humanoidConnection = nil
	end
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid or character ~= player.Character then
		return -- respawned again while we waited; that character's call takes over
	end
	if humanoidConnection then
		humanoidConnection:Disconnect()
	end
	local function onSeat()
		seated = isComputerSeat(humanoid.SeatPart)
		refresh()
	end
	humanoidConnection = humanoid:GetPropertyChangedSignal("SeatPart"):Connect(onSeat)
	onSeat()
end

-- ---------------------------------------------------------------------------
-- Login screen
-- ---------------------------------------------------------------------------

local function wireLogin()
	local card = login.Card
	Avatar.apply(card.Avatar, player.UserId, 150)
	card.Greeting.Text = `Hi, {player.DisplayName}`
	Ledger.setStatus(card.Status, "")

	local busy = false
	local function submit()
		if busy then
			return
		end
		local name = card.UsernameBox.Text
		if not string.find(name, "%S") then
			Ledger.setStatus(card.Status, "Type your Roblox username.", false)
			card.Status.TextColor3 = Theme.LeadBlockedText
			return
		end
		busy = true
		card.LoginButton.Text = "Logging in..."
		local result = CallStore.Login(name)
		card.LoginButton.Text = "Log in"
		busy = false
		if result.Ok then
			Ledger.setStatus(card.Status, "")
		else
			card.Status.Text = result.Message
			card.Status.TextColor3 = Theme.LeadBlockedText
			Sfx.Play("Error")
		end
		refresh()
	end
	ButtonFx.attach(card.LoginButton, 1.02, 0.97)
	card.LoginButton.MouseButton1Click:Connect(submit)
	local standButton = login:FindFirstChild("StandButton")
	if standButton then
		ButtonFx.attach(standButton, 1.03, 0.96)
		standButton.MouseButton1Click:Connect(standUp)
	end
	card.UsernameBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			submit()
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Desktop pieces
-- ---------------------------------------------------------------------------

local function wireStartMenu()
	local menu = desktop.StartMenu
	local dismiss = desktop.MenuDismiss
	local startButton = desktop.Taskbar.Apps.Start

	setMenuOpen = function(open: boolean)
		menu.Visible = open
		dismiss.Visible = open
	end
	setMenuOpen(false)

	Avatar.apply(menu.Avatar, player.UserId, 150)
	menu.DisplayName.Text = player.DisplayName
	local function updateDesk()
		local floor = ReplicatedStorage:GetAttribute("OfficeFloor") or 1
		menu.Desk.Text = `Desk {player:GetAttribute("Desk") or "?"} · floor {floor} · @{player.Name}`
	end
	player:GetAttributeChangedSignal("Desk"):Connect(updateDesk)
	ReplicatedStorage:GetAttributeChangedSignal("OfficeFloor"):Connect(updateDesk)
	updateDesk()

	startButton.BackgroundColor3 = Theme.White
	ButtonFx.highlight(startButton, 0.88)
	startButton.MouseButton1Click:Connect(function()
		setMenuOpen(not menu.Visible)
	end)
	dismiss.MouseButton1Click:Connect(function()
		setMenuOpen(false)
	end)

	local actions: { [string]: () -> () } = {
		LogOff = CallStore.Logoff,
		StandUp = standUp,
		LeaveShift = function()
			showDialog(desktop.Windows.LeaveWindow)
		end,
	}
	for _, app in APPS do
		actions[app[5]] = function()
			WindowManager.open(app[1])
		end
	end
	for name, action in actions do
		local item = menu.Items:FindFirstChild(name)
		if item then
			item.BackgroundColor3 = Theme.White
			ButtonFx.highlight(item, 0.9)
			item.MouseButton1Click:Connect(function()
				setMenuOpen(false)
				action()
			end)
		end
	end
end

local function wireLeaveDialog()
	local window = desktop.Windows.LeaveWindow
	window.Visible = false
	local function hide()
		window.Visible = false
	end
	wireDialogClose(window, hide)
	local body = window.Body
	ButtonFx.attach(body.StayButton, 1.03, 0.96)
	body.StayButton.MouseButton1Click:Connect(hide)
	ButtonFx.attach(body.LeaveButton, 1.03, 0.96)
	local leaving = false
	body.LeaveButton.MouseButton1Click:Connect(function()
		if leaving then
			return
		end
		leaving = true
		body.LeaveButton.Text = "Leaving..."
		Network.Shift.packets.LeaveShift.send(nil)
		task.delay(8, function()
			leaving = false
			body.LeaveButton.Text = "Leave shift"
		end)
	end)
	Network.Shift.packets.Notice.listen(function(message: string)
		leaving = false
		body.LeaveButton.Text = "Leave shift"
		Notify.show("Shift", message, Theme.Yellow)
		Sfx.Play("Notify")
	end)
end

local function wireReview()
	local window = desktop.Windows.ReviewWindow
	window.Visible = false
	local function hide()
		window.Visible = false
	end
	wireDialogClose(window, hide)
	local body = window.Body
	ButtonFx.attach(body.OkButton, 1.03, 0.96)
	body.OkButton.MouseButton1Click:Connect(hide)

	local token = 0
	Network.Shift.packets.Review.listen(function(review)
		token += 1
		local mine = token
		local banner = body.Banner
		banner.BackgroundColor3 = if review.Passed then Theme.Green else Theme.Red
		banner.Day.Text = `PERFORMANCE REVIEW · DAY {review.Day}`
		banner.Result.Text = if review.Passed then "QUOTA MET" else "YOU'RE FIRED"
		local nextFloor = math.min(review.Day + 1, #OfficeConfig.Floors)
		banner.Comment.Text = if review.Passed
			then (if nextFloor > review.Day
				then `Promoted! The crew moves up to floor {nextFloor}, {OfficeConfig.FloorInfo(nextFloor).Name}.`
				else "The penthouse suits you. Don't get comfortable.")
			else "The boss has seen enough. Clear your desks."
		body.Row1.Value.Text = Format.money(review.Team)
		body.Row2.Value.Text = Format.money(review.Quota)
		body.Row3.Value.Text = if review.TopName ~= "" then `{review.TopName} · {Format.money(review.TopAmount)}` else "Nobody"
		local tips = body:FindFirstChild("Tips")
		if tips then
			local list = review.Tips or {}
			tips.Visible = #list > 0
			tips.Title.Text = if review.Passed then "TIPS" else "TIPS FOR NEXT TIME"
			for index = 1, 3 do
				local label = tips:FindFirstChild(`Tip{index}`)
				if label then
					label.Text = list[index] or ""
					label.Visible = list[index] ~= nil
				end
			end
		end
		body.OkButton.Text = if review.Passed then "Back to work" else "Okay"
		showDialog(window)
		Sfx.Play(if review.Passed then "Payout" else "Error")

		local seconds = if review.Passed then CallConfig.ReviewTime else CallConfig.FiredReturnDelay
		task.spawn(function()
			for left = seconds, 0, -1 do
				if token ~= mine then
					return
				end
				body.Next.Text = if review.Passed
					then `Day {review.Day + 1} quota: {Format.money(review.NextQuota)}. Back to work in {left}s.`
					else `Back to the lobby in {left}s.`
				task.wait(1)
			end
		end)
	end)
end

local function wireIncoming()
	local popup = desktop.IncomingCall
	popup.Visible = false
	local shownCall = 0
	ButtonFx.attach(popup.AcceptButton, 1.03, 0.96)
	popup.AcceptButton.MouseButton1Click:Connect(function()
		CallStore.Answer(true)
		WindowManager.open("Phone")
		popup.Visible = false
		Sfx.SetRinging(false)
	end)
	ButtonFx.attach(popup.DeclineButton, 1.03, 0.96)
	popup.DeclineButton.MouseButton1Click:Connect(function()
		CallStore.Answer(false)
		popup.Visible = false
		Sfx.SetRinging(false)
	end)

	local ringing = false
	CallStore.Changed:Connect(function(state, previous)
		local incoming = state ~= nil and state.Phase == Phase.Incoming
		popup.Visible = incoming
		if incoming ~= ringing then
			ringing = incoming
			Sfx.SetRinging(incoming)
		end
		if incoming and state.CallId ~= shownCall then
			shownCall = state.CallId
			popup.DisplayName.Text = state.Lead.DisplayName
			popup.Tag.Text = state.Lead.Tag
			LeadAvatar.render(popup.Portrait.View, state.Lead)
			Notify.show("Phone", `{state.Lead.DisplayName} is calling you.`, Theme.Green)
		end
		-- Bring the Phone up when a call starts ringing or connects (not on every update), and keep the
		-- caller file on top of it if it's open.
		local phaseChanged = state ~= nil
			and (previous == nil or previous.CallId ~= state.CallId or previous.Phase ~= state.Phase)
		if phaseChanged and (state.Phase == Phase.Ringing or state.Phase == Phase.Connected) then
			WindowManager.open("Phone")
			if WindowManager.isOpen("CallerFile") then
				WindowManager.focus("CallerFile")
			end
		end
	end)
end

local function updateTray()
	local stats = desktop.Taskbar.Tray.Stats
	local personal = player:GetAttribute("ShiftPersonal") or 0
	local team = ReplicatedStorage:GetAttribute("ShiftTeam") or 0
	local quota = ReplicatedStorage:GetAttribute("ShiftQuota") or 0
	local day = ReplicatedStorage:GetAttribute("ShiftDay") or 1
	local floor = ReplicatedStorage:GetAttribute("OfficeFloor") or 1
	local data = CareerStore.Data
	stats.Personal.Text = `PERSONAL {Format.money(personal)}{if ShopStore.Boosted() then " · 2x" else ""}`
	stats.Team.Text = `TEAM {Format.money(team)} / {Format.money(quota)}`
	stats.Team.TextColor3 = if quota > 0 and team >= quota then Theme.GreenText else Theme.White
	stats.Floor.Text = `FLOOR {floor}`
	stats.Career.Text = `CAREER {Format.money(if data then data.Cash else 0)}`
	local leads = openLeads()
	stats.Leads.Text = `{leads} {if leads == 1 then "LEAD" else "LEADS"} OPEN`
	stats.Leads.TextColor3 = if leads == 0 then Theme.TrayReview else Theme.White
	local left = WalletApp.timeLeft()
	stats.Review.Text = if left
		then `DAY {day} · REVIEW {left}`
		elseif ReplicatedStorage:GetAttribute("ShiftReviewing") then `DAY {day} · REVIEW NOW`
		else `DAY {day} · STARTS AT LOGIN`

	local time, _, date = Format.clock(clock24)
	local clock = desktop.Taskbar.Tray.Clock
	clock.Time.Text = time
	clock.Date.Text = date
end

local function updateLockClock()
	local _, short, _, longDate = Format.clock(clock24)
	login.Clock.Time.Text = short
	login.Clock.Date.Text = longDate
end

local function applySettings(settings: any)
	Wallpaper.apply(root.Wallpaper, settings.Wallpaper)
	local size = SettingsConfig.UiSizes[settings.UiSize] or SettingsConfig.UiSizes[2]
	UiScale.SetMultiplier(size.Scale)
	Motion.Enabled = not settings.ReduceMotion
	clock24 = settings.Clock24 == true
	if desktop.Visible then
		updateTray()
	end
	updateLockClock()
end

-- Roblox chat typed while on a call is heard by the caller too.
local function forwardChat()
	local ok, err = pcall(function()
		TextChatService.SendingMessage:Connect(function(message: TextChatMessage)
			if loggedIn and CallStore.IsConnected() then
				CallStore.Say(message.Text)
			end
		end)
	end)
	if not ok then
		warn(`[Workstation] can't forward Roblox chat to calls: {err}`)
	end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function WorkstationController.Start()
	gui = player:WaitForChild("PlayerGui"):WaitForChild("Workstation") :: ScreenGui
	gui.Enabled = false
	root = gui:WaitForChild("Root") :: Frame
	desktop = root:WaitForChild("Desktop") :: Frame
	login = root:WaitForChild("LoginScreen") :: Frame
	UiScale.virtual(gui, root)
	root.Active = true -- clicks on the desktop never fall through to the 3D world behind it

	local windows = desktop.Windows
	local apps = desktop.Taskbar.Apps
	WindowManager.init(root, windows)
	Notify.init(desktop.Notifications)
	for _, app in APPS do
		local window = windows:FindFirstChild(app[2])
		if window then
			WindowManager.register(app[1], window, if app[3] then apps:FindFirstChild(app[3]) else nil)
		else
			warn(`[Workstation] the GUI has no {app[2]}`)
		end
	end
	WindowManager.register("CallerFile", windows.CallerFileWindow)

	PhoneApp.Start(windows.PhoneWindow)
	CashApps.StartGiftCards(windows.GiftCardsWindow)
	CashApps.StartTerminal(windows.TerminalWindow)
	CashApps.StartDonations(windows.DonationsWindow)
	WalletApp.Start(windows.WalletWindow)
	TrainingApp.Start(windows.TrainingWindow)
	CareerApp.Start(windows.CareerWindow)
	SettingsApp.Start(windows.SettingsWindow)
	CallerFileApp.Start(windows.CallerFileWindow)
	VirusApp.Start(desktop)
	local fileButton = windows.PhoneWindow.Body.CallView.CallerCard.FileButton
	ButtonFx.attach(fileButton, 1.05, 0.95)
	fileButton.MouseButton1Click:Connect(CallerFileApp.Show)

	for _, app in APPS do
		local icon = desktop.Icons:FindFirstChild(app[4])
		if icon then
			icon.BackgroundColor3 = Theme.White
			ButtonFx.highlight(icon, 0.8)
			icon.MouseButton1Click:Connect(function()
				WindowManager.open(app[1])
			end)
		end
	end

	wireLogin()
	wireStartMenu()
	wireLeaveDialog()
	wireReview()
	wireIncoming()
	forwardChat()
	Checklist.bind(desktop.Checklist)

	-- Robux items: notes for you and office events, as toasts while you're at the desk.
	ShopStore.Message:Connect(function(message)
		if desktop.Visible and gui.Enabled then
			Notify.show("Store", message.Text,
				if message.Kind == 3 then Theme.Red elseif message.Kind == 2 then Theme.Green else nil)
			Sfx.Play(if message.Kind == 3 then "Error" else "Notify")
		end
	end)
	ShopStore.Event:Connect(function(event)
		if not (desktop.Visible and gui.Enabled) then
			return
		end
		if event.Kind == "Virus" then
			Notify.show("Virus attack!", `{event.By} infected every computer. Close the pop-ups for a bonus.`, Theme.Red)
		elseif event.Kind == "Chaos" then
			Notify.show("Office chaos!", `{event.By} wrecked the office. Chores pay double for a while!`, Theme.Red)
		elseif event.Kind == "Prank" and event.Target ~= player.DisplayName then
			Notify.show("Prank call", `{event.By} sent {event.Target} a prank call.`, Theme.Yellow)
		end
	end)

	CallStore.Notice:Connect(function(message: string)
		Notify.show("Phone", message, Theme.Yellow)
		Sfx.Play("Notify")
	end)
	CallStore.Payout:Connect(function(payout)
		local bonus = if (payout.Bonus or 0) > 0 then `, +{Format.money(payout.Bonus)} bonus` else ""
		Notify.show(
			"Payout",
			`+{Format.money(payout.Amount)} from {payout.LeadName} ({string.lower(payout.Label)}{bonus})`,
			Theme.Green
		)
		Sfx.Play("Payout")
	end)
	CallStore.Line:Connect(function(line)
		local hint = PAID_HINT[line.Method]
		if hint then
			Notify.show("Phone", hint[2], Theme.Green)
			Sfx.Play("Notify")
		end
	end)
	CareerStore.Chore:Connect(function(done)
		if loggedIn then
			Notify.show("Chores", `+{Format.money(done.Reward)} for pitching in around the office.`, Theme.Green)
		end
	end)

	task.spawn(function()
		while gui.Parent do
			if gui.Enabled then
				if desktop.Visible then
					updateTray()
				else
					updateLockClock()
				end
			end
			task.wait(0.5)
		end
	end)

	SettingsStore.Changed:Connect(applySettings)
	applySettings(SettingsStore.Settings)

	player:GetAttributeChangedSignal("LoggedIn"):Connect(refresh)
	player:GetAttributeChangedSignal("Desk"):Connect(refresh)
	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then
		task.spawn(watchCharacter, player.Character)
	end
	updateTray()
	refresh()
end

return WorkstationController
