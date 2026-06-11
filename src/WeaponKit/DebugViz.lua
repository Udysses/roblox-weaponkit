--!strict
-- DebugViz.lua
-- Developer-only hitbox and ray visualization. Sends server-side validation
-- geometry to ONE specific client as coloured Part adornments.
--
-- Completely inert in production: the WeaponKit_Debug RemoteEvent is only
-- created when cfg.debug.enabled = true, and only fires when a target player
-- is set. No observable overhead for players who aren't the debug target.
--
-- Server usage (inside your server Script):
--   local dbg = WeaponKit.DebugViz.newServer(tool, server._maid, cfg.debug)
--   dbg:SetTarget(game.Players:FindFirstChild("YourName"))
--   -- WeaponKit wires SendHitbox / SendRay internally; you rarely call them.
--
-- Client usage (inside your LocalScript):
--   local dbgClient = WeaponKit.DebugViz.newClient(tool, client._topMaid)
--   dbgClient:Start()
--
-- Security: the server ONLY fires the remote toward the client.
--           The client ONLY listens (OnClientEvent). No OnServerEvent handler
--           is registered — firing the debug remote toward the server does nothing.

local Debris = game:GetService("Debris")

local REMOTE_NAME = "WeaponKit_Debug"

local DebugViz = {}

-- ── Server ─────────────────────────────────────────────────────────────────

export type ServerDebugViz = {
	SendHitbox : (self: ServerDebugViz, cf: CFrame, size: Vector3, hit: boolean) -> (),
	SendRay    : (self: ServerDebugViz, origin: Vector3, dir: Vector3, dist: number, hit: boolean) -> (),
	SetTarget  : (self: ServerDebugViz, player: Player?) -> (),
	Destroy    : (self: ServerDebugViz) -> (),
}

type SrvImpl = {
	_remote : RemoteEvent?,
	_target : Player?,
}

local SrvMeta   = {}
SrvMeta.__index = SrvMeta

function DebugViz.newServer(tool: Instance, maid: any, debugCfg: { [string]: any }?): ServerDebugViz
	local cfg    = debugCfg or {}
	local remote : RemoteEvent? = nil

	if cfg.enabled then
		local existing = tool:FindFirstChild(REMOTE_NAME)
		if existing and existing:IsA("RemoteEvent") then
			remote = existing :: RemoteEvent
		else
			remote = Instance.new("RemoteEvent")
			;(remote :: RemoteEvent).Name   = REMOTE_NAME
			;(remote :: RemoteEvent).Parent = tool
		end
		maid:Give(remote)
	end

	local self = setmetatable({ _remote = remote, _target = nil } :: SrvImpl, SrvMeta)

	-- Auto-set target from config if provided.
	if cfg.targetPlayer and type(cfg.targetPlayer) == "string" then
		task.defer(function()
			local player = game:GetService("Players"):FindFirstChild(cfg.targetPlayer :: string) :: Player?
			if player then
				(self :: any):SetTarget(player)
			end
		end)
	end

	return self :: any
end

function SrvMeta:SendHitbox(cf: CFrame, size: Vector3, hit: boolean)
	local impl = self :: SrvImpl
	if not impl._remote or not impl._target then return end
	impl._remote:FireClient(impl._target :: Player, "box", cf, size, hit)
end

function SrvMeta:SendRay(origin: Vector3, dir: Vector3, dist: number, hit: boolean)
	local impl = self :: SrvImpl
	if not impl._remote or not impl._target then return end
	impl._remote:FireClient(impl._target :: Player, "ray", origin, dir, dist, hit)
end

function SrvMeta:SetTarget(player: Player?)
	(self :: SrvImpl)._target = player
end

function SrvMeta:Destroy()
	local impl = self :: SrvImpl
	impl._remote = nil
	impl._target = nil
end

-- ── Client ─────────────────────────────────────────────────────────────────

export type ClientDebugViz = {
	Start   : (self: ClientDebugViz) -> (),
	Destroy : (self: ClientDebugViz) -> (),
}

type CliImpl = {
	_tool    : Instance,
	_maid    : any,
	_started : boolean,
}

local CliMeta   = {}
CliMeta.__index = CliMeta

function DebugViz.newClient(tool: Instance, maid: any): ClientDebugViz
	return setmetatable({
		_tool    = tool,
		_maid    = maid,
		_started = false,
	} :: CliImpl, CliMeta) :: any
end

function CliMeta:Start()
	local impl = self :: CliImpl
	if impl._started then return end
	impl._started = true

	local remote = impl._tool:FindFirstChild(REMOTE_NAME) :: RemoteEvent?
	if not remote then
		-- Debug remote not present — not enabled on server, nothing to do.
		return
	end

	impl._maid:Give(remote.OnClientEvent:Connect(function(kind: string, ...: any)
		local args = { ... }

		if kind == "box" then
			local cf    = args[1] :: CFrame
			local size  = args[2] :: Vector3
			local isHit = args[3] :: boolean
			local color = isHit
				and Color3.fromRGB(255, 80,  80)   -- red  = hit
				or  Color3.fromRGB(80,  80, 255)   -- blue = miss

			local box        = Instance.new("Part")
			box.Size         = size
			box.CFrame       = cf
			box.Anchored     = true
			box.CanCollide   = false
			box.CanTouch     = false
			box.Transparency = 0.55
			box.Color        = color
			box.Material     = Enum.Material.Neon
			box.Parent       = workspace
			Debris:AddItem(box, 1.0)

		elseif kind == "ray" then
			local origin = args[1] :: Vector3
			local dir    = args[2] :: Vector3
			local dist   = args[3] :: number
			local isHit  = args[4] :: boolean
			local color  = isHit
				and Color3.fromRGB(80, 255, 80)   -- green = hit
				or  Color3.fromRGB(255, 80, 80)   -- red   = miss/blocked

			local mid    = origin + dir.Unit * dist * 0.5
			local target = origin + dir.Unit * dist

			local ray        = Instance.new("Part")
			ray.Size         = Vector3.new(0.08, 0.08, dist)
			ray.CFrame       = CFrame.lookAt(mid, target)
			ray.Anchored     = true
			ray.CanCollide   = false
			ray.CanTouch     = false
			ray.Transparency = 0.35
			ray.Color        = color
			ray.Material     = Enum.Material.Neon
			ray.Parent       = workspace
			Debris:AddItem(ray, 0.5)
		end
	end))
end

function CliMeta:Destroy()
	(self :: CliImpl)._maid:Destroy()
end

return DebugViz
