--[[
	CallerFileApp (client)
	The Caller file window: who you're talking to. It pops up once per call, when you call someone or answer
	an incoming call, and the FILE button on the call screen opens it again. It shows the caller's made-up
	details, their soft spot and red flag, how they can pay, about how much they can spare, and how sharp
	callers are right now (with the trust they need before they'll pay).

	CallerFileApp.Start(window)
	CallerFileApp.Show()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CallConfig = require(Shared.Config.CallConfig)

local Client = script.Parent.Parent
local Ui = Client:WaitForChild("Ui")
local ButtonFx = require(Ui.ButtonFx)
local WindowManager = require(Ui.WindowManager)

local CallStore = require(script.Parent.CallStore)
local LeadAvatar = require(script.Parent.LeadAvatar)
local Ledger = require(script.Parent.Ledger)

local Phase = CallConfig.Phase
local FACTS = { "About", "Hobbies", "Pet", "Family", "Lately", "Tech" } -- Facts.Row1 .. Row6

local CallerFileApp = {}

local body: any
local filledFor = 0 -- call the window is showing
local poppedFor = 0 -- call it already popped up for

-- Fills the window for the current call. False if the file hasn't arrived yet.
local function fill(): boolean
	local state, file = CallStore.State, CallStore.File
	if not state or not file or file.CallId ~= state.CallId then
		return false
	end
	if filledFor == file.CallId then
		return true
	end
	filledFor = file.CallId

	local lead = state.Lead
	LeadAvatar.render(body.Portrait.View, lead)
	body.DisplayName.Text = lead.DisplayName
	body.Username.Text = `@{lead.Username}`
	body.Tag.Text = string.upper(lead.Tag)
	body.Smarts.Value.Text = file.Smarts
	body.Smarts.PayAt.Text = if file.PayAt <= 0
		then "Won't pay. It's a prank call!"
		else `Pays once trust hits {file.PayAt}%`
	for index, key in FACTS do
		local row = body.Facts:FindFirstChild(`Row{index}`)
		if row then
			row.Value.Text = file[key] or ""
		end
	end
	body.SoftSpot.Text.Text = file.SoftSpot
	body.RedFlag.Text.Text = file.RedFlag
	for _, chip in body.Methods:GetChildren() do
		if chip:IsA("GuiObject") then
			chip.Visible = table.find(file.Methods, chip.Name) ~= nil
		end
	end
	body.Wallet.Text = if file.PayAt <= 0 then "Nothing. Just jokes." else `About {Ledger.money(file.Wallet)}`
	return true
end

function CallerFileApp.Show()
	if fill() then
		WindowManager.open("CallerFile")
	end
end

-- Pops the file up once per call: as soon as you're calling someone, or once you've answered.
local function maybePop()
	local state = CallStore.State
	if not state or state.Phase == Phase.Incoming or state.Phase == Phase.Ended then
		return
	end
	if state.CallId ~= poppedFor and fill() then
		poppedFor = state.CallId
		-- Deferred so it lands on top of the Phone, which opens on the same change.
		task.defer(WindowManager.open, "CallerFile")
	end
end

function CallerFileApp.Start(window: Frame)
	body = window:WaitForChild("Body")
	ButtonFx.attach(body.GotItButton, 1.03, 0.96)
	body.GotItButton.MouseButton1Click:Connect(function()
		WindowManager.close("CallerFile")
	end)

	CallStore.Changed:Connect(function(state)
		if state == nil then
			WindowManager.close("CallerFile")
			return
		end
		maybePop()
	end)
	CallStore.FileChanged:Connect(maybePop)
end

return CallerFileApp
