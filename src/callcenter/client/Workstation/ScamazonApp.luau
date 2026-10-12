--[[
	ScamazonApp (client)
	The Scamazon window: every scam app (ScamConfig.Apps) on a card with its pitch, the weakness it plays on,
	and one button (BUY $x / UPGRADE $x / MAXED). Filters by weakness, OWNED shows only yours. Clicking a card
	opens its page: the mini-game in one sentence, the hook line, the three tiers, two reviews, BUY / UPGRADE
	and TRY IT (practice, no money). Apps are paid for with shift cash (ScamStore.Balance) and reset each shift.

	ScamazonApp.Start(window)
	ScamazonApp.Open(appKey?)   shows the window, on that app's page when given
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ScamConfig = require(Shared.Config.ScamConfig)
local Format = require(Shared.Util.Format)

local Client = script.Parent.Parent
local Ui = Client:WaitForChild("Ui")
local ButtonFx = require(Ui.ButtonFx)
local Theme = require(Ui.Theme)
local WindowManager = require(Ui.WindowManager)

local Ledger = require(script.Parent.Ledger)
local ScamGameApp = require(script.Parent.ScamGameApp)
local ScamStore = require(script.Parent.ScamStore)
local Sfx = require(script.Parent.Sfx)

local FILTERS = { "All", "Tech", "Greed", "Fear", "Heart", "Shopping" }

local ScamazonApp = {}

local body: any
local filter = "All"
local ownedOnly = false
local shown: string? = nil -- the app on the detail page
local buying = false

local function initials(app: ScamConfig.App): string
	local out = ""
	for word in string.gmatch(app.Name, "%S+") do
		out ..= string.sub(word, 1, 1)
	end
	return string.upper(string.sub(out, 1, 2))
end

local function weakColor(key: string): Color3
	local weakness = ScamConfig.Weakness(key)
	return if weakness then Color3.fromHex(weakness.Color) else Theme.NativeMuted
end

local function paintTile(tile: Frame, app: ScamConfig.App)
	tile.BackgroundColor3 = Color3.fromHex(app.Color)
	local letter = tile:FindFirstChild("Letter")
	if letter then
		letter.Text = initials(app)
	end
end

-- What the one button on a card says, and whether it does anything.
local function action(app: ScamConfig.App): (string, boolean, Color3)
	local tier = ScamStore.Tier(app.Key)
	if tier >= #ScamConfig.Tiers then
		return "MAXED", false, Theme.NativeMuted
	elseif tier == 0 then
		return `BUY {Format.money(ScamConfig.Cost(app, 1))}`, true, Theme.Accent
	end
	return `UPGRADE {Format.money(ScamConfig.Cost(app, tier + 1))}`, true, Theme.Green
end

local function stateText(app: ScamConfig.App): string
	local tier = ScamStore.Tier(app.Key)
	if tier == 0 then
		return ""
	end
	return `OWNED · {string.upper(ScamConfig.Tiers[tier].Name)}`
end

local function render()
	body.Balance.Text = `{Format.money(ScamStore.Balance())} TO SPEND`
	body.OwnedToggle.BackgroundColor3 = if ownedOnly then Theme.Accent else Theme.White
	body.OwnedToggle.TextColor3 = if ownedOnly then Theme.White else Theme.NativeText
	for _, name in FILTERS do
		local button = body.Filters:FindFirstChild(name)
		if button then
			local on = name == filter
			button.BackgroundColor3 = if on then Theme.Accent else Theme.White
			button.TextColor3 = if on then Theme.White else Theme.NativeText
		end
	end
	for index, app in ScamConfig.Apps do
		local card = body.Grid:FindFirstChild(`App{index}`)
		if not card then
			continue
		end
		local tier = ScamStore.Tier(app.Key)
		card.Visible = (filter == "All" or app.Weak == filter) and (not ownedOnly or tier > 0)
		card.LayoutOrder = index
		paintTile(card.Tile, app)
		card.Title.Text = app.Name
		card.Pitch.Text = app.Pitch
		card.Weak.Text = string.upper(app.Weak)
		card.Weak.BackgroundColor3 = weakColor(app.Weak)
		card.State.Text = stateText(app)
		local text, active, color = action(app)
		card.ActionButton.Text = text
		card.ActionButton.BackgroundColor3 = color
		card.ActionButton.Active = active
	end

	local detail = body.Detail
	local app = shown and ScamConfig.App(shown)
	detail.Visible = app ~= nil
	if app then
		local tier = ScamStore.Tier(app.Key)
		paintTile(detail.Tile, app)
		detail.Title.Text = app.Name
		detail.Pitch.Text = app.Pitch
		detail.Weak.Text = string.upper(app.Weak)
		detail.Weak.BackgroundColor3 = weakColor(app.Weak)
		detail.Owned.Text = if tier == 0 then "NOT OWNED" else stateText(app)
		detail.Owned.TextColor3 = if tier == 0 then Theme.NativeMuted else Theme.Green
		detail.HowTo.Text.Text = app.HowTo
		detail.HookBox.Text.Text = `"{app.Hook}"`
		for t, info in ScamConfig.Tiers do
			local row = detail.Tiers:FindFirstChild(`Tier{t}`)
			if row then
				row.Label.Text = string.upper(info.Name)
				row.Help.Text = if t == 1 then "The hook and the mini-game" else info.Help
				row.Price.Text = if t <= tier then "OWNED" else Format.money(ScamConfig.Cost(app, t))
				row.Price.TextColor3 = if t <= tier then Theme.Green else Theme.NativeText
				row.BackgroundColor3 = if t == tier then Theme.StoreOwned else Theme.NativePanel
			end
		end
		for r = 1, 2 do
			local review = detail.Reviews:FindFirstChild(`Review{r}`)
			if review then
				review.Text.Text = app.Reviews[r] or ""
			end
		end
		local text, active, color = action(app)
		detail.BuyButton.Text = text
		detail.BuyButton.BackgroundColor3 = color
		detail.BuyButton.Active = active
		detail.TryButton.Visible = tier > 0
	end
end

local function buy(app: ScamConfig.App)
	if buying then
		return
	end
	local tier = ScamStore.Tier(app.Key)
	if tier >= #ScamConfig.Tiers then
		return
	end
	local status = if shown then body.Detail.Status else body.Status
	local cost = ScamConfig.Cost(app, tier + 1)
	if ScamStore.Balance() < cost then
		Ledger.setStatus(status, `You need {Format.money(cost - ScamStore.Balance())} more shift cash. Get back on the phone!`, false)
		Sfx.Play("Error")
		return
	end
	buying = true
	Ledger.setStatus(status, if tier == 0 then `Buying {app.Name}…` else `Upgrading {app.Name}…`)
	local result = ScamStore.Buy(app.Key, tier + 1)
	buying = false
	Ledger.setStatus(status, result.Message, result.Ok)
	Sfx.Play(if result.Ok then "Payout" else "Error")
	render()
end

function ScamazonApp.Open(appKey: string?)
	shown = appKey
	render()
	WindowManager.open("Scamazon")
end

function ScamazonApp.Start(window: Frame)
	body = window:WaitForChild("Body")
	Ledger.setStatus(body.Status, "")
	Ledger.setStatus(body.Detail.Status, "")
	local template = body.Grid:FindFirstChild("CardTemplate")
	if template then
		template.Visible = false
	end

	for _, name in FILTERS do
		local button = body.Filters:FindFirstChild(name)
		if button then
			ButtonFx.attach(button, 1.04, 0.96)
			button.MouseButton1Click:Connect(function()
				filter = name
				render()
			end)
		end
	end
	ButtonFx.attach(body.OwnedToggle, 1.04, 0.96)
	body.OwnedToggle.MouseButton1Click:Connect(function()
		ownedOnly = not ownedOnly
		render()
	end)
	for index, app in ScamConfig.Apps do
		local card = body.Grid:FindFirstChild(`App{index}`)
		if card then
			ButtonFx.attach(card.ActionButton, 1.04, 0.96)
			card.ActionButton.MouseButton1Click:Connect(function()
				buy(app)
			end)
			-- the rest of the card opens its page
			local opener = Instance.new("TextButton")
			opener.Name = "Open"
			opener.BackgroundTransparency = 1
			opener.Text = ""
			opener.Size = UDim2.new(1, 0, 0, 96)
			opener.ZIndex = 2
			opener.Parent = card
			opener.MouseButton1Click:Connect(function()
				Sfx.Play("Click")
				shown = app.Key
				render()
			end)
		else
			warn(`[Scamazon] the GUI has no card App{index}; ScamConfig.Apps and the GUI are out of sync`)
		end
	end

	local detail = body.Detail
	ButtonFx.attach(detail.BackButton, 1.04, 0.96)
	detail.BackButton.MouseButton1Click:Connect(function()
		shown = nil
		Ledger.setStatus(detail.Status, "")
		render()
	end)
	ButtonFx.attach(detail.BuyButton, 1.04, 0.96)
	detail.BuyButton.MouseButton1Click:Connect(function()
		local app = shown and ScamConfig.App(shown)
		if app then
			buy(app)
		end
	end)
	ButtonFx.attach(detail.TryButton, 1.04, 0.96)
	detail.TryButton.MouseButton1Click:Connect(function()
		if shown then
			ScamGameApp.Practice(shown)
		end
	end)

	ScamStore.Changed:Connect(render)
	render()
end

return ScamazonApp
