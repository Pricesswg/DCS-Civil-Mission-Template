----------------------------------------------------------------------
-- DCS Civil Mission Template - Aviation tasks
-- File: 45_CivilAviation.lua  (requires 01_CivilCore.lua; load after the
-- other intervention files, before 50_CivilCommand.lua)
--
--   RECON: an anomaly appears on one of the "CIVIL Recon Point" corridor
--   waypoints (power line, pipeline...). Fly the corridor low: within
--   hintRadius you get a nudge, overhead and below maxAGL you report it
--   via F10. Optional visual from the "CIVIL Anomaly" template.
--
--   VIP SHUTTLE: a passenger waits at one "CIVIL VIP Pad" for a ride to
--   another. Board and drop off by holding landed on the pad. Ride
--   comfort IS the score quality: acceleration spikes eat it away.
--   Helicopters AND airplanes: put pads on airfield aprons and the light
--   trainers (Yak-52, MB-339, L-39, C-101...) get an air-taxi job.
--
--   MEDIA: any player helicopter or airplane holding in the filming ring
--   around an active event accumulates footage; when the story airs the
--   pilot is credited. One award per event, passive, no menu needed.
--
--   MEDICAL TRANSFER: event chain on the rescue module. A delivered
--   high-severity patient sometimes needs a second leg to a regional
--   hospital far away: pad to pad on the VIP Pad pool, with a criticality
--   clock and a tighter comfort threshold. The air ambulance job.
--
--   SKYDIVE: climb over a "CIVIL Drop Zone", release the jumpers via F10.
--   Landing point = wind drift (freefall damped + full canopy) plus a
--   steer correction toward the center; score quality = accuracy.
----------------------------------------------------------------------

assert(CIV and CIV.VERSION, "01_CivilCore.lua must be loaded first")

local C = CIV.Config

----------------------------------------------------------------------
-- INFRASTRUCTURE RECON
----------------------------------------------------------------------

CIV.Recon = { _anomalies = {}, _aid = 0 }
local RC = CIV.Recon
local CR = C.recon

-- opts (command center): { point = vec3, severity = 1..10 }
function RC.start(opts)
  local n = 0
  for _ in pairs(RC._anomalies) do n = n + 1 end
  if not (opts and opts.point) and n >= CR.maxActive then return nil end

  local pt
  if opts and opts.point then
    RC._aid = RC._aid + 1
    pt = { name = "GM anomaly " .. RC._aid, radius = 100,
           point = { x = opts.point.x, y = CIV.groundY(opts.point), z = opts.point.z } }
  else
    pt = CIV.Pool.pick(C.zones.reconPoints, 500)
  end
  if not pt then return nil end

  RC._aid = RC._aid + 1
  local sev = (opts and opts.severity)
    and math.max(1, math.min(10, opts.severity))
    or CIV.rollSeverity(CR.severity)
  local anomaly = {
    id = RC._aid, pt = pt, point = pt.point, severity = sev,
    scoreBonus = (opts and opts.scoreBonus) or 1,   -- task-board priority bonus
    expiresAt = timer.getTime() + CR.ttl,
    startedAt = timer.getTime(),
    hinted = {},
    gname = CIV.spawnFromTemplate(C.templates.anomaly, pt.point),
  }
  if CR.smokeVisual then
    -- thin smoke column: the fault is findable by eye, not only by the
    -- hint message (effectSmokeBig preset 5 = small smoke, no fire)
    anomaly.smokeName = "CIVIL_ANOMALY_" .. anomaly.id
    trigger.action.effectSmokeBig(anomaly.point, 5, 0.4, anomaly.smokeName)
  end
  RC._anomalies[anomaly.id] = anomaly
  CIV.Pool.occupy(pt)
  CIV.msgAll("INFRASTRUCTURE PATROL (severity " .. sev .. "/10): an anomaly " ..
    "is reported along the inspection corridor. Fly the recon line below " ..
    CR.maxAGL .. " m AGL and report it via F10 when overhead. " ..
    "Expires in " .. math.floor(CR.ttl / 60) .. " minutes.", 25)
  CIV.log("Recon anomaly #" .. anomaly.id .. " at " .. pt.name ..
    " severity " .. sev)
  return anomaly
end

local function closeAnomaly(anomaly)
  RC._anomalies[anomaly.id] = nil
  CIV.Pool.release(anomaly.pt)
  if anomaly.smokeName then trigger.action.effectSmokeStop(anomaly.smokeName) end
  if anomaly.gname then CIV.despawnGroup(anomaly.gname) end
end

-- command center: close an anomaly without any outcome
function RC.cancel(anomaly)
  if not RC._anomalies[anomaly.id] then return false end
  closeAnomaly(anomaly)
  return true
end

-- F10 report: valid when overhead (reportRadius) and low (maxAGL)
local function reportAnomaly(uname)
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  local p = u:getPoint()
  if CIV.agl(p) > CR.maxAGL then
    CIV.msgUnit(u, "Too high for a positive identification: get below " ..
      CR.maxAGL .. " m AGL.", 10)
    return
  end
  for _, anomaly in pairs(RC._anomalies) do
    if CIV.dist2D(p, anomaly.point) <= CR.reportRadius then
      local info = CIV.players[uname]
      if info then
        local timeFactor = math.max(0,
          1 - (timer.getTime() - anomaly.startedAt) / CR.ttl)
        CIV.Score.award(info.playerName, "recon", 0.8, timeFactor,
          CIV.severityMult(anomaly.severity) * (anomaly.scoreBonus or 1),
          "anomaly reported")
      end
      CIV.msgAll("RECON: anomaly at " .. anomaly.pt.name ..
        " identified and reported. Maintenance is on the way.", 15)
      closeAnomaly(anomaly)
      return
    end
  end
  CIV.msgUnit(u, "Nothing to report here.", 10)
end

-- expiry + proximity hints
CIV.schedule(function(_, t)
  local now = timer.getTime()
  for _, anomaly in pairs(RC._anomalies) do
    if now > anomaly.expiresAt then
      CIV.msgAll("RECON: the corridor anomaly went unreported and caused " ..
        "an outage. Task failed.", 15)
      closeAnomaly(anomaly)
    else
      CIV.forEachPlayer(function(u, info)
        if anomaly.hinted[info.unitName] then return end
        local p = u:getPoint()
        if CIV.dist2D(p, anomaly.point) <= CR.hintRadius
           and CIV.agl(p) <= CR.maxAGL then
          anomaly.hinted[info.unitName] = true
          CIV.msgUnit(u, "Something looks off along the line nearby: get " ..
            "overhead and report it via F10.", 12)
        end
      end)
    end
  end
  return t + 5
end, nil, 15)

----------------------------------------------------------------------
-- VIP SHUTTLE
----------------------------------------------------------------------

CIV.VIP = { _jobs = {}, _vid = 0 }
local VP = CIV.VIP
local CV = C.vip

local function padCandidates()
  return CIV.Pool.load(C.zones.vipPads)
end

-- opts (command center): { point = vec3 (pickup snaps to nearest pad),
--                          severity = 1..10 }
function VP.start(opts)
  local n = 0
  for _ in pairs(VP._jobs) do n = n + 1 end
  if not (opts and opts.point) and n >= CV.maxActive then return nil end

  local pads = padCandidates()
  if #pads < 2 then return nil end

  local from
  if opts and opts.point then
    local bestDist = 1e12
    for _, pad in ipairs(pads) do
      local d = CIV.dist2D(pad.point, opts.point)
      if d < bestDist then from, bestDist = pad, d end
    end
  else
    from = pads[math.random(#pads)]
  end
  local dest
  for _ = 1, 20 do
    local candidate = pads[math.random(#pads)]
    if candidate.name ~= from.name then dest = candidate break end
  end
  if not dest then return nil end

  VP._vid = VP._vid + 1
  local job = {
    id = VP._vid, from = from, to = dest,
    severity = (opts and opts.severity)
      and math.max(1, math.min(10, opts.severity))
      or CIV.rollSeverity(CV.severity),
    scoreBonus = (opts and opts.scoreBonus) or 1,   -- task-board priority bonus
    expiresAt = timer.getTime() + CV.pickupTtl,
    state = "waiting", unitName = nil,
    penalty = 0, lastVel = nil, lastComplaint = 0,
    boardTimer = {}, dropTimer = nil,
    gname = CIV.spawnFromTemplate(C.templates.vip, from.point),
  }
  VP._jobs[job.id] = job
  CIV.msgAll("VIP SHUTTLE (severity " .. job.severity .. "/10): passenger " ..
    "waiting at " .. from.name .. " for transport to " .. dest.name ..
    ".\n" .. CIV.coordText(from.point) ..
    "\nLand on the pad and hold for " .. CV.boardSeconds ..
    " seconds. Smooth flying pays: the passenger scores the ride.", 25)
  return job
end

local function closeJob(job)
  VP._jobs[job.id] = nil
  if job.gname then CIV.despawnGroup(job.gname) end
end

-- command center: close a job without any outcome
function VP.cancel(job)
  if not VP._jobs[job.id] then return false end
  closeJob(job)
  return true
end

local function landedOnPad(u, pad)
  return (not u:inAir())
    and CIV.speed(u:getVelocity()) <= 2.0
    and CIV.dist2D(u:getPoint(), pad.point) <= CV.padRadius
end

CIV.schedule(function(_, t)
  local now = timer.getTime()
  for _, job in pairs(VP._jobs) do
    if job.state == "waiting" then
      if now > job.expiresAt then
        CIV.msgAll("VIP SHUTTLE: the passenger at " .. job.from.name ..
          " gave up waiting. Task expired.", 12)
        closeJob(job)
      else
        -- helicopters and airplanes: place VIP pads on airfield aprons to
        -- give the light trainers an air-taxi job
        CIV.forEachPlayer(function(u, info)
          if info.category ~= Unit.Category.HELICOPTER
             and info.category ~= Unit.Category.AIRPLANE then return end
          if job.state ~= "waiting" then return end
          if landedOnPad(u, job.from) then
            job.boardTimer[info.unitName] = (job.boardTimer[info.unitName] or 0) + 2
            if job.boardTimer[info.unitName] >= CV.boardSeconds then
              job.state = "flying"
              job.unitName = info.unitName
              job.lastVel = u:getVelocity()
              if job.gname then CIV.despawnGroup(job.gname) job.gname = nil end
              CIV.msgUnit(u, "Passenger aboard. Destination: " .. job.to.name ..
                "\n" .. CIV.coordText(job.to.point) ..
                "\nKeep it smooth: hard maneuvers cost you the tip.", 20)
              CIV.msgAll("VIP SHUTTLE: " .. info.playerName ..
                " picked up the passenger at " .. job.from.name ..
                ", bound for " .. job.to.name .. ".", 10)
            end
          else
            job.boardTimer[info.unitName] = nil
          end
        end)
      end
    elseif job.state == "flying" then
      local u = Unit.getByName(job.unitName)
      if not u or not u:isExist() then
        CIV.msgAll("VIP SHUTTLE: transport lost with the passenger aboard.", 12)
        closeJob(job)
      else
        -- comfort sampling: acceleration spike = penalty (2 s tick)
        local v = u:getVelocity()
        if job.lastVel then
          local ax = (v.x - job.lastVel.x) / 2
          local ay = (v.y - job.lastVel.y) / 2
          local az = (v.z - job.lastVel.z) / 2
          local accel = math.sqrt(ax * ax + ay * ay + az * az)
          if accel > CV.comfort.accelLimit then
            job.penalty = job.penalty + CV.comfort.penaltyPerHit
            if now - job.lastComplaint > 30 then
              job.lastComplaint = now
              CIV.msgUnit(u, "The passenger grips the seat. Smoother, please.", 8)
            end
          end
        end
        job.lastVel = v
        -- dropoff
        if landedOnPad(u, job.to) then
          job.dropTimer = (job.dropTimer or 0) + 2
          if job.dropTimer >= CV.boardSeconds then
            local info = CIV.players[job.unitName]
            local quality = math.max(0, 1 - job.penalty)
            if info then
              CIV.Score.award(info.playerName, "vip", quality, 0.5,
                CIV.severityMult(job.severity) * (job.scoreBonus or 1),
                string.format("VIP shuttle (comfort %d%%)", math.floor(quality * 100)))
            end
            CIV.msgAll("VIP SHUTTLE: passenger delivered to " .. job.to.name ..
              " (ride comfort " .. math.floor(quality * 100) .. "%).", 15)
            closeJob(job)
          end
        else
          job.dropTimer = nil
        end
      end
    end
  end
  return t + 2
end, nil, 15)

----------------------------------------------------------------------
-- MEDICAL TRANSFER (air ambulance)
-- Chain trigger: the rescue module's hospital delivery loop calls
-- MT.maybeStart (guarded) after a successful delivery. Standalone starts
-- work too (admin menu, "civil transfer" marker command).
----------------------------------------------------------------------

CIV.MedTransfer = { _jobs = {}, _tid = 0 }
local MT = CIV.MedTransfer
local CT = C.medTransfer

-- opts: { severity = 1..10, nearPoint = vec3 (pickup snaps to nearest pad) }
function MT.start(opts)
  if not CT.enabled then return nil end
  local pads = padCandidates()
  if #pads < 2 then return nil end
  opts = opts or {}

  local from
  if opts.nearPoint then
    local bestDist = 1e12
    for _, pad in ipairs(pads) do
      local d = CIV.dist2D(pad.point, opts.nearPoint)
      if d < bestDist then from, bestDist = pad, d end
    end
  else
    from = pads[math.random(#pads)]
  end

  -- the regional hospital should be a real leg away; when the pool is
  -- tight, fall back to the farthest pad available
  local candidates, farthest, farDist = {}, nil, -1
  for _, pad in ipairs(pads) do
    if pad.name ~= from.name then
      local d = CIV.dist2D(pad.point, from.point)
      if d >= CT.minLeg then candidates[#candidates + 1] = pad end
      if d > farDist then farthest, farDist = pad, d end
    end
  end
  local dest = #candidates > 0 and candidates[math.random(#candidates)] or farthest
  if not dest then return nil end

  MT._tid = MT._tid + 1
  local sev = opts.severity
    and math.max(1, math.min(10, opts.severity))
    or CIV.rollSeverity({ min = CT.minSeverity, max = 10 })
  local job = {
    id = MT._tid, from = from, to = dest, severity = sev,
    scoreBonus = opts.scoreBonus or 1,   -- task-board priority bonus
    deadline = timer.getTime()
      + CIV.sevLerp(sev, CT.deadline.atMin, CT.deadline.atMax),
    deadlineTotal = CIV.sevLerp(sev, CT.deadline.atMin, CT.deadline.atMax),
    expiresAt = timer.getTime() + CT.pickupTtl,
    state = "waiting", unitName = nil,
    penalty = 0, lastVel = nil, lastComplaint = 0,
    boardTimer = {}, dropTimer = nil,
    gname = CIV.spawnFromTemplate(C.templates.survivor, from.point),
  }
  MT._jobs[job.id] = job
  CIV.msgAll("MEDICAL TRANSFER (severity " .. sev .. "/10): a patient at " ..
    from.name .. " must reach the regional hospital at " .. dest.name ..
    ".\n" .. CIV.coordText(from.point) ..
    "\nCriticality: " .. math.floor(job.deadlineTotal / 60) .. " minutes. " ..
    "Land and hold " .. CT.boardSeconds .. " seconds to board. Fly fast " ..
    "AND smooth: this passenger is on a stretcher.", 25)
  CIV.log("Medical transfer #" .. job.id .. " " .. from.name .. " -> " ..
    dest.name .. " severity " .. sev)
  return job
end

-- rescue chain hook, called (guarded) by the hospital delivery loop
function MT.maybeStart(severity, deliveryPoint)
  if not CT.enabled then return end
  if (severity or 0) < CT.minSeverity then return end
  if math.random(100) > CT.chance then return end
  MT.start({ severity = severity, nearPoint = deliveryPoint })
end

local function closeTransfer(job)
  MT._jobs[job.id] = nil
  if job.gname then CIV.despawnGroup(job.gname) end
end

-- command center: close a job without any outcome
function MT.cancel(job)
  if not MT._jobs[job.id] then return false end
  closeTransfer(job)
  return true
end

CIV.schedule(function(_, t)
  local now = timer.getTime()
  for _, job in pairs(MT._jobs) do
    if now > job.deadline then
      CIV.msgAll("MEDICAL TRANSFER: the patient did not survive the wait. " ..
        "Task failed.", 15)
      closeTransfer(job)
    elseif job.state == "waiting" then
      if now > job.expiresAt then
        CIV.msgAll("MEDICAL TRANSFER: reassigned to a ground ambulance. " ..
          "Task expired.", 12)
        closeTransfer(job)
      else
        -- pads sit on aprons: airplanes are the natural air ambulance,
        -- but a helicopter may take the leg too
        CIV.forEachPlayer(function(u, info)
          if info.category ~= Unit.Category.HELICOPTER
             and info.category ~= Unit.Category.AIRPLANE then return end
          if job.state ~= "waiting" then return end
          if landedOnPad(u, job.from) then
            job.boardTimer[info.unitName] = (job.boardTimer[info.unitName] or 0) + 2
            if job.boardTimer[info.unitName] >= CT.boardSeconds then
              job.state = "flying"
              job.unitName = info.unitName
              job.lastVel = u:getVelocity()
              if job.gname then CIV.despawnGroup(job.gname) job.gname = nil end
              CIV.msgUnit(u, "Patient aboard. Destination: " .. job.to.name ..
                "\n" .. CIV.coordText(job.to.point) ..
                "\nCriticality: " .. math.max(0,
                  math.floor((job.deadline - now) / 60)) .. " minutes.", 20)
              CIV.msgAll("MEDICAL TRANSFER: " .. info.playerName ..
                " has the patient aboard, bound for " .. job.to.name .. ".", 10)
            end
          else
            job.boardTimer[info.unitName] = nil
          end
        end)
      end
    elseif job.state == "flying" then
      local u = Unit.getByName(job.unitName)
      if not u or not u:isExist() then
        CIV.msgAll("MEDICAL TRANSFER: transport lost with the patient aboard.", 12)
        closeTransfer(job)
      else
        -- comfort sampling like the VIP job, tighter threshold (2 s tick)
        local v = u:getVelocity()
        if job.lastVel then
          local ax = (v.x - job.lastVel.x) / 2
          local ay = (v.y - job.lastVel.y) / 2
          local az = (v.z - job.lastVel.z) / 2
          local accel = math.sqrt(ax * ax + ay * ay + az * az)
          if accel > CT.comfort.accelLimit then
            job.penalty = job.penalty + CT.comfort.penaltyPerHit
            if now - job.lastComplaint > 30 then
              job.lastComplaint = now
              CIV.msgUnit(u, "The medic in the back: keep it steady!", 8)
            end
          end
        end
        job.lastVel = v
        if landedOnPad(u, job.to) then
          job.dropTimer = (job.dropTimer or 0) + 2
          if job.dropTimer >= CT.boardSeconds then
            local info = CIV.players[job.unitName]
            local quality = math.max(0, 1 - job.penalty)
            local timeFactor = math.max(0, (job.deadline - now) / job.deadlineTotal)
            if info then
              CIV.Score.award(info.playerName, "medTransfer", quality, timeFactor,
                CIV.severityMult(job.severity) * (job.scoreBonus or 1),
                string.format("medical transfer (comfort %d%%)",
                  math.floor(quality * 100)))
            end
            CIV.msgAll("MEDICAL TRANSFER: patient handed over at " ..
              job.to.name .. " in time.", 15)
            closeTransfer(job)
          end
        else
          job.dropTimer = nil
        end
      end
    end
  end
  return t + 2
end, nil, 15)

----------------------------------------------------------------------
-- SKYDIVE DROPS (the flying club)
----------------------------------------------------------------------

CIV.Skydive = {}
local SK = CIV.Skydive
local SKC = C.skydive
local lastDrop = {}   -- unitName -> time of the last release

function SK.release(uname)
  if not SKC.enabled then return end
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  local info = CIV.players[uname]
  if not info then return end
  if not u:inAir() then
    CIV.msgUnit(u, "The jumpers politely decline to exit on the ground.", 10)
    return
  end
  local p = u:getPoint()
  local dz = CIV.Zones.containing(C.zones.dropZones, p)
  if not dz then
    CIV.msgUnit(u, #CIV.Zones.byPrefix(C.zones.dropZones) == 0
      and ("No '" .. C.zones.dropZones .. "' zone is defined in this mission.")
      or "You are not over a drop zone.", 10)
    return
  end
  local agl = CIV.agl(p)
  if agl < SKC.minAGL then
    CIV.msgUnit(u, "Too low for a jump: release above " .. SKC.minAGL ..
      " m AGL.", 10)
    return
  end
  local now = timer.getTime()
  if lastDrop[uname] and now - lastDrop[uname] < SKC.cooldown then
    CIV.msgUnit(u, "The next load of jumpers is still kitting up: " ..
      math.ceil(SKC.cooldown - (now - lastDrop[uname])) .. " s.", 10)
    return
  end
  lastDrop[uname] = now

  -- wind sampled once at mid-canopy height (zero wind if the API balks)
  local wind = { x = 0, y = 0, z = 0 }
  pcall(function()
    local w = atmosphere.getWind({ x = p.x,
      y = CIV.groundY(p) + SKC.openAGL / 2, z = p.z })
    if w and w.x then wind = w end
  end)
  local ffTime = math.max(0, agl - SKC.openAGL) / SKC.freefallSpeed
  local canopyTime = math.min(agl, SKC.openAGL) / SKC.canopySink
  local drift = ffTime * SKC.freefallDrift + canopyTime
  local lp = { x = p.x + wind.x * drift, z = p.z + wind.z * drift }

  -- under canopy the jumpers steer back toward the DZ center
  local center = { x = dz.center.x, z = dz.center.z }
  local off = CIV.dist2D(lp, center)
  if off > 0 then
    local pull = math.min(SKC.steerM, off)
    lp.x = lp.x + (center.x - lp.x) / off * pull
    lp.z = lp.z + (center.z - lp.z) / off * pull
  end
  lp.y = land.getHeight({ x = lp.x, y = lp.z })

  local playerName, dzName, dzRadius = info.playerName, dz.name, dz.radius or 300
  CIV.msgUnit(u, SKC.jumpers .. " jumpers away over " .. dzName ..
    "! Canopies in the air.", 10)
  CIV.schedule(function()
    local gname = CIV.spawnGround(lp, SKC.jumpers, C.templates.skydiver,
      C.fallbackTypes.skydiver, "CIVIL_SKYDIVE")
    local dist = math.floor(CIV.dist2D(lp, center) + 0.5)
    local quality = math.max(0, 1 - dist / math.max(100, dzRadius))
    CIV.Score.award(playerName, "skydive", quality, 0.5, 1,
      string.format("skydive drop (%d m from center)", dist))
    CIV.msgAll("SKYDIVE: the jumpers released by " .. playerName ..
      " landed " .. dist .. " m from the center of " .. dzName .. ".", 12)
    if gname then
      CIV.schedule(function() CIV.despawnGroup(gname) end, nil, SKC.despawnDelay)
    end
  end, nil, math.max(1, ffTime + canopyTime))
end

----------------------------------------------------------------------
-- MEDIA COVERAGE (passive)
----------------------------------------------------------------------

local CM = C.media
local filmTime = {}   -- unitName .. "|" .. eventKey -> seconds
local aired = {}      -- eventKey -> true (one story per event)

-- active events worth filming: { key, point, label }. Every module lookup
-- is guarded, so leaving intervention files out of the load list is safe.
local function filmableEvents()
  local list = {}
  if CIV.Fire then
    for _, fire in pairs(CIV.Fire.actives()) do
      list[#list + 1] = { key = "fire" .. fire.id, point = fire.point,
        label = fire.kindDef.name .. " at " .. fire.pt.name }
    end
  end
  if CIV.Rescue then
    for _, sc in pairs(CIV.Rescue._scenarios) do
      for _, evt in pairs(sc.events) do
        list[#list + 1] = { key = sc.def.key .. evt.id, point = evt.point,
          label = sc.def.label .. " #" .. evt.id }
      end
    end
  end
  if CIV.SWAT then
    for _, scen in pairs(CIV.SWAT._scenarios) do
      list[#list + 1] = { key = "swat" .. scen.id, point = scen.pt.point,
        label = "SWAT operation at " .. scen.pt.name }
    end
  end
  if CIV.Police then
    for _, chase in pairs(CIV.Police._chases) do
      local g = Group.getByName(chase.gname)
      local u = g and g:getUnit(1)
      if u and u:isExist() then
        list[#list + 1] = { key = "chase" .. chase.id, point = u:getPoint(),
          label = "police chase #" .. chase.id }
      end
    end
  end
  return list
end

if CM.enabled then
  CIV.schedule(function(_, t)
    local events = filmableEvents()
    if #events > 0 then
      -- helicopters AND airplanes: a trainer orbiting the ring films too
      CIV.forEachPlayer(function(u, info)
        if info.category ~= Unit.Category.HELICOPTER
           and info.category ~= Unit.Category.AIRPLANE then return end
        local p = u:getPoint()
        if CIV.agl(p) < CM.minAGL then return end
        for _, evt in ipairs(events) do
          if not aired[evt.key] then
            local d = CIV.dist2D(p, evt.point)
            if d >= CM.minDist and d <= CM.maxDist then
              local k = info.unitName .. "|" .. evt.key
              filmTime[k] = (filmTime[k] or 0) + 5
              if filmTime[k] >= CM.filmSeconds then
                aired[evt.key] = true
                CIV.Score.award(info.playerName, "media", 0.7, 0.5, 1,
                  "live coverage: " .. evt.label)
                CIV.msgAll("LIVE ON AIR: " .. info.playerName ..
                  " broadcast footage of the " .. evt.label .. ".", 15)
              end
            end
          end
        end
      end)
    end
    return t + 5
  end, nil, 20)
end

----------------------------------------------------------------------
-- TASK BOARD (pilot-called aviation tasks)
-- Recon, VIP and medical transfer are not pushed on the pilots anymore:
-- the director POSTS OFFERS and whoever is ready accepts one via F10
-- (maybe you are refueling, or mid-task: nothing gets assigned to you).
-- Offers pre-roll severity so the board shows the expected points, and
-- PRIORITY offers carry a score bonus. GM marker commands bypass the
-- board on purpose: the commander wants the event NOW. The MedEvac chain
-- also stays direct: that patient already exists and his clock is
-- ticking.
----------------------------------------------------------------------

CIV.TaskBoard = { _offers = {}, _oid = 0 }
local TB = CIV.TaskBoard
local CB = C.taskBoard

local offerKinds = {
  recon    = { label = "Recon anomaly", scoreKey = "recon",
               start = function(o) return RC.start({ severity = o.severity,
                 scoreBonus = o.bonus }) end },
  vip      = { label = "VIP shuttle", scoreKey = "vip",
               start = function(o) return VP.start({ severity = o.severity,
                 scoreBonus = o.bonus }) end },
  transfer = { label = "Medical transfer", scoreKey = "medTransfer",
               start = function(o) return MT.start({ severity = o.severity,
                 scoreBonus = o.bonus }) end },
}

local function offerCount()
  local n = 0
  for _ in pairs(TB._offers) do n = n + 1 end
  return n
end

function TB.post(kind)
  local k = offerKinds[kind]
  if not k then return nil end
  if not CB.enabled then
    -- board disabled in config: fall back to the old push behavior
    return k.start({ severity = nil, bonus = 1 })
  end
  if offerCount() >= CB.maxOffers then return nil end
  TB._oid = TB._oid + 1
  local offer = {
    id = TB._oid, kind = kind, label = k.label,
    severity = kind == "transfer"
      and CIV.rollSeverity({ min = C.medTransfer.minSeverity, max = 10 })
      or CIV.rollSeverity(),
    priority = math.random(100) <= CB.priorityChance,
    expiresAt = timer.getTime() + CB.offerTtl,
  }
  offer.bonus = offer.priority and CB.priorityBonus or 1
  offer.points = CIV.Score.compute(k.scoreKey, 0.8, 0.5,
    CIV.severityMult(offer.severity) * offer.bonus)
  TB._offers[offer.id] = offer
  CIV.msgAll("TASK BOARD: new " .. (offer.priority and "PRIORITY " or "") ..
    "offer: " .. offer.label .. ", severity " .. offer.severity ..
    "/10, about " .. offer.points .. " pts" ..
    (offer.priority and (" (includes the +" ..
      math.floor((CB.priorityBonus - 1) * 100) .. "% priority bonus)") or "") ..
    ".\nAccept it via F10 -> Aviation tasks -> Task board.", 15)
  return offer
end

local function sortedOffers()
  local list = {}
  for _, o in pairs(TB._offers) do list[#list + 1] = o end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

local function listOffers(gid)
  local list = sortedOffers()
  if #list == 0 then
    CIV.msgGroupId(gid, "The task board is empty.", 10)
    return
  end
  local txt = "TASK BOARD (accept by slot number):\n"
  for i, o in ipairs(list) do
    txt = txt .. string.format("%d. %s%s  severity %d/10  ~%d pts  %d min left\n",
      i, o.priority and "[PRIORITY] " or "", o.label, o.severity, o.points,
      math.max(0, math.floor((o.expiresAt - timer.getTime()) / 60)))
  end
  CIV.msgGroupId(gid, txt, 25)
end

function TB.accept(slot, uname)
  local u = Unit.getByName(uname)
  local offer = sortedOffers()[slot]
  if not offer then
    if u then CIV.msgUnit(u, "No offer in slot " .. slot ..
      ": check the board first.", 8) end
    return
  end
  TB._offers[offer.id] = nil
  local started = offerKinds[offer.kind].start(offer)
  local info = CIV.players[uname]
  if started then
    CIV.msgAll("TASK BOARD: '" .. offer.label .. "' accepted" ..
      (info and (" by " .. info.playerName) or "") .. ". Task is live.", 10)
  elseif u then
    CIV.msgUnit(u, "The offer could not start (missing zones or cap " ..
      "reached). It has been taken off the board.", 10)
  end
end

-- offer expiry
CIV.schedule(function(_, t)
  local now = timer.getTime()
  for id, offer in pairs(TB._offers) do
    if now > offer.expiresAt then
      TB._offers[id] = nil
      CIV.log("Task board: offer '" .. offer.label .. "' expired unclaimed")
    end
  end
  return t + 30
end, nil, 30)

----------------------------------------------------------------------
-- F10 MENU + EVENT STARTERS
----------------------------------------------------------------------

CIV.Menu_register(function(gid, uname)
  local sub = missionCommands.addSubMenuForGroup(gid, "Aviation tasks", CIV.rootMenu[gid])
  missionCommands.addCommandForGroup(gid, "Recon: report anomaly overhead",
    sub, reportAnomaly, uname)
  missionCommands.addCommandForGroup(gid, "Skydive: release jumpers (over a drop zone)",
    sub, SK.release, uname)
  if CB.enabled then
    local board = missionCommands.addSubMenuForGroup(gid, "Task board", sub)
    missionCommands.addCommandForGroup(gid, "List offers", board, listOffers, gid)
    for slot = 1, math.min(CB.maxOffers, 6) do
      missionCommands.addCommandForGroup(gid, "Accept offer " .. slot, board,
        function() TB.accept(slot, uname) end)
    end
  end
  missionCommands.addCommandForGroup(gid, "Active aviation tasks", sub, function()
    local n, txt = 0, "Active aviation tasks:\n"
    for _, a in pairs(RC._anomalies) do
      n = n + 1
      txt = txt .. string.format("- Recon anomaly (severity %d/10), corridor, %d min left\n",
        a.severity, math.max(0, math.floor((a.expiresAt - timer.getTime()) / 60)))
    end
    for _, job in pairs(VP._jobs) do
      n = n + 1
      txt = txt .. string.format("- VIP %s -> %s (%s)\n", job.from.name,
        job.to.name, job.state)
    end
    for _, job in pairs(MT._jobs) do
      n = n + 1
      txt = txt .. string.format(
        "- Medical transfer %s -> %s (%s, %d min left)\n", job.from.name,
        job.to.name, job.state,
        math.max(0, math.floor((job.deadline - timer.getTime()) / 60)))
    end
    CIV.msgGroupId(gid, n > 0 and txt or "No active aviation tasks.", 20)
  end)
end)

-- the director and the admin menu post OFFERS on the board (pilot-called
-- tasks); with taskBoard.enabled = false TB.post falls back to direct starts
CIV.EventStarters.recon = { label = "Recon anomaly (board offer)",
  fn = function() return TB.post("recon") end }
CIV.EventStarters.vip = { label = "VIP shuttle (board offer)",
  fn = function() return TB.post("vip") end }
CIV.EventStarters.transfer = { label = "Medical transfer (board offer)",
  fn = function() return TB.post("transfer") end }

CIV.log("CivilAviation loaded")
