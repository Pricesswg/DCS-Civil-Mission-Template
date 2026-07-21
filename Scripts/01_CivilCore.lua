----------------------------------------------------------------------
-- DCS Civil Mission Template - Core
-- File: 01_CivilCore.lua  (load FIRST, before the intervention files)
--
-- Pure native DCS scripting Lua. No MIST / MOOSE / CTLD.
--
-- Provides everything shared by the intervention modules:
--   - central configuration (CIV.Config)
--   - logging, math, coordinate formatting (LL DDM + MGRS)
--   - mission scanner: trigger zones (circle AND polygon, with properties)
--     and late-activated spawn templates, read from env.mission
--   - zone areas + curated point pools with min-distance checks
--   - player registry (S_EVENT_BIRTH, covers MP slot changes)
--   - messaging, F10 map marks and circles
--   - spawn helpers (template-based with type fallback)
--   - HoverZoneTrigger: shared hover detection (floor time T, stability
--     malus B, failure window)
--   - session score system (pure scoring function + live leaderboard)
--   - zone dressing kits (static scenery)
--   - event director + admin F10 menu
--
-- Zone/template scanning and polygon support adapted from the
-- 527th CSAR System by {527th} ienatom and {104WW} Price.
----------------------------------------------------------------------

CIV = CIV or {}
CIV.VERSION = "0.3.0"

----------------------------------------------------------------------
-- CONFIGURATION
-- Values marked TO VALIDATE must be confirmed in the Mission Editor /
-- in-game before being considered final (see docs/FATTIBILITA.md).
----------------------------------------------------------------------

CIV.Config = {
  -- Country used for scripted spawns: CJTF Blue (Combined Joint Task Force)
  -- gives access to every unit without country restrictions. Add CJTF Blue
  -- to the blue coalition in the ME mission options.
  countryId = country.id.CJTF_BLUE,
  coalition = coalition.side.BLUE,
  debug     = true,                  -- verbose logging to dcs.log
  adminMenu = true,                  -- F10 "Admin" submenu to start events manually (testing)

  ------------------------------------------------------------------
  -- Trigger zone names. PREFIX match: any zone whose name STARTS with
  -- the string belongs to that pool ("CIVIL Fire Point Alpha", ...).
  -- Zones may be circular or polygon (quad) zones: both are read from
  -- env.mission with their vertices and properties.
  ------------------------------------------------------------------
  zones = {
    fireRegion        = "CIVIL Fire Region",         -- firefighting macro-region (spotter + C-130 line drops)
    firePoints        = "CIVIL Fire Point",           -- curated fire ignition points
    fireStations      = "CIVIL Fire Station",         -- fire brigade depots (trucks depart from the nearest)
    waterPoints       = "CIVIL Water Point",          -- helicopter water pickup points (on water)
    c130Reload        = "CIVIL C130 Reload",          -- ground retardant reload zone (user-built static area)
    sarMountainRegion = "CIVIL SAR Mountain Region",
    sarMountainPoints = "CIVIL SAR Mountain Point",
    sarSeaRegion      = "CIVIL SAR Sea Region",
    sarSeaPoints      = "CIVIL SAR Sea Point",        -- on OPEN WATER (a boat spawns there)
    policePoints      = "CIVIL Police Point",         -- 30-40 points on real city crossroads
    swatBase          = "CIVIL SWAT Base",
    swatPoints        = "CIVIL SWAT Point",           -- rooftops / urban LZs
    cargoPoints       = "CIVIL Cargo Point",
    cargoDestination  = "CIVIL Cargo Destination",
    medevacPoints     = "CIVIL Medevac Point",
    casevacPoints     = "CIVIL Casevac Point",        -- battlefield casualty extraction LZs
    hospitals         = "CIVIL Hospital",             -- hospital pads: delivery is ZONE-based, never S_EVENT_LAND
    vesselSpawn       = "CIVIL Vessel Spawn",         -- harbor zones where stock rescue boats are launched
    reconPoints       = "CIVIL Recon Point",          -- inspection corridor waypoints (anomalies spawn on them)
    vipPads           = "CIVIL VIP Pad",              -- passenger shuttle helipads (needs at least 2)
    dropZones         = "CIVIL Drop Zone",            -- emergency supply drop zones (score = accuracy)
    mediaBases        = "CIVIL Media Base",           -- media ground crew depots (the van rolls from here)
    airshowZones      = "CIVIL Airshow",              -- aerobatic display box (routine flown inside)
    seaSpawn          = "CIVIL Sea Spawn",            -- merchant traffic: route start zones (random point inside)
    seaLane           = "CIVIL Sea Lane",             -- merchant traffic: route waypoint pool (random walk)
    seaDespawn        = "CIVIL Sea Despawn",          -- merchant traffic: route end zones (ship is cleared there)
    restricted        = "CIVIL Restricted",           -- military areas closed to civil traffic (intercept tasks)
    convoyStart       = "CIVIL Convoy Start",         -- prisoner convoy departure zones
    convoyEnd         = "CIVIL Convoy End",           -- prisoner convoy destination zones
    fireLZ            = "CIVIL Fire LZ",              -- optional casualty LZ next to a structural fire point
    touristSites      = "CIVIL Tourist Site",         -- sightseeing tour orbit spots
  },

  ------------------------------------------------------------------
  -- Late-activated template groups (optional, CSAR-style). If a template
  -- with the given name prefix exists in the mission, spawns are cloned
  -- from it; otherwise the hardcoded fallback types below are used.
  ------------------------------------------------------------------
  templates = {
    survivor = "CIVIL Survivor",   -- ground group: SAR mountain / medevac casualty
    casualty = "CIVIL Casualty",   -- ground group: battlefield CASEVAC casualty
    boat     = "CIVIL Boat",       -- ship group: SAR sea target
    sinking  = "CIVIL Sinking",    -- ship group: sinking-ship wreck (optional visual)
    raft     = "CIVIL Raft",       -- ship group: life raft (sinking scenario survivor)
    vessel   = "CIVIL Vessel",     -- ship group: spawned rescue boat
    swatTeam = "CIVIL SWAT Team",  -- ground group: SWAT squad (unit count from template scaled at spawn)
    fugitive = "CIVIL Fugitive",   -- vehicle group: police chase car
    fireTruck= "CIVIL Fire Truck", -- vehicle group: fire brigade truck
    anomaly  = "CIVIL Anomaly",    -- ground group: recon corridor anomaly (optional visual)
    vip      = "CIVIL VIP",        -- ground group: waiting passenger (optional visual)
    supplies = "CIVIL Supplies",   -- ground group: landed supply crates (optional visual)
    mediaVan = "CIVIL Media Van",  -- vehicle group: media ground crew (needed for the van task)
    merchant = "CIVIL Merchant",   -- ship group: sea traffic freighter
    airliner = "CIVIL Airliner",   -- plane group: ambient air traffic (type/livery source)
    tourists = "CIVIL Tourists",   -- ground group: tourist party waiting at the pad (optional visual)
    convoy   = "CIVIL Convoy",     -- vehicle group: police car, school bus, tail car (in that order)
    ambush   = "CIVIL Ambush",     -- vehicle group: two armed men and a car; build it under a
                                   -- HOSTILE country if you want the gunmen to actually shoot
  },
  fallbackTypes = {
    survivor   = "Soldier M4",
    boat       = "ZWEZDNY",        -- TO VALIDATE on the chosen map
    raft       = "speedboat",      -- life raft fallback, TO VALIDATE type name
    rescueBoat = "speedboat",      -- stock small boat, TO VALIDATE type name
    swat       = "Soldier M4",
    fugitive   = "LandRover_ah",   -- TO VALIDATE on the chosen map
    fireTruck  = "HEMTT TFFT",     -- stock airfield fire truck, TO VALIDATE
    merchant   = "HandyWind",      -- stock bulk freighter, TO VALIDATE type name
    airliner   = "Yak-40",         -- stock small airliner (ambient traffic)
    convoyCar  = "LandRover_ah",   -- convoy fallback: lead and tail car, TO VALIDATE
    convoyBus  = "IKARUS Bus",     -- convoy fallback: the school bus, TO VALIDATE
  },

  -- Automatic scenery dressing of fixed zones. Everything is OFF by
  -- default: the C-130 reload and the CASEVAC LZs are USER-BUILT static
  -- areas, and hospital pads usually sit on real map hospitals that come
  -- already dressed (set hospitals = true for a bare map).
  autoDress = {
    c130Reload = false,
    hospitals  = false,
    -- Extra assignments: dress any zone prefix with any kit from
    -- CIV.Dressing.kits (add your own kits there). Example:
    --   { prefix = "CIVIL Refugee Camp", kit = "refugee_camp" },
    custom = {},
  },

  ------------------------------------------------------------------
  -- HoverZoneTrigger parameters per task type.
  -- T       = minimum required time (s); hard floor, can never shrink
  -- window  = total window (s) from hover start; expired -> mission failed
  -- B       = stability malus factor (only slows progress, never speeds it)
  -- maxSpeed (m/s) / radius (m) / minAGL / maxAGL (m) = valid hover envelope
  ------------------------------------------------------------------
  hover = {
    waterPickup = { T = 60,  window = 600,  B = 2.0, maxSpeed = 3.0, radius = 40, minAGL = 8, maxAGL = 30 },
    sarMountain = { T = 300, window = 1500, B = 2.0, maxSpeed = 2.5, radius = 30, minAGL = 3, maxAGL = 25 },
    sarSea      = { T = 300, window = 1500, B = 2.5, maxSpeed = 2.5, radius = 30, minAGL = 5, maxAGL = 25 },
    medevac     = { T = 240, window = 1200, B = 2.0, maxSpeed = 2.5, radius = 30, minAGL = 3, maxAGL = 25 },
    casevac     = { T = 240, window = 1200, B = 2.5, maxSpeed = 2.5, radius = 25, minAGL = 3, maxAGL = 25 },
    fastRope    = { T = 90,  window = 900,  B = 3.0, maxSpeed = 2.0, radius = 20, minAGL = 5, maxAGL = 30 },
  },

  ------------------------------------------------------------------
  -- Scoring. Difficulty weights are fixed NOW (changing them later would
  -- mean recomputing history). points = base * (0.5 + 0.35*quality +
  -- 0.15*timeFactor) * mult. See CIV.Score.compute.
  ------------------------------------------------------------------
  score = {
    base = {
      fireHelo    = 15,
      fireC130    = 12,
      sarMountain = 20,
      sarSea      = 25,     -- sea SAR with waves is worth more than flat transport
      sinking     = 12,     -- per survivor recovered from a sinking (many per event)
      medevac     = 20,
      casevac     = 22,     -- battlefield extraction: hostile setting premium
      chase       = 15,
      swat        = 20,
      transport   = 10,     -- multiplied by the cargo tier
      recon       = 12,     -- corridor anomaly found and reported
      vip         = 10,     -- passenger shuttle, quality = ride comfort
      media       = 8,      -- live footage of an active event
      spotter     = 6,      -- rescue subject identified from the air
      airAttack   = 8,      -- fire marked and extinguished while coordinated
      medTransfer = 14,     -- long-range air ambulance leg after a hospital delivery
      trafficWatch= 6,      -- airplane overwatch assist on a police chase arrest
      firewatch   = 5,      -- fire spotted early by a preventive patrol
      supplyDrop  = 10,     -- emergency airdrop crate on target, quality = accuracy
      airshow     = 1,      -- aerobatic routine: figure points are summed into the mult
      coastGuard  = 16,     -- merchant inspection (full score when a suspect is boarded)
      intercept   = 14,     -- restricted-area violator identified and escorted out
      convoy      = 18,     -- prisoner convoy escorted to destination, quality = coverage
      convoySpot  = 8,      -- ambush reported before the convoy reached it
      convoyMalus = -10,    -- NEGATIVE: convoy lost to an unreported ambush on your watch
      tour        = 12,     -- sightseeing tour completed, quality = ride comfort
    },
    tierMult  = { LIGHT = 1.0, MEDIUM = 1.5, HEAVY = 2.2, HEAVY_LIFT = 3.0 },
    -- Severity score multiplier: mult = base + perPoint * severity.
    -- ANCHORED NOW (severity 5 = x1.0): changing it later skews history.
    severity  = { base = 0.7, perPoint = 0.06 },
    broadcast = true,       -- coalition-wide announce on every completed task (live competition)
  },

  ------------------------------------------------------------------
  -- Civil transport: fixed mass tiers (kg). TO VALIDATE against the real
  -- external load capacity of the mission's modules. NOTE: some cargo
  -- object types ignore the custom 'mass' field: confirm the types in ME.
  ------------------------------------------------------------------
  cargo = {
    tiers = {
      LIGHT      = { kg = 600,  cargoType = "uh1h_cargo" },
      MEDIUM     = { kg = 1500, cargoType = "container_cargo" },
      HEAVY      = { kg = 3000, cargoType = "iso_container_small" },
      HEAVY_LIFT = { kg = 8000, cargoType = "iso_container" },  -- generated only if a heavy-lift type is present
    },
    tierWeights      = { LIGHT = 35, MEDIUM = 35, HEAVY = 30 },  -- random weights %; HEAVY_LIFT gated separately
    tierChangeDelay  = 25,     -- s, real cost of changing tier via F10 (despawn -> wait -> respawn)
    heavyLiftMinKg   = 6000,   -- capacity threshold that unlocks the HEAVY_LIFT tier
    maxActive        = 3,
    warnRadius       = 1000,   -- m, "aircraft not suited to this tier" warning radius

    -- Delivery PRIORITY (the transport flavor of the severity scale): one
    -- roll per loading point. It multiplies the score and sets a time to
    -- live: urgent loads expire sooner if nobody delivers them.
    priority = { min = 1, max = 10 },
    priorityTtl = { atMin = 7200, atMax = 2700 },  -- s: priority 1 -> 2h, priority 10 -> 45min

    -- Supply airdrop into the cargo destination zone (official C-130
    -- module): CRATE type containers landing inside CIVIL Cargo Destination
    -- score as supply deliveries. Same dual-channel detection and the same
    -- validation caveat as fire.airdrop (differentiated crates: drums for
    -- retardant, crates for supplies).
    airdrop = {
      enabled = true,
      containerTypes = { "Crate", "Container" },   -- supply crates, TO VALIDATE
      matchAnyObject = true,     -- accept any foreign object until types are validated
      scoreMult = 1.0,           -- transport score multiplier per delivered container
      creditRadius = 8000,       -- m, nearest player airplane gets the score
    },
  },

  -- Aircraft type -> external load capacity (kg). MAINTAINED BY HAND:
  -- the API does not expose lift capacity per type. Values TO VALIDATE.
  capacity = {
    ["UH-1H"]     = 1700,
    ["Mi-8MT"]    = 3000,
    ["Mi-24P"]    = 2400,
    ["SA342M"]    = 700,
    ["SA342L"]    = 700,
    ["CH-47Fbl1"] = 10800,
    ["UH-60L"]    = 4000,      -- if mod present: verify exact type name
    ["OH58D"]     = 900,
  },

  ------------------------------------------------------------------
  -- Firefighting
  ------------------------------------------------------------------
  fire = {
    maxActive        = 3,
    autoIgnite       = { min = 600, max = 1800 },  -- s between automatic ignitions

    -- SEVERITY: every fire carries an integer-ish severity from 1 to 10.
    -- A small fire spawns as a single smoke/fire effect; as severity grows
    -- new sub-fires light up around the anchor point (visual spread), up to
    -- maxEffects simultaneous effects (performance cap: effect size keeps
    -- scaling past the cap). Suppression subtracts severity; 0 = out.
    severity = {
      initial    = { min = 1, max = 3 },      -- rolled once at ignition
      max        = 10,
      growEvery  = { min = 300, max = 900 },  -- s per +1 severity, randomized ONCE per fire
      maxEffects = 5,                          -- simultaneous smoke/fire effects cap
    },

    -- Visual progression: every smoke/fire column starts SMALL and
    -- escalates one preset step (small -> medium -> large -> huge) for
    -- every escalateEvery seconds it goes unattended. Severity decides how
    -- MANY columns burn, the age of each column decides how BIG it looks:
    -- an ignored fire visibly takes hold even before severity grows. A
    -- suppression hit knocks every column back one step, so drops read on
    -- the fire immediately.
    visuals = {
      escalateEvery  = 450,   -- s per size step (small at 0, huge at ~22 min)
      knockbackOnHit = true,  -- water/retardant hit shrinks the columns one step
    },

    heloDropSeverity = 2.0,     -- severity removed per helicopter water drop
    c130DropPerSec   = 0.25,    -- severity removed per second during the line drop
    c130DropSeconds  = 10,      -- line drop duration

    -- Fire kinds, picked by weight at ignition. smokeOnly kinds use the
    -- thick-smoke effect presets (a dump burns dark and slow), growMult
    -- speeds up or slows down the severity growth cadence.
    --
    -- A fire POINT can force its kind: if the zone name contains a kind's
    -- match fragment ("CIVIL Fire Point Building Hotel"), every ignition
    -- there is that kind. The GM can also force it: "civil fire building 7".
    --
    -- Per-kind capability flags (default true when omitted):
    --   airAttack = false  the smoke-mark pass does not work on this kind
    --   retardant = false  C-130 line drops and retardant airdrops do not
    --                      suppress it (helicopter water and the ground
    --                      brigade still do)
    --
    -- Per-kind VISUAL behavior:
    --   startSize = 1..4  preset step every column STARTS at (default 1 =
    --                     small). Landfill and industrial fires burn hard
    --                     from the first minute: they start LARGE and age
    --                     to huge.
    --   compact = true    extra columns pile up almost on the same spot:
    --                     more total smoke, same footprint. For fires that
    --                     get contained and do not spread (dumps, plants,
    --                     buildings). Forest fires keep spreading over the
    --                     zone instead.
    kinds = {
      { name = "forest fire",     weight = 70, smokeOnly = false, growMult = 1.0, match = "forest" },
      { name = "landfill fire",   weight = 15, smokeOnly = true,  growMult = 0.6, match = "landfill",
        startSize = 3, compact = true },
      -- an industrial/factory fire is unlikely to break out while a wildfire
      -- outbreak is under way: suppressedBy drops this kind's pick weight to
      -- near zero if any active fire's kind matches one in the list. Scattered
      -- forest fires can still coexist among themselves.
      { name = "industrial fire", weight = 15, smokeOnly = false, growMult = 1.5, match = "industrial",
        startSize = 3, compact = true, suppressedBy = { "forest" } },
      -- Building fires NEVER roll on generic points (weight 0): they only
      -- ignite on fire points whose zone name contains "building", or on
      -- GM command. Structural firefighting is precision work: helicopter
      -- drops and the ground brigade only, no retardant, no smoke marking.
      { name = "building fire",   weight = 0,  smokeOnly = false, growMult = 0.8, match = "building",
        airAttack = false, retardant = false, compact = true, structural = true },
    },

    -- STRUCTURAL fires are not an air firefighting task: the brigade
    -- pumpers put the flames out on their own (their suppression is
    -- multiplied by brigadeMult on these fires), while the AIR job is the
    -- CASUALTY: a MedEvac spawns next to the burning building, and the
    -- rescue helicopters carry the injured to the hospital. Firefighting
    -- helicopters get the callout too, with the warning that water is not
    -- needed there.
    structural = {
      casualtyEvent   = true,  -- spawn a MedEvac next to a structural fire
      casualtyOffsetM = 60,    -- m from the flames (hover room)
      brigadeMult     = 3.0,   -- brigade suppression multiplier on these fires
      -- Landing point control: place an optional "CIVIL Fire LZ" zone near
      -- the building (within lzSearchRadius) and the casualty spawns
      -- exactly there, hand-picked in the ME instead of a blind offset
      -- (buildings rarely leave hover room in a random direction). Either
      -- way the point is marked with GREEN smoke at event start.
      lzSearchRadius  = 500,
      smokeLZ         = true,
    },

    -- Fire brigade: when a fire ignites, trucks depart from the nearest
    -- "CIVIL Fire Station" zone and drive to it ("On Road" with the same
    -- stall watchdog used by the police chase). Once on scene they apply
    -- continuous ground suppression, so fewer air passes are needed.
    trucks = {
      enabled        = true,
      count          = 2,      -- trucks per fire
      speed          = 20,     -- m/s route speed (~72 km/h): real maps are big
                               -- and real fire stations are far, the trucks
                               -- run with sirens on
      suppressRadius = 250,    -- m from the fire to count as "on scene"
      suppressPerMin = 0.6,    -- severity removed per minute while on scene
    },
    c130DropAGL      = { min = 120, max = 300 },   -- valid AGL band (nominal 150-250 m)
    dropRadius       = 300,     -- m, max distance from a fire for a drop to count
    c130ReloadTime   = 120,     -- s stationary inside the reload zone after requesting
                                -- the load via F10 (loading is opt-in: taking off clean
                                -- and just orbiting as a spotter needs no interaction)
    spotterInterval  = 180,     -- s between spotter reports

    -- AIR ATTACK role for the light fixed-wing (OV-10 Bronco mod, MB-339,
    -- L-39, C-101, Yak-52, Christen Eagle...): they do NOT haul retardant
    -- (the reload refuses them), they direct the traffic between tankers
    -- and helicopters. Their F10 command smoke-marks the nearest fire
    -- (like the real smoke rockets / trail smoke): while the mark is hot,
    -- every drop on that fire scores a coordination bonus, and the marker
    -- gets an assist when the fire goes out. Type names are
    -- substring-matched, TO VALIDATE against the installed mods.
    airAttack = {
      types = { "OV-10", "Bronco", "MB-339", "L-39", "C-101",
                "Yak-52", "Christen" },
      markRadius = 2500,    -- m, max distance from the fire to mark it
      maxAGL = 600,         -- m, must be below this to mark
      coordination = {
        seconds = 300,      -- how long the mark stays hot
        dropBonus = 1.25,   -- score multiplier for drops on a marked fire
      },
    },

    -- FIREWATCH preventive patrol: an airplane sweeping a fire region while
    -- no fire burns there keeps that region "watched". A fire igniting in a
    -- watched region is called in early: it starts smaller (severityCut off
    -- the initial roll) and the patrolling pilot is credited. Rewards flying
    -- the quiet stretches of the session, not only chasing the callouts.
    -- GM-commanded fires ("civil fire 7") keep their commanded severity.
    firewatch = {
      enabled     = true,
      window      = 900,   -- s a patrol pass keeps the region watched
      severityCut = 2,     -- severity removed from the initial roll
    },

    -- Physical retardant airdrop (official C-130 module). See the generic
    -- airdrop notes in CIV.Airdrop below: drops are detected from outside
    -- the cargo bay (S_EVENT_SHOT weapon tracking + object scan), both
    -- channels TO VALIDATE in-game against the official module.
    -- Differentiated crates: retardant uses DRUM/BARREL type containers,
    -- supply delivery (cargo.airdrop) uses CRATE type containers. Until the
    -- module's real type names are validated, matchAnyObject keeps a
    -- catch-all behavior and the impact LOCATION differentiates (fires vs
    -- cargo destination); once validated, fill containerTypes and set
    -- matchAnyObject = false to enforce crate-type separation.
    airdrop = {
      enabled = true,
      containerTypes = { "Barrel", "Drum", "Fuel" },  -- retardant drums, TO VALIDATE
      matchAnyObject = true,      -- accept any foreign object until types are validated
      severityPerContainer = 2.0, -- severity removed per container on target
      creditRadius = 8000,        -- m, nearest player airplane within this range gets the score
    },
    usePhysicalCargo = false,   -- true = spawn a mass Cargo object on water (EXPERIMENTAL, test in ME first)
    waterCargoType   = "uh1h_cargo",
    waterCargoKg     = 1000,
  },

  ------------------------------------------------------------------
  -- Rescue (SAR mountain/sea share the engine; medevac adds criticality)
  ------------------------------------------------------------------
  rescue = {
    -- Spawn region-based events (SAR mountain/sea, sinking) inside the
    -- macro-region that currently has a player, so nobody has to cross
    -- half the map for a random callout. Falls back to the region nearest
    -- a player, then to any point (no players / no regions). MedEvac and
    -- CASEVAC have no region and are unaffected. See Pool.pickNearPlayers.
    spawnNearPlayers = true,

    sarMountain = {
      maxActive = 2,
      severity  = { min = 1, max = 10 },
      beacon = { enabled = false,   -- needs an .ogg file inside the .miz; homing only on some modules (finicky)
                 file = "l10-beacon.ogg", freqHz = 40500000, modulation = 1, power = 100 },
    },
    sarSea  = { maxActive = 2, severity = { min = 1, max = 10 }, beacon = { enabled = false } },

    -- Sinking ship (mass rescue, RARE): a vessel is going down and a dozen
    -- survivors are in life rafts scattered around the wreck. Same intel
    -- fog as the other sea SAR (approximate circle, a spotter reveals the
    -- exact area), but recovery is per-raft: a helicopter holds a brief
    -- hover over a raft to pull those survivors aboard, one raft at a time.
    -- The deadline is the ship going down for good: rafts not reached by
    -- then are lost. Needs a "CIVIL Raft" template (no template = no
    -- scenario); the "CIVIL Sinking" wreck model is optional visual.
    sinking = {
      maxActive     = 1,
      severity      = { min = 6, max = 10 },  -- it is the grave tier
      raftCount     = { min = 8, max = 12 },  -- survivors in rafts, rolled per event
      spreadRadius  = 400,     -- m, rafts scattered this far around the wreck
      raftHoldSeconds = 15,    -- s of steady hover over a raft to recover it
      rescueRadius  = 40,      -- m, horizontal distance to a raft
      maxAGL        = 25,      -- m, hover height band for the pickup
      maxSpeed      = 3.0,     -- m/s, must be near-stationary
      deadline      = 2400,    -- s baseline before the ship goes down (scaled by severity)
    },

    medevac = {
      maxActive   = 2,
      criticality = 1800,  -- s baseline, scaled by severity (see severityEffects)
      severity    = { min = 1, max = 10 },
    },
    -- Battlefield CASEVAC: same engine and flow as MedEvac (hover pickup ->
    -- hospital delivery), hostile-setting skin, tighter criticality.
    casevac = {
      maxActive   = 2,
      criticality = 1500,
      severity    = { min = 1, max = 10 },
    },

    -- How severity shapes a rescue event (sevLerp between atMin=severity 1
    -- and atMax=severity 10):
    --   windowFactor   scales the hover failure window (worse case = less time)
    --   tFactor        scales the required hover time (stabilizing a bad
    --                  casualty takes longer)
    --   deadlineFactor scales the criticality deadline
    severityEffects = {
      windowFactor   = { atMin = 1.15, atMax = 0.85 },
      tFactor        = { atMin = 0.90, atMax = 1.20 },
      deadlineFactor = { atMin = 1.30, atMax = 0.60 },
    },
    delivery = { radius = 40, maxSpeed = 2.0, maxAGL = 10, holdSeconds = 15 }, -- zone-based hospital delivery
    smokeOffsetM = 20,     -- survivor smoke is offset by this distance

    -- Subject signal on request (all rescue variants share it): orange
    -- smoke by day, a sequence of signal flares by night, because smoke is
    -- invisible in the dark. Night is decided from mission local time.
    signal = {
      flareCount = 3,
      flareIntervalSeconds = 3,
      nightStartHour = 19,
      nightEndHour = 6,
    },

    -- Scene dressing spawned NEXT TO the casualty: each scenario picks one
    -- entry at random from its list, then clones a late-activated template
    -- with that prefix (several templates sharing the prefix = variants,
    -- picked at random like every other template). A scene is one ground
    -- group built in the ME: e.g. an ambulance plus two medics for the
    -- plain rescue, wrecked cars and bystanders for the accident. Missing
    -- templates are skipped silently, so scenes are fully optional.
    scenes = {
      despawnDelay = 300,   -- s the scene stays after the event ends (pickup, fail or cancel)
      offsetM = 15,         -- m from the casualty (keeps the hover center clean)
      byScenario = {
        MEDEVAC      = { "CIVIL Scene Rescue", "CIVIL Scene Accident" },
        CASEVAC      = { "CIVIL Scene Battlefield" },
        SAR_MOUNTAIN = { "CIVIL Scene Camp", "CIVIL Scene Crash" },
        SAR_SEA      = { "CIVIL Scene Sea" },   -- build it as a SHIP group (it spawns on water)
      },
    },

    -- AI SAR vessels: ship groups placed in the ME whose GROUP name starts
    -- with groupPrefix are tasked toward the APPROXIMATE search area when a
    -- sea SAR event starts (consistent with the intel model: they do not
    -- know the exact position), and re-tasked to the exact point once a
    -- spotter identifies the subject.
    --
    -- SEA RESCUE FALLBACK: a vessel holding within rescueRadius of the
    -- subject for rescueHoldSeconds completes the rescue by sea. The score
    -- goes to the identifying SPOTTER (the C-130 made it possible); without
    -- identification vessels only reach the approximate circle center, so a
    -- sea rescue realistically requires the spotter. If the helicopter's
    -- hover window expires while vessels are en route, the subject is NOT
    -- lost yet: the event stays alive for one extra window to let the boats
    -- arrive, then fails for good.
    --
    -- If fewer pre-placed vessels than perEvent are available, stock boats
    -- are SPAWNED from the nearest origin among: mother ships (the
    -- hospitalShips units, e.g. a Perry or a Tarawa) and "CIVIL Vessel
    -- Spawn" harbor zones. Balance rule for harbor placement: travel time
    -- = distance / speed should be slightly LONGER than the helicopter
    -- hover window, so the boat is the second chance, not a competitor.
    vessels = {
      enabled = true,
      groupPrefix = "CIVIL Rescue Vessel",
      speed = 9,               -- m/s route speed (~17.5 kts)
      perEvent = 2,            -- vessels dispatched per event (nearest first)
      rescueRadius = 200,      -- m: vessel within this of the subject...
      rescueHoldSeconds = 60,  -- ...for this long = rescued by sea
      spotterScoreMult = 0.8,  -- sea-rescue score multiplier for the identifying spotter
      spawn = {
        enabled = true,
        offsetFromShip = 150,  -- m, boats spawn this far from the mother ship (clear of the hull)
      },
    },

    -- Mobile landing zone (big-ship mod): ship UNITS whose name starts with
    -- unitPrefix act as moving hospital pads. Delivery detection is
    -- relative to the ship: horizontal distance from the unit, altitude
    -- above the ship reference point within deck bounds, and RELATIVE
    -- speed (the ship may be underway). Physical deck landing depends on
    -- the mod's deck collision: TO TEST in-game.
    hospitalShips = {
      enabled = true,
      unitPrefix = "CIVIL Hospital Ship",
      radius = 80,          -- m horizontal from the ship unit position
      deckAGLMax = 45,      -- m above the ship reference point (covers tall decks)
      maxRelSpeed = 2.0,    -- m/s relative to the ship
    },

    -- Intel model (CSAR-style): exact coordinates are NEVER broadcast on
    -- event start. The initial report is a rough direction plus an
    -- approximate search circle on the F10 map (subject inside but NOT
    -- centered). Exact position is released only when a player airplane
    -- (C-130 spotter) identifies the subject.
    intel = {
      approxRadius = { min = 3000, max = 6000 },   -- approximate search circle radius (m)
      centerOffset = { min = 0.2, max = 0.7 },     -- subject offset from circle center (fraction of radius)
      spotterDetectRadius = 8000,                  -- m; an airborne player airplane within this range
                                                   -- of the subject identifies it (also works with no region)
    },
  },

  ------------------------------------------------------------------
  -- Police
  ------------------------------------------------------------------
  police = {
    maxChases      = 2,
    severity       = { min = 1, max = 10 },   -- fugitive dangerousness, one roll per chase
    carSpeed       = { min = 12, max = 22 },  -- m/s, severity 1 -> min, severity 10 -> max
    pressureRadius = 500,   -- m, helicopter inside -> pressure rises
    pressureUp     = { min = 2.0, max = 4.0 },  -- %/s: severity 10 -> min (harder to build)
    pressureDown   = { min = 1.0, max = 3.0 },  -- %/s: severity 10 -> max (faster to lose)
    convoySeverity = 8,     -- severity >= this spawns a two-vehicle convoy
    routeHops      = 3,     -- waypoints generated ahead (local random walk)
    neighborRadius = 1500,  -- m, "nearby points" for the random walk
    sceneTemplates = { "CIVIL Scene Robbery" },  -- scene at the chase start crossroad (optional)

    -- TRAFFIC WATCH: the fixed-wing job on a chase, mirroring the air
    -- attack role on fires. An airplane orbiting over the fugitive (within
    -- radius, below maxAGL) keeps the pursuit on camera: while it holds
    -- contact the helicopter's pressure builds rateBonus times faster, and
    -- the watcher earns an assist when the arrest lands.
    -- Prisoner convoy escort: a police car, the school bus with the
    -- detainees and a tail car (build the CIVIL Convoy template in that
    -- order) drive "On Road" from a CIVIL Convoy Start zone to a CIVIL
    -- Convoy End zone. The helicopter shadows them. Along the way there is
    -- a chance an AMBUSH (CIVIL Ambush template) appears ahead of the
    -- route: spot it and report it via F10 for bonus points, and the
    -- police clears the site after clearDelay. Miss it and the convoy
    -- drives into it: mission FAILED, both groups despawn and the
    -- escorting pilot takes the malus.
    convoy = {
      enabled      = true,
      maxActive    = 1,
      severity     = { min = 1, max = 10 },
      speed        = 12,     -- m/s on road (~43 km/h: it is a bus)
      escortRadius = 2000,   -- m, helicopter within this counts as escorting
      arriveRadius = 300,    -- m from the destination = delivered
      ambush = {
        chance        = 60,   -- % per run (needs a CIVIL Ambush template)
        delay         = { min = 120, max = 360 },  -- s into the drive before it appears
        aheadM        = 800,  -- m ahead of the convoy when it appears
        lateralM      = 50,   -- m off the road
        hintRadius    = 2500, -- m, aircraft below maxAGL gets the nudge
        maxAGL        = 600,
        reportRadius  = 800,  -- m, F10 report valid within this
        clearDelay    = 60,   -- s after the report before the police clears the site
        triggerRadius = 250,  -- m, unspotted ambush this close to the convoy = sprung
      },
    },

    trafficWatch = {
      enabled   = true,
      radius    = 1800,   -- m from the fleeing vehicle: wide enough for a
                          -- real orbit (a light plane's standard turn is
                          -- already a ~1.1 km circle, the tether must be
                          -- larger than that to hold contact comfortably)
      maxAGL    = 1500,   -- m, must be below this to count as overwatch
      rateBonus = 1.5,    -- pressure build multiplier while the watch holds
    },
  },
  swat = {
    severity      = { min = 1, max = 10 },  -- scenario escalation, one roll per scenario
    squadSize     = { min = 4, max = 8 },   -- required operators: severity 1 -> min, 10 -> max
    boardingTime  = 20,     -- s stationary at the base to board the team
    resolveTime   = 300,    -- s baseline for the squad to "resolve" the scenario (scaled by severity)
    resolveFactor = { atMin = 0.7, atMax = 1.5 },
    sceneTemplates = { "CIVIL Scene Standoff" }, -- scene at the objective (optional)
  },

  ------------------------------------------------------------------
  -- Event director: automatic generation (besides manual Admin starts).
  -- interval = s between attempts; each module value = % chance that an
  -- attempt spawns that event (caps are each module's maxActive).
  ------------------------------------------------------------------
  director = {
    enabled  = true,
    interval = { min = 480, max = 1200 },
    chance   = {   -- module key -> probability % (0 = manual start only)
      sarMountain = 25,
      medevac     = 25,
      casevac     = 20,
      chase       = 25,
      swat        = 15,
      transport   = 40,
      recon       = 20,
      vip         = 20,
      seaEvent    = 30,   -- ONE sea roll, tier picked by weight (see seaTiers)
      convoy      = 15,
      tour        = 15,
      supply      = 20,
      -- fires have their own dedicated scheduler (fire.autoIgnite);
      -- sea/air ambient traffic have their own spawn schedulers too
    },

    -- Sea event RARITY tiers: the "seaEvent" roll weighted-picks WHICH sea
    -- event to start. Ship inspection is the everyday job, a sea rescue is
    -- less common, a sinking with many survivors is rare. If the picked
    -- tier cannot start (e.g. inspection with no merchant at sea) the roll
    -- falls through to the next-most-likely tier so it is not wasted.
    seaTiers = {
      { key = "inspection", weight = 60 },
      { key = "sarSea",     weight = 30 },
      { key = "sarSinking", weight = 10 },
    },

    -- CO-OCCURRENCE BUDGET: keep too many SEVERE events from piling up. The
    -- director sums the severity of the active "serious" events across every
    -- module (CIV.severityLoad) and scales every chance down as the load
    -- approaches severityBudget, reaching zero at the budget. Grave events
    -- weigh more, so they choke the pipeline hardest: a raging wildfire (its
    -- severity counts too) quiets the other callouts on its own. Light tasks
    -- (recon/vip/tour/media/transport) are NOT counted, they never crowd
    -- each other out. Fires keep their own scheduler and are not throttled,
    -- only counted.
    severityBudget = 24,
  },

  ------------------------------------------------------------------
  -- Aviation tasks: infrastructure recon, VIP shuttle, media coverage
  ------------------------------------------------------------------

  -- Infrastructure reconnaissance: an anomaly appears on one of the
  -- corridor waypoints (CIVIL Recon Point zones placed along a power
  -- line, a pipeline, ...). Players fly the corridor low; within
  -- hintRadius they get a nudge, overhead and below maxAGL they report
  -- it via F10. Optional visual from the CIVIL Anomaly template.
  recon = {
    maxActive    = 2,
    severity     = { min = 1, max = 10 },
    maxAGL       = 300,    -- m, you must be at or below this to spot/report
    reportRadius = 600,    -- m, horizontal distance for a valid report
    hintRadius   = 2000,   -- m, "something looks off" nudge
    ttl          = 2700,   -- s before the anomaly expires unreported
    smokeVisual  = true,   -- thin smoke column at the anomaly (a smoking
                           -- transformer / leaking joint), on top of the
                           -- optional CIVIL Anomaly template
  },

  -- VIP shuttle: a passenger waits at one CIVIL VIP Pad for a ride to
  -- another. Boarding and dropoff need boardSeconds landed on the pad.
  -- Ride comfort IS the score quality: acceleration spikes above
  -- accelLimit add penalty. Optional waiting figure from CIVIL VIP.
  vip = {
    maxActive    = 2,
    severity     = { min = 1, max = 10 },
    padRadius    = 60,     -- m from the pad point
    boardSeconds = 20,     -- s landed and still to board / drop off
    pickupTtl    = 2700,   -- s before the passenger gives up waiting
    -- LEG RULE: legs longer than this are FIXED-WING only. A short hop
    -- across the island suits a helicopter; a leg from another landmass
    -- needs an airplane, and boarding refuses helicopters on those jobs.
    fixedWingBeyondKm = 60,
    comfort = {
      accelLimit    = 3.0,   -- m/s^2 spike threshold (gravity excluded)
      penaltyPerHit = 0.05,  -- quality lost per sampled spike
    },
  },

  -- Medical transfer (air ambulance): event CHAIN on the rescue module.
  -- When a helicopter delivers a high-severity patient to a hospital,
  -- sometimes the patient must continue to a regional hospital far away:
  -- a transfer job spawns from the CIVIL VIP Pad nearest the delivery to
  -- a distant pad. Boarding works like the VIP shuttle (pads sit on
  -- aprons, so the light fixed-wing are the natural air ambulance), but
  -- the passenger is a patient: a criticality clock ticks and the comfort
  -- threshold is tighter. Requires 2+ CIVIL VIP Pad zones.
  medTransfer = {
    enabled      = true,
    chance       = 40,      -- % that a qualifying delivery spawns the transfer leg
    minSeverity  = 7,       -- only patients this bad need the regional hospital
    minLeg       = 15000,   -- m, destination pad at least this far from pickup
    fixedWingBeyondKm = 60, -- legs longer than this are FIXED-WING only (see vip)
    boardSeconds = 20,
    pickupTtl    = 1800,    -- s before the transfer is reassigned (task expires)
    deadline     = { atMin = 2400, atMax = 1200 },  -- s criticality clock, severity-scaled
    comfort = {
      accelLimit    = 2.5,  -- the patient tolerates less than a VIP
      penaltyPerHit = 0.05,
    },
  },

  -- Sightseeing tour: tourists board at a VIP pad and want to SEE the
  -- island. Fly them over 2-3 CIVIL Tourist Site zones (hold inside each
  -- zone, in the altitude band, for orbit.seconds) and bring them BACK to
  -- the same pad. Comfort is the score quality, tourists included. Legs
  -- beyond fixedWingBeyondKm make the tour fixed-wing only.
  tour = {
    maxActive    = 2,
    severity     = { min = 1, max = 10 },
    sites        = { min = 2, max = 3 },   -- tourist sites per tour
    boardSeconds = 20,
    pickupTtl    = 2700,    -- s before the group gives up waiting
    duration     = 3600,    -- s to fly the whole tour once boarded
    orbit = {
      seconds = 75,         -- s inside each site zone to call it "seen"
      minAGL  = 100,        -- m, lower is unsafe
      maxAGL  = 1500,       -- m, higher and the tourists see nothing
    },
    fixedWingBeyondKm = 60, -- farthest site beyond this = fixed-wing only
    comfort = {
      accelLimit    = 3.0,
      penaltyPerHit = 0.05,
    },
  },

  -- Emergency supply drop: an emergency opens on one CIVIL Drop Zone (a
  -- village cut off, a field team out of everything) and supplies must
  -- come from the air. Release via F10 overhead: the crates drift with
  -- the wind (no steering: cargo chutes do not fly back) and the closer
  -- to the zone center they land, the more the drop pays.
  --
  -- WHO FLIES IT: the C-130 is the only airplane rigged for a proper
  -- airdrop, and one full load from it resolves the emergency ALONE
  -- (scored with c130LoadMult). Helicopters kick single crates out low:
  -- dropsNeeded of them close it. Light planes are refused, they are not
  -- equipped for this.
  supplyDrop = {
    enabled        = true,
    maxActive      = 1,
    severity       = { min = 1, max = 10 },
    ttl            = 1500,   -- s the emergency stays open
    dropsNeeded    = 3,      -- helicopter drops that resolve the emergency
    onePerAircraft = true,   -- each aircraft scores once per emergency
    crates         = 3,      -- cargo statics spawned at the landing point
    crateType      = "uh1h_cargo",
    c130Types      = { "Hercules", "C-130", "C130" },  -- substring match, TO VALIDATE
    c130ResolvesAlone = true,
    c130LoadMult   = 2.0,    -- score multiplier for the full C-130 load
    c130MinAGL     = 500,    -- m, minimum release height for the C-130
    heloMinAGL     = 100,    -- m, helicopters kick crates out low
    freefallSpeed  = 60,     -- m/s before the cargo chutes open
    openAGL        = 400,    -- m, chute opening height
    canopySink     = 6,      -- m/s under canopy
    freefallDrift  = 0.3,    -- fraction of the wind acting before opening
    cooldown       = 120,    -- s per aircraft between releases
    despawnDelay   = 600,    -- s the landed crates stay on the ground
  },

  -- Task board: aviation tasks (recon, VIP, medical transfer) are not
  -- pushed on the pilots. The director POSTS OFFERS and whoever is ready
  -- accepts one via F10 (maybe you are refueling, or mid-task: nothing is
  -- assigned to you). Offers pre-roll their severity so the board shows
  -- the expected points; PRIORITY offers pay a bonus. GM marker commands
  -- bypass the board on purpose: the commander wants the event NOW.
  taskBoard = {
    enabled        = true,
    maxOffers      = 4,     -- offers on the board at once (also F10 accept slots)
    offerTtl       = 1500,  -- s an unclaimed offer stays posted
    priorityChance = 30,    -- % an offer is flagged PRIORITY
    priorityBonus  = 1.3,   -- score multiplier carried by priority offers
  },

  ------------------------------------------------------------------
  -- Sea operations (47_CivilSeaOps.lua): merchant traffic on lanes plus
  -- the coast guard inspection task.
  ------------------------------------------------------------------
  seaOps = {
    -- Merchant traffic: ships spawn at a random point inside a CIVIL Sea
    -- Spawn zone (staggered: two ships on the same spot explode), sail a
    -- local random walk over the CIVIL Sea Lane waypoint pool (same walk
    -- as the police chase) and end in a CIVIL Sea Despawn zone, where
    -- they are cleared. Scenic on its own, target pool for the coast
    -- guard.
    traffic = {
      enabled        = true,
      maxActive      = 3,
      spawnEvery     = { min = 600, max = 1500 },  -- s between spawn attempts
      speed          = 7,       -- m/s (~14 kts)
      laneHops       = 3,       -- lane waypoints per route
      neighborRadius = 60000,   -- m, "nearby lanes" for the random walk
      arriveRadius   = 800,     -- m from the route end = arrived, cleared
      minSpawnGap    = 400,     -- m between ships inside the spawn zone
      maxLifetime    = 10800,   -- s hard cleanup for stuck ships
    },
    -- Coast guard: helicopter inspection. Fly alongside the merchant (low,
    -- slow, close) to check the manifest. Clean pays a partial score; a
    -- SUSPICIOUS cargo escalates: the ship runs, the helicopter keeps
    -- track of it until the patrol boat arrives and boards (full score to
    -- the inspecting pilot).
    coastGuard = {
      enabled       = true,
      severity      = { min = 1, max = 10 },
      suspectChance = 35,      -- % the inspected ship carries suspicious cargo
      inspect = { radius = 200, maxRelAlt = 80, maxRelSpeed = 8, seconds = 45 },
      track   = { radius = 3000, graceSeconds = 180 },  -- lose contact this long = ship slips away
      boatHold = { radius = 300, seconds = 60 },        -- patrol boat alongside = boarding
      fleeSpeed = 10,          -- m/s a suspect runs at
      -- TARGET SELECTION (hybrid): prefer a merchant already sailing the
      -- lanes (realistic, reuses the ambient traffic); if none is free and
      -- dedicatedFallback is on, SPAWN one that sails a route so the task
      -- always works even without ambient traffic. A dedicated ship sails
      -- off and despawns once the inspection ends. dedicatedOnly always
      -- spawns a fresh merchant and ignores the ambient traffic.
      dedicatedFallback = true,
      dedicatedOnly     = false,
    },
  },

  ------------------------------------------------------------------
  -- Ambient air traffic (46_CivilAirTraffic.lua): AI civil flights
  -- between the map airports, purely scenic, plus the restricted-area
  -- violation task for the military flights.
  ------------------------------------------------------------------
  airTraffic = {
    enabled    = true,
    maxActive  = 6,        -- simultaneous AI flights (keep it in the 5-10 range)
    spawnEvery = { min = 240, max = 720 },
    altitude   = { min = 2500, max = 5500 },   -- m cruise band
    speed      = { min = 120, max = 170 },     -- m/s cruise
    minLegKm   = 30,       -- minimum airport-to-airport leg
    airports   = {},       -- explicit airdrome names; empty = every airdrome on the map
    excludeAirports = {},  -- airdromes never used (e.g. the player bases)
    maxLifetime = 3600,    -- s hard cleanup per flight
    -- Restricted areas: sometimes a flight strays into a CIVIL Restricted
    -- zone and loiters there. The violation is armed only when a player
    -- airplane is airborne to answer it (requirePlayers); intercept =
    -- fly within radius of the violator for the required seconds. If
    -- nobody intercepts in time, ATC diverts the flight out by itself.
    restricted = {
      enabled         = true,
      violationChance = 20,     -- % per spawned flight
      requirePlayers  = true,   -- no airborne player airplane = no violation
      intercept       = { radius = 500, seconds = 30 },
      divertAfter     = 600,    -- s before the self-divert
    },
  },

  -- Media coverage: any player helicopter holding in the filming ring
  -- around an active event (fire, rescue, SWAT, chase) accumulates
  -- footage; at filmSeconds the story airs. One award per event.
  media = {
    enabled     = true,
    minDist     = 1000,   -- m, closer than this is unsafe, no footage
    maxDist     = 3000,   -- m, farther than this the shot is useless
    minAGL      = 100,    -- m
    filmSeconds = 300,
    -- ACTION FOOTAGE: while you film, responders actually working the
    -- event (any OTHER player aircraft within actionRadius of it) make
    -- the story worth more, up to +actionBonus on the score. Filming an
    -- empty fire pays less than filming the helicopters fighting it.
    actionRadius = 2000,  -- m from the event
    actionBonus  = 0.5,   -- max score bonus (+50% with responders in frame the whole time)
    -- MEDIA VAN: the TV helicopter can dispatch a ground crew (the CIVIL
    -- Media Van template) from the nearest CIVIL Media Base zone to an
    -- active event. Once the van is ON SCENE, stories aired from that
    -- event pay an extra bonus. Needs the template and at least one base
    -- zone; without them the command reports what is missing.
    van = {
      enabled       = true,
      bonus         = 0.3,   -- extra score multiplier with the crew on scene
      speed         = 18,    -- m/s route speed (~65 km/h)
      onSceneRadius = 300,   -- m from the event = on scene
      cooldown      = 300,   -- s per player between dispatches
      despawnDelay  = 300,   -- s the van lingers after the event ends
    },
  },

  -- Airshow / aerobatic display (freestyle). Fly a timed routine inside a
  -- CIVIL Airshow box (F10 to start): a 5 Hz sampler reads the aircraft
  -- ATTITUDE (from Unit:getPosition orientation vectors) and recognizes a
  -- set of figures, with live feedback and a variety bonus. The scripting
  -- API exposes no throttle / AoA / real G, so figures are recognized
  -- HEURISTICALLY from attitude + velocity: thresholds below are TO TUNE
  -- in-game. Any airplane may fly it.
  airshow = {
    enabled       = true,
    duration      = 480,     -- s per routine (auto-ends; F10 again ends early)
    sampleSeconds = 0.2,     -- 5 Hz sampler while a routine is active
    -- recognition thresholds
    rollDeg       = 340,     -- accumulated bank sweep that counts as a roll
    headingTol    = 30,      -- deg, "heading held" tolerance (roll)
    loopHeadingTol= 45,      -- deg, heading returns to start = loop
    reversalMin   = 135,     -- deg heading change for Immelmann / Split-S
    reversalMax   = 225,
    altChangeMin  = 150,     -- m, altitude delta that makes a climb/descent figure
    invertedSeconds = 3,     -- s of sustained inverted flight = inverted pass
    knifeSeconds  = 3,       -- s of sustained knife-edge
    knifeBank     = { min = 75, max = 105 },   -- deg |bank| band for a knife-edge
    lowPassAGL    = 60,      -- m, below this + fast + upright = low pass
    lowPassSpeed  = 80,      -- m/s
    lowPassRearmAGL = 150,   -- m, must climb above this to re-arm a low pass
    cooldown      = 3,       -- s between scored figures (anti double-count)
    varietyBonus  = 0.5,     -- up to +50% of the total for many DISTINCT figures
    -- points per figure type (summed into the final routine score)
    figures = {
      loop = 10, roll = 8, immelmann = 14, splitS = 14,
      inverted = 8, knife = 12, lowpass = 6,
    },

    -- SMOKE BONUS: figures flown with the display smoke ON pay more. The
    -- scripting API has no universal "smoke on" flag, so detection is
    -- HYBRID: an F10 "Smoke ON/OFF" toggle works on every aircraft (honor
    -- system), and where you map an aircraft type to its smoke DRAW
    -- ARGUMENT the state is read automatically and overrides the toggle.
    -- The draw-argument index differs per model and is undocumented: turn
    -- finder on, use the F10 "find smoke draw arg" command with smoke off
    -- then on, and the changed index is logged for you to put in drawArgs.
    smoke = {
      enabled     = true,
      bonus       = 0.25,    -- per-figure score multiplier while smoke is on
      drawArgs    = {},      -- typeName -> draw-argument index (auto-detect); empty = F10 only
      onThreshold = 0.5,     -- draw-arg value at or above this = smoke on
      finder      = false,   -- debug: add the "find smoke draw arg" F10 command
      finderMaxArg= 400,     -- draw-arg indices the finder scans (0..this)
    },
  },

  ------------------------------------------------------------------
  -- Session recap: periodic situation summary plus final standings at
  -- mission end (also logged as FINAL| lines for the external parser)
  ------------------------------------------------------------------
  recap = {
    enabled = true,
    intervalSeconds = 1800,
  },

  ------------------------------------------------------------------
  -- Night assist: player F10 command that pops an illumination flare
  -- over the nearest active objective (fire, SWAT objective, cargo
  -- point, chase vehicle; rescue subjects get it on the APPROXIMATE
  -- search area until a spotter identifies them, so the intel model
  -- stays intact). Night only, with a per-player cooldown.
  ------------------------------------------------------------------
  nightAssist = {
    enabled = true,
    cooldownSeconds = 600,  -- 10 minutes between requests per player
    searchRadius = 30000,   -- m, nearest objective within this range
    heightAGL = 300,        -- m, illumination flare ignition height
    power = 1000000,        -- illumination power (older builds ignore it)
  },

  ------------------------------------------------------------------
  -- Command center: game-master driven mission control via F10 map
  -- markers. Intended for a player in a Game Master / Tactical Commander
  -- slot (full map view, SRS, native asset control with Combined Arms),
  -- but commands work from ANY slot. Place a marker whose text starts
  -- with markerPrefix, e.g.:
  --   civil fire 7        civil medevac 9      civil casevac
  --   civil sarm 5        civil sars           civil swat 8
  --   civil chase 6       civil cargo heavy 9
  --   civil spawn <template fragment> [count]
  --   civil move <group fragment> [speed] [road]
  --   civil cancel        civil director on|off      civil help
  ------------------------------------------------------------------
  command = {
    enabled = true,
    markerPrefix = "civil",   -- marker text prefix (case-insensitive)
    removeMarks = true,       -- delete the command marker once executed
    cancelRadius = 15000,     -- m, "civil cancel" hits the nearest event within this
    moveSpeed = 10,           -- m/s default for "civil move"
    -- GM slots spawn no unit, so commander presence cannot be read from the
    -- mission API: if the director was paused by the commander and no marker
    -- command arrives for idleSeconds, the mission RESUMES automatic mode.
    autoResume = { enabled = true, idleSeconds = 1800 },
    restrict = {
      enabled = false,        -- true = only playerNames below may issue commands
      playerNames = {},
      allowUnidentified = true, -- GM/CA slots can produce marks with no readable initiator
    },
  },

  ------------------------------------------------------------------
  -- F10 map drawing. Colors are { r, g, b, alpha } with 0..1 values.
  -- Circular zones are drawn with circleToAll; polygon zones with
  -- markupToAll (freeform shape), so the real perimeter is shown.
  ------------------------------------------------------------------
  marks = {
    drawCircles = true,
    circleRadiusM = 1852,                      -- 1 NM (rescue approximate circle default)
    borderColor = { 0, 0, 1, 0.5 },            -- rescue approximate search circle
    fillColor   = { 0, 0, 1, 0.15 },
    lineType    = 2,                           -- dashed

    -- Theme-area overlays drawn once at mission start, so players can see
    -- roughly where each mission type lives. zoneKey references
    -- CIV.Config.zones; missing zones are skipped silently.
    regions = {
      enabled = true,
      list = {
        { zoneKey = "fireRegion",        label = "Firefighting area", border = { 1, 0.4, 0, 0.5 },   fill = { 1, 0.4, 0, 0.05 } },
        { zoneKey = "sarMountainRegion", label = "SAR mountain area", border = { 0, 0.5, 1, 0.5 },   fill = { 0, 0.5, 1, 0.05 } },
        { zoneKey = "sarSeaRegion",      label = "SAR sea area",      border = { 0, 0.8, 0.8, 0.5 }, fill = { 0, 0.8, 0.8, 0.05 } },
        { zoneKey = "c130Reload",        label = "C-130 reload",      border = { 1, 1, 0, 0.6 },     fill = { 1, 1, 0, 0.08 } },
        { zoneKey = "cargoDestination",  label = "Cargo destination", border = { 0, 0.8, 0, 0.6 },   fill = { 0, 0.8, 0, 0.08 } },
        { zoneKey = "swatBase",          label = "SWAT base",         border = { 0.6, 0, 0.8, 0.6 }, fill = { 0.6, 0, 0.8, 0.08 } },
      },
    },

    -- Active-event zone highlighting: the event's own zone perimeter is
    -- drawn while the event is running and removed when it ends. Rescue
    -- events deliberately keep the approximate off-center circle instead
    -- (intel model: exact position needs a spotter).
    events = {
      enabled   = true,
      fire      = { border = { 1, 0, 0, 0.8 },     fill = { 1, 0, 0, 0.12 } },
      transport = { border = { 0, 0.8, 0, 0.8 },   fill = { 0, 0.8, 0, 0.10 } },
      swat      = { border = { 0.6, 0, 0.8, 0.8 }, fill = { 0.6, 0, 0.8, 0.10 } },
      chase     = { border = { 0, 0.4, 1, 0.8 },   fill = { 0, 0.4, 1, 0.10 } },
      restricted= { border = { 1, 0.2, 0, 0.8 },   fill = { 1, 0.2, 0, 0.10 } },
    },
  },
}

----------------------------------------------------------------------
-- LOGGING & SAFETY
----------------------------------------------------------------------

function CIV.log(msg) env.info("[CIVIL] " .. tostring(msg)) end
function CIV.dbg(msg) if CIV.Config.debug then env.info("[CIVIL:DBG] " .. tostring(msg)) end end

-- pcall wrapper for scheduled functions: an error inside one module must
-- not kill the other modules' schedulers (parallel events principle).
function CIV.protect(fn)
  return function(arg, t)
    local ok, res = pcall(fn, arg, t)
    if not ok then
      CIV.log("SCHEDULED ERROR: " .. tostring(res))
      return t and (t + 10) or nil
    end
    return res
  end
end

function CIV.schedule(fn, arg, delay)
  return timer.scheduleFunction(CIV.protect(fn), arg, timer.getTime() + (delay or 1))
end

----------------------------------------------------------------------
-- MATH / GEO
----------------------------------------------------------------------

function CIV.dist2D(a, b)
  local dx = (a.x or 0) - (b.x or 0)
  local dz = (a.z or a.y or 0) - (b.z or b.y or 0)
  return math.sqrt(dx * dx + dz * dz)
end

function CIV.speed(vel)
  return math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z)
end

function CIV.groundY(p) return land.getHeight({ x = p.x, y = p.z }) end
function CIV.agl(p) return p.y - CIV.groundY(p) end

function CIV.isWater(p)
  local st = land.getSurfaceType({ x = p.x, y = p.z })
  return st == land.SurfaceType.WATER or st == land.SurfaceType.SHALLOW_WATER
end

-- One-shot randomization: value fixed at event start (design rule: no
-- continuous per-tick jitter).
function CIV.randBetween(range)
  return range.min + math.random() * (range.max - range.min)
end

----------------------------------------------------------------------
-- SEVERITY SCALE (1..10), shared by every event type.
-- One roll at event start from which all the event's parameters derive
-- (the "randomize once" rule, made readable: "MedEvac severity 8").
-- For fires severity is a LIVE variable (grows, gets suppressed); for
-- every other event it is a static descriptor rolled at spawn.
----------------------------------------------------------------------

function CIV.rollSeverity(range)
  range = range or { min = 1, max = 10 }
  -- defensive: a misconfigured range (max < min) must not crash the roll
  if range.max < range.min then return range.min end
  return math.random(range.min, range.max)
end

-- linear interpolation over the severity scale: sev 1 -> atMin, sev 10 -> atMax
function CIV.sevLerp(sev, atMin, atMax)
  return atMin + (sev - 1) / 9 * (atMax - atMin)
end

-- score multiplier for a given severity (anchored: severity 5 = x1.0)
function CIV.severityMult(sev)
  local s = CIV.Config.score.severity
  return s.base + s.perPoint * math.max(1, math.min(10, sev))
end

-- Total severity currently in play across the SERIOUS event types, summed
-- read-only from each module's active collection (all guarded, so unloaded
-- modules contribute nothing). Drives the director co-occurrence budget:
-- the busier and graver the map, the fewer new callouts. Light tasks
-- (recon/vip/tour/media/transport) are deliberately excluded.
function CIV.severityLoad()
  local load = 0
  if CIV.Fire then
    for _, fire in pairs(CIV.Fire.actives()) do load = load + (fire.severity or 0) end
  end
  if CIV.Rescue then
    for _, sc in pairs(CIV.Rescue._scenarios) do
      for _, evt in pairs(sc.events) do load = load + (evt.severity or 0) end
    end
  end
  if CIV.Police then
    for _, chase in pairs(CIV.Police._chases) do load = load + (chase.severity or 0) end
  end
  if CIV.SWAT then
    for _, scen in pairs(CIV.SWAT._scenarios) do load = load + (scen.severity or 0) end
  end
  if CIV.Convoy then
    for _, run in pairs(CIV.Convoy._runs) do load = load + (run.severity or 0) end
  end
  if CIV.CoastGuard then
    for _, task in pairs(CIV.CoastGuard._tasks) do load = load + (task.severity or 0) end
  end
  if CIV.SupplyDrop then
    for _, evt in pairs(CIV.SupplyDrop._events) do load = load + (evt.severity or 0) end
  end
  return load
end

-- weighted random pick from a list of { weight = n, ... } entries
function CIV.weightedPick(list)
  local total = 0
  for _, entry in ipairs(list) do total = total + entry.weight end
  -- defensive: all-zero weights must not crash math.random(0)
  if total <= 0 then return list[1] end
  local r, acc = math.random(total), 0
  for _, entry in ipairs(list) do
    acc = acc + entry.weight
    if r <= acc then return entry end
  end
  return list[1]
end

-- night check from mission local time (hours configured in rescue.signal)
function CIV.isNight()
  local s = CIV.Config.rescue.signal
  local h = (timer.getAbsTime() % 86400) / 3600
  return h >= s.nightStartHour or h < s.nightEndHour
end

-- Self-contained atan2 (avoids DCS Lua build differences), from the 527th CSAR
local function atan2(y, x)
  y = y or 0; x = x or 0
  if x > 0 then return math.atan(y / x)
  elseif x < 0 and y >= 0 then return math.atan(y / x) + math.pi
  elseif x < 0 and y < 0 then return math.atan(y / x) - math.pi
  elseif x == 0 and y > 0 then return math.pi / 2
  elseif x == 0 and y < 0 then return -math.pi / 2 end
  return 0
end

-- DCS runtime axes: x = North, z = East. Compass bearing clockwise from N.
function CIV.bearingDeg(from, to)
  local brg = math.deg(atan2((to.z or to.y) - (from.z or from.y), to.x - from.x))
  if brg < 0 then brg = brg + 360 end
  return brg
end

-- Aircraft attitude from the orientation vectors of Unit:getPosition()
-- (pos.x = nose, pos.y = up, pos.z = right; world y is up). Returns pitch
-- and roll/bank in degrees, heading 0..360, and upY (the up vector's world
-- vertical component: < 0 = inverted). bank is a full -180..180 angle so a
-- roll sweeps continuously through knife-edge (+-90) and inverted (+-180).
function CIV.attitude(unit)
  local ok, pos = pcall(unit.getPosition, unit)
  if not ok or not pos then return nil end
  local nose, up, right = pos.x, pos.y, pos.z
  local pitch = math.deg(math.asin(math.max(-1, math.min(1, nose.y))))
  local bank = math.deg(atan2(right.y, up.y))
  local heading = math.deg(atan2(nose.z, nose.x))
  if heading < 0 then heading = heading + 360 end
  return { pitch = pitch, bank = bank, heading = heading, upY = up.y }
end

-- shortest signed angular difference a->b in -180..180 (degrees)
function CIV.angDelta(a, b)
  local d = (b - a) % 360
  if d > 180 then d = d - 360 end
  return d
end

function CIV.offsetPoint(p, bearingDeg, distM)
  local rad = math.rad(bearingDeg)
  local x = p.x + math.cos(rad) * distM
  local z = (p.z or p.y) + math.sin(rad) * distM
  return { x = x, y = land.getHeight({ x = x, y = z }), z = z }
end

-- 8-wind cardinal name for a bearing ("N", "NE", ...)
function CIV.cardinal(bearingDeg)
  local names = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
  return names[math.floor(((bearingDeg % 360) + 22.5) / 45) % 8 + 1]
end

-- Low-precision position report: rough distance (rounded to 5 km) and
-- cardinal direction from a reference point. Used for unidentified targets.
function CIV.vagueDirection(fromPoint, fromName, toPoint)
  local dist = CIV.dist2D(fromPoint, toPoint)
  local roundedKm = math.max(5, math.floor(dist / 5000 + 0.5) * 5)
  return string.format("roughly %d km %s of %s", roundedKm,
    CIV.cardinal(CIV.bearingDeg(fromPoint, toPoint)), fromName)
end

----------------------------------------------------------------------
-- COORDINATE FORMATTING (LL DDM + MGRS, from 527th CSAR)
----------------------------------------------------------------------

function CIV.llString(p)
  local lat, lon = coord.LOtoLL(p)
  local function fmt(v, pos, neg)
    local h = v >= 0 and pos or neg
    v = math.abs(v)
    local d = math.floor(v)
    return string.format("%s %d° %06.3f'", h, d, (v - d) * 60)
  end
  return fmt(lat, "N", "S") .. "  " .. fmt(lon, "E", "W")
end

function CIV.mgrsString(p)
  if not coord.LLtoMGRS then return "MGRS unavailable" end
  local lat, lon = coord.LOtoLL(p)
  local m = coord.LLtoMGRS(lat, lon)
  if not m then return "MGRS unavailable" end
  return string.format("%s %s %05d %05d", tostring(m.UTMZone), tostring(m.MGRSDigraph),
    tonumber(m.Easting) or 0, tonumber(m.Northing) or 0)
end

function CIV.coordText(p)
  return CIV.llString(p) .. "\nMGRS: " .. CIV.mgrsString(p)
end

----------------------------------------------------------------------
-- MISSION SCANNER (adapted from 527th CSAR)
-- Reads trigger zones (circle + polygon, with properties) and
-- late-activated spawn templates directly from env.mission.
----------------------------------------------------------------------

CIV.Zones = { _areas = {} }        -- list of { name, kind, center={x,z}, radius, vertices?, properties }
CIV.Templates = { _groups = {} }   -- list of { name, countryId, category, categoryEnum, data }
CIV.Ships = {}                     -- every ship unit in the mission: { unitName, groupName }
                                   -- (rescue vessels and mobile hospital ships are found here by prefix)
CIV.MissionGroups = {}             -- every ME group: { name, category } ("civil move" fragment search)
CIV._ids = { group = 900000, unit = 900000, mark = 950000 }

function CIV.startsWith(s, prefix)
  return type(s) == "string" and string.sub(s, 1, string.len(prefix)) == prefix
end
local startsWith = CIV.startsWith

local function pointInPolygon(point, vertices)
  if not vertices or #vertices < 3 then return false end
  local inside, j = false, #vertices
  local px, pz = point.x, point.z or point.y
  for i = 1, #vertices do
    local xi, zi = vertices[i].x, vertices[i].z
    local xj, zj = vertices[j].x, vertices[j].z
    if ((zi > pz) ~= (zj > pz))
       and (px < (xj - xi) * (pz - zi) / ((zj - zi) + 1e-7) + xi) then
      inside = not inside
    end
    j = i
  end
  return inside
end

local function loadTriggerZones()
  local zones = env.mission and env.mission.triggers and env.mission.triggers.zones
  if type(zones) ~= "table" then
    CIV.log("WARNING: env.mission trigger zones unavailable")
    return
  end
  for _, z in pairs(zones) do
    if type(z) == "table" and z.name then
      local raw = z.verticies or z.vertices
      if type(raw) == "table" and #raw >= 3 then
        local verts, cx, cz = {}, 0, 0
        for _, v in ipairs(raw) do
          local x, zz = v.x, v.z or v.y
          if x and zz then
            verts[#verts + 1] = { x = x, z = zz }
            cx, cz = cx + x, cz + zz
          end
        end
        if #verts >= 3 then
          cx, cz = cx / #verts, cz / #verts
          local rMax = 0
          for _, v in ipairs(verts) do
            rMax = math.max(rMax, CIV.dist2D({ x = cx, z = cz }, v))
          end
          CIV.Zones._areas[#CIV.Zones._areas + 1] = {
            name = z.name, kind = "polygon", vertices = verts,
            center = { x = cx, z = cz }, radius = rMax,
            properties = z.properties or {},
          }
        end
      elseif z.x and z.y and z.radius then
        CIV.Zones._areas[#CIV.Zones._areas + 1] = {
          name = z.name, kind = "circle",
          center = { x = z.x, z = z.y }, radius = z.radius,
          properties = z.properties or {},
        }
      end
    end
  end
  CIV.log("Mission scanner: " .. #CIV.Zones._areas .. " trigger zones loaded")
end

local function deepCopy(obj)
  if type(obj) ~= "table" then return obj end
  local res = {}
  for k, v in pairs(obj) do res[deepCopy(k)] = deepCopy(v) end
  return res
end

local categoryEnum = {
  vehicle = Group.Category.GROUND, helicopter = Group.Category.HELICOPTER,
  plane = Group.Category.AIRPLANE, ship = Group.Category.SHIP,
}

local function loadTemplates()
  local coalitions = env.mission and env.mission.coalition
  if type(coalitions) ~= "table" then return end
  for _, coaData in pairs(coalitions) do
    if type(coaData) == "table" and type(coaData.country) == "table" then
      for _, countryData in pairs(coaData.country) do
        if type(countryData) == "table" then
          for _, cat in ipairs({ "plane", "helicopter", "vehicle", "ship" }) do
            local catData = countryData[cat]
            if type(catData) == "table" and type(catData.group) == "table" then
              for _, g in pairs(catData.group) do
                if type(g) == "table" and g.name then
                  -- track max ids so scripted spawns never collide
                  if g.groupId and g.groupId > CIV._ids.group then CIV._ids.group = g.groupId + 1000 end
                  if type(g.units) == "table" then
                    for _, u in pairs(g.units) do
                      if u.unitId and u.unitId > CIV._ids.unit then CIV._ids.unit = u.unitId + 1000 end
                    end
                  end
                  if g.lateActivation then
                    CIV.Templates._groups[#CIV.Templates._groups + 1] = {
                      name = g.name, countryId = countryData.id,
                      category = cat, categoryEnum = categoryEnum[cat],
                      data = deepCopy(g),
                    }
                  end
                  CIV.MissionGroups[#CIV.MissionGroups + 1] = { name = g.name, category = cat }
                  if cat == "ship" and not g.lateActivation and type(g.units) == "table" then
                    for _, u in pairs(g.units) do
                      if u.name then
                        CIV.Ships[#CIV.Ships + 1] = { unitName = u.name, groupName = g.name }
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  CIV.log("Mission scanner: " .. #CIV.Templates._groups .. " late-activated templates loaded")
  for _, tpl in ipairs(CIV.Templates._groups) do
    CIV.log("  template: '" .. tpl.name .. "' (" .. tpl.category .. ")")
  end
end

loadTriggerZones()
loadTemplates()

function CIV.Zones.byName(name)
  for _, a in ipairs(CIV.Zones._areas) do
    if a.name == name then return a end
  end
  return nil
end

function CIV.Zones.byPrefix(prefix)
  local res = {}
  for _, a in ipairs(CIV.Zones._areas) do
    if startsWith(a.name, prefix) then res[#res + 1] = a end
  end
  return res
end

function CIV.Zones.contains(area, p)
  if not area then return false end
  if area.kind == "polygon" then return pointInPolygon(p, area.vertices) end
  return CIV.dist2D(p, area.center) <= area.radius
end

-- Every configured zone name is a PREFIX: one zone or many (e.g.
-- "CIVIL Fire Region North" and "CIVIL Fire Region South" both belong to
-- the "CIVIL Fire Region" macro-area). These helpers work on the whole set.

-- the area matching the prefix that contains p, or nil
function CIV.Zones.containing(prefix, p)
  for _, area in ipairs(CIV.Zones.byPrefix(prefix)) do
    if CIV.Zones.contains(area, p) then return area end
  end
  return nil
end

-- the area matching the prefix whose center is closest to p, or nil
function CIV.Zones.nearest(prefix, p)
  local best, bestDist = nil, 1e12
  for _, area in ipairs(CIV.Zones.byPrefix(prefix)) do
    local d = CIV.dist2D({ x = area.center.x, z = area.center.z }, p)
    if d < bestDist then best, bestDist = area, d end
  end
  return best
end

function CIV.Templates.byPrefix(prefix)
  local res = {}
  for _, t in ipairs(CIV.Templates._groups) do
    if startsWith(t.name, prefix) then res[#res + 1] = t end
  end
  return res
end

----------------------------------------------------------------------
-- POINT POOLS
-- A pool is the set of zones whose name starts with a prefix. Selection
-- is random with a min-distance check against ACTIVE events (parallel
-- events principle: no overlapping missions).
----------------------------------------------------------------------

CIV.Pool = { _pools = {}, _active = {} }

function CIV.Pool.load(prefix)
  if CIV.Pool._pools[prefix] then return CIV.Pool._pools[prefix] end
  local points = {}
  for _, area in ipairs(CIV.Zones.byPrefix(prefix)) do
    points[#points + 1] = {
      name = area.name, area = area, radius = area.radius,
      point = { x = area.center.x,
                y = land.getHeight({ x = area.center.x, y = area.center.z }),
                z = area.center.z },
    }
  end
  CIV.Pool._pools[prefix] = points
  CIV.log("Pool '" .. prefix .. "': " .. #points .. " points")
  return points
end

function CIV.Pool.occupy(pt)  CIV.Pool._active[pt.name] = pt end
function CIV.Pool.release(pt) CIV.Pool._active[pt.name] = nil end

local function tooClose(pt, minDist)
  for _, act in pairs(CIV.Pool._active) do
    if act.name == pt.name or CIV.dist2D(pt.point, act.point) < minDist then
      return true
    end
  end
  return false
end

function CIV.Pool.pick(prefix, minDist, filter)
  local candidates = {}
  for _, pt in ipairs(CIV.Pool.load(prefix)) do
    if not tooClose(pt, minDist or 500) and (not filter or filter(pt)) then
      candidates[#candidates + 1] = pt
    end
  end
  if #candidates == 0 then return nil end
  return candidates[math.random(#candidates)]
end

function CIV.Pool.near(prefix, point, radius, excludeName)
  local res = {}
  for _, pt in ipairs(CIV.Pool.load(prefix)) do
    if pt.name ~= excludeName and CIV.dist2D(pt.point, point) <= radius then
      res[#res + 1] = pt
    end
  end
  return res
end

-- Pick a free pool point BIASED to where the players actually are, so an
-- event does not spawn across the map from everyone. With a regionPrefix
-- (large macro-areas, each holding a cluster of points): prefer a point
-- inside a region that currently CONTAINS a player; if nobody is inside a
-- region, fall back to the region NEAREST to a player; with no players at
-- all, or no region defined, behave like Pool.pick. A GM-commanded point
-- bypasses this (the caller handles opts.point).
function CIV.Pool.pickNearPlayers(poolPrefix, regionPrefix, minDist)
  minDist = minDist or 1000
  local regions = regionPrefix and CIV.Zones.byPrefix(regionPrefix) or {}
  if #regions == 0 then return CIV.Pool.pick(poolPrefix, minDist) end

  local pps = {}
  CIV.forEachPlayer(function(u) pps[#pps + 1] = u:getPoint() end)
  if #pps == 0 then return CIV.Pool.pick(poolPrefix, minDist) end

  local function regionHasPlayer(region)
    for _, p in ipairs(pps) do
      if CIV.Zones.contains(region, p) then return true end
    end
    return false
  end

  local target = {}
  for _, region in ipairs(regions) do
    if regionHasPlayer(region) then target[#target + 1] = region end
  end
  if #target == 0 then
    -- nobody is inside a region: use the one nearest to any player
    local best, bestD = nil, 1e12
    for _, region in ipairs(regions) do
      local c = { x = region.center.x, z = region.center.z }
      for _, p in ipairs(pps) do
        local d = CIV.dist2D(c, p)
        if d < bestD then best, bestD = region, d end
      end
    end
    if best then target = { best } end
  end

  local function insideTarget(pt)
    for _, region in ipairs(target) do
      if CIV.Zones.contains(region, pt.point) then return true end
    end
    return false
  end
  -- last resort keeps events flowing if the chosen region has no free point
  return CIV.Pool.pick(poolPrefix, minDist, insideTarget)
    or CIV.Pool.pick(poolPrefix, minDist)
end

----------------------------------------------------------------------
-- PLAYER REGISTRY (S_EVENT_BIRTH)
----------------------------------------------------------------------

CIV.players = {}        -- unitName -> { unitName, groupId, typeName, playerName, category }
CIV.typesPresent = {}   -- typeName -> true (heavy-lift gate; updated on BIRTH, covers MP slot changes)
CIV._menuBuilders = {}
CIV._menuBuiltGroups = {}
CIV.rootMenu = {}       -- groupId -> F10 "Civil Missions" submenu path

function CIV.Menu_register(builder)
  table.insert(CIV._menuBuilders, builder)
end

local function registerPlayer(unit)
  local ok, playerName = pcall(unit.getPlayerName, unit)
  if not ok or not playerName then return end
  local group = unit:getGroup()
  if not group then return end
  local uname, gid = unit:getName(), group:getID()
  CIV.players[uname] = {
    unitName = uname, groupId = gid, typeName = unit:getTypeName(),
    playerName = playerName, category = unit:getDesc().category,
  }
  CIV.typesPresent[unit:getTypeName()] = true
  CIV.dbg("Player registered: " .. playerName .. " in " .. unit:getTypeName())
  if not CIV._menuBuiltGroups[gid] then
    CIV._menuBuiltGroups[gid] = true
    CIV.rootMenu[gid] = missionCommands.addSubMenuForGroup(gid, "Civil Missions")
    for _, builder in ipairs(CIV._menuBuilders) do
      local ok2, err = pcall(builder, gid, uname)
      if not ok2 then CIV.log("Menu build error: " .. tostring(err)) end
    end
  end
end

local eventHandler = {}
function eventHandler:onEvent(event)
  if event.id == world.event.S_EVENT_BIRTH and event.initiator then
    pcall(registerPlayer, event.initiator)
  end
end
world.addEventHandler(eventHandler)

-- periodic cleanup of abandoned slots
CIV.schedule(function(_, t)
  for uname in pairs(CIV.players) do
    local u = Unit.getByName(uname)
    local ok, pn = pcall(function() return u and u:getPlayerName() end)
    if not u or not ok or not pn then CIV.players[uname] = nil end
  end
  return t + 30
end, nil, 30)

function CIV.forEachPlayer(fn)
  for uname, info in pairs(CIV.players) do
    local u = Unit.getByName(uname)
    if u and u:isExist() then fn(u, info) end
  end
end

function CIV.forEachPlayerHelo(fn)
  CIV.forEachPlayer(function(u, info)
    if info.category == Unit.Category.HELICOPTER then fn(u, info) end
  end)
end

----------------------------------------------------------------------
-- MESSAGING & MAP MARKS
----------------------------------------------------------------------

function CIV.msgUnit(unit, text, dur)
  local group = unit.getGroup and unit:getGroup()
  if group then trigger.action.outTextForGroup(group:getID(), text, dur or 15) end
end

function CIV.msgGroupId(gid, text, dur)
  trigger.action.outTextForGroup(gid, text, dur or 15)
end

function CIV.msgAll(text, dur)
  trigger.action.outTextForCoalition(CIV.Config.coalition, text, dur or 15)
end

function CIV.nextMarkId()
  CIV._ids.mark = CIV._ids.mark + 1
  return CIV._ids.mark
end

function CIV.mark(text, p)
  local id = CIV.nextMarkId()
  trigger.action.markToCoalition(id, text, p, CIV.Config.coalition, false)
  return id
end

-- dashed event circle on the F10 map (CSAR-style); returns mark id or nil
function CIV.markCircle(p, text, radiusM)
  local m = CIV.Config.marks
  if not m.drawCircles or not trigger.action.circleToAll then return nil end
  local id = CIV.nextMarkId()
  local ok = pcall(trigger.action.circleToAll, CIV.Config.coalition, id, p,
    radiusM or m.circleRadiusM, m.borderColor, m.fillColor, m.lineType, true, text)
  if ok then return id end
  return nil
end

function CIV.unmark(id)
  if id then pcall(trigger.action.removeMark, id) end
end

-- Draw the actual perimeter of a scanned zone on the F10 map: circleToAll
-- for circular zones, markupToAll freeform shape (id 7) for polygon zones
-- (falls back to the bounding circle if markupToAll is unavailable).
-- colors = { border = {r,g,b,a}, fill = {r,g,b,a} }. Returns mark id or nil.
function CIV.drawZoneOutline(area, label, colors, lineType)
  if not area then return nil end
  local id = CIV.nextMarkId()
  lineType = lineType or CIV.Config.marks.lineType
  local coa = CIV.Config.coalition
  if area.kind == "polygon" and trigger.action.markupToAll and #area.vertices >= 3 then
    local args = { 7, coa, id }   -- 7 = freeform polygon
    for _, v in ipairs(area.vertices) do
      args[#args + 1] = { x = v.x, y = 0, z = v.z }
    end
    args[#args + 1] = colors.border
    args[#args + 1] = colors.fill
    args[#args + 1] = lineType
    args[#args + 1] = true        -- read only
    args[#args + 1] = label
    local ok = pcall(function() trigger.action.markupToAll(unpack(args)) end)
    if ok then return id end
  end
  local center = { x = area.center.x, y = 0, z = area.center.z }
  local ok = pcall(trigger.action.circleToAll, coa, id, center, area.radius,
    colors.border, colors.fill, lineType, true, label)
  if ok then return id end
  return nil
end

-- Active-event zone highlight (colored by event kind, see marks.events)
function CIV.drawEventZone(area, label, kind)
  local cfg = CIV.Config.marks.events
  if not cfg.enabled or not cfg[kind] then return nil end
  return CIV.drawZoneOutline(area, label, cfg[kind])
end

----------------------------------------------------------------------
-- SPAWN HELPERS (template-based with hardcoded type fallback)
----------------------------------------------------------------------

CIV._spawnIdx = 0
function CIV.uniqueName(prefix)
  CIV._spawnIdx = CIV._spawnIdx + 1
  return string.format("%s_%d_%d", prefix, CIV._spawnIdx, math.floor(timer.getTime()))
end

local function nextGroupId()
  CIV._ids.group = CIV._ids.group + 1
  return CIV._ids.group
end
local function nextUnitId()
  CIV._ids.unit = CIV._ids.unit + 1
  return CIV._ids.unit
end

-- Clone a late-activated template at a point (CSAR-style). unitCount
-- optionally trims/duplicates the template's first unit to reach N units.
function CIV.spawnFromTemplate(templatePrefix, p, unitCount)
  local candidates = CIV.Templates.byPrefix(templatePrefix)
  if #candidates == 0 then return nil end
  local tpl = candidates[math.random(#candidates)]
  local g = deepCopy(tpl.data)
  g.name = CIV.uniqueName(templatePrefix)
  g.groupId = nextGroupId()
  g.lateActivation = false
  g.visible = false
  g.start_time = 0
  local refX = g.units[1] and g.units[1].x or p.x
  local refY = g.units[1] and g.units[1].y or p.z
  local units = {}
  local count = unitCount or #g.units
  for i = 1, count do
    local src = g.units[math.min(i, #g.units)]
    local u = deepCopy(src)
    u.name = g.name .. "_" .. i
    u.unitId = nextUnitId()
    -- keep the template's relative layout, re-centered on the target point
    u.x = p.x + ((src.x or refX) - refX) + (i > #g.units and (i * 2) or 0)
    u.y = p.z + ((src.y or refY) - refY) + (i > #g.units and (i * 2) or 0)
    units[i] = u
  end
  g.units = units
  g.route = { points = { { x = p.x, y = p.z, type = "Turning Point",
                           action = "Off Road", speed = 0 } } }
  coalition.addGroup(tpl.countryId, tpl.categoryEnum, g)
  return g.name, tpl.categoryEnum
end

-- Ground group: from template if present, else fallback type
function CIV.spawnGround(p, count, templatePrefix, fallbackType, namePrefix)
  if templatePrefix then
    local name = CIV.spawnFromTemplate(templatePrefix, p, count)
    if name then return name end
  end
  local gname = CIV.uniqueName(namePrefix or "CIVIL_GRP")
  local units = {}
  for i = 1, count do
    local ang = (i / count) * 2 * math.pi
    units[i] = {
      type = fallbackType, name = gname .. "_" .. i, unitId = nextUnitId(),
      x = p.x + math.cos(ang) * 3, y = p.z + math.sin(ang) * 3,
      heading = 0, skill = "Average", playerCanDrive = false,
    }
  end
  coalition.addGroup(CIV.Config.countryId, Group.Category.GROUND, {
    visible = false, lateActivation = false, task = "Ground Nothing",
    name = gname, groupId = nextGroupId(), units = units,
    route = { points = { { x = p.x, y = p.z, type = "Turning Point",
                           action = "Off Road", speed = 0 } } },
  })
  return gname
end

-- Ship group: from template if present, else fallback type. Defaults spawn
-- the SAR sea target; pass templatePrefix/fallbackType for other boats
-- (e.g. spawned rescue boats).
function CIV.spawnBoat(p, namePrefix, templatePrefix, fallbackType)
  local name = CIV.spawnFromTemplate(templatePrefix or CIV.Config.templates.boat, p, 1)
  if name then return name end
  local gname = CIV.uniqueName(namePrefix or "CIVIL_BOAT")
  coalition.addGroup(CIV.Config.countryId, Group.Category.SHIP, {
    visible = false, lateActivation = false, name = gname, groupId = nextGroupId(),
    units = { { type = fallbackType or CIV.Config.fallbackTypes.boat, name = gname .. "_1",
                unitId = nextUnitId(), x = p.x, y = p.z, heading = 0, skill = "Average" } },
    route = { points = { { x = p.x, y = p.z, type = "Turning Point", speed = 0 } } },
  })
  return gname
end

-- Cargo static with native mass (mass/canCargo fields). NOTE: some cargo
-- types have a fixed mass and ignore the field -> validate types in ME.
function CIV.spawnCargo(p, cargoType, kg, namePrefix)
  local name = CIV.uniqueName(namePrefix or "CIVIL_CARGO")
  coalition.addStaticObject(CIV.Config.countryId, {
    category = "Cargos", type = cargoType, name = name,
    x = p.x, y = p.z, heading = 0, mass = kg, canCargo = true,
  })
  return name
end

-- public id accessors for modules that build their own group data
-- (e.g. the ambient air traffic spawns airplane groups directly)
function CIV.newGroupId() return nextGroupId() end
function CIV.newUnitId() return nextUnitId() end

function CIV.despawnGroup(gname)
  local g = Group.getByName(gname)
  if g then g:destroy() end
end

function CIV.despawnStatic(sname)
  local s = StaticObject.getByName(sname)
  if s then s:destroy() end
end

----------------------------------------------------------------------
-- HOVER ZONE TRIGGER
-- Shared hover detection reused by: water pickup, SAR mountain/sea,
-- medevac, SWAT fast-rope. NOT an AI task: it polls the player unit
-- (Unit:getVelocity / Unit:getPoint) inside an envelope.
--   - T is a hard floor; the stability malus B only SLOWS progress:
--       rate = 1 / (1 + B * instability)   (rate <= 1, never a bonus)
--   - outside the envelope progress FREEZES (never resets); the real cost
--     of sloppy flying is the failure window that keeps running
--   - wind already acts on the flight model: no scripted weather malus,
--     the measured deviation captures it (no double penalty)
----------------------------------------------------------------------

CIV.Hover = { _sessions = {}, _watches = {}, _sid = 0, _wid = 0 }

function CIV.Hover.start(spec)
  CIV.Hover._sid = CIV.Hover._sid + 1
  local s = {
    id = CIV.Hover._sid, spec = spec,
    progress = 0,                   -- accumulated "valid" seconds
    startTime = timer.getTime(),    -- window starts here
    lastMsg = 0, done = false,
  }
  CIV.Hover._sessions[s.id] = s
  CIV.dbg("Hover start #" .. s.id .. " [" .. (spec.label or "?") .. "] unit=" .. spec.unitName)
  return s
end

function CIV.Hover.cancel(session)
  if session then CIV.Hover._sessions[session.id] = nil end
end

local function tickSession(s, now)
  local spec = s.spec

  if now - s.startTime > spec.window then
    s.done = true
    CIV.Hover._sessions[s.id] = nil
    if spec.onFail then pcall(spec.onFail, "window", s) end
    return
  end

  local u = Unit.getByName(spec.unitName)
  if not u or not u:isExist() then
    -- unit gone (crash/slot change): session stays open until the window
    -- expires, so another helicopter can take over via watch
    return
  end

  local p   = u:getPoint()
  local spd = CIV.speed(u:getVelocity())
  local dev = CIV.dist2D(p, spec.center)
  local agl = CIV.agl(p)

  if dev <= spec.radius and agl >= spec.minAGL and agl <= spec.maxAGL
     and spd <= spec.maxSpeed then
    -- normalized instability: how much of the envelope is being used up.
    -- This alone captures wind (real measured deviation).
    local instab = math.max(spd / spec.maxSpeed, dev / spec.radius)
    local rate = 1 / (1 + spec.B * instab)
    s.progress = s.progress + rate

    if spec.onProgress then pcall(spec.onProgress, u, s, s.progress / spec.T) end
    if now - s.lastMsg > 10 then
      s.lastMsg = now
      CIV.msgUnit(u, string.format("%s: %d%%  (stability %d%%)",
        spec.label or "Operation", math.floor(100 * s.progress / spec.T),
        math.floor(100 * rate)), 8)
    end

    if s.progress >= spec.T then
      s.done = true
      CIV.Hover._sessions[s.id] = nil
      if spec.onSuccess then pcall(spec.onSuccess, u, s) end
    end
  else
    if now - s.lastMsg > 15 then
      s.lastMsg = now
      CIV.msgUnit(u, string.format(
        "%s: out of position (dist %dm, AGL %dm, %.1f m/s). Window: %d min left",
        spec.label or "Operation", math.floor(dev), math.floor(agl), spd,
        math.floor((spec.window - (now - s.startTime)) / 60)), 8)
    end
  end
end

-- Watch: monitors a point and hooks the FIRST player helicopter entering
-- the envelope (used when we don't know in advance who will do the job).
function CIV.Hover.watch(wspec)
  CIV.Hover._wid = CIV.Hover._wid + 1
  local w = { id = CIV.Hover._wid, spec = wspec, session = nil }
  CIV.Hover._watches[w.id] = w
  return w
end

function CIV.Hover.unwatch(w)
  if not w then return end
  if w.session then CIV.Hover.cancel(w.session) end
  CIV.Hover._watches[w.id] = nil
end

local function tickWatch(w)
  if w.session then return end
  local ws = w.spec
  local detect = ws.detectRadius or (ws.radius * 3)
  CIV.forEachPlayerHelo(function(u, info)
    if w.session then return end
    if ws.filter and not ws.filter(u, info) then return end
    local p = u:getPoint()
    if CIV.dist2D(p, ws.center) <= detect and CIV.agl(p) <= ws.maxAGL * 3 then
      local spec = {}
      for k, v in pairs(ws) do spec[k] = v end
      spec.unitName = u:getName()
      local userSuccess, userFail = ws.onSuccess, ws.onFail
      spec.onSuccess = function(unit, s)
        CIV.Hover._watches[w.id] = nil
        if userSuccess then userSuccess(unit, s) end
      end
      spec.onFail = function(reason, s)
        CIV.Hover._watches[w.id] = nil
        if userFail then userFail(reason, s) end
      end
      w.session = CIV.Hover.start(spec)
      CIV.msgUnit(u, (ws.label or "Operation") ..
        ": in position. Hold your hover inside the area.", 10)
    end
  end)
end

-- single 1 Hz loop for all sessions and watches (each has its own state)
CIV.schedule(function(_, t)
  local now = timer.getTime()
  for _, s in pairs(CIV.Hover._sessions) do tickSession(s, now) end
  for _, w in pairs(CIV.Hover._watches) do tickWatch(w) end
  return t + 1
end, nil, 2)

----------------------------------------------------------------------
-- AIRDROP TRACKING (official C-130 module)
-- The mission scripting API cannot read the module's internal cargo bay,
-- so airdrops are detected from the outside. This is the shared channel-1
-- implementation: if the module releases containers as weapon objects
-- (S_EVENT_SHOT, Hercules-mod style), matching containers are tracked to
-- impact and offered to the registered consumers. Location-based object
-- scans (channel 2) live in the intervention files, since each scans its
-- own area (active fires / cargo destination).
--
-- Consumers register with:
--   CIV.Airdrop.register({
--     key,                       -- log label
--     matchesType(typeName),     -- crate-type filter for this consumer
--     matchAny,                  -- accept unmatched types too (validation phase)
--     onImpact(point, typeName) -> handled,  -- true = impact consumed
--   })
-- On impact, consumers are tried in registration order; the impact
-- location decides which one actually handles it.
----------------------------------------------------------------------

CIV.Airdrop = { _consumers = {}, _tracked = {} }

function CIV.Airdrop.register(consumer)
  table.insert(CIV.Airdrop._consumers, consumer)
end

-- substring matcher factory for containerTypes pattern lists
function CIV.Airdrop.typeMatcher(patterns)
  return function(typeName)
    for _, pattern in ipairs(patterns) do
      if string.find(typeName, pattern, 1, true) then return true end
    end
    return false
  end
end

-- nearest player airplane within radius (score attribution for drops)
function CIV.nearestPlayerAirplane(point, radius)
  local best, bestDist = nil, radius
  CIV.forEachPlayer(function(u, info)
    if info.category ~= Unit.Category.AIRPLANE then return end
    local d = CIV.dist2D(u:getPoint(), point)
    if d < bestDist then best, bestDist = info, d end
  end)
  return best
end

local function airdropWorthTracking(typeName)
  for _, consumer in ipairs(CIV.Airdrop._consumers) do
    if consumer.matchAny or consumer.matchesType(typeName) then return true end
  end
  return false
end

local airdropHandler = {}
function airdropHandler:onEvent(event)
  if event.id ~= world.event.S_EVENT_SHOT or not event.weapon then return end
  if #CIV.Airdrop._consumers == 0 then return end
  local ok, typeName = pcall(function() return event.weapon:getTypeName() end)
  if not ok or not typeName or not airdropWorthTracking(typeName) then return end
  table.insert(CIV.Airdrop._tracked, { w = event.weapon, typeName = typeName })
  CIV.dbg("Airdrop container released: " .. typeName)
end
world.addEventHandler(airdropHandler)

local function airdropImpact(point, typeName)
  for _, consumer in ipairs(CIV.Airdrop._consumers) do
    if consumer.matchAny or consumer.matchesType(typeName) then
      local ok, handled = pcall(consumer.onImpact, point, typeName)
      if ok and handled then
        CIV.dbg("Airdrop impact handled by '" .. consumer.key .. "': " .. typeName)
        return
      end
    end
  end
end

CIV.schedule(function(_, t)
  local tracked = CIV.Airdrop._tracked
  for i = #tracked, 1, -1 do
    local drop = tracked[i]
    local landed = false
    local ok, p = pcall(function() return drop.w:getPoint() end)
    if ok and p then
      drop.lastPos = p
      if CIV.agl(p) < 3 then landed = true end
    else
      landed = true   -- object gone: use the last known position as impact
    end
    if landed then
      table.remove(tracked, i)
      if drop.lastPos then airdropImpact(drop.lastPos, drop.typeName) end
    end
  end
  return t + 1
end, nil, 5)

----------------------------------------------------------------------
-- SCORE SYSTEM
-- Session score in memory (reset on mission end; no files, no hooks).
-- The scoring function is PURE (task + quality + time -> points) and
-- independent from where the total lives: a future persistent leaderboard
-- (server hook / external file / dcs.log parser) reuses the same math.
-- Every award also logs a parsable line to dcs.log:
--   SCORE|player|taskType|points|q=..|t=..
----------------------------------------------------------------------

CIV.Score = { _board = {} }

function CIV.Score.compute(taskType, quality, timeFactor, mult)
  local base = CIV.Config.score.base[taskType]
  if not base then return 0 end
  quality    = math.max(0, math.min(1, quality or 0.5))
  timeFactor = math.max(0, math.min(1, timeFactor or 0.5))
  return math.floor(base * (0.5 + 0.35 * quality + 0.15 * timeFactor) * (mult or 1) + 0.5)
end

function CIV.Score.award(playerName, taskType, quality, timeFactor, mult, label)
  local points = CIV.Score.compute(taskType, quality, timeFactor, mult)
  local row = CIV.Score._board[playerName]
  if not row then
    row = { points = 0, tasks = 0 }
    CIV.Score._board[playerName] = row
  end
  row.points = row.points + points
  row.tasks = row.tasks + 1
  CIV.log(string.format("SCORE|%s|%s|%d|q=%.2f|t=%.2f", playerName, taskType,
    points, quality or -1, timeFactor or -1))
  if CIV.Config.score.broadcast then
    CIV.msgAll(string.format("%s completed: %s  (%+d points, total %d)",
      playerName, label or taskType, points, row.points), 12)
  end
  return points
end

-- quality from a hover session: average timer efficiency (T / time spent)
function CIV.Score.hoverQuality(session)
  local spent = timer.getTime() - session.startTime
  if spent <= 0 then return 1 end
  return math.min(1, session.spec.T / spent)
end

-- time factor: fraction of the window NOT consumed
function CIV.Score.hoverTimeFactor(session)
  return math.max(0, 1 - (timer.getTime() - session.startTime) / session.spec.window)
end

local function showLeaderboard(gid)
  local rows = {}
  for name, row in pairs(CIV.Score._board) do
    rows[#rows + 1] = { name = name, points = row.points, tasks = row.tasks }
  end
  if #rows == 0 then
    CIV.msgGroupId(gid, "Session leaderboard: no tasks completed yet.", 10)
    return
  end
  table.sort(rows, function(a, b) return a.points > b.points end)
  local txt = "=== SESSION LEADERBOARD ===\n"
  for i, r in ipairs(rows) do
    txt = txt .. string.format("%d. %-20s %5d pts  (%d tasks)\n", i, r.name, r.points, r.tasks)
    if i >= 10 then break end
  end
  CIV.msgGroupId(gid, txt, 20)
end

CIV.Menu_register(function(gid)
  missionCommands.addCommandForGroup(gid, "Session leaderboard",
    CIV.rootMenu[gid], showLeaderboard, gid)
end)

----------------------------------------------------------------------
-- ZONE DRESSING (static scenery kits)
-- Zones are FIXED, hand-placed in ME on flat ground (no runtime flatness
-- check needed). Statics only: passive and cheap, no AI for scenery.
----------------------------------------------------------------------

CIV.Dressing = { _spawned = {} }

-- Type names TO VALIDATE per map/version. Each entry:
-- { type, category (default "Fortifications"), dx, dy, heading }
CIV.Dressing.kits = {
  medical_camp = {
    { type = "FARP Tent",              dx =   0, dy =   0, heading = 0 },
    { type = "FARP Tent",              dx =  15, dy =   0, heading = 0 },
    { type = "FARP Ammo Dump Coating", dx = -12, dy =   8, heading = 0 },
    { type = "Windsock",               dx =  25, dy = -20, heading = 0 },
    { type = "FARP Fuel Depot",        dx = -20, dy = -15, heading = 0 },
    { type = "Hummer",                 dx =  10, dy =  18, heading = 1.57, category = "Unarmed" },
  },
  c130_loading_area = {
    { type = "Container_10ft",  dx =   0, dy =   0, heading = 0 },
    { type = "Container_20ft",  dx =   6, dy =   0, heading = 0 },
    { type = "Container_40ft",  dx =  14, dy =   0, heading = 0 },
    { type = "FARP Fuel Depot", dx = -15, dy =  10, heading = 0 },
    { type = "Windsock",        dx = -25, dy = -25, heading = 0 },
  },
  refugee_camp = {
    { type = "FARP Tent", dx =   0, dy =   0, heading = 0 },
    { type = "FARP Tent", dx =  12, dy =   3, heading = 0.5 },
    { type = "FARP Tent", dx =  -8, dy =  14, heading = 2.1 },
    { type = "FARP Tent", dx =   4, dy = -16, heading = 1.2 },
    { type = "Cafe",      dx =  30, dy =   0, heading = 0 },
  },
}

function CIV.Dressing.spawn(areaName, kitName)
  local area = CIV.Zones.byName(areaName)
  if not area then
    CIV.log("Dressing: zone '" .. areaName .. "' not found in mission")
    return nil
  end
  local kit = CIV.Dressing.kits[kitName]
  if not kit then
    CIV.log("Dressing: unknown kit '" .. tostring(kitName) .. "'")
    return nil
  end
  local names = {}
  for _, item in ipairs(kit) do
    local name = CIV.uniqueName("CIVIL_DRESS")
    local ok, err = pcall(coalition.addStaticObject, CIV.Config.countryId, {
      category = item.category or "Fortifications",
      type = item.type, name = name,
      x = area.center.x + item.dx, y = area.center.z + item.dy,
      heading = item.heading or 0,
    })
    if ok then
      names[#names + 1] = name
    else
      -- invalid type on this map/version: log and keep going
      CIV.log("Dressing: static '" .. item.type .. "' failed: " .. tostring(err))
    end
  end
  CIV.Dressing._spawned[areaName] = names
  CIV.log("Dressing '" .. kitName .. "' on " .. areaName .. ": " .. #names .. " statics")
  return names
end

function CIV.Dressing.clear(areaName)
  for _, n in ipairs(CIV.Dressing._spawned[areaName] or {}) do CIV.despawnStatic(n) end
  CIV.Dressing._spawned[areaName] = nil
end

----------------------------------------------------------------------
-- EVENT DIRECTOR + ADMIN MENU
-- Intervention files register their starters into CIV.EventStarters:
--   CIV.EventStarters[key] = { label = "...", fn = function() ... end }
-- The director rolls each configured chance on a random interval; the
-- admin menu (built on player BIRTH, after all files loaded) lists them.
----------------------------------------------------------------------

CIV.EventStarters = {}

-- Keeps rescheduling even while disabled, so the command center can turn
-- the automatic director off and on again at runtime ("civil director on").
-- One sea roll picks WHICH sea event to start, by rarity weight, falling
-- through to the next tier when the picked one cannot start (e.g. no
-- merchant at sea for an inspection).
local function startSeaEvent()
  local tiers = {}
  for _, tier in ipairs(CIV.Config.director.seaTiers) do
    tiers[#tiers + 1] = { key = tier.key, weight = tier.weight }
  end
  while #tiers > 0 do
    local pick = CIV.weightedPick(tiers)
    local starter = CIV.EventStarters[pick.key]
    if starter then
      local ok, res = pcall(starter.fn)
      if ok and res then return res end
    end
    -- picked tier could not start: drop it and try the next
    for i, tier in ipairs(tiers) do
      if tier.key == pick.key then table.remove(tiers, i) break end
    end
  end
  return nil
end

CIV.schedule(function(_, t)
  local cfg = CIV.Config.director
  if cfg.enabled then
    -- co-occurrence budget: throttle every chance as the severity load
    -- climbs, reaching zero at the budget (grave events choke hardest)
    local factor = math.max(0, 1 - CIV.severityLoad() / cfg.severityBudget)
    for key, chance in pairs(cfg.chance) do
      if math.random(100) <= chance * factor then
        local ok, err
        if key == "seaEvent" then
          ok, err = pcall(startSeaEvent)
        else
          local starter = CIV.EventStarters[key]
          if starter then ok, err = pcall(starter.fn) end
        end
        if ok == false then CIV.log("Director: start '" .. key .. "' failed: " .. tostring(err)) end
      end
    end
  end
  return t + CIV.randBetween(cfg.interval)
end, nil, CIV.randBetween(CIV.Config.director.interval))

CIV.Menu_register(function(gid)
  if not CIV.Config.adminMenu then return end
  local sub = missionCommands.addSubMenuForGroup(gid, "Admin (test)", CIV.rootMenu[gid])
  for key, starter in pairs(CIV.EventStarters) do
    missionCommands.addCommandForGroup(gid, "Start: " .. starter.label, sub, function()
      local ok, res = pcall(starter.fn)
      if not ok then
        CIV.msgGroupId(gid, "Error: " .. tostring(res), 15)
      elseif not res then
        CIV.msgGroupId(gid, starter.label ..
          ": not started (cap reached or no free point in the pool).", 12)
      end
    end)
  end
  missionCommands.addCommandForGroup(gid, "Pool status", sub, function()
    local txt = "Loaded pools:\n"
    for prefix, pool in pairs(CIV.Pool._pools) do
      txt = txt .. string.format("- %s: %d points\n", prefix, #pool)
    end
    CIV.msgGroupId(gid, txt, 20)
  end)
end)

----------------------------------------------------------------------
-- STARTUP
----------------------------------------------------------------------

-- initial dressing of fixed areas (only where auto-dressing is enabled:
-- user-built static areas like the C-130 reload keep their own decoration)
CIV.schedule(function()
  if CIV.Config.autoDress.c130Reload then
    for _, area in ipairs(CIV.Zones.byPrefix(CIV.Config.zones.c130Reload)) do
      CIV.Dressing.spawn(area.name, "c130_loading_area")
    end
  end
  if CIV.Config.autoDress.hospitals then
    for _, pt in ipairs(CIV.Pool.load(CIV.Config.zones.hospitals)) do
      CIV.Dressing.spawn(pt.name, "medical_camp")
    end
  end
  for _, entry in ipairs(CIV.Config.autoDress.custom) do
    for _, area in ipairs(CIV.Zones.byPrefix(entry.prefix)) do
      CIV.Dressing.spawn(area.name, entry.kit)
    end
  end
end, nil, 5)

-- theme-area overlays on the F10 map: every zone matching each configured
-- prefix gets the outline (multiple macro-areas per type are supported)
CIV.schedule(function()
  local cfg = CIV.Config.marks.regions
  if not cfg.enabled then return end
  for _, entry in ipairs(cfg.list) do
    local zoneName = CIV.Config.zones[entry.zoneKey]
    if zoneName then
      for _, area in ipairs(CIV.Zones.byPrefix(zoneName)) do
        CIV.drawZoneOutline(area, entry.label,
          { border = entry.border, fill = entry.fill })
      end
    end
  end
end, nil, 4)

-- preload pools so dcs.log immediately shows what is defined in ME
CIV.schedule(function()
  local z = CIV.Config.zones
  for _, prefix in pairs({ z.firePoints, z.fireStations, z.waterPoints, z.sarMountainPoints,
      z.sarSeaPoints, z.policePoints, z.swatPoints, z.cargoPoints,
      z.medevacPoints, z.casevacPoints, z.hospitals, z.vesselSpawn,
      z.reconPoints, z.vipPads, z.dropZones }) do
    CIV.Pool.load(prefix)
  end
end, nil, 3)

-- Startup banner, visible to EVERYONE (outText, not coalition-bound, so
-- spectators and GM slots see it too): an immediate "initializing" line
-- the moment the core runs, then a READY summary once every DO SCRIPT
-- FILE action has executed, listing which modules actually loaded.
pcall(trigger.action.outText,
  "Civil Mission Template v" .. CIV.VERSION .. ": initializing...", 10)

CIV.schedule(function()
  local mods = {}
  if CIV.Fire then mods[#mods + 1] = "Firefighting" end
  if CIV.Rescue then mods[#mods + 1] = "Rescue" end
  if CIV.Police then mods[#mods + 1] = "Police/SWAT" end
  if CIV.Cargo then mods[#mods + 1] = "Transport" end
  if CIV.Recon then mods[#mods + 1] = "Aviation" end
  if CIV.Command then mods[#mods + 1] = "Command center" end
  pcall(trigger.action.outText,
    "Civil Mission Template v" .. CIV.VERSION .. " READY.\nModules: " ..
    (#mods > 0 and table.concat(mods, ", ") or "core only") ..
    ".\nRadio menu: F10 -> Civil Missions.", 20)
end, nil, 10)

CIV.log("CivilCore " .. CIV.VERSION .. " loaded")
