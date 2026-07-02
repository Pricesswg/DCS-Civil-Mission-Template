--[[
  04_PointPool.lua — Pool di punti curati dentro macro-regioni.
  Convenzione: zone ME nominate PREFISSO + indice a 2 cifre (CIV_FUOCO_P01,
  CIV_FUOCO_P02, ...). La scansione parte da 01 e si ferma al primo buco.

  Selezione random con controllo di distanza minima dagli eventi attivi
  (principio eventi paralleli: più eventi contemporanei senza sovrapposizioni).

  Nessuna trigger zone creata a runtime: non esiste API nativa e non serve,
  le zone esistono già da ME.
]]

CIV = CIV or {}
CIV.Pool = { _pools = {}, _activePoints = {} }
local P = CIV.Pool

-- Carica un pool scandendo le zone ME col prefisso dato.
function P.load(prefix)
  if P._pools[prefix] then return P._pools[prefix] end
  local points = {}
  local i = 1
  while true do
    local zname = string.format("%s%02d", prefix, i)
    local z = CIV.getZone(zname)
    if not z then break end
    points[#points + 1] = {
      name = zname, radius = z.radius,
      point = { x = z.point.x, y = CIV.groundY(z.point), z = z.point.z },
    }
    i = i + 1
  end
  P._pools[prefix] = points
  CIV.log("Pool '" .. prefix .. "': " .. #points .. " punti")
  return points
end

-- Registra/deregistra un punto come occupato da un evento attivo
function P.occupy(pt)   P._activePoints[pt.name] = pt end
function P.release(pt)  P._activePoints[pt.name] = nil end

local function tooClose(pt, minDist)
  for _, act in pairs(P._activePoints) do
    if act.name == pt.name or CIV.dist2D(pt.point, act.point) < minDist then
      return true
    end
  end
  return false
end

-- Estrae un punto random dal pool, escludendo quelli troppo vicini a eventi
-- attivi. filter(pt) opzionale. Ritorna nil se nessun punto disponibile.
function P.pick(prefix, minDist, filter)
  local pool = P.load(prefix)
  if #pool == 0 then return nil end
  local candidates = {}
  for _, pt in ipairs(pool) do
    if not tooClose(pt, minDist or 500) and (not filter or filter(pt)) then
      candidates[#candidates + 1] = pt
    end
  end
  if #candidates == 0 then return nil end
  return candidates[math.random(#candidates)]
end

-- Punti del pool entro 'radius' da 'point' (random walk polizia)
function P.near(prefix, point, radius, excludeName)
  local pool = P.load(prefix)
  local res = {}
  for _, pt in ipairs(pool) do
    if pt.name ~= excludeName and CIV.dist2D(pt.point, point) <= radius then
      res[#res + 1] = pt
    end
  end
  return res
end

CIV.log("PointPool caricato")
