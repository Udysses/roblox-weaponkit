--!strict
-- Config.lua
-- Default configuration values, deep-merge helper, and validation.
-- Every value here can be overridden per weapon.

local Config = {}

Config.Defaults = {

	-- ── Combat ────────────────────────────────────────────────────────────
	damage            = 25,
	cooldown          = 0.5,             -- Minimum seconds between activations
	range             = 8,               -- Melee hitbox depth in studs
	hitboxSize        = Vector3.new(6, 5, 6), -- Hitbox width/height/depth
	perTargetCooldown = 0.3,
	-- ↑ Solves: Touched-style multi-hit. Each target can only be hit once
	--   per activation. Reset when the next swing begins.

	-- ── Animations ────────────────────────────────────────────────────────
	-- Set to "" or "0" to skip a slot.
	-- IDs must be full rbxassetid strings: "rbxassetid://1234567"
	animations = {
		equip = "", -- Plays once on equip
		idle  = "", -- Loops while equipped
		swing = "", -- Plays on each activation
	},

	-- Action priority means swing and idle override walk/run animations.
	-- Solves: swing animation being overridden by movement, appearing "stuck".
	animationPriority = Enum.AnimationPriority.Action,

	-- ── Sounds ────────────────────────────────────────────────────────────
	-- Set to 0 to skip.
	sounds = {
		equip = 0,
		swing = 0,
		hit   = 0,
	},

	-- ── Tool setup ────────────────────────────────────────────────────────
	requiresHandle = false,
	-- Solves: "Activated never fires / weapon won't shoot."
	-- When true, Roblox only fires Activated if the Handle is touching a
	-- surface. Setting false removes this restriction. WeaponKit uses
	-- spatial hitbox detection rather than Handle.Touched, so this is safe.

	-- ── Server-side exploit guards ─────────────────────────────────────────
	maxRange  = 16,  -- Reject hits claimed further than this (studs)
	maxDamage = 200, -- Clamp damage to this ceiling (exploit guard)
	rateLimit = 8,   -- Max activations accepted per player per second
	-- Solves: exploiters firing the RemoteEvent directly to deal
	-- unlimited damage or spam the server.
}

--- Deep-merge a user config over the defaults.
--- Nested tables (animations, sounds) are merged shallowly.
function Config.merge(
	defaults: { [string]: any },
	overrides: { [string]: any }
): { [string]: any }
	local result: { [string]: any } = table.clone(defaults)
	for key, value in overrides do
		if type(value) == "table" and type(result[key]) == "table" then
			local nested = table.clone(result[key] :: { [string]: any })
			for k2, v2 in value :: { [string]: any } do
				nested[k2] = v2
			end
			result[key] = nested
		else
			result[key] = value
		end
	end
	return result
end

--- Emit clear warnings for obviously wrong values so developers get
--- actionable messages instead of cryptic nil errors downstream.
--- Never throws — bad config degrades gracefully.
function Config.validate(cfg: { [string]: any })
	if (cfg.damage :: number) < 0 then
		warn("[WeaponKit] cfg.damage is negative — is this intentional?")
	end
	if (cfg.cooldown :: number) < 0 then
		warn("[WeaponKit] cfg.cooldown is negative; clamping to 0")
		cfg.cooldown = 0
	end
	if (cfg.range :: number) <= 0 then
		warn("[WeaponKit] cfg.range must be > 0; resetting to 8")
		cfg.range = 8
	end
	if (cfg.maxRange :: number) < (cfg.range :: number) then
		warn(string.format(
			"[WeaponKit] cfg.maxRange (%d) < cfg.range (%d); raising maxRange to match",
			cfg.maxRange :: number,
			cfg.range :: number
		))
		cfg.maxRange = cfg.range
	end
end

return Config
