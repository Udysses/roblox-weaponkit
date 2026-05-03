--!strict
-- WeaponKit/init.lua
-- Entry point. Exposes Client, Server, and a diagnose() utility.
--
-- ── Quick start ──────────────────────────────────────────────────────────────
--
--   LocalScript (inside your Tool):
--     local WeaponKit = require(game.ReplicatedStorage.WeaponKit)
--     WeaponKit.Client.new(script.Parent, { damage = 30 }):Start()
--
--   Script (inside your Tool):
--     local WeaponKit = require(game.ReplicatedStorage.WeaponKit)
--     WeaponKit.Server.new(script.Parent, { damage = 30 }):Start()
--
-- That's it. See the config reference in Config.lua or the README for options.

local WeaponKit = {
	Client  = require(script.Client),
	Server  = require(script.Server),
	VERSION = "1.0.0",
}

--- diagnose(tool) — run this in the Command Bar or a test Script when your
--- weapon isn't working. Checks all common setup mistakes and prints a
--- clear report to the Output window.
---
--- Example:
---   local WeaponKit = require(game.ReplicatedStorage.WeaponKit)
---   WeaponKit.diagnose(workspace.MyWeapon)  -- or script.Parent
function WeaponKit.diagnose(tool: Instance)
	if not tool:IsA("Tool") then
		warn("[WeaponKit] diagnose() expected a Tool, got:", tool.ClassName)
		return
	end

	local issues: { string } = {}
	local ok:     { string } = {}

	-- ── Check Handle ────────────────────────────────────────────────────
	local handle = tool:FindFirstChild("Handle") :: BasePart?
	if handle then
		table.insert(ok, "Handle part found (" .. handle.ClassName .. ")")
	else
		-- This is only a problem if RequiresHandle is still true.
		local requiresHandle = (tool :: Tool).RequiresHandle
		if requiresHandle then
			table.insert(
				issues,
				"No 'Handle' part found AND Tool.RequiresHandle = true.\n"
					.. "  → Tool.Activated will NEVER fire.\n"
					.. "  → Fix: rename your grip part to 'Handle', or set RequiresHandle = false\n"
					.. "    (WeaponKit sets this automatically from cfg.requiresHandle)."
			)
		else
			table.insert(ok, "No Handle, but RequiresHandle = false — that's fine with WeaponKit.")
		end
	end

	-- ── Check scripts ────────────────────────────────────────────────────
	local hasLocal  = tool:FindFirstChildOfClass("LocalScript")
	local hasScript = tool:FindFirstChildOfClass("Script")

	if hasLocal then
		table.insert(ok, "LocalScript found: '" .. (hasLocal :: LocalScript).Name .. "'")
	else
		table.insert(
			issues,
			"No LocalScript inside the tool.\n"
				.. "  → Client-side logic (animations, hit detection) will not run.\n"
				.. "  → Fix: add a LocalScript that calls WeaponKit.Client.new():Start()."
		)
	end

	if hasScript then
		table.insert(ok, "Script found: '" .. (hasScript :: Script).Name .. "'")
	else
		table.insert(
			issues,
			"No Script inside the tool.\n"
				.. "  → Server-side logic (damage, validation) will not run.\n"
				.. "  → Fix: add a Script that calls WeaponKit.Server.new():Start()."
		)
	end

	-- ── Check RemoteEvent ────────────────────────────────────────────────
	local remote = tool:FindFirstChild("WeaponKit_Fire") :: RemoteEvent?
	if remote and remote:IsA("RemoteEvent") then
		table.insert(ok, "WeaponKit_Fire RemoteEvent exists.")
	else
		table.insert(
			issues,
			"WeaponKit_Fire RemoteEvent not found inside the tool.\n"
				.. "  → This is created automatically by WeaponKit.Server.new().\n"
				.. "  → If Server.new() has been called, this may mean it ran after diagnose()."
		)
	end

	-- ── Check tool placement ─────────────────────────────────────────────
	local parent = tool.Parent
	if parent then
		local parentName = parent.Name
		local isInChar   = parent:FindFirstChildOfClass("Humanoid") ~= nil
		local isBackpack = parent:IsA("Backpack") or parentName == "StarterPack"
		if isInChar or isBackpack then
			table.insert(ok, "Tool is in a valid location: " .. parentName)
		else
			table.insert(
				issues,
				"Tool parent '" .. parentName .. "' looks unexpected.\n"
					.. "  → Tools should be in StarterPack, a player's Backpack, or their Character.\n"
					.. "  → LocalScripts inside tools only run when the tool is in the Character."
			)
		end
	end

	-- ── Report ────────────────────────────────────────────────────────────
	print(string.rep("─", 55))
	print("[WeaponKit] Diagnosis for:", tool:GetFullName())
	print(string.rep("─", 55))

	if #ok > 0 then
		print("✓ Passing checks:")
		for _, msg in ok do
			print("  ✓", msg)
		end
	end

	if #issues > 0 then
		warn(string.format("[WeaponKit] %d issue(s) found:", #issues))
		for i, msg in issues do
			warn(string.format("  [%d] %s", i, msg))
		end
	else
		print("[WeaponKit] No issues found. If the weapon still misbehaves,")
		print("            check the Output window for runtime errors during equip.")
	end

	print(string.rep("─", 55))
end

return WeaponKit
