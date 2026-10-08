--[[
	CallVoice (client)
	Voice for phone calls, using Roblox's own audio APIs:

	  Caller's voice   AudioTextToSpeech -> AudioDeviceOutput, created on this client only, so nobody else
	                   hears your caller. Lines are queued and read one at a time.
	  Your voice       AudioDeviceInput (your mic) -> AudioSpeechToText; each sentence you say becomes text
	                   that's sent to the call like a typed line. MicFilter drops transcripts that don't
	                   come from you actually talking (mouse clicks, desk noise, the caller's voice echoing
	                   out of your speakers): Roblox has to have heard a voice for long enough, and noise
	                   words like a lone "the" or "you" are ignored.

	Both are Roblox betas with limits: text-to-speech only works in a saved/published place, max 300
	characters per line and about one request per second per experience; speech-to-text needs Roblox voice
	chat (13+, verified) and is English only. If either isn't available the call carries on in text.

	CallVoice.Speak(text, voiceId)   CallVoice.StopSpeaking()
	CallVoice.SetVoiceEnabled(on)    CallVoice.VoiceEnabled
	CallVoice.SetVolume(0..1)        caller voice volume (Settings: master x voices)
	CallVoice.SetMic(on) -> (ok, message?)   CallVoice.MicOn   CallVoice.Hearing (voice detected)
	CallVoice.Changed()              fires when VoiceEnabled / MicOn / Hearing change
	CallVoice.Heard(text)            fires with each transcribed sentence that passed MicFilter
	CallVoice.Ignored(text, reason)  fires with each transcript MicFilter dropped
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local VoiceChatService = game:GetService("VoiceChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CallConfig = require(Shared.Config.CallConfig)
local Signal = require(Shared.Util.Signal)
local MicFilter = require(script.Parent.MicFilter)

local MAX_CHUNK = 300
local LOAD_GAP = 1.05 -- seconds between speech requests (Roblox rate limit)

local player = Players.LocalPlayer

local CallVoice = {
	VoiceEnabled = true,
	MicOn = false,
	Hearing = false,
	Changed = Signal.new(),
	Heard = Signal.new(),
	Ignored = Signal.new(),
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

-- What the caller said out loud lately, so their voice echoing back into your mic isn't sent as yours.
local CALLER_MEMORY = 20 -- seconds
local callerPlaying = false
local callerStoppedAt = -math.huge
local callerSaid: { { text: string, at: number } } = {}

local function rememberCallerLine(text: string)
	local now = os.clock()
	table.insert(callerSaid, { text = text, at = now })
	while #callerSaid > 0 and now - callerSaid[1].at > CALLER_MEMORY do
		table.remove(callerSaid, 1)
	end
end

local function recentCallerText(): string
	local now = os.clock()
	local parts = {}
	for _, line in callerSaid do
		if now - line.at <= CALLER_MEMORY then
			table.insert(parts, line.text)
		end
	end
	return table.concat(parts, " ")
end

local function callerAudible(): boolean
	return callerPlaying or os.clock() - callerStoppedAt < CallConfig.Mic.EchoTail
end

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
	rememberCallerLine(text)
	callerPlaying = true
	pcall(function()
		speaker:Play()
	end)
	local deadline = os.clock() + math.max(speaker.TimeLength, 1) + 1.5
	while not finished and token == speakToken and os.clock() < deadline do
		task.wait(0.1)
	end
	connection:Disconnect()
	callerPlaying = false
	callerStoppedAt = os.clock()
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
	if callerPlaying then
		callerPlaying = false
		callerStoppedAt = os.clock()
	end
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

-- ---------------------------------------------------------------------------
-- Your voice (speech-to-text)
-- ---------------------------------------------------------------------------

local listener: any = nil
local listenerConnections: { RBXScriptConnection } = {}
local voiceAllowed: boolean? = nil
local VOICE_FORGET = 12 -- seconds of quiet after which earlier stray noise no longer counts as voice
local voiceSeconds = 0 -- voice Roblox detected since the last transcript
local lastVoiceAt = -math.huge
local voiceWorks = false -- voice detection has fired at least once on this device

local function canUseVoice(): boolean
	if voiceAllowed == nil then
		local ok, allowed = pcall(function()
			return VoiceChatService:IsVoiceEnabledForUserIdAsync(player.UserId)
		end)
		if not ok then
			return false -- couldn't check (network blip): ask again next time
		end
		voiceAllowed = allowed == true
	end
	return voiceAllowed == true
end

local function setHearing(value: boolean)
	if CallVoice.Hearing ~= value then
		CallVoice.Hearing = value
		CallVoice.Changed:Fire()
	end
end

local function ensureListener(): boolean
	if listener then
		return true
	end
	local ok, err = pcall(function()
		local input = player:FindFirstChildOfClass("AudioDeviceInput")
		if not input then
			input = Instance.new("AudioDeviceInput")
			input.Name = "CallMic"
			input.Player = player
			input.Parent = player
		end
		local stt = Instance.new("AudioSpeechToText")
		stt.Name = "CallTranscriber"
		stt.Enabled = false
		local wire = Instance.new("Wire")
		wire.SourceInstance = input
		wire.TargetInstance = stt
		wire.Parent = stt
		stt.Parent = SoundService

		table.insert(listenerConnections, stt:GetPropertyChangedSignal("Text"):Connect(function()
			local heard = stt.Text
			if heard == "" then
				return
			end
			stt.Text = ""
			local seconds = if os.clock() - lastVoiceAt <= VOICE_FORGET then voiceSeconds else 0
			voiceSeconds = 0
			if not CallVoice.MicOn then
				return
			end
			local ok, result = MicFilter.Check(heard, {
				VoiceSeconds = seconds,
				VoiceWorks = voiceWorks,
				CallerAudible = callerAudible(),
				CallerText = recentCallerText(),
			})
			if ok then
				CallVoice.Heard:Fire(result)
			else
				if RunService:IsStudio() then
					print(`[CallVoice] ignored "{heard}": {result}`)
				end
				CallVoice.Ignored:Fire(heard, result)
			end
		end))
		-- VoiceDetected is polled: it's how long Roblox heard a voice that tells talking apart from noise.
		table.insert(listenerConnections, RunService.Heartbeat:Connect(function(dt)
			if not CallVoice.MicOn then
				return
			end
			local detected = stt.VoiceDetected == true
			if detected then
				local now = os.clock()
				if now - lastVoiceAt > VOICE_FORGET then
					voiceSeconds = 0
				end
				voiceSeconds += dt
				lastVoiceAt = now
				voiceWorks = true
			end
			setHearing(detected)
		end))
		listener = stt
	end)
	if not ok then
		warn(`[CallVoice] speech-to-text isn't available here: {err}`)
	end
	return ok
end

-- Turns your mic transcription on or off. Returns false and a reason if voice can't be used.
function CallVoice.SetMic(on: boolean): (boolean, string?)
	if on then
		if not canUseVoice() then
			return false, "Talking needs Roblox voice chat (13+ and verified). You can type instead."
		end
		if not ensureListener() then
			return false, "Voice isn't available in this server. Type instead."
		end
	end
	CallVoice.MicOn = on
	voiceSeconds = 0
	if listener then
		pcall(function()
			listener.Enabled = on
			if on then
				listener.Text = "" -- nothing left over from before the mic was on
			end
		end)
	end
	if not on then
		setHearing(false)
	end
	CallVoice.Changed:Fire()
	return true, nil
end

return CallVoice
