# Verifica di fattibilità — punto per punto

Riscontro tecnico del concept (`docs/CONCEPT.md`) rispetto all'implementazione
in `Scripts/`. Legenda: ✅ confermato e implementato · ⚠️ implementato ma da
testare in-game · ❌ da correggere/decidere.

> Aggiornato alla v0.2: struttura a 5 file (core + un file per tipo di
> intervento) + build a file unico (`tools/build.sh` →
> `dist/CivilMissionTemplate.lua`); codice in inglese; scanner zone/template
> via `env.mission` adottato dal 527th CSAR System.

## Confermato e implementato ✅

| Punto del concept | Esito | Dove |
|---|---|---|
| `S_EVENT_LAND` solo su airbase/FARP/nave: consegna a zona | ✅ Corretto. Consegna rilevata con fermo/basso in zona per X s | `20_CivilRescue.lua` (loop delivery) |
| Hover come polling di `getVelocity`/`getPoint`, non task AI | ✅ Nessuna API mancante, tutto nativo | `01_CivilCore.lua` (`CIV.Hover`) |
| T pavimento + malus B (mai bonus) + finestra con esito narrativo | ✅ `rate = 1/(1+B·instability)`, progresso congelato fuori inviluppo | `CIV.Hover` |
| Niente malus meteo scriptato (il vento agisce già sul modello di volo) | ✅ Il malus misura la deviazione reale, nient'altro | `CIV.Hover` |
| Stato per unità/gruppo, mai globale (eventi paralleli) | ✅ Sessioni hover, incendi, inseguimenti, carichi: tutti keyed per id/unità | tutti i moduli |
| Randomizzazione una-tantum a inizio evento (no jitter per tick) | ✅ `CIV.randBetween` chiamato solo alla creazione dell'evento | firefighting, police |
| Macro-regione + pool di punti curati con distanza minima | ✅ Matching per prefisso nome, `pick` con esclusione punti occupati | `CIV.Pool` |
| Nessuna trigger zone creata a runtime (API inesistente) | ✅ Solo zone ME + tabelle config | ovunque |
| `coalition.addStaticObject` con `mass`/`canCargo` nativi | ✅ Implementato; cambio massa = despawn+respawn (nessun setter runtime) | `CIV.spawnCargo`, `40_CivilTransport.lua` |
| Tier fissi + gate heavy-lift + etichetta per soglia di capacità | ✅ Gate su `CIV.typesPresent` (aggiornato su `S_EVENT_BIRTH`, copre i cambi slot MP) | `40_CivilTransport.lua` |
| Cambio tier via F10 con delay 20–30 s | ✅ 25 s in config, despawn→attesa→respawn | `40_CivilTransport.lua` |
| Tabella tipo→capacità mantenuta a mano (API non la espone) | ✅ Confermato: il descrittore dà `massEmpty`/`fuelMassMax`, non il carico esterno | `CIV.Config.capacity` |
| Embark/disembark nativi = AI-to-AI, inadatti | ✅ Fast-rope = hover + `coalition.addGroup` scriptato | `30_CivilPolice.lua` |
| Squadra SWAT dimensionata all'IMBARCO, non allo sbarco | ✅ Stato per unità fissato alla base | `30_CivilPolice.lua` |
| C-130: ricarica a terra (stato logico) + rilascio in linea 150–250 m | ✅ Banda quota in config, rilascio applicato lungo la traiettoria per N s | `10_CivilFirefighting.lua` |
| C-130 spotter: coordinate + marker F10 | ✅ `markToCoalition` nativo + cerchi `circleToAll` (stile CSAR) | firefighting, rescue |
| `effectSmokeBig`/`effectSmokeStop` con stato per zona | ✅ Preset scala con l'intensità; lo stop richiede il *name* (param dal 2.7.10 ca.) | `10_CivilFirefighting.lua` |
| Beacon `radioTransmission` con fallback coordinate | ✅ Implementato con `pcall` + fallback automatico; disattivo di default (serve `.ogg` nella .miz). In più: fumogeno su richiesta stile CSAR | `20_CivilRescue.lua` |
| Punteggio: funzione pura + pesi difficoltà fissati ora + broadcast live | ✅ `CIV.Score.compute` senza stato; pesi in config; `outTextForCoalition` | `CIV.Score` |
| Pathfinding "On Road" inaffidabile (bug noto) | ✅ Implementato CON watchdog: rilancio rotta dopo 45 s fermo, fallback "Off Road" al 2° blocco | `30_CivilPolice.lua` |
| Aree arredate: static passivi in zone ME fisse, no check planarità | ✅ Kit `medical_camp` / `c130_loading_area` / `refugee_camp` | `CIV.Dressing` |
| MedEvac: criticità come variabile di punteggio | ✅ Qualità = frazione di criticità residua; deadline scaduta = deceduto | `20_CivilRescue.lua` |
| Riuso `527th_CSARSystem.lua` | ✅ Adottati: scanner `env.mission` (zone poligonali + proprietà + template), cerchi mappa, MGRS/DDM, fumogeno soggetto, atan2/bearing, id univoci anti-collisione | `01_CivilCore.lua` |

## Implementato ma DA TESTARE in-game ⚠️

Coincidono con la lista del concept; ogni punto ha una via di fuga già pronta.

1. **Cargo su acqua aperta** — dietro flag `fire.usePhysicalCargo = false`
   (default: carico logico + sgancio F10, robusto). Attivare solo dopo test
   in ME.
2. **Rilevamento consegna cargo slingato via polling posizione** — da
   verificare che l'oggetto agganciato aggiorni `getPoint()` e sopravviva
   allo sgancio. Fallback: consegna "a zona + giocatore vicino" (già usata
   per il rescue).
3. **"On Road" sugli incroci reali della mappa scelta** — watchdog e fallback
   inclusi, ma il pool di 30–40 punti va validato incrocio per incrocio.
4. **Spawn fanteria su mesh tetto (SWAT)** — in caso negativo si sposta la LZ
   a livello strada.
5. **Tipo cargo che accetta `mass` personalizzata** — i tipi in
   `CIV.Config.cargo.tiers` (`uh1h_cargo`, `container_cargo`,
   `iso_container*`) vanno confermati in ME: alcuni tipi hanno massa fissa.
6. **Nomi tipo di fallback** (`ZWEZDNY`, `LandRover_ah`, static dei kit) —
   variano per mappa/versione; mitigazione: usare i template late-activated
   (`CIVIL Survivor`, ecc.) che eliminano il problema; gli spawn dei kit sono
   in `pcall`, un tipo sbagliato logga e non blocca il resto.
7. **Beacon `.ogg` + homing** — ostico come da concept: default disattivo.
8. **Task `Hold` per l'arresto del fuggitivo** — se su unità ground non
   fermasse il gruppo, alternativa: rotta di un solo punto sulla posizione
   corrente.

## Correzioni / precisazioni rispetto al concept ❌→

- **`world.setPersistenceHandler`**: NON ho trovato riscontro che esista come
  API nativa documentata — da verificare prima di contarci per la leaderboard
  persistente. Le altre due opzioni (hook lato server; parser di `dcs.log`)
  sono solide. Nel frattempo `CIV.Score.award` scrive già su `dcs.log` una
  riga parsabile per ogni task (`SCORE|player|tipo|punti|q|t`): l'opzione 3 è
  pronta lato missione, a costo zero.
- **Zone poligonali (quad zone)**: `trigger.misc.getZone` restituisce solo
  centro+raggio, MA le zone (con vertici `verticies` e proprietà) sono
  leggibili da **`env.mission.triggers.zones`**, come fa il 527th CSAR System
  già collaudato in campo. Il template usa questo scanner: **le zone possono
  essere circolari o poligonali**.
- **Enumerazione zone**: con lo scanner `env.mission` il matching è per
  **prefisso sul nome** (stile "CSAR Zone …"): niente numerazione obbligatoria
  01..N senza buchi.
- **Spawn da template**: adottato il pattern "CSAR Pilot" — gruppi
  late-activated in ME clonati a runtime, con fallback sui tipi hardcodati se
  il template manca.

## Decisioni ancora aperte (invariate dal concept)

- Leaderboard live vs consolidata a fine missione (le righe `SCORE|` su
  `dcs.log` supportano già entrambe via parser esterno).
- Valori kg definitivi dei tier e della tabella capacità.
- Modulo Black Hawk: verificare tipo esatto e cosa supporta (aggiungerlo a
  `CIV.Config.capacity` col nome tipo corretto).
- Priorità di sviluppo/test e realismo C-130 da confermare col gruppo.
