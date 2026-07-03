----------------------------------------------------------------------
-- DCS Civil Mission Template — Firefighting
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
-- FIRE ZONE MANAGER
----------------------------------------------------------------------

CIV.Fire = { _fires = {}, _fid = 0 }
local Fire = CIV.Fire

-- effectSmokeBig presets: 1..4 = smoke+fire S/M/L/XL, 5..8 = smoke only
local function presetFor(intensity)
  if intensity >= 1.5 then return 4 elseif intensity >= 1.0 then return 3
  elseif intensity >= 0.5 then return 2 else return 1 end
end

function Fire.count()
  local n = 0
  for _ in pairs(Fire._fires) do n = n + 1 end
  return n
end

function Fire.actives() return Fire._fires end

function Fire.ignite(pt)
  Fire._fid = Fire._fid + 1
  local fire = {
    id = Fire._fid, pt = pt,
    point = { x = pt.point.x, y = pt.point.y, z = pt.point.z },
    intensity = CF.startIntensity,
    growth = CIV.randBetween(CF.growthPerHour) / 3600,  -- fixed for the fire's lifetime
    smokeName = "CIVIL_FIRE_" .. Fire._fid,
    preset = 0, markId = nil,
  }
  fire.preset = presetFor(fire.intensity)
  trigger.action.effectSmokeBig(fire.point, fire.preset, 0.7, fire.smokeName)
  Fire._fires[fire.id] = fire
  CIV.Pool.occupy(pt)
  CIV.msgAll("WILDFIRE reported at " .. pt.name .. "\n" .. CIV.coordText(fire.point), 20)
  CIV.log("Fire #" .. fire.id .. " ignited at " .. pt.name)
  return fire
end

function Fire.igniteRandom()
  if Fire.count() >= CF.maxActive then return nil end
  local pt = CIV.Pool.pick(C.zones.firePoints, 1000)
  if not pt then return nil end
  return Fire.ignite(pt)
end

local function extinguish(fire, byWhom)
  trigger.action.effectSmokeStop(fire.smokeName)
  CIV.unmark(fire.markId)
  CIV.Pool.release(fire.pt)
  Fire._fires[fire.id] = nil
  CIV.msgAll("Fire at " .. fire.pt.name .. " EXTINGUISHED" ..
    (byWhom and (" by " .. byWhom) or "") .. ".", 15)
end

local function refreshEffect(fire)
  local p = presetFor(fire.intensity)
  if p ~= fire.preset then
    fire.preset = p
    trigger.action.effectSmokeStop(fire.smokeName)
    trigger.action.effectSmokeBig(fire.point, p, 0.7, fire.smokeName)
  end
end

-- Apply water/retardant at a point. Returns the fire hit (or nil).
-- Score attribution is the caller's job.
function Fire.applyWater(point, amount, byWhom)
  for _, fire in pairs(Fire._fires) do
    if CIV.dist2D(point, fire.point) <= CF.dropRadius then
      fire.intensity = fire.intensity - amount
      if fire.intensity <= 0 then
        extinguish(fire, byWhom)
      else
        refreshEffect(fire)
      end
      return fire
    end
  end
  return nil
end

-- growth + automatic ignition loop
local nextIgnition = timer.getTime() + CIV.randBetween(CF.autoIgnite)
CIV.schedule(function(_, t)
  for _, fire in pairs(Fire._fires) do
    fire.intensity = math.min(2.0, fire.intensity + fire.growth * 10)
    refreshEffect(fire)
  end
  if timer.getTime() >= nextIgnition then
    Fire.igniteRandom()
    nextIgnition = timer.getTime() + CIV.randBetween(CF.autoIgnite)
  end
  return t + 10
end, nil, 15)

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
  local fire = Fire.applyWater(u:getPoint(), CF.heloDropAmount, info and info.playerName)
  st.water = false
  if fire then
    CIV.msgUnit(u, "Drop on target!", 10)
    if info then
      -- fire still burning: partial credit; extinguished: full credit
      CIV.Score.award(info.playerName, "fireHelo",
        Fire._fires[fire.id] and 0.5 or 1.0, 0.5, 1, "firefighting drop")
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
            Fire.applyWater(fire.point, CF.heloDropAmount, info and info.playerName)
            if info then
              CIV.Score.award(info.playerName, "fireHelo", 1.0, 0.5, 1, "firefighting drop")
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

local c130State = {}   -- unitName -> { retardant, reloadSince, dropRun }

local function cState(uname)
  c130State[uname] = c130State[uname] or { retardant = false }
  return c130State[uname]
end

local function isAirplane(info)
  return info.category == Unit.Category.AIRPLANE
end

-- ground reload: stationary inside the reload zone for N seconds
CIV.schedule(function(_, t)
  local zone = CIV.Zones.byName(C.zones.c130Reload)
  if not zone then return t + 60 end
  local now = timer.getTime()
  CIV.forEachPlayer(function(u, info)
    if not isAirplane(info) then return end
    local st = cState(info.unitName)
    if st.retardant then return end
    local stopped = (not u:inAir()) and CIV.speed(u:getVelocity()) < 1
    if stopped and CIV.Zones.contains(zone, u:getPoint()) then
      if not st.reloadSince then
        st.reloadSince = now
        CIV.msgUnit(u, "Retardant reload in progress: stay put for " ..
          CF.c130ReloadTime .. " seconds.", 10)
      elseif now - st.reloadSince >= CF.c130ReloadTime then
        st.reloadSince = nil
        st.retardant = true
        CIV.msgUnit(u, "Retardant loaded. Drop: F10 -> Civil Missions -> " ..
          "Firefighting C-130 -> Start line drop (altitude " ..
          CF.c130DropAGL.min .. "-" .. CF.c130DropAGL.max .. " m AGL).", 15)
      end
    else
      st.reloadSince = nil
    end
  end)
  return t + 5
end, nil, 10)

local function startLineDrop(uname)
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  local st = cState(uname)
  if not st.retardant then
    CIV.msgUnit(u, "No retardant aboard: reload on the ground in the " ..
      C.zones.c130Reload .. " zone.", 10)
    return
  end
  local region = CIV.Zones.byName(C.zones.fireRegion)
  local p = u:getPoint()
  if region and not CIV.Zones.contains(region, p) then
    CIV.msgUnit(u, "You are outside the fire region.", 10)
    return
  end
  local agl = CIV.agl(p)
  if agl < CF.c130DropAGL.min or agl > CF.c130DropAGL.max then
    CIV.msgUnit(u, string.format("Invalid altitude (%d m AGL): drop band is %d-%d m.",
      math.floor(agl), CF.c130DropAGL.min, CF.c130DropAGL.max), 10)
    return
  end
  st.retardant = false
  st.dropRun = { endTime = timer.getTime() + CF.c130DropSeconds, hits = 0 }
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
        local hits = st.dropRun.hits
        st.dropRun = nil
        if u and u:isExist() then
          local info = CIV.players[uname]
          if hits > 0 and info then
            CIV.msgUnit(u, "Drop complete: effective line.", 10)
            CIV.Score.award(info.playerName, "fireC130",
              math.min(1, hits / CF.c130DropSeconds), 0.5, 1, "C-130 retardant line")
          elseif u then
            CIV.msgUnit(u, "Drop complete: no fire under the line.", 10)
          end
        end
      else
        local p = u:getPoint()
        local agl = CIV.agl(p)
        if agl >= CF.c130DropAGL.min and agl <= CF.c130DropAGL.max then
          local info = CIV.players[uname]
          if Fire.applyWater(p, CF.c130DropPerSec, info and info.playerName) then
            st.dropRun.hits = st.dropRun.hits + 1
          end
        end
      end
    end
  end
  return t + 1
end, nil, 10)

-- spotter: any player airplane inside the fire region relays fire intel
CIV.schedule(function(_, t)
  local region = CIV.Zones.byName(C.zones.fireRegion)
  if not region then return t + 120 end
  local spotter = nil
  CIV.forEachPlayer(function(u, info)
    if spotter then return end
    if isAirplane(info) and u:inAir() and CIV.Zones.contains(region, u:getPoint()) then
      spotter = info
    end
  end)
  if spotter then
    local n, txt = 0, ""
    for _, fire in pairs(Fire.actives()) do
      n = n + 1
      txt = txt .. string.format("- %s: %s (intensity %d%%)\n", fire.pt.name,
        CIV.llString(fire.point), math.floor(fire.intensity * 100))
      if not fire.markId then
        fire.markId = CIV.mark("WILDFIRE " .. fire.pt.name, fire.point)
      end
    end
    if n > 0 then
      CIV.msgAll("SPOTTER " .. spotter.playerName .. " reports " .. n ..
        " active fires:\n" .. txt, 20)
    end
  end
  return t + CF.spotterInterval
end, nil, 30)

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
      txt = txt .. string.format("- %s  intensity %d%%  %s\n", fire.pt.name,
        math.floor(fire.intensity * 100), CIV.llString(fire.point))
    end
    CIV.msgGroupId(gid, n > 0 and txt or "No active fires.", 20)
  end)
  local c130Sub = missionCommands.addSubMenuForGroup(gid, "Firefighting C-130", CIV.rootMenu[gid])
  missionCommands.addCommandForGroup(gid, "Start line drop", c130Sub, startLineDrop, uname)
end)

CIV.EventStarters.fire = { label = "Wildfire", fn = Fire.igniteRandom }

CIV.log("CivilFirefighting loaded")
