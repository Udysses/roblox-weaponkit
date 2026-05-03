-- LocalScript — place this inside your Tool in StarterPack (or StarterCharacterScripts).
-- This is the entire client-side setup. WeaponKit handles the rest.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- If WeaponKit is not in ReplicatedStorage yet, WaitForChild will wait for it.
local WeaponKit = require(ReplicatedStorage:WaitForChild("WeaponKit"))

WeaponKit.Client.new(script.Parent, {

	-- ── Combat ──────────────────────────────────────────────────────────
	damage   = 30,    -- HP dealt per hit
	cooldown = 0.6,   -- Seconds between swings
	range    = 9,     -- Hitbox depth in studs

	-- ── Animations ──────────────────────────────────────────────────────
	-- Replace these IDs with your own animation assets.
	-- Leave a slot as "" to skip it entirely.
	animations = {
		idle  = "rbxassetid://YOUR_IDLE_ANIM_ID",
		swing = "rbxassetid://YOUR_SWING_ANIM_ID",
		equip = "", -- optional: plays once when the sword is drawn
	},

	-- ── Sounds ──────────────────────────────────────────────────────────
	-- Replace with asset IDs, or leave as 0 to skip.
	sounds = {
		swing = 0,
		hit   = 0,
	},

}):Start()
