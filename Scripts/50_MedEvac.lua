--[[
  50_MedEvac.lua — Recupero feriti verso piazzola ospedale.
  Riusa il motore SAR (20_SAR.lua): stesso HoverZoneTrigger per il recupero in
  scenario ostile, stessa consegna a zona in ospedale (MAI S_EVENT_LAND: le
  piazzole ospedale in genere non sono FARP/airbase definiti — verificato).

  Differenza dal SAR: il timer di CRITICITÀ. Il paziente decade nel tempo e la
  qualità del punteggio è la frazione di criticità residua alla consegna.
  Se la deadline scade (anche a bordo), il paziente è deceduto.

  Riusabile in scenario insurgent/militare cambiando solo la skin narrativa.
]]

CIV = CIV or {}
local C = CIV.Config

CIV.SAR.newScenario({
  key = "MEDEVAC", label = "MedEvac",
  poolPrefix = C.zone.medevacPool, regione = nil,
  maxAttivi = C.medevac.maxAttivi,
  unita = C.medevac.unita, beacon = nil,
  scoreType = "medevac", hoverCfg = C.hover.medevac,
  deadline = C.medevac.criticita,
  -- qualità = criticità residua al momento del RECUPERO (poi la consegna
  -- oltre deadline annulla comunque il punteggio, vedi motore SAR)
  qualityFn = function(evt)
    local resta = evt.deadline - timer.getTime()
    return math.max(0, math.min(1, resta / C.medevac.criticita))
  end,
})

CIV.log("MedEvac caricato")
