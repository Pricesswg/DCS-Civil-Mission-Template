--[[
  05_ScoreSystem.lua — Punteggio di sessione (in memoria, azzerato a fine
  missione; nessun file, nessun hook).

  La funzione di calcolo è PURA (task + qualità + tempo -> punti), separata da
  dove vive il totale: una futura leaderboard persistente (hook server, file
  esterno o world.setPersistenceHandler — decisione aperta, vedi concept)
  riuserà lo stesso calcolo aggiungendo solo lo strato di persistenza.

  I pesi di difficoltà per tipo di task sono in CIV.Config.score.base: fissati
  ora perché cambiarli dopo significherebbe ricalcolare tutto lo storico.
]]

CIV = CIV or {}
CIV.Score = { _board = {} }   -- playerName -> { punti, tasks }
local S = CIV.Score
local C = CIV.Config

--------------------------------------------------------------------
-- Funzione pura: nessun effetto collaterale, nessuno stato letto/scritto.
--   taskType   : chiave di CIV.Config.score.base
--   quality    : 0..1 (es. criticità residua MedEvac, stabilità media hover)
--   timeFactor : 0..1 (frazione di finestra NON consumata)
--   mult       : moltiplicatore extra opzionale (es. tier del carico)
--------------------------------------------------------------------
function S.compute(taskType, quality, timeFactor, mult)
  local base = C.score.base[taskType]
  if not base then return 0 end
  quality    = math.max(0, math.min(1, quality or 0.5))
  timeFactor = math.max(0, math.min(1, timeFactor or 0.5))
  local punti = base * (0.5 + 0.35 * quality + 0.15 * timeFactor) * (mult or 1)
  return math.floor(punti + 0.5)
end

--------------------------------------------------------------------
-- Accredito (strato "dove vive il totale": oggi sessione, domani anche file)
--------------------------------------------------------------------
function S.award(playerName, taskType, quality, timeFactor, mult, label)
  local punti = S.compute(taskType, quality, timeFactor, mult)
  local row = S._board[playerName]
  if not row then
    row = { punti = 0, tasks = 0 }
    S._board[playerName] = row
  end
  row.punti = row.punti + punti
  row.tasks = row.tasks + 1
  CIV.log(string.format("SCORE|%s|%s|%d|q=%.2f|t=%.2f", playerName, taskType,
    punti, quality or -1, timeFactor or -1))  -- riga parsabile da dcs.log (opzione leaderboard esterna)
  if C.score.broadcast then
    CIV.msgAll(string.format("%s completa: %s  (+%d punti, totale %d)",
      playerName, label or taskType, punti, row.punti), 12)
  end
  return punti
end

-- Qualità derivata da una sessione hover: efficienza media del timer
-- (progress reale T / tempo speso dentro la finestra). Hover perfetto -> ~1.
function S.hoverQuality(session)
  local speso = timer.getTime() - session.startTime
  if speso <= 0 then return 1 end
  return math.min(1, session.spec.T / speso)
end

-- Fattore tempo da una sessione hover: frazione di finestra non consumata
function S.hoverTimeFactor(session)
  local speso = timer.getTime() - session.startTime
  return math.max(0, 1 - speso / session.spec.window)
end

--------------------------------------------------------------------
-- Classifica F10 (competizione live intra-sessione)
--------------------------------------------------------------------
local function mostraClassifica(gid)
  local rows = {}
  for name, row in pairs(S._board) do
    rows[#rows + 1] = { name = name, punti = row.punti, tasks = row.tasks }
  end
  if #rows == 0 then
    CIV.msgGroupId(gid, "Classifica di sessione: nessun task completato.", 10)
    return
  end
  table.sort(rows, function(a, b) return a.punti > b.punti end)
  local txt = "=== CLASSIFICA DI SESSIONE ===\n"
  for i, r in ipairs(rows) do
    txt = txt .. string.format("%d. %-20s %5d punti  (%d task)\n", i, r.name, r.punti, r.tasks)
    if i >= 10 then break end
  end
  CIV.msgGroupId(gid, txt, 20)
end

CIV.Menu_register(function(gid)
  missionCommands.addCommandForGroup(gid, "Classifica di sessione",
    CIV.rootMenu[gid], mostraClassifica, gid)
end)

CIV.log("ScoreSystem caricato")
