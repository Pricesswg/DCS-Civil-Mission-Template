----------------------------------------------------------------------
-- DCS Civil Mission Template - Sea operations
-- File: 47_CivilSeaOps.lua  (requires 01_CivilCore.lua; load after the
-- other intervention files, before 50_CivilCommand.lua)
--
--   SEA TRAFFIC: merchant ships spawn at a random point inside a
--   "CIVIL Sea Spawn" zone (staggered: two ships on the same spot
--   explode), sail a route over the "CIVIL Sea Lane" waypoint pool
--   (local random walk, same pattern as the police chase) and end in a
--   "CIVIL Sea Despawn" zone, where they are cleared. Purely scenic on
--   its own, and the target pool for the coast guard tasks.
--
--   COAST GUARD: helicopter inspection task. Fly alongside the reported
--   merchant (low, slow, close) to check the manifest. A clean manifest
--   pays a partial score; SUSPICIOUS cargo escalates: the ship runs for
--   it, the helicopter keeps track of it until the patrol boat arrives
--   and boards. Full score to the inspecting pilot on the boarding.
----------------------------------------------------------------------

assert(CIV and CIV.VERSION, "01_CivilCore.lua must be loaded first")

local C = CIV.Config
local ST = C.seaOps.traffic
local CG = C.seaOps.coastGuard

----------------------------------------------------------------------
-- SEA TRAFFIC
----------------------------------------------------------------------

CIV.SeaTraffic = { _ships = {}, _sid = 0 }
local SEA = CIV.SeaTraffic

local function zonesReady()
  return #CIV.Zones.byPrefix(C.zones.seaSpawn) > 0
     and #CIV.Zones.byPrefix(C.zones.seaDespawn) > 0
end

function SEA.count()
  local n = 0
  for _ in pairs(SEA._ships) do n = n + 1 end
  return n
end

local function shipUnit(ship)
  local g = Group.getByName(ship.gname)
  local u = g and g:getUnit(1)
  if u and u:isExist() then return u end
  return nil
end

-- random point inside a zone, kept clear of the other active ships
local function randomPointIn(area, minGap)
  for _ = 1, 12 do
    local ang = math.random() * 2 * math.pi
    local r = math.sqrt(math.random()) * math.max(200, (area.radius or 400) * 0.8)
    local p = { x = area.center.x + math.cos(ang) * r,
                z = area.center.z + math.sin(ang) * r }
    local clear = true
    for _, ship in pairs(SEA._ships) do
      local u = shipUnit(ship)
      if u and CIV.dist2D(u:getPoint(), p) < minGap then clear = false break end
    end
    if clear then return p end
  end
  return nil
end

-- Route: from the lane point nearest the spawn, walk laneHops nearby lane
-- points (local random walk over the CIVIL Sea Lane pool), then head for
-- the despawn zone nearest the last hop. No lanes defined = straight to
-- the despawn zone.
local function buildRoute(fromP)
  local hops = {}
  local lanes = CIV.Pool.load(C.zones.seaLane)
  if #lanes > 0 then
    local current, bestDist = nil, 1e12
    for _, pt in ipairs(lanes) do
      local d = CIV.dist2D(pt.point, fromP)
      if d < bestDist then current, bestDist = pt, d end
    end
    local lastName = nil
    while current and #hops < ST.laneHops do
      hops[#hops + 1] = current
      local nearby = CIV.Pool.near(C.zones.seaLane, current.point,
        ST.neighborRadius, lastName)
      lastName = current.name
      current = #nearby > 0 and nearby[math.random(#nearby)] or nil
    end
  end
  local lastP = #hops > 0 and hops[#hops].point or fromP
  local dz = CIV.Zones.nearest(C.zones.seaDespawn, lastP)
  return hops, dz
end

-- (re)assign the sailing route from an arbitrary start point
local function routeShip(ship, fromP, speed)
  local g = Group.getByName(ship.gname)
  if not g then return end
  local points = { { x = fromP.x, y = fromP.z, type = "Turning Point", speed = speed } }
  for _, hop in ipairs(ship.remainingHops or ship.hops) do
    points[#points + 1] = { x = hop.point.x, y = hop.point.z,
                            type = "Turning Point", speed = speed }
  end
  points[#points + 1] = { x = ship.endP.x, y = ship.endP.z,
                          type = "Turning Point", speed = speed }
  pcall(function()
    g:getController():setTask({ id = "Mission", params = { route = { points = points } } })
  end)
end

function SEA.spawn()
  if not ST.enabled or not zonesReady() then return nil end
  if SEA.count() >= ST.maxActive then return nil end
  local areas = CIV.Zones.byPrefix(C.zones.seaSpawn)
  local area = areas[math.random(#areas)]
  local p = randomPointIn(area, ST.minSpawnGap)
  if not p then return nil end
  local hops, dzArea = buildRoute(p)
  if not dzArea then return nil end

  SEA._sid = SEA._sid + 1
  local gname = CIV.spawnBoat({ x = p.x, y = 0, z = p.z }, "CIVIL_MERCHANT",
    C.templates.merchant, C.fallbackTypes.merchant)
  local ship = {
    id = SEA._sid, gname = gname, hops = hops,
    endP = { x = dzArea.center.x, z = dzArea.center.z },
    speed = ST.speed, spawnedAt = timer.getTime(), inspection = nil,
  }
  SEA._ships[ship.id] = ship
  CIV.schedule(function() routeShip(ship, p, ship.speed) end, nil, 2)
  CIV.log("Sea traffic: merchant #" .. ship.id .. " sailing out of " .. area.name)
  return ship
end

local function removeShip(ship, despawnAfter)
  SEA._ships[ship.id] = nil
  local gname = ship.gname
  CIV.schedule(function() CIV.despawnGroup(gname) end, nil, despawnAfter or 1)
end

-- Spawn a merchant on demand for a coast guard inspection (hybrid target
-- selection: used when no ambient merchant is free). It sails a real route
-- so the "inspect a moving vessel" mechanic still applies; if no sea zones
-- are defined it runs a straight line so it moves anyway. Registered like a
-- normal SEA ship (flagged dedicated) so the flee/board/cleanup logic is
-- shared. Bypasses the ambient traffic cap.
function SEA.spawnDedicated(nearPoint)
  local spawnP
  if nearPoint then
    spawnP = { x = nearPoint.x, z = nearPoint.z }
  else
    local areas = CIV.Zones.byPrefix(C.zones.seaSpawn)
    if #areas == 0 then return nil end   -- nowhere sensible to place it
    local area = areas[math.random(#areas)]
    spawnP = randomPointIn(area, ST.minSpawnGap)
      or { x = area.center.x, z = area.center.z }
  end
  local hops, dzArea = buildRoute(spawnP)
  local endP = dzArea and { x = dzArea.center.x, z = dzArea.center.z }
    or CIV.offsetPoint(spawnP, math.random(0, 359), 15000)  -- straight run

  SEA._sid = SEA._sid + 1
  local gname = CIV.spawnBoat({ x = spawnP.x, y = 0, z = spawnP.z },
    "CIVIL_MERCHANT", C.templates.merchant, C.fallbackTypes.merchant)
  local ship = {
    id = SEA._sid, gname = gname, hops = hops, endP = endP,
    speed = ST.speed, spawnedAt = timer.getTime(), inspection = nil,
    dedicated = true,
  }
  SEA._ships[ship.id] = ship
  CIV.schedule(function() routeShip(ship, spawnP, ship.speed) end, nil, 2)
  CIV.log("Sea traffic: dedicated inspection merchant #" .. ship.id .. " spawned")
  return ship
end

-- traffic loop: arrivals, hard cleanup, spawn cadence
local nextSeaSpawn = timer.getTime() + CIV.randBetween(ST.spawnEvery)
CIV.schedule(function(_, t)
  local now = timer.getTime()
  for _, ship in pairs(SEA._ships) do
    local u = shipUnit(ship)
    if not u then
      SEA._ships[ship.id] = nil
    elseif CIV.dist2D(u:getPoint(), ship.endP) <= ST.arriveRadius
        or now - ship.spawnedAt > ST.maxLifetime then
      if ship.inspection and CIV.CoastGuard then
        CIV.CoastGuard.shipGone(ship.inspection)
      end
      removeShip(ship, 5)
    end
  end
  if ST.enabled and now >= nextSeaSpawn then
    SEA.spawn()
    nextSeaSpawn = now + CIV.randBetween(ST.spawnEvery)
  end
  return t + 20
end, nil, 20)

----------------------------------------------------------------------
-- COAST GUARD
----------------------------------------------------------------------

CIV.CoastGuard = { _tasks = {}, _tid = 0 }
local CGD = CIV.CoastGuard

-- opts (command center): { point = vec3 (targets the merchant nearest the
--                          marker), severity = 1..10 }
function CGD.start(opts)
  if not CG.enabled then return nil end

  -- HYBRID: prefer a merchant already at sea (unless dedicatedOnly), else
  -- spawn one for the inspection (dedicatedFallback).
  local pick
  if not CG.dedicatedOnly then
    local candidates = {}
    for _, ship in pairs(SEA._ships) do
      if not ship.inspection then
        local u = shipUnit(ship)
        if u then candidates[#candidates + 1] = { ship = ship, unit = u } end
      end
    end
    if opts and opts.point then
      local bestDist = 1e12
      for _, cand in ipairs(candidates) do
        local d = CIV.dist2D(cand.unit:getPoint(), opts.point)
        if d < bestDist then pick, bestDist = cand, d end
      end
    elseif #candidates > 0 then
      pick = candidates[math.random(#candidates)]
    end
  end
  if not pick and (CG.dedicatedFallback or CG.dedicatedOnly) then
    local ship = SEA.spawnDedicated(opts and opts.point)
    local u = ship and shipUnit(ship)
    if u then pick = { ship = ship, unit = u } end
  end
  if not pick then return nil end

  CGD._tid = CGD._tid + 1
  local task = {
    id = CGD._tid, ship = pick.ship, state = "inspect",
    severity = (opts and opts.severity)
      and math.max(1, math.min(10, opts.severity))
      or CIV.rollSeverity(CG.severity),
    inspectTime = {},        -- unitName -> seconds alongside
    startedAt = timer.getTime(),
  }
  pick.ship.inspection = task.id
  CGD._tasks[task.id] = task
  local p = pick.unit:getPoint()
  CIV.msgAll("COAST GUARD (severity " .. task.severity .. "/10): inspect " ..
    "the merchant vessel M/V " .. (100 + task.id) ..
    ", last reported at:\n" .. CIV.coordText(p) ..
    "\nFly alongside LOW and SLOW (within " .. CG.inspect.radius ..
    " m, below " .. CG.inspect.maxRelAlt .. " m over the deck) for " ..
    CG.inspect.seconds .. " seconds to check the manifest.", 25)
  CIV.log("Coast guard task #" .. task.id .. " on merchant #" .. pick.ship.id)
  return task
end

local function closeTask(task)
  if task.ship then
    task.ship.inspection = nil
    -- a dedicated merchant was spawned just for this task: let it sail off
    -- and despawn (unless another path already removed it)
    if task.ship.dedicated and SEA._ships[task.ship.id] then
      removeShip(task.ship, 30)
    end
  end
  if task.boatGname then
    local gname = task.boatGname
    CIV.schedule(function() CIV.despawnGroup(gname) end, nil, 120)
  end
  CGD._tasks[task.id] = nil
end

-- command center: close a task without any outcome
function CGD.cancel(task)
  if not CGD._tasks[task.id] then return false end
  closeTask(task)
  return true
end

-- the merchant under inspection vanished (arrived or was cleaned up)
function CGD.shipGone(taskId)
  local task = CGD._tasks[taskId]
  if not task then return end
  CIV.msgAll("COAST GUARD: the merchant left the patrol sector. Task over.", 12)
  closeTask(task)
end

-- patrol boat dispatch: launched from the nearest CIVIL Vessel Spawn
-- harbor, re-tasked toward the (moving) suspect every pursuit tick
local function dispatchPatrolBoat(task, targetP)
  local best, bestDist = nil, 1e12
  for _, pt in ipairs(CIV.Pool.load(C.zones.vesselSpawn)) do
    local d = CIV.dist2D(pt.point, targetP)
    if d < bestDist then best, bestDist = pt, d end
  end
  if not best then return end
  task.boatGname = CIV.spawnBoat(best.point, "CIVIL_PATROL",
    C.templates.vessel, C.fallbackTypes.rescueBoat)
  CIV.msgAll("COAST GUARD: patrol boat launched from " .. best.name ..
    ", keep track of the suspect until it arrives.", 12)
end

local function steerBoat(task, targetP)
  if not task.boatGname then return end
  local g = Group.getByName(task.boatGname)
  if not g then return end
  pcall(function()
    g:getController():setTask({ id = "Mission", params = { route = { points = {
      { x = targetP.x, y = targetP.z, type = "Turning Point",
        speed = C.rescue.vessels.speed },
    } } } })
  end)
end

-- suspect ships stop following the lanes and run straight for the exit
local function shipFlees(task, fromP)
  task.ship.remainingHops = {}
  task.ship.speed = CG.fleeSpeed
  routeShip(task.ship, { x = fromP.x, z = fromP.z }, CG.fleeSpeed)
end

-- inspection / pursuit loop (2 s tick)
CIV.schedule(function(_, t)
  local now = timer.getTime()
  for _, task in pairs(CGD._tasks) do
    local u = shipUnit(task.ship)
    if not u then
      CGD.shipGone(task.id)
    else
      local sp = u:getPoint()
      if task.state == "inspect" then
        CIV.forEachPlayerHelo(function(h, info)
          if task.state ~= "inspect" then return end
          local hp = h:getPoint()
          local relAlt = hp.y - sp.y
          local relOk = relAlt >= 0 and relAlt <= CG.inspect.maxRelAlt
          local hv, sv = h:getVelocity(), u:getVelocity()
          local relSpeed = CIV.speed({ x = hv.x - sv.x, y = hv.y - sv.y,
                                       z = hv.z - sv.z })
          if CIV.dist2D(hp, sp) <= CG.inspect.radius and relOk
             and relSpeed <= CG.inspect.maxRelSpeed then
            task.inspectTime[info.unitName] =
              (task.inspectTime[info.unitName] or 0) + 2
            if task.inspectTime[info.unitName] >= CG.inspect.seconds then
              task.inspector = info.playerName
              if math.random(100) <= CG.suspectChance then
                task.state = "pursuit"
                task.lastContact = now
                CIV.msgAll("COAST GUARD: " .. info.playerName ..
                  " reports SUSPICIOUS CARGO on deck. The vessel is " ..
                  "running: keep track of it (within " ..
                  math.floor(CG.track.radius / 1000) ..
                  " km) until the patrol boat boards it.", 20)
                shipFlees(task, sp)
                dispatchPatrolBoat(task, sp)
              else
                CIV.msgAll("COAST GUARD: manifest of the inspected vessel " ..
                  "is CLEAN. Good check, " .. info.playerName .. ".", 15)
                CIV.Score.award(info.playerName, "coastGuard", 0.6, 0.5,
                  CIV.severityMult(task.severity), "vessel inspection (clean)")
                closeTask(task)
              end
            end
          end
        end)
      elseif task.state == "pursuit" then
        -- helicopter must keep contact
        local contact = false
        CIV.forEachPlayerHelo(function(h)
          if not contact
             and CIV.dist2D(h:getPoint(), sp) <= CG.track.radius then
            contact = true
          end
        end)
        if contact then task.lastContact = now end
        if now - task.lastContact > CG.track.graceSeconds then
          CIV.msgAll("COAST GUARD: contact lost too long, the suspect " ..
            "slipped away. Task failed.", 15)
          closeTask(task)
        else
          -- steer the patrol boat onto the moving target
          task.nextSteer = task.nextSteer or 0
          if now >= task.nextSteer then
            task.nextSteer = now + 30
            steerBoat(task, sp)
          end
          -- boarding check
          if task.boatGname then
            local bg = Group.getByName(task.boatGname)
            local bu = bg and bg:getUnit(1)
            if bu and bu:isExist()
               and CIV.dist2D(bu:getPoint(), sp) <= CG.boatHold.radius then
              task.boardTime = (task.boardTime or 0) + 2
              if task.boardTime >= CG.boatHold.seconds then
                CIV.msgAll("COAST GUARD: suspect vessel BOARDED. Cargo " ..
                  "seized. Textbook work by " ..
                  (task.inspector or "the patrol") .. ".", 20)
                if task.inspector then
                  CIV.Score.award(task.inspector, "coastGuard", 1.0, 0.5,
                    CIV.severityMult(task.severity),
                    "vessel inspection (suspect boarded)")
                end
                -- the merchant heaves to under escort, then clears out
                pcall(function()
                  local g = Group.getByName(task.ship.gname)
                  if g then g:getController():setTask({ id = "Hold", params = {} }) end
                end)
                local ship = task.ship
                CIV.schedule(function() removeShip(ship, 1) end, nil, 300)
                closeTask(task)
              end
            else
              task.boardTime = nil
            end
          end
        end
      end
    end
  end
  return t + 2
end, nil, 25)

CIV.EventStarters.inspection = { label = "Coast guard inspection",
  fn = function() return CGD.start() end }
CIV.EventStarters.merchant = { label = "Merchant ship (sea traffic)",
  fn = function() return SEA.spawn() end }

CIV.Menu_register(function(gid)
  local sub = missionCommands.addSubMenuForGroup(gid, "Coast guard", CIV.rootMenu[gid])
  missionCommands.addCommandForGroup(gid, "Active sea tasks", sub, function()
    local n, txt = 0, "Active sea tasks:\n"
    for _, task in pairs(CGD._tasks) do
      n = n + 1
      local u = shipUnit(task.ship)
      txt = txt .. string.format("- Inspection M/V %d (severity %d/10, %s)%s\n",
        100 + task.id, task.severity, task.state,
        u and ("  " .. CIV.llString(u:getPoint())) or "")
    end
    txt = txt .. string.format("Merchant traffic: %d ship(s) at sea.", SEA.count())
    CIV.msgGroupId(gid, n > 0 and txt
      or ("No inspection tasks. Merchant traffic: " .. SEA.count() .. " ship(s) at sea."), 20)
  end)
end)

CIV.log("CivilSeaOps loaded")
