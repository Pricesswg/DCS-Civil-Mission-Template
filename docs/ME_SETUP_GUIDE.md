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

**B) Modular (for development/testing)**: one `DO SCRIPT FILE` action per
file. ORDER MATTERS: DCS executes the actions of a trigger top to bottom,
in the order you add them, so keep the files in ascending numeric order.
That is exactly what the number prefixes are for. Hard rules: `01` must be
FIRST (every module depends on it) and `50` must be LAST (it looks into
every other module); the files in between only depend on the core, so
their relative order is free. Unused modules can simply be omitted: the
media/recap/game-master features detect missing modules and skip them.

```
Scripts/01_CivilCore.lua        <- ALWAYS, first
Scripts/10_CivilFirefighting.lua
Scripts/20_CivilRescue.lua      (SAR mountain/sea + MedEvac + CASEVAC)
Scripts/30_CivilPolice.lua      (chase + SWAT)
Scripts/40_CivilTransport.lua
Scripts/45_CivilAviation.lua    (recon, VIP shuttle, media coverage)
Scripts/50_CivilCommand.lua     <- LAST (game-master commands + recap)
```

After any change inside `Scripts/`, regenerate the single file with
`tools/build.sh` (or by manually concatenating the files in order into one
.lua).

## 3. Trigger zones to create in the ME

Matching is **by name prefix** (527th CSAR style): any zone whose name
STARTS with the prefix belongs to that pool: e.g. `CIVIL Fire Point Alpha`,
`CIVIL Fire Point 12`, `CIVIL Fire Point Forest`. No consecutive numbering
required. Zones can be **circular or polygon (quad) zones**: vertices and
properties are read from `env.mission`.

The prefix rule covers the MACRO-AREAS as well: place as many regions of
the same type as the mission needs (`CIVIL Fire Region North` and `CIVIL
Fire Region South`, two mountain SAR regions on separate ranges, several
reload aprons, cargo destinations or SWAT bases). The scripts check every
matching area: line drops and spotters work inside any fire region, rescue
reports name the region the subject actually belongs to, deliveries count
in any destination zone.

| Prefix / zone name | Use | Placement notes |
|---|---|---|
| `CIVIL Fire Region ...` | firefighting macro-region(s) | large; enable the spotter and the C-130 line drop; several regions of the same type are fine |
| `CIVIL Fire Point ...` | fire ignition points | forest/fields, away from buildings and roads |
| `CIVIL Fire Station ...` | fire brigade depots | trucks depart from the nearest one and drive "On Road" to the fire |
| `CIVIL Water Point ...` | helicopter water pickup | on a body of water, with maneuvering room |
| `CIVIL C130 Reload ...` | C-130 retardant reload apron(s) | reachable on the ground. USER-BUILT static area: decorate it yourself (`autoDress.c130Reload = false` by default) |
| `CIVIL SAR Mountain Region ...` + `CIVIL SAR Mountain Point ...` | mountain SAR | region(s) can cover separate ranges; points reachable in a hover |
| `CIVIL SAR Sea Region ...` + `CIVIL SAR Sea Point ...` | sea SAR | points on OPEN water (a boat spawns there) |
| `CIVIL Police Point ...` | chase | 30-40 points ON real crossroads, neighbor distance <= 1500 m |
| `CIVIL SWAT Base ...` | team boarding | apron(s) where the helicopter can land |
| `CIVIL SWAT Point ...` | SWAT scenarios | rooftops / urban LZs (rooftop spawn TO TEST) |
| `CIVIL Cargo Point ...` | cargo loading points | flat ground |
| `CIVIL Recon Point ...` | inspection corridor | 5+ zones along a power line or pipeline; anomalies spawn on them |
| `CIVIL VIP Pad ...` | passenger shuttle + medical transfer pads | at least 2; put them on airfield aprons and both jobs open up to the fixed-wing. Transfer legs pick a destination at least `medTransfer.minLeg` away (default 15 km), so spread the pads out |
| `CIVIL Drop Zone ...` | skydive drop zones | optional; an open field per zone. The zone RADIUS is the scoring scale (accuracy = distance from center vs radius), 300-500 m works well |
| `CIVIL Cargo Destination ...` | cargo delivery | one or more destination zones; deliveries and supply airdrops count in any of them |
| `CIVIL Medevac Point ...` | casualty recovery | "hostile"/accident LZs |
| `CIVIL Casevac Point ...` | battlefield casualty extraction | battlefield LZs (same flow as MedEvac, hostile skin). USER-BUILT static areas: dress them with your own battlefield assets |
| `CIVIL Hospital ...` | hospital pads | on the actual pad; delivery is ZONE-detected (still+low), no FARP needed. NOT auto-dressed: real map hospitals (e.g. Syria) come already decorated. Set `autoDress.hospitals = true` for the medical camp kit on a bare map |
| `CIVIL Vessel Spawn ...` | rescue boat harbors | on open water near a harbor. BALANCE RULE: place them so that distance / boat speed (9 m/s ~ 17.5 kts) is slightly LONGER than the sea SAR hover window (default 25 min ~ 13.5 km): the boat is the second chance, not a competitor to the helicopter |

Prefixes are configurable in `CIV.Config.zones` (top of `01_CivilCore.lua`).

## 4. Optional spawn templates (CSAR Pilot style)

**Late-activated** groups placed in the ME: if they exist, spawns are cloned
from them (units, liveries, country) instead of using the hardcoded fallback
types. Group-name prefix matching.

### How to build a template, step by step

The same recipe works for EVERY template in the tables below (anomaly,
scenes, survivor, fugitive, boats, SWAT team, VIP, fire truck):

1. In the ME, create a group of the right category: GROUND for survivors,
   scenes, teams, cars, trucks, anomalies and the VIP; SHIP for the sea
   SAR boat, the rescue boat and the sea scene. A ground group can mix
   vehicles and infantry in the same group.
2. Rename the GROUP so its name starts with the prefix, e.g.
   `CIVIL Anomaly Transformer Truck`. Only the group name matters, unit
   names are free.
3. Tick **LATE ACTIVATION**. The group will never activate on its own and
   costs nothing while unused: it is pure spawn data.
4. Place it ANYWHERE: no zone needed, the position is irrelevant. At spawn
   the group is cloned and re-centered on the event point. A tidy
   convention is a "template farm": park all templates together in an
   unused corner of the map.
5. Arrange the units exactly as you want them to appear: the layout
   RELATIVE to the first unit is preserved (ambulance here, two medics
   three meters away), and each unit keeps its own heading as you set it.
   Types, liveries, skill and country are cloned too.
6. Waypoints/routes are ignored: the clone gets a hold point where it
   spawns.
7. Verify at mission start: `dcs.log` lists every template found, one
   `[CIVIL]   template: '...'` line each. If yours is missing, the group
   name prefix is wrong or late activation is not ticked.

Notes: the SWAT team template is special, its unit count is scaled to the
squad size at insertion (the first unit is duplicated if needed). Pure
STATIC objects cannot be late-activated groups: for statics use the
dressing kits or direct ME placement (see below).

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
| `CIVIL Scene Camp ...` | SAR mountain | tent, backpacks, a second hiker |
| `CIVIL Scene Crash ...` | SAR mountain | light aircraft wreck |
| `CIVIL Scene Sea ...` | SAR sea | capsized boat, debris (SHIP group) |
| `CIVIL Scene Robbery ...` | chase start | police cars, crowd at the bank |
| `CIVIL Scene Standoff ...` | SWAT objective | police cordon, parked cars |

**How recon anomalies look**: the anomaly is placed on one of the
`CIVIL Recon Point` zones and is made of up to three layers: a thin smoke
column (default on, `recon.smokeVisual`: the smoking transformer you can
actually see from the corridor), the optional `CIVIL Anomaly` template
cloned at the point (build it as a maintenance scene: a stopped truck, a
damaged pylon area, workers), and the proximity nudge message when you fly
within 2 km below 300 m AGL. Reporting works from overhead (600 m) at low
level via F10.

**How static areas get their objects**: three layers, pick per zone.
(1) USER-BUILT: place statics directly in the ME inside the zone (reload
apron, CASEVAC LZs): nothing to configure, the script never touches them.
(2) AUTO-DRESS KITS: lists of static objects with offsets from the zone
center, defined in `CIV.Dressing.kits` in `01_CivilCore.lua` (each entry
is `{ type = "FARP Tent", dx = 15, dy = 0, heading = 0 }`: type names from
the ME statics list, offsets in meters). Assign kits to zones with
`autoDress` (everything off by default: real map hospitals are already
decorated) or add your own
pairs in `autoDress.custom = { { prefix = "CIVIL Refugee Camp", kit =
"refugee_camp" } }`. (3) SPAWNED GROUPS: anything that must appear at
runtime (scenes, subjects, teams) comes from the late-activated `CIVIL ...`
templates.

The subject signal command works day and night: orange smoke by day, green
signal flares after dark (`rescue.signal` sets the night hours and the
flare count). Fires also roll a KIND at ignition (`fire.kinds`): forest,
landfill (thick smoke, slow) or industrial (fast), named in every report.

At night players also have `Request illumination on nearest objective`: an
illumination flare ignites 300 m over the closest active objective and the
message gives bearing and range. Unidentified rescue subjects only get it
over the approximate search area (the spotter stays relevant). Cooldown
and search radius in `CIV.Config.nightAssist`.

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
| `CIVIL Anomaly ...` | recon anomaly visual (ground) | none, logical anomaly |
| `CIVIL VIP ...` | waiting passenger visual (ground) | none, logical passenger |
| `CIVIL Skydiver ...` | landed jumpers (ground) | `Soldier M4` |

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
- `autoDress`: which fixed zones get automatic scenery. ALL off by
  default: the reload apron and CASEVAC LZs are user-built, and hospital
  pads usually sit on real map hospitals that come already dressed.
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
civil cargo heavy 9  civil transfer 8         civil spawn survivor 3
civil move alpha 12 road   civil cancel       civil director on
civil help
```

If the commander goes quiet (leaves, disconnects, or stops commanding), the
mission resumes AUTOMATIC mode by itself after
`command.autoResume.idleSeconds` (default 30 min) without marker commands.

## 8. In game

`F10 -> Civil Missions` menu:

- **Session leaderboard**: shared live score.
- **Firefighting**: water pickup / drop / active fires (with severity and
  brigade status). Fires carry a severity 1-10 that drives how many smoke
  columns burn (capped for performance); each column starts SMALL and
  escalates one size step (small, medium, large, huge) every
  `fire.visuals.escalateEvery` seconds it goes unattended (default 7.5
  minutes per step), so an ignored fire is visibly taking hold within 20
  minutes. A suppression hit knocks
  the columns back one step. Fire trucks roll out of the nearest station
  automatically and suppress from the ground once on scene, reducing the
  air passes needed.
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
- **Aviation tasks**: report a recon anomaly from overhead, release
  skydivers over a drop zone, list active recon/VIP/transfer tasks. Media
  coverage is passive: hold the filming ring around any event for 5
  minutes (helicopters and airplanes). Every airplane can spot (fires and
  rescue subjects, with spotter points on identification) and serve VIP
  pads placed on airfield aprons. Light air-attack types (see
  `fire.airAttack`) cannot haul retardant: their job is the smoke mark on
  the fire, which buffs everyone's drops for 5 minutes and pays them the
  assist on extinguish. Two passive airplane rewards run on top: patrolling
  a quiet fire region keeps it watched (fires there start smaller, with
  credit), and orbiting over a police chase speeds up the helicopter's
  pressure build and pays an arrest assist. Medical transfers spawn as a
  chain after severity 7+ hospital deliveries (`medTransfer.chance`).
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
