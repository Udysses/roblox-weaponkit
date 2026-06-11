--!strict
-- LineOfSight.lua
-- Server-side wall-rejection for hit validation.
--
-- Raycasts from the attacker toward the claimed hit position.
-- If the first obstruction is NOT part of the victim's character,
-- the shot is considered blocked (fired through a wall/terrain/prop).
--
-- ⚠ IMPORTANT: call this INSIDE a LagCompensation rewind bracket.
-- Geometry (walls, terrain) is never rewound — only character Parts are.
-- Calling LOS outside the bracket means characters are at live positions
-- while walls are at geometry positions, matching neither side's view.
-- Server.lua handles this by keeping LOS inside the same rewind window
-- as the hitscan raycast.
--
-- Disabled by default (cfg.lineOfSight.enabled = false) because thin walls
-- and edge geometry can cause false rejections. Tune the excludeModels list
-- before enabling in competitive games.

local LineOfSight = {}

-- ── Types ──────────────────────────────────────────────────────────────────

export type LOSResult = {
	blocked  : boolean,
	hitPart  : BasePart?,
	hitPos   : Vector3?,
	distance : number,    -- studs from attacker to first obstruction
}

-- ── Core ───────────────────────────────────────────────────────────────────

-- Check whether the attacker has unobstructed LOS to `targetPos`.
-- `attackerChar` is excluded from the outbound raycast.
-- `victimChar`   identifies the victim — if the first hit part belongs to
--                the victim, LOS is considered clear.
-- `extraExclude` optional extra models/parts to skip (e.g. glass panels).
function LineOfSight.Check(
	attackerChar  : Model,
	attackerRoot  : BasePart,
	targetPos     : Vector3,
	victimChar    : Model?,
	extraExclude  : { Instance }?
): LOSResult
	local origin    = attackerRoot.Position
	local direction = targetPos - origin
	local totalDist = direction.Magnitude

	if totalDist < 0.05 then
		return { blocked = false, hitPart = nil, hitPos = targetPos, distance = 0 }
	end

	local exclude: { Instance } = { attackerChar }
	if extraExclude then
		for _, v in extraExclude do
			table.insert(exclude, v)
		end
	end

	local params = RaycastParams.new()
	params.FilterType                 = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater                = true

	local result = workspace:Raycast(origin, direction.Unit * totalDist, params)

	if not result then
		-- Nothing between attacker and target — clear.
		return { blocked = false, hitPart = nil, hitPos = targetPos, distance = totalDist }
	end

	-- If the first-hit part belongs to the victim's character, LOS is clear —
	-- we hit the target before hitting anything else.
	if victimChar then
		local hitModel = result.Instance:FindFirstAncestorOfClass("Model")
		if hitModel == victimChar then
			return {
				blocked  = false,
				hitPart  = result.Instance :: BasePart,
				hitPos   = result.Position,
				distance = (result.Position - origin).Magnitude,
			}
		end
	end

	-- Something else was hit first — shot was through a wall/prop.
	return {
		blocked  = true,
		hitPart  = result.Instance :: BasePart,
		hitPos   = result.Position,
		distance = (result.Position - origin).Magnitude,
	}
end

-- Convenience wrapper that returns (allowed: boolean, reason: string?).
-- Use this in Server.lua validation chains.
function LineOfSight.Assert(
	attackerChar : Model,
	attackerRoot : BasePart,
	targetPos    : Vector3,
	victimChar   : Model?,
	extraExclude : { Instance }?
): (boolean, string?)
	local r = LineOfSight.Check(attackerChar, attackerRoot, targetPos, victimChar, extraExclude)
	if r.blocked then
		local name = r.hitPart and r.hitPart.Name or "unknown"
		return false, ("LOS blocked by '%s' at %.1f studs"):format(name, r.distance)
	end
	return true, nil
end

return LineOfSight
