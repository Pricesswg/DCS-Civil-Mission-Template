--[[
  06_ZoneDressing.lua — Aree arredate (scenografia).
  Le zone sono FISSE, definite in ME su terreno piano scelto a mano (nessun
  check di planarità a runtime: serve solo per punti scelti a caso dal codice).
  Dentro la zona si spawnano static object scenici via coalition.addStaticObject
  (passivi ed economici; niente unità AI per pura scenografia).

  I "kit" sono liste di statici con offset relativi al centro zona: campo
  medico avanzato, zona carico C-130, campo profughi — equivalenti dei set
  usati nella missione 104ww, ricreati qui in nativo.
]]

CIV = CIV or {}
CIV.Dressing = { _spawned = {} }   -- zoneName -> lista nomi statici
local D = CIV.Dressing
local C = CIV.Config

-- Ogni voce: { type, category (default "Fortifications"), dx, dy, heading, shape_name? }
-- I nomi tipo sono DA VALIDARE in ME sulla mappa scelta (variano tra mappe/versioni).
D.kits = {
  campo_medico = {
    { type = "FARP Tent",            dx =   0, dy =   0, heading = 0 },
    { type = "FARP Tent",            dx =  15, dy =   0, heading = 0 },
    { type = "FARP Ammo Dump Coating", dx = -12, dy =  8, heading = 0 },
    { type = "Windsock",             dx =  25, dy = -20, heading = 0 },
    { type = "FARP Fuel Depot",      dx = -20, dy = -15, heading = 0 },
    { type = "Hummer",               dx =  10, dy =  18, heading = 1.57, category = "Unarmed" },
  },
  zona_carico_c130 = {
    { type = "Container_10ft",       dx =   0, dy =   0, heading = 0 },
    { type = "Container_20ft",       dx =   6, dy =   0, heading = 0 },
    { type = "Container_40ft",       dx =  14, dy =   0, heading = 0 },
    { type = "FARP Fuel Depot",      dx = -15, dy =  10, heading = 0 },
    { type = "Windsock",             dx = -25, dy = -25, heading = 0 },
  },
  campo_profughi = {
    { type = "FARP Tent",            dx =   0, dy =   0, heading = 0 },
    { type = "FARP Tent",            dx =  12, dy =   3, heading = 0.5 },
    { type = "FARP Tent",            dx =  -8, dy =  14, heading = 2.1 },
    { type = "FARP Tent",            dx =   4, dy = -16, heading = 1.2 },
    { type = "Cafe",                 dx =  30, dy =   0, heading = 0 },
  },
}

-- Spawna un kit dentro una zona ME. Ritorna la lista dei nomi creati.
function D.spawn(zoneName, kitName)
  local z = CIV.getZone(zoneName)
  if not z then
    CIV.log("Dressing: zona '" .. zoneName .. "' inesistente in ME")
    return nil
  end
  local kit = D.kits[kitName]
  if not kit then
    CIV.log("Dressing: kit '" .. tostring(kitName) .. "' sconosciuto")
    return nil
  end
  local names = {}
  for i, item in ipairs(kit) do
    local name = CIV.uniqueName("CIV_DRESS_" .. zoneName)
    local ok, err = pcall(coalition.addStaticObject, C.countryId, {
      category = item.category or "Fortifications",
      type = item.type, name = name,
      x = z.point.x + item.dx, y = z.point.z + item.dy,
      heading = item.heading or 0,
      shape_name = item.shape_name,
    })
    if ok then
      names[#names + 1] = name
    else
      -- tipo non valido su questa mappa/versione: si logga e si continua
      CIV.log("Dressing: statico '" .. item.type .. "' fallito: " .. tostring(err))
    end
  end
  D._spawned[zoneName] = names
  CIV.log("Dressing '" .. kitName .. "' su " .. zoneName .. ": " .. #names .. " statici")
  return names
end

function D.clear(zoneName)
  for _, n in ipairs(D._spawned[zoneName] or {}) do CIV.despawnStatic(n) end
  D._spawned[zoneName] = nil
end

CIV.log("ZoneDressing caricato")
