--!strict
-- Signal.lua
-- Typed event emitter. The backing implementation for Hooks.lua.
--
-- Fire() snapshots the listener list before iterating so callbacks can
-- safely call Connect/Disconnect without corrupting iteration.
-- Each callback runs via task.spawn — one bad callback cannot kill the rest,
-- and re-entrancy into the Rewind/restore bracket in Server.lua is prevented.

export type Connection = {
	Disconnect : (self: Connection) -> (),
}

-- T... is the payload type; used by Hooks.lua for typed signals.
export type Signal<T...> = {
	Connect      : (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Once         : (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Fire         : (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
}

-- ── Internals ──────────────────────────────────────────────────────────────

type ConnImpl = {
	_signal : any,
	_fn     : (...any) -> (),
	_once   : boolean,
}

type SigImpl = {
	_listeners : { ConnImpl },
}

local Connection   = {}
Connection.__index = Connection

local Signal   = {}
Signal.__index = Signal

-- ── Connection ──────────────────────────────────────────────────────────────

function Connection:Disconnect()
	local impl      = self :: ConnImpl
	local listeners = (impl._signal :: SigImpl)._listeners
	for i, c in listeners do
		if c == (self :: any) then
			table.remove(listeners, i)
			return
		end
	end
end

-- ── Signal ──────────────────────────────────────────────────────────────────

function Signal.new<T...>(): Signal<T...>
	return setmetatable({ _listeners = {} } :: SigImpl, Signal) :: any
end

function Signal:Connect(fn: (...any) -> ()): Connection
	local conn = setmetatable({
		_signal = self,
		_fn     = fn,
		_once   = false,
	} :: ConnImpl, Connection)
	table.insert((self :: SigImpl)._listeners, conn :: any)
	return conn :: any
end

function Signal:Once(fn: (...any) -> ()): Connection
	local conn = setmetatable({
		_signal = self,
		_fn     = fn,
		_once   = true,
	} :: ConnImpl, Connection)
	table.insert((self :: SigImpl)._listeners, conn :: any)
	return conn :: any
end

function Signal:Fire(...: any)
	local impl     = self :: SigImpl
	-- Snapshot prevents mutations during iteration from corrupting the loop.
	local snapshot = table.clone(impl._listeners)

	for _, conn in snapshot do
		local c = conn :: ConnImpl
		if c._once then
			-- Remove before spawning to prevent double-fire on re-entrant calls.
			for i, lc in impl._listeners do
				if lc == (conn :: any) then
					table.remove(impl._listeners, i)
					break
				end
			end
		end
		task.spawn(c._fn, ...)
	end
end

function Signal:DisconnectAll()
	table.clear((self :: SigImpl)._listeners)
end

return Signal
