----------------------------------------------------------------------
-- DCS Civil Mission Template - Rescue (SAR Mountain, SAR Sea, MedEvac)
-- File: 20_CivilRescue.lua  (requires 01_CivilCore.lua)
--
-- One generic rescue engine, three scenarios. Beacon/frequency logic and
-- survivor smoke marking adapted from the 527th CSAR System.
--
-- Event cycle:
--   spawn subject on a pool point (from "CIVIL Survivor"/"CIVIL Boat"
--   template if present, else fallback type) -> optional radio beacon
--   (homing only on Mi-8/UH-1H/SA342/AH-64D) -> extraction via hover watch
--   (first helicopter in the envelope gets the session) -> subject
--   despawned ("aboard") -> zone based delivery at a "CIVIL Hospital" pad
--   (hold low & still for N s).
--
-- Intel model: exact coordinates are NEVER broadcast automatically. The
-- initial report gives a rough direction and an approximate search circle
-- on the F10 map (subject inside, NOT centered). The exact position is
-- released only when a player airplane (C-130 spotter) flies close enough
-- to identify the subject. Survivor smoke remains available on request.
--
-- VERIFIED (concept): S_EVENT_LAND only fires on recognized airbase/FARP/
-- ship objects, NOT on arbitrary pads -> delivery is zone-based, never
-- the LAND event.
--
-- MedEvac difference: a CRITICALITY deadline. Score quality is the
-- remaining criticality fraction at pickup; delivery after the deadline
-- (even with the casualty aboard) means the patient did not make it.
----------------------------------------------------------------------

assert(CIV and CIV.VERSION, "01_CivilCore.lua must be loaded first")

local C = CIV.Config

CIV.Rescue = { _scenarios = {}, _aboard = {} }   -- _aboard: unitName -> list of subjects
local R = CIV.Rescue

----------------------------------------------------------------------
-- SUBJECTS ABOARD
----------------------------------------------------------------------

function R.aboardList(uname)
  R._aboard[uname] = R._aboard[uname] or {}
  return R._aboard[uname]
end

----------------------------------------------------------------------
-- SCENARIO ENGINE
-- def = { key, label, poolPrefix, region, maxActive, kind ("ground"|"boat"),
--         beacon, scoreType, hoverCfg, deadline (s, optional),
--         qualityFn(evt, session) optional }
----------------------------------------------------------------------

function R.newScenario(def)
  local sc = { def = def, events = {}, _eid = 0 }
  R._scenarios[def.key] = sc
  return sc
end

local function startBeacon(def, evt)
  local b = def.beacon
  if not (b and b.enabled) then return end
  -- needs the .ogg inside the .miz; homing works only on some modules
  evt.beaconName = "CIVIL_BCN_" .. def.key .. "_" .. evt.id
  local ok, err = pcall(trigger.action.radioTransmission,
    b.file, evt.point, b.modulation or 1, true, b.freqHz, b.power or 100, evt.beaconName)
  if not ok then
    CIV.log("Beacon failed (" .. tostring(err) .. "): falling back to text coordinates")
    evt.beaconName = nil
  end
end

local function stopBeacon(evt)
  if evt.beaconName then
    pcall(trigger.action.stopRadioTransmission, evt.beaconName)
    evt.beaconName = nil
  end
end

----------------------------------------------------------------------
-- AI SAR VESSELS
-- Ship groups placed in the ME (group name prefix rescue.vessels.
-- groupPrefix) steam toward the APPROXIMATE search area when a sea event
-- starts (they get the same low-precision intel as the players) and are
-- re-tasked to the exact point once a spotter identifies the subject.
----------------------------------------------------------------------

local vesselBusy = {}   -- groupName -> event id currently served

local function taskVessel(gname, point, speed)
  local g = Group.getByName(gname)
  if not g then return false end
  local ok = pcall(function()
    g:getController():setTask({ id = "Mission", params = { route = { points = {
      { x = point.x, y = point.z, type = "Turning Point", speed = speed },
    } } } })
  end)
  return ok
end

-- Nearest launch origin for spawned boats: mother ships (the hospital-ship
-- units, e.g. a Perry or a Tarawa) or "CIVIL Vessel Spawn" harbor zones.
local function nearestBoatOrigin(point)
  local best, bestDist = nil, 1e12
  for _, ship in ipairs(CIV.Ships) do
    if CIV.startsWith(ship.unitName, C.rescue.hospitalShips.unitPrefix) then
      local su = Unit.getByName(ship.unitName)
      if su and su:isExist() then
        local sp = su:getPoint()
        local d = CIV.dist2D(sp, point)
        if d < bestDist then
          best, bestDist = { point = sp, name = ship.unitName, isShip = true }, d
        end
      end
    end
  end
  for _, pt in ipairs(CIV.Pool.load(C.zones.vesselSpawn)) do
    local d = CIV.dist2D(pt.point, point)
    if d < bestDist then
      best, bestDist = { point = pt.point, name = pt.name, isShip = false }, d
    end
  end
  return best
end

local function dispatchVessels(evt)
  local vcfg = C.rescue.vessels
  if not vcfg.enabled then return end
  local seen, candidates = {}, {}
  for _, ship in ipairs(CIV.Ships) do
    local gname = ship.groupName
    if not seen[gname] and CIV.startsWith(gname, vcfg.groupPrefix)
       and not vesselBusy[gname] then
      seen[gname] = true
      local g = Group.getByName(gname)
      local u = g and g:getUnit(1)
      if u and u:isExist() then
        candidates[#candidates + 1] = {
          gname = gname, dist = CIV.dist2D(u:getPoint(), evt.approxCenter),
        }
      end
    end
  end
  table.sort(candidates, function(a, b) return a.dist < b.dist end)
  evt.vessels = {}
  for _, cand in ipairs(candidates) do
    if #evt.vessels >= vcfg.perEvent then break end
    if taskVessel(cand.gname, evt.approxCenter, vcfg.speed) then
      vesselBusy[cand.gname] = evt.id
      evt.vessels[#evt.vessels + 1] = cand.gname
    end
  end
  -- not enough pre-placed vessels: launch stock boats from the nearest
  -- origin (mother ship if it is closer than the harbors)
  evt.spawnedVessels = {}
  if vcfg.spawn.enabled and #evt.vessels < vcfg.perEvent then
    local origin = nearestBoatOrigin(evt.approxCenter)
    if origin then
      local launchPoint = origin.point
      if origin.isShip then
        -- clear of the mother ship's hull, offset toward the event
        launchPoint = CIV.offsetPoint(origin.point,
          CIV.bearingDeg(origin.point, evt.approxCenter), vcfg.spawn.offsetFromShip)
      end
      while #evt.vessels < vcfg.perEvent do
        local gname = CIV.spawnBoat(launchPoint, "CIVIL_RESCUEBOAT",
          C.templates.vessel, C.fallbackTypes.rescueBoat)
        evt.vessels[#evt.vessels + 1] = gname
        evt.spawnedVessels[#evt.spawnedVessels + 1] = gname
        CIV.schedule(function() taskVessel(gname, evt.approxCenter, vcfg.speed) end, nil, 2)
      end
      CIV.msgAll("Rescue boat(s) launched from " .. origin.name .. ".", 12)
    end
  end
  if #evt.vessels > 0 then
    CIV.msgAll(#evt.vessels .. " rescue vessel(s) underway to the search area.", 12)
  end
end

local function retaskVessels(evt, point)
  for _, gname in ipairs(evt.vessels or {}) do
    taskVessel(gname, point, C.rescue.vessels.speed)
  end
end

local function releaseVessels(evt)
  for _, gname in ipairs(evt.vessels or {}) do
    vesselBusy[gname] = nil
  end
  -- spawned boats are despawned after a scenic delay; pre-placed ones stay
  for _, gname in ipairs(evt.spawnedVessels or {}) do
    CIV.schedule(function() CIV.despawnGroup(gname) end, nil, 120)
  end
  evt.vessels = nil
  evt.spawnedVessels = nil
end

-- Scene dressing next to the casualty (ambulance and medics, wrecked
-- cars, battlefield props: whatever the matching ME template contains).
-- One random entry from the scenario's list, then one random template
-- among those sharing that prefix.
local function spawnScene(def, evt)
  local sceneList = C.rescue.scenes.byScenario[def.key]
  if not sceneList or #sceneList == 0 then return end
  local prefix = sceneList[math.random(#sceneList)]
  local scenePoint = CIV.offsetPoint(evt.point, math.random(0, 359),
    C.rescue.scenes.offsetM)
  local gname = CIV.spawnFromTemplate(prefix, scenePoint)
  if gname then
    evt.sceneGname = gname
    CIV.dbg("Scene '" .. prefix .. "' spawned for " .. def.key .. " #" .. evt.id)
  else
    CIV.dbg("No scene template found for prefix '" .. prefix .. "'")
  end
end

-- The scene lingers for a while after the event ends, then it is cleared
local function releaseScene(evt)
  if not evt.sceneGname then return end
  local gname = evt.sceneGname
  evt.sceneGname = nil
  CIV.schedule(function() CIV.despawnGroup(gname) end,
    nil, C.rescue.scenes.despawnDelay)
end

local function closeEvent(sc, evt)
  sc.events[evt.id] = nil
  CIV.Pool.release(evt.pt)
  stopBeacon(evt)
  releaseVessels(evt)
  releaseScene(evt)
  CIV.unmark(evt.markId)
  CIV.unmark(evt.circleId)
  if evt.gname then CIV.despawnGroup(evt.gname) end
  -- sinking scenario: clear any rafts still afloat
  if evt.rafts then
    for _, raft in ipairs(evt.rafts) do
      if raft.gname then CIV.despawnGroup(raft.gname) end
    end
    evt.rafts = nil
  end
end

-- command center: close an event without any outcome
function R.cancel(evt)
  local sc = R._scenarios[evt.scKey]
  if sc and sc.events[evt.id] then
    if evt.watch then CIV.Hover.unwatch(evt.watch) end
    closeEvent(sc, evt)
    return true
  end
  return false
end

-- reference point/name for the low-precision initial report: the scenario
-- region if defined, otherwise the nearest hospital pad
local function vagueReference(def, point)
  -- with several macro-regions per scenario, use the one containing the
  -- subject (fallback: the nearest one), and report ITS name
  local region = def.region
    and (CIV.Zones.containing(def.region, point) or CIV.Zones.nearest(def.region, point))
  if region then
    return { x = region.center.x, z = region.center.z }, region.name
  end
  local best, bestDist = nil, 1e12
  for _, pt in ipairs(CIV.Pool.load(C.zones.hospitals)) do
    local d = CIV.dist2D(point, pt.point)
    if d < bestDist then best, bestDist = pt, d end
  end
  if best then return best.point, best.name end
  return nil, nil
end

-- opts (command center): { point = vec3, severity = 1..10 }
function R.startEvent(key, opts)
  local sc = R._scenarios[key]
  if not sc then return nil end
  local def = sc.def
  local n = 0
  for _ in pairs(sc.events) do n = n + 1 end
  if not (opts and opts.point) and n >= def.maxActive then return nil end

  local pt
  if opts and opts.point then
    -- commanded position instead of the curated pool
    if def.kind == "boat" and not CIV.isWater(opts.point) then
      CIV.msgAll(def.label .. ": commanded position is not on open water.", 10)
      return nil
    end
    sc._gmid = (sc._gmid or 0) + 1
    pt = {
      name = "GM " .. def.key .. " " .. sc._gmid, radius = 100,
      point = { x = opts.point.x, y = CIV.groundY(opts.point), z = opts.point.z },
    }
  else
    -- bias the spawn to the region a player is in (see Pool.pickNearPlayers)
    pt = (C.rescue.spawnNearPlayers
      and CIV.Pool.pickNearPlayers(def.poolPrefix, def.region, 1000))
      or CIV.Pool.pick(def.poolPrefix, 1000)
    if not pt then
      CIV.dbg("Rescue " .. key .. ": no free point in pool " .. def.poolPrefix)
      return nil
    end
  end

  sc._eid = sc._eid + 1
  -- one severity roll shapes the whole event: deadline, hover envelope, score
  local sev = (opts and opts.severity)
    and math.max(1, math.min(10, opts.severity))
    or CIV.rollSeverity(def.severityRange)
  local se = C.rescue.severityEffects
  local evt = {
    id = sc._eid, pt = pt, point = pt.point,
    severity = sev, scKey = def.key,
    spawnTime = timer.getTime(),
  }
  if def.deadline then
    evt.deadlineTotal = def.deadline
      * CIV.sevLerp(sev, se.deadlineFactor.atMin, se.deadlineFactor.atMax)
    evt.deadline = timer.getTime() + evt.deadlineTotal
  end
  if def.kind == "boat" then
    evt.gname = CIV.spawnBoat(pt.point, "CIVIL_" .. def.key)
  else
    evt.gname = CIV.spawnGround(pt.point, 1,
      def.templatePrefix or C.templates.survivor,
      C.fallbackTypes.survivor, "CIVIL_" .. def.key)
  end
  startBeacon(def, evt)
  spawnScene(def, evt)
  sc.events[evt.id] = evt
  CIV.Pool.occupy(pt)

  -- Approximate search circle (CSAR opponent-intel style): the subject is
  -- inside the circle but NOT at its center, and the radius is random.
  local intel = C.rescue.intel
  local circleRadius = CIV.randBetween(intel.approxRadius)
  local circleCenter = CIV.offsetPoint(evt.point, math.random(0, 359),
    circleRadius * CIV.randBetween(intel.centerOffset))
  evt.approxCenter = circleCenter
  evt.circleId = CIV.markCircle(circleCenter,
    def.label .. " #" .. evt.id .. " search area", circleRadius)
  evt.identified = false
  if def.kind == "boat" then dispatchVessels(evt) end

  local refPoint, refName = vagueReference(def, evt.point)
  evt.vagueText = refPoint
    and CIV.vagueDirection(refPoint, refName, evt.point)
    or "position unknown"

  local msg = def.label .. " (severity " .. sev .. "/10): subject awaiting " ..
    "recovery, " .. evt.vagueText ..
    ".\nApproximate search area marked on the F10 map. Exact position " ..
    "requires a spotter aircraft overhead (or request smoke when close)."
  if evt.beaconName then
    msg = msg .. string.format("\nBeacon active on %.3f MHz", def.beacon.freqHz / 1e6)
  end
  if evt.deadline then
    msg = msg .. string.format("\nCriticality: %d minutes", math.floor(evt.deadlineTotal / 60))
  end
  CIV.msgAll(msg, 25)

  -- severity shapes the hover envelope: less window, more required time
  local hp = def.hoverCfg
  local windowS = hp.window * CIV.sevLerp(sev, se.windowFactor.atMin, se.windowFactor.atMax)
  local requiredT = hp.T * CIV.sevLerp(sev, se.tFactor.atMin, se.tFactor.atMax)
  evt.watch = CIV.Hover.watch({
    center = evt.point, label = def.label .. " - extraction",
    radius = hp.radius, minAGL = hp.minAGL, maxAGL = hp.maxAGL,
    maxSpeed = hp.maxSpeed, T = requiredT, window = windowS, B = hp.B,
    onSuccess = function(unit, session)
      -- despawn = loaded aboard; delivery just consumes the state flag.
      -- The scene assets stay a few more minutes, then they pack up.
      CIV.despawnGroup(evt.gname)
      evt.gname = nil
      stopBeacon(evt)
      releaseVessels(evt)
      releaseScene(evt)
      table.insert(R.aboardList(unit:getName()), {
        scoreType = def.scoreType, label = def.label, evt = evt,
        quality = def.qualityFn and def.qualityFn(evt, session)
                  or CIV.Score.hoverQuality(session),
        timeFactor = CIV.Score.hoverTimeFactor(session),
        mult = CIV.severityMult(evt.severity),
      })
      sc.events[evt.id] = nil
      CIV.Pool.release(evt.pt)
      CIV.unmark(evt.markId)
      CIV.unmark(evt.circleId)
      CIV.msgUnit(unit, def.label .. ": subject ABOARD. Deliver to a " ..
        "hospital pad (" .. C.zones.hospitals .. " zones): hold low and " ..
        "still for " .. C.rescue.delivery.holdSeconds .. " seconds.", 20)
      local pinfo = CIV.players[unit:getName()]
      if pinfo then
        CIV.msgAll(def.label .. ": " .. pinfo.playerName ..
          " has the subject ABOARD, inbound to the hospital.", 10)
      end
    end,
    onFail = function()
      -- Sea events with vessels en route are NOT lost yet: the event stays
      -- alive for one extra window so the boats can complete the rescue
      -- (spotter credit). Everything else fails as before.
      if def.kind == "boat" and evt.vessels and #evt.vessels > 0 then
        evt.heloFailed = true
        evt.hardDeadline = timer.getTime() + windowS
        CIV.msgAll(def.label .. ": helicopter recovery window EXPIRED at " ..
          pt.name .. ". Rescue vessels are still en route: the subject is " ..
          "holding on for now.", 20)
      else
        CIV.msgAll(def.label .. ": recovery FAILED at " .. pt.name ..
          " (window expired). The subject did not make it.", 20)
        closeEvent(sc, evt)
      end
    end,
  })
  CIV.log("Rescue " .. key .. " event #" .. evt.id .. " at " .. pt.name)
  return evt
end

----------------------------------------------------------------------
-- HOSPITAL DELIVERY (zone-based: still & low inside a hospital zone)
----------------------------------------------------------------------

local deliveryTimer = {}   -- unitName -> time the valid dwell started

-- Mobile hospital ship check: everything is measured RELATIVE to the ship
-- unit (it may be underway): horizontal distance, altitude above the ship
-- reference point within deck bounds, and relative speed.
local function onHospitalShip(u, p)
  local hcfg = C.rescue.hospitalShips
  if not hcfg.enabled then return false end
  for _, ship in ipairs(CIV.Ships) do
    if CIV.startsWith(ship.unitName, hcfg.unitPrefix) then
      local su = Unit.getByName(ship.unitName)
      if su and su:isExist() then
        local sp = su:getPoint()
        if CIV.dist2D(p, sp) <= hcfg.radius then
          local hv, sv = u:getVelocity(), su:getVelocity()
          local relSpeed = CIV.speed({ x = hv.x - sv.x, y = hv.y - sv.y, z = hv.z - sv.z })
          local deckHeight = p.y - sp.y
          if relSpeed <= hcfg.maxRelSpeed
             and deckHeight >= -5 and deckHeight <= hcfg.deckAGLMax then
            return true
          end
        end
      end
    end
  end
  return false
end

CIV.schedule(function(_, t)
  local cd = C.rescue.delivery
  local now = timer.getTime()
  for uname, list in pairs(R._aboard) do
    if #list > 0 then
      local u = Unit.getByName(uname)
      if u and u:isExist() then
        local p = u:getPoint()
        local inHospital = false
        for _, pt in ipairs(CIV.Pool.load(C.zones.hospitals)) do
          if CIV.dist2D(p, pt.point) <= math.max(pt.radius, cd.radius) then
            inHospital = true
            break
          end
        end
        local stillAndLow = CIV.speed(u:getVelocity()) <= cd.maxSpeed
          and CIV.agl(p) <= cd.maxAGL
        if (inHospital and stillAndLow) or onHospitalShip(u, p) then
          deliveryTimer[uname] = deliveryTimer[uname] or now
          if now - deliveryTimer[uname] >= cd.holdSeconds then
            deliveryTimer[uname] = nil
            local info = CIV.players[uname]
            for _, subj in ipairs(list) do
              if subj.evt.deadline and now > subj.evt.deadline then
                CIV.msgUnit(u, subj.label .. ": the subject died before delivery.", 15)
              elseif info then
                CIV.Score.award(info.playerName, subj.scoreType,
                  subj.quality, subj.timeFactor, subj.mult or 1, subj.label)
                -- event chain: a delivered high-severity patient sometimes
                -- needs a second leg to a regional hospital (air ambulance,
                -- see 45_CivilAviation). Guarded: the module is optional.
                if CIV.MedTransfer then
                  CIV.MedTransfer.maybeStart(subj.evt.severity, p)
                end
              end
            end
            R._aboard[uname] = {}
            CIV.msgUnit(u, "Hospital delivery complete.", 15)
          end
        else
          deliveryTimer[uname] = nil
        end
      end
    end
  end
  return t + 2
end, nil, 10)

-- criticality deadline notification while aboard (MedEvac)
CIV.schedule(function(_, t)
  local now = timer.getTime()
  for uname, list in pairs(R._aboard) do
    for _, subj in ipairs(list) do
      if subj.evt.deadline and not subj.deathNotified and now > subj.evt.deadline then
        subj.deathNotified = true
        local u = Unit.getByName(uname)
        if u then
          CIV.msgUnit(u, subj.label .. ": criticality expired, the patient died aboard.", 15)
        end
      end
    end
  end
  return t + 10
end, nil, 20)

----------------------------------------------------------------------
-- SUBJECT SIGNAL ON REQUEST (all rescue variants share it)
-- Orange smoke by day; by night smoke is invisible, so the subject fires
-- a sequence of signal flares instead. CSAR-style visual mark.
----------------------------------------------------------------------

local function requestSignal(uname)
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  local p = u:getPoint()
  local best, bestDist = nil, 15000   -- only within 15 km
  for _, sc in pairs(R._scenarios) do
    for _, evt in pairs(sc.events) do
      local d = CIV.dist2D(p, evt.point)
      if d < bestDist then best, bestDist = evt, d end
    end
  end
  if not best then
    CIV.msgUnit(u, "No rescue subject within 15 km.", 10)
    return
  end
  if CIV.isNight() then
    local sig = C.rescue.signal
    for i = 0, sig.flareCount - 1 do
      CIV.schedule(function()
        local fp = CIV.offsetPoint(best.point, math.random(0, 359), 5)
        pcall(trigger.action.signalFlare, fp,
          trigger.flareColor and trigger.flareColor.Green or 0,
          math.random(0, 359))
      end, nil, 1 + i * sig.flareIntervalSeconds)
    end
    CIV.msgUnit(u, "Subject is firing GREEN signal flares (" ..
      sig.flareCount .. " shots). Watch for them before pickup.", 12)
  else
    local sp = CIV.offsetPoint(best.point, math.random(0, 359), C.rescue.smokeOffsetM)
    trigger.action.smoke(sp, trigger.smokeColor.Orange)
    CIV.msgUnit(u, "Subject is marking position with ORANGE smoke. " ..
      "Confirm visual before pickup.", 12)
  end
end
R.requestSignal = requestSignal

----------------------------------------------------------------------
-- SPOTTER IDENTIFICATION
-- A subject stays unidentified (vague direction + approximate circle
-- only) until an airborne player airplane (C-130) either enters the
-- scenario region or flies within intel.spotterDetectRadius of the
-- subject. Identification is one-shot: it releases the exact position
-- and drops a point mark on the F10 map.
----------------------------------------------------------------------

CIV.schedule(function(_, t)
  local detectR = C.rescue.intel.spotterDetectRadius
  for _, sc in pairs(R._scenarios) do
    local regionPrefix = sc.def.region
    for _, evt in pairs(sc.events) do
      if not evt.identified then
        local spotter = nil
        CIV.forEachPlayer(function(u, info)
          if spotter then return end
          if info.category ~= Unit.Category.AIRPLANE or not u:inAir() then return end
          local p = u:getPoint()
          if (regionPrefix and CIV.Zones.containing(regionPrefix, p))
             or CIV.dist2D(p, evt.point) <= detectR then
            spotter = info
          end
        end)
        if spotter then
          evt.identified = true
          evt.spotterName = spotter.playerName   -- credited on a sea rescue
          evt.markId = CIV.mark(sc.def.label .. " #" .. evt.id, evt.point)
          retaskVessels(evt, evt.point)   -- vessels steer to the exact position
          CIV.Score.award(spotter.playerName, "spotter", 0.7, 0.5,
            CIV.severityMult(evt.severity),
            sc.def.label .. " #" .. evt.id .. " identified")
          CIV.msgAll("SPOTTER " .. spotter.playerName .. " has identified the " ..
            sc.def.label .. " #" .. evt.id .. " subject:\n" ..
            CIV.coordText(evt.point) .. "\nExact position marked on the F10 map.", 20)
        end
      end
    end
  end
  return t + 15
end, nil, 45)

----------------------------------------------------------------------
-- SEA RESCUE BY VESSEL
-- A vessel holding within rescueRadius of the subject for
-- rescueHoldSeconds completes the rescue by sea; the identifying spotter
-- gets the score (the C-130 made the sea rescue possible). Also enforces
-- the extended hard deadline after a failed helicopter window.
----------------------------------------------------------------------

CIV.schedule(function(_, t)
  local vcfg = C.rescue.vessels
  local now = timer.getTime()
  for _, sc in pairs(R._scenarios) do
    if sc.def.kind == "boat" then
      for _, evt in pairs(sc.events) do
        if evt.heloFailed and now > evt.hardDeadline then
          CIV.msgAll(sc.def.label .. ": the subject was lost at sea before " ..
            "the vessels could arrive.", 20)
          closeEvent(sc, evt)
        elseif evt.gname then
          local near = false
          for _, gname in ipairs(evt.vessels or {}) do
            local g = Group.getByName(gname)
            local u = g and g:getUnit(1)
            if u and u:isExist()
               and CIV.dist2D(u:getPoint(), evt.point) <= vcfg.rescueRadius then
              near = true
              break
            end
          end
          if near then
            evt.vesselNearSince = evt.vesselNearSince or now
            if now - evt.vesselNearSince >= vcfg.rescueHoldSeconds then
              if evt.watch then CIV.Hover.unwatch(evt.watch) end
              local msg = sc.def.label .. ": subject RECOVERED by a rescue vessel."
              if evt.spotterName then
                CIV.Score.award(evt.spotterName, sc.def.scoreType, 0.7, 0.5,
                  vcfg.spotterScoreMult * CIV.severityMult(evt.severity),
                  "sea rescue (spotter credit)")
              else
                msg = msg .. " No spotter on station: no credit assigned."
              end
              CIV.msgAll(msg, 20)
              closeEvent(sc, evt)
            end
          else
            evt.vesselNearSince = nil
          end
        end
      end
    end
  end
  return t + 5
end, nil, 25)

----------------------------------------------------------------------
-- SINKING SHIP (mass rescue, rare tier)
-- A vessel is going down with a dozen survivors in life rafts scattered
-- around the wreck. Same intel fog as the other sea SAR (approximate
-- circle, a spotter reveals the exact area via the shared spotter loop),
-- but recovery is PER RAFT: a helicopter holds a brief hover over a raft
-- to pull those survivors aboard, one raft at a time, until the ship goes
-- down (the deadline) and any raft not reached is lost. Needs a "CIVIL
-- Raft" template; the "CIVIL Sinking" wreck model is optional visual.
----------------------------------------------------------------------

-- opts (command center): { point = vec3 (must be water), severity = 1..10 }
function R.startSinking(opts)
  local sc = R._scenarios.SAR_SINKING
  if not sc then return nil end
  local scfg = C.rescue.sinking
  -- no raft template, no scenario (nothing to rescue)
  if #CIV.Templates.byPrefix(C.templates.raft) == 0 then
    CIV.dbg("Sinking: no '" .. C.templates.raft .. "' template, scenario skipped")
    return nil
  end
  local n = 0
  for _ in pairs(sc.events) do n = n + 1 end
  if not (opts and opts.point) and n >= scfg.maxActive then return nil end

  local pt
  if opts and opts.point then
    if not CIV.isWater(opts.point) then
      CIV.msgAll("Sinking ship: commanded position is not on open water.", 10)
      return nil
    end
    sc._gmid = (sc._gmid or 0) + 1
    pt = { name = "GM sinking " .. sc._gmid, radius = 100,
           point = { x = opts.point.x, y = 0, z = opts.point.z } }
  else
    pt = (C.rescue.spawnNearPlayers
      and CIV.Pool.pickNearPlayers(C.zones.sarSeaPoints, C.zones.sarSeaRegion, 1000))
      or CIV.Pool.pick(C.zones.sarSeaPoints, 1000)
    if not pt then return nil end
  end

  sc._eid = sc._eid + 1
  local sev = (opts and opts.severity)
    and math.max(1, math.min(10, opts.severity))
    or CIV.rollSeverity(scfg.severity)
  local se = C.rescue.severityEffects
  local evt = {
    id = sc._eid, pt = pt, point = pt.point, severity = sev,
    scKey = "SAR_SINKING", spawnTime = timer.getTime(),
    identified = false, rafts = {}, recovered = 0,
  }
  evt.deadlineTotal = scfg.deadline
    * CIV.sevLerp(sev, se.deadlineFactor.atMin, se.deadlineFactor.atMax)
  evt.deadline = timer.getTime() + evt.deadlineTotal

  -- optional wreck model at the centre (closeEvent despawns evt.gname)
  evt.gname = CIV.spawnFromTemplate(C.templates.sinking, pt.point)

  -- scatter the rafts around the wreck, each its own group
  local count = math.random(scfg.raftCount.min, scfg.raftCount.max)
  for i = 1, count do
    local rp = CIV.offsetPoint(pt.point, math.random(0, 359),
      math.random(30, scfg.spreadRadius))
    local gname = CIV.spawnBoat(rp, "CIVIL_RAFT", C.templates.raft, C.fallbackTypes.raft)
    evt.rafts[i] = { gname = gname, point = rp, done = false, dwell = 0, byUnit = nil }
  end

  -- intel fog: approximate off-centre circle, exact area needs a spotter
  local intel = C.rescue.intel
  local circleRadius = CIV.randBetween(intel.approxRadius)
  local circleCenter = CIV.offsetPoint(evt.point, math.random(0, 359),
    circleRadius * CIV.randBetween(intel.centerOffset))
  evt.approxCenter = circleCenter
  evt.circleId = CIV.markCircle(circleCenter,
    "Sinking ship #" .. evt.id .. " search area", circleRadius)

  local refPoint, refName = vagueReference(sc.def, evt.point)
  evt.vagueText = refPoint
    and CIV.vagueDirection(refPoint, refName, evt.point) or "position unknown"

  sc.events[evt.id] = evt
  CIV.Pool.occupy(pt)
  CIV.msgAll("MAYDAY - SINKING SHIP (severity " .. sev .. "/10): " .. count ..
    " survivors in life rafts, " .. evt.vagueText ..
    ".\nApproximate search area marked on the F10 map; a spotter overhead " ..
    "pins the exact area. Hover briefly over each raft to pull them aboard." ..
    "\nThe ship goes down in about " .. math.floor(evt.deadlineTotal / 60) ..
    " minutes: every raft not reached by then is lost.", 30)
  CIV.log("Sinking #" .. evt.id .. " at " .. pt.name .. " severity " .. sev ..
    " rafts " .. count)
  return evt
end

-- raft recovery loop: a brief steady hover over a raft pulls it aboard
CIV.schedule(function(_, t)
  local sc = R._scenarios.SAR_SINKING
  if not sc then return t + 5 end
  local scfg = C.rescue.sinking
  local now = timer.getTime()
  for _, evt in pairs(sc.events) do
    if now > evt.deadline then
      local lost = 0
      for _, raft in ipairs(evt.rafts) do if not raft.done then lost = lost + 1 end end
      CIV.msgAll("SINKING SHIP #" .. evt.id .. ": the vessel has gone down. " ..
        evt.recovered .. " survivors recovered, " .. lost .. " lost.", 20)
      closeEvent(sc, evt)
    else
      -- snapshot the player helicopters in a valid pickup state ONCE per
      -- tick (position + low + slow), then match rafts against it, instead
      -- of re-scanning every player for each of the dozen rafts
      local heloz = {}
      CIV.forEachPlayerHelo(function(h, info)
        local hp = h:getPoint()
        if CIV.agl(hp) <= scfg.maxAGL
           and CIV.speed(h:getVelocity()) <= scfg.maxSpeed then
          heloz[#heloz + 1] = { point = hp, name = info.playerName }
        end
      end)
      for _, raft in ipairs(evt.rafts) do
        if not raft.done then
          local rescuer = nil
          for _, h in ipairs(heloz) do
            if CIV.dist2D(h.point, raft.point) <= scfg.rescueRadius then
              rescuer = h
              break
            end
          end
          if rescuer then
            raft.dwell = raft.dwell + 2   -- 2 s tick
            raft.byUnit = rescuer.name
            if raft.dwell >= scfg.raftHoldSeconds then
              raft.done = true
              if raft.gname then CIV.despawnGroup(raft.gname) end
              evt.recovered = evt.recovered + 1
              local timeFactor = math.max(0, (evt.deadline - now) / evt.deadlineTotal)
              CIV.Score.award(raft.byUnit, "sinking", 0.8, timeFactor,
                CIV.severityMult(evt.severity), "sinking-ship rescue")
              CIV.msgAll("SINKING SHIP #" .. evt.id .. ": " .. raft.byUnit ..
                " pulled a raft aboard (" .. evt.recovered .. "/" ..
                #evt.rafts .. " survivors safe).", 12)
              if evt.recovered >= #evt.rafts then
                CIV.msgAll("SINKING SHIP #" .. evt.id ..
                  ": ALL survivors recovered. Outstanding work.", 20)
                closeEvent(sc, evt)
                break
              end
            end
          else
            raft.dwell = 0
          end
        end
      end
    end
  end
  return t + 2
end, nil, 25)

----------------------------------------------------------------------
-- SCENARIO INSTANCES
----------------------------------------------------------------------

-- quality = remaining criticality fraction at PICKUP time (delivery past
-- the deadline still voids the score, see the delivery loop). Uses the
-- severity-scaled per-event deadline.
local function criticalityQuality(evt)
  local left = evt.deadline - timer.getTime()
  return math.max(0, math.min(1, left / evt.deadlineTotal))
end

R.newScenario({
  key = "SAR_MOUNTAIN", label = "SAR Mountain", kind = "ground",
  poolPrefix = C.zones.sarMountainPoints, region = C.zones.sarMountainRegion,
  maxActive = C.rescue.sarMountain.maxActive, beacon = C.rescue.sarMountain.beacon,
  severityRange = C.rescue.sarMountain.severity,
  scoreType = "sarMountain", hoverCfg = C.hover.sarMountain,
})

R.newScenario({
  key = "SAR_SEA", label = "SAR Sea", kind = "boat",
  -- a floating unit on open water is a standard DCS use case: low risk
  poolPrefix = C.zones.sarSeaPoints, region = C.zones.sarSeaRegion,
  maxActive = C.rescue.sarSea.maxActive, beacon = C.rescue.sarSea.beacon,
  severityRange = C.rescue.sarSea.severity,
  scoreType = "sarSea", hoverCfg = C.hover.sarSea,
})

-- Sinking ship shares the sea region (spotter reveal + vague reference)
-- but its own recovery mechanic lives in R.startSinking / the raft loop.
R.newScenario({
  key = "SAR_SINKING", label = "Sinking ship", kind = "sinking",
  poolPrefix = C.zones.sarSeaPoints, region = C.zones.sarSeaRegion,
  maxActive = C.rescue.sinking.maxActive,
  severityRange = C.rescue.sinking.severity, scoreType = "sinking",
})

R.newScenario({
  key = "MEDEVAC", label = "MedEvac", kind = "ground",
  poolPrefix = C.zones.medevacPoints, region = nil,
  maxActive = C.rescue.medevac.maxActive, beacon = nil,
  severityRange = C.rescue.medevac.severity,
  scoreType = "medevac", hoverCfg = C.hover.medevac,
  deadline = C.rescue.medevac.criticality,
  qualityFn = criticalityQuality,
})

-- Battlefield casualty extraction: same flow as MedEvac (the concept
-- anticipated this reuse: same scheme, hostile narrative skin), with its
-- own LZ pool, casualty template, tighter criticality and score premium.
R.newScenario({
  key = "CASEVAC", label = "Battlefield CASEVAC", kind = "ground",
  poolPrefix = C.zones.casevacPoints, region = nil,
  maxActive = C.rescue.casevac.maxActive, beacon = nil,
  templatePrefix = C.templates.casualty,
  severityRange = C.rescue.casevac.severity,
  scoreType = "casevac", hoverCfg = C.hover.casevac,
  deadline = C.rescue.casevac.criticality,
  qualityFn = criticalityQuality,
})

----------------------------------------------------------------------
-- F10 MENU + EVENT STARTERS
----------------------------------------------------------------------

CIV.Menu_register(function(gid, uname)
  local sub = missionCommands.addSubMenuForGroup(gid, "Rescue", CIV.rootMenu[gid])
  missionCommands.addCommandForGroup(gid,
    "Request signal from subject (smoke / night flares)", sub, requestSignal, uname)
  missionCommands.addCommandForGroup(gid, "Active rescue events", sub, function()
    local n, txt = 0, "Active rescue events:\n"
    for _, sc in pairs(R._scenarios) do
      for _, evt in pairs(sc.events) do
        n = n + 1
        -- exact coordinates only once a spotter has identified the subject
        local pos = evt.identified and CIV.llString(evt.point)
          or (evt.vagueText .. " (not identified: needs a spotter overhead)")
        txt = txt .. string.format("- %s #%d (severity %d/10): %s\n",
          sc.def.label, evt.id, evt.severity, pos)
      end
    end
    CIV.msgGroupId(gid, n > 0 and txt or "No active rescue events.", 20)
  end)
end)

CIV.EventStarters.sarMountain = { label = "SAR Mountain",
  fn = function() return R.startEvent("SAR_MOUNTAIN") end }
CIV.EventStarters.sarSea = { label = "SAR Sea",
  fn = function() return R.startEvent("SAR_SEA") end }
CIV.EventStarters.sarSinking = { label = "Sinking ship (mass rescue)",
  fn = function() return R.startSinking() end }
CIV.EventStarters.medevac = { label = "MedEvac",
  fn = function() return R.startEvent("MEDEVAC") end }
CIV.EventStarters.casevac = { label = "Battlefield CASEVAC",
  fn = function() return R.startEvent("CASEVAC") end }

CIV.log("CivilRescue loaded")
