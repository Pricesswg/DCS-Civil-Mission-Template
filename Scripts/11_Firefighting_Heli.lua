--[[
  11_Firefighting_Heli.lua — Antincendio elicotteri.
  Ciclo: hover sopra specchio d'acqua (punti CIV_ACQUA_P##, quota di sicurezza
  non radente) -> carico acqua -> sgancio sopra un incendio attivo.

  Due modalità (CIV.Config.fuoco.usaCargoFisico):
  - false (default): carico come STATO LOGICO per unità + sgancio via F10.
    Robusto, nessun rischio tecnico.
  - true (SPERIMENTALE): al successo dell'hover spawn di un oggetto Cargo con
    massa nativa da agganciare col sistema sling load F8. Lo spawn di Cargo su
    acqua aperta è nel concept tra i punti DA TESTARE in-game: non attivare in
    una serata ufficiale senza averlo provato in ME.
]]

CIV = CIV or {}
CIV.FireHeli = { _stato = {} }   -- unitName -> { acqua = bool, cargoName = ... }
local FH = CIV.FireHeli
local C  = CIV.Config
local CF = C.fuoco

local function stato(uname)
  FH._stato[uname] = FH._stato[uname] or { acqua = false }
  return FH._stato[uname]
end

--------------------------------------------------------------------
-- Prelievo acqua: comando F10 valido solo dentro un punto acqua del pool
--------------------------------------------------------------------
local function trovaPuntoAcqua(p)
  for _, pt in ipairs(CIV.Pool.load(C.zone.acquaPool)) do
    if CIV.dist2D(p, pt.point) <= math.max(pt.radius, 200) then return pt end
  end
  return nil
end

local function iniziaPrelievo(uname)
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  local st = stato(uname)
  if st.acqua then
    CIV.msgUnit(u, "Serbatoio gia' pieno: porta l'acqua su un incendio.", 10)
    return
  end
  local pt = trovaPuntoAcqua(u:getPoint())
  if not pt then
    CIV.msgUnit(u, "Nessun punto di prelievo acqua nelle vicinanze.", 10)
    return
  end
  local hp = C.hover.prelievoAcqua
  CIV.Hover.start({
    unitName = uname, center = pt.point, label = "Prelievo acqua",
    radius = hp.radius, minAGL = hp.minAGL, maxAGL = hp.maxAGL,
    maxSpeed = hp.maxSpeed, T = hp.T, window = hp.window, B = hp.B,
    onSuccess = function(unit)
      if CF.usaCargoFisico then
        -- SPERIMENTALE: cargo con massa nativa spawnato sull'acqua
        local cn = CIV.spawnCargo(pt.point, CF.cargoAcquaTipo, CF.cargoAcquaKg, "CIV_ACQUA")
        st.cargoName = cn
        CIV.msgUnit(unit, "Sacca d'acqua pronta (" .. CF.cargoAcquaKg ..
          " kg). Agganciala con il sistema sling load (F8/hook).", 15)
      else
        st.acqua = true
        CIV.msgUnit(unit, "Acqua caricata. Vola su un incendio attivo e usa " ..
          "F10 -> Missioni Civili -> Antincendio -> Sgancia acqua.", 15)
      end
    end,
    onFail = function()
      CIV.msgUnit(Unit.getByName(uname) or u,
        "Prelievo acqua fallito: tempo scaduto.", 10)
    end,
  })
  CIV.msgUnit(u, "Mantieni l'hover sopra il punto di prelievo (" ..
    hp.minAGL .. "-" .. hp.maxAGL .. " m AGL).", 10)
end

--------------------------------------------------------------------
-- Sgancio (modalità logica): F10 sopra l'incendio
--------------------------------------------------------------------
local function sganciaAcqua(uname)
  local u = Unit.getByName(uname)
  if not u or not u:isExist() then return end
  local st = stato(uname)
  if not st.acqua then
    CIV.msgUnit(u, "Serbatoio vuoto: preleva acqua da un punto CIV_ACQUA.", 10)
    return
  end
  local fire = CIV.Fire.applyWater(u:getPoint(), CF.acquaHeli,
    CIV.players[uname] and CIV.players[uname].playerName)
  st.acqua = false
  if fire then
    CIV.msgUnit(u, "Sgancio a segno!", 10)
    local info = CIV.players[uname]
    if info then
      -- fuoco ancora attivo: piccolo accredito; spento: accredito pieno nel messaggio di spegnimento
      CIV.Score.award(info.playerName, "incendioHeli",
        CIV.Fire._fires[fire.id] and 0.5 or 1.0, 0.5, 1, "sgancio antincendio")
    end
  else
    CIV.msgUnit(u, "Sgancio a vuoto: nessun incendio nel raggio di " ..
      CF.raggioSgancio .. " m. Acqua persa.", 10)
  end
end

--------------------------------------------------------------------
-- Modalità cargo fisico: consegna rilevata via polling della posizione del
-- cargo (quando slingato l'oggetto si muove col velivolo). DA TESTARE.
--------------------------------------------------------------------
CIV.schedule(function(_, t)
  if not CF.usaCargoFisico then return t + 30 end
  for uname, st in pairs(FH._stato) do
    if st.cargoName then
      local s = StaticObject.getByName(st.cargoName)
      if not s then
        st.cargoName = nil   -- distrutto/sganciato male
      else
        local p = s:getPoint()
        local fire = nil
        for _, f in pairs(CIV.Fire.actives()) do
          if CIV.dist2D(p, f.point) <= CF.raggioSgancio then fire = f break end
        end
        if fire and CIV.agl(p) < 5 then
          CIV.despawnStatic(st.cargoName)
          st.cargoName = nil
          CIV.Fire.applyWater(fire.point, CF.acquaHeli,
            CIV.players[uname] and CIV.players[uname].playerName)
          local info = CIV.players[uname]
          if info then
            CIV.Score.award(info.playerName, "incendioHeli", 1.0, 0.5, 1, "sgancio antincendio")
          end
        end
      end
    end
  end
  return t + 2
end, nil, 10)

--------------------------------------------------------------------
-- Menu F10
--------------------------------------------------------------------
CIV.Menu_register(function(gid, uname)
  local sub = missionCommands.addSubMenuForGroup(gid, "Antincendio", CIV.rootMenu[gid])
  missionCommands.addCommandForGroup(gid, "Inizia prelievo acqua", sub, iniziaPrelievo, uname)
  missionCommands.addCommandForGroup(gid, "Sgancia acqua", sub, sganciaAcqua, uname)
  missionCommands.addCommandForGroup(gid, "Incendi attivi", sub, function()
    local n, txt = 0, "Incendi attivi:\n"
    for _, f in pairs(CIV.Fire.actives()) do
      n = n + 1
      txt = txt .. string.format("- %s  int. %d%%  %s\n", f.pt.name,
        math.floor(f.intensita * 100), CIV.llString(f.point))
    end
    CIV.msgGroupId(gid, n > 0 and txt or "Nessun incendio attivo.", 20)
  end)
end)

CIV.log("Firefighting_Heli caricato")
