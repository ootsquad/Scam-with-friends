--!strict
--[[
	Motion
	Every UI animation goes through here so the "Reduce motion" setting can switch them all off.
		Motion.tween(frame, Motion.FAST, { BackgroundTransparency = 0.9 })
]]

local TweenService = game:GetService("TweenService")

local Motion = {
	Enabled = true,
	FAST = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	MEDIUM = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
}

-- Tweens `instance` to `goals`, or sets them instantly when motion is reduced.
function Motion.tween(instance: Instance, info: TweenInfo, goals: { [string]: any }): Tween?
	if Motion.Enabled then
		local tween = TweenService:Create(instance, info, goals)
		tween:Play()
		return tween
	end
	for property, value in goals do
		(instance :: any)[property] = value
	end
	return nil
end

return Motion
