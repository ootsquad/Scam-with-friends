--[[
	PerkService (server, Call Center Place)
	What each player gets from game passes and Robux items (ShopConfig):

	  2x cash        Permanent 2x Cash, or time on the clock: the 15 min / 1 hour passes give that much at the
	                 start of every shift, and each 2x Cash product adds 15 minutes (saved until it's used).
	                 The clock only runs while the work day does. 2x sources don't stack with each other.
	  Team Leader    everyone else in the server earns TeamLeaderBonus more (one bonus however many leaders).
	  On-call tips   FreeTipsPerShift free uses of the Ideas (lightbulb) button per shift (VipFreeTips for VIPs), then the
	                 tips bought with Extra Tips (saved in the career until used).
	  Call saves     Save My Call credits (saved in the career), plus VipFreeSaves free ones per shift for VIPs.
	  VIP            a VIP nametag and chat tag, the extras above, and the VIP outfit / emotes in ShopConfig.Vip.

	A shift is one server, so the per-shift allowances are kept by UserId (leaving and coming back doesn't
	reset them).

	Player attributes (read by the client): Passes ("VIP,TeamLeader"), BoostPermanent, BoostSeconds, TeamBonus,
	TipsFree, TipCredits, SavesFree, CallSaves, VIP, TeamLeader.

	PerkService.Start()
	PerkService.Owns(player, passKey) -> boolean
	PerkService.GrantPass(player, passKey)            a pass was bought (or for tests)
	PerkService.Multiplier(player) -> number          what their earnings are multiplied by right now
	PerkService.HasDoubleCash(player) -> boolean
	PerkService.SetTicking(on)                        the work day is running (EconomyService)
	PerkService.AddBoost(player, seconds) / AddTips(player, n) / AddSaves(player, n)
	PerkService.TipsLeft(player) -> number
	PerkService.UseTip(player) -> boolean
	PerkService.SavesLeft(player) -> number
	PerkService.UseSave(player) -> string?            "Free" | "Bought" (nil = none left)
	PerkService.ReturnSave(player, kind)              gives back a save that couldn't be used
	PerkService.Refresh(player)                       re-publish their attributes
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShopConfig = require(Shared.Config.ShopConfig)
local CareerService = require(script.Parent.CareerService)
local PlayerLookService = require(script.Parent.PlayerLookService)

local OWNERSHIP_ATTEMPTS = 3
local TAG_NAME = "PerkTag"

local PerkService = {}

type Allowance = {
	passTime: number, -- 2x seconds left from the 15 min / 1 hour passes this shift
	passGranted: { [string]: boolean }, -- timed passes already counted this shift
	freeTips: number,
	freeSaves: number,
	vipCounted: boolean,
}

local owned: { [Player]: { [string]: boolean } } = {}
local allowances: { [number]: Allowance } = {} -- by UserId, for the whole server (= the shift)
local ticking = false

local function allowanceOf(player: Player): Allowance
	local allowance = allowances[player.UserId]
	if not allowance then
		allowance = {
			passTime = 0,
			passGranted = {},
			freeTips = ShopConfig.FreeTipsPerShift,
			freeSaves = 0,
			vipCounted = false,
		}
		allowances[player.UserId] = allowance
	end
	return allowance
end

function PerkService.Owns(player: Player, key: string): boolean
	local passes = owned[player]
	return passes ~= nil and passes[key] == true
end

local function teamBonus(player: Player): boolean
	for _, other in Players:GetPlayers() do
		if other ~= player and PerkService.Owns(other, "TeamLeader") then
			return true
		end
	end
	return false
end

local function timedSeconds(player: Player): number
	return allowanceOf(player).passTime + CareerService.Credit(player, "BoostSeconds")
end

function PerkService.HasDoubleCash(player: Player): boolean
	return PerkService.Owns(player, "CashForever") or timedSeconds(player) > 0
end

function PerkService.Multiplier(player: Player): number
	local multiplier = if PerkService.HasDoubleCash(player) then ShopConfig.CashMultiplier else 1
	if teamBonus(player) then
		multiplier *= 1 + ShopConfig.TeamLeaderBonus
	end
	return multiplier
end

-- ---------------------------------------------------------------------------
-- Nametag (VIP / Team Leader)
-- ---------------------------------------------------------------------------

local function pill(parent: Instance, name: string, text: string, color: Color3, order: number)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = UDim2.new(0, if #text > 4 then 104 else 44, 1, 0)
	label.BackgroundColor3 = color
	label.TextColor3 = Color3.fromRGB(20, 20, 20)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = text
	label.LayoutOrder = order
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = label
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 6)
	padding.PaddingRight = UDim.new(0, 6)
	padding.PaddingTop = UDim.new(0, 2)
	padding.PaddingBottom = UDim.new(0, 2)
	padding.Parent = label
	label.Parent = parent
end

local function updateTag(player: Player)
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not head then
		return
	end
	local old = head:FindFirstChild(TAG_NAME)
	if old then
		old:Destroy()
	end
	local vip, leader = PerkService.Owns(player, "VIP"), PerkService.Owns(player, "TeamLeader")
	if not vip and not leader then
		return
	end
	local tag = Instance.new("BillboardGui")
	tag.Name = TAG_NAME
	tag.Size = UDim2.fromOffset(160, 22)
	tag.StudsOffset = Vector3.new(0, 3.2, 0)
	tag.MaxDistance = 70
	tag.LightInfluence = 0
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = tag
	if vip then
		pill(tag, "VIP", "VIP", Color3.fromHex(ShopConfig.Vip.NametagColor), 1)
	end
	if leader then
		pill(tag, "TeamLeader", "TEAM LEADER", Color3.fromRGB(34, 211, 238), 2)
	end
	tag.Parent = head
end

-- VIPs wear the VIP outfit (if one is set up) and get the VIP emotes.
local function decorate(player: Player, description: HumanoidDescription)
	if not PerkService.Owns(player, "VIP") then
		return
	end
	local vip = ShopConfig.Vip
	if vip.Shirt > 0 then
		description.Shirt = vip.Shirt
	end
	if vip.Pants > 0 then
		description.Pants = vip.Pants
	end
	if next(vip.Emotes) then
		pcall(function()
			local emotes = description:GetEmotes()
			local equipped = description:GetEquippedEmotes()
			for name, id in vip.Emotes do
				emotes[name] = { id }
				if #equipped < 8 then
					table.insert(equipped, { Name = name, Slot = #equipped + 1 })
				end
			end
			description:SetEmotes(emotes)
			description:SetEquippedEmotes(equipped)
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Attributes
-- ---------------------------------------------------------------------------

function PerkService.Refresh(player: Player)
	if not player.Parent then
		return
	end
	local allowance = allowanceOf(player)
	local passes = {}
	for _, item in ShopConfig.Passes do
		if PerkService.Owns(player, item.Key) then
			table.insert(passes, item.Key)
		end
	end
	player:SetAttribute("Passes", table.concat(passes, ","))
	player:SetAttribute("BoostPermanent", PerkService.Owns(player, "CashForever"))
	player:SetAttribute("BoostSeconds", timedSeconds(player))
	player:SetAttribute("TeamBonus", teamBonus(player))
	player:SetAttribute("TipsFree", allowance.freeTips)
	player:SetAttribute("TipCredits", CareerService.Credit(player, "TipCredits"))
	player:SetAttribute("SavesFree", allowance.freeSaves)
	player:SetAttribute("CallSaves", CareerService.Credit(player, "CallSaves"))
	player:SetAttribute("VIP", PerkService.Owns(player, "VIP"))
	player:SetAttribute("TeamLeader", PerkService.Owns(player, "TeamLeader"))
end

local function refreshAll()
	for _, player in Players:GetPlayers() do
		PerkService.Refresh(player)
	end
end

-- ---------------------------------------------------------------------------
-- Passes
-- ---------------------------------------------------------------------------

-- What a pass gives this shift (once per pass per shift).
local function applyPass(player: Player, key: string)
	local allowance = allowanceOf(player)
	local item = ShopConfig.Pass(key)
	if item and item.BoostSeconds and not allowance.passGranted[key] then
		allowance.passGranted[key] = true
		allowance.passTime += item.BoostSeconds
	end
	if key == "VIP" and not allowance.vipCounted then
		allowance.vipCounted = true
		allowance.freeTips += math.max(0, ShopConfig.VipFreeTips - ShopConfig.FreeTipsPerShift)
		allowance.freeSaves += ShopConfig.VipFreeSaves
	end
end

function PerkService.GrantPass(player: Player, key: string)
	if not ShopConfig.Pass(key) then
		return
	end
	local passes = owned[player]
	if not passes then
		passes = {}
		owned[player] = passes
	end
	if passes[key] then
		return
	end
	passes[key] = true
	applyPass(player, key)
	if key == "VIP" or key == "TeamLeader" then
		updateTag(player)
	end
	if key == "VIP" then
		PlayerLookService.Refresh(player)
	end
	refreshAll() -- Team Leader changes everyone else's bonus
end

local function loadPasses(player: Player)
	owned[player] = owned[player] or {}
	if player.UserId <= 0 then
		PerkService.Refresh(player)
		return -- Studio test players can't own passes
	end
	for _, item in ShopConfig.Passes do
		for attempt = 1, OWNERSHIP_ATTEMPTS do
			local ok, has = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, item.Id)
			end)
			if ok then
				if has and player.Parent then
					PerkService.GrantPass(player, item.Key)
				end
				break
			end
			if attempt == OWNERSHIP_ATTEMPTS then
				warn(`[PerkService] couldn't check {player.Name}'s {item.Name} pass: {has}`)
			else
				task.wait(attempt)
			end
		end
		if not player.Parent then
			return
		end
	end
	PerkService.Refresh(player)
end

-- ---------------------------------------------------------------------------
-- Credits
-- ---------------------------------------------------------------------------

function PerkService.AddBoost(player: Player, seconds: number)
	CareerService.AddCredit(player, "BoostSeconds", seconds)
	PerkService.Refresh(player)
end

function PerkService.AddTips(player: Player, count: number)
	CareerService.AddCredit(player, "TipCredits", count)
	PerkService.Refresh(player)
end

function PerkService.AddSaves(player: Player, count: number)
	CareerService.AddCredit(player, "CallSaves", count)
	PerkService.Refresh(player)
end

function PerkService.TipsLeft(player: Player): number
	return allowanceOf(player).freeTips + CareerService.Credit(player, "TipCredits")
end

-- Uses one on-call tip: a free one first, then a bought one. false when there are none left.
function PerkService.UseTip(player: Player): boolean
	local allowance = allowanceOf(player)
	if allowance.freeTips > 0 then
		allowance.freeTips -= 1
	elseif CareerService.Credit(player, "TipCredits") > 0 then
		CareerService.AddCredit(player, "TipCredits", -1)
	else
		return false
	end
	PerkService.Refresh(player)
	return true
end

function PerkService.SavesLeft(player: Player): number
	return allowanceOf(player).freeSaves + CareerService.Credit(player, "CallSaves")
end

function PerkService.UseSave(player: Player): string?
	local allowance = allowanceOf(player)
	local kind
	if allowance.freeSaves > 0 then
		allowance.freeSaves -= 1
		kind = "Free"
	elseif CareerService.Credit(player, "CallSaves") > 0 then
		CareerService.AddCredit(player, "CallSaves", -1)
		kind = "Bought"
	else
		return nil
	end
	PerkService.Refresh(player)
	return kind
end

function PerkService.ReturnSave(player: Player, kind: string?)
	if kind == "Free" then
		allowanceOf(player).freeSaves += 1
	elseif kind == "Bought" then
		CareerService.AddCredit(player, "CallSaves", 1)
	end
	PerkService.Refresh(player)
end

function PerkService.SetTicking(on: boolean)
	ticking = on
end

-- One second of the work day: timed 2x runs down (this shift's pass time first, then bought time).
local function tick()
	for _, player in Players:GetPlayers() do
		if ticking and CareerService.IsLoaded(player) and not PerkService.Owns(player, "CashForever") then
			local allowance = allowanceOf(player)
			if allowance.passTime > 0 then
				allowance.passTime -= 1
			elseif CareerService.Credit(player, "BoostSeconds") > 0 then
				CareerService.AddCredit(player, "BoostSeconds", -1)
			end
		end
		PerkService.Refresh(player)
	end
end

function PerkService.Start()
	PlayerLookService.SetDecorator(decorate)
	-- A pass was bought in game: check with Roblox before granting it (Studio's test purchases can't be checked).
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, purchased: boolean)
		local item = ShopConfig.PassById(passId)
		if not purchased or not item or not player.Parent then
			return
		end
		if RunService:IsStudio() then
			PerkService.GrantPass(player, item.Key) -- a Studio test purchase
			return
		end
		for attempt = 1, OWNERSHIP_ATTEMPTS + 2 do
			local ok, has = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, item.Id)
			end)
			if ok and has then
				if player.Parent then
					PerkService.GrantPass(player, item.Key)
				end
				return
			end
			task.wait(attempt)
		end
		warn(`[PerkService] {player.Name} bought {item.Name}, but Roblox doesn't show it yet; it applies next time`)
	end)
	local function onPlayer(player: Player)
		allowanceOf(player)
		player.CharacterAdded:Connect(function(character)
			character:WaitForChild("Head", 10)
			updateTag(player)
		end)
		task.spawn(loadPasses, player)
		if player.Character then
			task.spawn(updateTag, player)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		owned[player] = nil
		task.defer(refreshAll) -- a Team Leader leaving ends everyone else's bonus
	end)
	task.spawn(function()
		while true do
			task.wait(1)
			tick()
		end
	end)
end

return PerkService
