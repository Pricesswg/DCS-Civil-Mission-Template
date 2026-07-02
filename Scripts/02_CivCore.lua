--[[
  02_CivCore.lua — Utility condivise: log, vettori, zone, registro giocatori,
  messaggistica, menu F10, marker. Lua puro nativo DCS.
]]

CIV = CIV or {}
local C = CIV.Config

------------------------------------------------------------------
-- Log
------------------------------------------------------------------
function CIV.log(msg)
  env.info("[CIV] " .. tostring(msg))
end
function CIV.dbg(msg)
  if C.debug then env.info("[CIV:DBG] " .. tostring(msg)) end
end

-- Wrapper pcall per le funzioni schedulate: un errore in un modulo non deve
-- uccidere lo scheduler degli altri (principio eventi paralleli).
function CIV.protect(fn)
  return function(arg, t)
    local ok, res = pcall(fn, arg, t)
    if not ok then
      CIV.log("ERRORE schedulato: " .. tostring(res))
      return t and (t + 10) or nil   -- riprova tra 10s invece di morire
    end
    return res
  end
end

function CIV.schedule(fn, arg, delay)
  return timer.scheduleFunction(CIV.protect(fn), arg, timer.getTime() + (delay or 1))
end

------------------------------------------------------------------
-- Matematica / geografia
------------------------------------------------------------------
function CIV.dist2D(a, b)
  local dx, dz = a.x - b.x, a.z - b.z
  return math.sqrt(dx * dx + dz * dz)
end

function CIV.speed(vel)
  return math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z)
end

-- Quota AGL di un punto vec3
function CIV.agl(p)
  return p.y - land.getHeight({ x = p.x, y = p.z })
end

-- Randomizzazione una-tantum: valore fissato all'inizio dell'evento (concept:
-- niente jitter continuo per tick).
function CIV.randBetween(range)
  return range.min + math.random() * (range.max - range.min)
end

function CIV.groundY(p)
  return land.getHeight({ x = p.x, y = p.z })
end

function CIV.isWater(p)
  local st = land.getSurfaceType({ x = p.x, y = p.z })
  return st == land.SurfaceType.WATER or st == land.SurfaceType.SHALLOW_WATER
end

-- Zona ME per nome; nil se non esiste (pcall: getZone su nome mancante può lanciare)
function CIV.getZone(name)
  local ok, z = pcall(trigger.misc.getZone, name)
  if ok and z and z.point then return z end
  return nil
end

function CIV.inZone(p, zone)
  return CIV.dist2D(p, zone.point) <= zone.radius
end

------------------------------------------------------------------
-- Registro giocatori (S_EVENT_BIRTH: copre anche i cambi slot in MP)
------------------------------------------------------------------
CIV.players = {}          -- unitName -> {unitName, groupId, typeName, playerName, categoria}
CIV.tipiPresenti = {}     -- typeName -> true (per il gate heavy-lift, aggiornato su BIRTH)
CIV._menuBuilders = {}    -- funzioni chiamate per ogni nuovo gruppo giocatore
CIV._menuBuiltGroups = {} -- groupId -> true
CIV.rootMenu = {}         -- groupId -> path del sottomenu F10 "Missioni Civili"

function CIV.Menu_register(builder)
  table.insert(CIV._menuBuilders, builder)
end

local function registraGiocatore(unit)
  local ok, playerName = pcall(unit.getPlayerName, unit)
  if not ok or not playerName then return end
  local uname = unit:getName()
  local group = unit:getGroup()
  if not group then return end
  local gid  = group:getID()
  local desc = unit:getDesc()
  CIV.players[uname] = {
    unitName = uname, groupId = gid, typeName = unit:getTypeName(),
    playerName = playerName, categoria = desc.category,
  }
  CIV.tipiPresenti[unit:getTypeName()] = true
  CIV.dbg("Giocatore registrato: " .. playerName .. " su " .. unit:getTypeName())
  if not CIV._menuBuiltGroups[gid] then
    CIV._menuBuiltGroups[gid] = true
    CIV.rootMenu[gid] = missionCommands.addSubMenuForGroup(gid, "Missioni Civili")
    for _, builder in ipairs(CIV._menuBuilders) do
      local ok2, err = pcall(builder, gid, uname)
      if not ok2 then CIV.log("Errore costruzione menu: " .. tostring(err)) end
    end
  end
end

local eventHandler = {}
function eventHandler:onEvent(event)
  if event.id == world.event.S_EVENT_BIRTH and event.initiator then
    local ok, err = pcall(registraGiocatore, event.initiator)
    if not ok then CIV.dbg("BIRTH scartato: " .. tostring(err)) end
  end
end
world.addEventHandler(eventHandler)

-- Pulizia periodica del registro (slot abbandonati)
CIV.schedule(function(_, t)
  for uname, info in pairs(CIV.players) do
    local u = Unit.getByName(uname)
    local ok, pn = pcall(function() return u and u:getPlayerName() end)
    if not u or not ok or not pn then CIV.players[uname] = nil end
  end
  return t + 30
end, nil, 30)

-- Itera i soli elicotteri pilotati da giocatori (uso: HoverZoneTrigger.watch)
function CIV.forEachPlayerHelo(fn)
  for uname, info in pairs(CIV.players) do
    if info.categoria == Unit.Category.HELICOPTER then
      local u = Unit.getByName(uname)
      if u and u:isExist() then fn(u, info) end
    end
  end
end

function CIV.forEachPlayer(fn)
  for uname, info in pairs(CIV.players) do
    local u = Unit.getByName(uname)
    if u and u:isExist() then fn(u, info) end
  end
end

------------------------------------------------------------------
-- Messaggistica
------------------------------------------------------------------
function CIV.msgUnit(unit, text, dur)
  local group = unit.getGroup and unit:getGroup()
  if group then
    trigger.action.outTextForGroup(group:getID(), text, dur or 15)
  end
end

function CIV.msgGroupId(gid, text, dur)
  trigger.action.outTextForGroup(gid, text, dur or 15)
end

function CIV.msgAll(text, dur)
  trigger.action.outTextForCoalition(C.coalition, text, dur or 15)
end

------------------------------------------------------------------
-- Marker F10 (spotter, punti attivi)
------------------------------------------------------------------
CIV._markId = 1000
function CIV.mark(text, p)
  CIV._markId = CIV._markId + 1
  trigger.action.markToCoalition(CIV._markId, text, p, C.coalition, false)
  return CIV._markId
end
function CIV.unmark(id)
  if id then trigger.action.removeMark(id) end
end

------------------------------------------------------------------
-- Coordinate leggibili (fallback quando il beacon non è utilizzabile)
------------------------------------------------------------------
function CIV.llString(p)
  local lat, lon = coord.LOtoLL(p)
  local function fmt(v, pos, neg)
    local h = v >= 0 and pos or neg
    v = math.abs(v)
    local d = math.floor(v)
    local m = (v - d) * 60
    return string.format("%s %d° %05.2f'", h, d, m)
  end
  return fmt(lat, "N", "S") .. "  " .. fmt(lon, "E", "W")
end

------------------------------------------------------------------
-- Spawn helper nativi
------------------------------------------------------------------
CIV._spawnIdx = 0
function CIV.uniqueName(prefix)
  CIV._spawnIdx = CIV._spawnIdx + 1
  return string.format("%s_%d_%d", prefix, CIV._spawnIdx, math.floor(timer.getTime()))
end

-- Gruppo di fanteria via coalition.addGroup (nativo; vedi concept: i task
-- embark/disembark sono AI-to-AI e non adatti al gameplay pilotato)
function CIV.spawnInfantry(p, count, tipo, namePrefix)
  local gname = CIV.uniqueName(namePrefix or "CIV_INF")
  local units = {}
  for i = 1, count do
    local ang = (i / count) * 2 * math.pi
    units[i] = {
      type = tipo, name = gname .. "_" .. i,
      x = p.x + math.cos(ang) * 3, y = p.z + math.sin(ang) * 3,
      heading = 0, skill = "Average", playerCanDrive = false,
    }
  end
  local groupData = {
    visible = false, lateActivation = false, task = "Ground Nothing",
    name = gname, units = units,
    route = { points = { { x = p.x, y = p.z, type = "Turning Point",
                           action = "Off Road", speed = 0 } } },
  }
  coalition.addGroup(C.countryId, Group.Category.GROUND, groupData)
  return gname
end

-- Nave/imbarcazione singola (SAR mare)
function CIV.spawnBoat(p, tipo, namePrefix)
  local gname = CIV.uniqueName(namePrefix or "CIV_BOAT")
  local groupData = {
    visible = false, lateActivation = false,
    name = gname,
    units = { { type = tipo, name = gname .. "_1", x = p.x, y = p.z,
                heading = 0, skill = "Average" } },
    route = { points = { { x = p.x, y = p.z, type = "Turning Point", speed = 0 } } },
  }
  coalition.addGroup(C.countryId, Group.Category.SHIP, groupData)
  return gname
end

-- Static Cargo con massa nativa (campi mass/canCargo di coalition.addStaticObject).
-- NB: alcuni tipi cargo hanno massa fissa e ignorano 'mass' -> tipo da validare in ME.
function CIV.spawnCargo(p, tipo, kg, namePrefix)
  local name = CIV.uniqueName(namePrefix or "CIV_CARGO")
  coalition.addStaticObject(C.countryId, {
    category = "Cargos", type = tipo, name = name,
    x = p.x, y = p.z, heading = 0,
    mass = kg, canCargo = true,
  })
  return name
end

function CIV.despawnGroup(gname)
  local g = Group.getByName(gname)
  if g then g:destroy() end
end

function CIV.despawnStatic(sname)
  local s = StaticObject.getByName(sname)
  if s then s:destroy() end
end

CIV.log("CivCore " .. CIV.VERSION .. " caricato")
