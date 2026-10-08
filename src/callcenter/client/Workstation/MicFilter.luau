--!strict
--[[
	MicFilter (client)
	Decides whether a speech-to-text result is something you really said. Speech-to-text guesses words
	from any sound it gets, so a mouse click, a desk bump or breathing can come out as "the", "you" or
	"thank you", and the caller's voice coming out of your speakers can come back in as your own line.

	A transcript is ignored when:
	  - it's only filler sounds (uh, um, hmm) or bracketed noise ([Music], (keyboard clicking))
	  - it's one of the words or phrases speech-to-text makes up from noise ("you", "the", "thank you", ...)
	  - Roblox heard less than CallConfig.Mic.MinVoiceSeconds of voice before it arrived
	  - it has more words than you had time to say in the voice Roblox heard
	  - on a device where Roblox never reports a voice, it's a single word
	  - it repeats what the caller just said while their voice was playing (echo from your speakers)

	MicFilter.Check(text, heard) -> (ok, cleanText | reason)
		heard.VoiceSeconds   seconds of voice Roblox detected since the last transcript
		heard.VoiceWorks     whether voice detection has ever fired on this device
		heard.CallerAudible  whether the caller's voice is playing now or only just stopped
		heard.CallerText     what the caller said recently
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CallConfig = require(ReplicatedStorage:WaitForChild("Shared").Config.CallConfig)

export type Heard = {
	VoiceSeconds: number,
	VoiceWorks: boolean,
	CallerAudible: boolean,
	CallerText: string,
}

local function set(list: { string }): { [string]: boolean }
	local out = {}
	for _, item in list do
		out[item] = true
	end
	return out
end

-- Sounds, not words.
local FILLERS = set({
	"uh", "uhh", "um", "umm", "uhm", "er", "erm", "ah", "ahh", "aah", "oh", "ohh", "hm", "hmm", "hmmm",
	"mm", "mmm", "mhm", "huh", "eh", "ugh",
})

-- Words speech-to-text makes up from noise. A transcript made only of these is ignored.
local NOISE_WORDS = set({ "you", "the", "a", "an", "i", "it", "so", "and", "to", "bye", "thanks", "uhhuh" })

-- Whole phrases speech-to-text makes up from noise.
local NOISE_PHRASES = set({
	"thank you",
	"thank you very much",
	"thank you so much",
	"thanks for watching",
	"thank you for watching",
	"thanks for watching bye",
	"please subscribe",
	"like and subscribe",
	"bye bye",
	"see you next time",
})

local MicFilter = {}

-- Removes bracketed noise tags and tidies spacing.
function MicFilter.Clean(text: string): string
	local clean = string.gsub(text, "%b[]", " ")
	clean = string.gsub(clean, "%b()", " ")
	clean = string.gsub(clean, "%b<>", " ")
	clean = string.gsub(clean, "%*[^%*]*%*", " ")
	clean = string.gsub(clean, "%s+", " ")
	clean = string.gsub(clean, "^%s+", "")
	clean = string.gsub(clean, "%s+$", "")
	return clean
end

-- Lowercase words without punctuation ("Don't!" -> "dont").
function MicFilter.Words(text: string): { string }
	local out = {}
	for word in string.gmatch(string.lower(text), "[%w']+") do
		local plain = string.gsub(word, "'", "")
		if plain ~= "" then
			table.insert(out, plain)
		end
	end
	return out
end

local function realWords(text: string): { string }
	local out = {}
	for _, word in MicFilter.Words(text) do
		if not FILLERS[word] then
			table.insert(out, word)
		end
	end
	return out
end

local function isEcho(words: { string }, callerText: string): boolean
	local callerWords = {}
	for _, word in realWords(callerText) do
		callerWords[word] = true
	end
	local matches = 0
	for _, word in words do
		if callerWords[word] then
			matches += 1
		end
	end
	if #words == 1 then
		return matches == 1
	end
	return matches / #words >= CallConfig.Mic.EchoShare
end

function MicFilter.Check(text: string, heard: Heard): (boolean, string)
	local Mic = CallConfig.Mic
	local clean = MicFilter.Clean(text)
	local words = realWords(clean)

	if #words == 0 then
		return false, "no words, only sounds"
	end
	if NOISE_PHRASES[table.concat(words, " ")] then
		return false, "a phrase speech-to-text often makes up from noise"
	end
	local onlyNoise = true
	for _, word in words do
		if not NOISE_WORDS[word] then
			onlyNoise = false
			break
		end
	end
	if onlyNoise then
		return false, "a word speech-to-text often makes up from noise"
	end

	if heard.VoiceWorks then
		if heard.VoiceSeconds < Mic.MinVoiceSeconds then
			return false, string.format("only %.2fs of voice was heard", heard.VoiceSeconds)
		end
		if #words > heard.VoiceSeconds * Mic.MaxWordsPerSecond + Mic.ExtraWords then
			return false, string.format("%d words in %.2fs of voice", #words, heard.VoiceSeconds)
		end
	elseif #words < Mic.MinWordsUnchecked then
		return false, "too short to trust, and this device doesn't report when you're talking"
	end

	if heard.CallerAudible and heard.CallerText ~= "" and isEcho(words, heard.CallerText) then
		return false, "the caller's own words coming back through your mic"
	end

	return true, clean
end

return MicFilter
