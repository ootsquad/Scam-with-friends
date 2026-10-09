--[[
	VirusApp (client, Call Center Place)
	Virus Attack / Office Chaos at your desk: while the computer you're sitting at has a virus (seat attribute
	Virus), the desktop fills up with silly pop-ups. Close every one (the X) to clean the computer; the server
	pays you for it. "Claim prize" buttons only open more pop-ups.

	VirusApp.Start(desktop)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShopConfig = require(Shared.Config.ShopConfig)

local ButtonFx = require(script.Parent.Parent:WaitForChild("Ui").ButtonFx)
local ShopStore = require(script.Parent.ShopStore)
local Sfx = require(script.Parent.Sfx)

local POPUPS = {
	{ "SuperDeals.exe", "CONGRATULATIONS! You are the 1,000,000th visitor!" },
	{ "PC_Cleaner_9000", "Your computer has 9,999 viruses. Act now!" },
	{ "FreeRAM.zip", "Download more RAM for FREE!!!" },
	{ "Toaster Giveaway", "Click here to win a golden toaster!" },
	{ "MouseAlert", "Warning: your mouse is running low on cheese." },
	{ "CoolBar 3000", "Install CoolBar 3000? It's extremely cool." },
	{ "WinnerWinner.exe", "You won a lifetime supply of staplers!" },
	{ "SpeedBoost.exe", "Your internet is slow. Try shouting at it." },
	{ "DancingBanana.gif", "A banana is dancing. Please watch the banana." },
	{ "Error 404", "Error: the error could not be found." },
}
local RECHECK = 0.4
local MIN_SHOWN = 3.2 -- the server only accepts a cleanup a few seconds after the virus hit

local player = Players.LocalPlayer

local VirusApp = {}

local layer: Frame
local template: Frame
local desktop: Frame
local random = Random.new()
local showingFor: Instance? = nil -- the seat whose pop-ups are up
local cleanedSeat: Instance? = nil
local cleanedAt = 0
local opened = 0
local order = 0
local shownAt = 0

local function popups(): { Frame }
	local out = {}
	for _, child in layer:GetChildren() do
		if child.Name == "Popup" then
			table.insert(out, child)
		end
	end
	return out
end

local function clear()
	for _, popup in popups() do
		popup:Destroy()
	end
	layer.Visible = false
	showingFor = nil
end

local spawnPopup: () -> ()

local function closed()
	if #popups() > 0 or not showingFor then
		return
	end
	cleanedSeat, cleanedAt = showingFor, os.clock()
	clear()
	Sfx.Play("Payout")
	task.delay(math.max(0, MIN_SHOWN - (os.clock() - shownAt)), ShopStore.CleanVirus)
end

spawnPopup = function()
	if opened >= ShopConfig.Virus.MaxPopups then
		return
	end
	opened += 1
	order += 1
	local text = POPUPS[random:NextInteger(1, #POPUPS)]
	local popup = template:Clone()
	popup.Name = "Popup"
	popup.TitleBar.Title.Text = text[1]
	popup.Message.Text = text[2]
	popup.AnchorPoint = Vector2.new(0.5, 0.5)
	popup.Position = UDim2.fromScale(random:NextNumber(0.22, 0.78), random:NextNumber(0.28, 0.72))
	popup.ZIndex = order
	popup.Visible = true
	ButtonFx.attach(popup.TitleBar.CloseButton, 1.08, 0.92)
	popup.TitleBar.CloseButton.MouseButton1Click:Connect(function()
		popup:Destroy()
		Sfx.Play("Click")
		closed()
	end)
	ButtonFx.attach(popup.ClaimButton, 1.04, 0.95)
	popup.ClaimButton.MouseButton1Click:Connect(function()
		Sfx.Play("Error")
		spawnPopup() -- of course it's another pop-up
	end)
	popup.Parent = layer
end

local function infectedSeat(): Instance?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if not seat or seat:GetAttribute("Virus") ~= true or not desktop.Visible then
		return nil
	end
	if seat == cleanedSeat and os.clock() - cleanedAt < 5 then
		return nil -- cleaned; the server is catching up
	end
	return seat
end

local function check()
	local seat = infectedSeat()
	if seat == showingFor then
		return
	end
	clear()
	if seat then
		showingFor = seat
		shownAt = os.clock()
		opened = 0
		layer.Visible = true
		Sfx.Play("Error")
		for _ = 1, ShopConfig.Virus.Popups do
			spawnPopup()
		end
	end
end

function VirusApp.Start(desktopFrame: Frame)
	desktop = desktopFrame
	layer = desktop:WaitForChild("VirusLayer") :: Frame
	template = layer:WaitForChild("PopupTemplate") :: Frame
	template.Visible = false
	clear()
	task.spawn(function()
		while layer.Parent do
			check()
			task.wait(RECHECK)
		end
	end)
end

return VirusApp
