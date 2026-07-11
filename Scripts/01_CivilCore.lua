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
CIV.VERSION = "0.2.0"

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
    dropZones         = "CIVIL Drop Zone",            -- skydive drop zones (score = distance from center)
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
    vessel   = "CIVIL Vessel",     -- ship group: spawned rescue boat
    swatTeam = "CIVIL SWAT Team",  -- ground group: SWAT squad (unit count from template scaled at spawn)
    fugitive = "CIVIL Fugitive",   -- vehicle group: police chase car
    fireTruck= "CIVIL Fire Truck", -- vehicle group: fire brigade truck
    anomaly  = "CIVIL Anomaly",    -- ground group: recon corridor anomaly (optional visual)
    vip      = "CIVIL VIP",        -- ground group: waiting passenger (optional visual)
    skydiver = "CIVIL Skydiver",   -- ground group: landed jumpers (optional visual)
  },
  fallbackTypes = {
    survivor   = "Soldier M4",
    boat       = "ZWEZDNY",        -- TO VALIDATE on the chosen map
    rescueBoat = "speedboat",      -- stock small boat, TO VALIDATE type name
    swat       = "Soldier M4",
    fugitive   = "LandRover_ah",   -- TO VALIDATE on the chosen map
    fireTruck  = "HEMTT TFFT",     -- stock airfield fire truck, TO VALIDATE
    skydiver   = "Soldier M4",
  },

  -- Automatic scenery dressing of fixed zones. The C-130 reload and the
  -- CASEVAC LZs are normally USER-BUILT static areas (you decorate them
  -- yourself in the ME), so their auto-dressing is off by default.
  autoDress = {
    c130Reload = false,
    hospitals  = true,
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
      skydive     = 8,      -- jumpers released over a drop zone, quality = accuracy
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

    heloDropSeverity = 2.0,     -- severity removed per helicopter water drop
    c130DropPerSec   = 0.25,    -- severity removed per second during the line drop
    c130DropSeconds  = 10,      -- line drop duration

    -- Fire kinds, picked by weight at ignition. smokeOnly kinds use the
    -- thick-smoke effect presets (a dump burns dark and slow), growMult
    -- speeds up or slows down the severity growth cadence.
    kinds = {
      { name = "forest fire",     weight = 60, smokeOnly = false, growMult = 1.0 },
      { name = "landfill fire",   weight = 20, smokeOnly = true,  growMult = 0.6 },
      { name = "industrial fire", weight = 20, smokeOnly = false, growMult = 1.5 },
    },

    -- Fire brigade: when a fire ignites, trucks depart from the nearest
    -- "CIVIL Fire Station" zone and drive to it ("On Road" with the same
    -- stall watchdog used by the police chase). Once on scene they apply
    -- continuous ground suppression, so fewer air passes are needed.
    trucks = {
      enabled        = true,
      count          = 2,      -- trucks per fire
      speed          = 14,     -- m/s route speed (~50 km/h)
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
    sarMountain = {
      maxActive = 2,
      severity  = { min = 1, max = 10 },
      beacon = { enabled = false,   -- needs an .ogg file inside the .miz; homing only on some modules (finicky)
                 file = "l10-beacon.ogg", freqHz = 40500000, modulation = 1, power = 100 },
    },
    sarSea  = { maxActive = 2, severity = { min = 1, max = 10 }, beacon = { enabled = false } },
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
    trafficWatch = {
      enabled   = true,
      radius    = 1200,   -- m from the fleeing vehicle
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
      sarSea      = 20,
      medevac     = 25,
      casevac     = 20,
      chase       = 25,
      swat        = 15,
      transport   = 40,
      recon       = 20,
      vip         = 20,
      -- fires have their own dedicated scheduler (fire.autoIgnite)
    },
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
    boardSeconds = 20,
    pickupTtl    = 1800,    -- s before the transfer is reassigned (task expires)
    deadline     = { atMin = 2400, atMax = 1200 },  -- s criticality clock, severity-scaled
    comfort = {
      accelLimit    = 2.5,  -- the patient tolerates less than a VIP
      penaltyPerHit = 0.05,
    },
  },

  -- Skydive drops: the flying club. Climb over a CIVIL Drop Zone, release
  -- the jumpers via F10 above minAGL, and the landing point is computed
  -- from the wind (freefall drift + full canopy drift, with a steer
  -- correction toward the DZ center). Jumpers spawn on the ground where
  -- they land; the score quality is the distance from the zone center.
  skydive = {
    enabled       = true,
    jumpers       = 4,      -- figures spawned per drop
    minAGL        = 800,    -- m, minimum release height
    freefallSpeed = 50,     -- m/s vertical, belly-to-earth
    openAGL       = 500,    -- m, canopy opening height
    canopySink    = 5,      -- m/s under canopy
    freefallDrift = 0.3,    -- fraction of the wind acting during freefall
    steerM        = 150,    -- m the jumpers steer back toward the DZ center
    cooldown      = 180,    -- s per aircraft between drops
    despawnDelay  = 300,    -- s the landed jumpers stay on the ground
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

-- weighted random pick from a list of { weight = n, ... } entries
function CIV.weightedPick(list)
  local total = 0
  for _, entry in ipairs(list) do total = total + entry.weight end
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
    CIV.msgAll(string.format("%s completed: %s  (+%d points, total %d)",
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
CIV.schedule(function(_, t)
  local cfg = CIV.Config.director
  if cfg.enabled then
    for key, chance in pairs(cfg.chance) do
      local starter = CIV.EventStarters[key]
      if starter and math.random(100) <= chance then
        local ok, err = pcall(starter.fn)
        if not ok then CIV.log("Director: start '" .. key .. "' failed: " .. tostring(err)) end
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
      z.reconPoints, z.vipPads }) do
    CIV.Pool.load(prefix)
  end
end, nil, 3)

CIV.msgAll("Civil Mission Template v" .. CIV.VERSION .. " loaded.\nMenu: F10 -> Civil Missions", 20)
CIV.log("CivilCore " .. CIV.VERSION .. " loaded")
