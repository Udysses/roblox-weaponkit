--!strict
-- Projectile.lua
-- Hitscan (instant raycast) weapon support for WeaponKit.
-- Extends the base melee system to support guns and ACS-style FPS weapons.
--
-- Architecture:
--   Client  → fires raycast immediately for local visual feedback
--             spawns a tracer part moving toward the hit point
--             sends {origin, direction, distance, timestamp} to the server
--
--   Server  → re-runs the raycast with all character positions rewound to
--             `timestamp` via LagCompensation (so high-ping players register
--             hits they clearly landed on their own screen)
--             validates origin proximity, self-hit, alive check, damage clamp
--
-- This module is required by Client.lua (Hitscan + SpawnTracer) and
-- Server.lua (Validator). Use cfg.weaponType = "hitscan" to activate.

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

local Hitscan = {}
Hitscan.__index = Hitscan

-- Perform a client-side raycast for immediate visual feedback.
-- Does NOT apply damage — the server validates separately.
-- Returns (RaycastResult?, clientTimestamp).
-- The timestamp must be sent to the server as-is for lag compensation.
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

-- Spawn a moving tracer part from `origin` toward `target` (or along direction).
-- cfg keys:  tracerColor (Color3), tracerLength (studs), tracerSpeed (studs/s)
local function SpawnTracer(
	origin:    Vector3,
	direction: Vector3,
	target:    Vector3?,
	cfg:       { [string]: any }
)
	local color   = (cfg.tracerColor  :: Color3?)  or Color3.fromRGB(255, 210, 80)
	local length  = (cfg.tracerLength :: number?)  or 2.5
	local speed   = (cfg.tracerSpeed  :: number?)  or 600
	local maxDist = (cfg.maxRange     :: number?)  or 300
	local lifetime = math.min(maxDist / speed + 0.1, 3)

	local dir = target and (target - origin).Unit or direction.Unit

	local part      = Instance.new("Part")
	part.Name       = "BulletTracer"
	part.Anchored   = true
	part.CanCollide = false
	part.CanTouch   = false
	part.CastShadow = false
	part.Size       = Vector3.new(0.05, 0.05, length)
	part.Material   = Enum.Material.Neon
	part.Color      = color
	part.CFrame     = CFrame.lookAt(origin, origin + dir) * CFrame.new(0, 0, -length * 0.5)
	part.Parent     = workspace
	Debris:AddItem(part, lifetime)

	local pos = origin
	local vel = dir * speed
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function(dt)
		if not part.Parent then conn:Disconnect(); return end
		pos = pos + vel * dt
		part.CFrame = CFrame.lookAt(pos, pos + vel) * CFrame.new(0, 0, -length * 0.5)
	end)
	task.delay(lifetime, function()
		pcall(conn.Disconnect, conn)
	end)
end

-- ── Server-side validator ──────────────────────────────────────────────────

local Validator   = {}
Validator.__index = Validator

-- `lagComp` is an optional LagCompensation instance.
-- If nil, validation runs against live positions (no rewind).
function Validator.new(lagComp: any?): any
	return setmetatable({ _lagComp = lagComp }, Validator)
end

-- Validate a client-reported hitscan shot on the server.
-- Returns (hitCharacter: Model?, failReason: string?).
--
-- `data` is the table sent by the client:
--   { origin: Vector3, direction: Vector3, distance: number, timestamp: number }
--
-- `cfg` is the weapon's merged config table.
function Validator:ValidateHitscan(
	shooter   : Player,
	data      : { [string]: any },
	cfg       : { [string]: any }
): (Model?, string?)
	local origin    = data.origin    :: Vector3?
	local direction = data.direction :: Vector3?
	local distance  = data.distance  :: number?
	local timestamp = data.timestamp :: number?

	if typeof(origin)    ~= "Vector3" then return nil, "missing origin"    end
	if typeof(direction) ~= "Vector3" then return nil, "missing direction" end

	local char = shooter.Character
	if not char then return nil, "no character" end

	local attackerRoot = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not attackerRoot then return nil, "no attacker root" end

	-- Verify origin isn't teleport-faked: must be near the character's muzzle.
	-- 15 studs is generous for any gun viewmodel offset.
	local originDelta = (origin - attackerRoot.Position).Magnitude
	if originDelta > 15 then
		return nil, ("origin %.1f studs from character (max 15)"):format(originDelta)
	end

	local hitscanCfg = cfg.hitscan :: { [string]: any }?
	local maxRange   = math.min(
		distance or (hitscanCfg and hitscanCfg.maxRange) or 300,
		(hitscanCfg and hitscanCfg.maxRange) or 300,
		cfg.maxRange :: number
	)

	-- Rewind all character positions to when the client fired.
	local restore: (() -> ())?
	if self._lagComp and timestamp then
		restore = (self._lagComp :: any):Rewind(timestamp)
	end

	local result = doRaycast(origin :: Vector3, direction :: Vector3, maxRange, { char })

	if restore then restore() end

	if not result then return nil, "no raycast hit" end

	local hitModel = result.Instance:FindFirstAncestorOfClass("Model") :: Model?
	if not hitModel then return nil, "hit non-model" end

	local humanoid = hitModel:FindFirstChildOfClass("Humanoid")
	if not humanoid         then return nil, "no humanoid"    end
	if humanoid.Health <= 0 then return nil, "target dead"    end
	if hitModel == char     then return nil, "self-hit"        end

	return hitModel, nil
end

-- ── Public API ─────────────────────────────────────────────────────────────

return {
	Hitscan     = Hitscan,
	Validator   = Validator,
	SpawnTracer = SpawnTracer,
	Raycast     = doRaycast,
}
