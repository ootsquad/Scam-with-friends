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

return Namespace
