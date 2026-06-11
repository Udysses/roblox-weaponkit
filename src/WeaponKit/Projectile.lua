--!strict
-- Projectile.lua
-- Hitscan (instant raycast) weapon support for WeaponKit.
--
-- Architecture:
--   Client  → fires raycast immediately for local visual feedback
--             spawns a tracer (direct or via EffectPool)
--             sends {origin, direction, distance, timestamp} to the server
--
--   Server  → re-runs the raycast with all character positions rewound to
--             `timestamp` via LagCompensation
--             validates origin proximity, self-hit, alive check, damage clamp
--             returns the restore function so LineOfSight can run inside the
--             same rewind bracket (caller must invoke restore() when done)

local RunService = game:GetService("RunService")
local Debris     = game:GetService("Debris")

-- ── Shared raycast helper ──────────────────────────────────────────────────

local function doRaycast(
	origin:    Vector3,
	direction: Vector3,
	maxDist:   number,
	exclude:   { Instance }
): RaycastResult?
	local params = RaycastParams.new()
	params.FilterType                 = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater                = true
	return workspace:Raycast(origin, direction.Unit * maxDist, params)
end

-- ── Hitscan — client-side fire ─────────────────────────────────────────────

local Hitscan   = {}
Hitscan.__index = Hitscan

-- Perform a client-side raycast for immediate visual feedback.
-- Does NOT apply damage — the server validates separately.
-- Returns (RaycastResult?, clientTimestamp).
function Hitscan.Fire(
	origin:    Vector3,
	direction: Vector3,
	maxDist:   number,
	exclude:   { Instance }
): (RaycastResult?, number)
	local result    = doRaycast(origin, direction, maxDist, exclude)
	local timestamp = workspace:GetServerTimeNow()
	return result, timestamp
end

-- ── Tracer — client-side visual ────────────────────────────────────────────

-- Spawn a moving tracer from `origin` toward `target` (or along `direction`).
-- `pool` is an optional EffectPool; if provided, Parts are recycled.
-- cfg keys: tracerColor (Color3), tracerLength (studs), tracerSpeed (studs/s)
local function SpawnTracer(
	origin:    Vector3,
	direction: Vector3,
	target:    Vector3?,
	cfg:       { [string]: any },
	pool:      any?   -- EffectPool | nil
)
	local color    = (cfg.tracerColor  :: Color3?)  or Color3.fromRGB(255, 210, 80)
	local length   = (cfg.tracerLength :: number?)  or 2.5
	local speed    = (cfg.tracerSpeed  :: number?)  or 600
	local maxDist  = (cfg.maxRange     :: number?)  or 300
	local lifetime = math.min(maxDist / speed + 0.1, 3)
	local dir      = target and (target - origin).Unit or direction.Unit

	local part: Part
	if pool then
		part = (pool :: any):Acquire()
		part.Size  = Vector3.new(0.05, 0.05, length)
		part.Color = color
	else
		part         = Instance.new("Part")
		part.Name    = "BulletTracer"
		part.Anchored  = true
		part.CanCollide = false
		part.CanTouch  = false
		part.CastShadow = false
		part.Size      = Vector3.new(0.05, 0.05, length)
		part.Material  = Enum.Material.Neon
		part.Color     = color
		part.Parent    = workspace
	end

	part.CFrame = CFrame.lookAt(origin, origin + dir) * CFrame.new(0, 0, -length * 0.5)

	local pos  = origin
	local vel  = dir * speed
	local conn : RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function(dt)
		if not part.Parent then conn:Disconnect(); return end
		pos = pos + vel * dt
		part.CFrame = CFrame.lookAt(pos, pos + vel) * CFrame.new(0, 0, -length * 0.5)
	end)

	if pool then
		task.delay(lifetime, function()
			pcall(conn.Disconnect, conn)
			;(pool :: any):Release(part, 0)
		end)
	else
		Debris:AddItem(part, lifetime)
		task.delay(lifetime, function()
			pcall(conn.Disconnect, conn)
		end)
	end
end

-- ── Server-side validator ──────────────────────────────────────────────────

local Validator   = {}
Validator.__index = Validator

-- `lagComp` is an optional LagCompensation instance.
function Validator.new(lagComp: any?): any
	return setmetatable({ _lagComp = lagComp }, Validator)
end

-- Validate a client-reported hitscan shot.
--
-- IMPORTANT: This function returns the restore() function WITHOUT calling it
-- so the caller (Server.lua) can run LineOfSight checks inside the same
-- rewind bracket. The caller MUST invoke restore() after all checks.
--
-- Returns: (hitModel?, reason?, hitPart?, distance, restoreFn)
--   hitModel  — victim's character Model, or nil on failure
--   reason    — human-readable rejection string (nil on success)
--   hitPart   — the specific BasePart hit (for headshot detection)
--   distance  — studs from origin to hit (for falloff)
--   restoreFn — call this to end the rewind bracket
function Validator:ValidateHitscan(
	shooter   : Player,
	data      : { [string]: any },
	cfg       : { [string]: any }
): (Model?, string?, BasePart?, number, () -> ())
	local noop = function() end

	local origin    = data.origin    :: Vector3?
	local direction = data.direction :: Vector3?
	local timestamp = data.timestamp :: number?

	if typeof(origin)    ~= "Vector3" then return nil, "missing origin",    nil, 0, noop end
	if typeof(direction) ~= "Vector3" then return nil, "missing direction", nil, 0, noop end

	local char = shooter.Character
	if not char then return nil, "no character", nil, 0, noop end

	local attackerRoot = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not attackerRoot then return nil, "no attacker root", nil, 0, noop end

	local originDelta = (origin - attackerRoot.Position).Magnitude
	if originDelta > 15 then
		return nil, ("origin %.1f studs from character"):format(originDelta), nil, 0, noop
	end

	local hitscanCfg = cfg.hitscan :: { [string]: any }?
	local maxRange   = math.min(
		(hitscanCfg and (hitscanCfg.maxRange :: number?)) or 300,
		cfg.maxRange :: number
	)

	-- Begin rewind bracket.
	local restore: () -> () = noop
	if self._lagComp and timestamp then
		restore = (self._lagComp :: any):Rewind(timestamp)
	end

	local result = doRaycast(origin :: Vector3, direction :: Vector3, maxRange, { char })

	-- Do NOT call restore() here — caller owns the bracket.

	if not result then
		return nil, "no hit", nil, 0, restore
	end

	local hitPart  = result.Instance :: BasePart
	local hitModel = hitPart:FindFirstAncestorOfClass("Model") :: Model?
	if not hitModel then
		return nil, "hit non-model", nil, 0, restore
	end

	local humanoid = hitModel:FindFirstChildOfClass("Humanoid")
	if not humanoid         then return nil, "no humanoid",  nil, 0, restore end
	if humanoid.Health <= 0 then return nil, "target dead",  nil, 0, restore end
	if hitModel == char     then return nil, "self-hit",     nil, 0, restore end

	local dist = (origin - result.Position).Magnitude
	return hitModel, nil, hitPart, dist, restore
end

-- Multi-pierce hitscan: successive raycasts through targets.
-- All raycasts run inside ONE rewind bracket (single Rewind call).
-- Returns: (hits, restoreFn)
--   hits = { {model: Model, hitPart: BasePart?, distance: number} }
function Validator:ValidateHitscanPierce(
	shooter    : Player,
	data       : { [string]: any },
	cfg        : { [string]: any },
	maxTargets : number
): ({ { model: Model, hitPart: BasePart?, distance: number } }, () -> ())
	local noop    = function() end
	local results : { { model: Model, hitPart: BasePart?, distance: number } } = {}

	local origin    = data.origin    :: Vector3?
	local direction = data.direction :: Vector3?
	local timestamp = data.timestamp :: number?

	if typeof(origin)    ~= "Vector3" then return results, noop end
	if typeof(direction) ~= "Vector3" then return results, noop end

	local char = shooter.Character
	if not char then return results, noop end

	local attackerRoot = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not attackerRoot then return results, noop end

	local hitscanCfg = cfg.hitscan :: { [string]: any }?
	local maxRange   = math.min(
		(hitscanCfg and (hitscanCfg.maxRange :: number?)) or 300,
		cfg.maxRange :: number
	)

	-- Single rewind bracket covering all successive raycasts.
	local restore: () -> () = noop
	if self._lagComp and timestamp then
		restore = (self._lagComp :: any):Rewind(timestamp)
	end

	local exclude  : { Instance } = { char }
	local remaining = maxRange
	local rayOrigin = origin :: Vector3
	local hitCount  = 0

	while hitCount < maxTargets and remaining > 0.1 do
		local result = doRaycast(rayOrigin, direction :: Vector3, remaining, exclude)
		if not result then break end

		local hitPart  = result.Instance :: BasePart
		local hitModel = hitPart:FindFirstAncestorOfClass("Model") :: Model?
		local dist     = (rayOrigin - result.Position).Magnitude

		if hitModel then
			local hum = hitModel:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 and hitModel ~= char then
				table.insert(results, { model = hitModel, hitPart = hitPart, distance = dist })
				hitCount += 1
				-- Exclude this character from future raycasts in this chain.
				table.insert(exclude, hitModel)
			end
		end

		-- Continue from just past the hit point.
		remaining = remaining - dist - 0.1
		rayOrigin = result.Position + (direction :: Vector3).Unit * 0.1
	end

	return results, restore
end

-- ── Public API ─────────────────────────────────────────────────────────────

return {
	Hitscan     = Hitscan,
	Validator   = Validator,
	SpawnTracer = SpawnTracer,
	Raycast     = doRaycast,
}
