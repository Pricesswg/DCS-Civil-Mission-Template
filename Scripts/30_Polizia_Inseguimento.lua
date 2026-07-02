--[[
  30_Polizia_Inseguimento.lua — Inseguimento in città.
  Pool CIV_POL_P## piazzato sugli incroci reali (macro-regione ravvicinata).
  Percorso: random walk locale tra punti vicini con waypoint "On Road" per il
  pathfinding stradale nativo.

  ATTENZIONE (concept, verificato): "On Road" è un problema noto su più
  versioni (le unità possono deviare o bloccarsi). Watchdog incluso: se l'auto
  resta ferma troppo a lungo viene rilanciata sul prossimo punto; se si blocca
  di nuovo, fallback "Off Road".

  Cattura: pressione per-inseguimento che sale con l'elicottero nel raggio e
  decade quando lo si perde; rate randomizzati UNA volta a inizio evento.
]]

CIV = CIV or {}
CIV.Police = { _chases = {}, _cid = 0 }
local PL = CIV.Police
local C  = CIV.Config
local CP = C.polizia

--------------------------------------------------------------------
-- Percorso
--------------------------------------------------------------------
local function waypoint(pt, speed, action)
  return { x = pt.point.x, y = pt.point.z, type = "Turning Point",
           action = action or "On Road", speed = speed,
           ETA = 0, ETA_locked = false, speed_locked = true }
end

-- Prossimi hop col random walk locale (mai salti su tutta la mappa)
local function generaHop(daPunto, n, escludi)
  local hops, corrente, lastName = {}, daPunto, escludi
  for i = 1, n do
    local vicini = CIV.Pool.near(C.zone.poliziaPool, corrente.point, CP.raggioVicini, lastName)
    if #vicini == 0 then break end
    local nxt = vicini[math.random(#vicini)]
    hops[#hops + 1] = nxt
    lastName = corrente.name
    corrente = nxt
  end
  return hops
end

local function assegnaRotta(chase)
  local g = Group.getByName(chase.gname)
  if not g then return end
  local u = g:getUnit(1)
  if not u then return end
  local p = u:getPoint()
  local points = { { x = p.x, y = p.z, type = "Turning Point",
                     action = chase.roadAction, speed = chase.speed } }
  for _, pt in ipairs(chase.hops) do
    points[#points + 1] = waypoint(pt, chase.speed, chase.roadAction)
  end
  local ctrl = g:getController()
  ctrl:setTask({ id = "Mission", params = { route = { points = points } } })
end

--------------------------------------------------------------------
-- Avvio inseguimento
--------------------------------------------------------------------
function PL.startChase()
  local n = 0
  for _ in pairs(PL._chases) do n = n + 1 end
  if n >= CP.maxInseguimenti then return nil end

  local start = CIV.Pool.pick(C.zone.poliziaPool, 800)
  if not start then return nil end

  PL._cid = PL._cid + 1
  local gname = CIV.uniqueName("CIV_FUGGITIVO")
  coalition.addGroup(C.countryId, Group.Category.GROUND, {
    visible = false, lateActivation = false, task = "Ground Nothing",
    name = gname,
    units = { { type = CP.autoTipo, name = gname .. "_1",
                x = start.point.x, y = start.point.z,
                heading = math.random() * 2 * math.pi,
                skill = "Excellent", playerCanDrive = false } },
    route = { points = { waypoint(start, 10) } },
  })

  local chase = {
    id = PL._cid, gname = gname, startPt = start,
    -- randomizzazione UNA TANTUM: carattere riconoscibile dell'evento
    speed      = CIV.randBetween(CP.velocitaMax),
    rateUp     = CIV.randBetween(CP.rateSalita),
    rateDown   = CIV.randBetween(CP.rateDecad),
    pressione  = 0,           -- 0..100, stato PER inseguimento
    roadAction = "On Road",
    fermoDa = nil, rilanci = 0,
    hops = generaHop(start, CP.hopWaypoint, nil),
    lastPos = nil,
  }
  PL._chases[chase.id] = chase
  CIV.Pool.occupy(start)
  CIV.schedule(function() assegnaRotta(chase) end, nil, 2)

  CIV.msgAll("POLIZIA: veicolo in fuga segnalato presso " .. start.name ..
    "\nCoordinate: " .. CIV.llString(start.point) ..
    "\nMantieni il contatto visivo con l'elicottero per far salire la pressione.", 25)
  CIV.log("Inseguimento #" .. chase.id .. " avviato da " .. start.name)
  return chase
end

local function chiudi(chase, dopo)
  CIV.Pool.release(chase.startPt)
  PL._chases[chase.id] = nil
  local gname = chase.gname
  CIV.schedule(function() CIV.despawnGroup(gname) end, nil, dopo or 60)
end

--------------------------------------------------------------------
-- Loop: pressione + estensione rotta + watchdog "On Road"
--------------------------------------------------------------------
CIV.schedule(function(_, t)
  local now = timer.getTime()
  for _, chase in pairs(PL._chases) do
    local g = Group.getByName(chase.gname)
    local u = g and g:getUnit(1)
    if not u or not u:isExist() then
      chiudi(chase, 1)
    else
      local p = u:getPoint()

      -- pressione: elicottero giocatore nel raggio?
      local agganciato = false
      CIV.forEachPlayerHelo(function(h)
        if not agganciato and CIV.dist2D(h:getPoint(), p) <= CP.raggioPressione then
          agganciato = true
        end
      end)
      if agganciato then
        chase.pressione = math.min(100, chase.pressione + chase.rateUp * 2)  -- tick da 2s
      else
        chase.pressione = math.max(0, chase.pressione - chase.rateDown * 2)
      end

      if chase.pressione >= 100 then
        -- Arresto: la pattuglia a terra intercetta
        local ctrl = g:getController()
        pcall(function() ctrl:setTask({ id = "Hold", params = {} }) end)
        CIV.msgAll("POLIZIA: fuggitivo FERMATO e in arresto presso " ..
          CIV.llString(p), 20)
        local migliore = nil
        CIV.forEachPlayerHelo(function(h, info)
          if CIV.dist2D(h:getPoint(), p) <= CP.raggioPressione then migliore = info end
        end)
        if migliore then
          CIV.Score.award(migliore.playerName, "inseguimento", 0.8, 0.5, 1,
            "arresto fuggitivo")
        end
        chiudi(chase, 90)
      else
        -- estensione rotta quando l'auto si avvicina all'ultimo hop
        local last = chase.hops[#chase.hops]
        if last and CIV.dist2D(p, last.point) < 200 then
          chase.hops = generaHop(last, CP.hopWaypoint, chase.hops[#chase.hops - 1]
            and chase.hops[#chase.hops - 1].name or nil)
          assegnaRotta(chase)
        end

        -- watchdog: auto ferma da troppo (bug noto "On Road")
        if chase.lastPos and CIV.dist2D(p, chase.lastPos) < 5 then
          chase.fermoDa = chase.fermoDa or now
          if now - chase.fermoDa > 45 then
            chase.fermoDa = nil
            chase.rilanci = chase.rilanci + 1
            if chase.rilanci >= 2 then
              chase.roadAction = "Off Road"   -- fallback definitivo per questo evento
              CIV.dbg("Inseguimento #" .. chase.id .. ": fallback Off Road")
            end
            chase.hops = generaHop({ point = p, name = "corrente" }, CP.hopWaypoint, nil)
            assegnaRotta(chase)
            CIV.dbg("Inseguimento #" .. chase.id .. ": rilancio rotta (watchdog)")
          end
        else
          chase.fermoDa = nil
        end
        chase.lastPos = { x = p.x, y = p.y, z = p.z }
      end
    end
  end
  return t + 2
end, nil, 10)

CIV.log("Polizia_Inseguimento caricato")
