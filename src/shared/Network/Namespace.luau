--[[
	Namespace
	Thin wrapper around ByteNetMax.defineNamespace.

	The server assigns packet/query ids and publishes them in ReplicatedStorage.BytenetStorage.
	The client can only build a namespace after that has replicated, so on the client we wait for it
	here instead of hoping the load order works out.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PUBLISH_TIMEOUT = 30

local packages = ReplicatedStorage:WaitForChild("Packages", 10)
if not packages then
	error(
		"[Call Center Chaos] ReplicatedStorage.Packages is missing. Restart `rojo serve` so it picks up the "
			.. "current default.project.json, then reconnect the Rojo plugin."
	)
end
local ByteNetMax = require(packages:WaitForChild("ByteNetMax"))

local Namespace = {}

Namespace.ByteNet = ByteNetMax

function Namespace.define<T>(name: string, build: () -> T): any
	if RunService:IsClient() then
		local storage = ReplicatedStorage:WaitForChild("BytenetStorage", PUBLISH_TIMEOUT)
		local published = storage and storage:WaitForChild(name, PUBLISH_TIMEOUT) :: StringValue?
		if not published then
			error(`[Network] Server never published the "{name}" namespace. Is the server requiring Shared.Network?`)
		end
		while published.Value == "" do
			published.Changed:Wait()
		end
	end

	return ByteNetMax.defineNamespace(name, build :: any)
end

-- ---------------------------------------------------------------------------
-- Queries that always answer
-- ByteNet gives a query listener 10 seconds. If the listener errors or takes longer, the client never gets
-- an answer and its invoke waits forever. Use these instead of query.listen / query.invoke.
-- ---------------------------------------------------------------------------

local SERVER_BUDGET = 8 -- seconds a listener may take before the fallback answer goes out instead
local CLIENT_TIMEOUT = 20 -- seconds the client waits before giving up on an answer

-- Runs fn(...) and returns its result, or onTimeout() if it takes longer than `seconds`. If fn errors,
-- returns onError(err).
local function within(seconds: number, fn: (...any) -> any, onError: (any) -> any, onTimeout: () -> any, ...: any): any
	local caller = coroutine.running()
	local done, waiting, answer = false, false, nil
	local function finish(value: any)
		if done then
			return
		end
		done, answer = true, value
		if waiting then
			task.spawn(caller, value)
		end
	end
	local args = table.pack(...)
	task.spawn(function()
		local ok, value = pcall(fn, table.unpack(args, 1, args.n))
		finish(if ok then value else onError(value))
	end)
	if done then
		return answer
	end
	waiting = true
	task.delay(seconds, function()
		if not done then
			finish(onTimeout())
		end
	end)
	return coroutine.yield()
end

-- Server: answers with fallback(request, player) when `handler` errors or is too slow.
function Namespace.listen(query: any, handler: (any, Player) -> any, fallback: (any, Player) -> any)
	query.listen(function(request: any, player: Player)
		return within(SERVER_BUDGET, handler, function(err)
			warn(`[Network] a query handler failed: {err}`)
			return fallback(request, player)
		end, function()
			warn(`[Network] a query took longer than {SERVER_BUDGET}s; answered with the fallback`)
			return fallback(request, player)
		end, request, player)
	end)
end

-- Client: the server's answer, or nil if it never came.
function Namespace.invoke(query: any, request: any, timeout: number?): any
	return within(timeout or CLIENT_TIMEOUT, query.invoke, function(err)
		warn(`[Network] a query failed: {err}`)
		return nil
	end, function()
		return nil
	end, request)
end

-- The usual { Ok, Message } answer for a request that couldn't be handled.
function Namespace.busy(): { Ok: boolean, Message: string }
	return { Ok = false, Message = "The server is busy. Try again in a moment." }
end

return Namespace
