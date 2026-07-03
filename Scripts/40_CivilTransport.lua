----------------------------------------------------------------------
-- DCS Civil Mission Template — Civil Cargo Transport (mass tiers)
-- File: 40_CivilTransport.lua  (requires 01_CivilCore.lua)
--
--   - Fixed mass tiers LIGHT/MEDIUM/HEAVY + HEAVY_LIFT: objective masses
--     (kg in config), never rescaled to whoever lifts them.
--   - Heavy-lift gate: the HEAVY_LIFT tier is generated only if a type
--     with capacity >= threshold is present in the mission (tracked via
--     S_EVENT_BIRTH in CIV.typesPresent: covers MP slot changes).
--   - Arrival WARNING (not a block) if the player's type is not suited to
--     the tier, from the same type->capacity table used by the gate.
--   - Tier change via F10 with a delay (despawn + respawn: cargo mass is
--     not editable at runtime — verified).
--   - Native mass: mass/canCargo fields of coalition.addStaticObject.
--     WARNING: some cargo types have a fixed mass -> validate the
--     configured types in the Mission Editor.
----------------------------------------------------------------------

assert(CIV and CIV.VERSION, "01_CivilCore.lua must be loaded first")

local C = CIV.Config
local CC = C.cargo

CIV.Cargo = { _points = {}, _pid = 0 }
local CG = CIV.Cargo

----------------------------------------------------------------------
-- HEAVY-LIFT GATE + TIER SELECTION
----------------------------------------------------------------------

local function heavyLiftPresent()
  for typeName in pairs(CIV.typesPresent) do
    local cap = C.capacity[typeName]
    if cap and cap >= CC.heavyLiftMinKg then return true end
  end
  return false
end

local function randomTier()
  if heavyLiftPresent() and math.random(100) <= 15 then return "HEAVY_LIFT" end
  local total = 0
  for _, w in pairs(CC.tierWeights) do total = total + w end
  local r, acc = math.random(total), 0
  for tier, w in pairs(CC.tierWeights) do
    acc = acc + w
    if r <= acc then return tier end
  end
  return "MEDIUM"
end

----------------------------------------------------------------------
-- ACTIVE LOADING POINTS
----------------------------------------------------------------------

function CG.startPoint(forcedTier)
  local n = 0
  for _ in pairs(CG._points) do n = n + 1 end
  if n >= CC.maxActive then return nil end

  local pt = CIV.Pool.pick(C.zones.cargoPoints, 800)
  if not pt then return nil end

  local tier = forcedTier or randomTier()
  CG._pid = CG._pid + 1
  local point = {
    id = CG._pid, pt = pt, tier = tier,
    cargoName = CIV.spawnCargo(pt.point, CC.tiers[tier].cargoType,
      CC.tiers[tier].kg, "CIVIL_TRANSPORT"),
    spawnPos = { x = pt.point.x, y = pt.point.y, z = pt.point.z },
    warned = {}, changing = false,
  }
  CG._points[point.id] = point
  CIV.Pool.occupy(pt)
  CIV.msgAll(string.format(
    "TRANSPORT: %s load (%d kg) available at %s\n%s\nDestination: %s",
    tier, CC.tiers[tier].kg, pt.name, CIV.coordText(pt.point),
    C.zones.cargoDestination), 25)
  return point
end

----------------------------------------------------------------------
-- ARRIVAL WARNING (advice, not a block)
----------------------------------------------------------------------

CIV.schedule(function(_, t)
  for _, point in pairs(CG._points) do
    CIV.forEachPlayerHelo(function(u, info)
      if point.warned[info.unitName] then return end
      if CIV.dist2D(u:getPoint(), point.pt.point) <= CC.warnRadius then
        point.warned[info.unitName] = true
        local cap = C.capacity[info.typeName]
        local kg = CC.tiers[point.tier].kg
        if cap and cap < kg then
          CIV.msgUnit(u, string.format(
            "WARNING: the load at %s is %s (%d kg), above the estimated " ..
            "capacity of your %s (%d kg). It requires a heavier aircraft, " ..
            "or change the tier via F10 (cost: %ds).",
            point.pt.name, point.tier, kg, info.typeName, cap, CC.tierChangeDelay), 20)
        elseif not cap then
          CIV.msgUnit(u, "Type " .. info.typeName ..
            " missing from the capacity table: update CIV.Config.capacity.", 15)
        end
      end
    end)
  end
  return t + 5
end, nil, 15)

----------------------------------------------------------------------
-- TIER CHANGE VIA F10 (free in both directions, with a real cost)
----------------------------------------------------------------------

local function nearbyPoint(u)
  local p = u:getPoint()
  for _, point in pairs(CG._points) do
    if CIV.dist2D(p, point.pt.point) <= CC.warnRadius then return point end
  end
  return nil
end

local function changeTier(args)
  local uname, tier = args[1], args[2]
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  local point = nearbyPoint(u)
  if not point then
    CIV.msgUnit(u, "No loading point nearby.", 10)
    return
  end
  if point.changing then
    CIV.msgUnit(u, "Re-rigging already in progress at this point.", 10)
    return
  end
  if point.tier == tier then
    CIV.msgUnit(u, "The load is already " .. tier .. ".", 10)
    return
  end
  if tier == "HEAVY_LIFT" and not heavyLiftPresent() then
    CIV.msgUnit(u, "HEAVY_LIFT tier unavailable: no heavy-lift aircraft in the mission.", 10)
    return
  end
  point.changing = true
  CIV.despawnStatic(point.cargoName)
  CIV.msgUnit(u, "Re-rigging the load to " .. tier .. ": ready in " ..
    CC.tierChangeDelay .. " seconds.", 12)
  CIV.schedule(function()
    if not CG._points[point.id] then return end   -- point closed meanwhile
    point.tier = tier
    point.cargoName = CIV.spawnCargo(point.pt.point, CC.tiers[tier].cargoType,
      CC.tiers[tier].kg, "CIVIL_TRANSPORT")
    point.changing = false
    point.warned = {}
    CIV.msgAll("TRANSPORT: load at " .. point.pt.name .. " re-rigged to " ..
      tier .. " (" .. CC.tiers[tier].kg .. " kg).", 12)
  end, nil, CC.tierChangeDelay)
end

----------------------------------------------------------------------
-- DELIVERY
-- The (slung) cargo arrives inside the destination zone. Detected by
-- polling the cargo position — slung-object behavior TO TEST in-game.
----------------------------------------------------------------------

CIV.schedule(function(_, t)
  local dest = CIV.Zones.byName(C.zones.cargoDestination)
  if not dest then return t + 60 end
  for id, point in pairs(CG._points) do
    if point.cargoName and not point.changing then
      local s = StaticObject.getByName(point.cargoName)
      if not s then
        -- cargo destroyed (dropped/broken): event closed without points
        CIV.msgAll("TRANSPORT: load at " .. point.pt.name .. " LOST.", 12)
        CIV.Pool.release(point.pt)
        CG._points[id] = nil
      else
        local p = s:getPoint()
        if CIV.Zones.contains(dest, p) and CIV.agl(p) < 5
           and CIV.dist2D(p, point.spawnPos) > 500 then
          -- delivered: credit the closest player helicopter
          local closest, minDist = nil, 1e9
          CIV.forEachPlayerHelo(function(u, info)
            local d = CIV.dist2D(u:getPoint(), p)
            if d < minDist then minDist, closest = d, info end
          end)
          CIV.msgAll("TRANSPORT: " .. point.tier .. " load delivered to " ..
            C.zones.cargoDestination .. "!", 15)
          if closest and minDist < 500 then
            CIV.Score.award(closest.playerName, "transport", 0.8, 0.5,
              C.score.tierMult[point.tier], point.tier .. " transport")
          end
          CIV.despawnStatic(point.cargoName)
          CIV.Pool.release(point.pt)
          CG._points[id] = nil
        end
      end
    end
  end
  return t + 3
end, nil, 20)

----------------------------------------------------------------------
-- F10 MENU + EVENT STARTER
----------------------------------------------------------------------

CIV.Menu_register(function(gid, uname)
  local sub = missionCommands.addSubMenuForGroup(gid, "Cargo transport", CIV.rootMenu[gid])
  local changeSub = missionCommands.addSubMenuForGroup(gid, "Change tier of nearby point", sub)
  for _, tier in ipairs({ "LIGHT", "MEDIUM", "HEAVY", "HEAVY_LIFT" }) do
    missionCommands.addCommandForGroup(gid,
      tier .. " (" .. CC.tiers[tier].kg .. " kg)", changeSub, changeTier, { uname, tier })
  end
  missionCommands.addCommandForGroup(gid, "Active loading points", sub, function()
    local n, txt = 0, "Active loading points:\n"
    for _, point in pairs(CG._points) do
      n = n + 1
      txt = txt .. string.format("- %s: %s (%d kg)  %s\n", point.pt.name,
        point.tier, CC.tiers[point.tier].kg, CIV.llString(point.pt.point))
    end
    CIV.msgGroupId(gid, n > 0 and txt or "No active loading points.", 20)
  end)
end)

CIV.EventStarters.transport = { label = "Transport point", fn = CG.startPoint }

CIV.log("CivilTransport loaded")
