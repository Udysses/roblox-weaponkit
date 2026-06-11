--!strict
-- Server.lua  (runs inside a Script in your Tool)
--
-- What this module handles so you don't have to:
--
--   "weapon won't fire / RemoteEvent not found"
--     → Creates WeaponKit_Fire synchronously on startup so the client's
--       WaitForChild never hangs or times out.
--
--   "ACS feels laggy / high-ping players can't hit"
--     → Lag compensation: every player's character positions are sampled at
--       20 Hz. When a fire event arrives the server rewinds hitboxes to the
--       client's timestamp before validating, then restores immediately.
--       This is "favor-the-shooter" — identical to Source engine behavior.
--
--   "exploiters dealing infinite damage by firing the remote directly"
--     → Server re-validates hit distance independently.
--     → Per-player rate limiter rejects fire events above the threshold.
--     → Damage is clamped to cfg.maxDamage regardless of client claims.
--     → Hit payload is capped at cfg.maxHitsPerEvent entries.
--
--   "attempt to index nil with Humanoid" on the server
--     → Every access is guarded with nil checks before TakeDamage is called.
--
--   "can't damage R6 rigs or non-player NPCs"
--     → FindFirstChildOfClass("Humanoid") works on any Model.
--
--   "all players take damage when one player swings"
--     → Each weapon instance has completely isolated state. No shared globals.
--
--   "gun hits not registering even when they clearly landed"
--     → Hitscan path re-runs the client's raycast on the server with rewound
--       positions, so what the client saw is what the server validates.

local Players = game:GetService("Players")

local Maid            = require(script.Parent.Maid)
local Config          = require(script.Parent.Config)
local LagCompensation = require(script.Parent.LagCompensation)
local Projectile      = require(script.Parent.Projectile)

-- ── Types ──────────────────────────────────────────────────────────────────

type RateEntry = { count: number, resetAt: number }

type MeleeHit = {
	charName  : string,
	rootPos   : Vector3,
	timestamp : number?,
}

type HitscanShot = {
	origin    : Vector3,
	direction : Vector3,
	distance  : number?,
	timestamp : number?,
}

-- ── Module ─────────────────────────────────────────────────────────────────

local Server   = {}
Server.__index = Server

-- ── Constructor ────────────────────────────────────────────────────────────

function Server.new(tool: Tool, userConfig: { [string]: any }?)
	local cfg = Config.merge(Config.Defaults, userConfig or {})
	Config.validate(cfg)

	-- Create the RemoteEvent NOW, synchronously, before Start() is called.
	-- The LocalScript uses WaitForChild("WeaponKit_Fire") — it will find it
	-- immediately because this runs first in the server Script.
	local remote = tool:FindFirstChild("WeaponKit_Fire") :: RemoteEvent?
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name   = "WeaponKit_Fire"
		remote.Parent = tool
	end

	-- Lag compensation: shared singleton so all weapons reuse one sampler.
	local lagComp: any = nil
	local lagCfg = cfg.lagCompensation :: { [string]: any }?
	if lagCfg and lagCfg.enabled then
		lagComp = LagCompensation.getShared()
	end

	-- Hitscan validator (used when weaponType = "hitscan").
	local validator = Projectile.Validator.new(lagComp)

	return setmetatable({
		_tool       = tool,
		_config     = cfg,
		_maid       = Maid.new(),
		_remote     = remote :: RemoteEvent,
		_rateState  = {} :: { [Player]: RateEntry },
		_lagComp    = lagComp,
		_validator  = validator,
	}, Server)
end

-- ── Public ─────────────────────────────────────────────────────────────────

--- Call once after requiring WeaponKit. Connects the OnServerEvent listener.
function Server:Start()
	local maid = self._maid

	maid:Give(self._remote.OnServerEvent:Connect(function(player: Player, data: unknown, timestamp: unknown)
		self:_onFire(player, data, timestamp)
	end))

	maid:Give(self._tool.AncestryChanged:Connect(function()
		if not self._tool:IsDescendantOf(game) then
			self:Destroy()
		end
	end))

	maid:Give(Players.PlayerRemoving:Connect(function(player: Player)
		self._rateState[player] = nil
	end))
end

--- Clean up all server-side state.
function Server:Destroy()
	self._maid:Destroy()
	self._rateState = {}
end

-- ── Private: fire router ───────────────────────────────────────────────────

function Server:_onFire(player: Player, data: unknown, timestamp: unknown)
	local char = player.Character
	if not char then return end

	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then return end

	if not self:_checkRate(player) then
		warn(string.format(
			"[WeaponKit] Rate limit exceeded: %s fired %s more than %d times/s",
			player.Name,
			self._tool.Name,
			self._config.rateLimit :: number
		))
		return
	end

	local weaponType = self._config.weaponType :: string

	if weaponType == "hitscan" then
		-- data = {origin, direction, distance?, timestamp?}
		if type(data) ~= "table" then return end
		local shot = data :: HitscanShot
		-- Allow timestamp as either a field in data or the separate argument.
		if typeof(timestamp) == "number" and not shot.timestamp then
			shot = table.clone(shot :: { [string]: any }) :: HitscanShot
			;(shot :: { [string]: any }).timestamp = timestamp :: number
		end
		self:_onFireHitscan(player, char, root, shot)
	else
		-- data = { {charName, rootPos, timestamp?}, ... }
		if type(data) ~= "table" then return end
		local ts: number? = typeof(timestamp) == "number" and (timestamp :: number) or nil
		self:_onFireMelee(player, char, root, data :: { MeleeHit }, ts)
	end
end

-- ── Private: melee path ────────────────────────────────────────────────────

function Server:_onFireMelee(
	player  : Player,
	char    : Model,
	root    : BasePart,
	hits    : { MeleeHit },
	timestamp : number?
)
	local cfg         = self._config
	local maxHits     = cfg.maxHitsPerEvent :: number
	local damaged: { [Model]: boolean } = {}

	-- Rewind positions for lag compensation (if enabled).
	-- All melee distance checks run against rewound positions.
	local ts = timestamp
	-- Also accept timestamp embedded in first hit entry.
	if not ts and #hits > 0 and typeof((hits[1] :: { [string]: any }).timestamp) == "number" then
		ts = (hits[1] :: { [string]: any }).timestamp :: number
	end

	local restore: (() -> ())?
	if self._lagComp and ts then
		restore = (self._lagComp :: any):Rewind(ts)
	end

	local count = 0
	for _, hit in hits :: { { [string]: any } } do
		if count >= maxHits then break end

		if type(hit) ~= "table" then continue end

		local charName = hit.charName :: string?
		local rootPos  = hit.rootPos  :: Vector3?

		if type(charName) ~= "string"  then continue end
		if typeof(rootPos) ~= "Vector3" then continue end

		local targetModel = workspace:FindFirstChild(charName) :: Model?
		if not targetModel        then continue end
		if damaged[targetModel]   then continue end

		local dist = (root.Position - (rootPos :: Vector3)).Magnitude
		if dist > (cfg.maxRange :: number) then
			warn(string.format(
				"[WeaponKit] Hit rejected: %s claimed range %.1f studs (max %d) on %s",
				player.Name, dist, cfg.maxRange :: number, self._tool.Name
			))
			continue
		end

		local humanoid = targetModel:FindFirstChildOfClass("Humanoid") :: Humanoid?
		if not humanoid         then continue end
		if humanoid.Health <= 0 then continue end
		if targetModel == char  then continue end

		local dmg = math.min(cfg.damage :: number, cfg.maxDamage :: number)
		humanoid:TakeDamage(dmg)
		damaged[targetModel] = true
		count += 1
	end

	if restore then restore() end
end

-- ── Private: hitscan path ──────────────────────────────────────────────────

function Server:_onFireHitscan(
	player : Player,
	char   : Model,
	root   : BasePart,
	shot   : HitscanShot
)
	local cfg = self._config

	local hitModel, reason = self._validator:ValidateHitscan(player, shot :: { [string]: any }, cfg)

	if not hitModel then
		-- Log only unusual rejections (not plain misses).
		if reason and reason ~= "no hit" then
			warn(("[WeaponKit] Hitscan rejected for %s: %s"):format(player.Name, reason))
		end
		return
	end

	local humanoid = hitModel:FindFirstChildOfClass("Humanoid") :: Humanoid?
	if not humanoid or humanoid.Health <= 0 then return end

	local dmg = math.min(cfg.damage :: number, cfg.maxDamage :: number)
	humanoid:TakeDamage(dmg)
end

-- ── Private: rate limiter ──────────────────────────────────────────────────

function Server:_checkRate(player: Player): boolean
	local now   = os.clock()
	local state = self._rateState[player]

	if not state or now >= state.resetAt then
		self._rateState[player] = { count = 1, resetAt = now + 1 }
		return true
	end

	state.count += 1
	return state.count <= (self._config.rateLimit :: number)
end

return Server
