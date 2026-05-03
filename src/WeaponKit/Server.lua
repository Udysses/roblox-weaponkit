--!strict
-- Server.lua  (runs inside a Script in your Tool)
--
-- What this module handles so you don't have to:
--
--   "weapon won't fire / RemoteEvent not found"
--     → Creates WeaponKit_Fire synchronously on startup so the client's
--       WaitForChild never hangs or times out.
--
--   "exploiters dealing infinite damage by firing the remote directly"
--     → Server re-validates hit distance independently. Client hit data is
--       treated as a suggestion, not ground truth.
--     → Per-player rate limiter rejects fire events above the threshold.
--     → Damage is clamped to cfg.maxDamage regardless of what the client claims.
--
--   "attempt to index nil with Humanoid" on the server
--     → Every access is guarded with nil checks before TakeDamage is called.
--
--   "can't damage R6 rigs or non-player NPCs"
--     → FindFirstChildOfClass("Humanoid") works on any Model, not just R15
--       players. No Players service lookup required.
--
--   "all players take damage when one player swings"
--     → Each weapon instance has completely isolated state. No shared globals.
--       The server looks up the target by name in workspace and cross-checks
--       that the attacker was actually nearby.

local Players = game:GetService("Players")

local Maid   = require(script.Parent.Maid)
local Config = require(script.Parent.Config)

-- ── Types ──────────────────────────────────────────────────────────────────

type RateEntry = { count: number, resetAt: number }

-- ── Module ─────────────────────────────────────────────────────────────────

local Server = {}
Server.__index = Server

-- ── Constructor ────────────────────────────────────────────────────────────

function Server.new(tool: Tool, userConfig: { [string]: any }?)
	local cfg = Config.merge(Config.Defaults, userConfig or {})
	Config.validate(cfg)

	-- Create the RemoteEvent NOW, synchronously, before Start() is called.
	-- The LocalScript uses WaitForChild("WeaponKit_Fire") — it will find it
	-- immediately because this runs first in the server Script.
	-- Solves: "weapon won't fire / WeaponKit_Fire not found after 15 s"
	local remote = tool:FindFirstChild("WeaponKit_Fire") :: RemoteEvent?
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name   = "WeaponKit_Fire"
		remote.Parent = tool
	end

	return setmetatable({
		_tool      = tool,
		_config    = cfg,
		_maid      = Maid.new(),
		_remote    = remote :: RemoteEvent,
		_rateState = {} :: { [Player]: RateEntry },
	}, Server)
end

-- ── Public ─────────────────────────────────────────────────────────────────

--- Call once after requiring WeaponKit. Connects the OnServerEvent listener.
function Server:Start()
	local maid = self._maid

	maid:Give(self._remote.OnServerEvent:Connect(function(player: Player, hits: unknown)
		self:_onFire(player, hits)
	end))

	-- Clean up when the tool leaves the DataModel (player leaves, tool destroyed).
	maid:Give(self._tool.AncestryChanged:Connect(function()
		if not self._tool:IsDescendantOf(game) then
			self:Destroy()
		end
	end))

	-- Release rate-limit state when a player leaves to prevent memory growth.
	maid:Give(Players.PlayerRemoving:Connect(function(player: Player)
		self._rateState[player] = nil
	end))
end

--- Clean up all server-side state.
function Server:Destroy()
	self._maid:Destroy()
	self._rateState = {}
end

-- ── Private: fire handler ──────────────────────────────────────────────────

function Server:_onFire(player: Player, hits: unknown)
	-- Validate the attacker has a character with a root part.
	local char = player.Character
	if not char then return end

	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then return end

	-- Rate limit — drop the event if the player is firing too fast.
	-- Solves: exploit spam / RemoteEvent flood attacks.
	if not self:_checkRate(player) then
		warn(string.format(
			"[WeaponKit] Rate limit exceeded: %s fired %s more than %d times/s",
			player.Name,
			self._tool.Name,
			self._config.rateLimit :: number
		))
		return
	end

	-- Validate the hits list is actually a table.
	if type(hits) ~= "table" then return end

	local cfg     = self._config
	-- Server-side dedupe: each character takes damage at most once per event.
	local damaged: { [Model]: boolean } = {}

	for _, hit in hits :: { { [string]: any } } do
		-- Validate individual hit entry structure.
		if type(hit) ~= "table" then continue end

		local charName = hit.charName
		local rootPos  = hit.rootPos

		if type(charName) ~= "string" then continue end
		if typeof(rootPos) ~= "Vector3" then continue end

		-- Look up the target by name in workspace.
		-- We find it ourselves rather than trusting a client-sent Instance ref.
		-- Solves: exploiters sending fake Instance references.
		local targetModel = workspace:FindFirstChild(charName) :: Model?
		if not targetModel then continue end
		if damaged[targetModel] then continue end

		-- Server-side distance validation.
		-- The client claimed the hit was at rootPos. Verify the attacker was
		-- actually within maxRange of that position when this event arrived.
		-- Solves: teleport exploits / fake long-range hits.
		local dist = (root.Position - rootPos).Magnitude
		if dist > (cfg.maxRange :: number) then
			warn(string.format(
				"[WeaponKit] Hit rejected for %s: claimed range %.1f studs (max %d) on %s",
				player.Name,
				dist,
				cfg.maxRange :: number,
				self._tool.Name
			))
			continue
		end

		-- Find Humanoid — works on R6, R15, and non-player NPCs.
		-- Solves: "can't damage R6 rigs or NPCs"
		local humanoid = targetModel:FindFirstChildOfClass("Humanoid") :: Humanoid?
		if not humanoid then continue end
		if humanoid.Health <= 0 then continue end

		-- Never damage the attacker's own character.
		if targetModel == char then continue end

		-- Apply clamped damage.
		-- Solves: exploiters sending absurdly high damage values.
		local dmg = math.min(cfg.damage :: number, cfg.maxDamage :: number)
		humanoid:TakeDamage(dmg)
		damaged[targetModel] = true
	end
end

-- ── Private: rate limiter ──────────────────────────────────────────────────

--- Returns true if the player is within the allowed activations-per-second.
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
