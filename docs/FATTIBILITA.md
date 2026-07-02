# Verifica di fattibilità — punto per punto

Riscontro tecnico del concept (`docs/CONCEPT.md`) rispetto all'implementazione
in `Scripts/`. Legenda: ✅ confermato e implementato · ⚠️ implementato ma da
testare in-game · ❌ da correggere/decidere.

## Confermato e implementato ✅

| Punto del concept | Esito | Dove |
|---|---|---|
| `S_EVENT_LAND` solo su airbase/FARP/nave: consegna a zona | ✅ Corretto. Consegna rilevata con fermo/basso in zona per X s | `20_SAR.lua` (loop consegna) |
| Hover come polling di `getVelocity`/`getPoint`, non task AI | ✅ Nessuna API mancante, tutto nativo | `03_HoverZoneTrigger.lua` |
| T pavimento + malus B (mai bonus) + finestra con esito narrativo | ✅ `rate = 1/(1+B·instabilità)`, progresso congelato fuori inviluppo | `03_HoverZoneTrigger.lua` |
| Niente malus meteo scriptato (il vento agisce già sul modello di volo) | ✅ Il malus misura la deviazione reale, nient'altro | `03_HoverZoneTrigger.lua` |
| Stato per unità/gruppo, mai globale (eventi paralleli) | ✅ Sessioni hover, incendi, inseguimenti, carichi: tutti keyed per id/unità | tutti i moduli |
| Randomizzazione una-tantum a inizio evento (no jitter per tick) | ✅ `CIV.randBetween` chiamato solo alla creazione dell'evento | `10`, `30` |
| Macro-regione + pool di punti curati con distanza minima | ✅ Convenzione `PREFISSO##`, scansione da 01, `pick` con esclusione punti occupati | `04_PointPool.lua` |
| Nessuna trigger zone creata a runtime (API inesistente) | ✅ Solo zone ME + tabelle config | ovunque |
| `coalition.addStaticObject` con `mass`/`canCargo` nativi | ✅ Implementato; cambio massa = despawn+respawn (nessun setter runtime) | `02` (`spawnCargo`), `40` |
| Tier fissi + gate heavy-lift + etichetta per soglia di capacità | ✅ Gate su `CIV.tipiPresenti` (aggiornato su `S_EVENT_BIRTH`, copre i cambi slot MP) | `40_Trasporto_Tier.lua` |
| Cambio tier via F10 con delay 20–30 s | ✅ 25 s in config, despawn→attesa→respawn | `40_Trasporto_Tier.lua` |
| Tabella tipo→capacità mantenuta a mano (API non la espone) | ✅ Confermato: il descrittore dà `massEmpty`/`fuelMassMax`, non il carico esterno | `01_CivConfig.lua` (`capacita`) |
| Embark/disembark nativi = AI-to-AI, inadatti | ✅ Fast-rope = hover + `coalition.addGroup` scriptato | `31_Polizia_SWAT.lua` |
| Squadra SWAT dimensionata all'IMBARCO, non allo sbarco | ✅ Stato per unità fissato alla base | `31_Polizia_SWAT.lua` |
| C-130: ricarica a terra (stato logico) + rilascio in linea 150–250 m | ✅ Banda quota in config, rilascio applicato lungo la traiettoria per N s | `12_Firefighting_C130.lua` |
| C-130 spotter: coordinate + marker F10 | ✅ `trigger.action.markToCoalition` è nativo | `12`, `20` |
| `effectSmokeBig`/`effectSmokeStop` con stato per zona | ✅ Preset scala con l'intensità; lo stop richiede il *name* (param dal 2.7.10 ca.) | `10_FireZoneManager.lua` |
| Beacon `radioTransmission` con fallback coordinate | ✅ Implementato con `pcall` + fallback automatico; disattivo di default (serve `.ogg` nella .miz) | `20_SAR.lua` |
| Punteggio: funzione pura + pesi difficoltà fissati ora + broadcast live | ✅ `CIV.Score.compute` senza stato; pesi in config; `outTextForCoalition` | `05_ScoreSystem.lua` |
| Pathfinding "On Road" inaffidabile (bug noto) | ✅ Implementato CON watchdog: rilancio rotta dopo 45 s fermo, fallback "Off Road" al 2° blocco | `30_Polizia_Inseguimento.lua` |
| Aree arredate: static passivi in zone ME fisse, no check planarità | ✅ Kit `campo_medico` / `zona_carico_c130` / `campo_profughi` | `06_ZoneDressing.lua` |
| MedEvac: criticità come variabile di punteggio | ✅ Qualità = frazione di criticità residua; deadline scaduta = deceduto | `50_MedEvac.lua` + motore in `20` |

## Implementato ma DA TESTARE in-game ⚠️

Coincidono con la lista del concept; ogni punto ha una via di fuga già pronta.

1. **Cargo su acqua aperta** — dietro flag `fuoco.usaCargoFisico = false`
   (default: carico logico + sgancio F10, robusto). Attivare il flag solo dopo
   test in ME.
2. **Rilevamento consegna cargo slingato via polling posizione** — da
   verificare che l'oggetto agganciato aggiorni `getPoint()` e che sopravviva
   allo sgancio. Se non funziona, il fallback è la consegna "a zona + giocatore
   vicino" (già usata per SAR).
3. **"On Road" sugli incroci reali della mappa scelta** — watchdog e fallback
   già inclusi, ma il pool di 30–40 punti va validato incrocio per incrocio.
4. **Spawn fanteria su mesh tetto (SWAT)** — nessuna mitigazione possibile a
   tavolino; in caso negativo si sposta la LZ a livello strada.
5. **Tipo cargo che accetta `mass` personalizzata** — i tipi in
   `Config.cargo.tiers` (`uh1h_cargo`, `container_cargo`, `iso_container*`)
   vanno confermati in ME: alcuni tipi hanno massa fissa.
6. **Nomi tipo degli static scenici** (`FARP Tent`, `Container_10ft`, ecc.) e
   dell'auto in fuga (`LandRover_ah`) — variano per mappa/versione; lo spawn è
   in `pcall`, un tipo sbagliato logga e non blocca il resto.
7. **Beacon `.ogg` + homing** — ostico come da concept: default disattivo.
8. **Task `Hold` per l'arresto del fuggitivo** — se su unità ground non
   fermasse il gruppo, alternativa: rotta di un solo punto sulla posizione
   corrente.

## Correzioni / precisazioni rispetto al concept ❌→

- **`world.setPersistenceHandler`**: NON ho trovato riscontro che esista come
  API nativa documentata — da verificare prima di contarci per la leaderboard
  persistente. Le altre due opzioni (hook lato server; parser di `dcs.log`)
  sono solide. Nel frattempo `05_ScoreSystem` scrive già su `dcs.log` una riga
  parsabile per ogni task (`SCORE|player|tipo|punti|q|t`): l'opzione 3 è
  quindi già pronta lato missione, a costo zero.
- **Zone poligonali (quad zone)**: `trigger.misc.getZone` restituisce solo
  centro+raggio; i vertici delle quad zone NON sono esposti al sandbox di
  missione. Tutte le zone del template devono quindi essere **circolari**. Il
  "corridoio poligonale" del C-130 è stato sostituito da macro-regione
  circolare + banda di quota: stesso gameplay, zero rischio API.
- **Enumerazione zone**: non esiste un'API per elencare le zone → la
  convenzione `PREFISSO + indice 01..N` (punto aperto del concept) è stata
  fissata e la scansione si ferma al primo indice mancante: **niente buchi
  nella numerazione**.

## Decisioni ancora aperte (invariate dal concept)

- Leaderboard live vs consolidata a fine missione (le righe `SCORE|` su
  `dcs.log` supportano già entrambe via parser esterno).
- Valori kg definitivi dei tier e della tabella capacità.
- Modulo Black Hawk: verificare tipo esatto e cosa supporta (aggiungerlo a
  `Config.capacita` col nome tipo corretto).
- Priorità di sviluppo/test e realismo C-130 da confermare col gruppo.
