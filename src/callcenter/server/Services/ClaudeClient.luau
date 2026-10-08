--[[
	ClaudeClient (server only)
	Talks to the Claude Messages API (claude-haiku-5-5) for the AI callers.

	The API key is read from the StringValue ServerStorage["claude-haiku-5-5 API"]. It never leaves the server.
	Requires Game Settings -> Security -> "Allow HTTP Requests".

	ClaudeClient.Respond(system, messages) -> (Reply?, errorCode?)    yields
		messages = { { role = "user" | "assistant", content = "..." }, ... }   (starts and ends with "user")
		errorCode: "missing_key" | "http_disabled" | "bad_key" | "busy" | "bad_request" | "bad_response"
	ClaudeClient.Describe(errorCode) -> string                         player-facing explanation
]]

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

local CallConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Config.CallConfig)
local CallerPrompt = require(script.Parent.Parent.Data.CallerPrompt)

export type Message = { role: string, content: string }

export type Reply = {
	Say: string,
	TrustChange: number,
	Pay: { Method: string, Amount: number }?,
	HangUp: boolean,
}

local RETRY_DELAY = 1.5
local RETRY_STATUS = { [408] = true, [429] = true, [500] = true, [502] = true, [503] = true, [504] = true, [529] = true }

local DESCRIPTIONS = {
	missing_key = `The phone line isn't set up: add a StringValue named "{CallConfig.ApiKeyValue}" with the API key to ServerStorage.`,
	http_disabled = "The phone line is down: turn on Game Settings > Security > Allow HTTP Requests.",
	bad_key = "The phone line rejected the API key. Check the key in ServerStorage.",
	busy = "All lines are busy right now. Try another call in a moment.",
	bad_request = "The call dropped. Try again.",
	bad_response = "The line crackled and the call dropped. Try again.",
}

local ClaudeClient = {}

local function readKey(): string?
	local holder = ServerStorage:FindFirstChild(CallConfig.ApiKeyValue)
	if holder and holder:IsA("StringValue") then
		local key = string.gsub(holder.Value, "^%s+", "")
		key = string.gsub(key, "%s+$", "")
		if key ~= "" then
			return key
		end
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
				HangUp = input.hang_up == true,
			}
		end
	end
	return nil
end

local function send(key: string, payload: string): (any, string?)
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
			return nil, "http_disabled"
		end
		warn(`[ClaudeClient] request failed: {message}`)
		return nil, "busy"
	end
	return response, nil
end

function ClaudeClient.Respond(system: string, messages: { Message }): (Reply?, string?)
	local key = readKey()
	if not key then
		return nil, "missing_key"
	end

	local payload = HttpService:JSONEncode({
		model = CallConfig.Model,
		max_tokens = CallConfig.MaxTokens,
		system = system,
		messages = messages,
		tools = { CallerPrompt.TOOL },
		tool_choice = { type = "tool", name = CallerPrompt.TOOL.name },
	})

	for attempt = 1, 2 do
		local response, err = send(key, payload)
		if err == "http_disabled" then
			return nil, err
		end
		if response then
			local status = response.StatusCode
			if response.Success then
				local reply = parse(response.Body)
				if reply then
					return reply, nil
				end
				warn("[ClaudeClient] couldn't read the reply")
				return nil, "bad_response"
			elseif status == 401 or status == 403 then
				return nil, "bad_key"
			elseif not RETRY_STATUS[status] then
				warn(`[ClaudeClient] HTTP {status}: {string.sub(tostring(response.Body), 1, 300)}`)
				return nil, "bad_request"
			end
			warn(`[ClaudeClient] HTTP {status}, attempt {attempt}`)
		end
		if attempt == 1 then
			task.wait(RETRY_DELAY)
		end
	end
	return nil, "busy"
end

function ClaudeClient.Describe(errorCode: string?): string
	return DESCRIPTIONS[errorCode or ""] or DESCRIPTIONS.bad_response
end

function ClaudeClient.HasKey(): boolean
	return readKey() ~= nil
end

return ClaudeClient
