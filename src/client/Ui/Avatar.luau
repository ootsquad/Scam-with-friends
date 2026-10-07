--!strict
--[[
	Avatar
	Roblox avatar headshots via rbxthumb:// content URLs (no web requests or yielding needed).
	Studio "Clients and Servers" test players have negative ids and no avatar, so we fall back to
	an initial letter for them.
]]

local Avatar = {}

-- Valid headshot sizes are 48, 60, 150 and 420.
function Avatar.url(userId: number, size: number?): string
	if userId <= 0 then
		return ""
	end
	local px = size or 420
	return `rbxthumb://type=AvatarHeadShot&id={userId}&w={px}&h={px}`
end

-- Shows `userId`'s headshot in `image`; shows `fallback` (if given) when there's no avatar to show.
function Avatar.apply(image: ImageLabel, userId: number?, size: number?, fallback: GuiObject?)
	local url = if userId then Avatar.url(userId, size) else ""
	image.Image = url
	if fallback then
		fallback.Visible = url == ""
	end
end

return Avatar
