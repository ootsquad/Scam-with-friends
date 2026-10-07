--[[
	LoadingController (client)
	Drives the ChaOS boot screen that ReplicatedFirst/Boot puts up: spinner, status text, progress bar
	and tips. Reused as the "clocking in" screen when the host starts the shift.

	LoadingController.Start()
	LoadingController.RunSteps(steps, doneText?) -> boolean   steps = { { status = "...", run = function() end } }
	LoadingController.Hide()                           (yields until faded out)
	LoadingController.PlayShiftIntro(seconds)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Ui = script.Parent.Parent:WaitForChild("Ui")
local Theme = require(Ui.Theme)
local UiScale = require(Ui.UiScale)

local MIN_BOOT_TIME = 2.2 -- seconds; keeps the screen from flashing on fast connections
local TIP_INTERVAL = 5
local FADE = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local TIPS = {
	"Switching schemes mid-call costs trust. Pick one and commit.",
	"The boss walks the floor when you're idle. Look busy.",
	"Desks by the boss's door get the most walk-bys.",
	"Callers remember you. Repeat callers pay out more.",
	"Scambaiters plant bait files. Think twice before opening one.",
	"Ready up, then politely harass your host to start.",
}

export type Step = {
	status: string,
	run: () -> (),
}

local LoadingController = {}

local refs: {
	gui: ScreenGui,
	root: CanvasGroup,
	status: TextLabel,
	fill: Frame,
	tip: TextLabel,
	dots: { Frame },
}? = nil
local tipToken = 0

local function getRefs()
	return assert(refs, "LoadingController.Start() must run first")
end

local function setProgress(alpha: number, duration: number?)
	local r = getRefs()
	TweenService:Create(
		r.fill,
		TweenInfo.new(duration or 0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = UDim2.fromScale(math.clamp(alpha, 0, 1), 1) }
	):Play()
end

local function startTips()
	local r = getRefs()
	tipToken += 1
	local token = tipToken
	task.spawn(function()
		local index = math.random(#TIPS)
		while token == tipToken do
			r.tip.Text = `TIP · {TIPS[index]}`
			index = index % #TIPS + 1
			task.wait(TIP_INTERVAL)
		end
	end)
end

local function stopTips()
	tipToken += 1
end

function LoadingController.SetStatus(text: string, isError: boolean?)
	local r = getRefs()
	r.status.Text = text
	r.status.TextColor3 = if isError then Theme.Red else Theme.White
end

function LoadingController.Start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild("LoadingScreen") :: ScreenGui
	local root = gui:WaitForChild("Root") :: CanvasGroup
	local canvas = root:WaitForChild("Canvas") :: Frame
	local spinner = canvas:WaitForChild("Spinner")

	local dots = {}
	for i = 1, 6 do
		dots[i] = spinner:WaitForChild(`Dot{i}`) :: Frame
	end
	refs = {
		gui = gui,
		root = root,
		status = canvas:WaitForChild("Status") :: TextLabel,
		fill = canvas:WaitForChild("Track"):WaitForChild("Fill") :: Frame,
		tip = canvas:WaitForChild("Tip") :: TextLabel,
		dots = dots,
	}
	UiScale.canvas(gui, canvas)

	-- Spinner: a bright dot chases around the ring.
	local t = 0
	RunService.RenderStepped:Connect(function(dt: number)
		if not gui.Enabled then
			return
		end
		t += dt
		for i, dot in dots do
			dot.BackgroundTransparency = ((i - 1 - t * 9) % 6) / 6 * 0.85
		end
	end)

	refs.fill.Size = UDim2.fromScale(0, 1)
	root.GroupTransparency = 0
	gui.Enabled = true
	startTips()
end

-- Runs each step in order, advancing the bar. Returns false (and shows an error) if a step throws.
function LoadingController.RunSteps(steps: { Step }, doneText: string?): boolean
	local perStep = MIN_BOOT_TIME / #steps

	for index, step in steps do
		local stepStarted = os.clock()
		LoadingController.SetStatus(step.status)

		local ok, err = pcall(step.run)
		if not ok then
			warn(`[Loading] "{step.status}" failed: {err}`)
			LoadingController.SetStatus("Couldn't reach the call center. Try rejoining.", true)
			stopTips()
			return false
		end

		local remaining = perStep - (os.clock() - stepStarted)
		setProgress(index / #steps, math.max(remaining, 0.2))
		if remaining > 0 then
			task.wait(remaining)
		end
	end

	LoadingController.SetStatus(doneText or "Welcome back.")
	task.wait(0.3)
	return true
end

function LoadingController.Hide()
	local r = refs
	if not r or not r.gui.Enabled then
		return
	end
	stopTips()
	local tween = TweenService:Create(r.root, FADE, { GroupTransparency = 1 })
	tween:Play()
	tween.Completed:Wait()
	r.gui.Enabled = false
end

-- The boot screen itself, e.g. for TeleportService:SetTeleportGui so it stays up during a teleport.
function LoadingController.GetGui(): ScreenGui?
	return refs and refs.gui
end

-- Shown to the crew when the host starts the shift; stays up while they teleport to the call center.
function LoadingController.PlayShiftIntro(seconds: number)
	local r = getRefs()
	r.fill.Size = UDim2.fromScale(0, 1)
	r.root.GroupTransparency = 1
	r.gui.Enabled = true
	TweenService:Create(r.root, FADE, { GroupTransparency = 0 }):Play()
	startTips()
	setProgress(1, seconds)

	task.spawn(function()
		for remaining = seconds, 1, -1 do
			if not r.gui.Enabled then
				return
			end
			LoadingController.SetStatus(`Clocking in… shift starts in {remaining}`)
			task.wait(1)
		end
		LoadingController.SetStatus("Heading to the call center…")
	end)
end

return LoadingController
