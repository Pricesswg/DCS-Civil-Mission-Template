# DCS Civil Mission Template

Modular template for civil missions in DCS World — firefighting, mountain/sea
SAR, MedEvac, police (chase and SWAT), tiered cargo transport — in **pure
native Lua** (no MIST/MOOSE/CTLD).

## Structure

```
Scripts/
  01_CivilCore.lua          Config + shared systems: mission scanner (zones,
                            polygon support, late-activated templates), point
                            pools, player registry, hover trigger, scoring,
                            scenery kits, event director, admin menu
  10_CivilFirefighting.lua  Fires, helicopter water ops, C-130 retardant + spotter
  20_CivilRescue.lua        SAR Mountain, SAR Sea, MedEvac (shared engine)
  30_CivilPolice.lua        Police chase (pressure mechanic) + SWAT fast-rope
  40_CivilTransport.lua     Fixed mass tiers with heavy-lift gate
dist/
  CivilMissionTemplate.lua  Single-file build (all of the above merged);
                            regenerate with tools/build.sh after edits
tools/
  build.sh                  Concatenates Scripts/ into the single-file build
docs/
  CONCEPT.md                Design brief (decisions and verifications)
  FEASIBILITY.md            Point-by-point feasibility check
  ME_SETUP_GUIDE.md         Mission Editor setup guide
```

## Quick start

1. Add CJTF Blue to the blue coalition (all scripted spawns run under it).
2. Create the trigger zones listed in `docs/ME_SETUP_GUIDE.md`
   (name-prefix matching, e.g. `CIVIL Fire Point Alpha`; circular or
   polygon zones both work).
3. Load `dist/CivilMissionTemplate.lua` with a single `DO SCRIPT FILE`
   action at MISSION START (or the five `Scripts/` files in order,
   `01_CivilCore.lua` first).
4. In game: `F10 → Civil Missions`.

Optional: place late-activated template groups (`CIVIL Survivor`,
`CIVIL Boat`, `CIVIL SWAT Team`, `CIVIL Fugitive`) to control exactly what
gets spawned; hardcoded fallback types are used otherwise.

## Status

Initial structure complete, syntax-checked (Lua 5.1) and smoke-tested against
a mock of the DCS scripting API — both the modular and the single-file build.
**Not yet tested inside DCS**: the items that need empirical in-game testing
are listed in `docs/FATTIBILITA.md` (⚠️ section) together with their
fallbacks.

Zone/template scanning, polygon area support and several utilities are
adapted from the 527th CSAR System by {527th} ienatom and {104WW} Price.
