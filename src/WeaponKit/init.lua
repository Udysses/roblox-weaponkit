--!strict
-- WeaponKit/init.lua
-- Entry point. Exposes Client, Server, and utility modules.
--
-- ── Quick start (melee) ───────────────────────────────────────────────────
--
--   LocalScript (inside your Tool):
--     local WeaponKit = require(game.ReplicatedStorage.WeaponKit)
--     WeaponKit.Client.new(script.Parent, { damage = 30 }):Start()
--
--   Script (inside your Tool):
--     local WeaponKit = require(game.ReplicatedStorage.WeaponKit)
--     WeaponKit.Server.new(script.Parent, { damage = 30 }):Start()
--
-- ── Quick start (ACS / hitscan guns) ────────────────────────────────────
--
--   LocalScript:
--     local WeaponKit = require(game.ReplicatedStorage.WeaponKit)
--     WeaponKit.Client.new(script.Parent, {
--         weaponType = "hitscan",
--         hitscan    = { maxRange = 500 },
--         damage     = 40,
--     }):Start()
--
--   Script:
--     local WeaponKit = require(game.ReplicatedStorage.WeaponKit)
--     WeaponKit.Server.new(script.Parent, {
--         weaponType = "hitscan",
--         hitscan    = { maxRange = 500 },
--         damage     = 40,
--         maxRange   = 500,
--     }):Start()
--
--     -- Optional: also validate damage from ACS's own gun RemoteEvents.
--     if WeaponKit.ACSBridge.IsPresent() then
--         WeaponKit.ACSBridge.HookRemotes(server, function(shooter, victim, damage)
--             victim:FindFirstChildOfClass("Humanoid"):TakeDamage(damage)
--         end)
--     end
--
-- See Config.lua for the full config reference.

local WeaponKit = {
	Client          = require(script.Client),
	Server          = require(script.Server),
	LagCompensation = require(script.LagCompensation),
	Projectile      = require(script.Projectile),
	ACSBridge       = require(script.ACSBridge),
	VERSION         = "2.0.0",
}

-- ── diagnose() ────────────────────────────────────────────────────────────

--- diagnose(tool?) — run this in the Command Bar or a test Script to get a
--- full report on your weapon setup, including ACS detection and common
--- configuration mistakes.
---
--- Example:
---   local WeaponKit = require(game.ReplicatedStorage.WeaponKit)
---   WeaponKit.diagnose(workspace.MyWeapon)
function WeaponKit.diagnose(tool: Instance?)
	-- If no tool given, try to find one automatically.
	if not tool then
		local lp = game:GetService("Players").LocalPlayer
		if lp then
			tool = lp.Character and lp.Character:FindFirstChildOfClass("Tool")
				or lp.Backpack:FindFirstChildOfClass("Tool")
		end
	end

	local issues: { string } = {}
	local ok:     { string } = {}
	local info:   { string } = {}

	-- ── Tool checks ────────────────────────────────────────────────────
	if not tool then
		warn("[WeaponKit] diagnose(): no Tool found. Pass a Tool instance explicitly.")
		return
	end

	if not tool:IsA("Tool") then
		warn("[WeaponKit] diagnose() expected a Tool, got: " .. tool.ClassName)
		return
	end

	-- Handle
	local handle = tool:FindFirstChild("Handle") :: BasePart?
	if handle then
		table.insert(ok, "Handle part found (" .. handle.ClassName .. ")")
	else
		local requiresHandle = (tool :: Tool).RequiresHandle
		if requiresHandle then
			table.insert(issues,
				"No 'Handle' part AND Tool.RequiresHandle = true.\n"
				.. "  → Activated will NEVER fire.\n"
				.. "  → Fix: rename your grip part to 'Handle', or use cfg.requiresHandle = false."
			)
		else
			table.insert(ok, "No Handle, RequiresHandle = false — correct for WeaponKit.")
		end
	end

	-- Scripts
	local hasLocal  = tool:FindFirstChildOfClass("LocalScript")
	local hasScript = tool:FindFirstChildOfClass("Script")

	if hasLocal then
		table.insert(ok, "LocalScript found: '" .. (hasLocal :: LocalScript).Name .. "'")
	else
		table.insert(issues,
			"No LocalScript inside the tool.\n"
			.. "  → Client-side logic (animations, hit detection) won't run.\n"
			.. "  → Fix: add a LocalScript calling WeaponKit.Client.new():Start()."
		)
	end

	if hasScript then
		table.insert(ok, "Script found: '" .. (hasScript :: Script).Name .. "'")
	else
		table.insert(issues,
			"No Script inside the tool.\n"
			.. "  → Server-side logic (damage, validation) won't run.\n"
			.. "  → Fix: add a Script calling WeaponKit.Server.new():Start()."
		)
	end

	-- RemoteEvent
	local remote = tool:FindFirstChild("WeaponKit_Fire") :: RemoteEvent?
	if remote and remote:IsA("RemoteEvent") then
		table.insert(ok, "WeaponKit_Fire RemoteEvent exists.")
	else
		table.insert(issues,
			"WeaponKit_Fire RemoteEvent not found inside the tool.\n"
			.. "  → Created automatically by WeaponKit.Server.new().\n"
			.. "  → If Server.new() was called, it may have run after diagnose()."
		)
	end

	-- Tool placement
	local parent = tool.Parent
	if parent then
		local isInChar   = parent:FindFirstChildOfClass("Humanoid") ~= nil
		local isBackpack = parent:IsA("Backpack") or parent.Name == "StarterPack"
			or parent.Name == "StarterGear"
		if isInChar or isBackpack then
			table.insert(ok, "Tool placement looks valid: " .. parent.Name)
		else
			table.insert(issues,
				"Tool parent '" .. parent.Name .. "' looks unexpected.\n"
				.. "  → Tools should be in StarterPack, a player Backpack, or the Character.\n"
				.. "  → LocalScripts inside tools only run when the tool is in the Character."
			)
		end
	end

	-- ── Animation ID format check ───────────────────────────────────────
	-- Try to read config from the LocalScript if present.
	-- We can't require the module safely from here, so we do a text scan.
	if hasLocal then
		local src = (hasLocal :: LocalScript).Source
		for animId in string.gmatch(src, '"(rbxassetid://[^"]+)"') do
			-- Any ID that doesn't look like a number after the prefix is suspicious.
			local numStr = string.match(animId, "rbxassetid://(%d+)")
			if not numStr then
				table.insert(issues,
					("Animation ID '%s' doesn't look valid — should be 'rbxassetid://<number>'."):format(animId)
				)
			end
		end
	end

	-- ── Duplicate Server setup check ────────────────────────────────────
	if hasScript then
		local remoteCount = 0
		for _, child in tool:GetChildren() do
			if child:IsA("RemoteEvent") and string.find(child.Name, "WeaponKit") then
				remoteCount += 1
			end
		end
		if remoteCount > 1 then
			table.insert(issues,
				("Found %d WeaponKit RemoteEvents in the tool — Server.new() may have been called twice.\n"):format(remoteCount)
				.. "  → Duplicate server instances cause double-damage and race conditions."
			)
		end
	end

	-- ── ACS detection ───────────────────────────────────────────────────
	if WeaponKit.ACSBridge.IsPresent() then
		local acsDesc = WeaponKit.ACSBridge.Describe()
		table.insert(info, "ACS detected at: " .. acsDesc)
		table.insert(info,
			"To validate ACS gun damage through WeaponKit, call:\n"
			.. "  WeaponKit.ACSBridge.HookRemotes(server, onHitCallback)"
		)

		-- Check for RemoteEvent name conflicts between WeaponKit and ACS.
		local rs = game:GetService("ReplicatedStorage")
		local acsRemotes = { "DamageEvent", "HitEvent", "WeaponDamage" }
		for _, name in acsRemotes do
			if rs:FindFirstChild(name, true) and tool:FindFirstChild(name) then
				table.insert(issues,
					("RemoteEvent '%s' exists in both ACS and this tool — naming conflict possible."):format(name)
				)
			end
		end
	else
		table.insert(info, "ACS not detected in ReplicatedStorage (that's fine if you're not using it).")
	end

	-- ── Lag compensation status ─────────────────────────────────────────
	local lcModule = require(script.LagCompensation) :: any
	if lcModule and (lcModule :: any)._shared then
		table.insert(ok, "LagCompensation singleton is active (sampling characters).")
	else
		table.insert(info,
			"LagCompensation not yet started. It activates automatically when\n"
			.. "  cfg.lagCompensation.enabled = true (default) and Server.new() is called."
		)
	end

	-- ── Print report ────────────────────────────────────────────────────
	print(string.rep("─", 60))
	print("[WeaponKit v" .. WeaponKit.VERSION .. "] Diagnosis for:", tool:GetFullName())
	print(string.rep("─", 60))

	if #ok > 0 then
		print("Passing checks:")
		for _, msg in ok do print("  ✓", msg) end
	end

	if #info > 0 then
		print("Info:")
		for _, msg in info do print("  ℹ", msg) end
	end

	if #issues > 0 then
		warn(string.format("[WeaponKit] %d issue(s) found:", #issues))
		for i, msg in issues do
			warn(string.format("  [%d] %s", i, msg))
		end
	else
		print("[WeaponKit] No issues found.")
		print("            If the weapon still misbehaves, check Output for runtime errors during equip.")
	end

	print(string.rep("─", 60))
end

return WeaponKit
