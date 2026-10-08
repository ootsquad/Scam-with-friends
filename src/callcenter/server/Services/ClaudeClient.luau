--[[
	ClaudeClient (server only)
	Talks to the Claude Messages API (claude-haiku-5-5) for the AI callers.

	The API key is read from a StringValue in ServerStorage (CallConfig.ApiKeyValue, "claude-haiku-5-5 API").
	The lookup is forgiving: any capitalisation or extra spaces in the name, the StringValue can be inside a
	folder, and if nothing matches by name, any StringValue in ServerStorage holding an "sk-ant-" key is used.
	The key never leaves the server and is never printed in full.
	Requires Game Settings -> Security -> "Allow HTTP Requests".

	ClaudeClient.Respond(system, messages) -> (Reply?, errorCode?, detail?)    yields
		messages = { { role = "user" | "assistant", content = "..." }, ... }   (starts and ends with "user")
		max_tokens is CallConfig.MaxTokens, clamped to the model's output limit (CallConfig.ModelLimits). If a
		conversation ever outgrows the model's context window, the oldest turns after the opening are dropped.
		With CallConfig.PromptCaching, the instructions and the conversation so far are cached between turns.
		errorCode: "missing_key" | "http_disabled" | "bad_key" | "busy" | "bad_request" | "bad_response"
		detail:    the API's own error message, when there is one
	ClaudeClient.Describe(errorCode, detail?) -> string    player-facing explanation
	ClaudeClient.HasKey() -> boolean
	ClaudeClient.Check()                                   logs whether the key is found and accepted (yields)
	                                                       and sets ReplicatedStorage "PhoneLine" ("ok" or why not)
]]

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local CallConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Config.CallConfig)
local CallerPrompt = require(script.Parent.Parent.Data.CallerPrompt)

export type Message = { role: string, content: string }

export type Reply = {
	Say: string,
	TrustChange: number,
	Pay: { Method: string, Amount: number }?,
	RepeatPayment: boolean,
	HangUp: boolean,
}

local RETRY_DELAY = 1.5
local RETRY_STATUS = { [408] = true, [429] = true, [500] = true, [502] = true, [503] = true, [504] = true, [529] = true }

local DESCRIPTIONS = {
	missing_key = `The phone line isn't set up: put a StringValue named "{CallConfig.ApiKeyValue}" with the API key in ServerStorage of the Call Center Place.`,
	http_disabled = "The phone line is down: turn on Game Settings > Security > Allow HTTP Requests.",
	bad_key = "The Claude API rejected the key in ServerStorage.",
	busy = "All lines are busy right now. Try another call in a moment.",
	bad_request = "The Claude API refused the call.",
	bad_response = "The line crackled and the call dropped. Try again.",
}

-- Problems that won't fix themselves; anything else (busy, a bad reply) is worth trying again.
local LINE_DOWN = { missing_key = true, http_disabled = true, bad_key = true }

local ClaudeClient = {}

-- The PhoneLine attribute the Phone app shows: "ok", or why calls can't work. Only setup problems mark the
-- line down, and any answer from Claude marks it up again.
local function reportLine(err: string?, detail: string?)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	if err == nil then
		if ReplicatedStorage:GetAttribute("PhoneLine") ~= "ok" then
			ReplicatedStorage:SetAttribute("PhoneLine", "ok")
		end
	elseif LINE_DOWN[err] then
		local text = DESCRIPTIONS[err]
		if detail and RunService:IsStudio() then
			text ..= ` ({detail})`
		end
		ReplicatedStorage:SetAttribute("PhoneLine", text)
	end
end

-- ---------------------------------------------------------------------------
-- Finding the key
-- ---------------------------------------------------------------------------

local function squash(text: string): string
	return string.lower((string.gsub(text, "%s", "")))
end

local function cleanKey(value: string): string
	local key = string.gsub(value, "%s", "") -- spaces or line breaks pasted along with the key
	key = string.gsub(key, "^[\"']+", "")
	key = string.gsub(key, "[\"']+$", "")
	return key
end

local function pathOf(instance: Instance): string
	return instance:GetFullName()
end

-- Returns the key and where it came from, or nil.
local function findKey(): (string?, string?)
	local wanted = squash(CallConfig.ApiKeyValue)
	local byName, byValue = nil, nil
	for _, instance in ServerStorage:GetDescendants() do
		if instance:IsA("StringValue") then
			local key = cleanKey(instance.Value)
			if key ~= "" then
				local named = squash(instance.Name) == wanted
					or (instance.Parent ~= nil and squash(instance.Parent.Name) == wanted)
				if named and not byName then
					byName = instance
				elseif not byValue and string.sub(key, 1, 7) == "sk-ant-" then
					byValue = instance
				end
			end
		end
	end
	local found = byName or byValue
	if found then
		return cleanKey((found :: StringValue).Value), pathOf(found)
	end
	return nil, nil
end

local function describeStringValues(): string
	local names = {}
	for _, instance in ServerStorage:GetDescendants() do
		if instance:IsA("StringValue") then
			local filled = if cleanKey(instance.Value) ~= "" then "has a value" else "empty"
			table.insert(names, `{pathOf(instance)} ({filled})`)
		end
	end
	return if #names > 0 then table.concat(names, ", ") else "none"
end

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

local function apiError(body: string?): string?
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(body or "")
	end)
	if ok and type(decoded) == "table" and type(decoded.error) == "table" then
		local kind = tostring(decoded.error.type or "error")
		local message = tostring(decoded.error.message or "")
		return `{kind}: {message}`
	end
	return nil
end

local function parse(body: string): Reply?
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(body)
	end)
	if not ok or type(decoded) ~= "table" or type(decoded.content) ~= "table" then
		return nil
	end
	for _, block in decoded.content do
		if type(block) == "table" and block.type == "tool_use" and type(block.input) == "table" then
			local input = block.input
			if type(input.say) ~= "string" then
				return nil
			end
			local pay = nil
			if type(input.pay) == "table" and type(input.pay.method) == "string" and tonumber(input.pay.amount) then
				pay = { Method = input.pay.method, Amount = tonumber(input.pay.amount) :: number }
			end
			return {
				Say = input.say,
				TrustChange = tonumber(input.trust_change) or 0,
				Pay = pay,
				RepeatPayment = input.repeat_payment == true,
				HangUp = input.hang_up == true,
			}
		end
	end
	return nil
end

local function send(key: string, payload: string): (any, string?, string?)
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = CallConfig.Endpoint,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
				["x-api-key"] = key,
				["anthropic-version"] = CallConfig.ApiVersion,
			},
			Body = payload,
		})
	end)
	if not ok then
		local message = tostring(response)
		if string.find(string.lower(message), "not enabled", 1, true) then
			return nil, "http_disabled", message
		end
		warn(`[ClaudeClient] request failed: {message}`)
		return nil, "busy", message
	end
	return response, nil, nil
end

-- Sends a request body; returns the decoded response on success.
local function post(body: { [string]: any }): (any, string?, string?)
	local key, where = findKey()
	if not key then
		return nil, "missing_key", `no StringValue named "{CallConfig.ApiKeyValue}" in ServerStorage (found: {describeStringValues()})`
	end

	local payload = HttpService:JSONEncode(body)
	local lastCode, lastDetail = "busy", nil
	for attempt = 1, 2 do
		local response, err, detail = send(key, payload)
		if err == "http_disabled" then
			return nil, err, detail
		end
		if response then
			local status = response.StatusCode
			if response.Success then
				return response, nil, nil
			end
			local reason = apiError(response.Body) or `HTTP {status}`
			if status == 401 or status == 403 then
				warn(`[ClaudeClient] the API rejected the key from {where}: {reason}`)
				return nil, "bad_key", reason
			elseif not RETRY_STATUS[status] then
				warn(`[ClaudeClient] HTTP {status}: {reason}`)
				return nil, "bad_request", reason
			end
			warn(`[ClaudeClient] HTTP {status} ({reason}), attempt {attempt}`)
			lastCode, lastDetail = "busy", reason
		else
			lastCode, lastDetail = err or "busy", detail
		end
		if attempt == 1 then
			task.wait(RETRY_DELAY)
		end
	end
	return nil, lastCode, lastDetail
end

-- ---------------------------------------------------------------------------
-- Limits and caching
-- ---------------------------------------------------------------------------

local function modelLimits(): { Context: number, Output: number }
	return CallConfig.ModelLimits[CallConfig.Model] or CallConfig.ModelLimits.Default
end

function ClaudeClient.MaxTokens(): number
	return math.clamp(math.floor(CallConfig.MaxTokens), 1, modelLimits().Output)
end

-- About four characters per token; only used to stay well inside the context window.
local function estimate(text: string): number
	return math.ceil(#text / 4)
end

local function fitContext(system: string, messages: { Message }): { Message }
	local budget = modelLimits().Context - ClaudeClient.MaxTokens() - 4000 -- room for the tool definition
	local total = estimate(system)
	for _, message in messages do
		total += estimate(message.content)
	end
	if total <= budget then
		return messages
	end
	-- Drop the oldest assistant/user pair after the opening until it fits (keeps the turns alternating).
	local kept = table.clone(messages)
	while total > budget and #kept > 3 do
		total -= estimate(kept[2].content) + estimate(kept[3].content)
		table.remove(kept, 2)
		table.remove(kept, 2)
	end
	return kept
end

-- Marks the instructions and the latest turn as cache points, so each turn only pays for what's new.
local function withCaching(system: string, messages: { Message }): (any, { any })
	if not CallConfig.PromptCaching then
		return system, messages
	end
	local cached = table.clone(messages) :: { any }
	local last = cached[#cached]
	if last and last.role == "user" and type(last.content) == "string" then
		cached[#cached] = {
			role = "user",
			content = { { type = "text", text = last.content, cache_control = { type = "ephemeral" } } },
		}
	end
	return { { type = "text", text = system, cache_control = { type = "ephemeral" } } }, cached
end

function ClaudeClient.Respond(system: string, messages: { Message }): (Reply?, string?, string?)
	local systemBlocks, conversation = withCaching(system, fitContext(system, messages))
	local response, err, detail = post({
		model = CallConfig.Model,
		max_tokens = ClaudeClient.MaxTokens(),
		system = systemBlocks,
		messages = conversation,
		tools = { CallerPrompt.TOOL },
		tool_choice = { type = "tool", name = CallerPrompt.TOOL.name },
	})
	reportLine(err, detail)
	if not response then
		return nil, err, detail
	end
	local reply = parse(response.Body)
	if reply then
		return reply, nil, nil
	end
	warn(`[ClaudeClient] couldn't read the reply: {string.sub(tostring(response.Body), 1, 300)}`)
	return nil, "bad_response", nil
end

function ClaudeClient.Describe(errorCode: string?, detail: string?): string
	local text = DESCRIPTIONS[errorCode or ""] or DESCRIPTIONS.bad_response
	-- In Studio, show the API's own reason too so setup problems are easy to spot.
	if detail and RunService:IsStudio() and errorCode ~= "missing_key" then
		text ..= ` ({detail})`
	end
	return text
end

function ClaudeClient.HasKey(): boolean
	return findKey() ~= nil
end

-- Logs whether the key is found and whether the API accepts it. Costs one tiny request.
function ClaudeClient.Check()
	local key, where = findKey()
	if not key then
		warn(
			`[ClaudeClient] no API key: put a StringValue named "{CallConfig.ApiKeyValue}" in ServerStorage of this place. `
				.. `StringValues in ServerStorage: {describeStringValues()}`
		)
		reportLine("missing_key")
		return
	end
	print(`[ClaudeClient] using the API key in {where} ({string.sub(key, 1, 10)}…, {#key} characters)`)
	local response, err, detail = post({
		model = CallConfig.Model,
		max_tokens = 5,
		messages = { { role = "user", content = "Say OK." } },
	})
	reportLine(err, detail)
	if response then
		print(`[ClaudeClient] {CallConfig.Model} is answering. Phone lines are open.`)
	else
		warn(`[ClaudeClient] key check failed: {DESCRIPTIONS[err or ""] or DESCRIPTIONS.bad_response} {detail or ""}`)
	end
end

return ClaudeClient
