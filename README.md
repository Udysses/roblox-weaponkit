# WeaponKit

A Roblox weapon framework that handles security, lag compensation, animations, and ACS integration — so you don't have to.

**Pick your path:**

| I want to… | Go to |
|---|---|
| Build a weapon from scratch | [Track A — New Setup](#track-a--new-setup) |
| Add features to my existing weapon code | [Track B — Partial Integration](#track-b--partial-integration) |
| Fix lag / validate hits for my ACS weapons | [Track C — ACS Integration](#track-c--acs-integration) |
| See every config option | [Configuration Reference](#configuration-reference) |
| Understand what each module does | [Module Reference](#module-reference) |

---

## What WeaponKit fixes

| Problem | Fix |
|---|---|
| `attempt to index nil with 'Humanoid'` | `WaitForChild` + `CharacterAdded` guard before any access |
| Animation stuck after unequip | Maid stops and destroys every track on each unequip |
| `.Touched` deals 10–30× intended damage | Replaced with `GetPartBoundsInBox` + per-swing hit cache |
| Exploiter deals infinite damage via remote | Server re-validates distance, rate-limits, and clamps damage |
| ACS shots miss at high ping | 20 Hz position history + timestamp rewind ("favor the shooter") |
| GC spikes at high fire rates | EffectPool recycles tracer Parts — no create/destroy per shot |
| Firing during reload / double-activation | StateMachine guards every state transition |
| Can't react to hits client-side | `hooks.OnHit` / `hooks.OnKill` fire with full context |
| All players take damage on one swing | Every weapon instance has fully isolated state |
| Can't damage R6 rigs or NPCs | `FindFirstChildOfClass("Humanoid")` works on any Model |

---

## Track A — New Setup

You have no weapon code yet. WeaponKit gives you a working weapon in two scripts.

### 1. Install

**Rojo (recommended):**
```bash
git clone https://github.com/Udysses/roblox-weaponkit.git
cd roblox-weaponkit
rojo serve default.project.json
```
Connect from the Rojo plugin in Studio. WeaponKit lands in `ReplicatedStorage.WeaponKit`.

**Manual:** Create a ModuleScript in `ReplicatedStorage` named `WeaponKit`. Paste `src/WeaponKit/init.lua` into it, then create a child ModuleScript for every file in `src/WeaponKit/` with the matching name.

### 2. Melee weapon (sword, bat, etc.)

Inside your Tool, create a **LocalScript**:
```lua
local WeaponKit = require(game.ReplicatedStorage.WeaponKit)
WeaponKit.Client.new(script.Parent, {
    weaponType = "melee",
    damage     = 30,
    cooldown   = 0.5,
    range      = 8,
    animations = {
        idle  = "rbxassetid://YOUR_ID",
        swing = "rbxassetid://YOUR_ID",
    },
    sounds = { swing = 0, hit = 0 },
}):Start()
```

Inside your Tool, create a **Script**:
```lua
local WeaponKit = require(game.ReplicatedStorage.WeaponKit)
WeaponKit.Server.new(script.Parent, {
    damage   = 30,
    maxRange = 14,   -- slightly larger than client range for latency headroom
}):Start()
```

That's it. Server validates every hit — rate limit, distance, alive check.

### 3. Hitscan weapon (gun, rifle, etc.)

Same two scripts, different config:
```lua
-- LocalScript
WeaponKit.Client.new(script.Parent, {
    weaponType = "hitscan",
    damage     = 45,
    cooldown   = 0.1,
    hitscan = {
        maxRange      = 300,
        tracerEnabled = true,
        tracerColor   = Color3.fromRGB(255, 210, 80),
        tracerSpeed   = 600,
    },
    effects = {
        poolEnabled = true,   -- recycles tracer Parts, prevents GC spikes
        poolSize    = 20,
    },
}):Start()

-- Script
WeaponKit.Server.new(script.Parent, {
    weaponType = "hitscan",
    damage     = 45,
    lagCompensation = { enabled = true, maxRewindMs = 500 },
}):Start()
```

`lagCompensation` rewinds character positions to the moment the client fired, so shots don't miss at high ping.

### 4. Reacting to hits

```lua
-- Script
local server = WeaponKit.Server.new(script.Parent, { damage = 45 })

server.hooks.OnHit:Connect(function(player, victim, damage, ctx)
    print(player.Name, "hit", victim.Name, "for", damage, "HP")
    -- ctx: isHeadshot, distance, hitPart, weaponName, weaponType, rawDamage, pierceIndex, timestamp
end)

server.hooks.OnKill:Connect(function(player, victim, ctx)
    -- award points, play sound, etc.
end)

server:Start()
```

---

## Track B — Partial Integration

You already have a weapon system. Use individual WeaponKit modules without replacing your code.

### Add server-side validation to your existing remote

Replace your `OnServerEvent` handler:
```lua
-- Before:
myRemote.OnServerEvent:Connect(function(player, hitName)
    workspace[hitName]:FindFirstChildOfClass("Humanoid"):TakeDamage(30)
end)

-- After — WeaponKit validates for you:
local Server = require(game.ReplicatedStorage.WeaponKit.Server)
local server = Server.new(myTool, { damage = 30, maxRange = 20, rateLimit = 8 })
server.hooks.OnHit:Connect(function(ctx)
    ctx.victim:FindFirstChildOfClass("Humanoid"):TakeDamage(ctx.damage)
end)
server:Start()
-- Your existing remote is replaced by WeaponKit_Fire — update your LocalScript to FireServer on WeaponKit_Fire.
```

### Add lag compensation to your existing hitscan

```lua
-- Script (server)
local LC = require(game.ReplicatedStorage.WeaponKit.LagCompensation)
local lc = LC.getShared()   -- singleton, safe to call from multiple weapons

-- Inside your OnServerEvent:
myRemote.OnServerEvent:Connect(function(player, origin, direction, timestamp)
    local restore = lc:Rewind(timestamp)         -- move characters to where client saw them
    local result  = workspace:Raycast(origin, direction * 300, rayParams)
    restore()                                    -- MUST call restore before yielding

    if result then
        local hum = result.Instance.Parent:FindFirstChildOfClass("Humanoid")
        if hum then hum:TakeDamage(45) end
    end
end)
```

### Add damage falloff and headshots

```lua
local DamageCurve = require(game.ReplicatedStorage.WeaponKit.DamageCurve)

-- Inside your hit handler:
local distance = (attackerRoot.Position - hitPos).Magnitude
local finalDamage, wasHeadshot = DamageCurve.Compute(
    45,            -- base damage
    distance,
    hitPartName,   -- "Head", "UpperTorso", etc.
    { enabled = true, fullDamageRange = 20, zeroRange = 150, minDamage = 10, curve = "linear" },
    { enabled = true, multiplier = 2.0, partName = "Head" }
)
humanoid:TakeDamage(finalDamage)
```

### Add OnHit / OnKill hooks to your existing server

```lua
local Hooks = require(game.ReplicatedStorage.WeaponKit.Hooks)
local hooks = Hooks.new()

-- Wire up in your damage code:
hooks.OnHit:Fire(player, victimModel, finalDamage, {
    weaponName  = "Rifle",
    weaponType  = "hitscan",
    damage      = finalDamage,
    rawDamage   = 45,
    isHeadshot  = wasHeadshot,
    distance    = distance,
    hitPart     = nil,
    hitPos      = nil,
    timestamp   = workspace:GetServerTimeNow(),
    pierceIndex = 0,
})

-- Somewhere else, listen:
hooks.OnKill:Connect(function(player, victim, ctx)
    -- award kill streak, etc.
end)
```

### Add bullet pierce

```lua
local Projectile = require(game.ReplicatedStorage.WeaponKit.Projectile)

-- Inside your hitscan handler (server):
local hits, restore = Projectile.ValidateHitscanPierce(
    origin, direction, player,
    { maxRange = 300, lagCompensation = { enabled = true, maxRewindMs = 500 } }
)
restore()  -- call after all raycasts

for i, hit in hits do
    local decay = 0.75 ^ (i - 1)
    hit.humanoid:TakeDamage(45 * decay)
end
```

### Add a state machine to your client weapon

Prevents double-fire and firing while reloading — drop in alongside your existing code:
```lua
local StateMachine = require(game.ReplicatedStorage.WeaponKit.StateMachine)
local Maid        = require(game.ReplicatedStorage.WeaponKit.Maid)

local maid = Maid.new()
local sm   = StateMachine.new(maid)   -- auto-cleaned when maid:Destroy()

-- In your Activated handler:
if not sm:canFire() then return end
sm:transition("Firing")
-- ... your fire logic ...
sm:transition("Idle")

-- On unequip:
maid:Destroy()
```

### Add line-of-sight rejection

```lua
local LOS = require(game.ReplicatedStorage.WeaponKit.LineOfSight)

-- Inside your hit handler, WHILE rewind is active:
local restore = lc:Rewind(timestamp)
local ok, reason = LOS.Assert(attackerChar, attackerRoot, hitPos, victimChar)
restore()

if not ok then
    warn("LOS blocked:", reason)
    return
end
```

---

## Track C — ACS Integration

You use ACS (Advanced Combat System) and want WeaponKit's security + lag compensation on top.

### Automatic ACS damage validation

ACS fires its own damage remote. WeaponKit intercepts and validates it:

```lua
-- Script (server, anywhere — not inside a Tool)
local WeaponKit = require(game.ReplicatedStorage.WeaponKit)
local server    = WeaponKit.Server.new(myTool, {
    maxRange  = 300,
    maxDamage = 150,
    rateLimit = 20,    -- ACS fire rates can be 600+ RPM
    lagCompensation = { enabled = true, maxRewindMs = 500 },
})
server:Start()

if WeaponKit.ACSBridge.IsPresent() then
    WeaponKit.ACSBridge.HookRemotes(server, function(shooter, victim, damage, weaponName, hitPos)
        -- Only called when WeaponKit approves the hit.
        victim:FindFirstChildOfClass("Humanoid"):TakeDamage(damage)
    end)
else
    warn("ACS not found in ReplicatedStorage — check folder name")
end
```

`HookRemotes` automatically finds ACS's damage remote under any common name (`DamageEvent`, `HitEvent`, `ACS_DamageEvent`, `ACS_Hit`, and more). Supports ACS v2, v3, and v4 payload formats.

### Lag compensation for ACS

ACS sends a timestamp in its fire event. Pass it through the standard lag comp:

```lua
-- In your existing ACS OnServerEvent handler:
local LC      = require(game.ReplicatedStorage.WeaponKit.LagCompensation)
local restore = LC.getShared():Rewind(timestamp)

-- ... your ACS validation logic ...

restore()
```

### Detecting ACS

```lua
print(WeaponKit.ACSBridge.Describe())
-- "ReplicatedStorage.ACS"  or  "not detected"
```

---

## Configuration Reference

All fields are optional. Unset fields use the defaults shown.

```lua
{
    -- Weapon type
    weaponType = "melee",    -- "melee" | "hitscan"

    -- Combat
    damage            = 25,
    cooldown          = 0.5,                   -- seconds between activations
    range             = 8,                     -- melee hitbox depth (studs)
    hitboxSize        = Vector3.new(6, 5, 6),  -- melee hitbox size
    perTargetCooldown = 0.3,
    maxHitsPerEvent   = 10,

    -- Hitscan
    hitscan = {
        maxRange      = 300,
        tracerEnabled = true,
        tracerColor   = Color3.fromRGB(255, 210, 80),
        tracerLength  = 2.5,
        tracerSpeed   = 600,
    },

    -- Damage falloff
    falloff = {
        enabled         = false,
        minDamage       = 5,
        fullDamageRange = 0,     -- studs before falloff begins
        zeroRange       = 300,   -- studs at which damage reaches minDamage
        curve           = "linear",  -- "linear" | "quadratic" | "exponential"
    },

    -- Headshots
    headshot = {
        enabled    = false,
        multiplier = 2.0,
        partName   = "Head",
    },

    -- Bullet pierce
    penetration = {
        enabled     = false,
        maxTargets  = 3,
        damageDecay = 0.75,   -- damage × 0.75^(targetIndex-1)
    },

    -- Lag compensation
    lagCompensation = {
        enabled     = true,
        maxRewindMs = 500,
    },

    -- Line-of-sight check (server raycast, rejects through-wall hits)
    -- Disable if thin walls or LOD meshes cause false rejects.
    lineOfSight = { enabled = false },

    -- Speed / teleport detection
    speedCheck = {
        enabled      = false,
        maxSpeed     = 80,     -- studs/s
        sampleWindow = 0.25,
    },

    -- Parallel Luau validation (requires Tool's Script to be inside an Actor)
    parallelValidation = { enabled = false },

    -- State machine (client) — prevents firing during equip/reload
    stateMachine = {
        enabled           = true,
        serverTimingCheck = false,
    },

    -- Effect pool — recycles tracer Parts, eliminates GC spikes
    effects = {
        poolEnabled         = false,
        poolSize            = 20,
        useUnreliableRemote = false,  -- broadcast visuals on UnreliableRemoteEvent
    },

    -- Debug visualization (sends hitbox/ray adornments to one player)
    debug = {
        enabled      = false,
        targetPlayer = nil,   -- set to a player's Name string
    },

    -- Animations
    animations = {
        equip = "",   -- rbxassetid://... or "" to skip
        idle  = "",
        swing = "",
    },
    animationPriority = Enum.AnimationPriority.Action,

    -- Sounds (0 = skip)
    sounds = { equip = 0, swing = 0, hit = 0 },

    -- Server exploit guards
    maxRange  = 16,    -- reject hits beyond this (studs)
    maxDamage = 200,
    rateLimit = 8,     -- max activations per player per second
}
```

---

## Module Reference

| Module | What it does | Typical user |
|---|---|---|
| `Client` | LocalScript side — animations, hit detection, state machine, tracer effects | Everyone |
| `Server` | Script side — validation, damage, hooks, lag comp routing | Everyone |
| `Config` | Default values, deep-merge, validation warnings | Automatic |
| `Maid` | Cleans up connections/instances on unequip/destroy | Automatic |
| `LagCompensation` | 20 Hz position history + rewind by timestamp | Hitscan / ACS users |
| `Projectile` | Hitscan raycast helpers: single shot, pierce, tracer spawn | Hitscan users |
| `ACSBridge` | Intercepts ACS damage remotes and re-validates through WeaponKit | ACS users |
| `DamageCurve` | Falloff, headshot multiplier, pierce decay math | Custom damage models |
| `LineOfSight` | Server raycast checking attacker → victim isn't through a wall | Anti-cheat hardening |
| `StateMachine` | FSM (Idle / Equipping / Firing / Reloading) preventing double-fire | Complex weapon flows |
| `EffectPool` | Recycles tracer `Part` objects to prevent GC spikes | High fire-rate guns |
| `Signal` | Typed event emitter (used by Hooks internally) | Custom event systems |
| `Hooks` | `OnHit` / `OnKill` / `OnMiss` / `OnRateExceeded` signals with hit context | Anyone reacting to hits |
| `DebugViz` | Sends hitbox/ray adornments to one player via RemoteEvent | Debugging hit detection |

---

## Diagnosing a broken weapon

Run this in the Studio **Command Bar**:

```lua
require(game.ReplicatedStorage.WeaponKit).diagnose(workspace.YourWeaponName)
```

Example output:
```
───────────────────────────────────────────────────
[WeaponKit] Diagnosis for: Workspace.BrokenSword
───────────────────────────────────────────────────
✓ No Handle, but RequiresHandle = false — OK
✓ Script found
✓ Tool is in StarterPack
⚠ 1 issue found:
  [1] No LocalScript inside the tool.
      Fix: add a LocalScript that calls WeaponKit.Client.new():Start()
───────────────────────────────────────────────────
```

---

## Project structure

```
src/WeaponKit/
├── init.lua           Entry point, diagnose()
├── Client.lua         LocalScript handler
├── Server.lua         Script handler + all server validation
├── Config.lua         Defaults, merge, validation
├── Maid.lua           Connection / instance cleanup
├── LagCompensation.lua  Position history + rewind
├── Projectile.lua     Hitscan raycast helpers
├── ACSBridge.lua      ACS damage remote interceptor
├── DamageCurve.lua    Falloff / headshot / pierce math
├── LineOfSight.lua    Through-wall rejection
├── StateMachine.lua   Weapon FSM
├── EffectPool.lua     Part recycling pool
├── Signal.lua         Event emitter
├── Hooks.lua          OnHit / OnKill / OnMiss signals
└── DebugViz.lua       Studio hit visualization
```

---

## Copyright & Contributions

**© 2026 Udysses. All rights reserved.**

- **Viewing:** You are welcome to explore the code here on GitHub.
- **Redistribution:** Use, reproduction, or distribution without express written permission is prohibited.
- **Feature ideas / bugs:** Open a GitHub Issue or send a DM first.
- **Pull Requests:** Restricted to approved collaborators. DM or open an issue to discuss.
