--!strict
-- Client.lua  (runs inside a LocalScript in your Tool)
--
-- What this module handles so you don't have to:
--
--   "animation stuck / lag accumulates / nil Humanoid"
--     → Maid lifecycle (topMaid + equipMaid) guarantees zero leaks.
--       All state rebuilt on every equip cycle.
--
--   "ACS feels laggy / hits miss at high ping"
--     → workspace:GetServerTimeNow() timestamp sent with every fire event.
--       Server rewinds positions to that moment before validating.
--
--   "firing while reloading / double-activation bugs"
--     → StateMachine (cfg.stateMachine.enabled) guards every transition.
--
--   "GC spikes from tracer Part churn"
--     → EffectPool (cfg.effects.poolEnabled) recycles tracer Parts.
--       No create/destroy on each shot — pool grows, never drops a shot.
--
--   "reliable RemoteEvent congested by bullet visuals"
--     → WeaponKit_Effects (UnreliableRemoteEvent) for visual-only data when
--       cfg.effects.useUnreliableRemote = true.
--
--   "no way to react to hits client-side without editing WeaponKit"
--     → client.hooks.OnHit fires immediately on activation for local feedback
--       (screen shake, hit sound, UI flash). Separate from server-authoritative hooks.

local Players = game:GetService("Players")
local Debris  = game:GetService("Debris")

local Maid         = require(script.Parent.Maid)
local Config       = require(script.Parent.Config)
local Projectile   = require(script.Parent.Projectile)
local StateMachine = require(script.Parent.StateMachine)
local EffectPool   = require(script.Parent.EffectPool)
local Hooks        = require(script.Parent.Hooks)

-- ── Types ──────────────────────────────────────────────────────────────────

type TrackSet = {
	equip : AnimationTrack?,
	idle  : AnimationTrack?,
	swing : AnimationTrack?,
}

-- ── Module ─────────────────────────────────────────────────────────────────

local Client   = {}
Client.__index = Client

-- ── Constructor ────────────────────────────────────────────────────────────

function Client.new(tool: Tool, userConfig: { [string]: any }?)
	local cfg = Config.merge(Config.Defaults, userConfig or {})
	Config.validate(cfg)

	tool.RequiresHandle = cfg.requiresHandle :: boolean

	-- Cached OverlapParams — rebuilt each equip (character changes on respawn),
	-- not each swing. Avoids pointless table allocation 10+ times/second.
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.MaxParts   = 60

	-- Optional EffectPool for high fire-rate hitscan weapons.
	local effectCfg = cfg.effects :: { [string]: any }?
	local pool: any = nil
	if effectCfg and effectCfg.poolEnabled and cfg.weaponType == "hitscan" then
		local hitscanCfg = cfg.hitscan :: { [string]: any }?
		pool = EffectPool.new(
			(effectCfg.poolSize :: number?) or 20,
			hitscanCfg or {}
		)
	end

	return setmetatable({
		_tool           = tool,
		_config         = cfg,
		_topMaid        = Maid.new(),
		_equipMaid      = Maid.new(),
		_tracks         = {} :: TrackSet,
		_onCooldown     = false :: boolean,
		_cooldownThread = nil :: thread?,
		_hitCache       = {} :: { [Model]: boolean },
		_remote         = nil :: RemoteEvent?,
		_effectRemote   = nil :: UnreliableRemoteEvent?,
		_overlapParams  = overlapParams,
		_stateMachine   = nil :: any?,
		_effectPool     = pool,
		-- Public: attach client-side hit listeners here (e.g. screen shake).
		hooks           = Hooks.new(),
	}, Client)
end

-- ── Public ─────────────────────────────────────────────────────────────────

function Client:Start()
	local tool   = self._tool
	local player = Players.LocalPlayer

	-- Reliable remote — damage events.
	local remote = tool:WaitForChild("WeaponKit_Fire", 15) :: RemoteEvent?
	if not remote then
		warn("[WeaponKit] WeaponKit_Fire not found in '" .. tool.Name .. "' after 15 s. "
			.. "Is WeaponKit.Server running inside this tool?")
		return
	end
	self._remote = remote

	-- Unreliable remote — visual-only events from server (impacts, shell casings, etc.)
	-- Non-fatal: only present when cfg.effects.useUnreliableRemote = true on server.
	local ure = tool:FindFirstChild("WeaponKit_Effects")
	if ure and ure:IsA("UnreliableRemoteEvent") then
		self._effectRemote = ure :: UnreliableRemoteEvent
		self._topMaid:Give((ure :: UnreliableRemoteEvent).OnClientEvent:Connect(function(...)
			self:_onEffectEvent(...)
		end))
	end

	self._topMaid:Give(tool.Equipped:Connect(function()
		self:_onEquip(player)
	end))

	self._topMaid:Give(tool.Unequipped:Connect(function()
		self:_onUnequip()
	end))
end

function Client:Destroy()
	self:_onUnequip()
	self._topMaid:Destroy()
	if self._effectPool then
		(self._effectPool :: any):Destroy()
		self._effectPool = nil
	end
	self.hooks:DisconnectAll()
end

-- ── Private: equip / unequip ───────────────────────────────────────────────

function Client:_onEquip(player: Player)
	self._equipMaid:Destroy()
	self._equipMaid  = Maid.new()
	self._onCooldown = false
	self._hitCache   = {}

	-- Use a BindableEvent tracked by the equipMaid so this wait is automatically
	-- cancelled if the weapon is unequipped before the character loads.
	-- Without this, the coroutine blocks indefinitely and resumes into a stale
	-- equip cycle after _equipMaid has already been replaced.
	local char = player.Character
	if not char then
		local charSignal = Instance.new("BindableEvent")
		self._equipMaid:Give(charSignal)
		local charConn = player.CharacterAdded:Connect(function(c: Model)
			charSignal:Fire(c)
		end)
		self._equipMaid:Give(charConn)
		local ok, result = pcall(function()
			return charSignal.Event:Wait()
		end)
		-- If _equipMaid was destroyed (unequip fired first), the BindableEvent
		-- is gone and :Wait() errors — pcall catches it and we bail cleanly.
		if not ok or not result then return end
		char = result :: Model
	end

	local humanoid = char:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		warn("[WeaponKit] Humanoid not found within 10 s — aborting equip for '" .. self._tool.Name .. "'")
		return
	end

	local animator = humanoid:FindFirstChildOfClass("Animator") :: Animator?
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	-- Rebuild OverlapParams exclude list (character Instance changes on respawn).
	self._overlapParams.FilterDescendantsInstances = { char }

	self._tracks = self:_loadTracks(animator :: Animator)

	-- ── State machine ────────────────────────────────────────────────────
	local smCfg = self._config.stateMachine :: { [string]: any }?
	if smCfg and smCfg.enabled then
		local sm = StateMachine.new(self._equipMaid)
		self._stateMachine = sm
		sm:transition("Equipping")

		-- Transition to Idle when equip animation finishes.
		if self._tracks.equip then
			self._tracks.equip:Play()
			-- Wait is fine here — we're in a task.spawn context from Equipped.
			self._tracks.equip.Stopped:Wait()
			sm:transition("Idle")
		else
			sm:transition("Idle")
		end
	else
		if self._tracks.equip then
			self._tracks.equip:Play()
			self._tracks.equip.Stopped:Wait()
		end
	end

	if self._tracks.idle then
		self._tracks.idle:Play()
	end

	self._equipMaid:Give(self._tool.Activated:Connect(function()
		self:_onActivate()
	end))

	self._equipMaid:Give((humanoid :: Humanoid).Died:Connect(function()
		self:_onUnequip()
	end))

	self:_playSound(self._config.sounds.equip :: number)
end

function Client:_onUnequip()
	if self._cooldownThread then
		pcall(task.cancel, self._cooldownThread)
		self._cooldownThread = nil
	end
	self._onCooldown = false
	self._hitCache   = {}

	-- Transition SM back to Idle cleanly before Destroy tears it down.
	if self._stateMachine then
		;(self._stateMachine :: any):transition("Idle")
		self._stateMachine = nil
	end

	for _, track in self._tracks :: { [string]: AnimationTrack? } do
		if track then
			pcall(function() track:Stop(0) end)
		end
	end
	self._tracks = {}

	self._equipMaid:Destroy()
	self._equipMaid = Maid.new()
end

-- ── Private: activation ────────────────────────────────────────────────────

function Client:_onActivate()
	-- Cooldown gate.
	if self._onCooldown then return end

	-- State machine gate.
	if self._stateMachine and not (self._stateMachine :: any):canFire() then
		return
	end

	self._onCooldown = true
	if self._stateMachine then
		;(self._stateMachine :: any):transition("Firing")
	end

	self._cooldownThread = task.delay(self._config.cooldown :: number, function()
		self._onCooldown     = false
		self._cooldownThread = nil
		if self._stateMachine then
			;(self._stateMachine :: any):transition("Idle")
		end
	end)

	self._hitCache = {}

	if self._tracks.idle then self._tracks.idle:Stop() end
	if self._tracks.swing then
		local swingTrack = self._tracks.swing :: AnimationTrack
		swingTrack:Play()
		self._equipMaid:Give(swingTrack.Stopped:Once(function()
			if self._tracks.idle and self._tool.Parent ~= nil then
				self._tracks.idle:Play()
			end
		end))
	end

	self:_playSound(self._config.sounds.swing :: number)

	local weaponType = self._config.weaponType :: string
	if weaponType == "hitscan" then
		self:_fireHitscan()
	else
		self:_fireMelee()
	end
end

-- ── Private: melee fire ────────────────────────────────────────────────────

function Client:_fireMelee()
	local hits = self:_detectHits()

	if #hits > 0 then
		self:_playSound(self._config.sounds.hit :: number)
		-- Fire local hook for immediate feedback (screen shake, UI, etc.)
		self.hooks.OnHit:Fire(
			Players.LocalPlayer,
			nil :: any,  -- victim unknown client-side; server is authoritative
			self._config.damage :: number,
			{} :: any
		)
	end

	if self._remote then
		self._remote:FireServer(hits, workspace:GetServerTimeNow())
	end
end

-- ── Private: hitscan fire ─────────────────────────────────────────────────

function Client:_fireHitscan()
	local player = Players.LocalPlayer
	local char   = player.Character
	if not char then return end

	local camera    = workspace.CurrentCamera
	local origin    = camera.CFrame.Position
	local direction = camera.CFrame.LookVector

	local hitscanCfg = self._config.hitscan :: { [string]: any }
	local maxRange   = (hitscanCfg.maxRange :: number?) or 300

	local result, timestamp = Projectile.Hitscan.Fire(origin, direction, maxRange, { char })

	-- Tracer visual.
	if hitscanCfg.tracerEnabled then
		local endPt = result and result.Position or (origin + direction.Unit * maxRange)
		Projectile.SpawnTracer(origin, direction, endPt, hitscanCfg, self._effectPool)
	end

	-- Local hit feedback.
	if result then
		local hitModel = result.Instance:FindFirstAncestorOfClass("Model")
		if hitModel and hitModel:FindFirstChildOfClass("Humanoid") then
			self:_playSound(self._config.sounds.hit :: number)
			self.hooks.OnHit:Fire(player, hitModel :: any, self._config.damage :: number, {} :: any)
		end
	end

	-- Send to server (reliable RemoteEvent for the authoritative fire event).
	if self._remote then
		self._remote:FireServer({
			origin    = origin,
			direction = direction,
			distance  = result and (origin - result.Position).Magnitude or maxRange,
			timestamp = timestamp,
		})
	end
end

-- ── Private: unreliable effect events from server ──────────────────────────

function Client:_onEffectEvent(_kind: string, ...: any)
	-- Default handler is a no-op. Override or listen to client.hooks to drive
	-- particle emitters, impact decals, shell ejection, muzzle flash, etc.
	-- kind = "impact", args = (origin: Vector3, direction: Vector3, dist: number)
end

-- ── Private: melee hit detection ──────────────────────────────────────────

type HitData = { charName: string, rootPos: Vector3 }

function Client:_detectHits(): { HitData }
	local player = Players.LocalPlayer
	local char   = player.Character
	if not char then return {} end

	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then return {} end

	local cfg   = self._config
	local range = cfg.range :: number
	local boxCF = root.CFrame * CFrame.new(0, 0, -(range / 2))

	local parts   = workspace:GetPartBoundsInBox(boxCF, cfg.hitboxSize :: Vector3, self._overlapParams)
	local results : { HitData } = {}
	local seen    : { [Model]: boolean } = {}

	for _, part in parts do
		local model = part:FindFirstAncestorOfClass("Model")
		if not model or seen[model] then continue end

		local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid?
		if not humanoid or humanoid.Health <= 0 then continue end

		if self._hitCache[model] then continue end
		self._hitCache[model] = true
		seen[model]           = true

		local modelRoot = model:FindFirstChild("HumanoidRootPart") :: BasePart?
		local pos = modelRoot and modelRoot.Position or part.Position
		table.insert(results, { charName = model.Name, rootPos = pos })
	end

	return results
end

-- ── Private: animation loading ─────────────────────────────────────────────

function Client:_loadTracks(animator: Animator): TrackSet
	local animCfg  = self._config.animations :: { [string]: string }
	local priority = self._config.animationPriority :: Enum.AnimationPriority
	local tracks   = {} :: TrackSet

	local function load(id: string): AnimationTrack?
		if id == "" or id == "0" then return nil end
		local anim    = Instance.new("Animation")
		anim.AnimationId = id
		local ok, result = pcall(function() return animator:LoadAnimation(anim) end)
		anim:Destroy()
		if not ok then
			warn("[WeaponKit] Failed to load animation '" .. id .. "':", tostring(result))
			return nil
		end
		local track = result :: AnimationTrack
		track.Priority = priority
		return track
	end

	tracks.equip = load(animCfg.equip or "")
	tracks.idle  = load(animCfg.idle  or "")
	tracks.swing = load(animCfg.swing or "")

	if tracks.idle  then (tracks.idle  :: AnimationTrack).Looped = true  end
	if tracks.equip then (tracks.equip :: AnimationTrack).Looped = false end
	if tracks.swing then (tracks.swing :: AnimationTrack).Looped = false end

	for _, track in tracks :: { [string]: AnimationTrack? } do
		if track then
			local t = track :: AnimationTrack
			self._equipMaid:Give(function()
				pcall(function() t:Stop(0); t:Destroy() end)
			end)
		end
	end

	return tracks
end

-- ── Private: sound ─────────────────────────────────────────────────────────

function Client:_playSound(soundId: number)
	if not soundId or soundId == 0 then return end
	local sound   = Instance.new("Sound")
	sound.SoundId = "rbxassetid://" .. tostring(soundId)
	sound.Parent  = self._tool
	sound:Play()
	Debris:AddItem(sound, 5)
end

return Client
