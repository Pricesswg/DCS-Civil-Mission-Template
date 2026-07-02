--[[
  03_HoverZoneTrigger.lua — Modulo condiviso di rilevamento hover.
  Riusato da: prelievo acqua antincendio, SAR montagna/mare, MedEvac ostile,
  fast-rope SWAT.

  NON è un task AI: è polling dello stato dell'unità del giocatore
  (Unit:getVelocity per la velocità, Unit:getPoint per posizione/quota),
  sostenuto per un tempo minimo dentro un inviluppo.

  Meccanica (vedi concept "Meccanica di hover e completamento"):
    - T      = tempo minimo richiesto (pavimento, mai riducibile)
    - B      = fattore stabilità, SOLO malus: rate = 1 / (1 + B * instabilita)
    - window = finestra totale dall'ingresso in hover; scaduta -> fallimento
    - Il vento agisce già sul modello di volo: nessun malus meteo scriptato
      aggiuntivo (si penalizzerebbe due volte la stessa causa).

  L'azione al successo è una callback passata dal chiamante, non incorporata.
]]

CIV = CIV or {}
CIV.Hover = { _sessions = {}, _watches = {}, _sid = 0, _wid = 0 }
local H = CIV.Hover

--------------------------------------------------------------------
-- Sessione esplicita: il chiamante sa già QUALE unità deve fare hover.
-- spec = {
--   unitName, center (vec3), label,
--   radius, minAGL, maxAGL, maxSpeed, T, window, B,   (da CIV.Config.hover.*)
--   onSuccess(unit, session), onFail(reason, session), onProgress(unit, session, frac)
-- }
--------------------------------------------------------------------
function H.start(spec)
  H._sid = H._sid + 1
  local s = {
    id = H._sid, spec = spec,
    progress = 0,                  -- secondi "validi" accumulati
    startTime = timer.getTime(),   -- da qui parte la finestra
    lastMsg = 0, done = false,
  }
  H._sessions[s.id] = s
  CIV.dbg("Hover start #" .. s.id .. " [" .. (spec.label or "?") .. "] unit=" .. spec.unitName)
  return s
end

function H.cancel(session)
  if session then H._sessions[session.id] = nil end
end

local function tickSession(s, now)
  local spec = s.spec

  -- Finestra scaduta -> fallimento con esito narrativo del chiamante
  if now - s.startTime > spec.window then
    s.done = true
    H._sessions[s.id] = nil
    if spec.onFail then pcall(spec.onFail, "window", s) end
    return
  end

  local u = Unit.getByName(spec.unitName)
  if not u or not u:isExist() then
    -- unità sparita (crash/cambio slot): la sessione resta aperta finché la
    -- finestra non scade, così un altro elicottero può subentrare via watch
    return
  end

  local p   = u:getPoint()
  local v   = u:getVelocity()
  local spd = CIV.speed(v)
  local dev = CIV.dist2D(p, spec.center)
  local agl = CIV.agl(p)

  local inEnvelope = dev <= spec.radius
    and agl >= spec.minAGL and agl <= spec.maxAGL
    and spd <= spec.maxSpeed

  if inEnvelope then
    -- Instabilità normalizzata: quanto si sta usando dell'inviluppo.
    -- Cattura da sola l'effetto del vento (deviazione reale misurata).
    local instab = math.max(spd / spec.maxSpeed, dev / spec.radius)
    local rate   = 1 / (1 + spec.B * instab)   -- <= 1: solo malus, mai bonus
    s.progress = s.progress + rate * 1.0       -- tick da 1 s

    if spec.onProgress then
      pcall(spec.onProgress, u, s, s.progress / spec.T)
    end
    if now - s.lastMsg > 10 then
      s.lastMsg = now
      CIV.msgUnit(u, string.format("%s: %d%%  (stabilita' %d%%)",
        spec.label or "Operazione", math.floor(100 * s.progress / spec.T),
        math.floor(100 * rate)), 8)
    end

    if s.progress >= spec.T then
      s.done = true
      H._sessions[s.id] = nil
      if spec.onSuccess then pcall(spec.onSuccess, u, s) end
      return
    end
  else
    -- Fuori inviluppo: il progresso si CONGELA (non si azzera); il costo
    -- reale dell'imprecisione è la finestra che continua a scorrere.
    if now - s.lastMsg > 15 then
      s.lastMsg = now
      local resta = math.floor(spec.window - (now - s.startTime))
      CIV.msgUnit(u, string.format(
        "%s: fuori posizione (dist %dm, AGL %dm, %.1f m/s). Finestra: %d min",
        spec.label or "Operazione", math.floor(dev), math.floor(agl), spd,
        math.floor(resta / 60)), 8)
    end
  end
end

--------------------------------------------------------------------
-- Watch: sorveglia un punto e aggancia automaticamente il primo elicottero
-- giocatore che entra nell'inviluppo. Usato da SAR/MedEvac/SWAT dove non si
-- sa in anticipo chi verrà a fare l'operazione.
-- wspec = spec (senza unitName) + { detectRadius (default radius*3),
--          filter(unit, info) -> bool opzionale, windowFromDetect = true/false }
-- La finestra parte dal primo aggancio; il fallimento della finestra chiude
-- anche il watch (evento perso: il chiamante decide la narrativa in onFail).
--------------------------------------------------------------------
function H.watch(wspec)
  H._wid = H._wid + 1
  local w = { id = H._wid, spec = wspec, session = nil, done = false }
  H._watches[w.id] = w
  return w
end

function H.unwatch(w)
  if not w then return end
  if w.session then H.cancel(w.session) end
  H._watches[w.id] = nil
end

local function tickWatch(w)
  if w.session and not w.session.done then return end  -- sessione già in corso
  if w.session and w.session.done then return end
  local ws = w.spec
  local detect = ws.detectRadius or (ws.radius * 3)
  CIV.forEachPlayerHelo(function(u, info)
    if w.session then return end
    if ws.filter and not ws.filter(u, info) then return end
    local p = u:getPoint()
    if CIV.dist2D(p, ws.center) <= detect and CIV.agl(p) <= ws.maxAGL * 3 then
      local spec = {}
      for k, v in pairs(ws) do spec[k] = v end
      spec.unitName = u:getName()
      local userFail = ws.onFail
      spec.onFail = function(reason, s)
        w.done = true
        H._watches[w.id] = nil
        if userFail then userFail(reason, s) end
      end
      local userSuccess = ws.onSuccess
      spec.onSuccess = function(unit, s)
        w.done = true
        H._watches[w.id] = nil
        if userSuccess then userSuccess(unit, s) end
      end
      w.session = H.start(spec)
      CIV.msgUnit(u, (ws.label or "Operazione") ..
        ": in posizione. Mantieni l'hover dentro l'area.", 10)
    end
  end)
end

--------------------------------------------------------------------
-- Loop unico a 1 Hz per tutte le sessioni e i watch (eventi paralleli:
-- ogni sessione ha il proprio stato, nessuna variabile globale condivisa)
--------------------------------------------------------------------
CIV.schedule(function(_, t)
  local now = timer.getTime()
  for _, s in pairs(H._sessions) do tickSession(s, now) end
  for _, w in pairs(H._watches)  do tickWatch(w) end
  return t + 1
end, nil, 2)

CIV.log("HoverZoneTrigger caricato")
