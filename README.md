# WeaponKit

A drop-in Roblox weapon framework that fixes the bugs every developer hits when implementing weapon packages.

**Two lines on the client. Two lines on the server. Everything else is handled.**

```lua
-- LocalScript inside your Tool
local WeaponKit = require(game.ReplicatedStorage.WeaponKit)
WeaponKit.Client.new(script.Parent, { damage = 30, cooldown = 0.6 }):Start()

-- Script inside your Tool
local WeaponKit = require(game.ReplicatedStorage.WeaponKit)
WeaponKit.Server.new(script.Parent, { damage = 30 }):Start()
```

---

## Problems this solves

Every bug below is sourced from real Roblox DevForum threads with hundreds of replies. These are the issues that appear on every weapon project eventually.

| Problem | Root cause | WeaponKit fix |
|---|---|---|
| `attempt to index nil with 'Humanoid'` | Script runs before Character loads | `CharacterAdded:Wait()` + `WaitForChild` before any access |
| `attempt to index nil with 'Character'` | Same — race condition on spawn | Same fix; works on first spawn and every respawn |
| Animation stuck after unequip | `AnimationTrack` never stopped or destroyed | Maid stops and destroys every track on each unequip |
| Idle / swing animation overrides nothing | Wrong animation priority | `Enum.AnimationPriority.Action` applied automatically |
| `.Touched` deals 10–30× intended damage | Event fires many times per swing | Replaced with `GetPartBoundsInBox` + per-swing hit cache |
| Weapon won't fire / `Activated` never runs | `RequiresHandle = true` but no `Handle` on ground | `RequiresHandle` set from config (default `false`) |
| `WeaponKit_Fire` not found / weapon silent | Client looks for RemoteEvent before server creates it | Server creates the event synchronously before `Start()` |
| Stuck in cooldown, can't shoot after error | Cooldown flag set, error prevented reset | `task.delay` resets cooldown even if mid-swing logic errors |
| Camera locks to third-person shoulder view | Official Weapons Kit bug | WeaponKit never touches `CurrentCamera` |
| Lag accumulates the longer the session runs | Connections never disconnected across equips | Maid rebuilt every equip cycle, zero leaks |
| Exploiter deals infinite damage via remote | No server-side validation | Server re-validates distance, rate-limits, and clamps damage |
| All players take damage on one swing | Shared global state in scripts | Every weapon instance has fully isolated state |
| Can't damage R6 rigs or NPCs | Code assumed R15 + Players lookup | `FindFirstChildOfClass("Humanoid")` works on any Model |

---

## Installation

### Option A — Manual (no extra tools)

1. In Roblox Studio, create a **ModuleScript** inside `ReplicatedStorage` named `WeaponKit`.
2. Copy the contents of `src/WeaponKit/init.lua` into it.
3. Inside that ModuleScript, create four more ModuleScripts named `Client`, `Server`, `Maid`, and `Config`, and paste the matching file from `src/WeaponKit/` into each.
4. Inside your weapon Tool, add a **LocalScript** and a **Script** from the `example/ExampleSword/` folder.

### Option B — Rojo

```bash
git clone https://github.com/Udysses/roblox-weaponkit.git
cd roblox-weaponkit
rojo serve default.project.json
```

Then connect from the Rojo plugin in Studio.

---

## Configuration

Pass a config table as the second argument to `Client.new()` and `Server.new()`.  
All fields are optional — unset fields fall back to the defaults below.

```lua
WeaponKit.Client.new(script.Parent, {

    -- Combat
    damage            = 25,                    -- HP dealt per hit
    cooldown          = 0.5,                   -- Seconds between activations
    range             = 8,                     -- Hitbox depth in studs
    hitboxSize        = Vector3.new(6, 5, 6),  -- Hitbox dimensions
    perTargetCooldown = 0.3,                   -- Seconds before same target can be hit again

    -- Animations (set to "" to skip a slot)
    animations = {
        idle  = "rbxassetid://1234567",  -- Loops while equipped
        swing = "rbxassetid://1234567",  -- Plays on each activation
        equip = "",                      -- Optional: plays once on equip
    },
    animationPriority = Enum.AnimationPriority.Action,

    -- Sounds (set to 0 to skip)
    sounds = {
        equip = 0,
        swing = 0,
        hit   = 0,
    },

    -- Tool
    requiresHandle = false,  -- Set true only if your tool genuinely needs a Handle

    -- Server-side guards (also set in Server.new)
    maxRange  = 16,   -- Reject hits beyond this distance (studs)
    maxDamage = 200,  -- Clamp damage to this ceiling
    rateLimit = 8,    -- Max activations accepted per player per second

}):Start()
```

> **Tip:** set `maxRange` in `Server.new()` slightly larger than `range` in `Client.new()` — e.g. `range = 8` + `maxRange = 14` — to give latency headroom without opening exploits.

---

## Diagnosing a broken weapon

If a weapon isn't showing, isn't firing, or is erroring, run this in Studio's **Command Bar**:

```lua
local WeaponKit = require(game.ReplicatedStorage.WeaponKit)
WeaponKit.diagnose(workspace.YourWeaponName) -- or script.Parent
```

Output example:
```
───────────────────────────────────────────────────
[WeaponKit] Diagnosis for: Workspace.BrokenSword
───────────────────────────────────────────────────
✓ Passing checks:
  ✓ No Handle, but RequiresHandle = false — that's fine with WeaponKit.
  ✓ Script found: 'Script'
  ✓ Tool is in a valid location: StarterPack
⚠ 1 issue(s) found:
  [1] No LocalScript inside the tool.
      → Client-side logic (animations, hit detection) will not run.
      → Fix: add a LocalScript that calls WeaponKit.Client.new():Start().
───────────────────────────────────────────────────
```

---

## How it works

```
Player clicks
      │
      ▼
LocalScript:_onActivate()
  ├── Gate on cooldown (task.delay always resets it — no stuck weapon)
  ├── Stop idle track, play swing track (Maid tracks both)
  ├── GetPartBoundsInBox → hit list (no Touched spam)
  ├── Per-swing cache (each model hit at most once)
  └── FireServer(hits)
            │
            ▼
      Server:_onFire()
        ├── Rate limit check
        ├── Distance validation (server measures independently)
        ├── Humanoid nil-check (R6 + R15 + NPC compatible)
        └── TakeDamage(clamp(damage, maxDamage))

On Unequip (any cause — button, death, game code):
  Maid:Destroy()
    ├── All RBXScriptConnections disconnected
    ├── All AnimationTracks stopped (track:Stop(0)) and destroyed
    └── Cooldown thread cancelled
```

---

## Common gotchas

**Animations don't play at all**  
→ Check your animation IDs are correct `rbxassetid://` strings and the animations are published.  
→ Make sure the animations are owned by you or your game's group — you can't load animations you don't own.

**Hitbox feels off (hits things behind you)**  
→ Tune `range` and `hitboxSize`. The hitbox is placed `range/2` studs in front of `HumanoidRootPart`. Increase `range` for longer reach; adjust `hitboxSize.X/Y` for width and height.

**I want a gun, not a sword**  
→ WeaponKit's hit detection is melee-only (spatial box in front of the character). For projectiles / raycasts, replace `Client:_detectHits()` with a raycast from the camera through the mouse position — then pass the hit model name back via the same remote.

**Tool from the Toolbox uses its own scripts**  
→ Delete the original scripts inside the toolbox weapon and replace them with the two example scripts. Keep the original `Handle` part and any meshes/textures.

---

## Project structure

```
roblox-weaponkit/
├── src/
│   └── WeaponKit/
│       ├── init.lua      Entry point + diagnose() utility
│       ├── Client.lua    LocalScript handler
│       ├── Server.lua    Script handler + server validation
│       ├── Maid.lua      Connection + instance cleanup
│       └── Config.lua    Defaults, merge, validation
├── example/
│   └── ExampleSword/
│       ├── LocalScript.client.lua
│       └── Script.server.lua
├── default.project.json  Rojo sync config
└── README.md
```

---

## Contributing

Pull requests are welcome. Open an issue first for larger changes.

---

## License

MIT
