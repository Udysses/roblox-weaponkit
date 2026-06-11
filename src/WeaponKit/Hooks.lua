--!strict
-- Hooks.lua
-- Event hooks for WeaponKit. Lets external code react to combat events
-- without modifying WeaponKit internals.
--
-- Both Server and Client expose a `.hooks` field of this type.
-- Server hooks are authoritative (fire after damage is applied).
-- Client hooks fire immediately for local feedback (sound, screen shake, UI).
--
-- Usage:
--   local server = WeaponKit.Server.new(tool, cfg)
--   server.hooks.OnHit:Connect(function(player, victim, damage, ctx)
--       StatsService:RecordHit(player, victim, damage)
--   end)
--   server.hooks.OnKill:Connect(function(player, victim, ctx)
--       AwardKillstreak(player)
--   end)
--
-- All signals fire via task.spawn so one listener error cannot affect others.
-- Attach listeners before :Start() to avoid missing the very first event.

local Signal = require(script.Parent.Signal)

-- ── HitContext ─────────────────────────────────────────────────────────────

-- Rich metadata carried by OnHit and OnKill.
-- Provides everything external systems typically need in one table.
export type HitContext = {
	weaponName  : string,
	weaponType  : string,     -- "melee" | "hitscan"
	damage      : number,     -- final damage after falloff / headshot / pierce
	rawDamage   : number,     -- base weapon damage before any modifiers
	isHeadshot  : boolean,
	distance    : number,     -- studs attacker → victim at the moment of firing
	hitPart     : BasePart?,  -- nil for melee (box intersection, not part raycast)
	hitPos      : Vector3?,   -- nil for melee
	timestamp   : number,     -- workspace:GetServerTimeNow() at client fire time
	pierceIndex : number,     -- 0 = primary target; 1+ = subsequent pierce target
}

-- ── HookSet ────────────────────────────────────────────────────────────────

export type HookSet = {
	-- Fires for every validated hit that applies damage.
	OnHit:          any, -- Signal<Player, Model, number, HitContext>

	-- Fires when a hit reduces the victim's Humanoid.Health to ≤ 0.
	OnKill:         any, -- Signal<Player, Model, HitContext>

	-- Fires when a shot is rejected during server validation.
	-- reason is a short human-readable string ("LOS blocked", "out of range", …)
	OnMiss:         any, -- Signal<Player, string>

	-- Fires when the rate limiter or speed check drops a player's fire event.
	OnRateExceeded: any, -- Signal<Player>

	-- Disconnect and clear all listeners. Called by Server:Destroy().
	DisconnectAll: (self: HookSet) -> (),
}

type HookSetImpl = {
	OnHit:          any,
	OnKill:         any,
	OnMiss:         any,
	OnRateExceeded: any,
}

local Hooks = {}

function Hooks.new(): HookSet
	local hs: HookSetImpl = {
		OnHit          = Signal.new(),
		OnKill         = Signal.new(),
		OnMiss         = Signal.new(),
		OnRateExceeded = Signal.new(),
	}

	local hookSet = hs :: any
	hookSet.DisconnectAll = function(self: any)
		self.OnHit:DisconnectAll()
		self.OnKill:DisconnectAll()
		self.OnMiss:DisconnectAll()
		self.OnRateExceeded:DisconnectAll()
	end

	return hookSet :: HookSet
end

return Hooks
