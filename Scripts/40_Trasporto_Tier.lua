--[[
  40_Trasporto_Tier.lua — Trasporto materiale civile a tier di massa fissi.
  - Tier LEGGERO/MEDIO/PESANTE + HEAVY: masse OGGETTIVE (kg in config), non
    ricalcolate sul mezzo che le solleva.
  - Gate heavy-lift: il tier HEAVY viene generato solo se in missione risulta
    presente almeno un tipo con capacità >= soglia (rilevato su S_EVENT_BIRTH
    via CIV.tipiPresenti: copre i cambi di slot in multiplayer).
  - Avviso (non blocco) all'arrivo sul punto se il mezzo non è adatto al tier.
  - Cambio tier via F10 con delay (despawn + respawn del Cargo: la massa non è
    modificabile a runtime, verificato nel concept).
  - Massa nativa: campi mass/canCargo di coalition.addStaticObject. ATTENZIONE:
    alcuni tipi cargo hanno massa fissa -> i tipi in config vanno validati in ME.
]]

CIV = CIV or {}
CIV.Cargo = { _punti = {}, _pid = 0 }
local CG = CIV.Cargo
local C  = CIV.Config
local CC = C.cargo

--------------------------------------------------------------------
-- Gate heavy-lift: capacità massima tra i tipi visti in missione
--------------------------------------------------------------------
local function heavyPresente()
  for tipo in pairs(CIV.tipiPresenti) do
    local cap = C.capacita[tipo]
    if cap and cap >= CC.sogliaHeavyKg then return true end
  end
  return false
end

local function tierRandom()
  if heavyPresente() and math.random(100) <= 15 then return "HEAVY" end
  local tot, r, acc = 0, 0, 0
  for _, w in pairs(CC.pesiTier) do tot = tot + w end
  r = math.random(tot)
  for tier, w in pairs(CC.pesiTier) do
    acc = acc + w
    if r <= acc then return tier end
  end
  return "MEDIO"
end

--------------------------------------------------------------------
-- Generazione punto di carico attivo
--------------------------------------------------------------------
function CG.startPoint(tierForzato)
  local n = 0
  for _ in pairs(CG._punti) do n = n + 1 end
  if n >= CC.maxAttivi then return nil end

  local pt = CIV.Pool.pick(C.zone.cargoPool, 800)
  if not pt then return nil end

  local tier = tierForzato or tierRandom()
  CG._pid = CG._pid + 1
  local punto = {
    id = CG._pid, pt = pt, tier = tier,
    cargoName = CIV.spawnCargo(pt.point, CC.tiers[tier].tipo, CC.tiers[tier].kg, "CIV_TRASP"),
    spawnPos = { x = pt.point.x, y = pt.point.y, z = pt.point.z },
    avvisati = {}, cambioInCorso = false,
  }
  CG._punti[punto.id] = punto
  CIV.Pool.occupy(pt)
  CIV.msgAll(string.format(
    "TRASPORTO: carico %s (%d kg) disponibile presso %s\nCoordinate: %s\nDestinazione: zona %s",
    tier, CC.tiers[tier].kg, pt.name, CIV.llString(pt.point), C.zone.cargoDest), 25)
  return punto
end

--------------------------------------------------------------------
-- Avviso all'arrivo: mezzo non adatto al tier (calcolato dalla stessa tabella
-- tipo->capacità usata per il gate). Avviso, NON blocco.
--------------------------------------------------------------------
CIV.schedule(function(_, t)
  for _, punto in pairs(CG._punti) do
    CIV.forEachPlayerHelo(function(u, info)
      if punto.avvisati[info.unitName] then return end
      if CIV.dist2D(u:getPoint(), punto.pt.point) <= CC.raggioAvviso then
        punto.avvisati[info.unitName] = true
        local cap = C.capacita[info.typeName]
        local kg = CC.tiers[punto.tier].kg
        if cap and cap < kg then
          CIV.msgUnit(u, string.format(
            "ATTENZIONE: il carico presso %s e' %s (%d kg), oltre la capacita' " ..
            "stimata del tuo %s (%d kg). Richiede un mezzo piu' pesante, oppure " ..
            "cambia tier via F10 (costo: %ds).",
            punto.pt.name, punto.tier, kg, info.typeName, cap, CC.delayCambioTier), 20)
        elseif not cap then
          CIV.msgUnit(u, "Tipo " .. info.typeName ..
            " non in tabella capacita': aggiornare CIV.Config.capacita.", 15)
        end
      end
    end)
  end
  return t + 5
end, nil, 15)

--------------------------------------------------------------------
-- Cambio tier via F10 (selezione libera in entrambe le direzioni),
-- con delay: despawn -> attesa -> respawn con la nuova massa
--------------------------------------------------------------------
local function puntoVicino(u)
  local p = u:getPoint()
  for _, punto in pairs(CG._punti) do
    if CIV.dist2D(p, punto.pt.point) <= CC.raggioAvviso then return punto end
  end
  return nil
end

local function cambiaTier(args)
  local uname, tier = args[1], args[2]
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  local punto = puntoVicino(u)
  if not punto then
    CIV.msgUnit(u, "Nessun punto di carico nelle vicinanze.", 10)
    return
  end
  if punto.cambioInCorso then
    CIV.msgUnit(u, "Riequipaggiamento gia' in corso su questo punto.", 10)
    return
  end
  if punto.tier == tier then
    CIV.msgUnit(u, "Il carico e' gia' di tier " .. tier .. ".", 10)
    return
  end
  if tier == "HEAVY" and not heavyPresente() then
    CIV.msgUnit(u, "Tier HEAVY non disponibile: nessun mezzo heavy-lift in missione.", 10)
    return
  end
  punto.cambioInCorso = true
  CIV.despawnStatic(punto.cargoName)
  CIV.msgUnit(u, "Riequipaggiamento del carico a tier " .. tier .. ": pronto tra " ..
    CC.delayCambioTier .. " secondi.", 12)
  CIV.schedule(function()
    if not CG._punti[punto.id] then return end   -- punto chiuso nel frattempo
    punto.tier = tier
    punto.cargoName = CIV.spawnCargo(punto.pt.point, CC.tiers[tier].tipo,
      CC.tiers[tier].kg, "CIV_TRASP")
    punto.cambioInCorso = false
    punto.avvisati = {}
    CIV.msgAll("TRASPORTO: carico presso " .. punto.pt.name ..
      " riconfigurato a " .. tier .. " (" .. CC.tiers[tier].kg .. " kg).", 12)
  end, nil, CC.delayCambioTier)
end

--------------------------------------------------------------------
-- Consegna: il cargo (slingato) arriva dentro la zona di destinazione.
-- Rilevamento via polling posizione del cargo — comportamento dell'oggetto
-- slingato DA TESTARE in-game (punto aperto del concept).
--------------------------------------------------------------------
CIV.schedule(function(_, t)
  local dest = CIV.getZone(C.zone.cargoDest)
  if not dest then return t + 60 end
  for id, punto in pairs(CG._punti) do
    if punto.cargoName and not punto.cambioInCorso then
      local s = StaticObject.getByName(punto.cargoName)
      if not s then
        -- cargo distrutto (caduto/rotto): evento chiuso senza punti
        CIV.msgAll("TRASPORTO: carico presso " .. punto.pt.name .. " PERSO.", 12)
        CIV.Pool.release(punto.pt)
        CG._punti[id] = nil
      else
        local p = s:getPoint()
        if CIV.inZone(p, dest) and CIV.agl(p) < 5
           and CIV.dist2D(p, punto.spawnPos) > 500 then
          -- consegnato: attribuzione al giocatore idoneo più vicino
          local migliore, distMin = nil, 1e9
          CIV.forEachPlayerHelo(function(u, info)
            local d = CIV.dist2D(u:getPoint(), p)
            if d < distMin then distMin, migliore = d, info end
          end)
          CIV.msgAll("TRASPORTO: carico " .. punto.tier .. " consegnato in zona " ..
            C.zone.cargoDest .. "!", 15)
          if migliore and distMin < 500 then
            CIV.Score.award(migliore.playerName, "trasporto", 0.8, 0.5,
              C.score.tierMult[punto.tier], "trasporto " .. punto.tier)
          end
          CIV.despawnStatic(punto.cargoName)
          CIV.Pool.release(punto.pt)
          CG._punti[id] = nil
        end
      end
    end
  end
  return t + 3
end, nil, 20)

--------------------------------------------------------------------
-- Menu F10: sottomenu cambio tier
--------------------------------------------------------------------
CIV.Menu_register(function(gid, uname)
  local sub = missionCommands.addSubMenuForGroup(gid, "Trasporto materiale", CIV.rootMenu[gid])
  local cambio = missionCommands.addSubMenuForGroup(gid, "Cambia tier del punto vicino", sub)
  for _, tier in ipairs({ "LEGGERO", "MEDIO", "PESANTE", "HEAVY" }) do
    missionCommands.addCommandForGroup(gid,
      tier .. " (" .. CC.tiers[tier].kg .. " kg)", cambio, cambiaTier, { uname, tier })
  end
  missionCommands.addCommandForGroup(gid, "Punti di carico attivi", sub, function()
    local n, txt = 0, "Punti di carico attivi:\n"
    for _, punto in pairs(CG._punti) do
      n = n + 1
      txt = txt .. string.format("- %s: %s (%d kg)  %s\n", punto.pt.name,
        punto.tier, CC.tiers[punto.tier].kg, CIV.llString(punto.pt.point))
    end
    CIV.msgGroupId(gid, n > 0 and txt or "Nessun punto di carico attivo.", 20)
  end)
end)

CIV.log("Trasporto_Tier caricato")
