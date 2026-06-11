--!strict
-- WeaponKit/init.lua  —  v3.0.0
-- Entry point. Exposes all modules and the diagnose() utility.
--
-- ── Melee weapon (quick start) ────────────────────────────────────────────
--
--   LocalScript:   WeaponKit.Client.new(script.Parent, { damage=30 }):Start()
--   Script:        WeaponKit.Server.new(script.Parent, { damage=30 }):Start()
--
-- ── Hitscan / ACS gun ────────────────────────────────────────────────────
--
--   LocalScript:
--     WeaponKit.Client.new(script.Parent, {
--         weaponType = "hitscan",
--         hitscan    = { maxRange=400 },
--         damage     = 35,
--     }):Start()
--
--   Script:
--     local server = WeaponKit.Server.new(script.Parent, {
--         weaponType = "hitscan",
--         hitscan    = { maxRange=400 },
--         damage     = 35,  maxRange = 400,
--         falloff    = { enabled=true, fullDamageRange=100, zeroRange=400, minDamage=8 },
--         headshot   = { enabled=true, multiplier=2.5 },
--         lineOfSight = { enabled=true },
--         effects    = { poolEnabled=true, useUnreliableRemote=true },
--     })
--     server:Start()
--
--     -- React to kills without touching WeaponKit:
--     server.hooks.OnKill:Connect(function(shooter, victim, ctx)
--         print(shooter.Name, "killed", victim.Name, ctx.isHeadshot and "(headshot!)" or "")
--     end)
--
--     -- Hook ACS damage events through WeaponKit validation:
--     if WeaponKit.ACSBridge.IsPresent() then
--         WeaponKit.ACSBridge.HookRemotes(server, function(shooter, victim, dmg)
--             victim:FindFirstChildOfClass("Humanoid"):TakeDamage(dmg)
--             server.hooks.OnHit:Fire(shooter, victim, dmg, {} :: any)
--         end)
--     end
--
-- ── Debug visualization ───────────────────────────────────────────────────
--
--   Script:
--     WeaponKit.Server.new(script.Parent, {
--         debug = { enabled=true, targetPlayer="YourName" }
--     }):Start()
--
--   LocalScript (same tool):
--     local dbgClient = WeaponKit.DebugViz.newClient(script.Parent, client._topMaid)
--     dbgClient:Start()
--
-- See Config.lua for the complete config reference.

local WeaponKit = {
	-- Core
	Client          = require(script.Client),
	Server          = require(script.Server),

	-- New v2 modules
	LagCompensation = require(script.LagCompensation),
	Projectile      = require(script.Projectile),
	ACSBridge       = require(script.ACSBridge),

	-- New v3 modules
	Signal          = require(script.Signal),
	Hooks           = require(script.Hooks),
	StateMachine    = require(script.StateMachine),
	EffectPool      = require(script.EffectPool),
	DebugViz        = require(script.DebugViz),
	DamageCurve     = require(script.DamageCurve),
	LineOfSight     = require(script.LineOfSight),

	VERSION         = "3.0.0",
}

-- ── diagnose() ────────────────────────────────────────────────────────────

function WeaponKit.diagnose(tool: Instance?)
	if not tool then
		local lp = game:GetService("Players").LocalPlayer
		if lp then
			tool = (lp.Character and lp.Character:FindFirstChildOfClass("Tool"))
				or lp.Backpack:FindFirstChildOfClass("Tool")
		end
	end

	if not tool then
		warn("[WeaponKit] diagnose(): no Tool found. Pass one explicitly.")
		return
	end
	if not tool:IsA("Tool") then
		warn("[WeaponKit] diagnose() expected a Tool, got: " .. tool.ClassName)
		return
	end

	local issues : { string } = {}
	local ok     : { string } = {}
	local info   : { string } = {}

	-- ── Handle ─────────────────────────────────────────────────────────
	local handle = tool:FindFirstChild("Handle") :: BasePart?
	if handle then
		table.insert(ok, "Handle found (" .. handle.ClassName .. ")")
	elseif (tool :: Tool).RequiresHandle then
		table.insert(issues,
			"No 'Handle' AND RequiresHandle = true → Activated never fires.\n"
			.. "  Fix: rename grip part to 'Handle' or set cfg.requiresHandle = false."
		)
	else
		table.insert(ok, "No Handle, RequiresHandle = false — correct for WeaponKit.")
	end

	-- ── Scripts ────────────────────────────────────────────────────────
	local hasLocal  = tool:FindFirstChildOfClass("LocalScript")
	local hasScript = tool:FindFirstChildOfClass("Script")

	if hasLocal  then table.insert(ok, "LocalScript: '"  .. (hasLocal  :: LocalScript).Name .. "'")
	else table.insert(issues, "No LocalScript → client logic won't run.") end

	if hasScript then table.insert(ok, "Script: '" .. (hasScript :: Script).Name .. "'")
	else table.insert(issues, "No Script → server validation won't run.") end

	-- ── RemoteEvents ────────────────────────────────────────────────────
	local fireRemote   = tool:FindFirstChild("WeaponKit_Fire")
	local effectRemote = tool:FindFirstChild("WeaponKit_Effects")
	local debugRemote  = tool:FindFirstChild("WeaponKit_Debug")

	if fireRemote and fireRemote:IsA("RemoteEvent") then
		table.insert(ok, "WeaponKit_Fire RemoteEvent present.")
	else
		table.insert(issues,
			"WeaponKit_Fire not found — Server.new() hasn't run yet or it ran after diagnose()."
		)
	end

	if effectRemote then
		if effectRemote:IsA("UnreliableRemoteEvent") then
			table.insert(ok, "WeaponKit_Effects UnreliableRemoteEvent present (effects optimized).")
		else
			table.insert(issues,
				"WeaponKit_Effects exists but is not an UnreliableRemoteEvent — remove and let WeaponKit recreate it."
			)
		end
	else
		table.insert(info, "WeaponKit_Effects not present (cfg.effects.useUnreliableRemote = false).")
	end

	if debugRemote then
		table.insert(info, "WeaponKit_Debug present — debug visualization active.")
	end

	-- ── Duplicate server setup ──────────────────────────────────────────
	local wkRemoteCount = 0
	for _, child in tool:GetChildren() do
		if child:IsA("RemoteEvent") and string.match(child.Name, "^WeaponKit_") then
			wkRemoteCount += 1
		end
	end
	if wkRemoteCount > 2 then
		table.insert(issues,
			("Found %d WeaponKit_* RemoteEvents — Server.new() may have been called twice."):format(wkRemoteCount)
		)
	end

	-- ── Tool placement ──────────────────────────────────────────────────
	local parent = tool.Parent
	if parent then
		local inChar  = parent:FindFirstChildOfClass("Humanoid") ~= nil
		local inPack  = parent:IsA("Backpack") or parent.Name == "StarterPack" or parent.Name == "StarterGear"
		if inChar or inPack then
			table.insert(ok, "Tool placement valid: " .. parent.Name)
		else
			table.insert(issues,
				"Tool parent '" .. parent.Name .. "' looks unexpected.\n"
				.. "  LocalScripts inside tools only run when the tool is in the Character."
			)
		end
	end

	-- ── Animation IDs ───────────────────────────────────────────────────
	if hasLocal then
		local src = (hasLocal :: LocalScript).Source
		for animId in string.gmatch(src, '"(rbxassetid://[^"]+)"') do
			if not string.match(animId, "rbxassetid://%d+$") then
				table.insert(issues, ("Animation ID '%s' looks malformed."):format(animId))
			end
		end
	end

	-- ── ACS detection ───────────────────────────────────────────────────
	if WeaponKit.ACSBridge.IsPresent() then
		table.insert(info, "ACS detected at: " .. WeaponKit.ACSBridge.Describe())
		table.insert(info,
			"To validate ACS damage through WeaponKit:\n"
			.. "  WeaponKit.ACSBridge.HookRemotes(server, onHitCallback)"
		)
	else
		table.insert(info, "ACS not detected (fine if you're not using it).")
	end

	-- ── Lag compensation status ─────────────────────────────────────────
	local lcMod = require(script.LagCompensation) :: any
	if lcMod.isActive() then
		table.insert(ok, "LagCompensation singleton is active and sampling characters.")
	else
		table.insert(info,
			"LagCompensation not yet started.\n"
			.. "  It activates when Server.new() is called with cfg.lagCompensation.enabled = true."
		)
	end

	-- ── Report ──────────────────────────────────────────────────────────
	print(string.rep("─", 60))
	print(("[WeaponKit v%s] Diagnosis: %s"):format(WeaponKit.VERSION, tool:GetFullName()))
	print(string.rep("─", 60))

	if #ok > 0 then
		print("Passing:")
		for _, m in ok do print("  ✓", m) end
	end
	if #info > 0 then
		print("Info:")
		for _, m in info do print("  ℹ", m) end
	end
	if #issues > 0 then
		warn(("[WeaponKit] %d issue(s):"):format(#issues))
		for i, m in issues do warn(("  [%d] %s"):format(i, m)) end
	else
		print("[WeaponKit] No issues found.")
	end
	print(string.rep("─", 60))
end

return WeaponKit
