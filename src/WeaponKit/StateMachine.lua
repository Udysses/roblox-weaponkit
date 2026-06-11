--!strict
-- StateMachine.lua
-- Weapon FSM for the client side. Guards _onActivate against impossible
-- transitions: firing while reloading, double-activation in the same frame,
-- activating before the equip animation has finished, etc.
--
-- States
--   Idle       → can fire, can reload
--   Equipping  → equip animation playing; cannot fire
--   Firing     → cooldown active; cannot fire again until → Idle
--   Reloading  → magazine swap; cannot fire
--
-- Allowed transitions (anything else is silently rejected and returns false):
--   Idle      → Equipping, Firing, Reloading
--   Equipping → Idle
--   Firing    → Idle, Reloading
--   Reloading → Idle
--
-- Usage:
--   local sm = StateMachine.new(self._equipMaid)
--   sm.onTransition:Connect(function(from, to)
--       print(from, "→", to)
--   end)
--   sm:transition("Equipping")   -- returns true
--   sm:transition("Firing")      -- returns false (Equipping → Firing not allowed)
--   sm:canFire()                 -- false

local Signal = require(script.Parent.Signal)
local Maid   = require(script.Parent.Maid)

-- ── State definition ───────────────────────────────────────────────────────

export type State = "Idle" | "Equipping" | "Firing" | "Reloading"

-- Table-driven transition map. Faster than a chain of ifs and trivially
-- extended when new states are added (e.g. "Jammed", "Inspecting").
local ALLOWED: { [State]: { [State]: true } } = {
	Idle      = { Equipping = true, Firing = true, Reloading = true },
	Equipping = { Idle = true },
	Firing    = { Idle = true, Reloading = true },
	Reloading = { Idle = true },
}

-- ── Types ──────────────────────────────────────────────────────────────────

export type StateMachine = {
	-- Current state. Read-only; mutate via transition().
	state        : State,
	-- Fires (from: State, to: State) on every successful transition.
	onTransition : any, -- Signal<State, State>
	-- Attempt a state transition. Returns false if the transition is not allowed.
	transition   : (self: StateMachine, to: State) -> boolean,
	-- True only when the weapon is in Idle and may accept a fire event.
	canFire      : (self: StateMachine) -> boolean,
	Destroy      : (self: StateMachine) -> (),
}

type SMImpl = {
	state        : State,
	onTransition : any,
	_maid        : any,
}

local SM   = {}
SM.__index = SM

-- ── Constructor ────────────────────────────────────────────────────────────

-- Pass the equip-cycle Maid so the machine is automatically cleaned up
-- when the weapon is unequipped without needing an explicit Destroy() call.
function StateMachine.new(parentMaid: any?): StateMachine
	local self = setmetatable({
		state        = "Idle" :: State,
		onTransition = Signal.new(),
		_maid        = Maid.new(),
	} :: SMImpl, SM)

	if parentMaid then
		parentMaid:Give(function()
			self:Destroy()
		end)
	end

	return self :: any
end

-- ── Public ──────────────────────────────────────────────────────────────────

function SM:transition(to: State): boolean
	local impl = self :: SMImpl
	local from = impl.state
	local row  = ALLOWED[from]
	if not row or not row[to] then
		return false
	end
	impl.state = to
	impl.onTransition:Fire(from, to)
	return true
end

function SM:canFire(): boolean
	return (self :: SMImpl).state == "Idle"
end

function SM:Destroy()
	local impl = self :: SMImpl
	impl.onTransition:DisconnectAll()
	impl._maid:Destroy()
end

return StateMachine
