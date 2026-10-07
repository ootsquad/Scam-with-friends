--!strict
--[[
	UiScale
	Screens are designed at 1280x720. Two ways to fit them to any screen:

	UiScale.canvas(screenGui, canvas)   a fixed 1280x720 frame, centered and scaled to fit (boot screen)
	UiScale.virtual(screenGui, root)    a full-screen root that works in "design pixels": the root is
	                                    sized 1/scale and scaled back up, so taskbars span the whole width
	                                    while windows keep their designed pixel sizes (desktop)

	UiScale.SetMultiplier(n) applies the player's Interface size setting to virtual roots.
]]

local DESIGN_SIZE = Vector2.new(1280, 720)

type Binding = {
	gui: ScreenGui,
	frame: GuiObject,
	scale: UIScale,
	virtual: boolean,
}

local UiScale = {}

local bindings: { Binding } = {}
local multiplier = 1

local function apply(binding: Binding)
	local size = binding.gui.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return
	end
	local fit = math.min(size.X / DESIGN_SIZE.X, size.Y / DESIGN_SIZE.Y)
	if binding.virtual then
		local s = fit * multiplier
		binding.scale.Scale = s
		binding.frame.Size = UDim2.fromScale(1 / s, 1 / s)
	else
		binding.scale.Scale = fit
	end
end

local function bind(screenGui: ScreenGui, frame: GuiObject, virtual: boolean)
	local scale = frame:FindFirstChildOfClass("UIScale")
	if not scale then
		warn(`[UiScale] {frame:GetFullName()} has no UIScale`)
		return
	end
	local binding: Binding = { gui = screenGui, frame = frame, scale = scale, virtual = virtual }
	table.insert(bindings, binding)
	apply(binding)
	screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		apply(binding)
	end)
end

function UiScale.canvas(screenGui: ScreenGui, canvas: GuiObject)
	bind(screenGui, canvas, false)
end

function UiScale.virtual(screenGui: ScreenGui, root: GuiObject)
	bind(screenGui, root, true)
end

function UiScale.SetMultiplier(value: number)
	multiplier = value
	for _, binding in bindings do
		apply(binding)
	end
end

-- Current design-pixel scale of a virtual root (for converting mouse movement).
function UiScale.ScaleOf(frame: GuiObject): number
	local scale = frame:FindFirstChildOfClass("UIScale")
	return if scale then scale.Scale else 1
end

return UiScale
