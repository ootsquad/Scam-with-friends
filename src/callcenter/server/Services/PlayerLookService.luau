--[[
	PlayerLookService (server, Call Center Place)
	Makes sure every player looks like their own Roblox avatar: once their character has loaded, their real
	HumanoidDescription (body, clothes, accessories, animations) is applied to it. That covers places where a
	StarterCharacter or the game's avatar settings would otherwise replace it with a plain rig.

	Avatars need R15 for the full look (Game Settings > Avatar > Avatar Type: R15). The Output warns if a
	StarterCharacter is set or a character spawns as R6.

	PlayerLookService.Start()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local CallConfig = require(ReplicatedStorage:WaitForChild("Shared").Config.CallConfig)

local APPEARANCE_WAIT = 10 -- seconds to wait for Roblox to load the avatar before applying ours

local PlayerLookService = {}

local descriptions: { [number]: HumanoidDescription } = {}
local warnedR6 = false

local function descriptionFor(userId: number): HumanoidDescription?
	local cached = descriptions[userId]
	if cached then
		return cached
	end
	local ok, description = pcall(function()
		return Players:GetHumanoidDescriptionFromUserId(userId)
	end)
	if ok and description then
		descriptions[userId] = description
		return description
	end
	return nil
end

local function apply(player: Player, character: Model)
	if player.UserId <= 0 then
		return -- Studio test players have no avatar to load
	end
	local humanoid = character:WaitForChild("Humanoid", APPEARANCE_WAIT) :: Humanoid?
	if not humanoid then
		return
	end
	if humanoid.RigType ~= Enum.HumanoidRigType.R15 and not warnedR6 then
		warnedR6 = true
		warn("[PlayerLookService] characters are R6. Set Game Settings > Avatar > Avatar Type to R15 so "
			.. "players look like their full Roblox avatars.")
	end
	local loaded = pcall(function()
		if not player:HasAppearanceLoaded() then
			local done = false
			local connection = player.CharacterAppearanceLoaded:Connect(function()
				done = true
			end)
			local deadline = os.clock() + APPEARANCE_WAIT
			while not done and os.clock() < deadline and character.Parent do
				task.wait(0.2)
			end
			connection:Disconnect()
		end
	end)
	if not loaded or not character.Parent then
		return
	end
	local description = descriptionFor(player.UserId)
	if not description then
		return
	end
	local ok, err = pcall(function()
		humanoid:ApplyDescriptionAsync(description:Clone())
	end)
	if not ok then
		warn(`[PlayerLookService] couldn't apply {player.Name}'s avatar: {err}`)
	end
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(apply, player, character)
	end)
	if player.Character then
		task.spawn(apply, player, player.Character)
	end
end

function PlayerLookService.Start()
	if not CallConfig.UseRealAvatars then
		return
	end
	if StarterPlayer:FindFirstChild("StarterCharacter") then
		warn("[PlayerLookService] StarterPlayer has a StarterCharacter, so players spawn as that rig. Their own "
			.. "avatars are applied on top; remove the StarterCharacter if you don't need it.")
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		local cached = descriptions[player.UserId]
		if cached then
			cached:Destroy()
			descriptions[player.UserId] = nil
		end
	end)
end

return PlayerLookService
