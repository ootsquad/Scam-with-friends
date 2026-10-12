--[[
	CallVoice (client)
	The caller's voice on phone calls: AudioTextToSpeech -> AudioDeviceOutput, created on this client only,
	so nobody else hears your caller. Lines are queued and read one at a time.

	Text-to-speech is a Roblox beta with limits: it only works in a saved/published place, max 300 characters
	per line and about one request per second per experience. If it isn't available the call carries on in
	text. (You never talk: you pick cards.)

	CallVoice.Speak(text, voiceId)   CallVoice.StopSpeaking()
	CallVoice.SetVoiceEnabled(on)    CallVoice.VoiceEnabled
	CallVoice.SetVolume(0..1)        caller voice volume (Settings: master x voices)
	CallVoice.Changed()              fires when VoiceEnabled changes
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared.Util.Signal)

local MAX_CHUNK = 300
local LOAD_GAP = 1.05 -- seconds between speech requests (Roblox rate limit)

local CallVoice = {
	VoiceEnabled = true,
	Changed = Signal.new(),
}

-- ---------------------------------------------------------------------------
-- Caller's voice (text-to-speech)
-- ---------------------------------------------------------------------------

local speaker: any = nil
local volume = 1
local queue: { { text: string, voice: string } } = {}
local speaking = false
local speakToken = 0
local lastLoad = -math.huge
local ttsBroken = false

local function ensureSpeaker(): boolean
	if speaker then
		return true
	end
	if ttsBroken then
		return false
	end
	local ok, err = pcall(function()
		local tts = Instance.new("AudioTextToSpeech")
		tts.Name = "CallerVoice"
		local output = Instance.new("AudioDeviceOutput")
		output.Name = "CallerVoiceOutput"
		local wire = Instance.new("Wire")
		wire.SourceInstance = tts
		wire.TargetInstance = output
		wire.Parent = tts
		output.Parent = SoundService
		tts.Volume = volume
		tts.Parent = SoundService
		speaker = tts
	end)
	if not ok then
		ttsBroken = true
		warn(`[CallVoice] text-to-speech isn't available here: {err}`)
	end
	return ok
end

-- Splits text into chunks under the text-to-speech limit, preferring sentence breaks.
local function chunks(text: string): { string }
	local out = {}
	local rest = text
	while #rest > MAX_CHUNK do
		local cut = 0
		for i = MAX_CHUNK, 1, -1 do
			local c = string.sub(rest, i, i)
			if c == "." or c == "!" or c == "?" then
				cut = i
				break
			end
		end
		if cut == 0 then
			cut = string.find(string.sub(rest, 1, MAX_CHUNK), " [^ ]*$") or MAX_CHUNK
		end
		table.insert(out, string.sub(rest, 1, cut))
		rest = string.gsub(string.sub(rest, cut + 1), "^%s+", "")
	end
	if rest ~= "" then
		table.insert(out, rest)
	end
	return out
end

local function playOne(text: string, voice: string, token: number)
	local wait = LOAD_GAP - (os.clock() - lastLoad)
	if wait > 0 then
		task.wait(wait)
	end
	if token ~= speakToken then
		return
	end
	lastLoad = os.clock()
	local ok, status = pcall(function()
		speaker.Text = text
		speaker.VoiceId = voice
		speaker.TimePosition = 0
		return speaker:LoadAsync()
	end)
	if not ok or status ~= Enum.AssetFetchStatus.Success or token ~= speakToken then
		return
	end
	local finished = false
	local connection = speaker.Ended:Connect(function()
		finished = true
	end)
	pcall(function()
		speaker:Play()
	end)
	local deadline = os.clock() + math.max(speaker.TimeLength, 1) + 1.5
	while not finished and token == speakToken and os.clock() < deadline do
		task.wait(0.1)
	end
	connection:Disconnect()
end

local function pump()
	if speaking then
		return
	end
	speaking = true
	local token = speakToken
	while #queue > 0 and token == speakToken do
		local item = table.remove(queue, 1) :: any
		playOne(item.text, item.voice, token)
	end
	-- StopSpeaking may have handed the speaker to a newer pump while this one was waiting.
	if token == speakToken then
		speaking = false
	end
end

function CallVoice.Speak(text: string, voiceId: string)
	if not CallVoice.VoiceEnabled or text == "" or not ensureSpeaker() then
		return
	end
	for _, piece in chunks(text) do
		table.insert(queue, { text = piece, voice = voiceId })
	end
	task.spawn(pump)
end

function CallVoice.StopSpeaking()
	speakToken += 1
	queue = {}
	speaking = false
	if speaker then
		pcall(function()
			speaker:Pause()
		end)
	end
end

function CallVoice.SetVolume(value: number)
	volume = math.clamp(value, 0, 1)
	if speaker then
		pcall(function()
			speaker.Volume = volume
		end)
	end
end

function CallVoice.SetVoiceEnabled(on: boolean)
	CallVoice.VoiceEnabled = on
	if not on then
		CallVoice.StopSpeaking()
	end
	CallVoice.Changed:Fire()
end

return CallVoice
