--[[
	LobbyApp (client)
	The Party window that Play opens. Four desk cards in the style of the Phone app's caller panel: name
	bar, the player's avatar head, @username, LEADER / YOU badges, ready status, and for the leader a KICK
	button on everyone else. The sidebar has the party code, invites, difficulty, crew readiness and the
	ready/start buttons. Party members can be on different servers; they all show up here.

	Everything is drawn from LobbyStore.State; clicks become requests to the server.

	LobbyApp.Start(window, createLobby)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared.Config.LobbyConfig)

local Client = script.Parent.Parent
local LobbyStore = require(Client.Stores.LobbyStore)
local Ui = Client.Ui
local Avatar = require(Ui.Avatar)
local ButtonFx = require(Ui.ButtonFx)
local Notify = require(Ui.Notify)
local Theme = require(Ui.Theme)
local WindowManager = require(Ui.WindowManager)

local Phase = LobbyConfig.Phase
local player = Players.LocalPlayer

local DIFFICULTY_NAMES = {}
for index, difficulty in LobbyConfig.Difficulties do
	DIFFICULTY_NAMES[index] = difficulty.Name
end

local LobbyApp = {}

local ui: any
local hoveredDesk: number? = nil
local countdownToken = 0
local countdownDeadline = 0 -- os.clock() when the start countdown reaches zero

local function countdownLeft(): number
	return math.max(math.ceil(countdownDeadline - os.clock()), 0)
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function styleButton(button: TextButton, label: string, background: Color3, textColor: Color3)
	button.Text = label
	button.BackgroundColor3 = background
	button.TextColor3 = textColor
end

local function setSegment(container: Instance, names: { string }, selected: number, editable: boolean)
	for index, name in names do
		local button = container:FindFirstChild(name) :: TextButton?
		if button then
			local on = index == selected
			button.BackgroundColor3 = if on then Theme.Accent else Theme.DarkHead
			button.TextColor3 = if on then Theme.White else Theme.DarkMuted
			button.TextTransparency = if on or editable then 0 else 0.45
		end
	end
end

local function renderDesk(desk: number, state: any)
	local card = ui.desks[desk]
	if not card then
		return
	end
	local seat = LobbyStore.SeatAt(desk)
	local isMe = seat ~= nil and seat.UserId == player.UserId
	local isHost = seat ~= nil and seat.UserId == state.HostUserId
	local hovering = seat == nil and hoveredDesk == desk

	card.Stroke.Color = if isMe then Theme.Accent elseif hovering then Theme.HoverOutline else Theme.DarkLine
	card.Stroke.Thickness = if isMe then 2 else 1

	card.NameBar.DisplayName.Text = if seat then string.upper(seat.DisplayName) else "EMPTY DESK"
	card.NameBar.DisplayName.TextColor3 = if seat then Theme.DarkText else Theme.DarkFaint

	-- Portrait: the player's avatar head on the phone-style grid
	local portrait = card.Portrait
	portrait.BackgroundColor3 = if seat then Theme.Portrait else Theme.PortraitEmpty
	local lineColor = if seat then Theme.PortraitLine else Theme.PortraitEmptyLine
	for _, line in portrait.Grid:GetChildren() do
		line.BackgroundColor3 = lineColor
	end
	portrait.Initial.Text = if seat then string.upper(string.sub(seat.DisplayName, 1, 1)) else "+"
	portrait.Initial.TextColor3 = if seat then Theme.PortraitInitial elseif hovering then Theme.Accent else Theme.DarkFaint
	Avatar.apply(portrait.Headshot, if seat then seat.UserId else nil, 420, portrait.Initial)

	card.Username.Text = if seat then `@{seat.Username}` else `Desk {desk} is free`
	card.DeskTag.Text = `DESK {desk} · {string.upper(LobbyConfig.DeskNames[desk] or "Spare")}`

	card.HostBadge.Visible = isHost
	card.YouBadge.Visible = isMe
	local kick = card:FindFirstChild("KickButton")
	if kick then
		kick.Visible = seat ~= nil and not isMe and state.HostUserId == player.UserId and state.Phase == Phase.Lobby
	end
	if isHost and isMe then
		card.HostBadge.Position = UDim2.fromOffset(38, 256)
		card.YouBadge.Position = UDim2.fromOffset(94, 256)
	else
		card.HostBadge.Position = UDim2.fromOffset(63, 256)
		card.YouBadge.Position = UDim2.fromOffset(66, 256)
	end

	local status = card.Status
	if not seat then
		status.Text = if hovering then "SIT HERE" else "CLICK TO SIT"
		status.TextColor3 = if hovering then Theme.White else Theme.DarkMuted
		status.BackgroundColor3 = if hovering then Theme.Accent else Theme.DarkStrip
	else
		status.Text = if seat.Ready then "READY" else "NOT READY"
		status.TextColor3 = if seat.Ready then Theme.GreenText else Theme.Yellow
		status.BackgroundColor3 = Theme.DarkStrip
	end
end

local function renderSide(state: any)
	local side = ui.side
	local host = state.HostUserId == player.UserId
	local mine = LobbyStore.MySeat()
	local lobbyOpen = state.Phase == Phase.Lobby

	side.CodePanel.Code.Text = state.Code

	setSegment(side.DifficultyPanel.Difficulty, DIFFICULTY_NAMES, state.Difficulty, host and lobbyOpen)
	local difficulty = LobbyConfig.Difficulties[state.Difficulty]
	if difficulty then
		side.DifficultyPanel.Info.Text =
			`Day 1 quota ${difficulty.Quota} · +{math.round(difficulty.Growth * 100)}% per day`
	end

	local seated, readyCount = #state.Seats, 0
	for _, seat in state.Seats do
		if seat.Ready then
			readyCount += 1
		end
	end
	local allReady = seated > 0 and readyCount == seated
	local crew = side.CrewPanel
	crew.Header.Count.Text = `{readyCount}/{seated}`
	crew.Header.Count.TextColor3 = if allReady then Theme.GreenText else Theme.Yellow
	crew.Bar.Fill.Size = UDim2.fromScale(if seated > 0 then readyCount / seated else 0, 1)
	crew.Caption.Text = `{seated}/{LobbyConfig.MaxDesks} at desks`

	if mine and mine.Ready then
		styleButton(side.ReadyButton, "CANCEL READY", Theme.DarkHead, Theme.DarkText)
	else
		styleButton(side.ReadyButton, "I'M READY", Theme.Green, Theme.White)
	end

	local canStart = host and allReady and lobbyOpen
	if state.Phase == Phase.Starting then
		styleButton(side.StartButton, `STARTING IN {countdownLeft()}`, Theme.DarkHead, Theme.DarkMuted)
	elseif state.Phase == Phase.Teleporting then
		styleButton(side.StartButton, "TELEPORTING…", Theme.DarkHead, Theme.DarkMuted)
	elseif canStart then
		styleButton(side.StartButton, "START SHIFT", Theme.Accent, Theme.White)
	elseif host then
		styleButton(side.StartButton, "WAITING FOR CREW", Theme.DarkHead, Theme.DarkMuted)
	else
		styleButton(side.StartButton, "LEADER STARTS SHIFT", Theme.DarkHead, Theme.DarkMuted)
	end
	side.StartButton.Stroke.Transparency = if canStart then 1 else 0

	-- Leave only exists while you're in a lobby that hasn't started.
	ui.floor.LeaveButton.Visible = lobbyOpen
end

local function render(state: any, previous: any)
	if not state then
		ui.noLobby.Visible = true
		ui.floor.Visible = false
		ui.side.Visible = false
		ui.title.Text = "Party"
		countdownToken += 1
		if previous then
			WindowManager.close("Lobby") -- the server's notice says why (left, removed, closed...)
		end
		return
	end

	ui.noLobby.Visible = false
	ui.floor.Visible = true
	ui.side.Visible = true
	ui.title.Text = `Party — {state.Code}`

	-- Count the start down on screen. The server only says how many whole seconds were left when it sent
	-- the party, so the clock starts when the countdown does and later updates don't reset it.
	local wasStarting = previous ~= nil and previous.Code == state.Code and previous.Phase == Phase.Starting
	if state.Phase ~= Phase.Starting then
		countdownToken += 1
	elseif not wasStarting then
		countdownToken += 1
		countdownDeadline = os.clock() + state.Countdown
		local token = countdownToken
		task.spawn(function()
			while token == countdownToken do
				local left = countdownLeft()
				ui.side.StartButton.Text = `STARTING IN {left}`
				if left == 0 then
					break
				end
				task.wait(0.25)
			end
		end)
	end

	for desk = 1, LobbyConfig.MaxDesks do
		renderDesk(desk, state)
	end
	renderSide(state)

	-- Just joined or created a party: bring the window up.
	if not previous or previous.Code ~= state.Code then
		WindowManager.open("Lobby")
	end
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

-- Friends who accept the invite join the game in their own lobby and land straight in this party (the code
-- travels as LaunchData).
local function promptInvite()
	local state = LobbyStore.State
	local ok, canInvite = pcall(SocialService.CanSendGameInviteAsync, SocialService, player)
	if ok and canInvite then
		local sent = pcall(function()
			local options = Instance.new("ExperienceInviteOptions")
			options.PromptMessage = "Join my Call Center Chaos party!"
			if state then
				options.LaunchData = state.Code
			end
			SocialService:PromptGameInvite(player, options)
		end)
		if not sent then
			pcall(SocialService.PromptGameInvite, SocialService, player)
		end
	else
		local code = if state then ` Share your party code {state.Code} for now.` else ""
		Notify.show("Invites", `Invites work in the published game.{code}`, Theme.Accent)
	end
end

local function wireDesks()
	for desk, card in ui.desks do
		card.MouseEnter:Connect(function()
			hoveredDesk = desk
			if LobbyStore.State then
				renderDesk(desk, LobbyStore.State)
			end
		end)
		card.MouseLeave:Connect(function()
			if hoveredDesk == desk then
				hoveredDesk = nil
			end
			if LobbyStore.State then
				renderDesk(desk, LobbyStore.State)
			end
		end)
		card.MouseButton1Click:Connect(function()
			if not LobbyStore.State then
				return
			end
			local seat = LobbyStore.SeatAt(desk)
			if seat == nil then
				LobbyStore.PickDesk(desk)
			elseif seat.UserId ~= player.UserId then
				Notify.show("Party", `That's {seat.DisplayName}'s desk. Pick a free one.`, Theme.Yellow)
			end
		end)
		local kick = card:FindFirstChild("KickButton")
		if kick then
			ButtonFx.attach(kick, 1.05, 0.95)
			kick.MouseButton1Click:Connect(function()
				local seat = LobbyStore.SeatAt(desk)
				if seat and seat.UserId ~= player.UserId and LobbyStore.IsHost() then
					LobbyStore.Kick(seat.UserId)
				end
			end)
		end
	end
end

local function wireSide()
	local side = ui.side

	ButtonFx.attach(side.InviteButton, 1.02, 0.97)
	side.InviteButton.MouseButton1Click:Connect(promptInvite)

	for index, name in DIFFICULTY_NAMES do
		local button = side.DifficultyPanel.Difficulty:FindFirstChild(name)
		if button then
			button.MouseButton1Click:Connect(function()
				if not LobbyStore.IsHost() then
					Notify.show("Party", "Only the party leader can change the difficulty.", Theme.Yellow)
					return
				end
				LobbyStore.SetDifficulty(index)
			end)
		end
	end

	ButtonFx.attach(side.ReadyButton, 1.02, 0.97)
	side.ReadyButton.MouseButton1Click:Connect(function()
		local mine = LobbyStore.MySeat()
		if mine then
			LobbyStore.SetReady(not mine.Ready)
		end
	end)

	ButtonFx.attach(side.StartButton, 1.02, 0.97)
	side.StartButton.MouseButton1Click:Connect(function()
		if not LobbyStore.IsHost() then
			Notify.show("Party", "Only the party leader can start the shift.", Theme.Yellow)
			return
		end
		-- The server checks that everyone is ready and replies with a notice if not.
		LobbyStore.StartShift()
	end)

	ButtonFx.attach(ui.floor.LeaveButton, 1.02, 0.97)
	ui.floor.LeaveButton.MouseButton1Click:Connect(function()
		LobbyStore.Leave()
	end)
end

local function wireNoLobby(createLobby: () -> ())
	ButtonFx.attach(ui.noLobby.CreateButton, 1.02, 0.97)
	ui.noLobby.CreateButton.MouseButton1Click:Connect(createLobby)
	ButtonFx.attach(ui.noLobby.JoinButton, 1.02, 0.97)
	ui.noLobby.JoinButton.MouseButton1Click:Connect(function()
		WindowManager.open("Join")
	end)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function LobbyApp.Start(window: Frame, createLobby: () -> ())
	local body = window:WaitForChild("Body")
	local floor = body:WaitForChild("Floor")
	local desks = {}
	for desk = 1, LobbyConfig.MaxDesks do
		desks[desk] = floor.Desks:FindFirstChild(`Desk{desk}`)
		if not desks[desk] then
			warn(`[LobbyApp] GUI has no Desk{desk}; LobbyConfig.MaxDesks and the GUI are out of sync`)
		end
	end
	ui = {
		title = window.TitleBar.Title,
		floor = floor,
		side = body:WaitForChild("Side"),
		noLobby = body:WaitForChild("NoLobby"),
		desks = desks,
	}

	wireDesks()
	wireSide()
	wireNoLobby(createLobby)

	LobbyStore.Changed:Connect(render)
	render(LobbyStore.State, nil)
end

return LobbyApp
