--[[
  12_Firefighting_C130.lua — Antincendio C-130 + ruolo spotter.
  Niente scooping in volo (compito dei Canadair): ricarica A TERRA nella zona
  CIV_C130_RIFORN (stato logico: in DCS non esiste un "ritardante" nativo) e
  rilascio in linea sorvolando l'area incendi a quota moderata (banda AGL in
  config, nominale 150-250 m).

  Spotter: qualunque C-130 (o aereo giocatore) dentro la macro-regione
  CIV_FUOCO_REGIONE riceve e trasmette periodicamente coordinate e marker F10
  degli incendi attivi alla coalizione.
]]

CIV = CIV or {}
CIV.FireC130 = { _stato = {} }  -- unitName -> { ritardante=bool, ricaricaDa=t, rilascio=nil|{fine=t} }
local FC = CIV.FireC130
local C  = CIV.Config
local CF = C.fuoco

local function stato(uname)
  FC._stato[uname] = FC._stato[uname] or { ritardante = false }
  return FC._stato[uname]
end

local function eAereo(info)
  return info.categoria == Unit.Category.AIRPLANE
end

--------------------------------------------------------------------
-- Ricarica a terra: fermo dentro la zona rifornimento per N secondi
--------------------------------------------------------------------
CIV.schedule(function(_, t)
  local zona = CIV.getZone(C.zone.c130Rifornimento)
  if not zona then return t + 60 end
  local now = timer.getTime()
  CIV.forEachPlayer(function(u, info)
    if not eAereo(info) then return end
    local st = stato(info.unitName)
    if st.ritardante then return end
    local p = u:getPoint()
    local fermo = (not u:inAir()) and CIV.speed(u:getVelocity()) < 1
    if fermo and CIV.inZone(p, zona) then
      if not st.ricaricaDa then
        st.ricaricaDa = now
        CIV.msgUnit(u, "Ricarica ritardante in corso: resta fermo " ..
          CF.ricaricaC130 .. " secondi.", 10)
      elseif now - st.ricaricaDa >= CF.ricaricaC130 then
        st.ricaricaDa = nil
        st.ritardante = true
        CIV.msgUnit(u, "Ritardante caricato. Rilascio: F10 -> Missioni Civili " ..
          "-> Antincendio C-130 -> Avvia rilascio in linea (quota " ..
          CF.quotaRilascio.min .. "-" .. CF.quotaRilascio.max .. " m AGL).", 15)
      end
    else
      st.ricaricaDa = nil
    end
  end)
  return t + 5
end, nil, 10)

--------------------------------------------------------------------
-- Rilascio in linea: per N secondi applica ritardante lungo la traiettoria
--------------------------------------------------------------------
local function avviaRilascio(uname)
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  local st = stato(uname)
  if not st.ritardante then
    CIV.msgUnit(u, "Nessun ritardante a bordo: ricarica a terra in zona " ..
      C.zone.c130Rifornimento .. ".", 10)
    return
  end
  local regione = CIV.getZone(C.zone.fuocoRegione)
  local p = u:getPoint()
  if regione and not CIV.inZone(p, regione) then
    CIV.msgUnit(u, "Sei fuori dalla macro-regione incendi.", 10)
    return
  end
  local agl = CIV.agl(p)
  if agl < CF.quotaRilascio.min or agl > CF.quotaRilascio.max then
    CIV.msgUnit(u, string.format(
      "Quota non valida (%d m AGL): banda di rilascio %d-%d m.",
      math.floor(agl), CF.quotaRilascio.min, CF.quotaRilascio.max), 10)
    return
  end
  st.ritardante = false
  st.rilascio = { fine = timer.getTime() + CF.durataRilascioC130, colpiti = 0 }
  CIV.msgUnit(u, "RILASCIO IN CORSO: mantieni rotta e quota per " ..
    CF.durataRilascioC130 .. " secondi.", 10)
end

CIV.schedule(function(_, t)
  local now = timer.getTime()
  for uname, st in pairs(FC._stato) do
    if st.rilascio then
      local u = Unit.getByName(uname)
      if not u or not u:isExist() or now > st.rilascio.fine then
        local colpiti = st.rilascio and st.rilascio.colpiti or 0
        st.rilascio = nil
        if u and u:isExist() then
          local info = CIV.players[uname]
          if colpiti > 0 and info then
            CIV.msgUnit(u, "Rilascio completato: linea efficace.", 10)
            CIV.Score.award(info.playerName, "incendioC130",
              math.min(1, colpiti / CF.durataRilascioC130), 0.5, 1, "linea ritardante C-130")
          elseif u then
            CIV.msgUnit(u, "Rilascio completato: nessun incendio sotto la linea.", 10)
          end
        end
      else
        local p = u:getPoint()
        local agl = CIV.agl(p)
        if agl >= CF.quotaRilascio.min and agl <= CF.quotaRilascio.max then
          local fire = CIV.Fire.applyWater(p, CF.ritardanteC130,
            CIV.players[uname] and CIV.players[uname].playerName)
          if fire then st.rilascio.colpiti = st.rilascio.colpiti + 1 end
        end
      end
    end
  end
  return t + 1
end, nil, 10)

--------------------------------------------------------------------
-- Spotter: C-130 in macro-regione -> coordinate + marker F10 degli incendi
--------------------------------------------------------------------
CIV.schedule(function(_, t)
  local regione = CIV.getZone(C.zone.fuocoRegione)
  if not regione then return t + 120 end
  local spotter = nil
  CIV.forEachPlayer(function(u, info)
    if spotter then return end
    if eAereo(info) and u:inAir() and CIV.inZone(u:getPoint(), regione) then
      spotter = info
    end
  end)
  if spotter then
    local n, txt = 0, ""
    for _, f in pairs(CIV.Fire.actives()) do
      n = n + 1
      txt = txt .. string.format("- %s: %s (int. %d%%)\n", f.pt.name,
        CIV.llString(f.point), math.floor(f.intensita * 100))
      if not f.markId then
        f.markId = CIV.mark("INCENDIO " .. f.pt.name, f.point)
      end
    end
    if n > 0 then
      CIV.msgAll("SPOTTER " .. spotter.playerName .. " riporta " .. n ..
        " incendi attivi:\n" .. txt, 20)
    end
  end
  return t + CF.spotterIntervallo
end, nil, 30)

--------------------------------------------------------------------
-- Menu F10
--------------------------------------------------------------------
CIV.Menu_register(function(gid, uname)
  local sub = missionCommands.addSubMenuForGroup(gid, "Antincendio C-130", CIV.rootMenu[gid])
  missionCommands.addCommandForGroup(gid, "Avvia rilascio in linea", sub, avviaRilascio, uname)
end)

CIV.log("Firefighting_C130 caricato")
