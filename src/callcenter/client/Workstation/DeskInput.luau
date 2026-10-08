--[[
	DeskInput (client)
	While you sit at a computer the screen is a desktop, so the mouse has to behave like one:
	  - the camera stops reacting to input, so scrolling or right-dragging over the desktop can't zoom it into
	    first person or turn it (first person locks the mouse to the middle of the screen)
	  - the mouse is kept free and visible every frame, even if something else tries to lock it (shift lock)
	  - a modal button keeps the mouse unlocked in any camera mode
	  - on touch screens the thumbstick and jump button are hidden (the desktop has Stand up instead)
	Everything goes back to normal when you stand up.

	DeskInput.Enter(screenGui)
	DeskInput.Exit()
	DeskInput.Active -> boolean
]]

local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local BIND_NAME = "ChaosDeskMouse"

local DeskInput = {
	Active = false,
}

local modal: TextButton? = nil
local savedTouchControls = true

local function keepMouseFree()
	if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
	if not UserInputService.MouseIconEnabled then
		UserInputService.MouseIconEnabled = true
	end
end

function DeskInput.Enter(screenGui: ScreenGui)
	if DeskInput.Active then
		return
	end
	DeskInput.Active = true

	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	pcall(function()
		savedTouchControls = GuiService.TouchControlsEnabled
		GuiService.TouchControlsEnabled = false
	end)

	if not modal then
		local button = Instance.new("TextButton")
		button.Name = "MouseUnlock"
		button.Modal = true
		button.BackgroundTransparency = 1
		button.Text = ""
		button.Size = UDim2.fromOffset(0, 0)
		button.Selectable = false
		modal = button
	end
	local button = modal :: TextButton
	button.Parent = screenGui
	button.Visible = true

	-- Runs right after the camera scripts so nothing can re-lock the mouse this frame.
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, keepMouseFree)
	keepMouseFree()
end

function DeskInput.Exit()
	if not DeskInput.Active then
		return
	end
	DeskInput.Active = false
	pcall(function()
		RunService:UnbindFromRenderStep(BIND_NAME)
	end)
	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
	end
	pcall(function()
		GuiService.TouchControlsEnabled = savedTouchControls
	end)
	if modal then
		modal.Visible = false
	end
	UserInputService.MouseIconEnabled = true
end

return DeskInput
