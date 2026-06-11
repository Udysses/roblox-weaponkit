--!strict
-- Config.lua
-- Default configuration values, deep-merge helper, and validation.
-- Every value here can be overridden per weapon.

local Config = {}

Config.Defaults = {

	-- ── Weapon type ────────────────────────────────────────────────────────
	-- "melee"   → GetPartBoundsInBox hit detection (swords, bats, etc.)
	-- "hitscan" → instant raycast (guns, ACS-style FPS weapons)
	weaponType = "melee",

	-- ── Combat ────────────────────────────────────────────────────────────
	damage            = 25,
	cooldown          = 0.5,                   -- Minimum seconds between activations
	range             = 8,                     -- Melee hitbox depth in studs
	hitboxSize        = Vector3.new(6, 5, 6),  -- Melee hitbox width/height/depth
	perTargetCooldown = 0.3,
	maxHitsPerEvent   = 10,
	-- ↑ Caps how many targets a single event can claim. Prevents a crafted
	--   payload from hammering TakeDamage on every player in one request.

	-- ── Hitscan / ranged weapons ───────────────────────────────────────────
	-- Used when weaponType = "hitscan". Ignored for melee.
	hitscan = {
		maxRange     = 300,                          -- studs
		tracerEnabled = true,
		tracerColor   = Color3.fromRGB(255, 210, 80),
		tracerLength  = 2.5,                         -- studs
		tracerSpeed   = 600,                         -- studs/s (visual only)
	},

	-- ── Lag compensation ──────────────────────────────────────────────────
	-- The primary fix for "ACS feels laggy" / high-ping missed hits.
	-- When enabled, the server rewinds all character positions to the
	-- client's fire timestamp before validating distance or running raycasts.
	lagCompensation = {
		enabled     = true,
		maxRewindMs = 500,  -- Hard cap; attacker cannot claim a shot older than this
	},

	-- ── ACS integration ───────────────────────────────────────────────────
	-- Intercepts ACS damage RemoteEvents and re-validates them through
	-- WeaponKit's security pipeline (range check, alive check, rate limit).
	acs = {
		autoDetect   = true,   -- Look for ACS in ReplicatedStorage automatically
		bridgeDamage = false,  -- Set true to validate ACS gun hits via WeaponKit
	},

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
	maxRange  = 16,  -- Reject hits claimed further than this (studs); raise for guns
	maxDamage = 200, -- Clamp damage to this ceiling (exploit guard)
	rateLimit = 8,   -- Max activations accepted per player per second
	-- Solves: exploiters firing the RemoteEvent directly to deal
	-- unlimited damage or spam the server.
}

--- Deep-merge a user config over the defaults.
--- Nested tables (animations, sounds, hitscan, lagCompensation, acs) are
--- merged shallowly so partial overrides work: { hitscan = { maxRange = 500 } }
--- keeps all other hitscan keys intact.
function Config.merge(
	defaults:  { [string]: any },
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
			cfg.range    :: number
		))
		cfg.maxRange = cfg.range
	end

	-- Validate weapon type.
	local wt = cfg.weaponType :: string?
	if wt and wt ~= "melee" and wt ~= "hitscan" then
		warn("[WeaponKit] Unknown cfg.weaponType '" .. tostring(wt) .. "'; defaulting to 'melee'")
		cfg.weaponType = "melee"
	end

	-- For hitscan weapons, maxRange default of 16 is too low. Auto-raise it.
	if cfg.weaponType == "hitscan" then
		local hitscanCfg = cfg.hitscan :: { [string]: any }
		local hsRange    = hitscanCfg and hitscanCfg.maxRange :: number? or 300
		if (cfg.maxRange :: number) < hsRange then
			cfg.maxRange = hsRange
		end
	end

	-- Validate animation IDs: they should be "rbxassetid://..." or empty.
	local animCfg = cfg.animations :: { [string]: string }?
	if animCfg then
		for slot, id in animCfg :: { [string]: string } do
			if id ~= "" and id ~= "0" and not string.match(id, "^rbxassetid://") then
				warn(("[WeaponKit] cfg.animations.%s = '%s' doesn't look like a valid asset ID. "
					.. "Use the full form: \"rbxassetid://1234567890\""):format(slot, id))
			end
		end
	end
end

return Config
