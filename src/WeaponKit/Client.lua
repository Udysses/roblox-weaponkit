--!strict
-- Client.lua  (runs inside a LocalScript in your Tool)
--
-- What this module handles so you don't have to:
--
--   "attempt to index nil with 'Humanoid'"
--     → Waits for Character, Humanoid, and Animator before connecting anything.
--       Handles both first spawn and every subsequent respawn.
--
--   "animation stuck playing after unequip"
--     → Maid stops and destroys ALL AnimationTracks on every unequip/death.
--
--   "weapon fires but does 10x damage / hits the same person repeatedly"
--     → GetPartBoundsInBox replaces .Touched entirely.
--       Per-swing hit cache ensures each target is hit at most once per swing.
--
--   "weapon won't fire / Activated never runs"
--     → RequiresHandle is set from config (defaults false) so Activated
--       fires regardless of whether the Handle is touching the ground.
--       RemoteEvent is located with WaitForChild so timing is never an issue.
--
--   "stuck in animation, can't shoot"
--     → Cooldown is reset with task.delay so it ALWAYS clears even if an
--       error occurs mid-swing. task.cancel is called on unequip so a stale
--       cooldown from a previous equip never bleeds into the next one.
--
--   "lag accumulates the longer a session runs"
--     → Maid rebuilds every equip cycle. Zero connections outlive their use.
--
--   "guns feel laggy / high-ping players miss"
--     → Client sends workspace:GetServerTimeNow() with every fire event.
--       Server rewinds positions to that timestamp before validating.
--       For hitscan (cfg.weaponType = "hitscan"), the client does a local
--       raycast immediately for visual feedback, then sends {origin, direction}
--       for the server to re-validate with lag compensation.

local Players = game:GetService("Players")
local Debris  = game:GetService("Debris")

local Maid       = require(script.Parent.Maid)
local Config     = require(script.Parent.Config)
local Projectile = require(script.Parent.Projectile)

-- ── Types ──────────────────────────────────────────────────────────────────

type TrackSet = {
	equip: AnimationTrack?,
	idle:  AnimationTrack?,
	swing: AnimationTrack?,
}

-- ── Module ─────────────────────────────────────────────────────────────────

local Client   = {}
Client.__index = Client

-- ── Constructor ────────────────────────────────────────────────────────────

function Client.new(tool: Tool, userConfig: { [string]: any }?)
	local cfg = Config.merge(Config.Defaults, userConfig or {})
	Config.validate(cfg)

	tool.RequiresHandle = cfg.requiresHandle :: boolean

	-- Cache OverlapParams for melee: creating it fresh each swing is wasteful
	-- when the exclude list changes every equip (not every swing).
	-- We rebuild it in _onEquip when the character reference changes.
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.MaxParts   = 60

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
		_overlapParams  = overlapParams,
	}, Client)
end

-- ── Public ─────────────────────────────────────────────────────────────────

function Client:Start()
	local tool   = self._tool
	local player = Players.LocalPlayer

	local remote = tool:WaitForChild("WeaponKit_Fire", 15) :: RemoteEvent?
	if not remote then
		warn(
			"[WeaponKit] WeaponKit_Fire not found in '"
				.. tool.Name
				.. "' after 15 s. Is WeaponKit.Server running inside this tool?"
		)
		return
	end
	self._remote = remote

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
end

-- ── Private: equip / unequip ───────────────────────────────────────────────

function Client:_onEquip(player: Player)
	self._equipMaid:Destroy()
	self._equipMaid  = Maid.new()
	self._onCooldown = false
	self._hitCache   = {}

	local char = player.Character or player.CharacterAdded:Wait()

	local humanoid = char:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		warn("[WeaponKit] Humanoid not found in character within 10 s — aborting equip for '" .. self._tool.Name .. "'")
		return
	end

	local animator = humanoid:FindFirstChildOfClass("Animator") :: Animator?
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	-- Rebuild the cached OverlapParams exclude list with the current character.
	-- Needed because the character Instance changes on each respawn.
	self._overlapParams.FilterDescendantsInstances = { char }

	self._tracks = self:_loadTracks(animator :: Animator)

	if self._tracks.equip then
		self._tracks.equip:Play()
		self._tracks.equip.Stopped:Wait()
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

	for _, track in self._tracks :: { [string]: AnimationTrack? } do
		if track then
			pcall(function()
				track:Stop(0)
			end)
		end
	end
	self._tracks = {}

	self._equipMaid:Destroy()
	self._equipMaid = Maid.new()
end

-- ── Private: activation ────────────────────────────────────────────────────

function Client:_onActivate()
	if self._onCooldown then return end
	self._onCooldown = true

	self._cooldownThread = task.delay(self._config.cooldown :: number, function()
		self._onCooldown     = false
		self._cooldownThread = nil
	end)

	self._hitCache = {}

	if self._tracks.idle then
		self._tracks.idle:Stop()
	end
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
	end

	if self._remote then
		-- Attach the client's server-synced timestamp so the server can rewind
		-- positions for lag compensation.
		local timestamp = workspace:GetServerTimeNow()
		self._remote:FireServer(hits, timestamp)
	end
end

-- ── Private: hitscan fire ──────────────────────────────────────────────────

function Client:_fireHitscan()
	local player = Players.LocalPlayer
	local char   = player.Character
	if not char then return end

	-- Get the camera for aiming direction.
	local camera    = workspace.CurrentCamera
	local origin    = camera.CFrame.Position
	local direction = camera.CFrame.LookVector

	local hitscanCfg = self._config.hitscan :: { [string]: any }
	local maxRange   = (hitscanCfg and hitscanCfg.maxRange :: number?) or 300

	-- Client-side raycast for immediate visual feedback.
	local result, timestamp = Projectile.Hitscan.Fire(origin, direction, maxRange, { char })

	-- Spawn a tracer regardless of whether we hit something.
	if hitscanCfg and hitscanCfg.tracerEnabled then
		local endPoint = result and result.Position or (origin + direction.Unit * maxRange)
		Projectile.SpawnTracer(origin, direction, endPoint, hitscanCfg)
	end

	-- Play hit sound if we landed on something with a Humanoid.
	if result then
		local hitModel = result.Instance:FindFirstAncestorOfClass("Model")
		if hitModel and hitModel:FindFirstChildOfClass("Humanoid") then
			self:_playSound(self._config.sounds.hit :: number)
		end
	end

	-- Send shot data to the server for authoritative validation.
	if self._remote then
		self._remote:FireServer({
			origin    = origin,
			direction = direction,
			distance  = result and (origin - result.Position).Magnitude or maxRange,
			timestamp = timestamp,
		})
	end
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

	-- _overlapParams exclude list is updated in _onEquip, not here, so we
	-- pay the allocation cost once per equip cycle instead of once per swing.
	local parts   = workspace:GetPartBoundsInBox(boxCF, cfg.hitboxSize :: Vector3, self._overlapParams)
	local results: { HitData } = {}
	local seen: { [Model]: boolean } = {}

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
		local ok, result = pcall(function()
			return animator:LoadAnimation(anim)
		end)
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
				pcall(function()
					t:Stop(0)
					t:Destroy()
				end)
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
