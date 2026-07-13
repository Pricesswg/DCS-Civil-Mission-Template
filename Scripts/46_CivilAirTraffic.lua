----------------------------------------------------------------------
-- DCS Civil Mission Template - Ambient air traffic
-- File: 46_CivilAirTraffic.lua  (requires 01_CivilCore.lua; load after
-- the other intervention files, before 50_CivilCommand.lua)
--
--   TRAFFIC: AI civil flights between the map airports, purely scenic
--   (the map feels alive). Flights spawn airborne a few km out of the
--   departure airdrome, cruise, and LAND at the destination, where they
--   are cleared after shutdown. Type and livery come from the optional
--   "CIVIL Airliner" template (Civil Aircraft Mod types work well),
--   fallback Yak-40. Hard cap on simultaneous flights.
--
--   RESTRICTED AREAS: sometimes a flight strays into a "CIVIL Restricted"
--   zone and loiters there. The violation is armed only if a player
--   airplane is airborne to answer it: intercept = fly within the
--   configured radius of the violator for the required seconds, then it
--   is escorted out and the interceptor is paid. If nobody intercepts in
--   time, ATC diverts the flight out by itself, no points for anyone.
----------------------------------------------------------------------

assert(CIV and CIV.VERSION, "01_CivilCore.lua must be loaded first")

local C = CIV.Config
local AT = C.airTraffic
local RS = AT.restricted

CIV.AirTraffic = { _flights = {}, _fid = 0 }
local AIR = CIV.AirTraffic

----------------------------------------------------------------------
-- AIRPORT LIST
----------------------------------------------------------------------

local airbaseCache
local function airports()
  if airbaseCache then return airbaseCache end
  airbaseCache = {}
  local ok, list = pcall(world.getAirbases)
  if not ok or type(list) ~= "table" then return airbaseCache end
  local exclude = {}
  for _, n in ipairs(AT.excludeAirports) do exclude[n] = true end
  local only = nil
  if #AT.airports > 0 then
    only = {}
    for _, n in ipairs(AT.airports) do only[n] = true end
  end
  local airdromeCat = (Airbase and Airbase.Category and Airbase.Category.AIRDROME) or 0
  for _, ab in ipairs(list) do
    local okAll, entry = pcall(function()
      return { name = ab:getName(), id = ab:getID(), point = ab:getPoint(),
               cat = ab:getDesc().category }
    end)
    if okAll and entry and entry.cat == airdromeCat
       and not exclude[entry.name] and (not only or only[entry.name]) then
      airbaseCache[#airbaseCache + 1] = entry
    end
  end
  CIV.log("Air traffic: " .. #airbaseCache .. " airdromes available")
  return airbaseCache
end

----------------------------------------------------------------------
-- FLIGHT SPAWN
----------------------------------------------------------------------

function AIR.count()
  local n = 0
  for _ in pairs(AIR._flights) do n = n + 1 end
  return n
end

-- type/livery from the CIVIL Airliner template pool (one picked at
-- random), fallback stock type otherwise
local function trafficType()
  local tpls = CIV.Templates.byPrefix(C.templates.airliner)
  if #tpls > 0 then
    local tpl = tpls[math.random(#tpls)]
    local unit = tpl.data.units and tpl.data.units[1]
    if unit and unit.type then return unit.type, unit.livery_id end
  end
  return C.fallbackTypes.airliner, nil
end

local function interceptorAirborne()
  local found = false
  CIV.forEachPlayer(function(u, info)
    if not found and info.category == Unit.Category.AIRPLANE and u:inAir() then
      found = true
    end
  end)
  return found
end

function AIR.spawn()
  if not AT.enabled then return nil end
  if AIR.count() >= AT.maxActive then return nil end
  local list = airports()
  if #list < 2 then return nil end

  local from, to
  for _ = 1, 15 do
    from = list[math.random(#list)]
    local cand = list[math.random(#list)]
    if cand.name ~= from.name
       and CIV.dist2D(from.point, cand.point) >= AT.minLegKm * 1000 then
      to = cand
      break
    end
  end
  if not to then return nil end

  -- sometimes the flight strays through a restricted zone; armed only if
  -- a player airplane is airborne to answer it (no interceptors, no task)
  local viaZone = nil
  if RS.enabled and math.random(100) <= RS.violationChance then
    local zones = CIV.Zones.byPrefix(C.zones.restricted)
    if #zones > 0 and (not RS.requirePlayers or interceptorAirborne()) then
      viaZone = zones[math.random(#zones)]
    end
  end

  AIR._fid = AIR._fid + 1
  local alt = CIV.randBetween(AT.altitude)
  local speed = CIV.randBetween(AT.speed)
  local typeName, livery = trafficType()
  local gname = CIV.uniqueName("CIVIL_TRAFFIC")
  local brg = CIV.bearingDeg(from.point,
    viaZone and { x = viaZone.center.x, z = viaZone.center.z } or to.point)
  local sp = CIV.offsetPoint(from.point, brg, 5000)
  local spAlt = CIV.groundY(sp) + math.max(600, alt * 0.4)

  local points = {
    { x = sp.x, y = sp.z, alt = spAlt, alt_type = "BARO",
      type = "Turning Point", action = "Turning Point", speed = speed },
  }
  if viaZone then
    points[#points + 1] = { x = viaZone.center.x, y = viaZone.center.z,
      alt = alt, alt_type = "BARO", type = "Turning Point",
      action = "Turning Point", speed = speed }
  end
  points[#points + 1] = { x = to.point.x, y = to.point.z, alt = alt,
    alt_type = "BARO", type = "Land", action = "Landing", speed = speed,
    airdromeId = to.id }

  local ok = pcall(coalition.addGroup, C.countryId, Group.Category.AIRPLANE, {
    visible = false, lateActivation = false, task = "Nothing",
    name = gname, groupId = CIV.newGroupId(), communication = false,
    units = { {
      type = typeName, name = gname .. "_1", unitId = CIV.newUnitId(),
      x = sp.x, y = sp.z, alt = spAlt, alt_type = "BARO", speed = speed,
      heading = math.rad(brg), skill = "Excellent", livery_id = livery,
      payload = { pylons = {}, fuel = 3000, flare = 0, chaff = 0, gun = 0 },
    } },
    route = { points = points },
  })
  if not ok then
    CIV.log("Air traffic: spawn failed for type " .. tostring(typeName))
    return nil
  end

  local flight = {
    id = AIR._fid, gname = gname, from = from, to = to,
    viaZone = viaZone, violationActive = false, resolved = false,
    interceptTime = {}, spawnedAt = timer.getTime(),
  }
  AIR._flights[flight.id] = flight
  CIV.log("Air traffic: flight #" .. flight.id .. " " .. from.name ..
    " -> " .. to.name .. (viaZone and " (VIOLATOR)" or ""))
  return flight
end

local function flightUnit(flight)
  local g = Group.getByName(flight.gname)
  local u = g and g:getUnit(1)
  if u and u:isExist() then return u end
  return nil
end

local function removeFlight(flight, despawnAfter)
  AIR._flights[flight.id] = nil
  CIV.unmark(flight.zoneMarkId)
  local gname = flight.gname
  CIV.schedule(function() CIV.despawnGroup(gname) end, nil, despawnAfter or 1)
end

-- resume the flight plan to the destination (after intercept or divert)
local function resumeToDestination(flight, fromP, speed)
  local g = Group.getByName(flight.gname)
  if not g then return end
  pcall(function()
    g:getController():setTask({ id = "Mission", params = { route = { points = {
      { x = fromP.x, y = fromP.z, alt = fromP.y, alt_type = "BARO",
        type = "Turning Point", action = "Turning Point", speed = speed },
      { x = flight.to.point.x, y = flight.to.point.z, alt = fromP.y,
        alt_type = "BARO", type = "Land", action = "Landing", speed = speed,
        airdromeId = flight.to.id },
    } } } })
  end)
end

-- violators loiter: keep steering them back onto the zone center until
-- the violation is resolved (intercept or self-divert)
local function loiterInZone(flight, fromP, speed)
  local g = Group.getByName(flight.gname)
  if not g then return end
  pcall(function()
    g:getController():setTask({ id = "Mission", params = { route = { points = {
      { x = fromP.x, y = fromP.z, alt = fromP.y, alt_type = "BARO",
        type = "Turning Point", action = "Turning Point", speed = speed },
      { x = flight.viaZone.center.x, y = flight.viaZone.center.z,
        alt = fromP.y, alt_type = "BARO", type = "Turning Point",
        action = "Turning Point", speed = speed },
    } } } })
  end)
end

----------------------------------------------------------------------
-- TRAFFIC + VIOLATION LOOP
----------------------------------------------------------------------

local nextAirSpawn = timer.getTime() + CIV.randBetween(AT.spawnEvery)
CIV.schedule(function(_, t)
  local now = timer.getTime()
  for _, flight in pairs(AIR._flights) do
    local u = flightUnit(flight)
    if not u then
      removeFlight(flight, 1)
    elseif now - flight.spawnedAt > AT.maxLifetime then
      removeFlight(flight, 1)      -- hard cleanup for stragglers
    else
      local p = u:getPoint()

      -- arrival: landed near the destination -> cleared after shutdown
      if not u:inAir() and CIV.speed(u:getVelocity()) < 2
         and CIV.dist2D(p, flight.to.point) < 8000 then
        removeFlight(flight, 120)

      -- violation lifecycle
      elseif flight.viaZone and not flight.resolved then
        if not flight.violationActive then
          if CIV.Zones.contains(flight.viaZone, p) then
            flight.violationActive = true
            flight.violatedAt = now
            flight.nextLoiterKick = 0
            flight.zoneMarkId = CIV.drawEventZone(flight.viaZone,
              "RESTRICTED - unauthorized traffic", "restricted")
            CIV.msgAll("AIRSPACE ALERT: unidentified civil traffic entered " ..
              "the restricted area " .. flight.viaZone.name ..
              " and is loitering.\nMilitary flights: intercept and identify " ..
              "(fly within " .. RS.intercept.radius .. " m of it for " ..
              RS.intercept.seconds .. " seconds).", 25)
          end
        else
          -- keep the violator loitering inside the zone
          if now >= (flight.nextLoiterKick or 0) then
            flight.nextLoiterKick = now + 60
            loiterInZone(flight, p, CIV.randBetween(AT.speed) * 0.8)
          end
          -- intercept check
          local caught = nil
          CIV.forEachPlayer(function(a, info)
            if caught or info.category ~= Unit.Category.AIRPLANE then return end
            if not a:inAir() then return end
            if CIV.dist2D(a:getPoint(), p) <= RS.intercept.radius then
              flight.interceptTime[info.unitName] =
                (flight.interceptTime[info.unitName] or 0) + 10
              if flight.interceptTime[info.unitName] >= RS.intercept.seconds then
                caught = info
              end
            end
          end)
          if caught then
            flight.resolved = true
            CIV.unmark(flight.zoneMarkId)
            flight.zoneMarkId = nil
            CIV.Score.award(caught.playerName, "intercept", 0.9, 0.5, 1,
              "restricted-area intercept")
            CIV.msgAll("INTERCEPT: " .. caught.playerName ..
              " identified the violator and is escorting it out of " ..
              flight.viaZone.name .. ". Traffic resuming its flight plan.", 15)
            resumeToDestination(flight, p, CIV.randBetween(AT.speed))
          elseif now - flight.violatedAt > RS.divertAfter then
            flight.resolved = true
            CIV.unmark(flight.zoneMarkId)
            flight.zoneMarkId = nil
            CIV.msgAll("AIRSPACE ALERT: ATC diverted the unauthorized " ..
              "traffic out of " .. flight.viaZone.name ..
              " (no interceptor on it). Alert over.", 15)
            resumeToDestination(flight, p, CIV.randBetween(AT.speed))
          end
        end
      end
    end
  end
  if AT.enabled and now >= nextAirSpawn then
    AIR.spawn()
    nextAirSpawn = now + CIV.randBetween(AT.spawnEvery)
  end
  return t + 10
end, nil, 30)

CIV.EventStarters.traffic = { label = "Civil traffic flight",
  fn = function() return AIR.spawn() end }

CIV.log("CivilAirTraffic loaded")
