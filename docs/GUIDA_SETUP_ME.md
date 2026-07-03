# Guida setup Mission Editor

Come collegare il template a una missione. Tutto in Lua puro nativo: nessun
MIST/MOOSE/CTLD da caricare.

## 1. Caricamento script

Due opzioni:

**A) File unico (consigliata per l'uso normale)** — un solo trigger
`MISSION START` con una sola azione `DO SCRIPT FILE`:

```
dist/CivilMissionTemplate.lua
```

**B) Modulare (per sviluppo/test)** — 5 azioni `DO SCRIPT FILE` in questo
ordine (il core per primo, gli altri in qualunque ordine; i moduli non usati
si possono omettere):

```
Scripts/01_CivilCore.lua        <- SEMPRE, per primo
Scripts/10_CivilFirefighting.lua
Scripts/20_CivilRescue.lua      (SAR montagna/mare + MedEvac)
Scripts/30_CivilPolice.lua      (inseguimento + SWAT)
Scripts/40_CivilTransport.lua
```

Dopo qualunque modifica in `Scripts/`, rigenerare il file unico con
`tools/build.sh` (o ricopiando a mano i 5 file in sequenza in un unico .lua).

## 2. Zone da creare in ME

Il matching è **per prefisso sul nome** (stile 527th CSAR): qualunque zona il
cui nome INIZIA con il prefisso appartiene a quel pool — ad es.
`CIVIL Fire Point Alpha`, `CIVIL Fire Point 12`, `CIVIL Fire Point Bosco`.
Non serve numerazione consecutiva. Le zone possono essere **circolari o
poligonali (quad zone)**: vertici e proprietà vengono letti da `env.mission`.

| Prefisso / nome zona | Uso | Note di piazzamento |
|---|---|---|
| `CIVIL Fire Region` | macro-regione antincendio | grande; abilita spotter e rilascio C-130 |
| `CIVIL Fire Point …` | punti incendio | bosco/campi, lontani da edifici e strade |
| `CIVIL Water Point …` | prelievo acqua elicotteri | su specchio d'acqua, spazio di manovra |
| `CIVIL C130 Reload` | ricarica ritardante C-130 | piazzale raggiungibile a terra; arredata col kit carico |
| `CIVIL SAR Mountain Region` + `CIVIL SAR Mountain Point …` | SAR montagna | punti raggiungibili in hover |
| `CIVIL SAR Sea Region` + `CIVIL SAR Sea Point …` | SAR mare | punti su acqua APERTA (ci spawna un'imbarcazione) |
| `CIVIL Police Point …` | inseguimento | 30–40 punti SUGLI INCROCI reali, distanza tra vicini ≤ 1500 m |
| `CIVIL SWAT Base` | imbarco squadra | piazzale dove l'elicottero può atterrare |
| `CIVIL SWAT Point …` | scenari SWAT | tetti/LZ urbane (spawn su tetto DA TESTARE) |
| `CIVIL Cargo Point …` | punti di carico materiale | terreno piano |
| `CIVIL Cargo Destination` | consegna materiale | zona unica di destinazione |
| `CIVIL Medevac Point …` | recupero feriti | LZ "ostili"/incidenti |
| `CIVIL Hospital …` | piazzole ospedale | sulla piazzola vera; arredate col kit campo medico; consegna rilevata A ZONA (fermo+basso), non serve FARP |

I prefissi sono modificabili in `CIV.Config.zones` (testa di `01_CivilCore.lua`).

## 3. Template di spawn opzionali (stile CSAR Pilot)

Gruppi **late-activated** piazzati in ME: se esistono, gli spawn vengono
clonati da lì (unità, skin, country) invece di usare i tipi di fallback
hardcodati. Matching per prefisso sul nome del gruppo:

| Prefisso gruppo | Uso | Fallback se assente |
|---|---|---|
| `CIVIL Survivor …` | disperso SAR montagna / ferito MedEvac (ground) | `Soldier M4` |
| `CIVIL Boat …` | bersaglio SAR mare (ship) | `ZWEZDNY` |
| `CIVIL SWAT Team …` | squadra SWAT (ground; il numero di unità viene scalato allo sbarco) | `Soldier M4` |
| `CIVIL Fugitive …` | auto in fuga (vehicle) | `LandRover_ah` |

## 4. Configurazione minima da rivedere

In testa a `01_CivilCore.lua` (`CIV.Config`):

- `countryId`: un paese presente nella coalizione blu della missione.
- `capacity`: tipi esatti dei moduli usati dal gruppo con i kg di carico
  esterno (l'API non li espone: tabella a mano, valori DA VALIDARE).
- `cargo.tiers`: kg e tipo cargo per tier (alcuni tipi cargo hanno massa
  fissa: validare in ME).
- `hover.*`: tempi T/finestre per tipo di operazione.
- `director`: probabilità/intervalli della generazione automatica
  (oppure `enabled = false` e si avvia tutto dal menu Admin).
- `adminMenu = false` per le serate ufficiali.

## 5. In gioco

Menu `F10 → Civil Missions`:

- **Session leaderboard** — punteggio live condiviso.
- **Firefighting** — prelievo acqua / sgancio / incendi attivi.
- **Firefighting C-130** — rilascio in linea (dopo ricarica a terra).
- **Rescue** — fumogeno dal soggetto / eventi attivi.
- **Police / SWAT** — imbarco squadra / stato squadra.
- **Cargo transport** — cambio tier del punto vicino / punti attivi.
- **Admin (test)** — avvio manuale di ogni evento, stato pool.

## 6. Checklist di test in-game (prima dell'uso serio)

1. Pool e menu: avviare ogni evento dal menu Admin e verificare messaggi/spawn.
2. Hover: prelievo acqua + un SAR completo fino alla consegna in ospedale.
3. Tipi cargo: verificare in ME che i tipi in config accettino la massa
   personalizzata (pesarli agganciandoli).
4. "On Road": osservare 2–3 inseguimenti interi sugli incroci del pool.
5. SWAT: spawn fanteria su un tetto del pool.
6. (Solo se interessa) `fire.usePhysicalCargo = true`: spawn cargo su acqua.
7. (Solo se interessa) beacon: file `.ogg` nella .miz e
   `rescue.sarMountain.beacon.enabled = true`.
