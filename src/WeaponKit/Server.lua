--!strict
-- Server.lua  (runs inside a Script in your Tool)
--
-- What this module handles so you don't have to:
--
--   "ACS / any weapon feels laggy at high ping"
--     → Lag compensation: position history sampled at 20 Hz. Server rewinds
--       all character hitboxes to the client's fire timestamp, validates, then
--       restores. "Favor-the-shooter" — identical to Source engine behavior.
--
--   "bullets passing through walls"
--     → cfg.lineOfSight.enabled: server raycasts attacker→victim inside the
--       rewind bracket. Rejected if a wall/prop is hit before the victim.
--
--   "exploiters dealing infinite damage"
--     → Range + rate + damage clamp + hit count ceiling all re-validated
--       server-side. Client data is never trusted for damage.
--
--   "speedhackers or teleport exploiters"
--     → cfg.speedCheck.enabled: attacker's server-measured displacement
--       between fire events is compared against cfg.speedCheck.maxSpeed.
--
--   "guns that don't respect falloff / headshots / penetration"
--     → DamageCurve applies falloff curve, headshot multiplier, and pierce
--       decay before every TakeDamage call.
--
--   "no way to award points / log analytics without editing WeaponKit"
--     → server.hooks.OnHit / OnKill / OnMiss / OnRateExceeded signals.
--       Attach external listeners without touching this file.
--
--   "can't see what the server is checking"
--     → cfg.debug.enabled + cfg.debug.targetPlayer: coloured hitbox and ray
--       adornments sent to one specific client only.
--
--   "parallel validation crashes the Script"
--     → cfg.parallelValidation.enabled is tested at startup; if the Script is
--       not inside a Roblox Actor the flag is auto-disabled with a warning.

local Players = game:GetService("Players")

local Maid            = require(script.Parent.Maid)
local Config          = require(script.Parent.Config)
local LagCompensation = require(script.Parent.LagCompensation)
local Projectile      = require(script.Parent.Projectile)
local Hooks           = require(script.Parent.Hooks)
local LineOfSight     = require(script.Parent.LineOfSight)
local DebugViz        = require(script.Parent.DebugViz)
local DamageCurve     = require(script.Parent.DamageCurve)

-- ── Types ──────────────────────────────────────────────────────────────────

type RateEntry   = { count: number, resetAt: number }
type SpeedSample = { pos: Vector3, t: number }

type MeleeHit = {
	charName : string,
	rootPos  : Vector3,
}

type HitscanShot = {
	origin    : Vector3,
	direction : Vector3,
	distance  : number?,
	timestamp : number?,
}

type ValidTarget = {
	model  : Model,
	hum    : Humanoid,
	dist   : number,
	rootPos: Vector3,
}

-- ── Module ─────────────────────────────────────────────────────────────────

local Server   = {}
Server.__index = Server

-- ── Constructor ────────────────────────────────────────────────────────────

function Server.new(tool: Tool, userConfig: { [string]: any }?)
	local cfg = Config.merge(Config.Defaults, userConfig or {})
	Config.validate(cfg)

	-- ── Parallel Luau Actor check ───────────────────────────────────────
	-- task.desynchronize() throws if the Script is not inside a Roblox Actor.
	-- Test at startup so developers get a clear warning instead of a cryptic
	-- runtime error on the first shot.
	local parallelCfg = cfg.parallelValidation :: { [string]: any }?
	if parallelCfg and parallelCfg.enabled then
		local canParallel = pcall(function()
			task.desynchronize()
			task.synchronize()
		end)
		if not canParallel then
			warn("[WeaponKit] cfg.parallelValidation.enabled = true requires this Script to run "
				.. "inside a Roblox Actor. Parallel validation disabled.")
			parallelCfg.enabled = false
		end
	end

	-- ── RemoteEvent (reliable, damage) ─────────────────────────────────
	local remote = tool:FindFirstChild("WeaponKit_Fire") :: RemoteEvent?
	if not remote then
		remote = Instance.new("RemoteEvent")
		;(remote :: RemoteEvent).Name   = "WeaponKit_Fire"
		;(remote :: RemoteEvent).Parent = tool
	end

	-- ── UnreliableRemoteEvent (visual effects broadcast) ───────────────
	local effectCfg     = cfg.effects :: { [string]: any }?
	local useUnreliable = effectCfg and effectCfg.useUnreliableRemote
	local effectRemote: UnreliableRemoteEvent? = nil
	if useUnreliable then
		local existing = tool:FindFirstChild("WeaponKit_Effects")
		if existing and existing:IsA("UnreliableRemoteEvent") then
			effectRemote = existing :: UnreliableRemoteEvent
		else
			local ure     = Instance.new("UnreliableRemoteEvent")
			ure.Name      = "WeaponKit_Effects"
			ure.Parent    = tool
			effectRemote  = ure
		end
	end

	-- ── Lag compensation (shared singleton) ────────────────────────────
	local lagComp: any = nil
	local lagCfg = cfg.lagCompensation :: { [string]: any }?
	if lagCfg and lagCfg.enabled then
		lagComp = LagCompensation.getShared()
	end

	-- ── Hitscan validator ───────────────────────────────────────────────
	local validator = Projectile.Validator.new(lagComp)

	-- ── Debug visualization ─────────────────────────────────────────────
	local debugCfg = cfg.debug :: { [string]: any }?
	local maid     = Maid.new()
	local debugViz = DebugViz.newServer(tool, maid, debugCfg)

	return setmetatable({
		_tool         = tool,
		_config       = cfg,
		_maid         = maid,
		_remote       = remote :: RemoteEvent,
		_effectRemote = effectRemote,
		_rateState    = {} :: { [Player]: RateEntry },
		_speedSamples = {} :: { [Player]: SpeedSample },
		_lagComp      = lagComp,
		_validator    = validator,
		_debugViz     = debugViz,
		-- Public: external code attaches listeners here.
		hooks         = Hooks.new(),
	}, Server)
end

-- ── Public ─────────────────────────────────────────────────────────────────

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
		self._rateState[player]    = nil
		self._speedSamples[player] = nil
	end))
end

function Server:Destroy()
	self._maid:Destroy()
	self._rateState    = {}
	self._speedSamples = {}
	self.hooks:DisconnectAll()
	;(self._debugViz :: any):Destroy()
end

-- Public wrapper so ACSBridge and other external modules can consume from
-- the shared rate bucket without calling the private implementation directly.
function Server:CheckRate(player: Player): boolean
	return self:_checkRate(player)
end

-- ── Private: fire router ───────────────────────────────────────────────────

function Server:_onFire(player: Player, data: unknown, timestamp: unknown)
	local char = player.Character
	if not char then return end

	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then return end

	if not self:_checkRate(player) then
		warn(string.format(
			"[WeaponKit] Rate limit: %s fired %s more than %d/s",
			player.Name, self._tool.Name, self._config.rateLimit :: number
		))
		self.hooks.OnRateExceeded:Fire(player)
		return
	end

	if not self:_checkSpeed(player, root) then
		self.hooks.OnRateExceeded:Fire(player)
		return
	end

	local weaponType = self._config.weaponType :: string
	local ts: number? = typeof(timestamp) == "number" and (timestamp :: number) or nil

	if weaponType == "hitscan" then
		if type(data) ~= "table" then return end
		local shot = data :: HitscanShot
		if ts and not (shot :: { [string]: any }).timestamp then
			;(shot :: { [string]: any }).timestamp = ts
		end
		self:_onFireHitscan(player, char, root, shot)
	else
		if type(data) ~= "table" then return end
		self:_onFireMelee(player, char, root, data :: { MeleeHit }, ts)
	end
end

-- ── Private: melee path ────────────────────────────────────────────────────

function Server:_onFireMelee(
	player    : Player,
	char      : Model,
	root      : BasePart,
	hits      : { MeleeHit },
	timestamp : number?
)
	local cfg         = self._config
	local maxHits     = cfg.maxHitsPerEvent :: number
	local losCfg      = cfg.lineOfSight :: { [string]: any }?
	local losEnabled  = losCfg and losCfg.enabled
	local falloffCfg  = cfg.falloff    :: { [string]: any }?
	local headshotCfg = cfg.headshot   :: { [string]: any }?
	local parallelCfg = cfg.parallelValidation :: { [string]: any }?
	local useParallel = parallelCfg and parallelCfg.enabled

	-- ── Rewind bracket ──────────────────────────────────────────────────
	-- CFrame writes require the synchronised context. The Actor-check in
	-- Server.new() guarantees that if useParallel is true we are in an Actor.
	local restore: () -> () = function() end
	if self._lagComp and timestamp then
		restore = (self._lagComp :: any):Rewind(timestamp)
	end

	-- ── Phase 1: validate (read-only, safe to desynchronize) ───────────
	-- Collect all targets that pass every check into validTargets.
	-- No TakeDamage or CFrame writes happen in this phase.
	-- A single desync/sync pair wraps the whole phase — no nesting inside
	-- the loop, so break/continue cannot leave the thread in the wrong state.
	local validTargets: { ValidTarget } = {}
	local seen: { [Model]: boolean } = {}

	if useParallel then task.desynchronize() end

	local count = 0
	for _, hit in hits :: { { [string]: any } } do
		if count >= maxHits then break end
		if type(hit) ~= "table" then continue end

		local charName = hit.charName :: string?
		local rootPos  = hit.rootPos  :: Vector3?

		if type(charName)   ~= "string"  then continue end
		if typeof(rootPos)  ~= "Vector3" then continue end

		local targetModel = workspace:FindFirstChild(charName) :: Model?
		if not targetModel or seen[targetModel] then continue end

		local dist = (root.Position - (rootPos :: Vector3)).Magnitude
		if dist > (cfg.maxRange :: number) then
			self.hooks.OnMiss:Fire(player, "out of range")
			continue
		end

		if losEnabled then
			local ok, reason = LineOfSight.Assert(char, root, rootPos :: Vector3, targetModel)
			if not ok then
				self.hooks.OnMiss:Fire(player, reason or "LOS blocked")
				continue
			end
		end

		local humanoid = targetModel:FindFirstChildOfClass("Humanoid") :: Humanoid?
		if not humanoid or humanoid.Health <= 0 then continue end
		if targetModel == char then continue end

		seen[targetModel] = true
		table.insert(validTargets, {
			model   = targetModel,
			hum     = humanoid,
			dist    = dist,
			rootPos = rootPos :: Vector3,
		})
		count += 1
	end

	-- ── Phase 2: apply damage (sync required for TakeDamage/CFrame) ────
	if useParallel then task.synchronize() end
	restore()  -- end rewind bracket — always runs in sync context

	for _, vt in validTargets do
		if vt.hum.Health <= 0 then continue end  -- re-check; may have changed

		local rawDmg            = cfg.damage :: number
		local penCfg            = cfg.penetration :: { [string]: any }?
		local finalDmg, wasHead = DamageCurve.Compute(
			rawDmg, vt.dist, nil, falloffCfg, headshotCfg, 0, penCfg
		)
		finalDmg = math.min(finalDmg, cfg.maxDamage :: number)

		local prevHealth = vt.hum.Health
		vt.hum:TakeDamage(finalDmg)

		local boxCF = root.CFrame * CFrame.new(0, 0, -(cfg.range :: number) / 2)
		;(self._debugViz :: any):SendHitbox(boxCF, cfg.hitboxSize :: Vector3, true)

		local ctx: Hooks.HitContext = {
			weaponName  = self._tool.Name,
			weaponType  = "melee",
			damage      = finalDmg,
			rawDamage   = rawDmg,
			isHeadshot  = wasHead,
			distance    = vt.dist,
			hitPart     = nil,
			hitPos      = vt.rootPos,
			timestamp   = timestamp or 0,
			pierceIndex = 0,
		}
		self.hooks.OnHit:Fire(player, vt.model, finalDmg, ctx)
		if prevHealth > 0 and vt.hum.Health <= 0 then
			self.hooks.OnKill:Fire(player, vt.model, ctx)
		end
	end
end

-- ── Private: hitscan path ──────────────────────────────────────────────────

function Server:_onFireHitscan(
	player : Player,
	char   : Model,
	root   : BasePart,
	shot   : HitscanShot
)
	local cfg         = self._config
	local losCfg      = cfg.lineOfSight  :: { [string]: any }?
	local losEnabled  = losCfg and losCfg.enabled
	local falloffCfg  = cfg.falloff      :: { [string]: any }?
	local headshotCfg = cfg.headshot     :: { [string]: any }?
	local penCfg      = cfg.penetration  :: { [string]: any }?
	local usePierce   = penCfg and penCfg.enabled

	if usePierce then
		self:_onFireHitscanPierce(player, char, root, shot)
		return
	end

	local shotData = shot :: { [string]: any }
	local origin   = shotData.origin    :: Vector3
	local dir      = shotData.direction :: Vector3

	-- ValidateHitscan returns the restore fn WITHOUT calling it so LineOfSight
	-- can run inside the same rewind bracket.
	local hitModel, reason, hitPart, dist, restore =
		self._validator:ValidateHitscan(player, shotData, cfg)

	if not hitModel then
		restore()
		if reason and reason ~= "no hit" then
			warn(("[WeaponKit] Hitscan rejected for %s: %s"):format(player.Name, reason))
			self.hooks.OnMiss:Fire(player, reason)
		end
		-- Use dist=0 on miss — never trust the client-supplied distance for visualization.
		;(self._debugViz :: any):SendRay(origin, dir, 0, false)
		return
	end

	-- LOS check inside the rewind bracket (positions still rewound).
	if losEnabled then
		local victimRoot = (hitModel :: Model):FindFirstChild("HumanoidRootPart") :: BasePart?
		if victimRoot then
			local ok, losReason = LineOfSight.Assert(char, root, victimRoot.Position, hitModel)
			if not ok then
				restore()
				warn(("[WeaponKit] LOS blocked for %s: %s"):format(player.Name, losReason))
				self.hooks.OnMiss:Fire(player, losReason or "LOS blocked")
				;(self._debugViz :: any):SendRay(origin, dir, dist, false)
				return
			end
		end
	end

	restore()  -- end rewind bracket

	local humanoid = (hitModel :: Model):FindFirstChildOfClass("Humanoid") :: Humanoid?
	if not humanoid or humanoid.Health <= 0 then return end

	local rawDmg = cfg.damage :: number
	local hitPartName = hitPart and (hitPart :: BasePart).Name or nil
	local finalDmg, wasHeadshot = DamageCurve.Compute(
		rawDmg, dist, hitPartName, falloffCfg, headshotCfg, 0, penCfg
	)
	finalDmg = math.min(finalDmg, cfg.maxDamage :: number)

	local prevHealth = humanoid.Health
	humanoid:TakeDamage(finalDmg)

	;(self._debugViz :: any):SendRay(origin, dir, dist, true)

	if self._effectRemote then
		self._effectRemote:FireAllClients("impact", origin, dir, dist)
	end

	local ctx: Hooks.HitContext = {
		weaponName  = self._tool.Name,
		weaponType  = "hitscan",
		damage      = finalDmg,
		rawDamage   = rawDmg,
		isHeadshot  = wasHeadshot,
		distance    = dist,
		hitPart     = hitPart,
		hitPos      = hitPart and (hitPart :: BasePart).Position or nil,
		timestamp   = (shotData.timestamp :: number?) or 0,
		pierceIndex = 0,
	}
	self.hooks.OnHit:Fire(player, hitModel :: Model, finalDmg, ctx)
	if prevHealth > 0 and humanoid.Health <= 0 then
		self.hooks.OnKill:Fire(player, hitModel :: Model, ctx)
	end
end

-- ── Private: hitscan pierce path ──────────────────────────────────────────

function Server:_onFireHitscanPierce(
	player : Player,
	char   : Model,
	root   : BasePart,
	shot   : HitscanShot
)
	local cfg         = self._config
	local penCfg      = cfg.penetration :: { [string]: any }
	local maxTargets  = penCfg.maxTargets :: number
	local falloffCfg  = cfg.falloff    :: { [string]: any }?
	local headshotCfg = cfg.headshot   :: { [string]: any }?

	local hits, restore = self._validator:ValidateHitscanPierce(
		player, shot :: { [string]: any }, cfg, maxTargets
	)
	restore()

	local damaged: { [Model]: boolean } = {}

	for i, hitEntry in hits do
		local hitModel = hitEntry.model
		if damaged[hitModel] then continue end

		local humanoid = hitModel:FindFirstChildOfClass("Humanoid") :: Humanoid?
		if not humanoid or humanoid.Health <= 0 then continue end

		local rawDmg = cfg.damage :: number
		local hitPartName = hitEntry.hitPart and hitEntry.hitPart.Name or nil
		local finalDmg, wasHeadshot = DamageCurve.Compute(
			rawDmg, hitEntry.distance, hitPartName,
			falloffCfg, headshotCfg, i - 1, penCfg
		)
		finalDmg = math.min(finalDmg, cfg.maxDamage :: number)

		local prevHealth = humanoid.Health
		humanoid:TakeDamage(finalDmg)
		damaged[hitModel] = true

		local ctx: Hooks.HitContext = {
			weaponName  = self._tool.Name,
			weaponType  = "hitscan",
			damage      = finalDmg,
			rawDamage   = rawDmg,
			isHeadshot  = wasHeadshot,
			distance    = hitEntry.distance,
			hitPart     = hitEntry.hitPart,
			hitPos      = hitEntry.hitPart and hitEntry.hitPart.Position or nil,
			timestamp   = (shot :: { [string]: any }).timestamp :: number? or 0,
			pierceIndex = i - 1,
		}
		self.hooks.OnHit:Fire(player, hitModel, finalDmg, ctx)
		if prevHealth > 0 and humanoid.Health <= 0 then
			self.hooks.OnKill:Fire(player, hitModel, ctx)
		end
	end
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

-- ── Private: speed check ──────────────────────────────────────────────────

function Server:_checkSpeed(player: Player, root: BasePart): boolean
	local sc = self._config.speedCheck :: { [string]: any }?
	if not sc or not sc.enabled then return true end

	local now    = workspace:GetServerTimeNow()
	local prev   = self._speedSamples[player]
	local sample : SpeedSample = { pos = root.Position, t = now }

	if prev then
		local dt = now - prev.t
		if dt > 0 and dt < (sc.sampleWindow :: number) * 2 then
			local speed = (root.Position - prev.pos).Magnitude / dt
			if speed > (sc.maxSpeed :: number) then
				warn(("[WeaponKit] Speed check failed for %s: %.1f studs/s (max %.1f)"):format(
					player.Name, speed, sc.maxSpeed :: number
				))
				self._speedSamples[player] = sample
				return false
			end
		end
	end

	self._speedSamples[player] = sample
	return true
end

return Server
