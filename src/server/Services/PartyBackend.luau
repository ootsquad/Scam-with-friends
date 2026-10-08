--[[
	PartyBackend (server, lobby place)
	The Roblox services behind PartyCore, wrapped so every call is protected and PartyCore stays testable:

	PartyBackend.store(name)   MemoryStore HashMap: get(code), update(code, transform, ttl), remove(code)
	PartyBackend.bus()         MessagingService: publish(topic, data), subscribe(topic, handler) -> connection?

	Every function returns false (or nil) instead of erroring when Roblox's services are busy; PartyCore keeps
	the last party it saw and tries again on its next poll.
]]

local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")

local PartyBackend = {}

local warned: { [string]: boolean } = {}

local function warnOnce(what: string, err: any)
	if not warned[what] then
		warned[what] = true
		warn(`[PartyBackend] {what} failed (will keep retrying quietly): {err}`)
	end
end

function PartyBackend.store(name: string)
	local map = MemoryStoreService:GetHashMap(name)
	return {
		get = function(code: string): (boolean, any)
			local ok, value = pcall(function()
				return map:GetAsync(code)
			end)
			if not ok then
				warnOnce("MemoryStore read", value)
			end
			return ok, if ok then value else nil
		end,
		update = function(code: string, transform: (any) -> any, ttl: number): (boolean, any)
			local ok, value = pcall(function()
				return map:UpdateAsync(code, transform, ttl)
			end)
			if not ok then
				warnOnce("MemoryStore write", value)
			end
			return ok, if ok then value else nil
		end,
		remove = function(code: string): boolean
			local ok, err = pcall(function()
				map:RemoveAsync(code)
			end)
			if not ok then
				warnOnce("MemoryStore remove", err)
			end
			return ok
		end,
	}
end

function PartyBackend.bus()
	return {
		publish = function(topic: string, data: any): boolean
			local ok, err = pcall(function()
				MessagingService:PublishAsync(topic, data)
			end)
			if not ok then
				warnOnce("MessagingService publish", err)
			end
			return ok
		end,
		subscribe = function(topic: string, handler: (any) -> ()): any
			local ok, connection = pcall(function()
				return MessagingService:SubscribeAsync(topic, function(message)
					handler(message.Data)
				end)
			end)
			if not ok then
				warnOnce("MessagingService subscribe", connection)
				return nil
			end
			return connection
		end,
	}
end

return PartyBackend
