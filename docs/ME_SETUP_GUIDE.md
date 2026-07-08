# Mission Editor setup guide

How to wire the template into a mission. Everything is pure native Lua: no
MIST/MOOSE/CTLD to load.

## 1. Coalition setup

Add **CJTF Blue** (Combined Joint Task Force Blue) to the blue coalition in
the mission options: all scripted spawns run under it, so there are no
per-country unit restrictions. If you prefer another country, change
`CIV.Config.countryId` at the top of `01_CivilCore.lua`.

## 2. Loading the scripts

Two options:

**A) Single file (recommended for normal use)**: one `MISSION START`
trigger with a single `DO SCRIPT FILE` action:

```
dist/CivilMissionTemplate.lua
```

**B) Modular (for development/testing)**: 5 `DO SCRIPT FILE` actions in
this order (core first, the others in any order; unused modules can simply
be omitted):

```
Scripts/01_CivilCore.lua        <- ALWAYS, first
Scripts/10_CivilFirefighting.lua
Scripts/20_CivilRescue.lua      (SAR mountain/sea + MedEvac + CASEVAC)
Scripts/30_CivilPolice.lua      (chase + SWAT)
Scripts/40_CivilTransport.lua
Scripts/50_CivilCommand.lua     <- LAST (game-master marker commands)
```

After any change inside `Scripts/`, regenerate the single file with
`tools/build.sh` (or by manually concatenating the 5 files in order into one
.lua).

## 3. Trigger zones to create in the ME

Matching is **by name prefix** (527th CSAR style): any zone whose name
STARTS with the prefix belongs to that pool: e.g. `CIVIL Fire Point Alpha`,
`CIVIL Fire Point 12`, `CIVIL Fire Point Forest`. No consecutive numbering
required. Zones can be **circular or polygon (quad) zones**: vertices and
properties are read from `env.mission`.

| Prefix / zone name | Use | Placement notes |
|---|---|---|
| `CIVIL Fire Region` | firefighting macro-region | large; enables the spotter and the C-130 line drop |
| `CIVIL Fire Point ...` | fire ignition points | forest/fields, away from buildings and roads |
| `CIVIL Fire Station ...` | fire brigade depots | trucks depart from the nearest one and drive "On Road" to the fire |
| `CIVIL Water Point ...` | helicopter water pickup | on a body of water, with maneuvering room |
| `CIVIL C130 Reload` | C-130 retardant reload | apron reachable on the ground. USER-BUILT static area: decorate it yourself (`autoDress.c130Reload = false` by default) |
| `CIVIL SAR Mountain Region` + `CIVIL SAR Mountain Point ...` | mountain SAR | points reachable in a hover |
| `CIVIL SAR Sea Region` + `CIVIL SAR Sea Point ...` | sea SAR | points on OPEN water (a boat spawns there) |
| `CIVIL Police Point ...` | chase | 30-40 points ON real crossroads, neighbor distance <= 1500 m |
| `CIVIL SWAT Base` | team boarding | apron where the helicopter can land |
| `CIVIL SWAT Point ...` | SWAT scenarios | rooftops / urban LZs (rooftop spawn TO TEST) |
| `CIVIL Cargo Point ...` | cargo loading points | flat ground |
| `CIVIL Cargo Destination` | cargo delivery | single destination zone |
| `CIVIL Medevac Point ...` | casualty recovery | "hostile"/accident LZs |
| `CIVIL Casevac Point ...` | battlefield casualty extraction | battlefield LZs (same flow as MedEvac, hostile skin). USER-BUILT static areas: dress them with your own battlefield assets |
| `CIVIL Hospital ...` | hospital pads | on the actual pad; auto-dressed with the medical camp kit (`autoDress.hospitals = false` to disable); delivery is ZONE-detected (still+low), no FARP needed |
| `CIVIL Vessel Spawn ...` | rescue boat harbors | on open water near a harbor. BALANCE RULE: place them so that distance / boat speed (9 m/s ~ 17.5 kts) is slightly LONGER than the sea SAR hover window (default 25 min ~ 13.5 km): the boat is the second chance, not a competitor to the helicopter |

Prefixes are configurable in `CIV.Config.zones` (top of `01_CivilCore.lua`).

## 4. Optional spawn templates (CSAR Pilot style)

**Late-activated** groups placed in the ME: if they exist, spawns are cloned
from them (units, liveries, country) instead of using the hardcoded fallback
types. Group-name prefix matching.

For variety, place SEVERAL templates with the same prefix (`CIVIL Boat 1`,
`CIVIL Boat 2`, ... or any suffix, numbers are optional): every spawn picks
one of the matching templates at random. Useful to rotate boat types, car
types, uniforms and so on without touching the config.

**Rescue scenes** (optional): MedEvac and CASEVAC also dress the casualty
site with a scene group. Scene type is picked at random from the
scenario's list in `rescue.scenes.byScenario`, then a random variant among
the matching templates:

| Group prefix | Scenario | Suggested content |
|---|---|---|
| `CIVIL Scene Rescue ...` | MedEvac | ambulance vehicle + 2 medics |
| `CIVIL Scene Accident ...` | MedEvac | crashed cars, bystanders |
| `CIVIL Scene Battlefield ...` | CASEVAC | battlefield props, soldiers |

Each scene is ONE ground group (DCS ground groups can mix vehicles and
infantry). It spawns ~15 m from the casualty so the hover center stays
clean, and it is cleared `rescue.scenes.despawnDelay` seconds (default 300,
5 minutes) after the event ends. No template with that prefix = no scene,
the event runs anyway.

| Group prefix | Use | Fallback if absent |
|---|---|---|
| `CIVIL Survivor ...` | mountain SAR missing person / MedEvac casualty (ground) | `Soldier M4` |
| `CIVIL Casualty ...` | battlefield CASEVAC casualty (ground) | `Soldier M4` |
| `CIVIL Boat ...` | sea SAR target (ship) | `ZWEZDNY` |
| `CIVIL Vessel ...` | spawned rescue boat (ship) | `speedboat` |
| `CIVIL SWAT Team ...` | SWAT squad (ground; unit count scaled at insertion) | `Soldier M4` |
| `CIVIL Fugitive ...` | fleeing car (vehicle) | `LandRover_ah` |
| `CIVIL Fire Truck ...` | fire brigade truck (vehicle) | `HEMTT TFFT` |

## 4b. Ships (regular units placed in the ME, matched by name prefix)

| Prefix | Matched on | Behavior |
|---|---|---|
| `CIVIL Rescue Vessel ...` | GROUP name | when a sea SAR starts, the nearest free vessels (up to `rescue.vessels.perEvent`) steam toward the APPROXIMATE search area; once a spotter identifies the subject they steer to the exact point. A vessel holding within 200 m of the subject for 60 s completes a SEA RESCUE: the identifying spotter (C-130) gets the score |
| `CIVIL Hospital Ship ...` | UNIT name | double role: (1) MOBILE delivery pad: casualty delivery detected relative to the ship (distance, deck height band, RELATIVE speed, works while underway; deck landing with big-ship mods TO TEST); (2) MOTHER SHIP: if it is closer to a sea SAR than the harbors, spawned rescue boats launch from it (e.g. a Perry or a Tarawa) |

If fewer pre-placed vessels than `perEvent` are free, stock boats are
spawned from the nearest origin (mother ship or `CIVIL Vessel Spawn` zone).
If the helicopter's hover window expires while vessels are en route, the
subject holds on for ONE extra window before being lost for good: the
window that lets the "slightly too far" boats arrive and turn a failed
helicopter rescue into a spotter-credited sea rescue.

## 5. Minimum configuration review

At the top of `01_CivilCore.lua` (`CIV.Config`):

- `countryId`: CJTF Blue by default (see section 1).
- `capacity`: exact type names of the group's modules with their external
  load in kg (the API does not expose it: hand-maintained table, values TO
  VALIDATE).
- `cargo.tiers`: kg and cargo type per tier (some cargo types have fixed
  mass: validate in the ME).
- `hover.*`: T times / windows per operation type.
- `rescue.intel`: approximate-circle radius and the spotter detection range
  used to release exact rescue coordinates.
- `autoDress`: which fixed zones get automatic scenery (reload apron off by
  default: user-built; hospital pads on by default).
- `fire.severity` / `fire.trucks`: fire growth pacing, effect cap, brigade
  size/speed/suppression rate.
- `director`: probabilities/intervals of automatic event generation (or
  `enabled = false` and start everything from the Admin menu).
- `adminMenu = false` for official events.

## 6. F10 map overlays

Two layers are drawn automatically (configurable in `CIV.Config.marks`):

- **Theme areas** (mission start): the macro-regions and fixed zones are
  outlined with faint colors so players know where each mission type lives:
  firefighting (orange), SAR mountain (blue), SAR sea (teal), C-130 reload
  (yellow), cargo destination (green), SWAT base (purple). Polygon zones are
  drawn with their real perimeter (`markupToAll`), circular ones as circles.
- **Active events**: while an event is running, its own zone is highlighted
  and removed when it ends: wildfire (red), cargo pickup (green), SWAT
  objective (purple), chase last-report area (blue). Rescue events keep the
  approximate off-center search circle instead (intel model).

Set `marks.regions.enabled = false` or `marks.events.enabled = false` to
turn either layer off; colors are `{ r, g, b, alpha }` tables in the same
config block.

## 7. Command center (game master)

Use a Game Master / Tactical Commander slot and drive the mission with F10
map markers (`civil ...` text, executed at the marker position: full
examples in the README):

```
civil director off   civil fire 8   civil medevac 9   civil swat 7
civil cargo heavy 9  civil spawn survivor 3   civil move alpha 12 road
civil cancel         civil director on        civil help
```

If the commander goes quiet (leaves, disconnects, or stops commanding), the
mission resumes AUTOMATIC mode by itself after
`command.autoResume.idleSeconds` (default 30 min) without marker commands.

## 8. In game

`F10 -> Civil Missions` menu:

- **Session leaderboard**: shared live score.
- **Firefighting**: water pickup / drop / active fires (with severity and
  brigade status). Fires carry a severity 1-10: they spawn small (single
  effect), grow on a random per-fire cadence and spread visually (more
  smoke/fire effects, capped for performance). Fire trucks roll out of the
  nearest station automatically and suppress from the ground once on scene,
  reducing the air passes needed.
- **Firefighting C-130**: loading is opt-in: taking off clean and orbiting
  as spotter/rescue support needs no interaction. `Load retardant` at the
  reload zone starts a 2-minute hold (moving aborts it), then `Start line
  drop` releases along the flight path. Alternatively, airdropped cargo
  containers landing near an active fire count as retardant drums
  (detection channels TO VALIDATE with the official C-130 module).
- **Rescue**: smoke from the subject / active events. Exact rescue
  coordinates appear only after a spotter airplane identifies the subject;
  until then, reports give a rough direction and an approximate search
  circle on the F10 map. Covers SAR mountain/sea, MedEvac and battlefield
  CASEVAC; delivery works at hospital pads and on hospital ships.
- **Police / SWAT**: board team / team status.
- **Cargo transport**: change tier of the nearby point / active points.
  Supply crates airdropped from the C-130 into `CIVIL Cargo Destination`
  also score as deliveries (differentiated crates: drums/barrels =
  retardant on fires, crates = supplies at the destination; until the
  official module's crate type names are validated, `matchAnyObject = true`
  makes the impact location decide).
- **Admin (test)**: manual start of every event, pool status.

## 9. In-game test checklist (before serious use)

1. Pools and menus: start every event from the Admin menu and check
   messages/spawns.
2. Hover: water pickup + one full SAR through to hospital delivery.
3. Rescue intel: verify the approximate circle, then identify the subject
   with a C-130 and check the exact-coordinates release.
4. Cargo types: verify in the ME that the configured types accept the custom
   mass (weigh them by hooking).
5. "On Road": watch 2-3 full chases on the pool's crossroads.
6. SWAT: infantry spawn on a rooftop from the pool.
7. C-130 airdrop: drop containers from the official module near an active
   fire AND inside the cargo destination, check `dcs.log` for which
   detection channel fires (S_EVENT_SHOT weapon vs object scan) and note
   the crate type names; then fill `fire.airdrop.containerTypes` /
   `cargo.airdrop.containerTypes` and set `matchAnyObject = false` to
   enforce the drum-vs-crate separation.
8. (Only if wanted) `fire.usePhysicalCargo = true`: cargo spawn on water.
9. (Only if wanted) beacon: `.ogg` file in the .miz and
   `rescue.sarMountain.beacon.enabled = true`.
