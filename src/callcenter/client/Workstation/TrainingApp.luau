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
			.. "• Every dollar you make counts for you and for the team.\n"
			.. "• The team has to hit the <b>quota</b> before the day clock runs out. Miss it and the whole crew "
			.. "is fired.",
	},
	{
		title = "The trust meter",
		text = `<b>Every call starts at {CallConfig.StartTrust}% trust.</b>\n\n`
			.. "• Friendly, believable lines push it up. Rude, pushy or confusing ones push it down.\n"
			.. "• The white mark on the bar is the <b>pay line</b>. Once trust is past it, ask and they'll pay.\n"
			.. `• If trust falls to {CallConfig.HangUpTrust}%, they hang up and won't pick up for a while.\n`
			.. `• You get {CallConfig.MaxTurns} lines per call, so don't waste them.`,
	},
	{
		title = "Read the caller file",
		text = "When a call starts, the caller's file pops up. Press <b>FILE</b> on the call screen to see it "
			.. "again.\n\n"
			.. "• <b>Soft spot</b>: what they care about. Build your story around it.\n"
			.. "• <b>Red flag</b>: what makes them nervous. Stay away from it.\n"
			.. "• <b>Pays with</b>: the ways they can pay. Ask for one of those.\n"
			.. "• <b>Can spare</b>: about how much money they have.\n"
			.. `• <b>Smarts</b>: how sharp callers are right now. At the start of the day they're `
			.. `{string.lower(dumbest.Name)} and pay at {dumbest.PayTrust}% trust. The closer your team gets to `
			.. `quota, the sharper they get, up to {sharpest.PayTrust}%.`,
	},
	{
		title = "Pick a story",
		text = "Match your story to their soft spot:\n\n"
			.. "• Worried about a virus? You're from the computer help desk.\n"
			.. "• Waiting on a refund? You're from the refund department.\n"
			.. "• Loves prizes? They just won something.\n"
			.. "• Package never came? You're from the delivery company.\n\n"
			.. "Use the rest of their file too. Ask about their pet or their hobby; people love talking about "
			.. "themselves. Stay patient and friendly: rude or pushy callers lose trust fast.",
	},
	{
		title = "Getting paid",
		text = "Once trust is past the pay line, ask for the money.\n\n"
			.. "• <b>Gift card</b>: they buy one and read you the code. Type it into <b>Gift Cards</b>.\n"
			.. "• <b>Credit card</b>: they read the card number, expiry and security code. Enter them in "
			.. `<b>Card Terminal</b> and charge up to what they can spare. {CallConfig.DeclinesBeforeFreeze} `
			.. "declines and the card is frozen.\n"
			.. "• <b>Donation</b>: tell them your fundraiser ID from <b>GiveHope</b> first, then ask them to "
			.. "donate.\n\n"
			.. "Missed a code? Ask them to repeat it.",
	},
	{
		title = "The chat filter",
		text = "Roblox hides anything that looks like personal info: numbers, phone numbers, addresses, emails, "
			.. "last names and links.\n\n"
			.. "• Hidden words reach the caller as static. Static never costs you trust; just say it again in "
			.. "plain words.\n"
			.. "• Give your company a made-up name with words, not numbers.\n"
			.. "• If the caller's line gets hidden, they'll ask you to say it again.",
	},
	{
		title = "Quota and reviews",
		text = "• The taskbar shows your money, the team total, the quota and the time left until the review.\n"
			.. "• Make the easy money early: callers get sharper as the team gets closer to quota.\n"
			.. "• Meet the quota and the next day starts with a bigger one. Miss it and the crew is fired.\n"
			.. "• Leave shift from the Start menu to go back to the lobby.\n\n"
			.. "<b>Real life tip:</b> this is a comedy game. Real companies never ask for gift cards, card numbers "
			.. "or donations over the phone. If a caller does, hang up.",
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
