--!strict
-- ACSBridge.lua
-- Integrates WeaponKit's security pipeline with ACS (Advanced Combat System).
--
-- ACS (by @00scorpion00 / @dusek_br) is a popular Roblox FPS framework that
-- handles viewmodel animations, bullet replication, recoil, and spread.
-- Because ACS ships as a Roblox model rather than a versioned package, its
-- internal API varies between releases. This bridge tries all known patterns.
--
-- What the bridge does:
--   1. Auto-detects ACS in ReplicatedStorage under common folder names.
--   2. Finds ACS's damage RemoteEvent(s) and intercepts OnServerEvent.
--   3. Parses the hit payload (ACS uses several formats across versions).
--   4. Re-validates every hit through WeaponKit's checks:
--        range, alive, self-damage, rate-limit (via the Server instance).
--   5. Fires a clean OnHit callback so your game's damage logic is in one place.
--
-- Usage (server Script):
--
--   local WeaponKit = require(ReplicatedStorage.WeaponKit)
--   local server    = WeaponKit.Server.new(tool, cfg)
--   server:Start()
--
--   -- Optional: hook ACS damage events through WeaponKit validation.
--   if WeaponKit.ACSBridge:IsPresent() then
--       WeaponKit.ACSBridge:HookRemotes(server, function(shooter, victim, damage, weapon)
--           victim:FindFirstChildOfClass("Humanoid"):TakeDamage(damage)
--       end)
--   end

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Common folder/module names ACS is distributed under.
local ACS_PATHS: { string } = {
	"ACS", "ACSEngine", "ACS_Engine", "AdvancedCombatSystem",
	"ACS_V4", "ACS_V3", "ACS_V2",
}

-- Remote event names ACS uses for damage notifications (varies by version).
local ACS_DAMAGE_REMOTES: { string } = {
	"DamageEvent", "HitEvent",    "ACS_DamageEvent", "ACS_Hit",
	"WeaponDamage", "BulletHit",  "ACS_BulletDamage", "DealDamage",
	"ACS_Damage",  "ServerDamage",
}

-- ── Types ──────────────────────────────────────────────────────────────────

type OnHitCallback = (
	shooter    : Player,
	victim     : Model,
	damage     : number,
	weaponName : string,
	hitPos     : Vector3?
) -> ()

-- ── Module ─────────────────────────────────────────────────────────────────

local ACSBridge   = {}
ACSBridge.__index = ACSBridge

-- ── Detection ──────────────────────────────────────────────────────────────

local _cachedRoot: Instance? = nil

-- Search ReplicatedStorage for the ACS root folder/module.
function ACSBridge.FindEngine(): Instance?
	if _cachedRoot then return _cachedRoot end
	for _, name in ACS_PATHS do
		local found = ReplicatedStorage:FindFirstChild(name)
			or ReplicatedStorage:FindFirstChild(name, true)
		if found then
			_cachedRoot = found
			return found
		end
	end
	return nil
end

function ACSBridge.IsPresent(): boolean
	return ACSBridge.FindEngine() ~= nil
end

-- Returns a human-readable location string for diagnose().
function ACSBridge.Describe(): string
	local root = ACSBridge.FindEngine()
	if not root then return "not detected" end
	return root:GetFullName()
end

-- ── Hook remotes ───────────────────────────────────────────────────────────

-- Search the ACS tree for known damage RemoteEvent names and intercept them.
-- `server` is a WeaponKit.Server instance (used for rate-limit + config).
-- `onHit` is called with (shooter, victim, damage, weaponName, hitPos?) for
--   every hit that passes validation.
--
-- Returns the number of remotes hooked. 0 means ACS remotes weren't found
-- (check ACS_DAMAGE_REMOTES list or your ACS version).
function ACSBridge.HookRemotes(server: any, onHit: OnHitCallback): number
	local root = ACSBridge.FindEngine()
	if not root then return 0 end

	-- Build a deduplicated list of folders to search.
	-- Using `or root` as a fallback would push `root` multiple times when
	-- sub-folders don't exist, causing redundant searches and misleading logs.
	local searchRoots: { Instance } = { root }
	local searchRootSet: { [Instance]: boolean } = { [root] = true }
	for _, subName in { "Remotes", "Events", "Server" } do
		local sub = root:FindFirstChild(subName)
		if sub and not searchRootSet[sub] then
			table.insert(searchRoots, sub)
			searchRootSet[sub] = true
		end
	end

	local hooked = 0
	local seen: { [RemoteEvent]: boolean } = {}

	for _, searchRoot in searchRoots do
		for _, name in ACS_DAMAGE_REMOTES do
			local remote = searchRoot:FindFirstChild(name, true) :: RemoteEvent?
			if remote and remote:IsA("RemoteEvent") and not seen[remote] then
				seen[remote] = true
				remote.OnServerEvent:Connect(function(player: Player, ...)
					ACSBridge._onACSFire(player, server, onHit, remote.Name, ...)
				end)
				hooked += 1
			end
		end
	end

	if hooked > 0 then
		print(("[WeaponKit/ACSBridge] Hooked %d ACS damage remote(s) under %s"):format(
			hooked, root:GetFullName()
		))
	else
		warn("[WeaponKit/ACSBridge] No ACS damage remotes found. "
			.. "If your ACS version uses a different remote name, add it to ACS_DAMAGE_REMOTES.")
	end

	return hooked
end

-- ── Hit parsing ────────────────────────────────────────────────────────────

-- ACS hit data formats vary by version. Try all known patterns.
local function _parseHit(args: { any }): (string?, number, string, Vector3?)
	local victimName: string?
	local damage: number     = 25
	local weaponName: string = "ACS_Weapon"
	local hitPos: Vector3?

	local first = args[1]

	-- Format A (common v3/v4): (victimCharName: string, damage: number, weapon?: string, pos?: Vector3)
	if type(first) == "string" then
		victimName = first
		damage     = type(args[2]) == "number" and (args[2] :: number) or damage
		weaponName = type(args[3]) == "string" and (args[3] :: string) or weaponName
		hitPos     = typeof(args[4]) == "Vector3" and (args[4] :: Vector3) or nil

	-- Format B (some v4+): ({victim, damage, weapon, position} table)
	elseif type(first) == "table" then
		local t = first :: { [string]: any }

		if type(t.victim) == "string" then
			victimName = t.victim :: string
		elseif typeof(t.victim) == "Instance" then
			victimName = (t.victim :: Instance).Name
		elseif type(t.char) == "string" then
			victimName = t.char :: string
		end

		damage     = type(t.damage)   == "number" and (t.damage   :: number) or damage
		weaponName = type(t.weapon)   == "string" and (t.weapon   :: string) or weaponName
		hitPos     = typeof(t.position) == "Vector3" and (t.position :: Vector3) or nil

	-- Format C (v2 / older): (victimInstance: Model, damage: number)
	elseif typeof(first) == "Instance" then
		local inst = first :: Instance
		victimName = inst.Name
		damage     = type(args[2]) == "number" and (args[2] :: number) or damage
	end

	return victimName, damage, weaponName, hitPos
end

-- ── Core handler ───────────────────────────────────────────────────────────

function ACSBridge._onACSFire(
	player:      Player,
	server:      any,
	onHit:       OnHitCallback,
	remoteName:  string,
	...
)
	-- Rate-limit check using the WeaponKit server's shared rate bucket.
	-- ACS shots intentionally share the bucket with WeaponKit shots — a player
	-- firing both simultaneously should not bypass the combined rate ceiling.
	if server and not server:CheckRate(player) then
		warn(("[WeaponKit/ACSBridge] Rate limit hit for %s via %s"):format(
			player.Name, remoteName
		))
		return
	end

	local args = { ... }
	local victimName, damage, weaponName, hitPos = _parseHit(args)

	if not victimName then
		warn(("[WeaponKit/ACSBridge] Could not parse victim from %s"):format(remoteName))
		return
	end

	local victim = workspace:FindFirstChild(victimName) :: Model?
	if not victim then return end

	-- Validate through WeaponKit security checks.
	local valid, reason = ACSBridge._validate(player, victim, hitPos, server)
	if not valid then
		warn(("[WeaponKit/ACSBridge] Rejected %s → %s: %s"):format(
			player.Name, victimName, reason or "unknown"
		))
		return
	end

	-- Clamp damage from ACS WeaponData to WeaponKit's ceiling.
	local maxDmg: number = (server and server._config and server._config.maxDamage :: number?) or 200
	damage = math.min(damage, maxDmg)

	onHit(player, victim, damage, weaponName, hitPos)
end

-- ── Validation helper ──────────────────────────────────────────────────────

function ACSBridge._validate(
	shooter : Player,
	victim  : Model,
	hitPos  : Vector3?,
	server  : any
): (boolean, string?)
	local char = shooter.Character
	if not char then return false, "no character" end

	local attackerRoot = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local victimRoot   = victim:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not attackerRoot then return false, "no attacker root" end
	if not victimRoot   then return false, "no victim root"   end
	if char == victim   then return false, "self-damage"      end

	local maxRange: number = (server and server._config and server._config.maxRange :: number?) or 300
	local checkPos = hitPos or victimRoot.Position
	local dist = (attackerRoot.Position - checkPos).Magnitude
	if dist > maxRange then
		return false, ("range %.1f > max %.1f"):format(dist, maxRange)
	end

	local hum = victim:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return false, "target not alive" end

	return true, nil
end

return ACSBridge
