--[[
	WalletApp (client)
	The Wallet window: your take this shift, the team's total against today's quota, time until the
	performance review, and your recent payouts.

	WalletApp.Start(window)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent
local Theme = require(Client:WaitForChild("Ui").Theme)
local CallStore = require(script.Parent.CallStore)

local METHOD_LOOK = {
	gift_card = { "GIFT CARD", "PaymentGiftCard" },
	card = { "CARD", "PaymentCard" },
	donation = { "DONATION", "PaymentDonation" },
}
local ROWS = 5

local player = Players.LocalPlayer

local WalletApp = {}

local body: any

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

local function timeLeft(): string?
	local endsAt = ReplicatedStorage:GetAttribute("ShiftDayEndsAt")
	if type(endsAt) ~= "number" or endsAt <= 0 then
		return nil
	end
	local seconds = math.max(0, math.floor(endsAt - workspace:GetServerTimeNow()))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function renderStats()
	local personal = player:GetAttribute("ShiftPersonal") or 0
	local team = ReplicatedStorage:GetAttribute("ShiftTeam") or 0
	local quota = ReplicatedStorage:GetAttribute("ShiftQuota") or 0
	local day = ReplicatedStorage:GetAttribute("ShiftDay") or 1

	body.PersonalCard.Value.Text = money(personal)
	body.TeamCard.Value.Text = money(team)
	body.TeamCard.Sub.Text = `of {money(quota)} quota`
	body.TeamCard.Value.TextColor3 = if quota > 0 and team >= quota then Theme.Green else Theme.NativeText
	body.TeamCard.Bar.Fill.Size = UDim2.fromScale(if quota > 0 then math.clamp(team / quota, 0, 1) else 0, 1)
	body.DayCard.Label.Text = `DAY {day}`
	local left = timeLeft()
	body.DayCard.Value.Text = left or "--:--"
	body.DayCard.Sub.Text = if left then "until review" else "starts at first login"
end

local function renderPayouts()
	local payouts = CallStore.Payouts
	body.Empty.Visible = #payouts == 0
	for i = 1, ROWS do
		local row = body:FindFirstChild(`Payout{i}`)
		local payout = payouts[i]
		if row then
			row.Visible = payout ~= nil
			if payout then
				local look = METHOD_LOOK[payout.Method] or { string.upper(payout.Label), "Accent" }
				row.Method.Text = look[1]
				row.Method.BackgroundColor3 = Theme[look[2]]
				row.Detail.Text = payout.Detail
				row.From.Text = `from {payout.LeadName}`
				row.Amount.Text = `+{money(payout.Amount)}`
			end
		end
	end
end

function WalletApp.Start(window: Frame)
	body = window:WaitForChild("Body")
	CallStore.Payout:Connect(renderPayouts)
	player:GetAttributeChangedSignal("ShiftPersonal"):Connect(renderStats)
	for _, name in { "ShiftTeam", "ShiftQuota", "ShiftDay", "ShiftDayEndsAt" } do
		ReplicatedStorage:GetAttributeChangedSignal(name):Connect(renderStats)
	end
	task.spawn(function()
		while window.Parent do
			if window.Visible then
				renderStats()
			end
			task.wait(1)
		end
	end)
	renderStats()
	renderPayouts()
end

WalletApp.money = money
WalletApp.timeLeft = timeLeft

return WalletApp
