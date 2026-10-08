--!strict
--[[
	Notify
	ChaOS notification toasts, stacked in the bottom-right corner above the taskbar.
		Notify.show("Lobby", "Moth joined the lobby.")
		Notify.show("Couldn't join", "No lobby found with code ABC123.", Theme.Red)
]]

local Motion = require(script.Parent.Motion)
local Theme = require(script.Parent.Theme)

local LIFETIME = 4
local MAX_VISIBLE = 3
local SPACING = 92

local Notify = {}

local container: Frame? = nil
local template: Frame? = nil
local active: { Frame } = {}
local homeY = 0

local function restack()
	for index, toast in active do
		-- newest (last) sits at the bottom
		local fromBottom = #active - index
		Motion.tween(toast, Motion.MEDIUM, { Position = UDim2.fromOffset(0, homeY - fromBottom * SPACING) })
	end
end

local function dismiss(toast: Frame)
	local index = table.find(active, toast)
	if index then
		table.remove(active, index)
		toast:Destroy()
		restack()
	end
end

function Notify.init(notifications: Frame)
	container = notifications
	local toast = notifications:WaitForChild("Toast") :: Frame
	toast.Visible = false
	template = toast
	homeY = toast.Position.Y.Offset
end

function Notify.show(title: string, message: string, accent: Color3?)
	if not container or not template then
		warn(`[Notify] {title}: {message}`)
		return
	end

	local toast = template:Clone()
	toast.Name = "ActiveToast"
	local titleLabel = toast:FindFirstChild("Title") :: TextLabel
	local messageLabel = toast:FindFirstChild("Message") :: TextLabel
	local accentBar = toast:FindFirstChild("Accent") :: Frame? -- optional colored edge (the lobby has one)
	titleLabel.Text = title
	messageLabel.Text = message
	if accentBar then
		accentBar.BackgroundColor3 = accent or Theme.Green
	end
	toast.Position = UDim2.fromOffset(0, homeY + SPACING)
	toast.Visible = true
	toast.Parent = container

	table.insert(active, toast)
	while #active > MAX_VISIBLE do
		dismiss(active[1])
	end
	restack()

	task.delay(LIFETIME, dismiss, toast)
end

return Notify
