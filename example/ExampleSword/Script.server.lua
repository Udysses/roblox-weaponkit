-- Script — place this inside your Tool alongside the LocalScript above.
-- This is the entire server-side setup. WeaponKit handles the rest.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponKit = require(ReplicatedStorage:WaitForChild("WeaponKit"))

WeaponKit.Server.new(script.Parent, {

	-- Keep damage consistent with the client config above.
	damage   = 30,

	-- maxRange should be slightly larger than the client's range to
	-- account for network latency without opening the door to exploits.
	maxRange = 18,

}):Start()
