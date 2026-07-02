--[[
  20_SAR.lua — Motore SAR generico + istanze Montagna e Mare.
  (Logica frequenza/beacon ispirata al 527th_CSARSystem: qui ricreata in
  nativo puro perché quello script non è in questa repository.)

  Ciclo evento:
    spawn disperso su punto del pool -> (beacon radio opzionale, solo moduli
    con homing: Mi-8/UH-1H/SA342/AH-64D; fallback coordinate via messaggio e
    spotter C-130) -> estrazione via HoverZoneTrigger (watch: si aggancia al
    primo elicottero in inviluppo) -> despawn del disperso ("caricato a
    bordo") -> flag di stato sull'elicottero -> consegna in ospedale rilevata
    A ZONA (fermo/basso per X s dentro CIV_OSPEDALE_P##).

  NOTA VERIFICATA (concept): S_EVENT_LAND scatta solo su airbase/FARP/nave
  riconosciuti, NON su piazzole arbitrarie -> la consegna usa il rilevamento
  a zona, mai l'evento LAND.
]]

CIV = CIV or {}
CIV.SAR = { _scenari = {}, _aboard = {} }  -- _aboard: unitName -> lista soggetti
local SAR = CIV.SAR
local C = CIV.Config

--------------------------------------------------------------------
-- Soggetti a bordo (condiviso con MedEvac, vedi 50_MedEvac.lua)
--------------------------------------------------------------------
function SAR.aboardList(uname)
  SAR._aboard[uname] = SAR._aboard[uname] or {}
  return SAR._aboard[uname]
end

function SAR.board(uname, soggetto)
  table.insert(SAR.aboardList(uname), soggetto)
end

--------------------------------------------------------------------
-- Definizione scenario
-- def = { key, label, poolPrefix, regione, maxAttivi, unita={tipo,categoria},
--         beacon={abilitato,...}, scoreType, hoverCfg, deadline (s, opz.),
--         qualityFn(sogg, session) opz. }
--------------------------------------------------------------------
function SAR.newScenario(def)
  local sc = { def = def, eventi = {}, _eid = 0 }
  SAR._scenari[def.key] = sc
  return sc
end

local function spawnSoggetto(sc, pt)
  local def = sc.def
  local gname
  if def.unita.categoria == "ship" then
    gname = CIV.spawnBoat(pt.point, def.unita.tipo, "CIV_" .. def.key)
  else
    gname = CIV.spawnInfantry(pt.point, 1, def.unita.tipo, "CIV_" .. def.key)
  end
  return gname
end

local function avviaBeacon(def, evt)
  local b = def.beacon
  if not (b and b.abilitato) then return end
  -- Richiede il file .ogg dentro la .miz; homing solo su alcuni moduli
  -- (segnalato come ostico nel concept: testare presto)
  evt.beaconName = "CIV_BCN_" .. def.key .. "_" .. evt.id
  local ok, err = pcall(trigger.action.radioTransmission,
    b.file, evt.point, b.modulation or 1, true, b.freqHz, b.power or 100, evt.beaconName)
  if not ok then
    CIV.log("Beacon fallito (" .. tostring(err) .. "): fallback coordinate testuali")
    evt.beaconName = nil
  end
end

local function fermaBeacon(evt)
  if evt.beaconName then
    pcall(trigger.action.stopRadioTransmission, evt.beaconName)
    evt.beaconName = nil
  end
end

local function chiudiEvento(sc, evt)
  sc.eventi[evt.id] = nil
  CIV.Pool.release(evt.pt)
  fermaBeacon(evt)
  if evt.markId then CIV.unmark(evt.markId) end
  if evt.gname then CIV.despawnGroup(evt.gname) end
end

function SAR.startEvent(key)
  local sc = SAR._scenari[key]
  if not sc then return nil end
  local def = sc.def
  local n = 0
  for _ in pairs(sc.eventi) do n = n + 1 end
  if n >= def.maxAttivi then return nil end

  local pt = CIV.Pool.pick(def.poolPrefix, 1000)
  if not pt then
    CIV.dbg("SAR " .. key .. ": nessun punto disponibile nel pool " .. def.poolPrefix)
    return nil
  end

  sc._eid = sc._eid + 1
  local evt = {
    id = sc._eid, pt = pt, point = pt.point,
    spawnTime = timer.getTime(),
    deadline = def.deadline and (timer.getTime() + def.deadline) or nil,
  }
  evt.gname = spawnSoggetto(sc, pt)
  avviaBeacon(def, evt)
  sc.eventi[evt.id] = evt
  CIV.Pool.occupy(pt)

  local msg = def.label .. ": soggetto da recuperare.\nCoordinate: " ..
    CIV.llString(evt.point)
  if evt.beaconName then
    msg = msg .. string.format("\nBeacon attivo su %.3f MHz", sc.def.beacon.freqHz / 1e6)
  end
  CIV.msgAll(msg, 25)

  -- Estrazione: watch hover sul punto (si aggancia al primo elicottero valido)
  local hp = def.hoverCfg
  evt.watch = CIV.Hover.watch({
    center = evt.point, label = def.label .. " - estrazione",
    radius = hp.radius, minAGL = hp.minAGL, maxAGL = hp.maxAGL,
    maxSpeed = hp.maxSpeed, T = hp.T, window = hp.window, B = hp.B,
    onSuccess = function(unit, session)
      -- despawn = caricato a bordo; alla consegna basta consumare il flag
      CIV.despawnGroup(evt.gname)
      evt.gname = nil
      fermaBeacon(evt)
      local uname = unit:getName()
      SAR.board(uname, {
        scenario = def.key, scoreType = def.scoreType, label = def.label,
        evt = evt, session = session,
        quality = def.qualityFn and def.qualityFn(evt, session)
                  or CIV.Score.hoverQuality(session),
        timeFactor = CIV.Score.hoverTimeFactor(session),
      })
      sc.eventi[evt.id] = nil
      CIV.Pool.release(evt.pt)
      if evt.markId then CIV.unmark(evt.markId) end
      CIV.msgUnit(unit, def.label .. ": soggetto A BORDO. Portalo su una " ..
        "piazzola ospedale (zone " .. C.zone.ospedalePool .. "##) e resta " ..
        "fermo e basso per " .. C.medevac.consegna.tempo .. " secondi.", 20)
    end,
    onFail = function(reason)
      CIV.msgAll(def.label .. ": recupero FALLITO in zona " .. pt.name ..
        " (finestra scaduta). Il soggetto non ce l'ha fatta.", 20)
      chiudiEvento(sc, evt)
    end,
  })
  CIV.log("SAR " .. key .. " evento #" .. evt.id .. " su " .. pt.name)
  return evt
end

--------------------------------------------------------------------
-- Consegna in ospedale: rilevamento a zona (fermo/basso per X secondi)
--------------------------------------------------------------------
local consegnaTimer = {}   -- unitName -> t inizio permanenza valida

CIV.schedule(function(_, t)
  local cd = C.medevac.consegna
  local now = timer.getTime()
  for uname, lista in pairs(SAR._aboard) do
    if #lista > 0 then
      local u = Unit.getByName(uname)
      if u and u:isExist() then
        local p = u:getPoint()
        local inOspedale = false
        for _, pt in ipairs(CIV.Pool.load(C.zone.ospedalePool)) do
          if CIV.dist2D(p, pt.point) <= math.max(pt.radius, cd.raggio) then
            inOspedale = true
            break
          end
        end
        local fermoBasso = CIV.speed(u:getVelocity()) <= cd.maxSpeed
          and CIV.agl(p) <= cd.maxAGL
        if inOspedale and fermoBasso then
          consegnaTimer[uname] = consegnaTimer[uname] or now
          if now - consegnaTimer[uname] >= cd.tempo then
            consegnaTimer[uname] = nil
            local info = CIV.players[uname]
            for _, sogg in ipairs(lista) do
              -- deadline (criticità MedEvac): se scaduta, il soggetto è deceduto
              if sogg.evt.deadline and now > sogg.evt.deadline then
                CIV.msgUnit(u, sogg.label .. ": il soggetto e' deceduto prima " ..
                  "della consegna.", 15)
              elseif info then
                CIV.Score.award(info.playerName, sogg.scoreType,
                  sogg.quality, sogg.timeFactor, 1, sogg.label)
              end
            end
            SAR._aboard[uname] = {}
            CIV.msgUnit(u, "Consegna in ospedale completata.", 15)
          end
        else
          consegnaTimer[uname] = nil
        end
      end
    end
  end
  return t + 2
end, nil, 10)

--------------------------------------------------------------------
-- Deadline a bordo (MedEvac): notifica se il soggetto decade in volo
--------------------------------------------------------------------
CIV.schedule(function(_, t)
  local now = timer.getTime()
  for uname, lista in pairs(SAR._aboard) do
    for _, sogg in ipairs(lista) do
      if sogg.evt.deadline and not sogg.notificatoDecesso and now > sogg.evt.deadline then
        sogg.notificatoDecesso = true
        local u = Unit.getByName(uname)
        if u then CIV.msgUnit(u, sogg.label .. ": criticita' esaurita, il " ..
          "paziente e' deceduto a bordo.", 15) end
      end
    end
  end
  return t + 10
end, nil, 20)

--------------------------------------------------------------------
-- Spotter C-130/aereo in regione: rilancia coordinate degli eventi attivi
--------------------------------------------------------------------
CIV.schedule(function(_, t)
  for key, sc in pairs(SAR._scenari) do
    local regione = sc.def.regione and CIV.getZone(sc.def.regione)
    if regione then
      local spotter = nil
      CIV.forEachPlayer(function(u, info)
        if spotter then return end
        if info.categoria == Unit.Category.AIRPLANE and u:inAir()
           and CIV.inZone(u:getPoint(), regione) then
          spotter = info
        end
      end)
      if spotter then
        for _, evt in pairs(sc.eventi) do
          if not evt.markId then
            evt.markId = CIV.mark(sc.def.label .. " #" .. evt.id, evt.point)
          end
          CIV.msgAll("SPOTTER " .. spotter.playerName .. " (" .. sc.def.label ..
            "): soggetto a " .. CIV.llString(evt.point), 15)
        end
      end
    end
  end
  return t + C.fuoco.spotterIntervallo
end, nil, 45)

--------------------------------------------------------------------
-- Istanze: SAR Montagna e SAR Mare
--------------------------------------------------------------------
SAR.newScenario({
  key = "SARM", label = "SAR Montagna",
  poolPrefix = C.zone.sarMontPool, regione = C.zone.sarMontRegione,
  maxAttivi = C.sar.montagna.maxAttivi,
  unita = C.sar.montagna.unita, beacon = C.sar.montagna.beacon,
  scoreType = "sarMontagna", hoverCfg = C.hover.sarMontagna,
})

SAR.newScenario({
  key = "SARS", label = "SAR Mare",
  poolPrefix = C.zone.sarMarePool, regione = C.zone.sarMareRegione,
  maxAttivi = C.sar.mare.maxAttivi,
  -- unità navale su acqua aperta: caso d'uso standard DCS, rischio tecnico basso
  unita = C.sar.mare.unita, beacon = C.sar.mare.beacon,
  scoreType = "sarMare", hoverCfg = C.hover.sarMare,
})

CIV.log("SAR (Montagna+Mare) caricato")
