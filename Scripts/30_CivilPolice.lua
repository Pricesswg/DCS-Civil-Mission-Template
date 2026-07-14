----------------------------------------------------------------------
-- DCS Civil Mission Template - Police (Chase + SWAT)
-- File: 30_CivilPolice.lua  (requires 01_CivilCore.lua)
--
--   CHASE: fugitive car spawned on a "CIVIL Police Point" (pool placed on
--   real city crossroads). Route = local random walk between nearby points
--   with "On Road" waypoints for native road pathfinding.
--   KNOWN ISSUE (verified): "On Road" is buggy across versions (units can
--   stray or get stuck). A watchdog re-tasks a stalled car and falls back
--   to "Off Road" on the second stall.
--   Capture: per-chase "pressure" that rises while a player helicopter is
--   within radius and decays when contact is lost; rates randomized ONCE
--   per chase. 100% = arrest.
--
--   SWAT: board the team at "CIVIL SWAT Base" (squad size fixed at
--   BOARDING, not at insertion), then fast-rope insertion over a
--   "CIVIL SWAT Point" via hover watch + scripted coalition.addGroup
--   (native embark/disembark tasks are AI-to-AI: unusable here).
--   TO TEST in-game: infantry spawn reliability on rooftop meshes.
----------------------------------------------------------------------

assert(CIV and CIV.VERSION, "01_CivilCore.lua must be loaded first")

local C = CIV.Config
local CP = C.police
local CS = C.swat

----------------------------------------------------------------------
-- CHASE
----------------------------------------------------------------------

CIV.Police = { _chases = {}, _cid = 0 }
local PL = CIV.Police

-- Optional scene dressing (robbery scene at the chase start, standoff at
-- the SWAT objective): same template mechanics as the rescue scenes, same
-- lingering despawn delay after the event ends.
local function spawnPoliceScene(templates, point)
  if not templates or #templates == 0 then return nil end
  local prefix = templates[math.random(#templates)]
  local sp = CIV.offsetPoint(point, math.random(0, 359), 20)
  local gname = CIV.spawnFromTemplate(prefix, sp)
  if not gname then CIV.dbg("No scene template for prefix '" .. prefix .. "'") end
  return gname
end

local function releaseSceneLater(gname)
  if not gname then return end
  CIV.schedule(function() CIV.despawnGroup(gname) end,
    nil, C.rescue.scenes.despawnDelay)
end

local function waypoint(pt, speed, action)
  return { x = pt.point.x, y = pt.point.z, type = "Turning Point",
           action = action or "On Road", speed = speed,
           ETA = 0, ETA_locked = false, speed_locked = true }
end

-- next hops via local random walk (never map-wide jumps)
local function makeHops(fromPt, n, excludeName)
  local hops, current, lastName = {}, fromPt, excludeName
  for _ = 1, n do
    local nearby = CIV.Pool.near(C.zones.policePoints, current.point,
      CP.neighborRadius, lastName)
    if #nearby == 0 then break end
    local nxt = nearby[math.random(#nearby)]
    hops[#hops + 1] = nxt
    lastName = current.name
    current = nxt
  end
  return hops
end

local function assignRoute(chase)
  local g = Group.getByName(chase.gname)
  local u = g and g:getUnit(1)
  if not u then return end
  local p = u:getPoint()
  local points = { { x = p.x, y = p.z, type = "Turning Point",
                     action = chase.roadAction, speed = chase.speed } }
  for _, pt in ipairs(chase.hops) do
    points[#points + 1] = waypoint(pt, chase.speed, chase.roadAction)
  end
  g:getController():setTask({ id = "Mission", params = { route = { points = points } } })
end

-- opts (command center): { point = vec3, severity = 1..10 }. A commanded
-- point snaps to the nearest free crossroad of the pool (the chase needs
-- the road network).
function PL.startChase(opts)
  local n = 0
  for _ in pairs(PL._chases) do n = n + 1 end
  if not (opts and opts.point) and n >= CP.maxChases then return nil end

  local start
  if opts and opts.point then
    local bestDist = 1e12
    for _, pt in ipairs(CIV.Pool.load(C.zones.policePoints)) do
      local d = CIV.dist2D(pt.point, opts.point)
      if d < bestDist and not CIV.Pool._active[pt.name] then
        start, bestDist = pt, d
      end
    end
  else
    start = CIV.Pool.pick(C.zones.policePoints, 800)
  end
  if not start then return nil end

  PL._cid = PL._cid + 1
  -- one severity roll shapes the chase: car speed, pressure rates, convoy
  -- size and score (severity 10 = fast car, slow pressure build, 2 vehicles)
  local sev = (opts and opts.severity)
    and math.max(1, math.min(10, opts.severity))
    or CIV.rollSeverity(CP.severity)
  local cars = sev >= CP.convoySeverity and 2 or 1
  local gname = CIV.spawnGround(start.point, cars, C.templates.fugitive,
    C.fallbackTypes.fugitive, "CIVIL_FUGITIVE")

  local chase = {
    id = PL._cid, gname = gname, startPt = start,
    severity     = sev,
    speed        = CIV.sevLerp(sev, CP.carSpeed.min, CP.carSpeed.max),
    rateUp       = CIV.sevLerp(sev, CP.pressureUp.max, CP.pressureUp.min),
    rateDown     = CIV.sevLerp(sev, CP.pressureDown.min, CP.pressureDown.max),
    pressure     = 0,            -- 0..100, per-chase state
    roadAction   = "On Road",
    stalledSince = nil, rekicks = 0,
    hops = makeHops(start, CP.routeHops, nil),
    lastPos = nil,
  }
  PL._chases[chase.id] = chase
  CIV.Pool.occupy(start)
  chase.sceneGname = spawnPoliceScene(CP.sceneTemplates, start.point)
  chase.zoneMarkId = CIV.drawEventZone(start.area,
    "Police chase #" .. chase.id .. " last report", "chase")
  CIV.schedule(function() assignRoute(chase) end, nil, 2)

  CIV.msgAll("POLICE: fleeing " .. (cars > 1 and "CONVOY" or "vehicle") ..
    " reported near " .. start.name .. " (severity " .. sev .. "/10)" ..
    "\n" .. CIV.coordText(start.point) ..
    "\nLast reported area highlighted on the F10 map." ..
    "\nKeep helicopter contact on the vehicle to build up pressure.", 25)
  CIV.log("Chase #" .. chase.id .. " started at " .. start.name ..
    " severity " .. sev)
  return chase
end

local function closeChase(chase, despawnAfter)
  CIV.Pool.release(chase.startPt)
  CIV.unmark(chase.zoneMarkId)
  releaseSceneLater(chase.sceneGname)
  chase.sceneGname = nil
  PL._chases[chase.id] = nil
  local gname = chase.gname
  CIV.schedule(function() CIV.despawnGroup(gname) end, nil, despawnAfter or 60)
end

-- command center: close a chase without any outcome
function PL.cancel(chase)
  closeChase(chase, 1)
end

-- chase loop: pressure + route extension + "On Road" watchdog
CIV.schedule(function(_, t)
  local now = timer.getTime()
  for _, chase in pairs(PL._chases) do
    local g = Group.getByName(chase.gname)
    local u = g and g:getUnit(1)
    if not u or not u:isExist() then
      closeChase(chase, 1)
    else
      local p = u:getPoint()

      local contact = false
      CIV.forEachPlayerHelo(function(h)
        if not contact and CIV.dist2D(h:getPoint(), p) <= CP.pressureRadius then
          contact = true
        end
      end)

      -- TRAFFIC WATCH: an airplane orbiting over the fugitive keeps the
      -- pursuit on camera; while the watch holds, helicopter pressure
      -- builds faster and the watcher earns an assist on the arrest
      local TW = CP.trafficWatch
      local watcher = nil
      if TW.enabled then
        CIV.forEachPlayer(function(a, info)
          if watcher or info.category ~= Unit.Category.AIRPLANE then return end
          if not a:inAir() then return end
          local ap = a:getPoint()
          if CIV.dist2D(ap, p) <= TW.radius and CIV.agl(ap) <= TW.maxAGL then
            watcher = info
          end
        end)
      end
      if watcher then
        chase.watcherName = watcher.playerName
        if not chase.watchAnnounced then
          chase.watchAnnounced = true
          CIV.msgAll("TRAFFIC WATCH: " .. watcher.playerName ..
            " is tracking the fugitive from above. Pressure builds " ..
            "faster while the watch holds.", 12)
        end
      end

      if contact then
        chase.pressure = math.min(100,
          chase.pressure + chase.rateUp * (watcher and TW.rateBonus or 1) * 2)   -- 2 s tick
      else
        chase.pressure = math.max(0, chase.pressure - chase.rateDown * 2)
      end

      if chase.pressure >= 100 then
        pcall(function() g:getController():setTask({ id = "Hold", params = {} }) end)
        CIV.msgAll("POLICE: fugitive STOPPED and under arrest at " .. CIV.llString(p), 20)
        local closest = nil
        CIV.forEachPlayerHelo(function(h, info)
          if CIV.dist2D(h:getPoint(), p) <= CP.pressureRadius then closest = info end
        end)
        if closest then
          CIV.Score.award(closest.playerName, "chase", 0.8, 0.5,
            CIV.severityMult(chase.severity), "fugitive arrest")
        end
        if chase.watcherName then
          CIV.Score.award(chase.watcherName, "trafficWatch", 0.8, 0.5,
            CIV.severityMult(chase.severity), "traffic watch assist")
        end
        closeChase(chase, 90)
      else
        -- extend the route when the car nears its last hop
        local last = chase.hops[#chase.hops]
        if last and CIV.dist2D(p, last.point) < 200 then
          local prev = chase.hops[#chase.hops - 1]
          chase.hops = makeHops(last, CP.routeHops, prev and prev.name or nil)
          assignRoute(chase)
        end

        -- watchdog: car stalled too long (known "On Road" bug)
        if chase.lastPos and CIV.dist2D(p, chase.lastPos) < 5 then
          chase.stalledSince = chase.stalledSince or now
          if now - chase.stalledSince > 45 then
            chase.stalledSince = nil
            chase.rekicks = chase.rekicks + 1
            if chase.rekicks >= 2 then
              chase.roadAction = "Off Road"   -- definitive fallback for this event
              CIV.dbg("Chase #" .. chase.id .. ": falling back to Off Road")
            end
            chase.hops = makeHops({ point = p, name = "current" }, CP.routeHops, nil)
            assignRoute(chase)
            CIV.dbg("Chase #" .. chase.id .. ": route re-kicked (watchdog)")
          end
        else
          chase.stalledSince = nil
        end
        chase.lastPos = { x = p.x, y = p.y, z = p.z }
      end
    end
  end
  return t + 2
end, nil, 10)

----------------------------------------------------------------------
-- SWAT
----------------------------------------------------------------------

CIV.SWAT = { _scenarios = {}, _sid = 0 }
local SW = CIV.SWAT
local swatState = {}   -- unitName -> { squad = n }

local function sState(uname)
  swatState[uname] = swatState[uname] or { squad = 0 }
  return swatState[uname]
end

-- operators required by a scenario, from its severity roll
local function requiredOperators(scen)
  return math.floor(CIV.sevLerp(scen.severity, CS.squadSize.min, CS.squadSize.max) + 0.5)
end

-- boarding sizes the team for the WORST active scenario (the squad size
-- stays fixed at boarding, per the design rule; the severity roll just
-- tells the base how many operators the callout needs)
local function boardingSize()
  local worst = nil
  for _, scen in pairs(SW._scenarios) do
    if not worst or scen.severity > worst.severity then worst = scen end
  end
  if worst then return requiredOperators(worst) end
  return math.random(CS.squadSize.min, CS.squadSize.max)
end

local function boardTeam(uname)
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  local st = sState(uname)
  if st.squad > 0 then
    CIV.msgUnit(u, "Team already aboard (" .. st.squad .. " operators).", 10)
    return
  end
  if #CIV.Zones.byPrefix(C.zones.swatBase) == 0 then
    CIV.msgUnit(u, "No '" .. C.zones.swatBase .. "' zone is defined in the mission.", 10)
    return
  end
  if u:inAir() or not CIV.Zones.containing(C.zones.swatBase, u:getPoint())
     or CIV.speed(u:getVelocity()) > 1 then
    CIV.msgUnit(u, "You must be LANDED and stationary inside a SWAT base.", 10)
    return
  end
  CIV.msgUnit(u, "Boarding team: stay put for " .. CS.boardingTime .. " seconds.", 10)
  CIV.schedule(function()
    local u2 = Unit.getByName(uname)
    if not u2 or not u2:isExist() then return end
    if u2:inAir() or not CIV.Zones.containing(C.zones.swatBase, u2:getPoint())
       or CIV.speed(u2:getVelocity()) > 1 then
      CIV.msgUnit(u2, "Boarding aborted: you moved.", 10)
      return
    end
    -- squad size fixed HERE, at boarding (design rule)
    st.squad = boardingSize()
    CIV.msgUnit(u2, "SWAT team aboard: " .. st.squad ..
      " operators. Insert them on the active objective via fast-rope.", 15)
    local info = CIV.players[uname]
    if info then
      CIV.msgAll("SWAT: " .. info.playerName .. " boarded a team of " ..
        st.squad .. " operators.", 10)
    end
  end, nil, CS.boardingTime)
end

-- opts (command center): { point = vec3, severity = 1..10 }
function SW.startScenario(opts)
  local pt
  if opts and opts.point then
    SW._gmid = (SW._gmid or 0) + 1
    pt = {
      name = "GM SWAT " .. SW._gmid, radius = 60,
      point = { x = opts.point.x, y = CIV.groundY(opts.point), z = opts.point.z },
    }
  else
    pt = CIV.Pool.pick(C.zones.swatPoints, 500)
  end
  if not pt then return nil end
  SW._sid = SW._sid + 1
  -- one severity roll shapes the scenario: operators required, resolve time, score
  local scen = { id = SW._sid, pt = pt,
    severity = (opts and opts.severity)
      and math.max(1, math.min(10, opts.severity))
      or CIV.rollSeverity(CS.severity) }
  SW._scenarios[scen.id] = scen
  CIV.Pool.occupy(pt)
  scen.sceneGname = spawnPoliceScene(CS.sceneTemplates, pt.point)
  scen.circleId = CIV.drawEventZone(pt.area, "SWAT objective #" .. scen.id, "swat")

  local hp = C.hover.fastRope
  scen.watch = CIV.Hover.watch({
    center = pt.point, label = "SWAT - fast-rope",
    radius = hp.radius, minAGL = hp.minAGL, maxAGL = hp.maxAGL,
    maxSpeed = hp.maxSpeed, T = hp.T, window = hp.window, B = hp.B,
    -- only hooks helicopters carrying enough operators for this scenario
    filter = function(u) return sState(u:getName()).squad >= requiredOperators(scen) end,
    onSuccess = function(unit, session)
      local uname = unit:getName()
      local st = sState(uname)
      local squad = st.squad
      st.squad = 0
      -- the squad stays physically present and operational after insertion
      -- (unlike rescue subjects, which are despawned when picked up)
      CIV.spawnGround(pt.point, squad, C.templates.swatTeam,
        C.fallbackTypes.swat, "CIVIL_SWAT")
      CIV.msgAll("SWAT: " .. squad .. " operators inserted at " .. pt.name ..
        ". Intervention in progress.", 15)
      local info = CIV.players[uname]
      if info then
        CIV.Score.award(info.playerName, "swat",
          CIV.Score.hoverQuality(session), CIV.Score.hoverTimeFactor(session),
          CIV.severityMult(scen.severity), "SWAT insertion")
      end
      CIV.schedule(function()
        CIV.msgAll("SWAT: scenario at " .. pt.name .. " RESOLVED. Area secure.", 15)
        CIV.unmark(scen.circleId)
        CIV.Pool.release(pt)
        releaseSceneLater(scen.sceneGname)
        scen.sceneGname = nil
        SW._scenarios[scen.id] = nil
      end, nil, CS.resolveTime
        * CIV.sevLerp(scen.severity, CS.resolveFactor.atMin, CS.resolveFactor.atMax))
    end,
    onFail = function()
      CIV.msgAll("SWAT: intervention at " .. pt.name .. " FAILED (window expired).", 15)
      CIV.unmark(scen.circleId)
      CIV.Pool.release(pt)
      releaseSceneLater(scen.sceneGname)
      scen.sceneGname = nil
      SW._scenarios[scen.id] = nil
    end,
  })
  CIV.msgAll("SWAT: hostile scenario reported at " .. pt.name ..
    " (severity " .. scen.severity .. "/10, requires " ..
    requiredOperators(scen) .. "+ operators)" ..
    "\n" .. CIV.coordText(pt.point) ..
    "\nBoard a team at the base and insert it via fast-rope.", 25)
  return scen
end

-- command center: close a scenario without any outcome
function SW.cancel(scen)
  if not SW._scenarios[scen.id] then return false end
  if scen.watch then CIV.Hover.unwatch(scen.watch) end
  CIV.unmark(scen.circleId)
  CIV.Pool.release(scen.pt)
  releaseSceneLater(scen.sceneGname)
  scen.sceneGname = nil
  SW._scenarios[scen.id] = nil
  return true
end

----------------------------------------------------------------------
-- PRISONER CONVOY ESCORT
-- A police car, the school bus with the detainees and a tail car drive
-- "On Road" from a CIVIL Convoy Start zone to a CIVIL Convoy End zone,
-- with the helicopter shadowing them. Along the way an AMBUSH (CIVIL
-- Ambush template: two armed men and a car) may appear ahead of the
-- route: report it via F10 for bonus points and the police clears the
-- site; miss it and the convoy drives into it, mission FAILED with a
-- malus on the escorting pilot. The ambush clone keeps the template's
-- own country: build it under a hostile country and the gunmen shoot
-- for real, but the scripted outcome works with any country.
----------------------------------------------------------------------

CIV.Convoy = { _runs = {}, _cid = 0 }
local CVY = CIV.Convoy
local CC = CP.convoy

-- convoy group: template first, else police car + school bus + tail car
local function spawnConvoyGroup(p)
  local name = CIV.spawnFromTemplate(C.templates.convoy, p)
  if name then return name end
  local gname = CIV.uniqueName("CIVIL_CONVOY")
  local types = { C.fallbackTypes.convoyCar, C.fallbackTypes.convoyBus,
                  C.fallbackTypes.convoyCar }
  local units = {}
  for i, tp in ipairs(types) do
    units[i] = { type = tp, name = gname .. "_" .. i, unitId = CIV.newUnitId(),
      x = p.x - (i - 1) * 15, y = p.z, heading = 0, skill = "Average",
      playerCanDrive = false }
  end
  coalition.addGroup(C.countryId, Group.Category.GROUND, {
    visible = false, lateActivation = false, task = "Ground Nothing",
    name = gname, groupId = CIV.newGroupId(), units = units,
    route = { points = { { x = p.x, y = p.z, type = "Turning Point",
                           action = "Off Road", speed = 0 } } },
  })
  return gname
end

local function convoyRoute(run, fromP)
  local g = Group.getByName(run.gname)
  if not g then return end
  pcall(function()
    g:getController():setTask({ id = "Mission", params = { route = { points = {
      { x = fromP.x, y = fromP.z, type = "Turning Point",
        action = run.roadAction, speed = CC.speed },
      { x = run.endP.x, y = run.endP.z, type = "Turning Point",
        action = run.roadAction, speed = CC.speed },
    } } } })
  end)
end

-- opts (command center): { severity = 1..10 }
function CVY.start(opts)
  if not CC.enabled then return nil end
  local n = 0
  for _ in pairs(CVY._runs) do n = n + 1 end
  if n >= CC.maxActive then return nil end
  local starts = CIV.Zones.byPrefix(C.zones.convoyStart)
  local stops = CIV.Zones.byPrefix(C.zones.convoyEnd)
  if #starts == 0 or #stops == 0 then return nil end
  local sArea = starts[math.random(#starts)]
  local eArea = stops[math.random(#stops)]
  local sp = { x = sArea.center.x,
               y = land.getHeight({ x = sArea.center.x, y = sArea.center.z }),
               z = sArea.center.z }

  CVY._cid = CVY._cid + 1
  local run = {
    id = CVY._cid, gname = spawnConvoyGroup(sp),
    endP = { x = eArea.center.x, z = eArea.center.z }, endName = eArea.name,
    severity = (opts and opts.severity)
      and math.max(1, math.min(10, opts.severity))
      or CIV.rollSeverity(CC.severity),
    roadAction = "On Road",
    escortTicks = 0, totalTicks = 0, escortName = nil,
    lastPos = nil, stalledSince = nil, rekicks = 0,
    -- the ambush needs its template: no CIVIL Ambush group, no threat
    ambushPlanned = math.random(100) <= CC.ambush.chance
      and #CIV.Templates.byPrefix(C.templates.ambush) > 0,
    ambushAt = timer.getTime() + CIV.randBetween(CC.ambush.delay),
  }
  local okSize, size0 = pcall(function()
    return Group.getByName(run.gname):getSize()
  end)
  if okSize then run.size0 = size0 end
  CVY._runs[run.id] = run
  CIV.schedule(function() convoyRoute(run, sp) end, nil, 2)
  CIV.msgAll("CONVOY ESCORT (severity " .. run.severity .. "/10): prisoner " ..
    "transport departing " .. sArea.name .. " for " .. eArea.name ..
    ".\n" .. CIV.coordText(sp) ..
    "\nShadow the convoy. Intel says the route may be watched: report " ..
    "anything suspicious via F10 BEFORE the convoy gets there.", 25)
  CIV.log("Convoy #" .. run.id .. " severity " .. run.severity ..
    (run.ambushPlanned and " (ambush planned)" or ""))
  return run
end

local function closeRun(run, delay)
  CVY._runs[run.id] = nil
  CIV.unmark(run.markId)
  local cg = run.gname
  local ag = run.ambush and run.ambush.gname
  CIV.schedule(function()
    CIV.despawnGroup(cg)
    if ag then CIV.despawnGroup(ag) end
  end, nil, delay or 1)
end

-- command center: close a run without any outcome
function CVY.cancel(run)
  if not CVY._runs[run.id] then return false end
  closeRun(run, 1)
  return true
end

-- F10 report: valid within reportRadius of an unreported ambush
function CVY.report(uname)
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  local p = u:getPoint()
  for _, run in pairs(CVY._runs) do
    local amb = run.ambush
    if amb and not amb.spotted
       and CIV.dist2D(p, amb.point) <= CC.ambush.reportRadius then
      amb.spotted = true
      local info = CIV.players[uname]
      if info then
        CIV.Score.award(info.playerName, "convoySpot", 0.9, 0.5,
          CIV.severityMult(run.severity), "convoy ambush reported")
      end
      run.markId = CIV.mark("Reported ambush (police responding)", amb.point)
      CIV.msgAll("CONVOY ESCORT: armed group reported on the route, " ..
        "marked on the F10 map. Ground units are moving in to clear the " ..
        "site before the convoy passes.", 15)
      local gname = amb.gname
      CIV.schedule(function()
        CIV.despawnGroup(gname)
        CIV.unmark(run.markId)
        run.markId = nil
        CIV.msgAll("CONVOY ESCORT: site clear. The route is safe again.", 12)
      end, nil, CC.ambush.clearDelay)
      return
    end
  end
  CIV.msgUnit(u, "Nothing suspicious in sight from here.", 10)
end

local function convoySprung(run, p)
  CIV.msgAll("CONVOY ESCORT: the convoy drove into an UNREPORTED ambush at\n" ..
    CIV.llString(p) .. "\nMission FAILED.", 20)
  pcall(trigger.action.explosion, { x = p.x, y = p.y + 2, z = p.z }, 10)
  if run.escortName then
    CIV.Score.award(run.escortName, "convoyMalus", 0.5, 0.5,
      CIV.severityMult(run.severity), "convoy lost (ambush unreported)")
  end
  closeRun(run, 20)
end

-- convoy loop: escort coverage, ambush lifecycle, arrival, watchdog
CIV.schedule(function(_, t)
  local now = timer.getTime()
  for _, run in pairs(CVY._runs) do
    local g = Group.getByName(run.gname)
    local u = g and g:getUnit(1)
    if not u or not u:isExist() then
      CIV.msgAll("CONVOY ESCORT: convoy lost. Mission over.", 12)
      closeRun(run, 1)
    else
      local p = u:getPoint()

      -- escort coverage: completion quality = time on station
      run.totalTicks = run.totalTicks + 1
      local escorted = false
      CIV.forEachPlayerHelo(function(h, info)
        if not escorted and CIV.dist2D(h:getPoint(), p) <= CC.escortRadius then
          escorted = true
          run.escortName = info.playerName
        end
      end)
      if escorted then run.escortTicks = run.escortTicks + 1 end

      -- the ambush appears ahead of the convoy, just off the road
      if run.ambushPlanned and not run.ambush and now >= run.ambushAt then
        local v = u:getVelocity()
        local hdg = CIV.speed(v) > 2
          and CIV.bearingDeg(p, { x = p.x + v.x, z = p.z + v.z })
          or CIV.bearingDeg(p, { x = run.endP.x, z = run.endP.z })
        local ap = CIV.offsetPoint(p, hdg, CC.ambush.aheadM)
        ap = CIV.offsetPoint(ap, hdg + (math.random(2) == 1 and 90 or -90),
          math.random(10, math.max(10, CC.ambush.lateralM)))
        local agname = CIV.spawnFromTemplate(C.templates.ambush, ap)
        if agname then
          run.ambush = { gname = agname, point = ap, spotted = false, hinted = {} }
          CIV.log("Convoy #" .. run.id .. ": ambush placed ahead of the route")
        else
          run.ambushPlanned = false
        end
      end

      -- hints + sprung check while the ambush is live and unreported
      local amb = run.ambush
      local sprung = false
      if amb and not amb.spotted then
        CIV.forEachPlayer(function(a, info)
          if amb.hinted[info.unitName] then return end
          local apnt = a:getPoint()
          if CIV.dist2D(apnt, amb.point) <= CC.ambush.hintRadius
             and CIV.agl(apnt) <= CC.ambush.maxAGL then
            amb.hinted[info.unitName] = true
            CIV.msgUnit(a, "Something odd off the convoy route nearby: a " ..
              "parked car and movement. Take a look and report it via F10.", 12)
          end
        end)
        local damaged = false
        local okSize, size = pcall(function() return g:getSize() end)
        if okSize and run.size0 and size < run.size0 then damaged = true end
        if damaged or CIV.dist2D(p, amb.point) <= CC.ambush.triggerRadius then
          sprung = true
          convoySprung(run, p)
        end
      end

      if not sprung then
        if CIV.dist2D(p, run.endP) <= CC.arriveRadius then
          local quality = run.escortTicks / math.max(1, run.totalTicks)
          if run.escortName then
            CIV.Score.award(run.escortName, "convoy", quality, 0.5,
              CIV.severityMult(run.severity),
              string.format("convoy escort (coverage %d%%)",
                math.floor(quality * 100)))
          end
          CIV.msgAll("CONVOY ESCORT: the transport reached " .. run.endName ..
            ". Detainees delivered." ..
            (run.escortName and "" or " No escort was on station."), 15)
          closeRun(run, 60)
        else
          -- stall watchdog (same "On Road" caveat as the chase)
          if run.lastPos and CIV.dist2D(p, run.lastPos) < 5 then
            run.stalledSince = run.stalledSince or now
            if now - run.stalledSince > 60 then
              run.stalledSince = nil
              run.rekicks = run.rekicks + 1
              if run.rekicks >= 2 then run.roadAction = "Off Road" end
              convoyRoute(run, p)
              CIV.dbg("Convoy #" .. run.id .. " re-kicked (watchdog)")
            end
          else
            run.stalledSince = nil
          end
          run.lastPos = { x = p.x, y = p.y, z = p.z }
        end
      end
    end
  end
  return t + 5
end, nil, 20)

----------------------------------------------------------------------
-- F10 MENU + EVENT STARTERS
----------------------------------------------------------------------

CIV.Menu_register(function(gid, uname)
  local sub = missionCommands.addSubMenuForGroup(gid, "Police / SWAT", CIV.rootMenu[gid])
  missionCommands.addCommandForGroup(gid, "Board SWAT team (at base)", sub, boardTeam, uname)
  missionCommands.addCommandForGroup(gid, "Team status", sub, function()
    local st = sState(uname)
    CIV.msgGroupId(gid, st.squad > 0
      and ("Team aboard: " .. st.squad .. " operators.")
      or "No team aboard.", 10)
  end)
  missionCommands.addCommandForGroup(gid, "Convoy: report suspicious activity",
    sub, CVY.report, uname)
end)

CIV.EventStarters.chase = { label = "Police chase", fn = PL.startChase }
CIV.EventStarters.swat = { label = "SWAT scenario", fn = SW.startScenario }
CIV.EventStarters.convoy = { label = "Prisoner convoy escort",
  fn = function() return CVY.start() end }

CIV.log("CivilPolice loaded")
