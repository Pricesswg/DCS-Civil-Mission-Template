# DCS Civil Mission Template

Modular template for civil missions in DCS World: firefighting, mountain/sea
SAR, MedEvac, battlefield CASEVAC, police (chase and SWAT), tiered cargo
transport. All in **pure native Lua** (no MIST/MOOSE/CTLD).

![DCS Civil Mission Template](cover.jpg)


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
  45_CivilAviation.lua      Recon, VIP shuttle, media, medical transfer,
                            skydive, aviation task board
  46_CivilAirTraffic.lua    Ambient AI civil flights + restricted-area intercepts
  47_CivilSeaOps.lua        Merchant traffic on sea lanes + coast guard inspections
  50_CivilCommand.lua       Command center marker commands + session recap
dist/
  CivilMissionTemplate.lua  Single-file build; regenerate with tools/build.sh
missions/
  Civil_Water_Template_Cyprus.miz  Test mission (Cyprus): zones and script
                            already wired, used for in-game validation
tools/build.sh              Concatenates Scripts/ into the single-file build
tools/leaderboard.py        Cross-session leaderboard from dcs.log SCORE lines
docs/
  CONCEPT.md                Design brief (decisions and verifications)
  FEASIBILITY.md            Point-by-point feasibility check
  ME_SETUP_GUIDE.md         Extended Mission Editor guide
  PILOT_BRIEFING.txt        Ready-to-paste mission briefing for the players
  GAME_MASTER_GUIDE.md      Handbook for the command center player
```

## Quick start

1. Add **CJTF Blue** to the blue coalition (all scripted spawns run under it).
2. Create the trigger zones from the checklist below.
3. Load `dist/CivilMissionTemplate.lua` with a single `DO SCRIPT FILE` action
   at MISSION START. If you load the `Scripts/` files individually instead,
   ORDER MATTERS: DCS runs `DO SCRIPT FILE` actions top to bottom, so add
   them in ascending numeric order. The prefixes ARE the load order: `01`
   first (everything depends on it), `50` last (it looks into every other
   module). Modules you do not use can be skipped, the rest adapts.
4. In game: `F10 -> Civil Missions` (the `Admin (test)` submenu starts any
   event manually).

## Mission Editor checklist: trigger zones

Matching is **by name prefix**: any zone whose name *starts with* the prefix
belongs to that pool (`CIVIL Fire Point Alpha`, `CIVIL Fire Point 12`, ...).
No numbering rules. Zones can be **circular or polygon (quad)**. Modules
whose zones are missing are skipped gracefully: place only what you test.

This applies to the MACRO-AREAS too: every name below is a prefix, so you
can have several regions of the same type (`CIVIL Fire Region North` and
`CIVIL Fire Region South`, two separate `CIVIL SAR Mountain Region ...`
mountains, more than one reload apron, cargo destination or SWAT base).
Events use whichever matching area contains or is nearest to them, and
rescue reports name the specific region.

| Zone name / prefix | Module | Qty | Placement |
|---|---|---|---|
| `CIVIL Fire Region ...` | Firefighting | 1+ | macro-region(s) containing the fire points; enable the spotter role and the C-130 line drop |
| `CIVIL Fire Point ...` | Firefighting | 3+ | curated ignition points: forest/fields, clear of buildings and roads. A name containing `Building`/`Landfill`/`Industrial`/`Forest` FORCES that kind on the point (aim building fires at real buildings) |
| `CIVIL Fire Station ...` | Firefighting | 1+ | fire brigade depots; trucks depart from the nearest one and drive "On Road" to the fire |
| `CIVIL Water Point ...` | Firefighting | 1+ | helicopter water pickup, on a body of water with hover room |
| `CIVIL C130 Reload ...` | Firefighting | 1+ | retardant reload apron, reachable by taxi. **User-built static area**: decorate it yourself (auto-dressing off by default) |
| `CIVIL SAR Mountain Region ...` | Rescue | 1+ | macro-region(s) for mountain SAR (spotter + vague-direction reference); two separate mountains = two zones |
| `CIVIL SAR Mountain Point ...` | Rescue | 3+ | survivor spots reachable in a hover |
| `CIVIL SAR Sea Region ...` | Rescue | 1+ | macro-region(s) for sea SAR |
| `CIVIL SAR Sea Point ...` | Rescue | 3+ | on OPEN water (a boat spawns there) |
| `CIVIL Vessel Spawn ...` | Rescue | 1+ | rescue-boat harbors, on water. Balance rule: distance to the SAR points / 9 m/s should be slightly LONGER than the hover window (default 25 min ~ 13.5 km) |
| `CIVIL Medevac Point ...` | Rescue | 3+ | civilian casualty LZs (accidents, unsafe areas) |
| `CIVIL Casevac Point ...` | Rescue | 3+ | battlefield extraction LZs. **User-built static areas**: dress them with your own battlefield assets |
| `CIVIL Hospital ...` | Rescue | 1+ | on the actual hospital pads; delivery is ZONE-detected (still + low for 15 s), no FARP object needed. NOT auto-dressed by default (real map hospitals come decorated); `autoDress.hospitals = true` adds the medical-camp kit on bare maps |
| `CIVIL Police Point ...` | Police | 30-40 | ON real city crossroads, neighbor distance <= 1500 m (chase random walk) |
| `CIVIL SWAT Base ...` | Police | 1+ | apron(s) where the helicopter can land to board the team |
| `CIVIL SWAT Point ...` | Police | 3+ | rooftops / urban LZs (rooftop infantry spawn TO TEST) |
| `CIVIL Cargo Point ...` | Transport | 3+ | loading points on flat ground |
| `CIVIL Cargo Destination ...` | Transport | 1+ | delivery zone(s): sling loads and supply airdrops count in any of them |
| `CIVIL Recon Point ...` | Aviation | 5+ | along a power line or pipeline; anomalies spawn on them, patrol the corridor low |
| `CIVIL VIP Pad ...` | Aviation | 2+ | passenger shuttle helipads; the medical transfer legs use the same pool (pads on aprons give the job to the fixed-wing) |
| `CIVIL Drop Zone ...` | Aviation | 0+ | skydive drop zones: release jumpers overhead via F10, score = landing accuracy |
| `CIVIL Sea Spawn ...` | Sea ops | 1+ | merchant route START: ships appear at a random point inside (staggered so they never overlap) |
| `CIVIL Sea Lane ...` | Sea ops | 2+ | route waypoints: ships walk nearby lanes like the police chase walks crossroads |
| `CIVIL Sea Despawn ...` | Sea ops | 1+ | merchant route END: ships are cleared on arrival |
| `CIVIL Restricted ...` | Air traffic | 0+ | military areas closed to civil traffic; strayed flights loiter inside until intercepted |
| `CIVIL Convoy Start ...` | Police | 1+ | prisoner convoy departure (police station, courthouse); route runs "On Road" to the destination |
| `CIVIL Convoy End ...` | Police | 1+ | prisoner convoy destination (prison, courthouse) |

## Mission Editor checklist: units (matched by name prefix)

**Ships (regular units):**

| Prefix | Matched on | Role |
|---|---|---|
| `CIVIL Rescue Vessel ...` | group name | steams to the approximate search area on sea SAR; a vessel holding 200 m / 60 s from the subject completes a SEA RESCUE credited to the identifying spotter |
| `CIVIL Hospital Ship ...` | unit name | mobile delivery pad (detection relative to the ship: works underway; deck landing with big-ship mods TO TEST) + mother ship launching rescue boats when closer than the harbors (e.g. Perry, Tarawa) |

**Late-activated spawn templates (optional: hardcoded fallback types are
used when absent):**

| Group prefix | Spawned as | Fallback type |
|---|---|---|
| `CIVIL Survivor ...` | mountain SAR / MedEvac subject | `Soldier M4` |
| `CIVIL Casualty ...` | battlefield CASEVAC casualty | `Soldier M4` |
| `CIVIL Boat ...` | sea SAR target | `ZWEZDNY` |
| `CIVIL Vessel ...` | spawned rescue boat | `speedboat` |
| `CIVIL SWAT Team ...` | SWAT squad | `Soldier M4` |
| `CIVIL Fugitive ...` | police chase car | `LandRover_ah` |
| `CIVIL Fire Truck ...` | fire brigade truck | `HEMTT TFFT` |
| `CIVIL Scene Rescue ...` | MedEvac scene: ambulance + medics | none (scene skipped) |
| `CIVIL Scene Accident ...` | MedEvac scene: crashed cars, bystanders | none (scene skipped) |
| `CIVIL Scene Battlefield ...` | CASEVAC scene: battlefield props | none (scene skipped) |
| `CIVIL Scene Camp ...` | mountain SAR scene: tent, second hiker | none (scene skipped) |
| `CIVIL Scene Crash ...` | mountain SAR scene: aircraft wreck | none (scene skipped) |
| `CIVIL Scene Sea ...` | sea SAR scene, built as a SHIP group | none (scene skipped) |
| `CIVIL Scene Robbery ...` | chase start scene: police cars, crowd | none (scene skipped) |
| `CIVIL Scene Standoff ...` | SWAT objective scene: cordon, cars | none (scene skipped) |
| `CIVIL Anomaly ...` | recon corridor anomaly visual | none (logical anomaly) |
| `CIVIL VIP ...` | waiting passenger visual | none (logical passenger) |
| `CIVIL Skydiver ...` | landed jumpers | `Soldier M4` |
| `CIVIL Merchant ...` | sea traffic freighter | `HandyWind` |
| `CIVIL Airliner ...` | ambient air traffic (type + livery source) | `Yak-40` |
| `CIVIL Convoy ...` | prisoner transport: police car, school bus, tail car (in that order) | `LandRover_ah` + `IKARUS Bus` + `LandRover_ah` |
| `CIVIL Ambush ...` | roadside ambush: two armed men and a car. Build it under a HOSTILE country and the gunmen actually open fire; the scripted outcome works either way | none (no template = no ambush, plain escort) |

**Building a template**: create a group of the right category (ground or
ship), name the GROUP with the prefix, tick LATE ACTIVATION, place it
anywhere (position is irrelevant: the clone is re-centered on the event
point, keeping the relative layout and each unit's heading, types,
liveries and skill). No zone needed. `dcs.log` lists every template found
at mission start. Full step-by-step recipe in `docs/ME_SETUP_GUIDE.md`.

**Variety through multiple templates**: place as many groups as you want
with the same prefix and each spawn picks ONE of them at random. For
example `CIVIL Boat 1`, `CIVIL Boat 2`, `CIVIL Boat 3` (or `CIVIL Fugitive
BMW`, `CIVIL Fugitive Van`: any suffix works, numbering is optional) and
every event comes out with a different boat or car. The list builds itself
at mission start, no config to touch.

**Event scenes**: rescue events, the chase start and the SWAT objective all
spawn a scene next to the action. The scenario first picks a scene TYPE at
random from its list (`rescue.scenes.byScenario`, `police.sceneTemplates`,
`swat.sceneTemplates`), then a random variant among the templates sharing
that prefix. Build each scene as one group in the ME (an ambulance plus two
medics, wrecked cars, a police cordon; the sea scene as a ship group). When
the event ends the scene stays on for `rescue.scenes.despawnDelay` (default
5 minutes), then it is cleared. Missing templates simply spawn no scene.

**Subject signal, day and night**: the F10 command asks the subject to mark
its position. By day it pops orange smoke; by night (mission local time,
`rescue.signal` hours) smoke would be invisible, so the subject fires a
sequence of green signal flares instead. Works the same for every rescue
variant: mountain, sea, MedEvac and CASEVAC.

**Night illumination assist**: a second F10 command, night only, pops an
illumination flare 300 m over the nearest active objective (fire, SWAT
objective, cargo pickup, fleeing vehicle) and reports its bearing and
range. Rescue subjects not yet identified by a spotter get the flare over
the APPROXIMATE search area, so the intel model stays intact. Per-player
cooldown, tunable in `nightAssist`.

**Aviation tasks**: infrastructure recon (fly the corridor low, spot the
anomaly, report it via F10 before it expires), VIP shuttle (board a
passenger at one pad, deliver to another; ride comfort is the score:
acceleration spikes cost you the tip) and passive media coverage (hold in
the 1-3 km filming ring around any active event for 5 minutes and the
story airs). Filming an empty event pays the base rate; **action
footage** pays more: while another player aircraft is working the event
within `media.actionRadius` (a helicopter dropping water, the C-130 on
its line run), your footage accumulates a bonus worth up to
+`media.actionBonus` (default +50%) on the story. The TV helicopter
earns the most by staying with the response, not by circling ruins.

**Medical transfer (air ambulance)**: an event CHAIN on the rescue module.
When a severity 7+ patient reaches a hospital, there is a chance
(`medTransfer.chance`, default 40%) the patient must continue to a regional
hospital: a transfer job spawns from the VIP pad nearest the delivery to a
pad at least 15 km away. Boarding works like the VIP shuttle, but a
criticality clock ticks and the comfort threshold is tighter: the passenger
is on a stretcher. Helicopters can take the leg, but pads on aprons plus
the long distance make it the natural fixed-wing job. It can also be
started manually (`civil transfer 8`, or the admin menu).

**Task board (pilot-called aviation tasks)**: recon, VIP shuttle and
medical transfer are not pushed on the pilots. The director posts OFFERS
and whoever is ready accepts one via `F10 -> Aviation tasks -> Task board`
(maybe you are refueling or mid-task: nothing gets assigned to you). Each
offer shows severity, expected points and time left; offers flagged
PRIORITY carry a +30% score bonus. Unclaimed offers expire quietly. GM
marker commands bypass the board on purpose, and the MedEvac transfer
chain stays direct: that patient already exists and his clock is ticking.
Set `taskBoard.enabled = false` to go back to pushed tasks.

**Sea traffic and coast guard** (`47_CivilSeaOps.lua`): merchant ships
spawn at a random point inside a `CIVIL Sea Spawn` zone, sail a local
random walk over the `CIVIL Sea Lane` waypoints and are cleared in a
`CIVIL Sea Despawn` zone, so you control exactly where routes start, run
and end. On top of that traffic runs the COAST GUARD task (helicopters):
fly alongside the reported merchant, low and slow, to check the manifest.
A clean manifest pays a partial score; suspicious cargo escalates: the
ship runs for it, you keep track of it (3 km) and a patrol boat launches
from the nearest `CIVIL Vessel Spawn` harbor to board it. Full score to
the inspecting pilot on the boarding, task failed if contact stays lost
too long.

**Ambient air traffic** (`46_CivilAirTraffic.lua`): AI civil flights
between the map airdromes keep the sky alive, capped at
`airTraffic.maxActive` (default 6, keep it in the 5-10 range). Flights
spawn airborne out of the departure field and land at the destination;
type and livery come from the optional `CIVIL Airliner` templates (Civil
Aircraft Mod types work well). Sometimes a flight strays into a `CIVIL
Restricted` zone and loiters: the AIRSPACE ALERT intercept task goes to
the military flights (fly within 500 m of the violator for 30 s to
identify and escort it out, `score.base.intercept` points). The violation
is armed only when a player airplane is airborne to answer it; if nobody
intercepts in time, ATC diverts the flight out by itself and the alert
closes with no points.

**Skydive drops**: mark one or more `CIVIL Drop Zone` zones and the flying
club is in business. Climb overhead, release the jumpers via F10 above
800 m AGL, and the landing point is computed from the actual mission wind:
damped drift in freefall, full drift under canopy, plus a small steer
correction toward the center. The jumpers spawn where they land and the
score is their distance from the zone center, so the pilot's job is
reading the wind and picking the release point. Per-aircraft cooldown
between drops.

**Light fixed-wing (Bronco, MB-339, L-39, C-101, Yak-52, Christen
Eagle...)** have a full job list: spotting works from ANY airplane (fire
intel relay plus rescue identification, which pays spotter points), the
recon corridor and the media ring suit them natively, and VIP pads placed
on airfield aprons give them an air-taxi role. On fires they fly the AIR
ATTACK role, like the real lead planes: they cannot haul retardant (the
reload refuses their types), instead their F10 command smoke-marks the
nearest fire from below 600 m. While the mark is hot (5 min), every drop
on that fire scores +25%, and the marker earns the assist when the fire
goes out. Types in `fire.airAttack`, TO VALIDATE per mod.

**Prisoner convoy escort** (helicopters): a police car, the school bus
with the detainees and a tail car drive from a `CIVIL Convoy Start` zone
to a `CIVIL Convoy End` zone on the road network, and the helicopter
shadows them (escort coverage is the completion quality). Along the way
there is a chance (`police.convoy.ambush.chance`) an ambush appears ahead
of the route: two armed men and a car from your `CIVIL Ambush` template,
just off the road. Fly low over the route, catch the nudge, and REPORT it
via `F10 -> Police / SWAT` before the convoy gets there: bonus points,
the site gets marked on the map and the police clears it in a minute.
Miss it and the convoy drives into the kill zone: mission FAILED, both
groups despawn and the escorting pilot takes a points malus for the
miss.

Two more airplane jobs reward flying when nothing burns yet. **Firewatch**:
sweeping a fire region that has no active fire keeps it watched for 15
minutes; a fire igniting in a watched region is called in early, starts 2
severity points smaller and credits the patrolling pilot. **Traffic
watch**: on a police chase, an airplane orbiting over the fugitive (within
1.8 km, below 1500 m) keeps the pursuit on camera: the helicopter's
pressure builds 50% faster while the watch holds, and the watcher earns an
assist when the arrest lands. A situation recap broadcasts every 30
minutes, final standings at mission end; `tools/leaderboard.py` turns the
logged SCORE lines into a cross-session ranking.

**Fire kinds**: each ignition rolls what is burning (`fire.kinds`), with
forest fires dominating (70%), plus landfill (thick dark smoke, slow) and
industrial (fast growth). The report and the F10 mark name the kind, and
the SMOKE ITSELF tells the story from afar: a forest fire starts small,
grows with time and spreads new columns across the zone; landfill and
industrial fires burn hard from the first minute (columns start LARGE and
age to huge) but stay contained, piling their extra smoke on nearly the
same spot instead of spreading. Suppression knockback never shrinks a
contained fire below its starting size.

A fire POINT can force its kind through its zone name: any `CIVIL Fire
Point` whose name contains `Building` (or `Forest`, `Landfill`,
`Industrial`) always ignites as that kind, so you aim structural fires at
specific buildings. **Building fires never roll randomly** (weight 0):
they only start on those dedicated points or by GM command (`civil fire
building 7`). And they play differently: retardant does not work on them
(C-130 line drops and drums have no effect) and the air attack does not
smoke-mark them, because neither is used on structures. Helicopter drops
and the ground brigade do the job.

## The severity scale (1-10, all events)

Every event rolls a **severity 1-10** at spawn: one roll from which all its
parameters derive, announced in every report ("MedEvac severity 8"):

| Event | Severity drives |
|---|---|
| Wildfire | LIVE variable: grows on a per-fire cadence, adds smoke columns as it spreads (capped at 5 for performance); each column also grows small -> huge with time unattended (one step per 7.5 min) and shrinks a step when hit. Suppressed by drops/trucks, 0 = out |
| SAR / MedEvac / CASEVAC | criticality deadline (severity 10 = -40%), hover window (less time) and required hover time (more), score |
| Police chase | car speed, pressure build/decay rates, two-vehicle convoy at severity >= 8, score |
| SWAT | operators required (4->8), squad boarded at the base is sized for the worst active scenario, resolve time, score |
| Transport ("priority") | time to live of the load (priority 10 expires in 45 min) and score |

Score multiplier is anchored at `0.7 + 0.06 * severity`: severity 5 = x1.0.

## Command center (game master)

A player in a **Game Master / Tactical Commander slot** (full F10 map, SRS;
native asset control with Combined Arms) acts as the emergency command
center by placing **F10 map markers** whose text starts with `civil`: the
commands work from any slot and the marker position IS the target position.

Worked examples (place the marker where you want the effect, type the text,
the marker is consumed once executed):

```
civil director off        take the wheel: automatic generation pauses
civil fire 8              severity-8 wildfire right under the marker
civil fire building 7     structural fire on that building (no retardant,
                          no air-attack marking: helicopters and trucks)
civil medevac 9           critical casualty there (~18 min of criticality)
civil sars 6              castaway on that water position (vessels react)
civil casevac             battlefield casualty, severity rolled randomly
civil swat 7              SWAT objective there (needs ~7 operators)
civil chase 9             fast two-car convoy from the nearest crossroad
civil convoy 7            prisoner transport run (Convoy Start -> End zones)
civil cargo heavy 9       urgent HEAVY load there (expires in ~45 min)
civil transfer 8          medical transfer from the pad nearest the marker
civil inspect 7           coast guard inspection on the merchant nearest
                          the marker
civil ship                extra merchant on the sea lanes
civil flight              extra ambient civil flight
civil spawn survivor 3    clone 3 units of the "CIVIL Survivor" template
civil spawn truck         one "CIVIL Fire Truck" group at the marker
civil move alpha 12 road  send the group matching "alpha" there at 12 m/s
                          following roads (single-word fragment; no CA needed)
civil cancel              call off the event nearest to the marker
civil director on         hand back to automatic generation
civil help                list the commands in game
```

While the commander directs (`civil director off`), automatic generation
stays paused. **If the commander goes quiet (leaves the slot, disconnects,
or simply stops issuing commands) the mission returns to AUTOMATIC mode by
itself** after `command.autoResume.idleSeconds` (default 30 minutes) without
marker commands: an unattended session never stays frozen. Optional
player-name whitelist in `CIV.Config.command.restrict`. Marker behavior from
GM slots is TO VALIDATE in-game (see FEASIBILITY).

Fire suppression (in severity units): helicopter drop -2, C-130 line
-0.25/s, retardant drum -2/container, fire brigade on scene -0.6/min. The
brigade rolls out of the nearest `CIVIL Fire Station` automatically, cutting
the air passes needed: players race the clock, not the trucks.

## Status

Structure complete, syntax-checked (Lua 5.1) and smoke-tested against a mock
of the DCS scripting API: both the modular and the single-file build.
**Not yet tested inside DCS**: the items needing in-game validation (cargo
mass types, "On Road" behavior, rooftop spawns, official C-130 airdrop
channels, deck landings, boat/vehicle type names) are listed with their
fallbacks in `docs/FEASIBILITY.md`.

## Recommended Mods

* [Civilian Assets by Eightball](https://forum.dcs.world/topic/270558-civilian-objects-and-vehicles/)
* [Copter Life by Eightball](https://forum.dcs.world/topic/386801-copterlife-mod-pack/)
* [Fire Department Livery Pack](https://forum.dcs.world/topic/254036-fire-department-livery-pack/#comment-5689752)
* [Civilian skin pack (DCS User Files)](https://files.digitalcombatsimulator.com/it/files/3313210/)
* [OV-10A Bronco](https://splitair.gumroad.com/l/fwzxn)
* [Civil Aircraft Mod](https://cam.em-key.de/)


Zone/template scanning, polygon area support and several utilities are
adapted from the 527th CSAR System by {527th} ienatom and {104WW} Price.

## License

This project is released under the **PolyForm Noncommercial License 1.0.0**
(see the `LICENSE` file). You are free to use, modify and share it for any
noncommercial purpose: personal missions, hobby squadrons, free community
servers, training and study.

**Use on paid servers is not covered.** Running this mission, or any work
based on it, on pay-to-access servers, donation-gated slots or any other
for-profit hosting requires a specific request to, and prior written
authorization from, the repository owner (Pricesswg). If that is your case,
open an issue on this repository and ask before deploying.
