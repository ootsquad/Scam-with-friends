--!strict
--[[
	Device
	Which kind of device this client is: a touch-only device (phone or tablet) gets "phone mode". The desktop
	is designed at 1280x720; in phone mode the design canvas is 900x506 (UiScale) so everything is a third
	bigger, windows open fitted to the screen (WindowManager), and the Phone, Scamazon and mini-game windows
	are swapped for their full-width variants (WorkstationController).

	Device.IsPhone() -> boolean     touch, no mouse, no keyboard (Studio's phone emulation counts)
]]

local UserInputService = game:GetService("UserInputService")

local Device = {}

function Device.IsPhone(): boolean
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled and not UserInputService.KeyboardEnabled
end

return Device
