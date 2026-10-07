--!strict
--[[
	Signal
	Minimal event object for module-to-module events (stores, window manager).
		local changed = Signal.new()
		local connection = changed:Connect(function(...) end)
		changed:Fire(...)
		connection:Disconnect()
]]

export type Connection = {
	Disconnect: (self: Connection) -> (),
}

export type Signal = {
	Connect: (self: Signal, handler: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
}

local Signal = {}
Signal.__index = Signal

function Signal.new(): Signal
	return (setmetatable({ _handlers = {} }, Signal) :: any) :: Signal
end

function Signal:Connect(handler: (...any) -> ()): Connection
	local handlers = self._handlers
	local entry = { handler = handler }
	table.insert(handlers, entry)

	local connection = {}
	function connection.Disconnect()
		local index = table.find(handlers, entry)
		if index then
			table.remove(handlers, index)
		end
	end
	return (connection :: any) :: Connection
end

function Signal:Fire(...: any)
	for _, entry in table.clone(self._handlers) do
		task.spawn(entry.handler, ...)
	end
end

return Signal
