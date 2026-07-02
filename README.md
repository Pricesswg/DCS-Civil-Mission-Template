# DCS Civil Mission Template

Template modulare per missioni civili in DCS World — antincendio, SAR
montagna/mare, MedEvac, polizia (inseguimento e SWAT), trasporto materiale a
tier — in **Lua puro nativo** (nessun MIST/MOOSE/CTLD).

## Struttura

```
Scripts/
  01_CivConfig.lua           Configurazione centrale (zone, tier, capacità, punteggi)
  02_CivCore.lua             Utility, registro giocatori, messaggi, menu F10
  03_HoverZoneTrigger.lua    Modulo hover condiviso (T + malus stabilità + finestra)
  04_PointPool.lua           Macro-regioni + pool di punti curati
  05_ScoreSystem.lua         Punteggio di sessione (funzione pura + classifica F10)
  06_ZoneDressing.lua        Aree arredate (campo medico, zona carico C-130, ...)
  10_FireZoneManager.lua     Incendi: accensione, intensità, fumo/fuoco
  11_Firefighting_Heli.lua   Antincendio elicotteri (prelievo in hover + sgancio)
  12_Firefighting_C130.lua   Antincendio C-130 (ricarica a terra + linea) + spotter
  20_SAR.lua                 Motore SAR generico + istanze Montagna e Mare
  30_Polizia_Inseguimento.lua  Inseguimento con pressione + watchdog "On Road"
  31_Polizia_SWAT.lua        Imbarco squadra + inserimento fast-rope
  40_Trasporto_Tier.lua      Carichi a tier fissi con gate heavy-lift
  50_MedEvac.lua             Recupero feriti con timer di criticità
  99_CivMain.lua             Direttore eventi + menu Admin (caricare per ultimo)
docs/
  CONCEPT.md                 Brief di design (decisioni e verifiche)
  FATTIBILITA.md             Verifica punto-per-punto concept vs implementazione
  GUIDA_SETUP_ME.md          Zone da creare in ME, ordine di caricamento, checklist test
```

## Quick start

1. Creare in Mission Editor le zone elencate in `docs/GUIDA_SETUP_ME.md`
   (convenzione `PREFISSO + 01..N`, zone circolari).
2. Caricare gli script con `DO SCRIPT FILE` nell'ordine numerico
   (`99_CivMain.lua` per ultimo).
3. In gioco: `F10 → Missioni Civili`.

## Stato

Struttura iniziale completa e sintatticamente verificata (Lua 5.1) con smoke
test su mock delle API. **Non ancora testata in DCS**: i punti che richiedono
test empirico in-game sono elencati in `docs/FATTIBILITA.md` (sezione ⚠️) con
i relativi fallback già inclusi.
