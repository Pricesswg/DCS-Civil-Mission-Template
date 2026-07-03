----------------------------------------------------------------------
-- DCS Civil Mission Template — Rescue (SAR Mountain, SAR Sea, MedEvac)
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

local function closeEvent(sc, evt)
  sc.events[evt.id] = nil
  CIV.Pool.release(evt.pt)
  stopBeacon(evt)
  CIV.unmark(evt.markId)
  CIV.unmark(evt.circleId)
  if evt.gname then CIV.despawnGroup(evt.gname) end
end

-- reference point/name for the low-precision initial report: the scenario
-- region if defined, otherwise the nearest hospital pad
local function vagueReference(def, point)
  local region = def.region and CIV.Zones.byName(def.region)
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

function R.startEvent(key)
  local sc = R._scenarios[key]
  if not sc then return nil end
  local def = sc.def
  local n = 0
  for _ in pairs(sc.events) do n = n + 1 end
  if n >= def.maxActive then return nil end

  local pt = CIV.Pool.pick(def.poolPrefix, 1000)
  if not pt then
    CIV.dbg("Rescue " .. key .. ": no free point in pool " .. def.poolPrefix)
    return nil
  end

  sc._eid = sc._eid + 1
  local evt = {
    id = sc._eid, pt = pt, point = pt.point,
    spawnTime = timer.getTime(),
    deadline = def.deadline and (timer.getTime() + def.deadline) or nil,
  }
  if def.kind == "boat" then
    evt.gname = CIV.spawnBoat(pt.point, "CIVIL_" .. def.key)
  else
    evt.gname = CIV.spawnGround(pt.point, 1, C.templates.survivor,
      C.fallbackTypes.survivor, "CIVIL_" .. def.key)
  end
  startBeacon(def, evt)
  sc.events[evt.id] = evt
  CIV.Pool.occupy(pt)

  -- Approximate search circle (CSAR opponent-intel style): the subject is
  -- inside the circle but NOT at its center, and the radius is random.
  local intel = C.rescue.intel
  local circleRadius = CIV.randBetween(intel.approxRadius)
  local circleCenter = CIV.offsetPoint(evt.point, math.random(0, 359),
    circleRadius * CIV.randBetween(intel.centerOffset))
  evt.circleId = CIV.markCircle(circleCenter,
    def.label .. " #" .. evt.id .. " search area", circleRadius)
  evt.identified = false

  local refPoint, refName = vagueReference(def, evt.point)
  evt.vagueText = refPoint
    and CIV.vagueDirection(refPoint, refName, evt.point)
    or "position unknown"

  local msg = def.label .. ": subject awaiting recovery, " .. evt.vagueText ..
    ".\nApproximate search area marked on the F10 map. Exact position " ..
    "requires a spotter aircraft overhead (or request smoke when close)."
  if evt.beaconName then
    msg = msg .. string.format("\nBeacon active on %.3f MHz", def.beacon.freqHz / 1e6)
  end
  if evt.deadline then
    msg = msg .. string.format("\nCriticality: %d minutes", math.floor(def.deadline / 60))
  end
  CIV.msgAll(msg, 25)

  local hp = def.hoverCfg
  evt.watch = CIV.Hover.watch({
    center = evt.point, label = def.label .. " - extraction",
    radius = hp.radius, minAGL = hp.minAGL, maxAGL = hp.maxAGL,
    maxSpeed = hp.maxSpeed, T = hp.T, window = hp.window, B = hp.B,
    onSuccess = function(unit, session)
      -- despawn = loaded aboard; delivery just consumes the state flag
      CIV.despawnGroup(evt.gname)
      evt.gname = nil
      stopBeacon(evt)
      table.insert(R.aboardList(unit:getName()), {
        scoreType = def.scoreType, label = def.label, evt = evt,
        quality = def.qualityFn and def.qualityFn(evt, session)
                  or CIV.Score.hoverQuality(session),
        timeFactor = CIV.Score.hoverTimeFactor(session),
      })
      sc.events[evt.id] = nil
      CIV.Pool.release(evt.pt)
      CIV.unmark(evt.markId)
      CIV.unmark(evt.circleId)
      CIV.msgUnit(unit, def.label .. ": subject ABOARD. Deliver to a " ..
        "hospital pad (" .. C.zones.hospitals .. " zones): hold low and " ..
        "still for " .. C.rescue.delivery.holdSeconds .. " seconds.", 20)
    end,
    onFail = function()
      CIV.msgAll(def.label .. ": recovery FAILED at " .. pt.name ..
        " (window expired). The subject did not make it.", 20)
      closeEvent(sc, evt)
    end,
  })
  CIV.log("Rescue " .. key .. " event #" .. evt.id .. " at " .. pt.name)
  return evt
end

----------------------------------------------------------------------
-- HOSPITAL DELIVERY (zone-based: still & low inside a hospital zone)
----------------------------------------------------------------------

local deliveryTimer = {}   -- unitName -> time the valid dwell started

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
        if inHospital and stillAndLow then
          deliveryTimer[uname] = deliveryTimer[uname] or now
          if now - deliveryTimer[uname] >= cd.holdSeconds then
            deliveryTimer[uname] = nil
            local info = CIV.players[uname]
            for _, subj in ipairs(list) do
              if subj.evt.deadline and now > subj.evt.deadline then
                CIV.msgUnit(u, subj.label .. ": the subject died before delivery.", 15)
              elseif info then
                CIV.Score.award(info.playerName, subj.scoreType,
                  subj.quality, subj.timeFactor, 1, subj.label)
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
-- SURVIVOR SMOKE (CSAR-style visual mark on request)
----------------------------------------------------------------------

local function popSmoke(uname)
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
  local sp = CIV.offsetPoint(best.point, math.random(0, 359), C.rescue.smokeOffsetM)
  trigger.action.smoke(sp, trigger.smokeColor.Orange)
  CIV.msgUnit(u, "Subject is marking position with ORANGE smoke. " ..
    "Confirm visual before pickup.", 12)
end

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
    local region = sc.def.region and CIV.Zones.byName(sc.def.region)
    for _, evt in pairs(sc.events) do
      if not evt.identified then
        local spotter = nil
        CIV.forEachPlayer(function(u, info)
          if spotter then return end
          if info.category ~= Unit.Category.AIRPLANE or not u:inAir() then return end
          local p = u:getPoint()
          if (region and CIV.Zones.contains(region, p))
             or CIV.dist2D(p, evt.point) <= detectR then
            spotter = info
          end
        end)
        if spotter then
          evt.identified = true
          evt.markId = CIV.mark(sc.def.label .. " #" .. evt.id, evt.point)
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
-- SCENARIO INSTANCES
----------------------------------------------------------------------

R.newScenario({
  key = "SAR_MOUNTAIN", label = "SAR Mountain", kind = "ground",
  poolPrefix = C.zones.sarMountainPoints, region = C.zones.sarMountainRegion,
  maxActive = C.rescue.sarMountain.maxActive, beacon = C.rescue.sarMountain.beacon,
  scoreType = "sarMountain", hoverCfg = C.hover.sarMountain,
})

R.newScenario({
  key = "SAR_SEA", label = "SAR Sea", kind = "boat",
  -- a floating unit on open water is a standard DCS use case: low risk
  poolPrefix = C.zones.sarSeaPoints, region = C.zones.sarSeaRegion,
  maxActive = C.rescue.sarSea.maxActive, beacon = C.rescue.sarSea.beacon,
  scoreType = "sarSea", hoverCfg = C.hover.sarSea,
})

R.newScenario({
  key = "MEDEVAC", label = "MedEvac", kind = "ground",
  poolPrefix = C.zones.medevacPoints, region = nil,
  maxActive = C.rescue.medevac.maxActive, beacon = nil,
  scoreType = "medevac", hoverCfg = C.hover.medevac,
  deadline = C.rescue.medevac.criticality,
  -- quality = remaining criticality fraction at PICKUP time (delivery past
  -- the deadline still voids the score, see the delivery loop)
  qualityFn = function(evt)
    local left = evt.deadline - timer.getTime()
    return math.max(0, math.min(1, left / C.rescue.medevac.criticality))
  end,
})

----------------------------------------------------------------------
-- F10 MENU + EVENT STARTERS
----------------------------------------------------------------------

CIV.Menu_register(function(gid, uname)
  local sub = missionCommands.addSubMenuForGroup(gid, "Rescue", CIV.rootMenu[gid])
  missionCommands.addCommandForGroup(gid, "Request smoke from subject", sub, popSmoke, uname)
  missionCommands.addCommandForGroup(gid, "Active rescue events", sub, function()
    local n, txt = 0, "Active rescue events:\n"
    for _, sc in pairs(R._scenarios) do
      for _, evt in pairs(sc.events) do
        n = n + 1
        -- exact coordinates only once a spotter has identified the subject
        local pos = evt.identified and CIV.llString(evt.point)
          or (evt.vagueText .. " (not identified: needs a spotter overhead)")
        txt = txt .. string.format("- %s #%d: %s\n", sc.def.label, evt.id, pos)
      end
    end
    CIV.msgGroupId(gid, n > 0 and txt or "No active rescue events.", 20)
  end)
end)

CIV.EventStarters.sarMountain = { label = "SAR Mountain",
  fn = function() return R.startEvent("SAR_MOUNTAIN") end }
CIV.EventStarters.sarSea = { label = "SAR Sea",
  fn = function() return R.startEvent("SAR_SEA") end }
CIV.EventStarters.medevac = { label = "MedEvac",
  fn = function() return R.startEvent("MEDEVAC") end }

CIV.log("CivilRescue loaded")
