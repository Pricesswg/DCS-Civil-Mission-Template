# DCS Civil Missions — Concept Draft

Consolidated design brief for the implementation (pure native Lua, no
MIST/MOOSE/CTLD). Collects the decisions taken, the technical checks done on
native documentation, and the points still to be tested in-game or decided.

## Shared architectural principles

Rules valid for **all** scripts, not just firefighting:

- **Load/weight**: wherever possible use the native DCS Cargo system (static
  objects with mass, loadable via the F8 radio command on modules that
  support it) so the weight is real on the flight model. Where no native
  equivalent exists (e.g. retardant for the C-130), the load stays a
  **logical state** (per-unit variable) with on-screen notification, not a
  real physical weight.
- **Parallel events**: any counter/state (chase pressure, load, activation
  timer) must be kept **per unit/group**, never in global variables. It must
  be possible to have several fires, chases or SAR events running at the same
  time without polluting each other.
- **Event placement**: no spawning on fully random terrain points (risk of
  ending up in shallow water, inside buildings, on a busy road). Two-level
  system:
  - **Macro-region** (ME polygon) to thematically group an area (e.g. fire
    area, mountain SAR area, police city area).
  - **Pool of curated points** inside the region, hand-placed, among which
    the script picks at random (with a minimum-distance check against other
    active events). Exception: truly homogeneous areas (e.g. uniform forest)
    where a random point with a single validation check may be enough.
- **Variability**: variation parameters (rise/decay rates, timing) must be
  **randomized once at event start**, not every tick. Continuous jitter tends
  to statistically level out and becomes unreadable noise; a value fixed for
  the whole duration gives the event a recognizable "character" instead.
- **Shared hover detection (`HoverZoneTrigger`)**: a single module reused by
  any operation without a guaranteed clean landing — firefighting water
  pickup, mountain SAR, sea SAR, MedEvac in a hostile setting, SWAT insertion
  by fast-rope. Technically it is NOT a task assigned to an AI controller
  (the operating helicopters are player-flown): it is **polling of the player
  unit's state** — `Unit:getVelocity()` for the speed magnitude,
  `Unit:getPoint()` for position and altitude, zone membership check,
  sustained for a minimum time. The success action (spawn, despawn, state
  change) is mission-specific and passed as a callback, not baked into the
  module. For the completion mechanics and timings, see the "Hover and
  completion mechanics" section.

## Hover and completion mechanics

Applies to every operation based on `HoverZoneTrigger` (SAR, hostile MedEvac,
water pickup, fast-rope).

- **T = minimum required time** for the operation (fixed per task type, e.g.
  5 minutes). It is a floor: it can never go below this value.
- **B = hover stability factor**, acting **only as a malus**. The more
  unstable the pilot (high speed / deviation from center), the slower the
  timer advances, stretching the effective time beyond T. It can never speed
  completion up below T. This realistically models the fact that a wobbly
  hover prolongs the recovery, without making T variable downwards.
- **Time window**: from hover entry a window wider than T starts (e.g. 20-25
  min for a 5-minute task) within which to complete. Window expired ->
  mission failed with a narrative outcome (the missing person drowned, the
  patient died, etc.). The window exists precisely to absorb the time lost
  when the hover is imprecise and the timer slows down.
- **Weather**: wind in DCS already acts on the flight model, so windy
  conditions make the hover objectively harder **with no extra code** — the
  B malus captures it automatically by measuring the real deviation. Start
  with this passive effect only; do NOT add a scripted weather-based
  tolerance reduction without testing, because added on top of the physical
  wind effect it risks penalizing the same cause twice and making the
  operation unplayable.
- Native feasibility: stability and deviation are measured with
  `Unit:getVelocity()` and `Unit:getPoint()` sampled in the loop. No external
  framework.

## Scoring and leaderboard

- **Session score** (decided): Lua variable in memory, incremented per
  completed task, reset at mission end. No file, no hook, no persistence. It
  is intra-session feedback, not a historical ranking.
- **Difficulty weight per task type (to fix NOW, not later)**: each task's
  points must be scaled by a difficulty multiplier decided per type (a sea
  SAR with waves is worth more than a cargo run over flat terrain), otherwise
  whoever does ten easy tasks beats whoever does two hard tasks well. This
  goes inside the scoring function: changing it later means recomputing
  everything.
- **Pure scoring function**: design the calculation as a function
  `task + quality + time -> points`, independent from where the total lives.
  This way today's session score and a possible future persistent leaderboard
  use the same math; persistence is a layer added on top, not a prerequisite.
- **Live intra-session competition**: a shared session score visible to all
  (`outTextForCoalition` or F10 panel) creates real-time competition among
  those present, with no persistence issues.
- **Cross-session persistence (OPEN DECISION)**: we do not use the classic
  DCS values (kills/deaths), the metric is entirely our own, so
  `S_EVENT_SCORE` is useless; the problem is **storing** our values. Three
  options, the choice depends on a requirement still to be fixed — must the
  ranking update **during** the session or is consolidating it **at mission
  end** enough?
  - *Native persistence* (`world.setPersistenceHandler`): commits at the end
    of the simulation. Fine for a ranking consolidated at mission end/restart,
    NOT live.
  - *Server-side hook + external file*: hooks run outside the sandbox, write
    files freely, support live updates. Maximum freedom.
  - *`env.info` to `dcs.log` + external parser*: the simplest on the mission
    side, moves the ranking logic outside DCS.

## Dressed areas (scenery)

- **Decision**: dressed areas (refugee camp, forward medical camp, C-130
  loading area) live in a **fixed trigger zone defined in the ME**. Inside
  the zone, scenic static objects are spawned via `coalition.addStaticObject`
  (native). No trigger zone is created at runtime — no native API exists for
  it, and none is needed: the zone already exists from the ME.
- **No runtime flatness check**: since the point is hand-picked in the ME,
  flatness is guaranteed at design time by placing the zone on flat ground.
  The `land.getHeight` check is only for points picked randomly by code,
  which is not the case here.
- **Same zone+condition pattern already used elsewhere**: "unit in zone ->
  can be resupplied" (C-130), "player landed at the medical camp -> MedEvac
  delivery" (zone detection, NOT `S_EVENT_LAND`). The dressing is just the
  scenic skin of zones the system already manages.
- Prefer static objects (passive, cheap) over AI units for pure scenery; keep
  an eye on the count if several areas are active at once (parallel events
  principle).

## Firefighting

- **Helicopters**: `HoverZoneTrigger` module over a body of water, safe
  altitude (not skimming), minimum dwell -> on success, spawn of a Cargo
  object with mass (to validate whether the spawn works reliably on open
  water) -> player notification -> loading via the native radio command ->
  release over an active fire zone.
- **C-130**: no in-flight scooping (not operationally consistent with
  real-world use; that is the job of amphibians like the Canadair CL-215/415).
  Ground reload in a dedicated zone/FARP (logical state, no native
  "retardant" in DCS) and a line drop overflying a polygon corridor at
  moderate altitude (roughly 150-250 m, not 1-2 m).
- **C-130 as spotter**: if present in a firefighting macro-region, it
  locates the active fires and passes their coordinates to the helicopters
  (message or F10 marker), giving a gameplay reason to keep it orbiting the
  area.
- **FireZoneManager**: random ignition among the pool points (or rejection
  sampling in homogeneous areas), smoke/fire effect with
  `effectSmokeBig`/`effectSmokeStop`, active/extinguished state per zone.

## Mountain SAR

- Spawn of a missing person on the ground with an assigned radio frequency.
  **A scriptable beacon exists** (`trigger.action.radioTransmission()` with a
  9-digit frequency in Hz, or the `activateBeacon` command for NDB/VOR/TACAN
  types), but it is usable only by modules that can home on radio beacons
  (Mi-8, Huey, Gazelle, AH-64D via NDB preset), it requires an .ogg audio
  file inside the mission and is reported as finicky to get working
  reliably. For the other modules, fall back to coordinates passed by
  message.
- A C-130 present in the area can act as spotter and pass the coordinates
  down.
- **Extraction**: same `HoverZoneTrigger` module used for the firefighting
  water pickup — the helicopter must hold a hover over the missing person's
  zone for a minimum time. On success: the ground unit representing the
  missing person is despawned (as if loaded aboard) and the helicopter's
  state records the rescue. On delivery to the hospital no person needs to be
  respawned: just consume a "subject aboard -> rescued" state flag (see the
  MedEvac section for the hospital landing detection mechanism, which CANNOT
  rely on `S_EVENT_LAND` unless the pad is a defined FARP/airbase).
- Possible partial reuse of the logic already present in
  `527th_CSARSystem.lua` (frequency handling, mission ID fallback).

## Sea SAR

- Castaways/boats in distress as the target (possibly using sinking boat
  mods for the scenic effect).
- The C-130 in the area acts as spotter for the vessel and passes the
  coordinates to the helicopters.
- **Extraction**: same `HoverZoneTrigger` used for mountain SAR and the
  firefighting water pickup, with the unit/raft placed on open water. Unlike
  the Cargo object of the water pickup (spawn on water to be verified), a
  floating unit/static is a standard DCS use case (naval unit spawns on
  water), so the technical risk here is low. Same despawn-on-success logic
  as mountain SAR.

## Police — Chase

- Pool of 30-40 points placed on the real crossroads of a city area
  (close-range macro-region).
- Route generated by choosing the next waypoint among the points near the
  current one (local random walk, not a random jump across the whole map),
  with the **"On Road"** waypoint action to exploit DCS's native road
  pathfinding. The reliability on different crossings/hops must be validated
  empirically before trusting the whole pool.
- Capture mechanics: "pressure" that rises while the helicopter is within
  the car's radius and decays when it is lost, fixed threshold at 100% for
  the arrest. Rise/decay rates randomized once at chase start (not every
  tick), for variety while staying readable. Extra variability possible by
  giving the car a random top speed at event start.
- State kept per unit/group to support several parallel chases in the same
  city.

## Police — SWAT

- Team boarding, drop-off on rooftops/buildings for robbery/hostage style
  scenarios.
- Precision landing on rooftops is unreliable on many building meshes
  (gear/skids without clean collision). No real touchdown is used: insertion
  is by **fast-rope**, the same `HoverZoneTrigger` module already used for
  firefighting/SAR/MedEvac — helicopter hovering over the rooftop/LZ for a
  minimum time, then scripted spawn of the team on the ground (no native
  fast-rope equivalent exists in DCS, so it stays virtual state like the
  C-130's retardant).
- The number of soldiers spawned when the hover succeeds must come from a
  state tracked at boarding time at the base (same pattern used for the
  cargo tier), not from a value decided at drop-off.
- To verify: reliability of infantry spawns on rooftop meshes. Presumably
  lower risk than a helicopter touchdown (no physical contact to handle),
  but not taken for granted without testing.
- **Verified note**: the native troop embark/disembark tasks (`embarking`,
  `embarkToTransport`) are AI-to-AI systems, they force the AI helicopter to
  land and do not allow free choice of the drop zone. They are not suitable
  for a player-flown fast-rope: the correct path is the scripted spawn of the
  infantry group via `coalition.addGroup` in pure Lua (no external framework
  dependency) when the hover completes.

## Civil cargo transport — Tier system

- Same zone logic already validated elsewhere: macro-region + pool of curated
  loading points, with random generation of the active point.
- **Fixed mass tiers** (light / medium / heavy + a dedicated heavy-lift
  tier), not recomputed based on the vehicle that selects them: a real
  physical load (beam, pallet of bricks) has an objective mass independent of
  who lifts it, unlike water which can be dosed in flight — relative bands
  would have been inconsistent with the simulation fiction.
- **Label based on the required capacity threshold** ("requires heavy-lift
  aircraft"), not on the specific aircraft name: avoids adding a new
  exclusive label every time a new heavy aircraft joins the roster.
- **Heavy-lift tier generated only if at least one type meeting the
  threshold is present in the mission** (dynamic detection, gate), otherwise
  the point stays at the normal "heavy" tier — avoids loading points that
  are structurally unreachable in sessions without the right aircraft.
- **Arrival filter at the point**: warning (not a block) if the player's
  helicopter type is not suited to the tier generated at that point,
  computed from the same type->capacity table already planned for the
  limits. Recomputed on `S_EVENT_BIRTH`, not only at initial spawn, to cover
  mid-session slot changes in multiplayer.
- **Tier change on request**: F10 radio entry at the loading point ->
  Light/Medium/Heavy submenu, free selection in both directions (not only
  downgrades: a heavy-lift aircraft may randomly receive a light tier, which
  is no challenge for it). On selection: despawn of the current Cargo,
  respawn with the chosen tier's mass at the same position, with a delay
  (20-30 s, justified as re-rigging time) to give the change a real cost —
  without the delay the tier system becomes decorative, because every player
  would instantly adjust the load to their own aircraft.
- The actual kg values for each tier must be anchored to the real external
  load capacity of the modules planned for the mission (UH-1H, Mi-8, CH-47F
  etc.), not invented at the desk — still to be verified with real data
  before fixing the final table. Note: lift capacity is NOT exposed by the
  API per unit type (the descriptor provides `massEmpty` and `fuelMassMax`,
  not a max external load), so this table must be maintained by hand as
  configuration data.
- **Verified on native documentation** (`coalition.addStaticObject`): cargo
  objects have the native fields `mass` (weight in kg) and `canCargo`
  (boolean, whether it can be slung). No external framework required.
  **Important caveat**: the native documentation warns that *some* cargo
  object types have a fixed mass and ignore the passed value. So the tier
  generator must use a cargo type that accepts a custom mass, to be confirmed
  in the ME for the chosen type — it is not guaranteed that any cargo object
  accepts an arbitrary mass. The StaticObject class exposes no method to
  change the mass at runtime, so the tier change must be done with a
  despawn + respawn of the object.

## MedEvac

- Recovery of casualties to a hospital helipad, with a criticality timer
  decaying over time as a score variable.
- **Hospital delivery — careful, verified technical correction**:
  `S_EVENT_LAND` fires ONLY on landing on a recognized Airbase, FARP or ship
  object (the event's `place` field), NOT on terrain or arbitrary building
  covers. Hospital pads on Syria are generally not defined FARP/airbase
  objects, so `S_EVENT_LAND` does not fire on them. Delivery must be detected
  with the same zone scheme (helicopter still/low inside a hand-placed zone
  on the pad for X seconds), NOT with `S_EVENT_LAND`. `S_EVENT_LAND` remains
  valid only if the delivery pad is actually a FARP defined in the ME.
- **Recovery in a hostile setting** (accident, unsafe LZ, battlefield
  terrain): same `HoverZoneTrigger` module as firefighting/SAR — on success,
  the casualty unit is despawned as if loaded aboard.
- On delivery no person needs respawning: just consume the "subject aboard ->
  rescued" state flag when the landing in the zone is detected, unlike the
  SWAT fast-rope where the team must remain physically present and
  operational after the drop.
- Also reusable in an insurgent/military scenario with the same scheme,
  changing only the narrative skin of the recovered unit.

## Other ideas proposed during the discussion

- **Infrastructure reconnaissance** (power lines, pipelines): low-level
  patrol along a corridor, random anomaly detection along the track. Reuses
  the same polygon corridor + AGL altitude system already planned for the
  firefighting C-130.
- **Flood relief**: delivery of supply crates to isolated areas by
  helicopter, a narrative variant of the cargo transport.

## Points clarified through documentation checks

Sources: native Hoggit wiki documentation (`coalition.addStaticObject`,
`DCS_event_land`, `radioTransmission`, `activateBeacon`). All the APIs cited
are native to the DCS scripting engine: no dependency on MIST, MOOSE or CTLD
in the implementation. Where those frameworks' sources were consulted, it
served only to confirm how they call the underlying native functions.

- **`S_EVENT_LAND` fires only on recognized Airbase, FARP or ship** (`place`
  field), NOT on arbitrary terrain or covers. Impacts MedEvac and any
  hospital delivery: use zone detection, not the event, except for pads that
  are defined FARPs.
- **Scriptable beacon: it exists** (`trigger.action.radioTransmission`,
  `activateBeacon`), but only some modules can home (Mi-8, Huey, Gazelle,
  AH-64D via NDB), it needs an .ogg file and can be finicky. Textual
  coordinate fallback for the others.
- **Lift capacity NOT exposed per type** by the API — type->capacity table
  to maintain by hand as config.
- **Native troop embark/disembark tasks = AI-to-AI**, they force the landing
  and do not let you choose the zone. Player-driven fast-rope needs a
  scripted spawn via `coalition.addGroup` in pure Lua.
- **Cargo mass = native `mass`/`canCargo` fields** in
  `coalition.addStaticObject`, but some cargo types have a fixed mass: the
  type chosen for the tiers must be verified in the ME. Changing it requires
  recreating the object (no runtime setter).
- **"On Road" pathfinding is a known problem** (bug reports across several
  versions, 2.8 up to 2025), not just an unknown: units can stray or get
  stuck. Test early and plan a fallback.

## Points requiring empirical in-game testing (not solvable at the desk)

- Reliability of Cargo object spawns over open water (the `mass` field
  works, but the behavior on water must be tried in the ME).
- Real behavior of "On Road" pathfinding on the specific points/crossroads
  of the chosen map.
- Reliability of infantry spawns on rooftop meshes (for the SWAT fast-rope).
- Which troop transport/drop system the Black Hawk module planned for the
  mission exposes (verify whether it is an official ED module or third-party
  mod, and what it actually supports).
- Naming convention for the new zones/points, to be defined consistently
  with the scheme already used in the main project (prefix + numeric index).
- Real kg values for each cargo tier, anchored to the actual lift capacity
  of the planned modules.

## Open questions for the team

- Preferences on realism vs arcade for the firefighting C-130 (ground rearm
  + line drop, option already chosen, but to be confirmed with the group).
- Leaderboard: live update during the session (needs a server-side hook) or
  consolidation at mission end (native persistence is enough)? Decides which
  of the three options to implement.
- Other civil mission categories to add to the list?
- Development priority: which module to start with?

## Non-negotiable implementation constraints

- **Pure native Lua**: no dependency on MIST, MOOSE, CTLD or other
  frameworks. All the APIs used must belong to the DCS scripting engine.
- The items in the "Points requiring empirical in-game testing" section are
  NOT solvable by writing code at the desk: they must be tried in the
  Mission Editor before or during implementation. Do not assume they work as
  described without verification.
