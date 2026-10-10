--[[
	CashApps (client)
	The three apps that turn what callers hand over into money:

	  Gift Cards      type the code the caller read out -> Redeem
	  Card Terminal   type the card number, expiry, security code and how much to charge -> Charge
	                  (charge more than the card holds and it's declined; two declines freeze it)
	  GiveHope        your fake fundraiser and its ID; tell callers the ID and donations land here

	CashApps.StartGiftCards(window)
	CashApps.StartTerminal(window)
	CashApps.StartDonations(window)
]]

local Players = game:GetService("Players")

local Client = script.Parent.Parent
local ButtonFx = require(Client:WaitForChild("Ui").ButtonFx)
local CallStore = require(script.Parent.CallStore)
local Ledger = require(script.Parent.Ledger)

local player = Players.LocalPlayer

local CashApps = {}

local function brandOf(payout: any): string
	return string.upper(string.match(payout.Detail, "^(%S+)") or payout.Label)
end

-- Runs `action` once at a time with the button showing `busyText`.
local function busyButton(button: TextButton, busyText: string, action: () -> ())
	local idleText = button.Text
	local running = false
	return function()
		if running then
			return
		end
		running = true
		button.Text = busyText
		action()
		button.Text = idleText
		running = false
	end
end

function CashApps.StartGiftCards(window: Frame)
	local body = window:WaitForChild("Body")
	local box = body:WaitForChild("CodeBox") :: TextBox
	local status = body:WaitForChild("Status") :: TextLabel
	Ledger.setStatus(status, "")

	local redeem = busyButton(body.RedeemButton, "Checking...", function()
		local code = box.Text
		if not string.find(code, "%w") then
			Ledger.setStatus(status, "Type the code the caller read out.", false)
			return
		end
		local result = CallStore.RedeemGiftCard(code)
		Ledger.setStatus(status, result.Message, result.Ok)
		if result.Ok then
			box.Text = ""
		end
	end)
	ButtonFx.attach(body.RedeemButton, 1.03, 0.96)
	body.RedeemButton.MouseButton1Click:Connect(redeem)
	box.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			redeem()
		end
	end)

	local function render()
		Ledger.fill(body, "Card", CallStore.PayoutsOf("gift_card"), brandOf)
	end
	CallStore.Payout:Connect(render)
	render()
end

function CashApps.StartTerminal(window: Frame)
	local body = window:WaitForChild("Body")
	local number = body:WaitForChild("NumberBox") :: TextBox
	local exp = body:WaitForChild("ExpBox") :: TextBox
	local cvv = body:WaitForChild("CvvBox") :: TextBox
	local amount = body:WaitForChild("AmountBox") :: TextBox
	local status = body:WaitForChild("Status") :: TextLabel
	Ledger.setStatus(status, "")

	-- The amount box only takes digits.
	amount:GetPropertyChangedSignal("Text"):Connect(function()
		local cleaned = string.sub(Ledger.digits(amount.Text), 1, 6)
		if cleaned ~= amount.Text then
			amount.Text = cleaned
		end
	end)

	local charge = busyButton(body.ChargeButton, "Contacting the bank...", function()
		if #Ledger.digits(number.Text) < 15 then
			Ledger.setStatus(status, "Enter the full card number.", false)
			return
		end
		local dollars = tonumber(amount.Text) or 0
		if dollars <= 0 then
			Ledger.setStatus(status, "Enter how much to charge.", false)
			return
		end
		local result = CallStore.ChargeCard(number.Text, exp.Text, cvv.Text, dollars)
		Ledger.setStatus(status, result.Message, result.Ok)
		if result.Ok then
			number.Text, exp.Text, cvv.Text, amount.Text = "", "", "", ""
		end
	end)
	ButtonFx.attach(body.ChargeButton, 1.02, 0.97)
	body.ChargeButton.MouseButton1Click:Connect(charge)
	amount.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			charge()
		end
	end)

	local function render()
		Ledger.fill(body, "Charge", CallStore.PayoutsOf("card"), brandOf)
	end
	CallStore.Payout:Connect(render)
	render()
end

function CashApps.StartDonations(window: Frame)
	local body = window:WaitForChild("Body")
	local card = body:WaitForChild("Fundraiser")

	local function renderFundraiser()
		card.Title.Text = player:GetAttribute("FundraiserTitle") or "Your fundraiser"
		card.Code.Text = player:GetAttribute("FundraiserCode") or "..."
		local raised = player:GetAttribute("FundraiserRaised") or 0
		body.Raised.Text = `RAISED {Ledger.money(raised)}`
		local bar = card:FindFirstChild("Bar")
		if bar then
			bar.Fill.Size = UDim2.fromScale(math.clamp(raised / 1000, 0, 1), 1) -- fills up over the first $1,000
		end
	end
	for _, name in { "FundraiserTitle", "FundraiserCode", "FundraiserRaised" } do
		player:GetAttributeChangedSignal(name):Connect(renderFundraiser)
	end
	renderFundraiser()

	local function render()
		Ledger.fill(body, "Donation", CallStore.PayoutsOf("donation"), function()
			return "DONATION"
		end)
	end
	CallStore.Payout:Connect(render)
	render()
end

return CashApps
