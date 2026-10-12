--[[
	TrainingApp (client)
	The Training window: short lessons on how the game works, from your first call to getting paid and the
	end-of-day review. Pick a lesson on the left, or page through with Back / Next.

	The lesson text lives here (rich text). Numbers come from CallConfig so they stay right when it's tuned.

	TrainingApp.Start(window)
	TrainingApp.Select(index)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CallConfig = require(Shared.Config.CallConfig)
local ScamConfig = require(Shared.Config.ScamConfig)

local Client = script.Parent.Parent
local Ui = Client:WaitForChild("Ui")
local ButtonFx = require(Ui.ButtonFx)
local Theme = require(Ui.Theme)
local WindowManager = require(Ui.WindowManager)

local smarts = CallConfig.Smarts
local dumbest, sharpest = smarts[1], smarts[#smarts]

local LESSONS: { { title: string, text: string } } = {
	{
		title = "Your first shift",
		text = "<b>Welcome to Call Center Chaos.</b> Your crew works one shift together.\n\n"
			.. "• Sit at a desk and log in with your Roblox username.\n"
			.. "• Open <b>Phone</b> to see your leads: made-up people you can call. Press <b>Call</b>, or wait, "
			.. "because leads call you too.\n"
			.. "• You never type. Every turn you pick one of <b>three cards</b>: things you could say.\n"
			.. "• Every dollar you make counts for you and for the team.\n"
			.. `• Each day lasts {math.round(CallConfig.DayLength / 60)} minutes. The team has to hit the `
			.. "<b>quota</b> before the day clock runs out. Miss it and the whole crew is fired.",
	},
	{
		title = "Pick a card",
		text = "The caller talks, then three cards show up. <b>Click one to say it</b> (or press 1, 2, 3).\n\n"
			.. "• The tag on each card says what kind of line it is: <b>Friendly</b>, <b>Story</b>, <b>Push</b> or "
			.. "<b>Small talk</b>. Friendly and small talk are safe; a story about their soft spot wins big; a push "
			.. "too early loses trust.\n"
			.. "• One card is usually a <b>trap</b>: it touches their red flag or pushes too hard.\n"
			.. "• The <b>hint</b> under the cards tells you what works on this caller (Settings turns it off).\n"
			.. `• <b>Refresh</b> (R) swaps the cards. Free {ScamConfig.FreeRefreshes} times per call, then it uses `
			.. "a tip, then it costs a pick.\n"
			.. `• You get {CallConfig.MaxTurns} picks per call.`,
	},
	{
		title = "The trust meter",
		text = `<b>Every call starts at {CallConfig.StartTrust}% trust.</b>\n\n`
			.. "• Good cards push it up. The trap card pushes it down.\n"
			.. "• The white mark on the bar is the <b>pay line</b>. Once trust is past it, a gold <b>HOOK</b> card "
			.. "shows up.\n"
			.. `• If trust falls to {CallConfig.HangUpTrust}%, they hang up and won't pick up for a while.\n`
			.. `• At the start of the day callers are {string.lower(dumbest.Name)} and pay at {dumbest.PayTrust}% `
			.. `trust. The closer your team gets to quota, the sharper they get, up to {sharpest.PayTrust}%.`,
	},
	{
		title = "Read the caller file",
		text = "When a call starts, the caller's file pops up. Press <b>FILE</b> on the call screen to see it "
			.. "again.\n\n"
			.. "• <b>Soft spot</b>: what they care about. Pick the cards that play to it.\n"
			.. "• <b>Red flag</b>: what makes them nervous. That's the trap card.\n"
			.. "• <b>Weak to</b>: the kind of hook they fall for: <b>Tech</b>, <b>Greed</b>, <b>Fear</b>, "
			.. "<b>Heart</b> or <b>Shopping</b>. Use an app with the same badge.\n"
			.. "• <b>Can spare</b>: about how much money they have. The mini-game takes a share of it.\n"
			.. "• <b>Smarts</b>: how sharp callers are right now.",
	},
	{
		title = "Hooks and mini-games",
		text = "Past the pay line, the third card turns into a gold <b>HOOK</b>: one for every scam app you own "
			.. "(the › button cycles through them).\n\n"
			.. `• A hook that <b>matches</b> what they're weak to always lands, and pays {math.round(ScamConfig.MatchBonus * 100)}% `
			.. `extra. One that doesn't needs trust well past the line, or it costs {-ScamConfig.HookMismatchTrust} trust.\n`
			.. "• When it lands, the app's <b>mini-game</b> opens: slide a card through a slot, close pop-ups, catch "
			.. "hearts... Each one is a sentence long and takes about 15 seconds. Mouse or finger only.\n"
			.. `• You can't lose: a mini-game always pays at least {math.round(ScamConfig.MinScore * 100)}% of what it `
			.. `could. A perfect run pays {math.round((ScamConfig.PerfectScore - 1) * 100)}% extra.\n`
			.. "• The money lands in your <b>Wallet</b> straight away and counts for the quota. The caller says "
			.. "goodbye, none the wiser.",
	},
	{
		title = "Scamazon",
		text = "Every scam app comes from <b>Scamazon</b> on your desktop, paid for with the cash you've made "
			.. "this shift.\n\n"
			.. "• You start with <b>Card Swiper</b> and <b>WalletDrop</b>. More apps mean a matching hook for every "
			.. "kind of caller.\n"
			.. `• Each app has three tiers: <b>Basic</b>, <b>Pro</b> (+{math.round((ScamConfig.Tiers[2].Bonus - 1) * 100)}% `
			.. `payout, a little longer and easier) and <b>Elite</b> (+{math.round((ScamConfig.Tiers[3].Bonus - 1) * 100)}% `
			.. "and a helper that plays along).\n"
			.. "• <b>TRY IT</b> on an app's page plays its mini-game for practice, no money.\n"
			.. "• Apps reset every shift, so buy what you need each time. Spending never takes anything away "
			.. "from the team's total.",
	},
	{
		title = "Quota and reviews",
		text = "• The taskbar shows your money, the team against the quota, your floor, your career cash, open "
			.. "leads and the time left until the review.\n"
			.. "• Make the easy money early: callers get sharper as the team gets closer to quota.\n"
			.. "• Meet the quota and the crew is promoted one floor up the tower, from Rock Bottom all the way to "
			.. "the Penthouse. Higher floors warm callers up and pay bonuses. Miss it and the crew is fired, and "
			.. "the review gives you tips for next time.\n"
			.. "• Trash, messy desks and smoking computers show up around the office. Hold the prompt to fix them "
			.. "for a small bonus; a tidy office warms callers up too.\n"
			.. "• Everything you earn goes to your career cash too. Spend it on headsets, computers and routers at "
			.. "the <b>Tech Store</b>: talk to the dealer.\n"
			.. "• Leave shift from the Start menu to go back to the lobby.\n\n"
			.. "<b>Real life tip:</b> this is a comedy game. Real companies never ask you to swipe a card, install "
			.. "an update or pay a fee over the phone. If a caller does, hang up.",
	},
}

local TrainingApp = {}

local body: any
local current = 1

function TrainingApp.Select(index: number)
	current = math.clamp(index, 1, #LESSONS)
	local lesson = LESSONS[current]
	local page = body.Page
	page.Step.Text = `LESSON {current} OF {#LESSONS}`
	page.Heading.Text = lesson.title
	page.Scroll.Text.Text = lesson.text
	page.Scroll.CanvasPosition = Vector2.zero
	page.BackButton.Visible = current > 1
	page.NextButton.Text = if current < #LESSONS then "Next" else "Done"

	for i = 1, #LESSONS do
		local button = body.Lessons:FindFirstChild(`Lesson{i}`)
		if button then
			local on = i == current
			button.BackgroundColor3 = if on then Theme.Accent else Theme.LessonIdle
			button.Label.TextColor3 = if on then Theme.White else Theme.NativeText
			button.Number.BackgroundColor3 = if on then Theme.White else Theme.Training
			button.Number.TextColor3 = if on then Theme.Accent else Theme.White
		end
	end
end

function TrainingApp.Start(window: Frame)
	body = window:WaitForChild("Body")
	for i, lesson in LESSONS do
		local button = body.Lessons:FindFirstChild(`Lesson{i}`)
		if button then
			button.Label.Text = lesson.title
			ButtonFx.attach(button, 1.02, 0.97)
			button.MouseButton1Click:Connect(function()
				TrainingApp.Select(i)
			end)
		else
			warn(`[TrainingApp] GUI has no Lesson{i}`)
		end
	end
	local page = body.Page
	page.Scroll.Text.AutomaticSize = Enum.AutomaticSize.Y
	ButtonFx.attach(page.BackButton, 1.03, 0.96)
	page.BackButton.MouseButton1Click:Connect(function()
		TrainingApp.Select(current - 1)
	end)
	ButtonFx.attach(page.NextButton, 1.03, 0.96)
	page.NextButton.MouseButton1Click:Connect(function()
		if current < #LESSONS then
			TrainingApp.Select(current + 1)
		else
			WindowManager.close("Training")
		end
	end)
	TrainingApp.Select(1)
end

return TrainingApp
