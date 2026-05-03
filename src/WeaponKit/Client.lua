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

local Players = game:GetService("Players")
local Debris  = game:GetService("Debris")

local Maid   = require(script.Parent.Maid)
local Config = require(script.Parent.Config)

-- ── Types ──────────────────────────────────────────────────────────────────

type TrackSet = {
	equip: AnimationTrack?,
	idle:  AnimationTrack?,
	swing: AnimationTrack?,
}

-- ── Module ─────────────────────────────────────────────────────────────────

local Client = {}
Client.__index = Client

-- ── Constructor ────────────────────────────────────────────────────────────

function Client.new(tool: Tool, userConfig: { [string]: any }?)
	local cfg = Config.merge(Config.Defaults, userConfig or {})
	Config.validate(cfg)

	-- Apply RequiresHandle immediately so the tool is correct before equip.
	-- Solves: "Activated never fires" when Handle isn't touching the ground.
	tool.RequiresHandle = cfg.requiresHandle :: boolean

	return setmetatable({
		_tool           = tool,
		_config         = cfg,
		_topMaid        = Maid.new(), -- Lives for the life of :Start()
		_equipMaid      = Maid.new(), -- Rebuilt every equip cycle
		_tracks         = {} :: TrackSet,
		_onCooldown     = false :: boolean,
		_cooldownThread = nil :: thread?,
		_hitCache       = {} :: { [Model]: boolean },
		_remote         = nil :: RemoteEvent?,
	}, Client)
end

-- ── Public ─────────────────────────────────────────────────────────────────

--- Call once after requiring WeaponKit. Sets up Equipped / Unequipped listeners.
function Client:Start()
	local tool   = self._tool
	local player = Players.LocalPlayer

	-- Locate the RemoteEvent that Server.lua creates synchronously.
	-- WaitForChild with a timeout gives a clear error instead of an infinite hang.
	-- Solves: timing issues where the client looks for the event before it exists.
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

--- Clean up everything. Call if you need to fully tear down the weapon.
function Client:Destroy()
	self:_onUnequip()
	self._topMaid:Destroy()
end

-- ── Private: equip / unequip ───────────────────────────────────────────────

function Client:_onEquip(player: Player)
	-- Rebuild per-equip state so nothing from the previous equip leaks in.
	self._equipMaid:Destroy()
	self._equipMaid = Maid.new()
	self._onCooldown = false
	self._hitCache   = {}

	-- Wait for character — handles first spawn AND every respawn.
	-- Solves: "attempt to index nil with 'Character'"
	local char = player.Character or player.CharacterAdded:Wait()

	-- WaitForChild with timeout gives a clear error message rather than hanging.
	-- Solves: "attempt to index nil with 'Humanoid'"
	local humanoid = char:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		warn("[WeaponKit] Humanoid not found in character within 10 s — aborting equip for '" .. self._tool.Name .. "'")
		return
	end

	-- Get or create the Animator. Roblox sometimes omits it on older rigs.
	-- Solves: "LoadAnimation requires Humanoid to be a descendant" error.
	local animator = humanoid:FindFirstChildOfClass("Animator") :: Animator?
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	self._tracks = self:_loadTracks(animator :: Animator)

	-- Play equip animation first (if configured), then start idle loop.
	if self._tracks.equip then
		self._tracks.equip:Play()
		self._tracks.equip.Stopped:Wait()
	end
	if self._tracks.idle then
		self._tracks.idle:Play()
	end

	-- Bind activation only after character is confirmed — no nil-ref risk.
	self._equipMaid:Give(self._tool.Activated:Connect(function()
		self:_onActivate()
	end))

	-- If the character dies while the weapon is equipped, clean up immediately.
	self._equipMaid:Give((humanoid :: Humanoid).Died:Connect(function()
		self:_onUnequip()
	end))

	-- Equip sound
	self:_playSound(self._config.sounds.equip :: number)
end

function Client:_onUnequip()
	-- Cancel any pending cooldown thread so it doesn't fire into the next equip.
	-- Solves: "weapon stuck in cooldown after re-equipping quickly"
	if self._cooldownThread then
		pcall(task.cancel, self._cooldownThread)
		self._cooldownThread = nil
	end
	self._onCooldown = false
	self._hitCache   = {}

	-- Stop every animation track that is still running.
	-- Solves: "idle / swing animation stuck playing after unequip"
	for _, track in self._tracks :: { [string]: AnimationTrack? } do
		if track then
			pcall(function()
				track:Stop(0) -- 0 = instant stop, no fade-out blending artefacts
			end)
		end
	end
	self._tracks = {}

	-- Destroy the per-equip Maid — disconnects every connection from this cycle.
	-- Solves: memory leak / lag accumulation over repeated equip sessions.
	self._equipMaid:Destroy()
	self._equipMaid = Maid.new()
end

-- ── Private: activation ────────────────────────────────────────────────────

function Client:_onActivate()
	if self._onCooldown then return end
	self._onCooldown = true

	-- Schedule cooldown reset with task.delay so it fires even if an error
	-- occurs below. This is the ONLY place _onCooldown is set back to false
	-- during normal play.
	-- Solves: "weapon permanently stuck, can't shoot after any error mid-swing"
	self._cooldownThread = task.delay(self._config.cooldown :: number, function()
		self._onCooldown  = false
		self._cooldownThread = nil
	end)

	-- Clear per-swing hit cache.
	-- Solves: same target being hit multiple times in one activation.
	self._hitCache = {}

	-- Transition idle → swing animation.
	if self._tracks.idle then
		self._tracks.idle:Stop()
	end
	if self._tracks.swing then
		local swingTrack = self._tracks.swing :: AnimationTrack
		swingTrack:Play()

		-- Resume idle once swing animation finishes.
		-- Using Once so the connection auto-disconnects and doesn't accumulate.
		self._equipMaid:Give(swingTrack.Stopped:Once(function()
			if self._tracks.idle and self._tool.Parent ~= nil then
				self._tracks.idle:Play()
			end
		end))
	end

	-- Play swing sound
	self:_playSound(self._config.sounds.swing :: number)

	-- Detect hits in the spatial hitbox
	local hits = self:_detectHits()

	if #hits > 0 then
		self:_playSound(self._config.sounds.hit :: number)
	end

	-- Fire to server with the list of hit character names + positions.
	-- Server validates independently — client data is not trusted for damage.
	if self._remote then
		self._remote:FireServer(hits)
	end
end

-- ── Private: hit detection ─────────────────────────────────────────────────

type HitData = { charName: string, rootPos: Vector3 }

--- Returns all valid targets inside the forward hitbox this swing.
--- Uses GetPartBoundsInBox — no .Touched, no spam, no multi-hit.
function Client:_detectHits(): { HitData }
	local player = Players.LocalPlayer
	local char   = player.Character
	if not char then return {} end

	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then return {} end

	local cfg    = self._config
	local range  = cfg.range :: number
	local boxCF  = root.CFrame * CFrame.new(0, 0, -(range / 2))

	local params = OverlapParams.new()
	params.FilterDescendantsInstances = { char }
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.MaxParts   = 60

	local parts   = workspace:GetPartBoundsInBox(boxCF, cfg.hitboxSize :: Vector3, params)
	local results: { HitData } = {}
	local seen: { [Model]: boolean } = {}

	for _, part in parts do
		local model = part:FindFirstAncestorOfClass("Model")
		if not model or seen[model] then continue end

		-- Must have a living Humanoid (works on R6, R15, and NPCs).
		local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid?
		if not humanoid or humanoid.Health <= 0 then continue end

		-- Per-swing debounce: hit each model at most once per activation.
		-- Solves: the classic "Touched fires 10-30x per swing" problem.
		if self._hitCache[model] then continue end
		self._hitCache[model] = true
		seen[model] = true

		-- Send root position for server distance validation.
		local modelRoot = model:FindFirstChild("HumanoidRootPart") :: BasePart?
		local pos = modelRoot and modelRoot.Position or part.Position

		table.insert(results, {
			charName = model.Name,
			rootPos  = pos,
		})
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

	-- Register all tracks in the equip Maid so they stop + get destroyed on unequip.
	-- Solves: AnimationTracks accumulating and playing invisibly after unequip.
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
	local sound    = Instance.new("Sound")
	sound.SoundId  = "rbxassetid://" .. tostring(soundId)
	sound.Parent   = self._tool
	sound:Play()
	Debris:AddItem(sound, 5)
end

return Client
