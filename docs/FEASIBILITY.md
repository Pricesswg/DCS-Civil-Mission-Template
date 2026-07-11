# Feasibility check: point by point

Technical cross-check of the concept (`docs/CONCEPT.md`) against the
implementation in `Scripts/`. Legend: [OK] confirmed and implemented, [TO TEST] implemented but needs
in-game testing, [FIX] to correct/decide.

> Updated for v0.2: 5-file structure (core + one file per intervention type)
> plus single-file build (`tools/build.sh` -> `dist/CivilMissionTemplate.lua`);
> zone/template scanner via `env.mission` adopted from the 527th CSAR System;
> spawns under CJTF Blue; rescue intel model (exact coordinates only through
> a spotter aircraft).

## Confirmed and implemented [OK]

| Concept point | Outcome | Where |
|---|---|---|
| `S_EVENT_LAND` only on airbase/FARP/ship: zone-based delivery | [OK] Correct. Delivery detected as still/low inside the zone for N s | `20_CivilRescue.lua` (delivery loop) |
| Hover as `getVelocity`/`getPoint` polling, not an AI task | [OK] No missing API, all native | `01_CivilCore.lua` (`CIV.Hover`) |
| Floor time T + malus B (never a bonus) + window with narrative failure | [OK] `rate = 1/(1+B*instability)`, progress frozen outside the envelope | `CIV.Hover` |
| No scripted weather malus (wind already acts on the flight model) | [OK] The malus measures real deviation, nothing else | `CIV.Hover` |
| Per-unit/group state, never global (parallel events) | [OK] Hover sessions, fires, chases, loads: all keyed by id/unit | all modules |
| One-shot randomization at event start (no per-tick jitter) | [OK] `CIV.randBetween` called only at event creation | firefighting, police |
| Macro-region + curated point pools with min distance | [OK] Name-prefix matching, `pick` excludes occupied points | `CIV.Pool` |
| No runtime trigger zone creation (API does not exist) | [OK] ME zones + config tables only | everywhere |
| `coalition.addStaticObject` with native `mass`/`canCargo` | [OK] Implemented; mass change = despawn+respawn (no runtime setter) | `CIV.spawnCargo`, `40_CivilTransport.lua` |
| Fixed tiers + heavy-lift gate + capacity-threshold label | [OK] Gate on `CIV.typesPresent` (updated on `S_EVENT_BIRTH`, covers MP slot changes) | `40_CivilTransport.lua` |
| Tier change via F10 with 20-30 s delay | [OK] 25 s in config, despawn->wait->respawn | `40_CivilTransport.lua` |
| Hand-maintained type->capacity table (API does not expose it) | [OK] Confirmed: the descriptor gives `massEmpty`/`fuelMassMax`, not external load | `CIV.Config.capacity` |
| Native embark/disembark = AI-to-AI, unusable | [OK] Fast-rope = hover + scripted `coalition.addGroup` | `30_CivilPolice.lua` |
| SWAT squad sized at BOARDING, not at insertion | [OK] Per-unit state fixed at the base | `30_CivilPolice.lua` |
| C-130: ground reload (logical state) + line drop 150-250 m | [OK] AGL band in config, drop applied along the path for N s | `10_CivilFirefighting.lua` |
| C-130 spotter: coordinates + F10 marks | [OK] Native `markToCoalition` + `circleToAll` circles (CSAR-style). Spotting is now the ONLY source of exact rescue coordinates | firefighting, rescue |
| `effectSmokeBig`/`effectSmokeStop` with per-zone state | [OK] Preset scales with intensity; stopping needs the *name* (param since ~2.7.10) | `10_CivilFirefighting.lua` |
| `radioTransmission` beacon with coordinate fallback | [OK] Implemented with `pcall` + automatic fallback; off by default (needs the `.ogg` in the .miz). Plus CSAR-style smoke on request | `20_CivilRescue.lua` |
| Scoring: pure function + difficulty weights fixed now + live broadcast | [OK] Stateless `CIV.Score.compute`; weights in config; `outTextForCoalition` | `CIV.Score` |
| "On Road" pathfinding unreliable (known bug) | [OK] Implemented WITH a watchdog: route re-kick after 45 s stalled, "Off Road" fallback on the 2nd stall | `30_CivilPolice.lua` |
| Dressed areas: passive statics in fixed ME zones, no flatness check | [OK] Kits `medical_camp` / `c130_loading_area` / `refugee_camp` | `CIV.Dressing` |
| MedEvac: criticality as a score variable | [OK] Quality = remaining criticality fraction; expired deadline = deceased | `20_CivilRescue.lua` |
| Reuse of `527th_CSARSystem.lua` | [OK] Adopted: `env.mission` scanner (polygon zones + properties + templates), map circles, MGRS/DDM, subject smoke, approximate-intel circle, atan2/bearing, collision-free ids | `01_CivilCore.lua`, `20_CivilRescue.lua` |

## Implemented but NEEDS in-game testing [TO TEST]

These match the concept's list; each item ships with an escape route.

1. **Cargo on open water**: behind the `fire.usePhysicalCargo = false` flag
   (default: logical load + F10 drop, robust). Enable only after ME testing.
2. **Slung cargo delivery detection via position polling**: verify that the
   hooked object updates `getPoint()` and survives the drop. Fallback:
   "zone + nearest player" delivery (already used by rescue).
3. **"On Road" on the chosen map's real crossroads**: watchdog and fallback
   included, but the 30-40 point pool must be validated crossing by crossing.
   The same watchdog covers the FIRE TRUCKS driving from station to fire;
   validate the station->fire-points road runs too, and the truck fallback
   type name (`HEMTT TFFT`).
   Note on fire visuals: severity spawns up to `fire.severity.maxEffects`
   (default 5) simultaneous `effectSmokeBig` instances per fire; with
   `maxActive = 3` fires that is 15 effects worst case: verify the frame
   cost on the group's servers before raising the caps.
4. **Infantry spawn on rooftop meshes (SWAT)**: if it fails, move the LZ to
   street level.
5. **Cargo types accepting a custom `mass`**: the types in
   `CIV.Config.cargo.tiers` (`uh1h_cargo`, `container_cargo`,
   `iso_container*`) must be confirmed in the ME: some types have fixed mass.
6. **Fallback type names** (`ZWEZDNY`, `LandRover_ah`, dressing statics):
   they vary per map/version; mitigation: use the late-activated templates
   (`CIVIL Survivor`, etc.) which remove the problem entirely; kit spawns run
   in `pcall`, a wrong type logs and does not break the rest.
7. **`.ogg` beacon + homing**: finicky as per the concept: off by default.
8. **`Hold` task to stop the fugitive**: if it does not stop a ground group,
   alternative: a single-point route at the current position.
9. **Hospital-ship deck landing (big-ship mods)**: delivery detection is
    measured relative to the ship (horizontal distance, deck height band,
    relative speed), so it works even while the ship is underway; but the
    PHYSICAL deck landing depends on the mod's deck collision mesh, exactly
    like the rooftop case: TO TEST with the chosen mod. If the deck is not
    landable, a stable low hover over the deck also satisfies the check.
10. **AI vessel routing on open water**: vessels get a single waypoint
    toward the search area; ship pathfinding on open water is generally
    reliable (no known "On Road"-class bug), but shallow water or islands
    between vessel and target can stall them: place rescue vessels, harbor
    spawn zones and mother ships with a clear run to the SAR sea regions.
    Also validate the stock boat type name (`fallbackTypes.rescueBoat`,
    default `speedboat`) or place a `CIVIL Vessel` late-activated template.
11. **C-130 airdrop detection (official module)**: the scripting API cannot
   read the module's cargo bay, and how the official module exposes airdrops
   is undocumented. Two parallel detection channels are implemented
   (shared `CIV.Airdrop` consumer system): S_EVENT_SHOT weapon tracking
   (Hercules-mod style) and `world.searchObjects` scans for foreign cargo
   objects (near active fires for retardant, inside the destination zone
   for supplies). Differentiated crates: drums/barrels = retardant
   (`fire.airdrop.containerTypes`), crates = supply delivery
   (`cargo.airdrop.containerTypes`); until the real type names are
   validated, `matchAnyObject = true` lets the impact location decide.
   Worst case (drops not visible to scripting at all) the F10 line-drop
   flow still covers the C-130 firefighting role entirely.

**Aviation additions (v0.3)**: the medical transfer, traffic watch and
firewatch mechanics reuse already-listed primitives (pad boarding, player
position polling, zone containment), so they add no new API risk. The
skydive drop uses `atmosphere.getWind` to compute the drift: the call is
standard scripting API, but verify on the chosen map that the returned
vector matches the mission weather (some weather presets report calm winds
at low altitude); with zero wind the jumpers simply land where released,
which still plays fine.

## Corrections / clarifications vs the concept

- **`world.setPersistenceHandler`**: I found NO evidence this exists as a
  documented native API: verify before relying on it for the persistent
  leaderboard. The other two options (server-side hook; `dcs.log` parser)
  are solid. Meanwhile `CIV.Score.award` already writes a parsable line to
  `dcs.log` for every task (`SCORE|player|type|points|q|t`): option 3 is
  ready on the mission side at zero cost.
- **Polygon (quad) trigger zones**: `trigger.misc.getZone` returns only
  center+radius, BUT zones (with `verticies` and properties) are readable
  from **`env.mission.triggers.zones`**, exactly as the field-proven 527th
  CSAR System does. The template uses this scanner: **zones may be circular
  or polygon**.
- **Zone enumeration**: with the `env.mission` scanner, matching is by
  **name prefix** ("CSAR Zone ..." style): no mandatory gap-free 01..N
  numbering.
- **Template spawning**: adopted the "CSAR Pilot" pattern: late-activated
  groups in the ME cloned at runtime, with hardcoded fallback types when the
  template is missing.
- **Spawn country**: spawns run under **CJTF Blue** (combined faction, no
  per-country unit restrictions). CJTF Blue must be added to the blue
  coalition in the ME.
- **F10 map zone coloring**: natively supported: `circleToAll` for circular
  zones and `markupToAll` (freeform shape 7, one point per vertex) for the
  real perimeter of polygon zones, both per-coalition with border + fill
  colors and removable with `removeMark`. Implemented as two layers: static
  theme-area overlays at mission start and per-event zone highlighting while
  an event is active (`CIV.Config.marks.regions` / `marks.events`).
  `markupToAll` calls run in `pcall` with a bounding-circle fallback for
  older DCS versions.
- **Rescue intel model (v0.2 change)**: exact coordinates are never
  broadcast automatically. Initial report = rough direction (distance
  rounded to 5 km + cardinal) from the scenario region (or nearest hospital)
  plus an approximate search circle on the F10 map with the subject inside
  but off-center (CSAR opponent-intel pattern). Exact position + point mark
  are released only when a player airplane (C-130) enters the scenario
  region or flies within `rescue.intel.spotterDetectRadius` of the subject.
  Survivor smoke on request remains as the close-range aid.

12. **Game-master marker commands**: `S_EVENT_MARK_ADDED`/`MARK_CHANGE`
    are native and documented, but two things need an in-game pass: whether
    marks placed from a Game Master / Tactical Commander slot deliver the
    events with a readable initiator (affects the optional player-name
    whitelist: `allowUnidentified` covers the nil case), and whether the
    mark text arrives on ADDED or only on the first CHANGE after typing
    (both are handled). The `civil move` command intentionally supports
    ground/ship groups only.

## Severity generalization (v0.2)

The fire severity scale (1-10) is generalized to every event type as the
single one-shot roll from which all event parameters derive (an extension of
the concept's "randomize once at event start" rule, made player-readable).
Fires keep it as a LIVE variable; everywhere else it is a static descriptor:
rescue deadlines/hover envelope, chase speed/pressure/convoy, SWAT squad
requirement/resolve time, transport priority/TTL. The score multiplier
`0.7 + 0.06 * severity` is ANCHORED NOW (severity 5 = x1.0), per the same
rule as the difficulty weights: changing it later skews history.

## Still-open decisions (unchanged from the concept)

- Leaderboard: live vs consolidated at mission end (the `SCORE|` lines in
  `dcs.log` already support both via an external parser).
- Final kg values for the tiers and the capacity table.
- Black Hawk module: verify the exact type name and what it supports (add it
  to `CIV.Config.capacity` with the correct type name).
- Development/test priority and C-130 realism to confirm with the group.
