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
local Format = require(ReplicatedStorage:WaitForChild("Shared").Util.Format)
local CallStore = require(script.Parent.CallStore)
local Ledger = require(script.Parent.Ledger)

local METHOD_LOOK = {
	gift_card = { "GIFT CARD", "PaymentGiftCard" },
	card = { "CARD", "PaymentCard" },
	donation = { "DONATION", "PaymentDonation" },
}

local player = Players.LocalPlayer

local WalletApp = {}

local body: any

local money = Format.money

-- "6:12" until the review, or nil when the day clock isn't running (before the first login, during a review).
local function timeLeft(): string?
	local endsAt = ReplicatedStorage:GetAttribute("ShiftDayEndsAt")
	if type(endsAt) ~= "number" or endsAt <= 0 then
		return nil
	end
	return Format.duration(endsAt - workspace:GetServerTimeNow())
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
	body.DayCard.Sub.Text = if left
		then "until review"
		elseif ReplicatedStorage:GetAttribute("ShiftReviewing") then "review in progress"
		else "starts at first login"
end

local function renderPayouts()
	Ledger.fill(body, "Payout", CallStore.Payouts, function(payout)
		local look = METHOD_LOOK[payout.Method]
		return if look then look[1] else string.upper(payout.Label)
	end, function(payout)
		local look = METHOD_LOOK[payout.Method]
		return Theme[if look then look[2] else "Accent"]
	end)
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

WalletApp.timeLeft = timeLeft

return WalletApp
