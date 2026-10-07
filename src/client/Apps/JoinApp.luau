--[[
	JoinApp (client)
	The "Join with Code" window: type a friend's 6-character lobby code and join their crew.
	Works for lobbies on this server, and in the live game for lobbies on other servers (teleport).

	JoinApp.Start(window)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LobbyConfig = require(ReplicatedStorage:WaitForChild("Shared").Config.LobbyConfig)

local Client = script.Parent.Parent
local LobbyStore = require(Client.Stores.LobbyStore)
local Ui = Client.Ui
local ButtonFx = require(Ui.ButtonFx)
local Theme = require(Ui.Theme)
local WindowManager = require(Ui.WindowManager)

local JoinApp = {}

local ui: any
local busy = false

local function clean(text: string): string
	local stripped = string.gsub(text, "[^%w]", "")
	return string.sub(string.upper(stripped), 1, LobbyConfig.CodeLength)
end

local function setStatus(text: string, color: Color3?)
	ui.status.Text = text
	ui.status.TextColor3 = color or Theme.NativeMuted
end

local function resetStatus()
	local state = LobbyStore.State
	if state then
		setStatus(`You're in lobby {state.Code}. Joining another one leaves it.`)
	else
		setStatus("")
	end
end

local function submit()
	if busy then
		return
	end
	local code = clean(ui.box.Text)
	if #code ~= LobbyConfig.CodeLength then
		setStatus(`Codes are {LobbyConfig.CodeLength} letters or numbers.`, Theme.Red)
		return
	end
	if LobbyStore.State and LobbyStore.State.Code == code then
		setStatus("You're already in that lobby.", Theme.NativeMuted)
		return
	end

	busy = true
	ui.button.Text = "Joining…"
	setStatus("Dialing that lobby…")
	local result = LobbyStore.Join(code)
	busy = false
	ui.button.Text = "Join lobby"

	if result.Ok then
		ui.box.Text = ""
		setStatus(result.Message, Theme.Green)
	else
		setStatus(result.Message, Theme.Red)
	end
end

function JoinApp.Start(window: Frame)
	local body = window:WaitForChild("Body")
	ui = {
		box = body:WaitForChild("CodeBox") :: TextBox,
		button = body:WaitForChild("JoinButton") :: TextButton,
		status = body:WaitForChild("Status") :: TextLabel,
	}

	ui.box:GetPropertyChangedSignal("Text"):Connect(function()
		local cleaned = clean(ui.box.Text)
		if cleaned ~= ui.box.Text then
			ui.box.Text = cleaned
		end
	end)
	ui.box.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			submit()
		end
	end)

	ButtonFx.attach(ui.button, 1.02, 0.97)
	ui.button.MouseButton1Click:Connect(submit)

	WindowManager.Changed:Connect(function(name: string, state: string)
		if name == "Join" and state == "open" then
			resetStatus()
			ui.box:CaptureFocus()
		end
	end)

	-- Landed in a different lobby (joined here, or created one): this window's job is done.
	LobbyStore.Changed:Connect(function(state, previous)
		if state and (not previous or previous.Code ~= state.Code) then
			WindowManager.close("Join")
		end
	end)

	resetStatus()
end

return JoinApp
