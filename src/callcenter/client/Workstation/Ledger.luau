--[[
	Ledger (client)
	Shared bits for the cash-in apps (Gift Cards, Card Terminal, GiveHope, Wallet).

	Ledger.money(1750) -> "$1,750"
	Ledger.fill(body, prefix, payouts, pillText?)   fills rows <prefix>1..n and toggles body.Empty
	Ledger.setStatus(label, text, ok?)              green for success, red for errors, grey otherwise
	Ledger.digits(text) -> string                    keep only digits
]]

local Theme = require(script.Parent.Parent:WaitForChild("Ui").Theme)

local Ledger = {}

function Ledger.money(amount: number): string
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

function Ledger.digits(text: string): string
	return (string.gsub(text, "%D", ""))
end

function Ledger.fill(body: Instance, prefix: string, payouts: { any }, pillText: ((any) -> string)?)
	local empty = body:FindFirstChild("Empty") :: GuiObject?
	if empty then
		empty.Visible = #payouts == 0
	end
	local i = 1
	while true do
		local row = body:FindFirstChild(`{prefix}{i}`) :: any
		if not row then
			break
		end
		local payout = payouts[i]
		row.Visible = payout ~= nil
		if payout then
			row.Method.Text = if pillText then pillText(payout) else string.upper(payout.Label)
			row.Detail.Text = payout.Detail
			row.From.Text = `from {payout.LeadName}`
			row.Amount.Text = `+{Ledger.money(payout.Amount)}`
		end
		i += 1
	end
end

function Ledger.setStatus(label: TextLabel, text: string, ok: boolean?)
	label.Text = text
	label.TextColor3 = if ok == true then Theme.Green elseif ok == false then Theme.Red else Theme.NativeMuted
end

return Ledger
