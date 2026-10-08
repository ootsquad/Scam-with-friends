--[[
	WindowManager
	Real desktop behavior for ChaOS windows: open/close, minimize to the taskbar, maximize (zooms the
	window to fill the desktop), focus (bring to front) and dragging by the title bar.

	WindowManager.init(root, windowsFrame)
	WindowManager.register(name, windowFrame, taskButton?, launch?)
		launch(): called instead of a plain open when the window is closed (e.g. Play creates a lobby)
	WindowManager.open(name) / close(name) / minimize(name) / toggle(name) / focus(name)
	WindowManager.isOpen(name) -> boolean
	WindowManager.raise(frame)        puts a dialog (not a registered window) above every window
	WindowManager.styleClose(button)  the red X close button look, for dialogs
	WindowManager.Changed:Connect(function(name, state) end)   state: "open" | "minimized" | "closed"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Signal = require(ReplicatedStorage:WaitForChild("Shared").Util.Signal)
local ButtonFx = require(script.Parent.ButtonFx)
local Motion = require(script.Parent.Motion)
local Theme = require(script.Parent.Theme)
local UiScale = require(script.Parent.UiScale)

type WindowState = "open" | "minimized" | "closed"

type Entry = {
	name: string,
	frame: Frame,
	taskButton: GuiButton?,
	launch: (() -> ())?,
	state: WindowState,
	zoom: UIScale,
	maximized: boolean,
	homePosition: UDim2,
	restorePosition: UDim2?,
}

local TITLE_BAR_HEIGHT = 40
local KEEP_VISIBLE = 120 -- px of a dragged window that must stay on screen

local WindowManager = {
	Changed = Signal.new(),
}

local entries: { [string]: Entry } = {}
local root: GuiObject
local container: GuiObject
local topZ = 10
local focused: string? = nil
-- The window being dragged. `touch` is the finger doing it (nil when it's the mouse).
local drag: { entry: Entry, startMouse: Vector2, startPosition: UDim2, touch: InputObject? }? = nil

local function isPointer(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

-- Desktop area available to windows, in design pixels.
local function areaSize(): Vector2
	return container.AbsoluteSize / UiScale.ScaleOf(root)
end

local function updateTaskButton(entry: Entry)
	local button = entry.taskButton
	if not button then
		return
	end
	local running = entry.state ~= "closed"
	local active = entry.state == "open" and focused == entry.name
	-- Active app gets the lighter slot; every running app gets the blue underline.
	ButtonFx.setIdle(button, if active then 0.82 else 1)

	local indicator = button:FindFirstChild("Indicator") :: Frame?
	if indicator then
		indicator.Visible = running
		indicator.Size = UDim2.fromOffset(if active then 56 else 40, 4)
		indicator.Position = UDim2.fromOffset(if active then 0 else 8, 52)
	end
end

local function updateBorder(entry: Entry)
	local border = entry.frame:FindFirstChildOfClass("UIStroke")
	if border then
		border.Color = if focused == entry.name then Theme.BorderFocused else Theme.BorderIdle
	end
end

local function refreshTaskbar()
	for _, entry in entries do
		updateTaskButton(entry)
		updateBorder(entry)
	end
end

local function setState(entry: Entry, state: WindowState)
	if entry.state == state then
		return
	end
	entry.state = state
	entry.frame.Visible = state == "open"
	if state ~= "open" and focused == entry.name then
		focused = nil
	end
	if state ~= "open" and drag and drag.entry == entry then
		drag = nil
	end
	refreshTaskbar()
	WindowManager.Changed:Fire(entry.name, state)
end

local function fitZoom(entry: Entry): number
	local area = areaSize()
	local size = entry.frame.Size
	return math.max(1, math.min((area.X - 32) / size.X.Offset, (area.Y - 24) / size.Y.Offset))
end

local function clampOffset(entry: Entry, x: number, y: number): (number, number)
	local area = areaSize()
	local w, h = entry.frame.Size.X.Offset, entry.frame.Size.Y.Offset
	local minX, maxX = -area.X / 2 - w / 2 + KEEP_VISIBLE, area.X / 2 + w / 2 - KEEP_VISIBLE
	local minY, maxY = h / 2 - area.Y / 2, area.Y / 2 + h / 2 - TITLE_BAR_HEIGHT
	return math.clamp(x, minX, math.max(minX, maxX)), math.clamp(y, minY, math.max(minY, maxY))
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function WindowManager.focus(name: string)
	local entry = entries[name]
	if not entry or entry.state ~= "open" then
		return
	end
	topZ += 1
	entry.frame.ZIndex = topZ
	focused = name
	refreshTaskbar()
end

function WindowManager.open(name: string)
	local entry = entries[name]
	if not entry then
		return
	end
	if entry.state ~= "open" then
		setState(entry, "open")
		local target = if entry.maximized then fitZoom(entry) else 1
		entry.zoom.Scale = target * 0.94
		Motion.tween(entry.zoom, Motion.MEDIUM, { Scale = target })
	end
	WindowManager.focus(name)
end

function WindowManager.close(name: string)
	local entry = entries[name]
	if entry then
		setState(entry, "closed")
	end
end

function WindowManager.minimize(name: string)
	local entry = entries[name]
	if entry and entry.state == "open" then
		setState(entry, "minimized")
	end
end

-- Taskbar behavior: launch/restore, focus, or minimize when already in front.
function WindowManager.toggle(name: string)
	local entry = entries[name]
	if not entry then
		return
	end
	if entry.state == "open" then
		if focused == name then
			WindowManager.minimize(name)
		else
			WindowManager.focus(name)
		end
	elseif entry.state == "closed" and entry.launch then
		entry.launch()
	else
		WindowManager.open(name)
	end
end

function WindowManager.toggleMaximize(name: string)
	local entry = entries[name]
	if not entry then
		return
	end
	entry.maximized = not entry.maximized
	if entry.maximized then
		entry.restorePosition = entry.frame.Position
		entry.frame.Position = UDim2.new(0.5, 0, 0.5, 0)
		Motion.tween(entry.zoom, Motion.MEDIUM, { Scale = fitZoom(entry) })
	else
		entry.frame.Position = entry.restorePosition or entry.homePosition
		Motion.tween(entry.zoom, Motion.MEDIUM, { Scale = 1 })
	end
end

function WindowManager.isOpen(name: string): boolean
	local entry = entries[name]
	return entry ~= nil and entry.state == "open"
end

function WindowManager.raise(frame: GuiObject)
	topZ += 1
	frame.ZIndex = topZ
end

-- Close: red X at rest, white X on a red square when hovered (like Windows).
function WindowManager.styleClose(close: GuiButton)
	close.BackgroundColor3 = Theme.RedHover
	ButtonFx.highlight(close, 0)
	local function paint(hovered: boolean)
		for _, bar in close:GetChildren() do
			if bar:IsA("Frame") then
				bar.BackgroundColor3 = if hovered then Theme.White else Theme.Red
			end
		end
	end
	paint(false)
	close.MouseEnter:Connect(function()
		paint(true)
	end)
	close.MouseLeave:Connect(function()
		paint(false)
	end)
end

function WindowManager.register(name: string, frame: Frame, taskButton: GuiButton?, launch: (() -> ())?)
	local zoom = frame:FindFirstChild("Zoom") :: UIScale?
	if not zoom then
		local created = Instance.new("UIScale")
		created.Name = "Zoom"
		created.Parent = frame
		zoom = created
	end

	local entry: Entry = {
		name = name,
		frame = frame,
		taskButton = taskButton,
		launch = launch,
		state = "closed",
		zoom = zoom :: UIScale,
		maximized = false,
		homePosition = frame.Position,
	}
	entries[name] = entry
	frame.Visible = false

	-- Clicking anywhere on a window brings it to the front.
	frame.InputBegan:Connect(function(input)
		if isPointer(input) then
			WindowManager.focus(name)
		end
	end)

	local titleBar = frame:WaitForChild("TitleBar")
	titleBar.InputBegan:Connect(function(input)
		if not isPointer(input) then
			return
		end
		WindowManager.focus(name)
		if not entry.maximized then
			drag = {
				entry = entry,
				startMouse = Vector2.new(input.Position.X, input.Position.Y),
				startPosition = frame.Position,
				touch = if input.UserInputType == Enum.UserInputType.Touch then input else nil,
			}
		end
	end)

	local minimize = titleBar:WaitForChild("Minimize") :: GuiButton
	local maximize = titleBar:WaitForChild("Maximize") :: GuiButton
	local close = titleBar:WaitForChild("Close") :: GuiButton
	for _, button in { minimize, maximize } do
		button.BackgroundColor3 = Theme.TitleHover
		ButtonFx.highlight(button, 0)
	end
	WindowManager.styleClose(close)
	minimize.MouseButton1Click:Connect(function()
		WindowManager.minimize(name)
	end)
	maximize.MouseButton1Click:Connect(function()
		WindowManager.toggleMaximize(name)
	end)
	close.MouseButton1Click:Connect(function()
		WindowManager.close(name)
	end)

	if taskButton then
		ButtonFx.highlight(taskButton, 0.88)
		taskButton.MouseButton1Click:Connect(function()
			WindowManager.toggle(name)
		end)
	end
	updateTaskButton(entry)
	updateBorder(entry)
end

function WindowManager.init(desktopRoot: GuiObject, windowsFrame: GuiObject)
	root = desktopRoot
	container = windowsFrame

	UserInputService.InputChanged:Connect(function(input)
		local current = drag
		if not current then
			return
		end
		-- Follow the finger that started the drag, or the mouse.
		if current.touch then
			if input ~= current.touch then
				return
			end
		elseif input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		local delta = (Vector2.new(input.Position.X, input.Position.Y) - current.startMouse) / UiScale.ScaleOf(root)
		local start = current.startPosition
		local x, y = clampOffset(current.entry, start.X.Offset + delta.X, start.Y.Offset + delta.Y)
		current.entry.frame.Position = UDim2.new(start.X.Scale, x, start.Y.Scale, y)
	end)

	UserInputService.InputEnded:Connect(function(input)
		local current = drag
		if current and (input.UserInputType == Enum.UserInputType.MouseButton1 or input == current.touch) then
			drag = nil
		end
	end)
	-- Alt-tabbing away mid-drag would otherwise leave the window stuck to the mouse.
	UserInputService.WindowFocusReleased:Connect(function()
		drag = nil
	end)
end

return WindowManager
