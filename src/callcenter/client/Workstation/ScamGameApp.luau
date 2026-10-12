--[[
	ScamGameApp (client)
	The mini-game window. When a hook lands on a call, the server sends Call Game (which app, its tier, how
	long, a seed and what a full score pays) and this opens the window over the Phone: a one-line "how to
	play" (click to start, or it starts by itself after a moment), a timer bar, the running payout, and the
	game itself (ScamGames) in the Arena. When the timer runs out or the game says it's done, the score goes
	to the server (CallStore.GameDone), a "$412 TAKEN!" card shows for a moment, and the call carries on.
	Esc, B, QUIT or the window's X ends it early and keeps the score so far.

	Practice (from Scamazon's TRY IT) runs the same game with no money and no server.

	ScamGameApp.Start(window)
	ScamGameApp.Play(game)              Call Game packet
	ScamGameApp.Practice(appKey)
	ScamGameApp.IsOpen() -> boolean
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ScamConfig = require(Shared.Config.ScamConfig)
local Format = require(Shared.Util.Format)

local Client = script.Parent.Parent
local Ui = Client:WaitForChild("Ui")
local ButtonFx = require(Ui.ButtonFx)
local Device = require(Ui.Device)
local Theme = require(Ui.Theme)
local WindowManager = require(Ui.WindowManager)

local CallStore = require(script.Parent.CallStore)
local ScamGames = require(script.Parent.ScamGames)
local ScamStore = require(script.Parent.ScamStore)
local Sfx = require(script.Parent.Sfx)

local AUTO_START = 2.5 -- seconds the how-to shows before the game starts by itself
local RESULT_TIME = 2.2 -- seconds the result card stays up
local GUI_INSET = GuiService:GetGuiInset()

local ScamGameApp = {}

local window: Frame
local body: any
local open = false
local running: { stop: () -> () }? = nil
local token = 0
local raw = 0
local perfectWanted = false
local current: { app: ScamConfig.App, callId: number?, expect: number, seconds: number, tier: number, seed: number, finished: boolean }? = nil
local timeLeft = 0
local heartbeat: RBXScriptConnection? = nil
local lastTouch: Vector2? = nil -- where the last finger was (touch screens)

function ScamGameApp.IsOpen(): boolean
	return open
end

-- The pointer in the arena's own pixels (the desktop's UIScale divided out), for the games.
local function pointer(): Vector2
	local position = if UserInputService.TouchEnabled and lastTouch then lastTouch else UserInputService:GetMouseLocation()
	local arena = body.Arena
	local scale = if arena.Size.X.Offset > 0 and arena.AbsoluteSize.X > 0 then arena.AbsoluteSize.X / arena.Size.X.Offset else 1
	return (position - arena.AbsolutePosition) / scale
end

local function estimate(): number
	local game = current
	if not game then
		return 0
	end
	local score = if perfectWanted and raw >= ScamConfig.PerfectAt
		then ScamConfig.PerfectScore
		else ScamConfig.MinScore + (1 - ScamConfig.MinScore) * math.clamp(raw, 0, 1)
	return math.round(game.expect * score)
end

local function paintPayout()
	local game = current
	if not game then
		return
	end
	if game.callId then
		body.Payout.Text = Format.money(estimate())
		body.PayoutLabel.Text = "TAKEN SO FAR"
	else
		body.Payout.Text = `{math.round(math.clamp(raw, 0, 1) * 100)}%`
		body.PayoutLabel.Text = "PRACTICE"
	end
end

local function clearArena()
	for _, child in body.Arena:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function stopGame()
	if running then
		running.stop()
		running = nil
	end
	if heartbeat then
		heartbeat:Disconnect()
		heartbeat = nil
	end
end

local function close()
	token += 1
	stopGame()
	clearArena()
	open = false
	current = nil
	window.Visible = false
end

local function finish(final: number, perfect: boolean)
	local game = current
	if not game or game.finished then
		return
	end
	game.finished = true
	local mine = token
	stopGame()
	body.HowTo.Visible = false
	raw = math.clamp(final, 0, 1)
	perfectWanted = perfect
	paintPayout()
	if game.callId then
		CallStore.GameDone(game.callId, raw, perfect)
		body.Result.Amount.Text = `{Format.money(estimate())} TAKEN!`
		body.Result.Sub.Text = "Back to the call..."
	else
		body.Result.Amount.Text = `{math.round(raw * 100)}%`
		body.Result.Sub.Text = "Practice run. No money, no harm."
	end
	body.Result.Perfect.Visible = perfect and raw >= ScamConfig.PerfectAt
	body.Result.Visible = true
	Sfx.Play(if perfect and raw >= ScamConfig.PerfectAt then "Payout" else "Ding")
	task.delay(RESULT_TIME, function()
		if token == mine then
			close()
		end
	end)
end

local function startGame()
	local game = current
	if not game or running or not open or game.finished then
		return
	end
	body.HowTo.Visible = false
	local mine = token
	local tier = game.tier
	local kind = ScamGames[game.app.Game]
	if type(kind) ~= "function" then
		warn(`[ScamGameApp] no mini-game called {game.app.Game}`)
		finish(1, false)
		return
	end
	timeLeft = game.seconds
	raw = 0
	perfectWanted = false
	local ctx = {
		arena = body.Arena,
		seconds = game.seconds,
		random = Random.new(game.seed),
		easier = tier >= 2,
		helper = tier >= 3,
		touch = Device.IsPhone(),
		report = function(value: number)
			if token == mine and running then
				raw = math.clamp(value, 0, 1)
				paintPayout()
			end
		end,
		done = function(value: number, perfect: boolean)
			if token == mine and running then
				task.defer(finish, value, perfect)
			end
		end,
		pointer = pointer,
	}
	running = kind(ctx)
	heartbeat = RunService.Heartbeat:Connect(function(dt)
		if token ~= mine or not running then
			return
		end
		timeLeft -= dt
		body.TimerBar.Fill.Size = UDim2.fromScale(math.clamp(timeLeft / game.seconds, 0, 1), 1)
		body.TimerBar.Fill.BackgroundColor3 = if timeLeft < 4 then Theme.Red else Theme.GreenBar
		if timeLeft <= 0 then
			finish(raw, false)
		end
	end)
end

local function show(app: ScamConfig.App, tier: number, seconds: number, seed: number, callId: number?, expect: number)
	close()
	token += 1
	local mine = token
	open = true
	current = { app = app, callId = callId, expect = expect, seconds = seconds, tier = tier, seed = seed, finished = false }
	raw = 0
	perfectWanted = false
	local tierInfo = ScamConfig.Tiers[math.clamp(tier, 1, #ScamConfig.Tiers)]
	body.AppName.Text = app.Name
	body.Tier.Text = if callId then `{string.upper(tierInfo.Name)} · {seconds}s` else `{string.upper(tierInfo.Name)} · practice`
	body.TimerBar.Fill.Size = UDim2.fromScale(1, 1)
	body.TimerBar.Fill.BackgroundColor3 = Theme.GreenBar
	body.Result.Visible = false
	body.HowTo.Text.Text = app.HowTo
	body.HowTo.Sub.Text = "Click anywhere to start"
	body.HowTo.Visible = true
	paintPayout()
	window.Visible = true
	WindowManager.raise(window)
	Sfx.Play("Notify")
	task.delay(AUTO_START, function()
		if token == mine and open and not running then
			startGame()
		end
	end)
end

function ScamGameApp.Play(game: any)
	local app = ScamConfig.App(game.App)
	if not app then
		warn(`[ScamGameApp] the server started a game for an unknown app: {game.App}`)
		CallStore.GameDone(game.CallId, 0, false)
		return
	end
	show(app, game.Tier, game.Seconds, game.Seed, game.CallId, game.Expect)
end

function ScamGameApp.Practice(appKey: string)
	local app = ScamConfig.App(appKey)
	if not app then
		return
	end
	local tier = math.max(1, ScamStore.Tier(appKey))
	local seconds = app.Seconds + (if tier >= 2 then ScamConfig.ExtraSeconds else 0)
	show(app, tier, seconds, os.time(), nil, 0)
end

function ScamGameApp.Start(gameWindow: Frame)
	window = gameWindow
	body = window:WaitForChild("Body")
	window.Visible = false
	body.Result.Visible = false
	body.HowTo.Visible = false
	WindowManager.styleClose(window.TitleBar.Close)
	local function quit()
		if open then
			finish(raw, false) -- before the game even started: the minimum, and the call carries on
		end
	end
	window.TitleBar.Close.MouseButton1Click:Connect(quit)
	ButtonFx.attach(body.QuitButton, 1.04, 0.96)
	body.QuitButton.MouseButton1Click:Connect(quit)
	body.HowTo.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			startGame()
		end
	end)
	local function trackTouch(touch: InputObject)
		lastTouch = touch.Position + GUI_INSET
	end
	UserInputService.TouchStarted:Connect(trackTouch)
	UserInputService.TouchMoved:Connect(trackTouch)
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not open then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
			quit()
		elseif not running and body.HowTo.Visible and (input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.ButtonA) then
			startGame()
		end
	end)
	-- A call that ends (or a new one) takes its game with it.
	CallStore.Changed:Connect(function(state)
		local game = current
		if open and game and game.callId and (not state or state.CallId ~= game.callId) then
			close()
		end
	end)
end

return ScamGameApp
