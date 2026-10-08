--[[
	Checklist (client, Call Center Place)
	The first-shift checklist (OfficeConfig.Tutorial). The same card appears on the in-world HUD and on the
	workstation desktop; the server ticks steps off as you do them and remembers them in your career.
	It goes away once every step is done, or when you press Hide.

	Checklist.bind(frame)    frame has Title, Count, HideButton and Step1..StepN (each with Check and Label)
	Checklist.IsActive() -> boolean
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local OfficeConfig = require(ReplicatedStorage:WaitForChild("Shared").Config.OfficeConfig)

local Client = script.Parent.Parent
local Ui = Client:WaitForChild("Ui")
local ButtonFx = require(Ui.ButtonFx)
local Theme = require(Ui.Theme)
local CareerStore = require(script.Parent.CareerStore)

local Checklist = {}

local frames: { Frame } = {}

function Checklist.IsActive(): boolean
	if not CareerStore.Data or CareerStore.TutorialHidden() then
		return false
	end
	local done, total = CareerStore.TutorialProgress()
	return done < total
end

local function render(frame: any)
	local active = Checklist.IsActive()
	frame.Visible = active and frame:GetAttribute("Allowed") ~= false
	if not active then
		return
	end
	local done, total = CareerStore.TutorialProgress()
	frame.Count.Text = `{done}/{total}`
	local nextShown = false
	for index, step in OfficeConfig.Tutorial do
		local row = frame:FindFirstChild(`Step{index}`)
		if row then
			local isDone = CareerStore.StepDone(index)
			local isNext = not isDone and not nextShown
			if isNext then
				nextShown = true
			end
			row.Label.Text = step.Text
			row.Label.TextColor3 = if isDone then Theme.HudMuted elseif isNext then Theme.HudText else Theme.HudMuted
			row.Check.BackgroundColor3 = if isDone then Theme.ChecklistDone else Theme.ChecklistTodo
			row.Check.BackgroundTransparency = if isDone or isNext then 0 else 0.4
		end
	end
end

local function renderAll()
	for _, frame in frames do
		render(frame)
	end
end

-- Frames can be hidden by their owner (e.g. the HUD while you're at a desk): set attribute Allowed = false.
function Checklist.bind(frame: Frame)
	table.insert(frames, frame)
	local hide = frame:FindFirstChild("HideButton") :: GuiButton?
	if hide then
		ButtonFx.attach(hide, 1.05, 0.95)
		hide.MouseButton1Click:Connect(function()
			CareerStore.SetTutorialHidden(true)
			frame.Visible = false
		end)
	end
	frame:GetAttributeChangedSignal("Allowed"):Connect(function()
		render(frame)
	end)
	render(frame)
end

CareerStore.Changed:Connect(renderAll)

return Checklist
