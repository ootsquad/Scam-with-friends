--[[
	TextFilter (server, Call Center Place)
	Every piece of free text in a call goes through Roblox's text filter here, once:

	  TextFilter.Player(player, text)   what the player typed or said, shown back to them and sent to the
	                                    caller. Filtered for that player (their age and chat settings).
	  TextFilter.Caller(player, text)   what the AI caller says. It isn't anyone's chat, so it's filtered like
	                                    sign text everyone can see (GetNonChatStringForBroadcastAsync): the
	                                    same strict filter for every player, whatever their own chat settings.
	                                    If that isn't available, it falls back to the player's own filter.

	Both return (shown, hiddenShare): the filtered text (nil if the filter couldn't run) and how much of it
	Roblox hid (0 = nothing, 1 = everything).

	Roblox only lets accounts that passed its age check chat (since January 2026). For an account that
	can't chat, the filter hides everything that player types or says, even "Hello". TextFilter.CanChat()
	finds out (TextChatService:CanUserChatAsync) so the game can say so and offer ready-made lines instead.

	With CallConfig.LogFilter on, every line the filter hid any of is printed to the server output (F9 >
	Server in a live game) with what was hidden and why, so filter problems can be tracked down.

	TextFilter.CanChat(player) -> boolean?    nil = unknown (Studio test player, or the check failed)
	TextFilter.hiddenShare(original, filtered) -> number
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local TextService = game:GetService("TextService")

local CallConfig = require(ReplicatedStorage:WaitForChild("Shared").Config.CallConfig)

local TextFilter = {}

local canChat: { [Player]: boolean } = {}
local checkFailed: { [Player]: boolean } = {} -- the check errored once; don't keep asking
local warnedFailure = false
local warnedBroadcast = false

-- How much of `original` Roblox's filter replaced with # (0 to 1).
function TextFilter.hiddenShare(original: string, filtered: string): number
	local letters = #string.gsub(original, "%s", "")
	if letters == 0 then
		return 0
	end
	local _, before = string.gsub(original, "#", "")
	local _, after = string.gsub(filtered, "#", "")
	return math.clamp((after - before) / letters, 0, 1)
end

function TextFilter.CanChat(player: Player): boolean?
	if player.UserId <= 0 then
		return nil -- Studio test player
	end
	local known = canChat[player]
	if known ~= nil then
		return known
	elseif checkFailed[player] then
		return nil
	end
	local ok, allowed = pcall(function()
		return TextChatService:CanUserChatAsync(player.UserId)
	end)
	if not ok or type(allowed) ~= "boolean" then
		if player.Parent then
			checkFailed[player] = true
		end
		return nil
	end
	if player.Parent then
		canChat[player] = allowed
		player:SetAttribute("CanChat", allowed)
	end
	return allowed
end

local function log(kind: string, player: Player, original: string, shown: string, share: number, how: string)
	if not CallConfig.LogFilter or share <= 0 then
		return
	end
	local chat = canChat[player] -- only what's already known; logging never waits on a check
	print(
		`[TextFilter] {kind} line for {player.Name} ({how}, can chat: {if chat == nil then "unknown" else tostring(chat)}): `
			.. `{math.round(share * 100)}% hidden\n    sent:  {original}\n    shown: {shown}`
	)
end

local function filterResult(text: string, fromUserId: number): any
	local ok, result = pcall(function()
		return TextService:FilterStringAsync(text, fromUserId, Enum.TextFilterContext.PrivateChat)
	end)
	if not ok then
		if not warnedFailure then
			warnedFailure = true
			warn(`[TextFilter] Roblox's text filter failed ({result}); using fallbacks`)
		end
		return nil
	end
	return result
end

-- What the player typed or said, filtered for them. In Studio (where test players can't always be
-- filtered) and if the filter is down, their own words are shown as-is.
function TextFilter.Player(player: Player, text: string): (string?, number)
	local result = filterResult(text, player.UserId)
	local shown: string? = nil
	if result then
		local ok, value = pcall(function()
			return result:GetNonChatStringForUserAsync(player.UserId)
		end)
		if ok and type(value) == "string" then
			shown = value
		end
	end
	if not shown then
		return text, 0 -- the player's own words, shown only to them
	end
	local share = TextFilter.hiddenShare(text, shown)
	log("player", player, text, shown, share, "for them")
	return shown, share
end

-- What the AI caller said, filtered like public sign text (the same for everyone).
function TextFilter.Caller(player: Player, text: string): (string?, number)
	local result = filterResult(text, player.UserId)
	if not result then
		if RunService:IsStudio() then
			return text, 0
		end
		return nil, 1
	end
	local how = "broadcast"
	local ok, value = pcall(function()
		return result:GetNonChatStringForBroadcastAsync()
	end)
	if not ok or type(value) ~= "string" then
		if not warnedBroadcast then
			warnedBroadcast = true
			warn(`[TextFilter] broadcast filtering failed ({value}); filtering caller lines per player instead`)
		end
		how = "for them"
		ok, value = pcall(function()
			return result:GetNonChatStringForUserAsync(player.UserId)
		end)
	end
	if not ok or type(value) ~= "string" then
		return if RunService:IsStudio() then text else nil, if RunService:IsStudio() then 0 else 1
	end
	local share = TextFilter.hiddenShare(text, value)
	log("caller", player, text, value, share, how)
	return value, share
end

function TextFilter.Start()
	Players.PlayerAdded:Connect(function(player)
		task.spawn(TextFilter.CanChat, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(TextFilter.CanChat, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		canChat[player] = nil
		checkFailed[player] = nil
	end)
end

return TextFilter
