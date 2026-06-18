# Incremental Collectible Fishing Simulator

A complete, modular, server-authoritative fishing game for Roblox, written in
strict-typed Luau. Built around a **Single Script Architecture (SSA)**: one
server `Script` and one client `LocalScript` bootstrap every module.

## A note on the build method

The original brief asked for the hierarchy to be created live in Studio via the
Roblox Studio MCP tools `create_object` / `set_script_source`. This repository
was developed in a **headless cloud container with no live Studio instance**
attached, so those tools are not reachable here. Instead the project is
delivered the way production Roblox teams version-control their games: as a
[Rojo](https://rojo.space) project. `default.project.json` declares the exact
instance tree the MCP calls would have produced, and each `.luau` file is the
exact source `set_script_source` would have written. Syncing the project into
Studio (`rojo serve` + the Rojo plugin, or `rojo build`) reproduces the live
hierarchy 1:1.

## Instance hierarchy (from `default.project.json`)

```
ReplicatedStorage
├── FishingNetwork              RemoteEvent
├── Shared/
│   └── LootManager             ModuleScript  -- loot config + weighted selection
└── Packages/
    └── ProfileService          ModuleScript  -- vendored MadStudioRoblox/ProfileService

ServerScriptService
├── ServerBootstrap             Script        -- SSA server entry point
└── Services/
    ├── DataService             ModuleScript  -- ProfileService-backed persistence
    └── FishingService          ModuleScript  -- server-authoritative loop

StarterPlayer/StarterPlayerScripts
├── ClientBootstrap             LocalScript    -- SSA client entry point
└── Controllers/
    └── FishingController       ModuleScript   -- rendering + slider minigame
```

## Systems

### `LootManager` (Shared)
- Catalogue of catchable items with `Weight` and `BaseValue`:
  - Common Fish — Weight 70, BaseValue 15
  - Uncommon Salmon — Weight 20, BaseValue 40
  - Rare Golden Trout — Weight 8.5, BaseValue 120
  - Legendary Kraken Tentacle — Weight 1.5, BaseValue 750
- `SelectLoot(luck)` implements `modifiedWeight = baseWeight * luck` (with a
  gentle rarity bias so luck favours rarer tiers), **normalises weights at
  runtime**, draws a single `math.random()` sample, and walks the cumulative
  distribution. At `luck = 1` the odds are exactly the base weights.
- `RollCatch(luck, valueMultiplier)` returns the full catch payload.

### `DataService` (Server)
- Built on **ProfileService** (session-locked, leak-free DataStore profiles).
- Template `{ Coins = 0, ActiveRod = "BasicRod", LuckLevel = 1, Inventory = {} }`.
- Calls `profile:Reconcile()` so returning players safely gain new fields.
- Transactional helpers: `GetProfile`, `GetData`, `AwardCoins`,
  `AddToInventory`, `SetActiveRod`, `SetLuckLevel`.
- `:ListenToRelease()` clears state and `player:Kick()`s on a lost session lock;
  profiles are `:Release()`d on `PlayerRemoving`.

### `FishingService` (Server, authoritative)
- `RequestCast`: validates the player has a loaded profile/rod, enforces a cast
  cooldown (anti-spam) and single-line-in-water rule, starts a rod-timed bite
  timer, and replies `FishBite`.
- `ResolveMinigame`: validates the cast was active and the result arrived in a
  realistic window (not before the bite, not after the deadline), consumes the
  session to block replays, rolls the catch with `LootManager`, persists via
  `DataService`, then fires `CatchResult` for UI + particles.

### `FishingController` (Client)
- Binds the player's rod `Tool.Activated` → fires `RequestCast` and spawns a
  local water splash.
- On `FishBite`, renders a slider minigame (a marker sweeping over a target
  zone) driven by `RunService.RenderStepped`.
- On input, reports success/failure via `ResolveMinigame`.
- On `CatchResult`, shows a reward toast and a rarity-tinted particle burst.

## Running it

1. Install [Rojo](https://rojo.space) (`cargo install rojo` or Aftman/Foreman).
2. From the repo root: `rojo serve`, then connect via the Rojo Studio plugin
   (or `rojo build -o FishingSimulator.rbxlx` for a one-shot place file).
3. Give players a `Tool` named with "Rod" (or with attribute `IsFishingRod =
   true`) so `FishingController` recognises it. Equip and activate to fish.
4. Enable **Studio Access to API Services** so ProfileService can use DataStores
   (it falls back to a mock store automatically in Studio when disabled).

## Credits
- [ProfileService](https://github.com/MadStudioRoblox/ProfileService) by loleris
  (MadStudioRoblox), vendored under `src/ReplicatedStorage/ProfileService.luau`.
