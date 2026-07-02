--[[
  31_Polizia_SWAT.lua — Inserimento SWAT via fast-rope.
  Il touchdown reale su tetti non è affidabile (mesh edifici): l'inserimento è
  virtuale via HoverZoneTrigger sopra la LZ, poi spawn scriptato della squadra
  con coalition.addGroup (i task nativi embark/disembark sono AI-to-AI e non
  adatti: verificato nel concept).

  Il NUMERO di soldati sbarcati viene dallo stato tracciato all'IMBARCO alla
  base (stesso pattern del tier di carico), non deciso allo sbarco.

  DA TESTARE in-game: affidabilità dello spawn di fanteria sulla mesh di un
  tetto (rischio basso ma non scontato).
]]

CIV = CIV or {}
CIV.SWAT = { _stato = {}, _scenari = {}, _sid = 0 }  -- _stato: unitName -> {squadra=n}
local SW = CIV.SWAT
local C  = CIV.Config
local CS = C.swat

local function stato(uname)
  SW._stato[uname] = SW._stato[uname] or { squadra = 0 }
  return SW._stato[uname]
end

--------------------------------------------------------------------
-- Imbarco alla base: fermo dentro CIV_SWAT_BASE
--------------------------------------------------------------------
local function imbarca(uname)
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  local st = stato(uname)
  if st.squadra > 0 then
    CIV.msgUnit(u, "Squadra gia' a bordo (" .. st.squadra .. " operatori).", 10)
    return
  end
  local zona = CIV.getZone(C.zone.swatBase)
  if not zona then
    CIV.msgUnit(u, "Zona " .. C.zone.swatBase .. " non definita in ME.", 10)
    return
  end
  local p = u:getPoint()
  if u:inAir() or not CIV.inZone(p, zona) or CIV.speed(u:getVelocity()) > 1 then
    CIV.msgUnit(u, "Devi essere ATTERRATO e fermo dentro la base SWAT.", 10)
    return
  end
  CIV.msgUnit(u, "Imbarco squadra in corso: resta fermo " .. CS.tempoImbarco .. " secondi.", 10)
  CIV.schedule(function()
    local u2 = Unit.getByName(uname)
    if not u2 or not u2:isExist() then return end
    local p2 = u2:getPoint()
    if u2:inAir() or not CIV.inZone(p2, zona) or CIV.speed(u2:getVelocity()) > 1 then
      CIV.msgUnit(u2, "Imbarco annullato: ti sei mosso.", 10)
      return
    end
    -- numero operatori fissato QUI, all'imbarco
    st.squadra = math.random(CS.squadra.numMin, CS.squadra.numMax)
    CIV.msgUnit(u2, "Squadra SWAT a bordo: " .. st.squadra ..
      " operatori. Inseriscili sull'obiettivo attivo via fast-rope.", 15)
  end, nil, CS.tempoImbarco)
end

--------------------------------------------------------------------
-- Scenario (rapina/ostaggi): punto attivo dal pool + watch fast-rope
--------------------------------------------------------------------
function SW.startScenario()
  local pt = CIV.Pool.pick(C.zone.swatPool, 500)
  if not pt then return nil end
  SW._sid = SW._sid + 1
  local scen = { id = SW._sid, pt = pt }
  SW._scenari[scen.id] = scen
  CIV.Pool.occupy(pt)

  local hp = C.hover.fastRope
  scen.watch = CIV.Hover.watch({
    center = pt.point, label = "SWAT - fast-rope",
    radius = hp.radius, minAGL = hp.minAGL, maxAGL = hp.maxAGL,
    maxSpeed = hp.maxSpeed, T = hp.T, window = hp.window, B = hp.B,
    -- si aggancia solo a elicotteri CON squadra a bordo
    filter = function(u) return stato(u:getName()).squadra > 0 end,
    onSuccess = function(unit, session)
      local uname = unit:getName()
      local st = stato(uname)
      local n = st.squadra
      st.squadra = 0
      -- spawn sulla LZ: la squadra resta fisicamente presente e operativa
      -- (a differenza di SAR/MedEvac dove il soggetto viene despawnato)
      CIV.spawnInfantry(pt.point, n, CS.squadra.tipo, "CIV_SWAT")
      CIV.msgAll("SWAT: squadra di " .. n .. " operatori inserita su " ..
        pt.name .. ". Intervento in corso.", 15)
      local info = CIV.players[uname]
      if info then
        CIV.Score.award(info.playerName, "swat",
          CIV.Score.hoverQuality(session), CIV.Score.hoverTimeFactor(session),
          1, "inserimento SWAT")
      end
      -- risoluzione narrativa dopo N secondi
      CIV.schedule(function()
        CIV.msgAll("SWAT: scenario su " .. pt.name .. " RISOLTO. Zona sicura.", 15)
        CIV.Pool.release(pt)
        SW._scenari[scen.id] = nil
      end, nil, CS.risoluzione)
    end,
    onFail = function()
      CIV.msgAll("SWAT: intervento su " .. pt.name ..
        " FALLITO (finestra scaduta).", 15)
      CIV.Pool.release(pt)
      SW._scenari[scen.id] = nil
    end,
  })
  CIV.msgAll("SWAT: scenario ostile segnalato su " .. pt.name ..
    "\nCoordinate: " .. CIV.llString(pt.point) ..
    "\nImbarca una squadra alla base e inseriscila via fast-rope.", 25)
  return scen
end

--------------------------------------------------------------------
-- Menu F10
--------------------------------------------------------------------
CIV.Menu_register(function(gid, uname)
  local sub = missionCommands.addSubMenuForGroup(gid, "Polizia / SWAT", CIV.rootMenu[gid])
  missionCommands.addCommandForGroup(gid, "Imbarca squadra SWAT (alla base)", sub, imbarca, uname)
  missionCommands.addCommandForGroup(gid, "Stato squadra", sub, function()
    local st = stato(uname)
    CIV.msgGroupId(gid, st.squadra > 0
      and ("Squadra a bordo: " .. st.squadra .. " operatori.")
      or "Nessuna squadra a bordo.", 10)
  end)
end)

CIV.log("Polizia_SWAT caricato")
