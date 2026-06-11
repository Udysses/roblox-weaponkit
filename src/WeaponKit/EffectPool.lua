--!strict
-- EffectPool.lua
-- Client-side object pool for tracer/bullet Parts.
--
-- Creating and destroying a Part on every shot causes GC pressure that
-- manifests as periodic frame spikes, especially at ACS fire rates (600+ RPM).
-- This pool pre-allocates N Parts and recycles them: Acquire() pulls one off
-- the stack; Release() hides it off-screen and pushes it back.
-- If the pool is exhausted it grows automatically — no shots are ever dropped.
--
-- Parts are parented to workspace (NOT a character) so they survive death.
-- While idle they sit at CFrame.new(0,-99999,0), invisible and inert.

local OFFSCREEN = CFrame.new(0, -99999, 0)

-- ── Types ──────────────────────────────────────────────────────────────────

export type EffectPool = {
	Acquire : (self: EffectPool) -> Part,
	Release : (self: EffectPool, part: Part, delay: number?) -> (),
	Destroy : (self: EffectPool) -> (),
}

type PoolImpl = {
	_available : { Part },
	_all       : { Part },
	_cfg       : { [string]: any },
	_inUse     : { [Part]: boolean },  -- prevents double-release corruption
}

local EffectPool   = {}
EffectPool.__index = EffectPool

-- ── Internal part factory ──────────────────────────────────────────────────

local function makePart(cfg: { [string]: any }): Part
	local p      = Instance.new("Part")
	p.Name       = "PooledTracer"
	p.Anchored   = true
	p.CanCollide = false
	p.CanTouch   = false
	p.CastShadow = false
	p.Size       = Vector3.new(0.05, 0.05, (cfg.tracerLength :: number?) or 2.5)
	p.Material   = Enum.Material.Neon
	p.Color      = (cfg.tracerColor :: Color3?) or Color3.fromRGB(255, 210, 80)
	p.CFrame     = OFFSCREEN
	p.Parent     = workspace
	return p
end

-- ── Constructor ────────────────────────────────────────────────────────────

-- `initialSize` — how many parts to pre-allocate. 20 is good for most guns;
--   raise to 40+ for very high fire-rate weapons or multiple simultaneous shooters.
-- `cfg` — the weapon's hitscan config sub-table (for tracerColor/tracerLength).
function EffectPool.new(initialSize: number, cfg: { [string]: any }): EffectPool
	local self = setmetatable({
		_available = {} :: { Part },
		_all       = {} :: { Part },
		_cfg       = cfg,
		_inUse     = {} :: { [Part]: boolean },
	} :: PoolImpl, EffectPool)

	for _ = 1, math.max(1, initialSize) do
		local p = makePart(cfg)
		table.insert(self._available, p)
		table.insert(self._all, p)
	end

	return self :: any
end

-- ── Public ─────────────────────────────────────────────────────────────────

-- Pull a Part from the pool. The caller is responsible for positioning it
-- and calling Release() when the visual is done.
function EffectPool:Acquire(): Part
	local impl = self :: PoolImpl
	local part: Part
	if #impl._available == 0 then
		-- Pool exhausted — grow rather than drop the shot.
		part = makePart(impl._cfg)
		table.insert(impl._all, part)
	else
		part = table.remove(impl._available) :: Part
	end
	impl._inUse[part] = true
	return part
end

-- Return a Part to the pool after an optional delay (e.g. tracer lifetime).
-- Double-release is silently ignored — the _inUse guard prevents a Part
-- from entering _available twice and corrupting future Acquire() calls.
function EffectPool:Release(part: Part, delay: number?)
	local impl = self :: PoolImpl
	if not impl._inUse[part] then return end  -- already released; ignore
	impl._inUse[part] = nil

	local function ret()
		if part and part.Parent then
			part.CFrame = OFFSCREEN
			table.insert(impl._available, part)
		end
	end
	if delay and delay > 0 then
		task.delay(delay, ret)
	else
		ret()
	end
end

-- Destroy all Parts and clear the pool.
function EffectPool:Destroy()
	local impl = self :: PoolImpl
	for _, p in impl._all do
		if p and p.Parent then
			p:Destroy()
		end
	end
	table.clear(impl._all)
	table.clear(impl._available)
end

return EffectPool
