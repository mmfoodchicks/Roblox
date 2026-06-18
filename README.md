# Incremental Collectible Fishing Simulator

A complete, modular, server-authoritative incremental fishing game for Roblox,
written in strict-typed Luau. Built around a **Single Script Architecture
(SSA)**: one server `Script` and one client `LocalScript` bootstrap every
module.

The full gameplay loop is implemented end-to-end: **cast → skill minigame →
catch (server-rolled) → collect in inventory → sell for coins → buy rod & luck
upgrades → catch rarer fish faster.**

## A note on the build method

The original brief asked for the hierarchy to be created live in Studio via the
Roblox Studio MCP tools `create_object` / `set_script_source`. This repository
was developed in a **headless cloud container with no live Studio instance**
attached, so those tools are not reachable here. Instead the project is
delivered the way production Roblox teams version-control their games: as a
[Rojo](https://rojo.space) project. `default.project.json` declares the exact
instance tree the MCP calls would have produced, and each `.luau` file is the
exact source `set_script_source` would have written. Syncing into Studio
(`rojo serve` + the Rojo plugin, or `rojo build`) reproduces the hierarchy 1:1.

All 17 source files have been verified to **parse and compile** with the
official Luau toolchain (`luau-compile`). The map, the rod Tool, and every UI
are generated procedurally in code, so the game has **no binary asset
dependencies** beyond the vendored ProfileService.

## Instance hierarchy (from `default.project.json`)

```
ReplicatedStorage
├── FishingNetwork              RemoteEvent    -- cast / bite / resolve / catch
├── DataNetwork                 RemoteEvent    -- server → client data snapshots
├── ShopFunction                RemoteFunction -- buy / equip / upgrade / sell
├── Shared/
│   ├── LootManager             ModuleScript   -- loot catalogue + weighted roll
│   └── GameConfig              ModuleScript   -- rods + luck curve (shared truth)
└── Packages/
    └── ProfileService          ModuleScript   -- vendored MadStudioRoblox/ProfileService

ServerScriptService
├── ServerBootstrap             Script         -- SSA server entry point
└── Services/
    ├── DataService             ModuleScript   -- ProfileService persistence + replication
    ├── FishingService          ModuleScript   -- authoritative fishing loop
    ├── ShopService             ModuleScript   -- authoritative economy (buy/sell)
    ├── LeaderstatsService      ModuleScript   -- Coins / Caught on the leaderboard
    ├── RodToolBuilder          ModuleScript   -- builds the rod Tool → StarterPack
    └── MapBuilder              ModuleScript   -- procedural map generation

StarterPlayer/StarterPlayerScripts
├── ClientBootstrap             LocalScript     -- SSA client entry point
└── Controllers/
    ├── UiUtil                  ModuleScript    -- shared GUI helpers (not Init'd)
    ├── DataController          ModuleScript    -- client data cache + Changed signal
    ├── HudController           ModuleScript    -- coins / rod / luck HUD + buttons
    ├── ShopController          ModuleScript    -- rod & luck shop window
    ├── InventoryController     ModuleScript    -- catch log + Sell All
    └── FishingController       ModuleScript    -- casting + slider minigame + FX
```

## Gameplay & economy

- **Catch** fish via the cast → bite → slider-minigame loop. Outcomes are rolled
  on the server with `LootManager`; the client only reports success/failure.
- Catches accumulate in your **inventory** as unsold records (each remembers the
  coin value at catch time).
- **Sell All** (inventory window) converts the haul to **coins**.
- Spend coins in the **shop**: unlock/equip better **rods** (faster bites, more
  luck, higher value) and buy **luck levels** (geometric cost curve) to bias the
  roll toward rarer fish.
- **Coins** and **Caught** appear on the Roblox leaderboard.

## Systems

### `LootManager` (Shared)
- Catalogue: Common Fish (W70/V15), Uncommon Salmon (W20/V40), Rare Golden Trout
  (W8.5/V120), Legendary Kraken Tentacle (W1.5/V750).
- `SelectLoot(luck)` implements `modifiedWeight = baseWeight * luck` with a gentle
  rarity bias, **normalises weights at runtime**, draws one `math.random()`
  sample, and walks the cumulative distribution. At `luck = 1` the odds equal the
  base weights.

### `GameConfig` (Shared)
- Single source of truth for the 4 rods and the luck upgrade curve, with helpers
  `GetRod`, `GetSortedRods`, `GetLuckMultiplier`, `GetLuckUpgradeCost`. Used by
  both server (authoritative) and client (UI), so they can never disagree.

### `DataService` (Server)
- Built on **ProfileService** (session-locked, leak-free DataStore profiles).
- Template `{ Coins, ActiveRod, LuckLevel, Inventory, OwnedRods, Stats }`.
- `profile:Reconcile()` back-fills new fields for returning players.
- Validated mutators: `AwardCoins`, `AddToInventory`, `ClearInventory`,
  `SetActiveRod`, `SetOwnedRod`, `SetLuckLevel` — each **replicates** the new
  state to the owning client (DataNetwork) and raises a server `Changed` signal.
- `:ListenToRelease()` clears state and `player:Kick()`s on a lost session lock;
  profiles are `:Release()`d on `PlayerRemoving`.

### `FishingService` (Server, authoritative)
- `RequestCast`: validates loaded profile/rod, enforces a cast cooldown and the
  single-line rule, starts a rod-timed bite, replies `FishBite`.
- `ResolveMinigame`: validates the cast was active and the result arrived in a
  realistic window (after the bite, before the deadline), consumes the session to
  block replays, rolls with `LootManager`, stores the catch via `DataService`,
  and replies `CatchResult` for UI + particles.

### `ShopService` (Server, authoritative)
- `ShopFunction` handler for `BuyRod`, `EquipRod`, `BuyLuck`, `SellAll`. Every
  price check and coin movement happens here against `GameConfig`; wrapped in
  `pcall` so a malformed request can never hang the RemoteFunction.

### `MapBuilder` (Server)
- Procedurally builds the scene at boot — **no binary assets**, seeded for
  reproducibility: grass island + sand beach, a real **Terrain water** lake
  (`Terrain:FillBlock`), a wooden dock with posts/railing and an
  `IsFishingSpot`-tagged end marker, a `SpawnLocation`, trees, shoreline rocks,
  and tuned Lighting/Atmosphere/Sky. Idempotent `:Build()`.

### `RodToolBuilder` (Server)
- Constructs the **Fishing Rod** Tool from welded parts (grip, shaft, tip, line),
  tags it `IsFishingRod`, and seeds it into `StarterPack` so every player spawns
  holding a rod.

### Client controllers
- `DataController` caches authoritative snapshots and exposes a `Changed` signal.
- `HudController` shows coins / unsold value / luck / rod and opens the windows
  (`E` = shop, `Q` = inventory).
- `ShopController` / `InventoryController` render from `GameConfig` + the cached
  snapshot and route intents through `ShopFunction`.
- `FishingController` binds the rod `Tool.Activated`, plays the
  `RenderStepped`-driven slider minigame, and renders water-splash + rarity-tinted
  catch particles.

## Running it

1. Install [Rojo](https://rojo.space) (`aftman install` reads `aftman.toml`, or
   `cargo install rojo`).
2. `rojo serve` and connect via the Rojo Studio plugin, **or**
   `rojo build -o FishingSimulator.rbxlx` for a one-shot place file.
3. Press Play. You spawn on the dock holding a rod — click to cast, click again
   to hook in the minigame, then sell your catch and buy upgrades.
4. Enable **Studio Access to API Services** so ProfileService can use DataStores
   (it auto-falls back to a mock store in Studio when disabled).

## Credits
- [ProfileService](https://github.com/MadStudioRoblox/ProfileService) by loleris
  (MadStudioRoblox), vendored under `src/ReplicatedStorage/ProfileService.luau`.
