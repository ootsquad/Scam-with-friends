--!strict
--[[
	Wallpaper
	Paints a ChaOS desktop wallpaper (the Wallpaper frame from the GUI generator) in one of the
	Theme.Wallpapers looks. Used by both desktops (lobby and call center).

	Wallpaper.apply(wallpaperFrame, index)
]]

local Theme = require(script.Parent.Theme)

local Wallpaper = {}

function Wallpaper.apply(wallpaper: any, index: number)
	local theme = Theme.Wallpapers[index] or Theme.Wallpapers[1]
	wallpaper.Sky.Gradient.Color = theme.Sky
	wallpaper.Water.Gradient.Color = theme.Water
	wallpaper.Sun.BackgroundColor3 = theme.Sun
	wallpaper.Sun.BackgroundTransparency = theme.SunTransparency
	wallpaper.Halo.BackgroundColor3 = theme.Sun
	wallpaper.Halo.BackgroundTransparency = theme.HaloTransparency
	for _, peak in wallpaper.RidgeBack:GetChildren() do
		peak.BackgroundColor3 = theme.Back
	end
	for _, peak in wallpaper.RidgeFront:GetChildren() do
		peak.BackgroundColor3 = theme.Front
	end
	for _, child in wallpaper:GetChildren() do
		if string.sub(child.Name, 1, 5) == "Shine" then
			child.BackgroundColor3 = theme.Shine
			child.BackgroundTransparency = theme.ShineTransparency
		end
	end
end

return Wallpaper
