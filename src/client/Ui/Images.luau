--!strict
--[[
	Images (client, both places)
	Puts the game's uploaded images (Shared.Config.ImageConfig) on screen. The server turns decal ids into image
	ids and shares them in ReplicatedStorage.ImageIds (ImageService); until that arrives, the id from the config
	is used as it is.

	The GUI generator marks image slots with an ImageKey attribute (an ImageConfig.Lookup key). A slot may name
	a sibling in its ImageFallback attribute: it's shown only while Roblox can't load the picture (none of the
	game's slots use one right now; a picture that can't load leaves its tile plain and is named in the Output).

	Images.content(key) -> string            "rbxassetid://..." ("" for a key that isn't in ImageConfig)
	Images.set(label, key, fallback?)        shows the picture on an ImageLabel or ImageButton and keeps it current
	Images.bind(root)                        Images.set for every slot under root with an ImageKey attribute,
	                                         now and for slots added later
]]

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ImageConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("ImageConfig"))

local FOLDER_NAME = "ImageIds"
local FOLDER_WAIT = 30 -- seconds to wait for the server's image ids before using the config's ids as they are
local GRACE = 2 -- seconds a picture gets to load before its fallback shows
local POLL = 1

local Images = {}

local lookup = ImageConfig.Lookup()
local folder: Instance? = nil
local gaveUp = false -- the server's image ids never arrived
local watching = false
local slots: { [Instance]: string } = setmetatable({}, { __mode = "k" }) :: any
local fallbacks: { [Instance]: GuiObject } = setmetatable({}, { __mode = "k" }) :: any
local loaded: { [string]: boolean } = {} -- picture -> whether Roblox could load it
local checking: { [string]: boolean } = {}
local since: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any -- when a slot got its picture
local polling = false

function Images.content(key: string): string
	local resolved = if folder then folder:GetAttribute(key) else nil
	if type(resolved) == "string" and resolved ~= "" then
		return resolved
	end
	local id = lookup[key]
	return if id then `rbxassetid://{id}` else ""
end

-- The server has said which picture this key is (or isn't going to).
local function settled(key: string): boolean
	return gaveUp or (folder ~= nil and (folder:GetAttribute(key) ~= nil or folder:GetAttribute("Ready") == true))
end

-- Whether a slot's fallback should show right now.
local function fallbackWanted(label: any): boolean
	local content = label.Image
	if content == "" or loaded[content] == false then
		return true
	end
	if label.IsLoaded then
		return false
	end
	return os.clock() - (since[label] or 0) > GRACE
end

local function showFallback(label: any)
	local fallback = fallbacks[label]
	if fallback then
		local show = fallbackWanted(label)
		if fallback.Visible ~= show then
			fallback.Visible = show
		end
	end
end

local function poll()
	if polling then
		return
	end
	polling = true
	task.spawn(function()
		while true do
			task.wait(POLL)
			for label in fallbacks do
				if (label :: Instance).Parent then
					showFallback(label)
				end
			end
		end
	end)
end

local function check(content: string, key: string)
	if content == "" or loaded[content] ~= nil or checking[content] then
		return
	end
	checking[content] = true
	task.spawn(function()
		local ok = false
		pcall(function()
			ContentProvider:PreloadAsync({ content }, function(_, status: Enum.AssetFetchStatus)
				ok = status == Enum.AssetFetchStatus.Success
			end)
		end)
		checking[content] = nil
		loaded[content] = ok
		if not ok then
			warn(`[Images] couldn't load {key} ({content}); showing its stand-in. Is it still waiting for Roblox's review?`)
		end
		for label in fallbacks do
			if (label :: any).Image == content then
				showFallback(label)
			end
		end
	end)
end

local function paint(label: any)
	local key = slots[label]
	if not key then
		return
	end
	local content = Images.content(key)
	if label.Image ~= content then
		label.Image = content
		since[label] = os.clock()
	end
	showFallback(label)
	if fallbacks[label] and settled(key) then
		check(content, key)
	end
end

local function paintAll()
	for label in slots do
		paint(label)
	end
end

-- Repaint every slot once the server's image ids arrive (or change).
local function watch()
	if watching then
		return
	end
	watching = true
	task.spawn(function()
		local found = ReplicatedStorage:FindFirstChild(FOLDER_NAME) or ReplicatedStorage:WaitForChild(FOLDER_NAME, FOLDER_WAIT)
		if not found then
			gaveUp = true
			paintAll()
			return
		end
		folder = found
		found.AttributeChanged:Connect(function(name: string)
			if name == "Ready" then
				paintAll()
				return
			end
			for label, key in slots do
				if key == name then
					paint(label)
				end
			end
		end)
		paintAll()
	end)
end

function Images.set(label: ImageLabel | ImageButton, key: string, fallback: GuiObject?)
	if lookup[key] == nil then
		warn(`[Images] no image called {key} in ImageConfig`)
		return
	end
	slots[label] = key
	since[label] = os.clock()
	if fallback then
		fallbacks[label] = fallback
		poll()
	end
	watch()
	paint(label)
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
