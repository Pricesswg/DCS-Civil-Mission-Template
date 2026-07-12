----------------------------------------------------------------------
-- DCS Civil Mission Template - Firefighting
-- File: 10_CivilFirefighting.lua  (requires 01_CivilCore.lua)
--
-- Fire zone manager + helicopter water ops + C-130 retardant ops.
--
--   FIRES: random ignition among the curated "CIVIL Fire Point" zones,
--   smoke/fire via trigger.action.effectSmokeBig/effectSmokeStop, per-zone
--   active state, growth rate randomized ONCE per fire.
--
--   HELICOPTERS: hover over a "CIVIL Water Point" (safe height, not skimming)
--   -> water loaded -> drop over an active fire. Two modes
--   (CIV.Config.fire.usePhysicalCargo):
--     false (default): logical per-unit load + F10 drop. Robust.
--     true (EXPERIMENTAL): spawns a native mass Cargo object to sling with
--     F8; cargo spawn on open water is UNTESTED in-game (see docs).
--
--   C-130: no in-flight scooping (that is amphibian work). Ground reload in
--   the "CIVIL C130 Reload" zone (logical state, DCS has no native
--   retardant), then a line drop across the fire region at moderate AGL.
--   Any player airplane inside the fire region also acts as SPOTTER,
--   relaying fire coordinates and F10 marks to the coalition.
----------------------------------------------------------------------

assert(CIV and CIV.VERSION, "01_CivilCore.lua must be loaded first")

local C = CIV.Config
local CF = C.fire

----------------------------------------------------------------------
-- FIRE ZONE MANAGER (severity model)
-- Every fire carries a severity from 1 to 10, rolled at ignition and
-- growing on a per-fire randomized cadence. Severity drives the column
-- COUNT (sub-fires light up around the anchor, capped at
-- severity.maxEffects for performance); each column's SIZE grows with its
-- own age (small -> medium -> large -> huge, one step per
-- visuals.escalateEvery seconds unattended), so an ignored fire visibly
-- takes hold and a suppression hit visibly knocks it back.
-- Suppression (helicopter drops, C-130 line/airdrop, fire trucks on
-- scene) subtracts severity; at 0 the fire is out.
----------------------------------------------------------------------

CIV.Fire = { _fires = {}, _fid = 0 }
local Fire = CIV.Fire
local SEV = CF.severity
local dispatchFireTrucks, releaseFireTrucks   -- defined in the brigade section
local coordinationBonus                       -- defined in the C-130 section

-- FIREWATCH state: region zone name -> { time, playerName } of the last
-- patrol pass while the region had no active fire (see the patrol loop)
local regionPatrols = {}

-- effectSmokeBig presets: 1..4 = smoke+fire S/M/L/XL, 5..8 = thick smoke
-- only (used by smokeOnly fire kinds such as a landfill fire).
-- Every column starts SMALL and escalates one step per visuals.escalateEvery
-- seconds it goes unattended (age-based progression: small at ignition,
-- huge after 15 minutes with the defaults). Severity controls the column
-- COUNT, age controls the column SIZE.
local function presetFor(effect, kindDef)
  local age = timer.getTime() - effect.bornAt
  local preset = math.max(1, math.min(4,
    1 + math.floor(age / CF.visuals.escalateEvery)))
  if kindDef and kindDef.smokeOnly then preset = preset + 4 end
  return preset
end

local function effectCountFor(severity)
  return math.max(1, math.min(SEV.maxEffects, math.ceil(severity / 2)))
end

function Fire.count()
  local n = 0
  for _ in pairs(Fire._fires) do n = n + 1 end
  return n
end

function Fire.actives() return Fire._fires end

function Fire.severityLabel(fire)
  return string.format("severity %d/10", math.ceil(fire.severity))
end

-- Bring the smoke/fire effect cluster in line with the current severity:
-- add sub-fires as it grows, stop them as it shrinks, resize on preset
-- change. Each effect keeps a stable random offset inside the fire zone.
local function refreshVisuals(fire)
  local wanted = effectCountFor(fire.severity)
  for i = #fire.effects + 1, wanted do
    local p = fire.point
    if i > 1 then
      p = CIV.offsetPoint(fire.point, math.random(0, 359),
        math.random(30, math.max(40, math.floor(fire.pt.radius * 0.8))))
    end
    -- a NEW column starts small and ages on its own clock, same
    -- progression as the first one
    fire.effects[i] = { point = p, name = fire.smokeName .. "_" .. i,
                        preset = 0, bornAt = timer.getTime() }
  end
  for i = #fire.effects, wanted + 1, -1 do
    trigger.action.effectSmokeStop(fire.effects[i].name)
    fire.effects[i] = nil
  end
  for _, eff in ipairs(fire.effects) do
    local preset = presetFor(eff, fire.kindDef)
    if eff.preset ~= preset then
      if eff.preset ~= 0 then trigger.action.effectSmokeStop(eff.name) end
      eff.preset = preset
      trigger.action.effectSmokeBig(eff.point, preset, 0.7, eff.name)
    end
  end
end

function Fire.ignite(pt, severityOverride)
  Fire._fid = Fire._fid + 1
  -- kind picked by weight: forest (fire), landfill (dark smoke, slow),
  -- industrial (fast growth); tells the players from afar what is burning
  local kindDef = CIV.weightedPick(CF.kinds)
  local fire = {
    id = Fire._fid, pt = pt, kindDef = kindDef,
    point = { x = pt.point.x, y = pt.point.y, z = pt.point.z },
    severity = severityOverride
      and math.max(1, math.min(SEV.max, severityOverride))
      or math.random(SEV.initial.min, SEV.initial.max),
    growEvery = CIV.randBetween(SEV.growEvery) / kindDef.growMult,
    smokeName = "CIVIL_FIRE_" .. Fire._fid,
    effects = {}, markId = nil,
  }
  local region = CIV.Zones.containing(C.zones.fireRegion, fire.point)
  fire.regionName = region and region.name
  -- FIREWATCH early detection: a recent patrol pass over this region means
  -- the fire is called in before it takes hold. GM-commanded severities are
  -- deliberate and stay untouched.
  if not severityOverride and CF.firewatch.enabled and fire.regionName then
    local patrol = regionPatrols[fire.regionName]
    if patrol and timer.getTime() - patrol.time <= CF.firewatch.window then
      fire.severity = math.max(1, fire.severity - CF.firewatch.severityCut)
      fire.earlyBy = patrol.playerName
    end
  end
  fire.nextGrow = timer.getTime() + fire.growEvery
  refreshVisuals(fire)
  Fire._fires[fire.id] = fire
  CIV.Pool.occupy(pt)
  fire.zoneMarkId = CIV.drawEventZone(pt.area,
    string.upper(kindDef.name) .. " " .. pt.name, "fire")
  CIV.msgAll(string.upper(kindDef.name) .. " reported at " .. pt.name ..
    " (" .. Fire.severityLabel(fire) .. ")\n" .. CIV.coordText(fire.point) ..
    "\nFire zone highlighted on the F10 map.", 20)
  CIV.log("Fire #" .. fire.id .. " (" .. kindDef.name .. ") ignited at " ..
    pt.name .. " severity " .. fire.severity)
  if fire.earlyBy then
    CIV.msgAll("FIREWATCH: the patrol flown by " .. fire.earlyBy ..
      " called this fire in early. The response starts ahead of the growth.", 15)
    CIV.Score.award(fire.earlyBy, "firewatch", 0.8, 0.5,
      CIV.severityMult(fire.severity), "firewatch early detection")
  end
  dispatchFireTrucks(fire)
  return fire
end

function Fire.igniteRandom()
  if Fire.count() >= CF.maxActive then return nil end
  local pt = CIV.Pool.pick(C.zones.firePoints, 1000)
  if not pt then return nil end
  return Fire.ignite(pt)
end

-- command center: ignite at an arbitrary commanded position
function Fire.igniteAt(point, severity)
  Fire._fid = Fire._fid + 1
  local pt = {
    name = "GM fire " .. Fire._fid, radius = 150,
    point = { x = point.x, y = CIV.groundY(point), z = point.z },
  }
  return Fire.ignite(pt, severity)
end

local function extinguish(fire, byWhom)
  -- air-attack assist: the fire went out while the smoke mark was hot
  if fire.coordination and timer.getTime() < fire.coordination.untilTime then
    CIV.Score.award(fire.coordination.playerName, "airAttack",
      0.8, 0.5, CIV.severityMult(fire.coordination.severity or 5),
      "air attack coordination")
  end
  for _, eff in ipairs(fire.effects) do
    trigger.action.effectSmokeStop(eff.name)
  end
  fire.effects = {}
  CIV.unmark(fire.markId)
  CIV.unmark(fire.zoneMarkId)
  CIV.Pool.release(fire.pt)
  Fire._fires[fire.id] = nil
  releaseFireTrucks(fire)
  CIV.msgAll("Fire at " .. fire.pt.name .. " EXTINGUISHED" ..
    (byWhom and (" by " .. byWhom) or "") .. ".", 15)
end

-- command center: call a fire off without scoring
function Fire.callOff(fire)
  extinguish(fire, "the command center (called off)")
end

-- Apply suppression at a point (amount in severity units). Returns the
-- fire hit (or nil). Score attribution is the caller's job.
function Fire.applyWater(point, amount, byWhom)
  for _, fire in pairs(Fire._fires) do
    if CIV.dist2D(point, fire.point) <= CF.dropRadius then
      fire.severity = fire.severity - amount
      if fire.severity <= 0 then
        extinguish(fire, byWhom)
      else
        -- the hit knocks every column back one size step: the drop reads
        -- on the fire immediately (aging the columns forward again takes
        -- another escalateEvery unattended)
        if CF.visuals.knockbackOnHit then
          local now = timer.getTime()
          for _, eff in ipairs(fire.effects) do
            eff.bornAt = math.min(now, eff.bornAt + CF.visuals.escalateEvery)
          end
        end
        refreshVisuals(fire)
      end
      return fire
    end
  end
  return nil
end

-- growth + automatic ignition loop
local nextIgnition = timer.getTime() + CIV.randBetween(CF.autoIgnite)
CIV.schedule(function(_, t)
  local now = timer.getTime()
  for _, fire in pairs(Fire._fires) do
    if now >= fire.nextGrow and fire.severity < SEV.max then
      fire.severity = math.min(SEV.max, fire.severity + 1)
      fire.nextGrow = now + fire.growEvery
      if fire.severity >= SEV.max then
        CIV.msgAll("Fire at " .. fire.pt.name ..
          " is RAGING (severity 10/10): all assets required.", 15)
      end
    end
    -- age-based column escalation ticks here even without severity
    -- changes; cheap, effects only restart when a preset step is crossed
    refreshVisuals(fire)
  end
  if now >= nextIgnition then
    Fire.igniteRandom()
    nextIgnition = now + CIV.randBetween(CF.autoIgnite)
  end
  return t + 10
end, nil, 15)

----------------------------------------------------------------------
-- FIRE BRIGADE (scenic ground response)
-- Trucks depart from the nearest "CIVIL Fire Station" zone and drive to
-- the fire "On Road" (same stall watchdog as the police chase). On scene
-- they apply continuous suppression, cutting the air passes needed.
----------------------------------------------------------------------

local function truckRoute(brigade, fromPoint, firePoint)
  -- the fire may have been extinguished or called off between the dispatch
  -- and this delayed call: the brigade is already released then
  if not brigade then return end
  local g = Group.getByName(brigade.gname)
  if not g then return end
  pcall(function()
    g:getController():setTask({ id = "Mission", params = { route = { points = {
      { x = fromPoint.x, y = fromPoint.z, type = "Turning Point",
        action = brigade.roadAction, speed = CF.trucks.speed },
      { x = firePoint.x, y = firePoint.z, type = "Turning Point",
        action = brigade.roadAction, speed = CF.trucks.speed },
    } } } })
  end)
end

dispatchFireTrucks = function(fire)
  if not CF.trucks.enabled then return end
  local best, bestDist = nil, 1e12
  for _, pt in ipairs(CIV.Pool.load(C.zones.fireStations)) do
    local d = CIV.dist2D(pt.point, fire.point)
    if d < bestDist then best, bestDist = pt, d end
  end
  if not best then return end
  local gname = CIV.spawnGround(best.point, CF.trucks.count,
    C.templates.fireTruck, C.fallbackTypes.fireTruck, "CIVIL_FIRETRUCK")
  fire.brigade = {
    gname = gname, station = best, arrived = false,
    roadAction = "On Road", lastPos = nil, stalledSince = nil, rekicks = 0,
  }
  CIV.schedule(function() truckRoute(fire.brigade, best.point, fire.point) end, nil, 2)
  CIV.msgAll("Fire brigade rolling out of " .. best.name .. " towards " ..
    fire.pt.name .. ".", 12)
end

releaseFireTrucks = function(fire)
  if not fire.brigade then return end
  local gname = fire.brigade.gname
  fire.brigade = nil
  -- scenic pause on scene, then the trucks are cleared
  CIV.schedule(function() CIV.despawnGroup(gname) end, nil, 120)
end

-- brigade loop: arrival detection, ground suppression, stall watchdog
CIV.schedule(function(_, t)
  local now = timer.getTime()
  for _, fire in pairs(Fire._fires) do
    local b = fire.brigade
    if b then
      local g = Group.getByName(b.gname)
      local u = g and g:getUnit(1)
      if not u or not u:isExist() then
        fire.brigade = nil
      else
        local p = u:getPoint()
        if not b.arrived then
          if CIV.dist2D(p, fire.point) <= CF.trucks.suppressRadius then
            b.arrived = true
            CIV.msgAll("Fire brigade ON SCENE at " .. fire.pt.name ..
              ": ground suppression in progress.", 12)
          else
            -- stall watchdog (known "On Road" bug, same pattern as the chase)
            if b.lastPos and CIV.dist2D(p, b.lastPos) < 5 then
              b.stalledSince = b.stalledSince or now
              if now - b.stalledSince > 60 then
                b.stalledSince = nil
                b.rekicks = b.rekicks + 1
                if b.rekicks >= 2 then b.roadAction = "Off Road" end
                truckRoute(b, p, fire.point)
                CIV.dbg("Fire brigade re-kicked towards " .. fire.pt.name)
              end
            else
              b.stalledSince = nil
            end
            b.lastPos = { x = p.x, y = p.y, z = p.z }
          end
        else
          -- 10 s tick: suppressPerMin / 6 severity per tick
          fire.severity = fire.severity - CF.trucks.suppressPerMin / 6
          if fire.severity <= 0 then
            extinguish(fire, "the fire brigade")
          else
            refreshVisuals(fire)
          end
        end
      end
    end
  end
  return t + 10
end, nil, 20)

----------------------------------------------------------------------
-- HELICOPTER WATER OPS
----------------------------------------------------------------------

local heloState = {}   -- unitName -> { water = bool, cargoName = string|nil }

local function hState(uname)
  heloState[uname] = heloState[uname] or { water = false }
  return heloState[uname]
end

local function nearestWaterPoint(p)
  for _, pt in ipairs(CIV.Pool.load(C.zones.waterPoints)) do
    if CIV.dist2D(p, pt.point) <= math.max(pt.radius, 200) then return pt end
  end
  return nil
end

local function startWaterPickup(uname)
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  local st = hState(uname)
  if st.water then
    CIV.msgUnit(u, "Tank already full: take the water to a fire.", 10)
    return
  end
  local pt = nearestWaterPoint(u:getPoint())
  if not pt then
    CIV.msgUnit(u, "No water pickup point nearby.", 10)
    return
  end
  local hp = C.hover.waterPickup
  CIV.Hover.start({
    unitName = uname, center = pt.point, label = "Water pickup",
    radius = hp.radius, minAGL = hp.minAGL, maxAGL = hp.maxAGL,
    maxSpeed = hp.maxSpeed, T = hp.T, window = hp.window, B = hp.B,
    onSuccess = function(unit)
      if CF.usePhysicalCargo then
        -- EXPERIMENTAL: native mass cargo spawned on the water
        st.cargoName = CIV.spawnCargo(pt.point, CF.waterCargoType, CF.waterCargoKg, "CIVIL_WATER")
        CIV.msgUnit(unit, "Water bag ready (" .. CF.waterCargoKg ..
          " kg). Hook it with the sling load system (F8).", 15)
      else
        st.water = true
        CIV.msgUnit(unit, "Water loaded. Fly to an active fire and use " ..
          "F10 -> Civil Missions -> Firefighting -> Drop water.", 15)
      end
    end,
    onFail = function()
      local u2 = Unit.getByName(uname)
      if u2 then CIV.msgUnit(u2, "Water pickup failed: time expired.", 10) end
    end,
  })
  CIV.msgUnit(u, "Hold your hover over the pickup point (" ..
    hp.minAGL .. "-" .. hp.maxAGL .. " m AGL).", 10)
end

local function dropWater(uname)
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  local st = hState(uname)
  if not st.water then
    CIV.msgUnit(u, "Tank empty: pick up water at a CIVIL Water Point first.", 10)
    return
  end
  local info = CIV.players[uname]
  local fire = Fire.applyWater(u:getPoint(), CF.heloDropSeverity, info and info.playerName)
  st.water = false
  if fire then
    CIV.msgUnit(u, "Drop on target!", 10)
    if info then
      -- fire still burning: partial credit; extinguished: full credit.
      -- Score scales with the severity the fire had when hit, plus the
      -- coordination bonus while an air-attack mark is hot.
      local preHit = fire.severity + CF.heloDropSeverity
      CIV.Score.award(info.playerName, "fireHelo",
        Fire._fires[fire.id] and 0.5 or 1.0, 0.5,
        CIV.severityMult(preHit) * coordinationBonus(fire), "firefighting drop")
    end
  else
    CIV.msgUnit(u, "Drop missed: no fire within " .. CF.dropRadius ..
      " m. Water wasted.", 10)
  end
end

-- physical cargo mode: delivery detected by polling the cargo position
-- (a slung cargo moves with the aircraft). TO TEST in-game.
CIV.schedule(function(_, t)
  if not CF.usePhysicalCargo then return t + 30 end
  for uname, st in pairs(heloState) do
    if st.cargoName then
      local s = StaticObject.getByName(st.cargoName)
      if not s then
        st.cargoName = nil   -- destroyed / dropped badly
      else
        local p = s:getPoint()
        for _, fire in pairs(Fire.actives()) do
          if CIV.dist2D(p, fire.point) <= CF.dropRadius and CIV.agl(p) < 5 then
            CIV.despawnStatic(st.cargoName)
            st.cargoName = nil
            local info = CIV.players[uname]
            local preHit = fire.severity
            Fire.applyWater(fire.point, CF.heloDropSeverity, info and info.playerName)
            if info then
              CIV.Score.award(info.playerName, "fireHelo", 1.0, 0.5,
                CIV.severityMult(preHit), "firefighting drop")
            end
            break
          end
        end
      end
    end
  end
  return t + 2
end, nil, 10)

----------------------------------------------------------------------
-- C-130 RETARDANT OPS + SPOTTER
----------------------------------------------------------------------

local c130State = {}   -- unitName -> { retardant, loading, dropRun }

local function cState(uname)
  c130State[uname] = c130State[uname] or { retardant = false }
  return c130State[uname]
end

local function isAirplane(info)
  return info.category == Unit.Category.AIRPLANE
end

-- light air-attack types direct the traffic and mark fires: they do not
-- haul retardant
local function isAirAttackType(typeName)
  for _, pattern in ipairs(CF.airAttack.types) do
    if string.find(typeName or "", pattern, 1, true) then return true end
  end
  return false
end

-- coordination bonus while an air-attack smoke mark is hot on the fire
-- (forward-declared at the top: the water drop handlers run before this
-- section is reached lexically)
coordinationBonus = function(fire)
  if fire.coordination and timer.getTime() < fire.coordination.untilTime then
    return CF.airAttack.coordination.dropBonus
  end
  return 1.0
end

-- Ground reload, OPT-IN via F10: nothing happens by just parking in the
-- reload zone, so a C-130 that only wants to orbit as spotter/rescue
-- support takes off clean with no interaction. Requesting the load starts
-- a hold timer; moving before it expires aborts the loading.
local function stoppedInReloadZone(u)
  if (not u:inAir()) and CIV.speed(u:getVelocity()) < 1 then
    return CIV.Zones.containing(C.zones.c130Reload, u:getPoint()) ~= nil
  end
  return false
end

local function loadRetardant(uname)
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  local info = CIV.players[uname]
  if info and isAirAttackType(info.typeName) then
    CIV.msgUnit(u, "Your aircraft is an AIR ATTACK platform: it directs " ..
      "the traffic and smoke-marks the fires (F10), the tankers haul the " ..
      "retardant.", 12)
    return
  end
  local st = cState(uname)
  if st.retardant then
    CIV.msgUnit(u, "Retardant already aboard.", 10)
    return
  end
  if st.loading then
    CIV.msgUnit(u, "Loading already in progress: stay put.", 10)
    return
  end
  if not stoppedInReloadZone(u) then
    CIV.msgUnit(u, "You must be LANDED and stationary inside the " ..
      C.zones.c130Reload .. " zone.", 10)
    return
  end
  st.loading = true
  CIV.msgUnit(u, "Loading retardant drums: stay put for " ..
    CF.c130ReloadTime .. " seconds.", 12)
  CIV.schedule(function()
    st.loading = false
    local u2 = Unit.getByName(uname)
    if not u2 or not u2:isExist() then return end
    if not stoppedInReloadZone(u2) then
      CIV.msgUnit(u2, "Loading aborted: you moved before the drums were secured.", 10)
      return
    end
    st.retardant = true
    CIV.msgUnit(u2, "Retardant loaded. Drop: F10 -> Civil Missions -> " ..
      "Firefighting C-130 -> Start line drop (altitude " ..
      CF.c130DropAGL.min .. "-" .. CF.c130DropAGL.max .. " m AGL).", 15)
  end, nil, CF.c130ReloadTime)
end

local function startLineDrop(uname)
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  local st = cState(uname)
  if not st.retardant then
    CIV.msgUnit(u, "No retardant aboard: reload on the ground in the " ..
      C.zones.c130Reload .. " zone.", 10)
    return
  end
  local p = u:getPoint()
  if #CIV.Zones.byPrefix(C.zones.fireRegion) > 0
     and not CIV.Zones.containing(C.zones.fireRegion, p) then
    CIV.msgUnit(u, "You are outside every fire region.", 10)
    return
  end
  local agl = CIV.agl(p)
  if agl < CF.c130DropAGL.min or agl > CF.c130DropAGL.max then
    CIV.msgUnit(u, string.format("Invalid altitude (%d m AGL): drop band is %d-%d m.",
      math.floor(agl), CF.c130DropAGL.min, CF.c130DropAGL.max), 10)
    return
  end
  st.retardant = false
  st.dropRun = { endTime = timer.getTime() + CF.c130DropSeconds, hits = 0, maxSev = 1 }
  CIV.msgUnit(u, "DROP IN PROGRESS: hold heading and altitude for " ..
    CF.c130DropSeconds .. " seconds.", 10)
end

-- line drop tick: applies retardant along the flight path
CIV.schedule(function(_, t)
  local now = timer.getTime()
  for uname, st in pairs(c130State) do
    if st.dropRun then
      local u = Unit.getByName(uname)
      if not u or not u:isExist() or now > st.dropRun.endTime then
        local hits, maxSev = st.dropRun.hits, st.dropRun.maxSev
        local coordBonus = st.dropRun.coordBonus or 1
        st.dropRun = nil
        if u and u:isExist() then
          local info = CIV.players[uname]
          if hits > 0 and info then
            CIV.msgUnit(u, "Drop complete: effective line.", 10)
            CIV.Score.award(info.playerName, "fireC130",
              math.min(1, hits / CF.c130DropSeconds), 0.5,
              CIV.severityMult(maxSev) * coordBonus, "C-130 retardant line")
          elseif u then
            CIV.msgUnit(u, "Drop complete: no fire under the line.", 10)
          end
        end
      else
        local p = u:getPoint()
        local agl = CIV.agl(p)
        if agl >= CF.c130DropAGL.min and agl <= CF.c130DropAGL.max then
          local info = CIV.players[uname]
          local fire = Fire.applyWater(p, CF.c130DropPerSec, info and info.playerName)
          if fire then
            st.dropRun.hits = st.dropRun.hits + 1
            st.dropRun.maxSev = math.max(st.dropRun.maxSev,
              fire.severity + CF.c130DropPerSec)
            st.dropRun.coordBonus = math.max(st.dropRun.coordBonus or 1,
              coordinationBonus(fire))
          end
        end
      end
    end
  end
  return t + 1
end, nil, 10)

----------------------------------------------------------------------
-- RETARDANT AIRDROP (official C-130 module, drum/barrel type crates)
-- Channel 1 (S_EVENT_SHOT weapon tracking) is shared: this file only
-- registers a consumer with CIV.Airdrop. Channel 2 scans for foreign
-- cargo/static objects appearing near active fires. Crate types and the
-- triggering channel are TO VALIDATE against the official module.
----------------------------------------------------------------------

if CF.airdrop.enabled then
  local matchesType = CIV.Airdrop.typeMatcher(CF.airdrop.containerTypes)

  local function retardantOnTarget(impact)
    local playerInfo = CIV.nearestPlayerAirplane(impact, CF.airdrop.creditRadius)
    local fire = Fire.applyWater(impact, CF.airdrop.severityPerContainer,
      playerInfo and playerInfo.playerName)
    if fire and playerInfo then
      local preHit = fire.severity + CF.airdrop.severityPerContainer
      CIV.Score.award(playerInfo.playerName, "fireC130",
        Fire._fires[fire.id] and 0.6 or 1.0, 0.5,
        CIV.severityMult(preHit), "retardant airdrop")
    end
    return fire ~= nil
  end

  CIV.Airdrop.register({
    key = "fire", matchesType = matchesType,
    matchAny = CF.airdrop.matchAnyObject,
    onImpact = function(point) return retardantOnTarget(point) end,
  })

  -- Channel 2: foreign objects near active fires (template spawns are all
  -- named "CIVIL_*" and skipped)
  local processedObjects = {}
  CIV.schedule(function(_, t)
    if not (world.searchObjects and world.VolumeType and Object and Object.Category) then
      return t + 60
    end
    for _, fire in pairs(Fire.actives()) do
      local volume = { id = world.VolumeType.SPHERE,
                       params = { point = fire.point, radius = CF.dropRadius } }
      pcall(world.searchObjects, Object.Category.STATIC, volume, function(obj)
        local ok, name = pcall(function() return obj:getName() end)
        if ok and name and not processedObjects[name]
           and string.sub(tostring(name), 1, 6) ~= "CIVIL_" then
          processedObjects[name] = true
          local okT, typeName = pcall(function() return obj:getTypeName() end)
          if CF.airdrop.matchAnyObject or (okT and typeName and matchesType(typeName)) then
            CIV.dbg("Foreign cargo object near fire: " .. tostring(name))
            local ok2, p = pcall(function() return obj:getPoint() end)
            if ok2 and p then retardantOnTarget(p) end
          end
        end
        return true
      end)
    end
    return t + 5
  end, nil, 10)
end

----------------------------------------------------------------------
-- AIR ATTACK SMOKE MARK
-- The light fixed-wing job: get low near a fire and mark it with red
-- smoke (the smoke-rocket / trail-smoke pass). While the mark is hot,
-- drops on that fire score the coordination bonus and the marker earns
-- the assist when the fire goes out.
----------------------------------------------------------------------

local function airAttackMark(uname)
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  local info = CIV.players[uname]
  if not info or info.category ~= Unit.Category.AIRPLANE
     or not isAirAttackType(info.typeName) then
    CIV.msgUnit(u, "Smoke marking is the air-attack platforms' job " ..
      "(OV-10, MB-339, L-39, C-101, Yak-52...).", 10)
    return
  end
  local p = u:getPoint()
  if CIV.agl(p) > CF.airAttack.maxAGL then
    CIV.msgUnit(u, "Too high to mark: get below " .. CF.airAttack.maxAGL ..
      " m AGL.", 10)
    return
  end
  local best, bestDist = nil, CF.airAttack.markRadius
  for _, fire in pairs(Fire._fires) do
    local d = CIV.dist2D(p, fire.point)
    if d < bestDist then best, bestDist = fire, d end
  end
  if not best then
    CIV.msgUnit(u, "No active fire within " ..
      math.floor(CF.airAttack.markRadius / 1000) .. " km.", 10)
    return
  end
  best.coordination = {
    untilTime = timer.getTime() + CF.airAttack.coordination.seconds,
    playerName = info.playerName,
    severity = best.severity,
  }
  trigger.action.smoke(CIV.offsetPoint(best.point, math.random(0, 359), 60),
    trigger.smokeColor.Red)
  CIV.msgAll("AIR ATTACK " .. info.playerName .. " smoke-marked the " ..
    best.kindDef.name .. " at " .. best.pt.name .. " (RED smoke). " ..
    "Coordinated drops for the next " ..
    math.floor(CF.airAttack.coordination.seconds / 60) .. " minutes score +" ..
    math.floor((CF.airAttack.coordination.dropBonus - 1) * 100) .. "%.", 15)
end

-- spotter: any player airplane inside the fire region relays fire intel
CIV.schedule(function(_, t)
  if #CIV.Zones.byPrefix(C.zones.fireRegion) == 0 then return t + 120 end
  local spotter = nil
  CIV.forEachPlayer(function(u, info)
    if spotter then return end
    if isAirplane(info) and u:inAir()
       and CIV.Zones.containing(C.zones.fireRegion, u:getPoint()) then
      spotter = info
    end
  end)
  if spotter then
    local n, txt = 0, ""
    for _, fire in pairs(Fire.actives()) do
      n = n + 1
      txt = txt .. string.format("- %s: %s (%s)\n", fire.pt.name,
        CIV.llString(fire.point), Fire.severityLabel(fire))
      if not fire.markId then
        fire.markId = CIV.mark(string.upper(fire.kindDef.name) .. " " ..
          fire.pt.name, fire.point)
      end
    end
    if n > 0 then
      CIV.msgAll("SPOTTER " .. spotter.playerName .. " reports " .. n ..
        " active fires:\n" .. txt, 20)
    end
  end
  return t + CF.spotterInterval
end, nil, 30)

-- FIREWATCH patrol tracking: an airplane sweeping a fire region that has
-- no active fire keeps it watched for firewatch.window seconds. Burning
-- regions do not count as patrol (fight the fire, or spot it: both are
-- already rewarded).
if CF.firewatch.enabled then
  CIV.schedule(function(_, t)
    if #CIV.Zones.byPrefix(C.zones.fireRegion) == 0 then return t + 120 end
    CIV.forEachPlayer(function(u, info)
      if not isAirplane(info) or not u:inAir() then return end
      local region = CIV.Zones.containing(C.zones.fireRegion, u:getPoint())
      if not region then return end
      for _, fire in pairs(Fire._fires) do
        if fire.regionName == region.name then return end
      end
      regionPatrols[region.name] = { time = timer.getTime(),
                                     playerName = info.playerName }
    end)
    return t + 30
  end, nil, 25)
end

----------------------------------------------------------------------
-- F10 MENUS + EVENT STARTER
----------------------------------------------------------------------

CIV.Menu_register(function(gid, uname)
  local heloSub = missionCommands.addSubMenuForGroup(gid, "Firefighting", CIV.rootMenu[gid])
  missionCommands.addCommandForGroup(gid, "Start water pickup", heloSub, startWaterPickup, uname)
  missionCommands.addCommandForGroup(gid, "Drop water", heloSub, dropWater, uname)
  missionCommands.addCommandForGroup(gid, "Active fires", heloSub, function()
    local n, txt = 0, "Active fires:\n"
    for _, fire in pairs(Fire.actives()) do
      n = n + 1
      local brigade = fire.brigade
        and (fire.brigade.arrived and "  [brigade on scene]" or "  [brigade en route]")
        or ""
      txt = txt .. string.format("- %s  %s  %s%s\n", fire.pt.name,
        Fire.severityLabel(fire), CIV.llString(fire.point), brigade)
    end
    CIV.msgGroupId(gid, n > 0 and txt or "No active fires.", 20)
  end)
  missionCommands.addCommandForGroup(gid, "Air attack: smoke-mark nearest fire",
    heloSub, airAttackMark, uname)
  local c130Sub = missionCommands.addSubMenuForGroup(gid, "Firefighting C-130", CIV.rootMenu[gid])
  missionCommands.addCommandForGroup(gid, "Load retardant (at reload zone)", c130Sub, loadRetardant, uname)
  missionCommands.addCommandForGroup(gid, "Start line drop", c130Sub, startLineDrop, uname)
  missionCommands.addCommandForGroup(gid, "Retardant status", c130Sub, function()
    local st = cState(uname)
    local txt = st.retardant and "Retardant aboard."
      or (st.loading and "Loading in progress: stay put." or "No retardant aboard.")
    CIV.msgGroupId(gid, txt, 10)
  end)
end)

CIV.EventStarters.fire = { label = "Wildfire", fn = Fire.igniteRandom }

CIV.log("CivilFirefighting loaded")
