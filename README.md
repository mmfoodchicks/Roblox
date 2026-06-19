# Incremental Collectible Fishing Simulator

A complete, modular, server-authoritative Roblox fishing game written in
strict-typed Luau, built around a **Single Script Architecture (SSA)** — one
server `Script` and one client `LocalScript` bootstrap every module.

**Core loop:** explore a huge island → fish at the water's edge (skill minigame)
→ carry your catch to the **market under the mountain** → sell for coins → buy
rods, luck, crates & pets from the merchant stands → catch rarer fish. Plus a
**mega-hard parkour** up the mountain to a summit chest, a **teleport hub**, and
a full **Robux monetization** layer.

## Build method

Developed in a headless container (no live Studio), so it's delivered as a
[Rojo](https://rojo.space) project rather than via the Studio MCP tools:
`default.project.json` declares the instance tree and each `.luau` is the script
source. Syncing into Studio reproduces the hierarchy 1:1. **The entire map, the
rod, every UI and the parkour are generated procedurally in code — no binary
assets** beyond the vendored ProfileService. All 31 source files are verified to
parse/compile with the official Luau toolchain.

## Instance hierarchy (`default.project.json`)

```
ReplicatedStorage
├── FishingNetwork / DataNetwork / CrateNetwork        RemoteEvents
├── ShopFunction / CrateFunction / PetFunction / DailyFunction   RemoteFunctions
├── Shared/  LootManager · GameConfig · MonetizationConfig · CrateConfig
│            · DailyConfig · TeleportConfig
└── Packages/ ProfileService

ServerScriptService/ServerBootstrap  (+ Services/)
  DataService · FishingService · ShopService · BoostService · PetService
  · CrateService · DailyRewardService · MonetizationService · LeaderstatsService
  · RodToolBuilder · MapBuilder

StarterPlayer/StarterPlayerScripts/ClientBootstrap  (+ Controllers/)
  UiUtil · DataController · ShopController · InventoryController · StoreController
  · CrateController · DailyController · SprintController · MerchantController
  · HudController · FishingController
```

## The world (procedural — `MapBuilder`)

- **Huge island** (radius 180) with a sand beach, real **Terrain water** lake,
  the main dock + **6 mini docks** ringing the coast, and seeded trees/rocks.
- A massive **Terrain rock mountain** (115 base, 175 tall) dominating the island.
  It's too steep to free-climb (`MaxSlopeAngle` is lowered on spawn), so the
  parkour is the only way up.
- A **walk-through tunnel** carved through the mountain base opening into a
  **market cavern** lit by lamps.
- The cavern is the **market**: five merchant stands you walk up to (Proximity
  prompt, press **E**) — Fish Market (sell), Rod & Luck Smith, Crate Trader,
  Premium Bazaar, Daily Rewards. There are **no HUD shop buttons** by design.
- A **mega-hard floating-block parkour** that starts at the +Z shore, spirals all
  over the map while climbing, and ends on a **summit chest** (1200 coins + 1 key,
  5-min cooldown). Jumps are tuned just-reachable; **Shift to sprint** helps.
- A **teleport hub** by spawn — portals to your other games (set PlaceIds).

## Gameplay & economy

- **Fishing** must happen at the water's edge: `FishingService` ray-samples for
  Terrain water under the player before allowing a cast (no fishing on land).
- **Catch** via cast → bite → slider minigame. The roll is server-side
  (`LootManager`); the client only reports success/failure and plays FX.
- Catches go to your **inventory** (capped at 1500 to protect the save); **sell**
  at the Fish Market for coins.
- Spend coins on **rods** and **luck levels** (geometric cost). **Coins** &
  **Caught** show on the leaderboard.

## Systems (highlights)

- **`LootManager`** — 4 fish (Common→Legendary), `modifiedWeight = baseWeight ×
  luck`, runtime-normalised weighted roll.
- **`GameConfig`** — single source of truth for rods + the luck curve.
- **`DataService`** — ProfileService persistence (session-locked, `:Reconcile()`),
  validated mutators that **replicate** to the owning client and raise `Changed`.
- **`FishingService`** — authoritative cast/bite/resolve with cooldown, replay
  protection, water-proximity check.
- **`ShopService`** — authoritative `BuyRod`/`EquipRod`/`BuyLuck`/`SellAll`.
- **`BoostService`** — the one hub that stacks **all** luck/coin multipliers
  (passes, Premium, equipped pets, timed potions).
- **Gacha (`CrateService`/`PetService`/`CrateConfig`)** — 3 crates roll pets/
  coins/keys/potions with a client reveal animation; **pets** give stacking
  passive boosts when equipped.
- **`DailyRewardService`** — 7-day escalating streak (auto-opens on join).
- **`MonetizationService`** 💰 — game passes, dev products, Premium, and an
  **idempotent `ProcessReceipt`**; runs the Auto Fisher perk.
- **`MerchantController`** — opens the right shop UI when you trigger a stand's
  ProximityPrompt.

## Running it in Studio

1. Install [Rojo](https://rojo.space) (`rojo.exe` from releases, or `aftman
   install` / `cargo install rojo`).
2. `rojo serve` → connect via the Rojo Studio plugin, **or** `rojo build -o
   FishingSimulator.rbxlx` and open that file directly.
3. Enable **Game Settings → Security → Studio Access to API Services** so
   ProfileService can use DataStores (it auto-uses a mock store otherwise).
4. **Play.** You spawn on the beach with a rod. Fish at the water, then walk into
   the mountain base to reach the market.

> The map generates at *runtime* — the Workspace looks empty in edit mode and
> populates on Play. That's expected.

## Publishing checklist

1. **File → Publish to Roblox** (create the place).
2. **Game Settings → Security:** enable **Studio Access to API Services** and
   **Allow Third Party Teleports** (for the hub).
3. **Monetization** (`create.roblox.com` → game → Monetization):
   - Create **Game Passes**: VIP, Lucky Charm, Auto Fisher, +2 Pet Slots.
   - Create **Developer Products**: 1k/10k/100k coin packs, Luck Potion, 5 Keys,
     25 Keys, Open Mythic Crate.
   - Paste each numeric **Id** into `src/Shared/MonetizationConfig.luau`
     (`Id = 0` = "Unavailable" until set). Set a Robux price on each.
4. **Teleport hub:** paste your other games' **PlaceIds** into
   `src/Shared/TeleportConfig.luau` (`PlaceId = 0` shows "Coming soon").
   Teleporting only works in the published game, not in Studio.
5. Re-sync/rebuild and publish. Revenue flows via pass sales, product sales, and
   Premium Payouts (cashable through DevEx).

## Credits
- [ProfileService](https://github.com/MadStudioRoblox/ProfileService) by loleris,
  vendored under `src/ReplicatedStorage/ProfileService.luau`.
