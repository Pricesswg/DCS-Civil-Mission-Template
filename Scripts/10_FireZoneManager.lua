--[[
  10_FireZoneManager.lua — Gestione incendi.
  Accensione random tra i punti del pool CIV_FUOCO_P## (curati a mano in ME),
  effetto fumo/fuoco con trigger.action.effectSmokeBig / effectSmokeStop,
  stato attivo/spento PER ZONA (eventi paralleli).

  La crescita dell'intensità è randomizzata UNA volta all'accensione (concept:
  niente jitter per tick). L'estinzione avviene tramite CIV.Fire.applyWater,
  chiamata dai moduli elicottero (11) e C-130 (12).
]]

CIV = CIV or {}
CIV.Fire = { _fires = {}, _fid = 0 }
local F = CIV.Fire
local C = CIV.Config
local CF = C.fuoco

-- preset effectSmokeBig: 1..4 = fumo+fuoco S/M/L/XL, 5..8 = solo fumo
local function presetPerIntensita(int)
  if int >= 1.5 then return 4 elseif int >= 1.0 then return 3
  elseif int >= 0.5 then return 2 else return 1 end
end

function F.count()
  local n = 0
  for _ in pairs(F._fires) do n = n + 1 end
  return n
end

function F.actives() return F._fires end

--------------------------------------------------------------------
-- Accensione
--------------------------------------------------------------------
function F.ignite(pt)
  F._fid = F._fid + 1
  local fire = {
    id = F._fid, pt = pt,
    point = { x = pt.point.x, y = pt.point.y, z = pt.point.z },
    intensita = CF.intensitaInit,
    crescita  = CIV.randBetween(CF.crescitaOraria) / 3600,  -- fissata per tutta la durata
    smokeName = "CIV_FIRE_" .. F._fid,
    preset = 0, markId = nil, accensione = timer.getTime(),
  }
  fire.preset = presetPerIntensita(fire.intensita)
  trigger.action.effectSmokeBig(fire.point, fire.preset, 0.7, fire.smokeName)
  F._fires[fire.id] = fire
  CIV.Pool.occupy(pt)
  CIV.msgAll("INCENDIO segnalato in zona " .. pt.name ..
    "\nCoordinate: " .. CIV.llString(fire.point), 20)
  CIV.log("Incendio #" .. fire.id .. " acceso su " .. pt.name)
  return fire
end

function F.igniteRandom()
  if F.count() >= CF.maxAttivi then return nil end
  local pt = CIV.Pool.pick(C.zone.fuocoPool, 1000)
  if not pt then return nil end
  return F.ignite(pt)
end

--------------------------------------------------------------------
-- Estinzione / applicazione acqua-ritardante
-- point = dove è avvenuto lo sgancio; amount = riduzione intensità.
-- Ritorna il fuoco colpito (o nil). L'attribuzione punteggio è del chiamante.
--------------------------------------------------------------------
local function spegni(fire, autore)
  trigger.action.effectSmokeStop(fire.smokeName)
  if fire.markId then CIV.unmark(fire.markId) end
  CIV.Pool.release(fire.pt)
  F._fires[fire.id] = nil
  CIV.msgAll("Incendio in zona " .. fire.pt.name .. " SPENTO" ..
    (autore and (" da " .. autore) or "") .. ".", 15)
end

function F.applyWater(point, amount, autore)
  for _, fire in pairs(F._fires) do
    if CIV.dist2D(point, fire.point) <= CF.raggioSgancio then
      fire.intensita = fire.intensita - amount
      if fire.intensita <= 0 then
        spegni(fire, autore)
      else
        -- aggiorna l'effetto se il preset scende di taglia
        local p = presetPerIntensita(fire.intensita)
        if p ~= fire.preset then
          fire.preset = p
          trigger.action.effectSmokeStop(fire.smokeName)
          trigger.action.effectSmokeBig(fire.point, p, 0.7, fire.smokeName)
        end
      end
      return fire
    end
  end
  return nil
end

--------------------------------------------------------------------
-- Loop: crescita intensità + accensioni automatiche
--------------------------------------------------------------------
local prossimaAccensione = timer.getTime() + CIV.randBetween(CF.intervalloAvvio)

CIV.schedule(function(_, t)
  local now = timer.getTime()
  for _, fire in pairs(F._fires) do
    fire.intensita = math.min(2.0, fire.intensita + fire.crescita * 10)
    local p = presetPerIntensita(fire.intensita)
    if p ~= fire.preset then
      fire.preset = p
      trigger.action.effectSmokeStop(fire.smokeName)
      trigger.action.effectSmokeBig(fire.point, p, 0.7, fire.smokeName)
    end
  end
  if now >= prossimaAccensione then
    F.igniteRandom()
    prossimaAccensione = now + CIV.randBetween(CF.intervalloAvvio)
  end
  return t + 10
end, nil, 15)

CIV.log("FireZoneManager caricato")
