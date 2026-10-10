--!strict
--[[
	Images (client, both places)
	Puts the game's uploaded images (Shared.Config.ImageConfig) on screen. The server turns decal ids into image
	ids and shares them in ReplicatedStorage.ImageIds (ImageService); until that arrives, the id from the config
	is used as it is.

	The GUI generator marks image slots with an ImageKey attribute (an ImageConfig.Lookup key). A slot can name
	a sibling in its ImageFallback attribute (the old drawn icon, or a text symbol): that one shows instead while
	the picture can't be loaded (for example while Roblox is still reviewing a new upload), and hides once it has.

	Images.content(key) -> string            "rbxassetid://..." ("" for a key that isn't in ImageConfig)
	Images.set(label, key, fallback?)        shows the picture on an ImageLabel or ImageButton and keeps it current
	Images.bind(root)                        Images.set for every slot under root with an ImageKey attribute,
	                                         now and for slots added later
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ImageConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("ImageConfig"))

local FOLDER_NAME = "ImageIds"
local FALLBACK_DELAY = 1.5 -- seconds a picture gets to load before its fallback shows

local Images = {}

local lookup = ImageConfig.Lookup()
local folder: Instance? = nil
local watching = false
local slots: { [Instance]: string } = setmetatable({}, { __mode = "k" }) :: any
local fallbackTokens: { [Instance]: {} } = setmetatable({}, { __mode = "k" }) :: any

function Images.content(key: string): string
	local resolved = if folder then folder:GetAttribute(key) else nil
	if type(resolved) == "string" and resolved ~= "" then
		return resolved
	end
	local id = lookup[key]
	return if id then `rbxassetid://{id}` else ""
end

local function paint(label: any)
	local key = slots[label]
	if key then
		local content = Images.content(key)
		if label.Image ~= content then
			label.Image = content
		end
	end
end

-- Repaint every slot once the server's image ids arrive (or change).
local function watch()
	if watching then
		return
	end
	watching = true
	task.spawn(function()
		local found = ReplicatedStorage:FindFirstChild(FOLDER_NAME) or ReplicatedStorage:WaitForChild(FOLDER_NAME, 30)
		if not found then
			return
		end
		folder = found
		for label in slots do
			paint(label)
		end
		found.AttributeChanged:Connect(function(name: string)
			for label, key in slots do
				if key == name then
					paint(label)
				end
			end
		end)
	end)
end

-- The fallback shows only while the picture hasn't loaded, and only after it's had a moment to.
local function followLoading(label: any, fallback: GuiObject)
	local function check()
		if label.IsLoaded then
			fallbackTokens[label] = nil
			fallback.Visible = false
			return
		end
		local token = {}
		fallbackTokens[label] = token
		task.delay(FALLBACK_DELAY, function()
			if fallbackTokens[label] == token and not label.IsLoaded and label.Parent then
				fallback.Visible = true
			end
		end)
	end
	fallback.Visible = false
	label:GetPropertyChangedSignal("IsLoaded"):Connect(check)
	check()
end

function Images.set(label: ImageLabel | ImageButton, key: string, fallback: GuiObject?)
	if lookup[key] == nil then
		warn(`[Images] no image called {key} in ImageConfig`)
		return
	end
	slots[label] = key
	watch()
	paint(label)
	if fallback then
		followLoading(label, fallback)
	end
end

local function bindOne(instance: Instance)
	if not (instance:IsA("ImageLabel") or instance:IsA("ImageButton")) then
		return
	end
	local key = instance:GetAttribute("ImageKey")
	if type(key) ~= "string" or slots[instance] then
		return
	end
	local fallbackName = instance:GetAttribute("ImageFallback")
	local parent = instance.Parent
	local fallback = if type(fallbackName) == "string" and parent then parent:FindFirstChild(fallbackName) else nil
	Images.set(instance :: any, key, if fallback and fallback:IsA("GuiObject") then fallback else nil)
end

function Images.bind(root: Instance)
	for _, instance in root:GetDescendants() do
		bindOne(instance)
	end
	root.DescendantAdded:Connect(bindOne)
end

return Images
