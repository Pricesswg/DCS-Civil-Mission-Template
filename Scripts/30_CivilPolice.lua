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
      if contact then
        chase.pressure = math.min(100, chase.pressure + chase.rateUp * 2)   -- 2 s tick
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
  local zone = CIV.Zones.byName(C.zones.swatBase)
  if not zone then
    CIV.msgUnit(u, "Zone '" .. C.zones.swatBase .. "' is not defined in the mission.", 10)
    return
  end
  if u:inAir() or not CIV.Zones.contains(zone, u:getPoint())
     or CIV.speed(u:getVelocity()) > 1 then
    CIV.msgUnit(u, "You must be LANDED and stationary inside the SWAT base.", 10)
    return
  end
  CIV.msgUnit(u, "Boarding team: stay put for " .. CS.boardingTime .. " seconds.", 10)
  CIV.schedule(function()
    local u2 = Unit.getByName(uname)
    if not u2 or not u2:isExist() then return end
    if u2:inAir() or not CIV.Zones.contains(zone, u2:getPoint())
       or CIV.speed(u2:getVelocity()) > 1 then
      CIV.msgUnit(u2, "Boarding aborted: you moved.", 10)
      return
    end
    -- squad size fixed HERE, at boarding (design rule)
    st.squad = boardingSize()
    CIV.msgUnit(u2, "SWAT team aboard: " .. st.squad ..
      " operators. Insert them on the active objective via fast-rope.", 15)
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
end)

CIV.EventStarters.chase = { label = "Police chase", fn = PL.startChase }
CIV.EventStarters.swat = { label = "SWAT scenario", fn = SW.startScenario }

CIV.log("CivilPolice loaded")
