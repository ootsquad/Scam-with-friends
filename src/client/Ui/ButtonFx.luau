--!strict
--[[
	ButtonFx
	Hover / press feedback for buttons.

	ButtonFx.attach(button, hoverScale?, pressScale?)
		Grows on hover and squishes on press using a UIScale, so it never fights with colors that
		controllers set. Buttons in the GUI models are center-anchored so they scale from the middle.

	ButtonFx.highlight(button, hoverTransparency?)
		For "ghost" buttons (desktop icons, taskbar, menu items) whose background only shows on hover.
		The idle transparency is whatever the button has when this is called; change it later with
		ButtonFx.setIdle(button, transparency).
]]

local Motion = require(script.Parent.Motion)

local ButtonFx = {}

local idle: { [GuiObject]: number } = {}
local hovered: { [GuiObject]: boolean } = {}

function ButtonFx.attach(button: GuiButton, hoverScale: number?, pressScale: number?)
	local hover = hoverScale or 1.03
	local press = pressScale or 0.96

	local uiScale = button:FindFirstChild("PressScale") :: UIScale?
	if not uiScale then
		local created = Instance.new("UIScale")
		created.Name = "PressScale"
		created.Parent = button
		uiScale = created
	end
	local scale = uiScale :: UIScale

	local hovering = false
	button.MouseEnter:Connect(function()
		hovering = true
		Motion.tween(scale, Motion.FAST, { Scale = hover })
	end)
	button.MouseLeave:Connect(function()
		hovering = false
		Motion.tween(scale, Motion.FAST, { Scale = 1 })
	end)
	button.MouseButton1Down:Connect(function()
		Motion.tween(scale, Motion.FAST, { Scale = press })
	end)
	button.MouseButton1Up:Connect(function()
		Motion.tween(scale, Motion.FAST, { Scale = if hovering then hover else 1 })
	end)
end

function ButtonFx.highlight(button: GuiButton, hoverTransparency: number?)
	local target = hoverTransparency or 0.9
	idle[button] = button.BackgroundTransparency
	button.MouseEnter:Connect(function()
		hovered[button] = true
		Motion.tween(button, Motion.FAST, { BackgroundTransparency = math.min(target, idle[button]) })
	end)
	button.MouseLeave:Connect(function()
		hovered[button] = nil
		Motion.tween(button, Motion.FAST, { BackgroundTransparency = idle[button] })
	end)
end

function ButtonFx.setIdle(button: GuiButton, transparency: number)
	idle[button] = transparency
	if not hovered[button] then
		button.BackgroundTransparency = transparency
	end
end

return ButtonFx
