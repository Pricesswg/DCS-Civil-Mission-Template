----------------------------------------------------------------------
-- DCS Civil Mission Template - Command Center (game-master console)
-- File: 50_CivilCommand.lua  (requires 01_CivilCore.lua and the
-- intervention files; load LAST)
--
-- Marker-driven mission control for a player acting as the emergency
-- command center, intended for a Game Master / Tactical Commander slot
-- (full F10 map, SRS; with Combined Arms they also get native asset
-- control). Marker commands work from ANY slot though.
--
-- Usage: place an F10 map marker whose text starts with the configured
-- prefix (default "civil"), at the position where the effect should
-- happen. The marker is consumed (removed) once executed.
--
--   civil fire [kind] [sev]   wildfire at the marker; kind is optional
--                             (forest/landfill/industrial/building)
--   civil sarm [sev]          mountain SAR subject at the marker
--   civil sars [sev]          sea SAR subject at the marker (must be water)
--   civil medevac [sev]       MedEvac casualty at the marker
--   civil casevac [sev]       battlefield casualty at the marker
--   civil swat [sev]          SWAT objective at the marker
--   civil chase [sev]         chase from the crossroad nearest the marker
--   civil convoy [sev]        prisoner convoy run (uses the Convoy Start/End zones)
--   civil recon [sev]         corridor anomaly at the marker
--   civil vip [sev]           VIP shuttle from the pad nearest the marker
--   civil transfer [sev]      medical transfer from the pad nearest the marker
--   civil tour [sev]          sightseeing tour from the pad nearest the marker
--   civil supply [sev]        supply-drop emergency on the drop zone nearest
--                             the marker
--   civil inspect [sev]       coast guard inspection on the merchant
--                             nearest the marker
--   civil ship                spawn a merchant on the sea lanes
--   civil flight              spawn an ambient civil flight
--   civil cargo [tier] [pri]  loading point at the marker (tier: light/
--                             medium/heavy/heavy_lift)
--   civil spawn <tpl> [n]     clone a late-activated template whose name
--                             contains <tpl> at the marker (n units)
--   civil move <grp> [spd] [road]  route the ME ground/ship group whose
--                             name contains <grp> to the marker
--   civil cancel              cancel the nearest active event
--   civil director on|off     toggle the automatic event director
--   civil help                list the commands
--
-- NOTE (to validate in-game): marker events from Game Master / Combined
-- Arms slots may carry no readable initiator; with restrict.enabled the
-- allowUnidentified flag decides whether such marks are accepted.
----------------------------------------------------------------------

assert(CIV and CIV.VERSION, "01_CivilCore.lua must be loaded first")

local C = CIV.Config
local CMD = C.command

CIV.Command = {}

----------------------------------------------------------------------
-- PERMISSIONS
----------------------------------------------------------------------

local function allowed(event)
  if not CMD.restrict.enabled then return true end
  local name = nil
  if event.initiator then
    local ok, n = pcall(function() return event.initiator:getPlayerName() end)
    if ok then name = n end
  end
  if not name then return CMD.restrict.allowUnidentified end
  for _, allowedName in ipairs(CMD.restrict.playerNames) do
    if allowedName == name then return true end
  end
  return false
end

----------------------------------------------------------------------
-- COMMAND IMPLEMENTATIONS
----------------------------------------------------------------------

local function say(text)
  CIV.msgAll("COMMAND CENTER: " .. text, 12)
end

local function toSeverity(token)
  local n = tonumber(token)
  if n then return math.max(1, math.min(10, math.floor(n))) end
  return nil
end

local function findTemplate(fragment)
  fragment = string.lower(fragment)
  for _, tpl in ipairs(CIV.Templates._groups) do
    if string.find(string.lower(tpl.name), fragment, 1, true) then return tpl end
  end
  return nil
end

local function findGroup(fragment)
  fragment = string.lower(fragment)
  -- exact name first, then fragment search over the ME group list
  local g = Group.getByName(fragment)
  if g and g:getUnit(1) then return g, fragment, nil end
  for _, entry in ipairs(CIV.MissionGroups) do
    if string.find(string.lower(entry.name), fragment, 1, true) then
      local grp = Group.getByName(entry.name)
      if grp and grp:getUnit(1) and grp:getUnit(1):isExist() then
        return grp, entry.name, entry.category
      end
    end
  end
  return nil
end

-- nearest active event of any kind within cancelRadius
local function cancelNearest(point)
  local best, bestDist = nil, CMD.cancelRadius
  local function consider(p, label, fn)
    local d = CIV.dist2D(p, point)
    if d < bestDist then best, bestDist = { label = label, fn = fn }, d end
  end
  if CIV.Fire then
    for _, fire in pairs(CIV.Fire.actives()) do
      consider(fire.point, "wildfire at " .. fire.pt.name,
        function() CIV.Fire.callOff(fire) end)
    end
  end
  if CIV.Rescue then
    for _, sc in pairs(CIV.Rescue._scenarios) do
      for _, evt in pairs(sc.events) do
        consider(evt.point, sc.def.label .. " #" .. evt.id,
          function() CIV.Rescue.cancel(evt) end)
      end
    end
  end
  if CIV.Police then
    for _, chase in pairs(CIV.Police._chases) do
      local g = Group.getByName(chase.gname)
      local u = g and g:getUnit(1)
      if u and u:isExist() then
        consider(u:getPoint(), "police chase #" .. chase.id,
          function() CIV.Police.cancel(chase) end)
      end
    end
  end
  if CIV.SWAT then
    for _, scen in pairs(CIV.SWAT._scenarios) do
      consider(scen.pt.point, "SWAT objective at " .. scen.pt.name,
        function() CIV.SWAT.cancel(scen) end)
    end
  end
  if CIV.Cargo then
    for _, pt in pairs(CIV.Cargo._points) do
      consider(pt.pt.point, "loading point at " .. pt.pt.name,
        function() CIV.Cargo.cancel(pt) end)
    end
  end
  if CIV.Recon then
    for _, anomaly in pairs(CIV.Recon._anomalies) do
      consider(anomaly.point, "recon anomaly at " .. anomaly.pt.name,
        function() CIV.Recon.cancel(anomaly) end)
    end
  end
  if CIV.VIP then
    for _, job in pairs(CIV.VIP._jobs) do
      consider(job.from.point, "VIP shuttle from " .. job.from.name,
        function() CIV.VIP.cancel(job) end)
    end
  end
  if CIV.MedTransfer then
    for _, job in pairs(CIV.MedTransfer._jobs) do
      consider(job.from.point, "medical transfer from " .. job.from.name,
        function() CIV.MedTransfer.cancel(job) end)
    end
  end
  if CIV.Tour then
    for _, job in pairs(CIV.Tour._jobs) do
      consider(job.from.point, "sightseeing tour from " .. job.from.name,
        function() CIV.Tour.cancel(job) end)
    end
  end
  if CIV.SupplyDrop then
    for _, evt in pairs(CIV.SupplyDrop._events) do
      consider({ x = evt.center.x, z = evt.center.z },
        "supply drop at " .. evt.zone.name,
        function() CIV.SupplyDrop.cancel(evt) end)
    end
  end
  if CIV.Convoy then
    for _, run in pairs(CIV.Convoy._runs) do
      local g = Group.getByName(run.gname)
      local u = g and g:getUnit(1)
      if u and u:isExist() then
        consider(u:getPoint(), "prisoner convoy #" .. run.id,
          function() CIV.Convoy.cancel(run) end)
      end
    end
  end
  if CIV.CoastGuard then
    for _, task in pairs(CIV.CoastGuard._tasks) do
      local g = Group.getByName(task.ship.gname)
      local u = g and g:getUnit(1)
      if u and u:isExist() then
        consider(u:getPoint(), "coast guard inspection #" .. task.id,
          function() CIV.CoastGuard.cancel(task) end)
      end
    end
  end
  if best then
    best.fn()
    say("cancelled: " .. best.label .. ".")
  else
    say("no active event within " .. math.floor(CMD.cancelRadius / 1000) .. " km of the marker.")
  end
end

local commands = {}

local function moduleMissing(name)
  say(name .. " module is not loaded in this mission.")
end

-- civil fire [kind] [sev]: the kind word is optional ("civil fire 7",
-- "civil fire building 7", "civil fire landfill"). Building fires only
-- start this way or on dedicated fire points: they never roll randomly.
commands.fire = function(args, point)
  if not CIV.Fire then moduleMissing("firefighting") return end
  local kind, sev = nil, toSeverity(args[1])
  if args[1] and not sev then
    kind = CIV.Fire.kindByFragment(args[1])
    if not kind then
      say("unknown fire kind '" .. args[1] ..
        "' (forest/landfill/industrial/building).")
      return
    end
    sev = toSeverity(args[2])
  end
  local fire = CIV.Fire.igniteAt(point, sev, kind)
  if not fire then say("fire command failed.") end
end

local rescueKeys = { sarm = "SAR_MOUNTAIN", sars = "SAR_SEA",
                     medevac = "MEDEVAC", casevac = "CASEVAC" }
for word, key in pairs(rescueKeys) do
  commands[word] = function(args, point)
    if not CIV.Rescue then moduleMissing("rescue") return end
    if not CIV.Rescue.startEvent(key, { point = point, severity = toSeverity(args[1]) }) then
      say(word .. " command failed (check the position).")
    end
  end
end

commands.swat = function(args, point)
  if not CIV.SWAT then moduleMissing("police") return end
  if not CIV.SWAT.startScenario({ point = point, severity = toSeverity(args[1]) }) then
    say("swat command failed.")
  end
end

commands.chase = function(args, point)
  if not CIV.Police then moduleMissing("police") return end
  if not CIV.Police.startChase({ point = point, severity = toSeverity(args[1]) }) then
    say("chase command failed (no free crossroad in the police pool).")
  end
end

commands.recon = function(args, point)
  if not CIV.Recon then moduleMissing("aviation") return end
  if not CIV.Recon.start({ point = point, severity = toSeverity(args[1]) }) then
    say("recon command failed.")
  end
end

commands.vip = function(args, point)
  if not CIV.VIP then moduleMissing("aviation") return end
  if not CIV.VIP.start({ point = point, severity = toSeverity(args[1]) }) then
    say("vip command failed (needs at least 2 CIVIL VIP Pad zones).")
  end
end

commands.transfer = function(args, point)
  if not CIV.MedTransfer then moduleMissing("aviation") return end
  if not CIV.MedTransfer.start({ nearPoint = point,
      severity = toSeverity(args[1]) }) then
    say("transfer command failed (needs at least 2 CIVIL VIP Pad zones).")
  end
end

commands.convoy = function(args, _)
  if not (CIV.Convoy and CIV.Convoy.start) then moduleMissing("police") return end
  if not CIV.Convoy.start({ severity = toSeverity(args[1]) }) then
    say("convoy command failed (needs CIVIL Convoy Start and End zones, " ..
      "or the cap is reached).")
  end
end

commands.tour = function(args, point)
  if not CIV.Tour then moduleMissing("aviation") return end
  if not CIV.Tour.start({ point = point, severity = toSeverity(args[1]) }) then
    say("tour command failed (needs CIVIL VIP Pad and CIVIL Tourist Site zones).")
  end
end

commands.supply = function(args, point)
  if not CIV.SupplyDrop then moduleMissing("aviation") return end
  if not CIV.SupplyDrop.start({ point = point,
      severity = toSeverity(args[1]) }) then
    say("supply command failed (needs a free CIVIL Drop Zone).")
  end
end

commands.inspect = function(args, point)
  if not CIV.CoastGuard then moduleMissing("sea ops") return end
  if not CIV.CoastGuard.start({ point = point,
      severity = toSeverity(args[1]) }) then
    say("inspect command failed (no free merchant at sea).")
  end
end

commands.ship = function(_, _)
  if not CIV.SeaTraffic then moduleMissing("sea ops") return end
  if not CIV.SeaTraffic.spawn() then
    say("ship command failed (cap reached or missing sea zones).")
  end
end

commands.flight = function(_, _)
  if not CIV.AirTraffic then moduleMissing("air traffic") return end
  if not CIV.AirTraffic.spawn() then
    say("flight command failed (cap reached or fewer than 2 airports).")
  end
end

commands.cargo = function(args, point)
  local tier = args[1] and string.upper(args[1])
  if tier and not C.cargo.tiers[tier] then
    say("unknown tier '" .. args[1] .. "' (light/medium/heavy/heavy_lift).")
    return
  end
  if not CIV.Cargo then moduleMissing("transport") return end
  if not CIV.Cargo.startPoint(tier, { point = point, priority = toSeverity(args[2]) }) then
    say("cargo command failed.")
  end
end

commands.spawn = function(args, point)
  if not args[1] then
    say("usage: " .. CMD.markerPrefix .. " spawn <template fragment> [count]")
    return
  end
  local tpl = findTemplate(args[1])
  if not tpl then
    say("no late-activated template matching '" .. args[1] .. "'.")
    return
  end
  local count = tonumber(args[2])
  local name = CIV.spawnFromTemplate(tpl.name, point, count and math.floor(count) or nil)
  if name then
    say("spawned '" .. tpl.name .. "' at the marker.")
  else
    say("spawn failed.")
  end
end

commands.move = function(args, point)
  if not args[1] then
    say("usage: " .. CMD.markerPrefix .. " move <group fragment> [speed] [road]")
    return
  end
  local grp, gname, category = findGroup(args[1])
  if not grp then
    say("no alive ME group matching '" .. args[1] .. "'.")
    return
  end
  if category == "plane" or category == "helicopter" then
    say("'" .. gname .. "' is an air group: move supports ground and ship groups only.")
    return
  end
  local speed = tonumber(args[2]) or CMD.moveSpeed
  local onRoad = false
  for _, a in ipairs(args) do
    if a == "road" then onRoad = true end
  end
  local wp = { x = point.x, y = point.z, type = "Turning Point", speed = speed }
  if category == "vehicle" or category == nil then
    wp.action = onRoad and "On Road" or "Off Road"
  end
  local ok = pcall(function()
    grp:getController():setTask({ id = "Mission", params = { route = { points = { wp } } } })
  end)
  say(ok and ("'" .. gname .. "' moving to the marker (" .. speed .. " m/s"
      .. (wp.action and (", " .. wp.action) or "") .. ").")
    or ("failed to task '" .. gname .. "'."))
end

commands.cancel = function(_, point)
  cancelNearest(point)
end

commands.director = function(args)
  if args[1] == "on" then
    C.director.enabled = true
    CIV.Command.pausedByCommand = false
    say("automatic director ENABLED.")
  elseif args[1] == "off" then
    C.director.enabled = false
    CIV.Command.pausedByCommand = true
    say("automatic director DISABLED: the command center is directing. " ..
      "Automatic mode resumes after " ..
      math.floor(CMD.autoResume.idleSeconds / 60) ..
      " minutes without commands.")
  else
    say("director is " .. (C.director.enabled and "ON" or "OFF") ..
      " (use: " .. CMD.markerPrefix .. " director on|off).")
  end
end

commands.help = function()
  say("marker commands:\n" ..
    CMD.markerPrefix .. " fire|sarm|sars|medevac|casevac|swat|chase|convoy|recon|vip|transfer|tour|supply|inspect [severity]\n" ..
    CMD.markerPrefix .. " ship  |  " .. CMD.markerPrefix .. " flight  (ambient traffic)\n" ..
    CMD.markerPrefix .. " cargo [tier] [priority]\n" ..
    CMD.markerPrefix .. " spawn <template> [count]  |  " ..
    CMD.markerPrefix .. " move <group> [speed] [road]\n" ..
    CMD.markerPrefix .. " cancel  |  " ..
    CMD.markerPrefix .. " director on|off")
end

----------------------------------------------------------------------
-- SESSION RECAP
-- Periodic situation summary for everyone, plus final standings when the
-- mission ends (also logged as FINAL| lines for tools/leaderboard.py).
----------------------------------------------------------------------

local function countTable(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local function topThree()
  local rows = {}
  for name, row in pairs(CIV.Score._board) do
    rows[#rows + 1] = { name = name, points = row.points, tasks = row.tasks }
  end
  table.sort(rows, function(a, b) return a.points > b.points end)
  return rows
end

if C.recap.enabled then
  CIV.schedule(function(_, t)
    local rescueCount = 0
    if CIV.Rescue then
      for _, sc in pairs(CIV.Rescue._scenarios) do
        rescueCount = rescueCount + countTable(sc.events)
      end
    end
    local txt = string.format(
      "=== SITUATION RECAP ===\nFires %d | Rescue %d | SWAT %d | Chases %d " ..
      "| Cargo %d | Recon %d | VIP %d",
      CIV.Fire and countTable(CIV.Fire.actives()) or 0, rescueCount,
      CIV.SWAT and countTable(CIV.SWAT._scenarios) or 0,
      CIV.Police and countTable(CIV.Police._chases) or 0,
      CIV.Cargo and countTable(CIV.Cargo._points) or 0,
      CIV.Recon and countTable(CIV.Recon._anomalies) or 0,
      CIV.VIP and countTable(CIV.VIP._jobs) or 0)
    local rows = topThree()
    if #rows > 0 then
      txt = txt .. "\nLeaders:"
      for i = 1, math.min(3, #rows) do
        txt = txt .. string.format("  %d. %s %d pts", i, rows[i].name, rows[i].points)
      end
    end
    CIV.msgAll(txt, 20)
    return t + C.recap.intervalSeconds
  end, nil, C.recap.intervalSeconds)

  local endHandler = {}
  function endHandler:onEvent(event)
    if event.id ~= world.event.S_EVENT_MISSION_END then return end
    -- protected like every other handler: an error here must not spill
    -- into the mission-end sequence
    local ok, err = pcall(function()
    local rows = topThree()
    local txt = "=== FINAL STANDINGS ===\n"
    for i, r in ipairs(rows) do
      txt = txt .. string.format("%d. %s  %d pts (%d tasks)\n", i, r.name, r.points, r.tasks)
      CIV.log(string.format("FINAL|%s|%d|%d", r.name, r.points, r.tasks))
      if i >= 10 then break end
    end
    if #rows > 0 then CIV.msgAll(txt, 30) end
    end)
    if not ok then CIV.log("Final standings error: " .. tostring(err)) end
  end
  world.addEventHandler(endHandler)
end

----------------------------------------------------------------------
-- NIGHT ASSIST (player F10 command, lives here because this file loads
-- last and can see every module's active events)
-- Pops an illumination flare over the nearest active objective. Night
-- only, per-player cooldown. Rescue subjects not yet identified by a
-- spotter get the flare on the APPROXIMATE search area, keeping the
-- intel model honest.
----------------------------------------------------------------------

local assistCooldown = {}   -- unitName -> last request time

local function nearestObjective(point)
  local NA = C.nightAssist
  local best, bestDist = nil, NA.searchRadius
  local function consider(p, label)
    if not p then return end
    local d = CIV.dist2D(p, point)
    if d < bestDist then best, bestDist = { point = p, label = label }, d end
  end
  if CIV.Fire then
    for _, fire in pairs(CIV.Fire.actives()) do
      consider(fire.point, fire.kindDef.name .. " at " .. fire.pt.name)
    end
  end
  if CIV.Rescue then
    for _, sc in pairs(CIV.Rescue._scenarios) do
      for _, evt in pairs(sc.events) do
        if evt.identified then
          consider(evt.point, sc.def.label .. " #" .. evt.id)
        else
          consider(evt.approxCenter, sc.def.label .. " #" .. evt.id ..
            " search area (not identified)")
        end
      end
    end
  end
  if CIV.SWAT then
    for _, scen in pairs(CIV.SWAT._scenarios) do
      consider(scen.pt.point, "SWAT objective at " .. scen.pt.name)
    end
  end
  if CIV.Cargo then
    for _, pt in pairs(CIV.Cargo._points) do
      consider(pt.pt.point, "cargo pickup at " .. pt.pt.name)
    end
  end
  if CIV.Police then
    for _, chase in pairs(CIV.Police._chases) do
      local g = Group.getByName(chase.gname)
      local u = g and g:getUnit(1)
      if u and u:isExist() then
        consider(u:getPoint(), "fleeing vehicle (chase #" .. chase.id .. ")")
      end
    end
  end
  return best, bestDist
end

local function nightAssist(uname)
  local NA = C.nightAssist
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  if not CIV.isNight() then
    CIV.msgUnit(u, "Illumination assist is available at night only.", 10)
    return
  end
  local now = timer.getTime()
  if assistCooldown[uname] and now - assistCooldown[uname] < NA.cooldownSeconds then
    CIV.msgUnit(u, "Illumination assist recharging: " ..
      math.ceil(NA.cooldownSeconds - (now - assistCooldown[uname])) .. " s left.", 10)
    return
  end
  local p = u:getPoint()
  local best, dist = nearestObjective(p)
  if not best then
    CIV.msgUnit(u, "No active objective within " ..
      math.floor(NA.searchRadius / 1000) .. " km.", 10)
    return
  end
  assistCooldown[uname] = now
  local ip = { x = best.point.x,
               y = CIV.groundY(best.point) + NA.heightAGL,
               z = best.point.z }
  local ok = pcall(trigger.action.illuminationBomb, ip, NA.power)
  if not ok then pcall(trigger.action.illuminationBomb, ip) end
  CIV.msgUnit(u, string.format(
    "Illumination flare over %s: bearing %03d, %.1f km.",
    best.label, CIV.bearingDeg(p, best.point), dist / 1000), 15)
end
CIV.Command.nightAssist = nightAssist

CIV.Menu_register(function(gid, uname)
  if not C.nightAssist.enabled then return end
  missionCommands.addCommandForGroup(gid,
    "Request illumination on nearest objective (night)",
    CIV.rootMenu[gid], nightAssist, uname)
end)

----------------------------------------------------------------------
-- MARKER EVENT HANDLER
-- Commands are parsed from S_EVENT_MARK_ADDED / S_EVENT_MARK_CHANGE
-- (the CHANGE event covers text typed after placing the mark). Each
-- mark id + text pair is executed once.
----------------------------------------------------------------------

local processed = {}   -- mark idx -> last executed text

local function onMark(event)
  if not (event.text and event.pos) then return end
  if processed[event.idx] == event.text then return end
  local text = string.lower(event.text)
  local rest = string.match(text, "^%s*" .. CMD.markerPrefix .. "%s+(.+)$")
  if not rest then return end
  processed[event.idx] = event.text
  if not allowed(event) then
    say("command refused: player not authorized.")
    return
  end
  local args = {}
  for token in string.gmatch(rest, "%S+") do args[#args + 1] = token end
  local cmd = table.remove(args, 1)
  local point = { x = event.pos.x, y = event.pos.y or 0, z = event.pos.z }
  local handler = commands[cmd]
  if not handler then
    say("unknown command '" .. tostring(cmd) .. "' (try: " ..
      CMD.markerPrefix .. " help).")
    return
  end
  CIV.log("Command marker: " .. event.text)
  CIV.Command.lastCommandTime = timer.getTime()   -- commander activity signal
  local ok, err = pcall(handler, args, point)
  if not ok then say("command error: " .. tostring(err)) end
  if CMD.removeMarks then
    local idx = event.idx
    CIV.schedule(function() pcall(trigger.action.removeMark, idx) end, nil, 2)
  end
end

if CMD.enabled then
  local markHandler = {}
  function markHandler:onEvent(event)
    if event.id == world.event.S_EVENT_MARK_ADDED
       or event.id == world.event.S_EVENT_MARK_CHANGE then
      local ok, err = pcall(onMark, event)
      if not ok then CIV.log("Marker command error: " .. tostring(err)) end
    end
  end
  world.addEventHandler(markHandler)

  -- Watchdog: if the commander paused the director and then went quiet
  -- (left the slot, disconnected), the mission falls back to automatic
  -- mode. Only fires on command-issued pauses: a director disabled in the
  -- config stays disabled.
  CIV.schedule(function(_, t)
    local ar = CMD.autoResume
    if ar.enabled and CIV.Command.pausedByCommand and not C.director.enabled
       and timer.getTime() - (CIV.Command.lastCommandTime or 0) > ar.idleSeconds then
      C.director.enabled = true
      CIV.Command.pausedByCommand = false
      say("no command activity for " .. math.floor(ar.idleSeconds / 60) ..
        " minutes: resuming AUTOMATIC mode.")
    end
    return t + 60
  end, nil, 60)

  CIV.log("CivilCommand loaded: marker prefix '" .. CMD.markerPrefix .. "'")
else
  CIV.log("CivilCommand disabled by config")
end
