--[[
  99_CivMain.lua — Orchestrazione finale: direttore eventi, menu Admin,
  banner. Da caricare per ULTIMO (dopo config, core e tutti i moduli).
]]

CIV = CIV or {}
local C = CIV.Config

--------------------------------------------------------------------
-- Tabella di avvio per modulo (usata da direttore e menu Admin)
--------------------------------------------------------------------
local avvii = {
  sarMontagna  = { label = "SAR Montagna",  fn = function() return CIV.SAR.startEvent("SARM") end },
  sarMare      = { label = "SAR Mare",      fn = function() return CIV.SAR.startEvent("SARS") end },
  medevac      = { label = "MedEvac",       fn = function() return CIV.SAR.startEvent("MEDEVAC") end },
  inseguimento = { label = "Inseguimento",  fn = function() return CIV.Police.startChase() end },
  swat         = { label = "Scenario SWAT", fn = function() return CIV.SWAT.startScenario() end },
  trasporto    = { label = "Punto trasporto", fn = function() return CIV.Cargo.startPoint() end },
  incendio     = { label = "Incendio",      fn = function() return CIV.Fire.igniteRandom() end },
}

--------------------------------------------------------------------
-- Direttore eventi automatico
--------------------------------------------------------------------
if C.director.abilitato then
  CIV.schedule(function(_, t)
    for chiave, prob in pairs(C.director.moduli) do
      if avvii[chiave] and math.random(100) <= prob then
        local ok, res = pcall(avvii[chiave].fn)
        if not ok then CIV.log("Direttore: avvio " .. chiave .. " fallito: " .. tostring(res)) end
      end
    end
    return t + CIV.randBetween(C.director.intervallo)
  end, nil, CIV.randBetween(C.director.intervallo))
end

--------------------------------------------------------------------
-- Menu Admin (test): avvio manuale di ogni evento
--------------------------------------------------------------------
if C.adminMenu then
  CIV.Menu_register(function(gid)
    local sub = missionCommands.addSubMenuForGroup(gid, "Admin (test)", CIV.rootMenu[gid])
    for chiave, v in pairs(avvii) do
      missionCommands.addCommandForGroup(gid, "Avvia: " .. v.label, sub, function()
        local ok, res = pcall(v.fn)
        if not ok then
          CIV.msgGroupId(gid, "Errore: " .. tostring(res), 15)
        elseif not res then
          CIV.msgGroupId(gid, v.label .. ": non avviato (tetto raggiunto o " ..
            "nessun punto/pool disponibile).", 12)
        end
      end)
    end
    missionCommands.addCommandForGroup(gid, "Stato pool", sub, function()
      local txt = "Pool caricati:\n"
      for prefix, pool in pairs(CIV.Pool._pools) do
        txt = txt .. string.format("- %s: %d punti\n", prefix, #pool)
      end
      CIV.msgGroupId(gid, txt, 20)
    end)
  end)
end

--------------------------------------------------------------------
-- Arredo iniziale delle aree fisse (se le zone esistono in ME)
--------------------------------------------------------------------
CIV.schedule(function()
  if CIV.getZone(C.zone.c130Rifornimento) then
    CIV.Dressing.spawn(C.zone.c130Rifornimento, "zona_carico_c130")
  end
  -- le piazzole ospedale arredate come campo medico avanzato
  for _, pt in ipairs(CIV.Pool.load(C.zone.ospedalePool)) do
    CIV.Dressing.spawn(pt.name, "campo_medico")
  end
end, nil, 5)

--------------------------------------------------------------------
-- Precarica i pool (log immediato di quanti punti sono definiti in ME)
--------------------------------------------------------------------
CIV.schedule(function()
  for _, prefix in pairs({ C.zone.fuocoPool, C.zone.acquaPool, C.zone.sarMontPool,
      C.zone.sarMarePool, C.zone.poliziaPool, C.zone.swatPool, C.zone.cargoPool,
      C.zone.medevacPool, C.zone.ospedalePool }) do
    CIV.Pool.load(prefix)
  end
end, nil, 3)

CIV.msgAll("Template Missioni Civili v" .. CIV.VERSION .. " attivo.\n" ..
  "Menu: F10 -> Missioni Civili", 20)
CIV.log("CivMain caricato: template attivo")
