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
	-- ↑ Caps how many targets a single fire event can claim.
	--   Prevents a crafted payload from calling TakeDamage on every player.

	-- ── Hitscan / ranged weapons ───────────────────────────────────────────
	-- Used when weaponType = "hitscan". Ignored for melee.
	hitscan = {
		maxRange      = 300,                         -- studs
		tracerEnabled = true,
		tracerColor   = Color3.fromRGB(255, 210, 80),
		tracerLength  = 2.5,                         -- studs
		tracerSpeed   = 600,                         -- studs/s (visual only)
	},

	-- ── Damage falloff ─────────────────────────────────────────────────────
	-- Damage decreases with distance. Only active when enabled = true.
	falloff = {
		enabled         = false,
		minDamage       = 5,      -- damage floor (never drops below this)
		fullDamageRange = 0,      -- studs before falloff begins (0 = immediate)
		zeroRange       = 300,    -- studs at which damage reaches minDamage
		curve           = "linear",  -- "linear" | "quadratic" | "exponential"
	},

	-- ── Headshot ───────────────────────────────────────────────────────────
	headshot = {
		enabled    = false,
		multiplier = 2.0,    -- damage × multiplier when headshot
		partName   = "Head", -- exact part name (R6 and R15 both use "Head")
	},

	-- ── Penetration / pierce ───────────────────────────────────────────────
	-- Bullets pass through targets, dealing reduced damage to targets behind.
	penetration = {
		enabled     = false,
		maxTargets  = 3,     -- maximum targets hit in one shot (including first)
		damageDecay = 0.75,  -- damage multiplier per additional target
		             --   target 1: base × 0.75^0 = 100%
		             --   target 2: base × 0.75^1 =  75%
		             --   target 3: base × 0.75^2 ≈  56%
	},

	-- ── Lag compensation ──────────────────────────────────────────────────
	-- The primary fix for "ACS feels laggy" / high-ping missed hits.
	lagCompensation = {
		enabled     = true,
		maxRewindMs = 500,
	},

	-- ── Line-of-sight validation ───────────────────────────────────────────
	-- Server raycasts attacker → victim. Rejects hits fired through walls.
	-- Disabled by default — thin walls and LOD meshes can cause false rejects.
	-- Enable only after stress-testing on your map geometry.
	lineOfSight = {
		enabled = false,
	},

	-- ── Speedhack / teleport check ─────────────────────────────────────────
	-- Rejects fire events from players moving faster than maxSpeed.
	-- Default maxSpeed covers sprint + vehicle seats; tune for your game.
	speedCheck = {
		enabled      = false,
		maxSpeed     = 80,   -- studs/s; Roblox walk ≈16, sprint ≈24, vehicles vary
		sampleWindow = 0.25, -- seconds between server position samples
	},

	-- ── Parallel Luau validation ───────────────────────────────────────────
	-- task.desynchronize() during the melee hit-validation loop.
	-- Meaningful gain on servers with many simultaneous swingers (10+).
	-- Harmless to enable always; requires no Actor setup.
	parallelValidation = {
		enabled = false,
	},

	-- ── State machine (client) ─────────────────────────────────────────────
	-- Prevents firing while equipping, reloading, or in mid-swing.
	-- serverTimingCheck adds a secondary server-side cooldown guard.
	stateMachine = {
		enabled           = true,
		serverTimingCheck = false,
	},

	-- ── Effect pool (client) ───────────────────────────────────────────────
	-- Reuse tracer Parts instead of create/destroy each shot.
	-- Eliminates GC spikes at high ACS fire rates. Recommended for guns.
	effects = {
		poolEnabled         = false,
		poolSize            = 20,
		useUnreliableRemote = false, -- broadcast visuals on UnreliableRemoteEvent
	},

	-- ── ACS integration ───────────────────────────────────────────────────
	acs = {
		autoDetect   = true,
		bridgeDamage = false,
	},

	-- ── Debug visualization ────────────────────────────────────────────────
	-- Creates WeaponKit_Debug RemoteEvent only when enabled = true.
	-- Set targetPlayer to a player's Name to send hitbox/ray adornments.
	debug = {
		enabled      = false,
		targetPlayer = nil :: string?,
	},

	-- ── Animations ────────────────────────────────────────────────────────
	animations = {
		equip = "",
		idle  = "",
		swing = "",
	},

	animationPriority = Enum.AnimationPriority.Action,

	-- ── Sounds ────────────────────────────────────────────────────────────
	sounds = {
		equip = 0,
		swing = 0,
		hit   = 0,
	},

	-- ── Tool setup ────────────────────────────────────────────────────────
	requiresHandle = false,

	-- ── Server-side exploit guards ─────────────────────────────────────────
	maxRange  = 16,   -- Reject hits claimed further than this (studs)
	maxDamage = 200,  -- Clamp damage ceiling (exploit guard)
	rateLimit = 8,    -- Max activations accepted per player per second
}

-- ── Merge ──────────────────────────────────────────────────────────────────

--- Deep-merge user config over defaults. Nested tables are merged shallowly
--- so partial overrides work: { falloff = { enabled = true } } keeps all
--- other falloff keys from defaults intact.
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

-- ── Validate ───────────────────────────────────────────────────────────────

function Config.validate(cfg: { [string]: any })
	if (cfg.damage :: number) < 0 then
		warn("[WeaponKit] cfg.damage is negative — intentional?")
	end
	if (cfg.cooldown :: number) < 0 then
		warn("[WeaponKit] cfg.cooldown is negative; clamping to 0")
		cfg.cooldown = 0
	end
	if (cfg.range :: number) <= 0 then
		warn("[WeaponKit] cfg.range must be > 0; resetting to 8")
		cfg.range = 8
	end
	-- Only compare melee range against maxRange — for hitscan weapons cfg.range
	-- is the melee hitbox depth (irrelevant) and maxRange is the ray ceiling.
	if cfg.weaponType ~= "hitscan" and (cfg.maxRange :: number) < (cfg.range :: number) then
		warn(string.format(
			"[WeaponKit] cfg.maxRange (%d) < cfg.range (%d); raising maxRange to match",
			cfg.maxRange :: number, cfg.range :: number
		))
		cfg.maxRange = cfg.range
	end

	-- Weapon type
	local wt = cfg.weaponType :: string?
	if wt and wt ~= "melee" and wt ~= "hitscan" then
		warn("[WeaponKit] Unknown cfg.weaponType '" .. tostring(wt) .. "'; defaulting to 'melee'")
		cfg.weaponType = "melee"
	end
	if cfg.weaponType == "hitscan" then
		local hs = cfg.hitscan :: { [string]: any }?
		local hsRange = (hs and hs.maxRange :: number?) or 300
		if (cfg.maxRange :: number) < hsRange then cfg.maxRange = hsRange end
	end

	-- Falloff
	local fo = cfg.falloff :: { [string]: any }?
	if fo and fo.enabled then
		if (fo.zeroRange :: number) <= (fo.fullDamageRange :: number) then
			warn("[WeaponKit] cfg.falloff.zeroRange must be > fullDamageRange; disabling falloff")
			fo.enabled = false
		end
	end

	-- Penetration
	local pen = cfg.penetration :: { [string]: any }?
	if pen then
		if type(pen.maxTargets) == "number" then
			pen.maxTargets = math.clamp(math.round(pen.maxTargets :: number), 1, 10)
		end
		if type(pen.damageDecay) == "number" then
			pen.damageDecay = math.clamp(pen.damageDecay :: number, 0.01, 1.0)
		end
	end

	-- Speed check
	local sc = cfg.speedCheck :: { [string]: any }?
	if sc and sc.enabled and (sc.maxSpeed :: number?) and (sc.maxSpeed :: number) <= 0 then
		warn("[WeaponKit] cfg.speedCheck.maxSpeed must be > 0; disabling speed check")
		sc.enabled = false
	end

	-- Animation IDs
	local animCfg = cfg.animations :: { [string]: string }?
	if animCfg then
		for slot, id in animCfg :: { [string]: string } do
			if id ~= "" and id ~= "0" and not string.match(id, "^rbxassetid://") then
				warn(("[WeaponKit] cfg.animations.%s = '%s' — use 'rbxassetid://<number>'"):format(slot, id))
			end
		end
	end

	-- Debug
	local dbg = cfg.debug :: { [string]: any }?
	if dbg and dbg.enabled and not dbg.targetPlayer then
		warn("[WeaponKit] cfg.debug.enabled = true but cfg.debug.targetPlayer is nil — "
			.. "no debug data will be sent until SetTarget() is called.")
	end
end

return Config
