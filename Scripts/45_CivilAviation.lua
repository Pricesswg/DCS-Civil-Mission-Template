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
--
--   MEDIA: any player helicopter holding in the filming ring around an
--   active event accumulates footage; when the story airs the pilot is
--   credited. One award per event, passive, no menu needed.
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
    expiresAt = timer.getTime() + CR.ttl,
    startedAt = timer.getTime(),
    hinted = {},
    gname = CIV.spawnFromTemplate(C.templates.anomaly, pt.point),
  }
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
          CIV.severityMult(anomaly.severity), "anomaly reported")
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
        CIV.forEachPlayerHelo(function(u, info)
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
                CIV.severityMult(job.severity),
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
-- MEDIA COVERAGE (passive)
----------------------------------------------------------------------

local CM = C.media
local filmTime = {}   -- unitName .. "|" .. eventKey -> seconds
local aired = {}      -- eventKey -> true (one story per event)

-- active events worth filming: { key, point, label }
local function filmableEvents()
  local list = {}
  for _, fire in pairs(CIV.Fire.actives()) do
    list[#list + 1] = { key = "fire" .. fire.id, point = fire.point,
      label = fire.kindDef.name .. " at " .. fire.pt.name }
  end
  for _, sc in pairs(CIV.Rescue._scenarios) do
    for _, evt in pairs(sc.events) do
      list[#list + 1] = { key = sc.def.key .. evt.id, point = evt.point,
        label = sc.def.label .. " #" .. evt.id }
    end
  end
  for _, scen in pairs(CIV.SWAT._scenarios) do
    list[#list + 1] = { key = "swat" .. scen.id, point = scen.pt.point,
      label = "SWAT operation at " .. scen.pt.name }
  end
  for _, chase in pairs(CIV.Police._chases) do
    local g = Group.getByName(chase.gname)
    local u = g and g:getUnit(1)
    if u and u:isExist() then
      list[#list + 1] = { key = "chase" .. chase.id, point = u:getPoint(),
        label = "police chase #" .. chase.id }
    end
  end
  return list
end

if CM.enabled then
  CIV.schedule(function(_, t)
    local events = filmableEvents()
    if #events > 0 then
      CIV.forEachPlayerHelo(function(u, info)
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
-- F10 MENU + EVENT STARTERS
----------------------------------------------------------------------

CIV.Menu_register(function(gid, uname)
  local sub = missionCommands.addSubMenuForGroup(gid, "Aviation tasks", CIV.rootMenu[gid])
  missionCommands.addCommandForGroup(gid, "Recon: report anomaly overhead",
    sub, reportAnomaly, uname)
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
    CIV.msgGroupId(gid, n > 0 and txt or "No active aviation tasks.", 20)
  end)
end)

CIV.EventStarters.recon = { label = "Recon anomaly", fn = function() return RC.start() end }
CIV.EventStarters.vip = { label = "VIP shuttle", fn = function() return VP.start() end }

CIV.log("CivilAviation loaded")
