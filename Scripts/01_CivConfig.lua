--[[
  01_CivConfig.lua — Configurazione centrale del template Missioni Civili
  Lua puro nativo DCS: nessuna dipendenza da MIST/MOOSE/CTLD.

  Tutti i valori "DA VALIDARE" vanno confermati in Mission Editor / in-game
  prima di considerarli definitivi (vedi docs/FATTIBILITA.md).

  Ordine di caricamento (DO SCRIPT FILE, MISSION START):
    01_CivConfig -> 02_CivCore -> 03_HoverZoneTrigger -> 04_PointPool
    -> 05_ScoreSystem -> 06_ZoneDressing -> moduli 10..50 -> 99_CivMain
]]

CIV = CIV or {}
CIV.VERSION = "0.1.0"

CIV.Config = {

  -- Paese usato per gli spawn scriptati (deve esistere nella coalizione blu in ME)
  countryId  = country.id.USA,
  coalition  = coalition.side.BLUE,

  debug      = true,   -- log estesi su dcs.log (env.info)
  adminMenu  = true,   -- sottomenu F10 "Admin" per avviare eventi a mano (test)

  ------------------------------------------------------------------
  -- Convenzione naming zone ME: PREFISSO + indice a 2 cifre (es. CIV_FUOCO_P01)
  -- I pool vengono scansionati da 01 in su finché la zona esiste.
  ------------------------------------------------------------------
  zone = {
    fuocoRegione    = "CIV_FUOCO_REGIONE",   -- macro-regione antincendio (zona circolare grande)
    fuocoPool       = "CIV_FUOCO_P",         -- pool punti incendio
    acquaPool       = "CIV_ACQUA_P",         -- pool punti prelievo acqua (su specchio d'acqua)
    c130Rifornimento= "CIV_C130_RIFORN",     -- zona ricarica ritardante a terra
    sarMontRegione  = "CIV_SARM_REGIONE",
    sarMontPool     = "CIV_SARM_P",
    sarMareRegione  = "CIV_SARS_REGIONE",
    sarMarePool     = "CIV_SARS_P",
    poliziaPool     = "CIV_POL_P",           -- incroci cittadini (30-40 punti)
    swatBase        = "CIV_SWAT_BASE",
    swatPool        = "CIV_SWAT_P",
    cargoPool       = "CIV_CARGO_P",         -- punti di carico materiale
    cargoDest       = "CIV_CARGO_DEST",      -- zona di consegna materiale
    medevacPool     = "CIV_MEDEVAC_P",
    ospedalePool    = "CIV_OSPEDALE_P",      -- piazzole ospedale (rilevamento a zona, NON S_EVENT_LAND)
  },

  ------------------------------------------------------------------
  -- HoverZoneTrigger: parametri per tipo di task.
  -- T       = tempo minimo richiesto (s), pavimento non riducibile
  -- window  = finestra totale (s) dall'inizio hover, scaduta -> fallimento
  -- B       = fattore malus instabilità (solo rallenta, mai accelera)
  -- maxSpeed/radius/minAGL/maxAGL = inviluppo dell'hover valido
  ------------------------------------------------------------------
  hover = {
    prelievoAcqua = { T = 60,  window = 600,  B = 2.0, maxSpeed = 3.0, radius = 40, minAGL = 8,  maxAGL = 30 },
    sarMontagna   = { T = 300, window = 1500, B = 2.0, maxSpeed = 2.5, radius = 30, minAGL = 3,  maxAGL = 25 },
    sarMare       = { T = 300, window = 1500, B = 2.5, maxSpeed = 2.5, radius = 30, minAGL = 5,  maxAGL = 25 },
    medevac       = { T = 240, window = 1200, B = 2.0, maxSpeed = 2.5, radius = 30, minAGL = 3,  maxAGL = 25 },
    fastRope      = { T = 90,  window = 900,  B = 3.0, maxSpeed = 2.0, radius = 20, minAGL = 5,  maxAGL = 30 },
  },

  ------------------------------------------------------------------
  -- Punteggio: pesi di difficoltà per tipo task (fissati ORA, come da concept).
  -- punti = base * (0.5 + 0.35*qualita + 0.15*fattoreTempo)   [vedi 05_ScoreSystem]
  ------------------------------------------------------------------
  score = {
    base = {
      incendioHeli   = 15,
      incendioC130   = 12,
      sarMontagna    = 20,
      sarMare        = 25,   -- mare con onde vale più del trasporto piano
      medevac        = 20,
      inseguimento   = 15,
      swat           = 20,
      trasporto      = 10,   -- moltiplicato dal tier (vedi sotto)
    },
    tierMult = { LEGGERO = 1.0, MEDIO = 1.5, PESANTE = 2.2, HEAVY = 3.0 },
    broadcast = true,        -- annuncio a coalizione ad ogni task completato (competizione live)
  },

  ------------------------------------------------------------------
  -- Trasporto materiale: tier di massa fissi (kg). DA VALIDARE con capacità
  -- reali dei moduli (l'API non espone il carico esterno max: tabella a mano).
  ------------------------------------------------------------------
  cargo = {
    tiers = {
      LEGGERO = { kg = 600,   tipo = "uh1h_cargo" },
      MEDIO   = { kg = 1500,  tipo = "container_cargo" },
      PESANTE = { kg = 3000,  tipo = "iso_container_small" },
      HEAVY   = { kg = 8000,  tipo = "iso_container" },   -- generato solo se presente heavy-lift
    },
    -- ATTENZIONE: alcuni tipi cargo ignorano il campo mass (massa fissa).
    -- I tipi qui sopra vanno confermati in ME prima di fissare la tabella.
    pesiTier   = { LEGGERO = 35, MEDIO = 35, PESANTE = 30 }, -- pesi random % (HEAVY gestito dal gate)
    delayCambioTier = 25,    -- s, costo reale del cambio tier via F10
    sogliaHeavyKg   = 6000,  -- capacità minima per abilitare il tier HEAVY in missione
    maxAttivi       = 3,
    raggioAvviso    = 1000,  -- m, avviso mezzo non adatto all'arrivo sul punto
  },

  -- Tabella tipo velivolo -> capacità carico esterno (kg). MANTENUTA A MANO,
  -- l'API non la espone. Valori indicativi DA VALIDARE coi moduli reali.
  capacita = {
    ["UH-1H"]            = 1700,
    ["Mi-8MT"]           = 3000,
    ["Mi-24P"]           = 2400,
    ["SA342M"]           = 700,
    ["SA342L"]           = 700,
    ["CH-47Fbl1"]        = 10800,
    ["UH-60L"]           = 4000,   -- se mod presente: verificare nome tipo esatto
    ["OH58D"]            = 900,
  },

  ------------------------------------------------------------------
  -- Antincendio
  ------------------------------------------------------------------
  fuoco = {
    maxAttivi        = 3,
    intervalloAvvio  = { min = 600, max = 1800 },  -- s tra accensioni automatiche
    intensitaInit    = 1.0,
    crescitaOraria   = { min = 0.1, max = 0.5 },   -- randomizzata UNA volta per incendio
    acquaHeli        = 0.4,    -- riduzione intensità per sgancio elicottero
    ritardanteC130   = 0.12,   -- riduzione/secondo durante il rilascio in linea
    durataRilascioC130 = 10,   -- s di rilascio in linea
    quotaRilascio    = { min = 120, max = 300 },   -- m AGL banda valida C-130 (nominale 150-250)
    raggioSgancio    = 300,    -- m, distanza max dal fuoco perché lo sgancio conti
    ricaricaC130     = 60,     -- s fermo in zona rifornimento per ricaricare
    spotterIntervallo= 180,    -- s tra i report del C-130 spotter
    usaCargoFisico   = false,  -- true = spawn Cargo con massa su acqua (SPERIMENTALE, da testare)
    cargoAcquaTipo   = "uh1h_cargo",
    cargoAcquaKg     = 1000,
  },

  ------------------------------------------------------------------
  -- SAR (montagna e mare condividono il motore, 20_SAR.lua)
  ------------------------------------------------------------------
  sar = {
    montagna = {
      maxAttivi = 2,
      unita     = { tipo = "Soldier M4", categoria = "ground" },
      beacon    = { abilitato = false,   -- richiede file .ogg dentro la .miz (l.10 MHz, ostico: vedi concept)
                    file = "l10-beacon.ogg", freqHz = 40500000, modulation = 1, power = 100 },
    },
    mare = {
      maxAttivi = 2,
      unita     = { tipo = "ZWEZDNY", categoria = "ship" },  -- imbarcazione in panne; zattera se mod disponibile
      beacon    = { abilitato = false },
    },
  },

  ------------------------------------------------------------------
  -- Polizia
  ------------------------------------------------------------------
  polizia = {
    maxInseguimenti  = 2,
    autoTipo         = "LandRover_ah",       -- auto in fuga, DA VALIDARE su mappa scelta
    velocitaMax      = { min = 12, max = 22 },  -- m/s, randomizzata a inizio evento
    raggioPressione  = 500,   -- m, elicottero entro il raggio -> pressione sale
    rateSalita       = { min = 2.0, max = 4.0 },   -- %/s, randomizzato a inizio inseguimento
    rateDecad        = { min = 1.0, max = 3.0 },
    hopWaypoint      = 3,     -- punti del percorso generati in anticipo (random walk locale)
    raggioVicini     = 1500,  -- m, "punti vicini" per il random walk
  },
  swat = {
    squadra      = { tipo = "Soldier M4", numMin = 4, numMax = 8 },
    tempoImbarco = 20,   -- s fermo alla base per imbarcare
    risoluzione  = 300,  -- s dopo l'inserimento perché la squadra "risolva" lo scenario
  },

  ------------------------------------------------------------------
  -- Direttore eventi: generazione automatica (oltre agli avvii manuali Admin).
  -- intervallo = s tra i tentativi; probabilita = % che il tentativo generi
  -- l'evento (il tetto resta il maxAttivi di ciascun modulo).
  ------------------------------------------------------------------
  director = {
    abilitato  = true,
    intervallo = { min = 480, max = 1200 },
    moduli = {   -- chiave -> probabilita % (0 = solo avvio manuale)
      sarMontagna  = 25,
      sarMare      = 20,
      medevac      = 25,
      inseguimento = 25,
      swat         = 15,
      trasporto    = 40,
      -- gli incendi hanno già il loro scheduler dedicato (10_FireZoneManager)
    },
  },

  ------------------------------------------------------------------
  -- MedEvac
  ------------------------------------------------------------------
  medevac = {
    maxAttivi     = 2,
    unita         = { tipo = "Soldier M4", categoria = "ground" },
    criticita     = 1800,  -- s: il paziente "decade" in questo tempo; la qualità del punteggio
                           -- è la frazione di criticità residua alla consegna
    consegna      = { raggio = 40, maxSpeed = 2.0, maxAGL = 10, tempo = 15 }, -- rilevamento a zona in ospedale
  },
}
