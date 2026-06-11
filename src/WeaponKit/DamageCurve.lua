--!strict
-- DamageCurve.lua
-- Pure math: damage falloff over distance, headshot multiplier, pierce decay.
-- No side effects. Safe to call inside task.desynchronize() blocks.
--
-- All config keys are optional — pass nil sub-tables to skip that modifier.
-- Final damage is rounded to the nearest integer and floored at 1
-- (a hit always deals at least 1 damage; use alive-check to avoid overkill).

local DamageCurve = {}

-- ── Types ──────────────────────────────────────────────────────────────────

export type FalloffConfig = {
	enabled         : boolean,
	minDamage       : number,      -- absolute floor (e.g. 5)
	fullDamageRange : number,      -- studs before falloff begins (0 = instant)
	zeroRange       : number,      -- studs at which damage reaches minDamage
	curve           : string,      -- "linear" | "quadratic" | "exponential"
}

export type HeadshotConfig = {
	enabled    : boolean,
	multiplier : number,   -- e.g. 2.0 for double damage
	partName   : string,   -- exact part name, usually "Head"
}

export type PierceConfig = {
	enabled     : boolean,
	maxTargets  : number,  -- how many targets a single shot can pierce
	damageDecay : number,  -- multiplier per additional target (e.g. 0.75)
}

-- ── Core function ──────────────────────────────────────────────────────────

-- Compute final damage given:
--   baseDamage   - weapon's configured damage value
--   distance     - studs between attacker and victim at fire time
--   hitPartName  - name of the specific Part hit (nil if not available)
--   falloff      - FalloffConfig sub-table from weapon config (nil = disabled)
--   headshot     - HeadshotConfig sub-table from weapon config (nil = disabled)
--   pierceIndex  - 0-based index of this target in a pierce chain
--                  (0 = primary, 1 = second, etc.; nil = not a pierce shot)
--
-- Returns: (finalDamage: number, wasHeadshot: boolean)
function DamageCurve.Compute(
	baseDamage   : number,
	distance     : number,
	hitPartName  : string?,
	falloff      : FalloffConfig?,
	headshot     : HeadshotConfig?,
	pierceIndex  : number?,
	pierceCfg    : PierceConfig?   -- decay is read from here, not hardcoded
): (number, boolean)
	local damage = baseDamage

	-- ── Pierce decay ──────────────────────────────────────────────────
	-- Each successive target receives damage * decay^index.
	-- Primary target (index 0) is unaffected.
	if pierceIndex and pierceIndex > 0 then
		local decay = (pierceCfg and pierceCfg.damageDecay) or 0.75
		damage = damage * (decay ^ pierceIndex)
	end

	-- ── Distance falloff ──────────────────────────────────────────────
	if falloff and falloff.enabled then
		local fullRange = falloff.fullDamageRange
		local zeroRange = falloff.zeroRange
		local minDmg    = falloff.minDamage
		local curve     = falloff.curve

		-- >= so falloff applies at exactly distance=0 when fullDamageRange=0
		if zeroRange > fullRange and distance >= fullRange then
			local t          = math.clamp((distance - fullRange) / (zeroRange - fullRange), 0, 1)
			local multiplier : number

			if curve == "quadratic" then
				multiplier = 1 - t * t
			elseif curve == "exponential" then
				-- e^(-3t): 1.0 at t=0, ~0.05 at t=1 — gradual until steep at range
				multiplier = math.exp(-3 * t)
			else -- "linear" default
				multiplier = 1 - t
			end

			damage = math.max(minDmg, damage * multiplier)
		end
	end

	-- ── Headshot multiplier ────────────────────────────────────────────
	local wasHeadshot = false
	if headshot and headshot.enabled and hitPartName then
		if hitPartName == headshot.partName then
			damage      = damage * headshot.multiplier
			wasHeadshot = true
		end
	end

	-- Round to nearest integer; minimum 1 so hits always register.
	return math.max(1, math.round(damage)), wasHeadshot
end

return DamageCurve
