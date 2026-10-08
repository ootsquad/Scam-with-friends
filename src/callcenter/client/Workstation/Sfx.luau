--[[
	Sfx (client, Call Center Place)
	Sound effects and volumes. Every effect plays through the "Effects" SoundGroup, and the caller's voice
	goes through CallVoice; both follow the Settings app (master x effects, master x voices).
	Sound ids live in OfficeConfig.Sounds.

	Sfx.Start()
	Sfx.Play(name)            "Notify" | "Payout" | "Ding" | "Chore" | "Error" | "Click"
	Sfx.SetRinging(on)        the incoming-call ring, repeated until turned off
]]

local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OfficeConfig = require(Shared.Config.OfficeConfig)
local SettingsConfig = require(Shared.Config.SettingsConfig)

local Client = script.Parent.Parent
local SettingsStore = require(Client:WaitForChild("Stores"):WaitForChild("SettingsStore"))
local CallVoice = require(script.Parent.CallVoice)

local Sfx = {}

local group: SoundGroup? = nil
local sounds: { [string]: Sound } = {}
local ringToken = 0

local function level(settings: any, key: string): number
	local value = settings[key]
	if type(value) ~= "number" then
		value = (SettingsConfig.Defaults :: any)[key]
	end
	return math.clamp(value / 100, 0, 1)
end

local function apply(settings: any)
	local master = level(settings, "MasterVolume")
	if group then
		group.Volume = master * level(settings, "EffectsVolume")
	end
	CallVoice.SetVolume(master * level(settings, "VoiceVolume"))
end

function Sfx.Start()
	local effects = Instance.new("SoundGroup")
	effects.Name = "Effects"
	effects.Parent = SoundService
	group = effects
	for name, info in OfficeConfig.Sounds do
		local sound = Instance.new("Sound")
		sound.Name = name
		sound.SoundId = info.Id
		sound.Volume = info.Volume
		sound.PlaybackSpeed = info.Speed
		sound.SoundGroup = effects
		sound.Parent = effects
		sounds[name] = sound
	end
	SettingsStore.Changed:Connect(apply)
	apply(SettingsStore.Settings)
end

function Sfx.Play(name: string)
	local sound = sounds[name]
	if sound then
		pcall(function()
			sound.TimePosition = 0
			sound:Play()
		end)
	end
end

function Sfx.SetRinging(on: boolean)
	ringToken += 1
	if not on then
		return
	end
	local token = ringToken
	task.spawn(function()
		while token == ringToken do
			Sfx.Play("Ring")
			task.wait(0.22)
			if token ~= ringToken then
				break
			end
			Sfx.Play("Ring")
			task.wait(1.4)
		end
	end)
end

return Sfx
