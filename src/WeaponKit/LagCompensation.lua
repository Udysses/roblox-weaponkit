--!strict
-- LagCompensation.lua
-- Server-side rolling position history for fair hit validation.
--
-- Root problem with ACS and any Roblox weapon system at high ping:
--   Player fires at T=0 from their client's view of the world.
--   The RemoteEvent arrives at the server at T = (ping/2).
--   The server validates against positions at T+(ping/2) — targets have moved.
--   Result: high-latency players miss hits they clearly landed on their screen.
--
-- Fix: record every character's part positions at 20 Hz. When a fire event
-- arrives with a client timestamp, rewind all hitboxes to that moment, run
-- the distance/raycast check, then immediately restore positions.
-- This is "favor-the-shooter" lag compensation — identical to how Source
-- engine and most modern shooters handle it.
--
-- Usage (server Script, runs once for the whole server):
--
--   local LC = require(ReplicatedStorage.WeaponKit.LagCompensation)
--   local lagComp = LC.getShared()   -- singleton; sets up PlayerAdded/CharacterAdded
--
-- Server.lua calls LC.getShared() automatically when cfg.lagCompensation.enabled.

local RunService = game:GetService("RunService")
local Players    = game:GetService("Players")

-- ── Constants ──────────────────────────────────────────────────────────────

local HISTORY_SECONDS  = 1.0    -- How many seconds of history to keep
local SAMPLE_HZ        = 20     -- Snapshots per second
local SAMPLE_INTERVAL  = 1 / SAMPLE_HZ
local MAX_REWIND_S     = 0.5    -- Security cap: never rewind more than 500 ms

-- ── Types ──────────────────────────────────────────────────────────────────

type Snapshot = {
	t      : number,
	frames : { [BasePart]: CFrame },
}

type LagCompensationImpl = {
	_history    : { [Model]: { Snapshot } },
	_registered : { [Model]: boolean },
	_stepConn   : RBXScriptConnection?,
	_lastSample : number,
}

-- ── Module ─────────────────────────────────────────────────────────────────

local LagCompensation   = {}
LagCompensation.__index = LagCompensation

-- Module-level shared singleton so multiple weapons reuse one sampler.
local _shared: any = nil

-- ── Constructor ────────────────────────────────────────────────────────────

function LagCompensation.new(): any
	return setmetatable({
		_history    = {} :: { [Model]: { Snapshot } },
		_registered = {} :: { [Model]: boolean },
		_stepConn   = nil :: RBXScriptConnection?,
		_lastSample = 0   :: number,
	} :: LagCompensationImpl, LagCompensation)
end

-- ── Singleton accessor ─────────────────────────────────────────────────────

-- Returns the shared instance, creating and wiring it on first call.
-- Automatically registers all current and future player characters.
function LagCompensation.getShared(): any
	if _shared then return _shared end

	_shared = LagCompensation.new()
	_shared:StartSampling()

	-- Wire up characters that already exist.
	for _, player in Players:GetPlayers() do
		if player.Character then
			_shared:Register(player.Character)
		end
		player.CharacterAdded:Connect(function(char)
			_shared:Register(char)
		end)
	end

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(char)
			_shared:Register(char)
		end)
	end)

	return _shared
end

-- ── Registration ───────────────────────────────────────────────────────────

-- Begin tracking positions for `character`.
function LagCompensation:Register(character: Model)
	if (self :: LagCompensationImpl)._registered[character] then return end
	;(self :: LagCompensationImpl)._registered[character] = true
	;(self :: LagCompensationImpl)._history[character]    = {}

	character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			(self :: LagCompensationImpl)._history[character]    = nil
			;(self :: LagCompensationImpl)._registered[character] = nil
		end
	end)
end

function LagCompensation:Unregister(character: Model)
	;(self :: LagCompensationImpl)._history[character]    = nil
	;(self :: LagCompensationImpl)._registered[character] = nil
end

-- ── Sampling ───────────────────────────────────────────────────────────────

function LagCompensation:StartSampling()
	local impl = self :: LagCompensationImpl
	if impl._stepConn then return end

	impl._stepConn = RunService.Heartbeat:Connect(function()
		local now = workspace:GetServerTimeNow()
		if now - impl._lastSample < SAMPLE_INTERVAL then return end
		impl._lastSample = now

		local cutoff = now - HISTORY_SECONDS

		for character, history in impl._history do
			-- Snapshot every non-tool BasePart in the character.
			local frames: { [BasePart]: CFrame } = {}
			local ok = pcall(function()
				for _, desc in character:GetDescendants() do
					if desc:IsA("BasePart") and not desc:IsA("Tool") then
						local bp = desc :: BasePart
						frames[bp] = bp.CFrame
					end
				end
			end)
			if not ok then continue end

			table.insert(history, { t = now, frames = frames })

			-- Trim entries older than HISTORY_SECONDS.
			local trimTo = 0
			for i = 1, #history do
				if history[i].t < cutoff then
					trimTo = i
				else
					break
				end
			end
			if trimTo > 0 then
				table.move(history, trimTo + 1, #history, 1)
				for i = #history - trimTo + 1, #history do
					history[i] = nil
				end
			end
		end
	end)
end

function LagCompensation:StopSampling()
	local impl = self :: LagCompensationImpl
	if impl._stepConn then
		impl._stepConn:Disconnect()
		impl._stepConn = nil
	end
end

-- ── Rewind ─────────────────────────────────────────────────────────────────

-- Temporarily move all tracked characters' parts to where they were at
-- `timestamp`. Returns a restore() function — ALWAYS call it, even on error.
--
-- Pattern:
--   local restore = lagComp:Rewind(clientTimestamp)
--   local result  = workspace:Raycast(...)
--   restore()
--
function LagCompensation:Rewind(timestamp: number): () -> ()
	local impl   = self :: LagCompensationImpl
	local now    = workspace:GetServerTimeNow()
	-- Clamp: attackers cannot claim an arbitrarily old shot to cheat range.
	local target = math.max(timestamp, now - MAX_REWIND_S)

	type RestoreEntry = { part: BasePart, original: CFrame }
	local restores: { RestoreEntry } = {}

	for character, history in impl._history do
		if #history == 0 then continue end

		-- Binary search for the latest snapshot at or before `target`.
		local lo, hi, best = 1, #history, 1
		while lo <= hi do
			local mid = (lo + hi) // 2
			if history[mid].t <= target then
				best = mid
				lo   = mid + 1
			else
				hi   = mid - 1
			end
		end

		local snap = history[best]
		for part, historicCF in snap.frames do
			if part and part.Parent then
				table.insert(restores, { part = part, original = part.CFrame })
				part.CFrame = historicCF
			end
		end
	end

	return function()
		for _, entry in restores do
			if entry.part and entry.part.Parent then
				entry.part.CFrame = entry.original
			end
		end
	end
end

-- ── Cleanup ────────────────────────────────────────────────────────────────

function LagCompensation:Destroy()
	self:StopSampling()
	local impl = self :: LagCompensationImpl
	table.clear(impl._history)
	table.clear(impl._registered)
end

return LagCompensation
