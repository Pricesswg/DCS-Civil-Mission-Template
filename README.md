# DCS Civil Mission Template

Modular template for civil missions in DCS World — firefighting, mountain/sea
SAR, MedEvac, battlefield CASEVAC, police (chase and SWAT), tiered cargo
transport — in **pure native Lua** (no MIST/MOOSE/CTLD).

## Repository layout

```
Scripts/
  01_CivilCore.lua          Config + shared systems: mission scanner (zones,
                            polygon support, templates, ships), point pools,
                            player registry, hover trigger, airdrop tracking,
                            scoring, scenery kits, event director, admin menu
  10_CivilFirefighting.lua  Fires (severity 1-10), fire brigade trucks,
                            helicopter water ops, C-130 retardant + spotter
  20_CivilRescue.lua        SAR Mountain/Sea, MedEvac, CASEVAC, SAR vessels,
                            hospital ships (shared rescue engine)
  30_CivilPolice.lua        Police chase (pressure mechanic) + SWAT fast-rope
  40_CivilTransport.lua     Fixed mass tiers + supply airdrops
  50_CivilCommand.lua       Command center: game-master marker commands
dist/
  CivilMissionTemplate.lua  Single-file build; regenerate with tools/build.sh
tools/build.sh              Concatenates Scripts/ into the single-file build
docs/
  CONCEPT.md                Design brief (decisions and verifications)
  FEASIBILITY.md            Point-by-point feasibility check
  ME_SETUP_GUIDE.md         Extended Mission Editor guide
```

## Quick start

1. Add **CJTF Blue** to the blue coalition (all scripted spawns run under it).
2. Create the trigger zones from the checklist below.
3. Load `dist/CivilMissionTemplate.lua` with a single `DO SCRIPT FILE` action
   at MISSION START (or the five `Scripts/` files in order, core first).
4. In game: `F10 → Civil Missions` (the `Admin (test)` submenu starts any
   event manually).

## Mission Editor checklist — trigger zones

Matching is **by name prefix**: any zone whose name *starts with* the prefix
belongs to that pool (`CIVIL Fire Point Alpha`, `CIVIL Fire Point 12`, …).
No numbering rules. Zones can be **circular or polygon (quad)**. Modules
whose zones are missing are skipped gracefully — place only what you test.

| Zone name / prefix | Module | Qty | Placement |
|---|---|---|---|
| `CIVIL Fire Region` | Firefighting | 1 | large macro-region containing the fire points; enables the spotter role and the C-130 line drop |
| `CIVIL Fire Point …` | Firefighting | 3+ | curated ignition points: forest/fields, clear of buildings and roads |
| `CIVIL Fire Station …` | Firefighting | 1+ | fire brigade depots; trucks depart from the nearest one and drive "On Road" to the fire |
| `CIVIL Water Point …` | Firefighting | 1+ | helicopter water pickup, on a body of water with hover room |
| `CIVIL C130 Reload` | Firefighting | 1 | retardant reload apron, reachable by taxi. **User-built static area**: decorate it yourself (auto-dressing off by default) |
| `CIVIL SAR Mountain Region` | Rescue | 1 | macro-region for mountain SAR (spotter + vague-direction reference) |
| `CIVIL SAR Mountain Point …` | Rescue | 3+ | survivor spots reachable in a hover |
| `CIVIL SAR Sea Region` | Rescue | 1 | macro-region for sea SAR |
| `CIVIL SAR Sea Point …` | Rescue | 3+ | on OPEN water (a boat spawns there) |
| `CIVIL Vessel Spawn …` | Rescue | 1+ | rescue-boat harbors, on water. Balance rule: distance to the SAR points / 9 m/s should be slightly LONGER than the hover window (default 25 min ≈ 13.5 km) |
| `CIVIL Medevac Point …` | Rescue | 3+ | civilian casualty LZs (accidents, unsafe areas) |
| `CIVIL Casevac Point …` | Rescue | 3+ | battlefield extraction LZs. **User-built static areas**: dress them with your own battlefield assets |
| `CIVIL Hospital …` | Rescue | 1+ | on the actual hospital pads; delivery is ZONE-detected (still + low for 15 s), no FARP object needed. Auto-dressed with the medical-camp kit (`autoDress.hospitals = false` to disable) |
| `CIVIL Police Point …` | Police | 30-40 | ON real city crossroads, neighbor distance ≤ 1500 m (chase random walk) |
| `CIVIL SWAT Base` | Police | 1 | apron where the helicopter can land to board the team |
| `CIVIL SWAT Point …` | Police | 3+ | rooftops / urban LZs (rooftop infantry spawn TO TEST) |
| `CIVIL Cargo Point …` | Transport | 3+ | loading points on flat ground |
| `CIVIL Cargo Destination` | Transport | 1 | delivery zone (sling loads and supply airdrops) |

## Mission Editor checklist — units (matched by name prefix)

**Ships (regular units):**

| Prefix | Matched on | Role |
|---|---|---|
| `CIVIL Rescue Vessel …` | group name | steams to the approximate search area on sea SAR; a vessel holding 200 m / 60 s from the subject completes a SEA RESCUE credited to the identifying spotter |
| `CIVIL Hospital Ship …` | unit name | mobile delivery pad (detection relative to the ship: works underway; deck landing with big-ship mods TO TEST) + mother ship launching rescue boats when closer than the harbors (e.g. Perry, Tarawa) |

**Late-activated spawn templates (optional — hardcoded fallback types are
used when absent):**

| Group prefix | Spawned as | Fallback type |
|---|---|---|
| `CIVIL Survivor …` | mountain SAR / MedEvac subject | `Soldier M4` |
| `CIVIL Casualty …` | battlefield CASEVAC casualty | `Soldier M4` |
| `CIVIL Boat …` | sea SAR target | `ZWEZDNY` |
| `CIVIL Vessel …` | spawned rescue boat | `speedboat` |
| `CIVIL SWAT Team …` | SWAT squad | `Soldier M4` |
| `CIVIL Fugitive …` | police chase car | `LandRover_ah` |
| `CIVIL Fire Truck …` | fire brigade truck | `HEMTT TFFT` |

## The severity scale (1-10, all events)

Every event rolls a **severity 1-10** at spawn — one roll from which all its
parameters derive, announced in every report ("MedEvac severity 8"):

| Event | Severity drives |
|---|---|
| Wildfire | LIVE variable: grows on a per-fire cadence, spreads visually (1 effect → cluster, capped at 5 for performance), suppressed by drops/trucks, 0 = out |
| SAR / MedEvac / CASEVAC | criticality deadline (severity 10 = −40%), hover window (less time) and required hover time (more), score |
| Police chase | car speed, pressure build/decay rates, two-vehicle convoy at severity ≥ 8, score |
| SWAT | operators required (4→8), squad boarded at the base is sized for the worst active scenario, resolve time, score |
| Transport ("priority") | time to live of the load (priority 10 expires in 45 min) and score |

Score multiplier is anchored at `×(0.7 + 0.06·severity)` — severity 5 = ×1.

## Command center (game master)

A player in a **Game Master / Tactical Commander slot** (full F10 map, SRS;
native asset control with Combined Arms) acts as the emergency command
center by placing **F10 map markers** whose text starts with `civil` — the
commands work from any slot and the marker position IS the target position:

```
civil fire 7          civil medevac 9        civil casevac
civil sarm 5          civil sars             civil swat 8
civil chase 6         civil cargo heavy 9
civil spawn <template fragment> [count]
civil move <group fragment> [speed] [road]     (ground/ship, no CA needed)
civil cancel          civil director on|off    civil help
```

`civil director off` pauses the automatic event generation while the
commander directs the session. Optional player-name whitelist in
`CIV.Config.command.restrict`. Marker behavior from GM slots is TO VALIDATE
in-game (see FEASIBILITY).

Fire suppression (in severity units): helicopter drop −2, C-130 line
−0.25/s, retardant drum −2/container, fire brigade on scene −0.6/min. The
brigade rolls out of the nearest `CIVIL Fire Station` automatically, cutting
the air passes needed — players race the clock, not the trucks.

## Status

Structure complete, syntax-checked (Lua 5.1) and smoke-tested against a mock
of the DCS scripting API — both the modular and the single-file build.
**Not yet tested inside DCS**: the items needing in-game validation (cargo
mass types, "On Road" behavior, rooftop spawns, official C-130 airdrop
channels, deck landings, boat/vehicle type names) are listed with their
fallbacks in `docs/FEASIBILITY.md`.

Zone/template scanning, polygon area support and several utilities are
adapted from the 527th CSAR System by {527th} ienatom and {104WW} Price.
