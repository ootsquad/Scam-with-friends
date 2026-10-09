--[[
	DisasterService (server, Call Center Place)
	Office disasters that players set off with Robux items (ShopConfig):

	  Virus Attack   every computer on the crew's floor catches a (fake) virus: its monitor glows and says
	                 VIRUS, and whoever sits there gets a screen full of pop-ups. Close them all to clean the
	                 computer and earn ShopConfig.Virus.CleanReward. Computers nobody cleans recover after
	                 Virus.Duration seconds.
	  Office Chaos   a virus attack plus a pile of chores at once (trash, messy desks, broken equipment),
	                 flashing alarms for Chaos.AlarmTime seconds, and chores paying double for a while.

	Seat attribute: Virus (true while infected).
	ReplicatedStorage attribute: OfficeAlarmUntil (server time the alarms stop; 0 = off).

	DisasterService.Start()
	DisasterService.Virus(byName) -> number      computers infected
	DisasterService.Chaos(byName)
	DisasterService.CanStart() -> boolean        not during the review or the last ShopConfig.DisasterCutoff seconds
	                                             of a day (moving up a floor would wipe it out)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShopConfig = require(Shared.Config.ShopConfig)
local Format = require(Shared.Util.Format)
local Shop = require(Shared:WaitForChild("Network")).Shop
local ChoreService = require(script.Parent.ChoreService)
local DeskService = require(script.Parent.DeskService)
local EconomyService = require(script.Parent.EconomyService)
local OfficeService = require(script.Parent.OfficeService)

local EFFECT_NAME = "VirusEffect"
local CLEAN_COOLDOWN = 1 -- seconds between clean requests from one player
local MIN_CLEAN_TIME = 3 -- seconds a computer has the virus before it can be cleaned

local DisasterService = {}

local infected: { [Seat]: { effect: Instance, token: number, at: number } } = {}
local nextToken = 0
local lastClean: { [Player]: number } = {}

local function message(player: Player, text: string, kind: number)
	if player.Parent then
		Shop.packets.Message.sendTo({ Text = text, Kind = kind }, player)
	end
end

local function event(kind: string, by: string, target: string, seconds: number)
	for _, player in Players:GetPlayers() do
		Shop.packets.Event.sendTo({ Kind = kind, By = by, Target = target, Seconds = seconds }, player)
	end
end

-- A green glow and a VIRUS sign on the desk's computer.
local function virusEffect(seat: Seat): Instance
	local target = ChoreService.ComputerOf(seat)
	local attachment = Instance.new("Attachment")
	attachment.Name = EFFECT_NAME
	attachment.Position = Vector3.new(0, target.Size.Y / 2 + 0.2, 0)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(74, 222, 128)
	light.Brightness = 3
	light.Range = 8
	light.Parent = attachment
	local sign = Instance.new("BillboardGui")
	sign.Name = "VirusSign"
	sign.Size = UDim2.fromOffset(90, 26)
	sign.StudsOffset = Vector3.new(0, 1.8, 0)
	sign.MaxDistance = 50
	sign.LightInfluence = 0
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundColor3 = Color3.fromRGB(22, 163, 74)
	text.TextColor3 = Color3.new(1, 1, 1)
	text.Font = Enum.Font.GothamBold
	text.TextScaled = true
	text.Text = "VIRUS!"
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = text
	text.Parent = sign
	sign.Parent = attachment
	attachment.Parent = target
	return attachment
end

local function clear(seat: Seat)
	local entry = infected[seat]
	if not entry then
		return
	end
	infected[seat] = nil
	if entry.effect.Parent then
		entry.effect:Destroy()
	end
	seat:SetAttribute("Virus", nil)
	if next(infected) == nil then
		ReplicatedStorage:SetAttribute("OfficeVirus", false)
	end
end

function DisasterService.CanStart(): boolean
	if ReplicatedStorage:GetAttribute("ShiftReviewing") or ReplicatedStorage:GetAttribute("ShiftFired") then
		return false
	end
	local endsAt = ReplicatedStorage:GetAttribute("ShiftDayEndsAt") or 0
	return endsAt <= 0 or endsAt - workspace:GetServerTimeNow() > ShopConfig.DisasterCutoff
end

function DisasterService.Virus(byName: string): number
	nextToken += 1
	local token = nextToken
	local count = 0
	for _, seat in DeskService.Seats() do
		if seat:IsDescendantOf(workspace) and OfficeService.IsActive(seat) then
			local old = infected[seat]
			if old and old.effect.Parent then
				old.effect:Destroy()
			end
			local ok, effect = pcall(virusEffect, seat)
			infected[seat] = { effect = if ok then effect else Instance.new("Folder"), token = token, at = os.clock() }
			seat:SetAttribute("Virus", true)
			count += 1
		end
	end
	if count > 0 then
		ReplicatedStorage:SetAttribute("OfficeVirus", true)
	end
	event("Virus", byName, "", ShopConfig.Virus.Duration)
	task.delay(ShopConfig.Virus.Duration, function()
		local left = 0
		for seat, entry in table.clone(infected) do
			if entry.token == token then
				clear(seat)
				left += 1
			end
		end
		if left > 0 or count > 0 then
			event("VirusOver", byName, "", 0)
		end
	end)
	print(`[DisasterService] {byName} set off a virus attack ({count} computers)`)
	return count
end

function DisasterService.Chaos(byName: string)
	local chaos = ShopConfig.Chaos
	DisasterService.Virus(byName)
	ChoreService.Burst({ Trash = chaos.Trash, Desk = chaos.Messy, Fix = chaos.Broken })
	ChoreService.BoostRewards(chaos.ChoreMultiplier, chaos.ChoreBoostTime)
	local untilTime = workspace:GetServerTimeNow() + chaos.AlarmTime
	ReplicatedStorage:SetAttribute("OfficeAlarmUntil", untilTime)
	event("Chaos", byName, "", chaos.AlarmTime)
	task.delay(chaos.AlarmTime, function()
		if ReplicatedStorage:GetAttribute("OfficeAlarmUntil") == untilTime then
			ReplicatedStorage:SetAttribute("OfficeAlarmUntil", 0)
			event("ChaosOver", byName, "", 0)
		end
	end)
	print(`[DisasterService] {byName} set off office chaos`)
end

-- The player closed every pop-up at their desk.
local function onCleanVirus(_: nil, player: Player)
	local now = os.clock()
	if now - (lastClean[player] or 0) < CLEAN_COOLDOWN then
		return
	end
	lastClean[player] = now
	local seat = DeskService.SeatOf(player)
	local entry = seat and infected[seat]
	if not seat or not entry or not DeskService.IsLoggedIn(player) or now - entry.at < MIN_CLEAN_TIME then
		return
	end
	clear(seat)
	local reward = EconomyService.Award(player, ShopConfig.Virus.CleanReward)
	message(player, `Virus removed! +{Format.money(reward)}`, 2)
end

function DisasterService.Start()
	ReplicatedStorage:SetAttribute("OfficeAlarmUntil", 0)
	ReplicatedStorage:SetAttribute("OfficeVirus", false)
	Shop.packets.CleanVirus.listen(onCleanVirus)
	-- A new floor starts clean.
	OfficeService.OnFloorChanged(function()
		for seat in table.clone(infected) do
			clear(seat)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastClean[player] = nil
	end)
end

return DisasterService
