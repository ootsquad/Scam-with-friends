--[[
	ImageService (server, both places)
	Shares the game's images (Shared.Config.ImageConfig) with every player's screen.

	The Creator Dashboard hands out decal ids, but an ImageLabel needs the image inside the decal. This loads
	each decal (InsertService) and reads its image id. An id that isn't a decal (already an image id) is used as
	it is. The results go in ReplicatedStorage.ImageIds as attributes (key = "rbxassetid://..."), which the
	client's Ui/Images module puts on screen. Loading only works for decals made by the game's owner (the
	group), which is who uploads them.

	ImageService.Start()
]]

local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ImageConfig = require(ReplicatedStorage:WaitForChild("Shared").Config.ImageConfig)

local FOLDER_NAME = "ImageIds"
local WORKERS = 6 -- decals loaded at the same time
local RETRY_DELAY = 2

local ImageService = {}

-- The image inside a decal, or nil if this id can't be loaded as one.
local function imageOf(id: number): number?
	local ok, model = pcall(InsertService.LoadAsset, InsertService, id)
	if not ok or not model then
		return nil
	end
	local decal = model:FindFirstChildWhichIsA("Decal", true)
	local texture = if decal then decal.Texture else ""
	model:Destroy()
	-- "http://www.roblox.com/asset/?id=123" or "rbxassetid://123"
	return tonumber(string.match(texture, "(%d+)%D*$"))
end

function ImageService.Start()
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = ReplicatedStorage

	-- One load per id (two keys can share a picture).
	local keysOf: { [number]: { string } } = {}
	local ids: { number } = {}
	for key, id in ImageConfig.Lookup() do
		if not keysOf[id] then
			keysOf[id] = {}
			table.insert(ids, id)
		end
		table.insert(keysOf[id], key)
	end
	table.sort(ids)

	local converted, asIs = 0, {}
	local nextIndex, running = 1, 0
	local function worker()
		while nextIndex <= #ids do
			local id = ids[nextIndex]
			nextIndex += 1
			local image = imageOf(id)
			if not image then
				task.wait(RETRY_DELAY) -- a hiccup, or an image id: try once more before using it as it is
				image = imageOf(id)
			end
			if image then
				converted += 1
			else
				table.insert(asIs, keysOf[id][1])
			end
			for _, key in keysOf[id] do
				folder:SetAttribute(key, `rbxassetid://{image or id}`)
			end
		end
		running -= 1
		if running == 0 then
			folder:SetAttribute("Ready", true)
			if RunService:IsStudio() then
				table.sort(asIs)
				print(`[ImageService] {converted} decal ids turned into image ids`
					.. (if #asIs > 0 then `; used as they are: {table.concat(asIs, ", ")}` else ""))
			end
		end
	end
	running = math.min(WORKERS, #ids)
	if running == 0 then
		folder:SetAttribute("Ready", true)
	end
	for _ = 1, running do
		task.spawn(worker)
	end
end

return ImageService
