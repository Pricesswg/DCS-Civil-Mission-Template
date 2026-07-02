# Guida setup Mission Editor

Come collegare il template a una missione. Tutto in Lua puro nativo: nessun
MIST/MOOSE/CTLD da caricare.

## 1. Caricamento script

Trigger `MISSION START` (o `ONCE / TIME MORE(1)`) con azioni `DO SCRIPT FILE`
in QUESTO ordine:

```
01_CivConfig.lua
02_CivCore.lua
03_HoverZoneTrigger.lua
04_PointPool.lua
05_ScoreSystem.lua
06_ZoneDressing.lua
10_FireZoneManager.lua
11_Firefighting_Heli.lua
12_Firefighting_C130.lua
20_SAR.lua
30_Polizia_Inseguimento.lua
31_Polizia_SWAT.lua
40_Trasporto_Tier.lua
50_MedEvac.lua
99_CivMain.lua
```

I moduli non usati si possono semplicemente omettere (tranne 01–05 che sono la
base comune; 06 serve solo se si vogliono le aree arredate). `99_CivMain` va
sempre per ultimo.

## 2. Zone da creare in ME

Convenzione: **prefisso + indice a 2 cifre partendo da 01, senza buchi** (la
scansione si ferma al primo indice mancante). Tutte le zone devono essere
**circolari** (i vertici delle quad zone non sono leggibili da script nativo).

| Zona/e | Uso | Note di piazzamento |
|---|---|---|
| `CIV_FUOCO_REGIONE` | macro-regione antincendio | grande, contiene i punti fuoco; abilita spotter e rilascio C-130 |
| `CIV_FUOCO_P01…` | punti incendio | bosco/campi, lontani da edifici e strade |
| `CIV_ACQUA_P01…` | prelievo acqua elicotteri | su specchio d'acqua, spazio di manovra |
| `CIV_C130_RIFORN` | ricarica ritardante C-130 | su piazzale/rullaggio raggiungibile a terra; viene arredata col kit carico |
| `CIV_SARM_REGIONE` + `CIV_SARM_P01…` | SAR montagna | punti su terreno raggiungibile in hover |
| `CIV_SARS_REGIONE` + `CIV_SARS_P01…` | SAR mare | punti su acqua APERTA (ci spawna un'imbarcazione) |
| `CIV_POL_P01…` | inseguimento | 30–40 punti SUGLI INCROCI reali, distanza tra vicini ≤ 1500 m (config `raggioVicini`) |
| `CIV_SWAT_BASE` | imbarco squadra | piazzale dove l'elicottero può atterrare |
| `CIV_SWAT_P01…` | scenari SWAT | tetti/LZ urbane (spawn su tetto DA TESTARE) |
| `CIV_CARGO_P01…` | punti di carico materiale | terreno piano |
| `CIV_CARGO_DEST` | consegna materiale | zona unica di destinazione |
| `CIV_MEDEVAC_P01…` | recupero feriti | LZ "ostili"/incidenti |
| `CIV_OSPEDALE_P01…` | piazzole ospedale | sulla piazzola vera; vengono arredate col kit campo medico; consegna rilevata A ZONA (fermo+basso), non serve FARP |

I prefissi sono modificabili in `01_CivConfig.lua` → `CIV.Config.zone`.

## 3. Configurazione minima da rivedere

In `01_CivConfig.lua`:

- `countryId`: un paese presente nella coalizione blu della missione.
- `capacita`: aggiungere i tipi esatti dei moduli usati dal gruppo
  (nome tipo DCS, es. `CH-47Fbl1`) con i kg di carico esterno.
- `cargo.tiers`: kg e tipo cargo per tier (tipo da validare in ME: alcuni
  cargo hanno massa fissa).
- `hover.*`: tempi T/finestre per tipo di operazione.
- `director`: probabilità/intervalli della generazione automatica eventi
  (oppure `abilitato = false` e si avvia tutto dal menu Admin).
- `adminMenu = false` per le serate ufficiali.

## 4. In gioco

Menu `F10 → Missioni Civili`:

- **Classifica di sessione** — punteggio live condiviso.
- **Antincendio** — inizia prelievo acqua / sgancia acqua / incendi attivi.
- **Antincendio C-130** — avvia rilascio in linea (dopo ricarica a terra).
- **Polizia / SWAT** — imbarca squadra / stato squadra.
- **Trasporto materiale** — cambia tier del punto vicino / punti attivi.
- **Admin (test)** — avvio manuale di ogni tipo di evento, stato pool.

## 5. Checklist di test in-game (prima dell'uso serio)

Dal concept, sezione "Punti che richiedono test empirico" — in ordine
suggerito:

1. Pool e menu: avviare ogni evento dal menu Admin e verificare messaggi/spawn.
2. Hover: prelievo acqua + un SAR completo fino alla consegna in ospedale.
3. Tipi cargo: verificare in ME che i tipi in config accettino la massa
   personalizzata (pesarli agganciandoli).
4. "On Road": osservare 2–3 inseguimenti interi sugli incroci del pool.
5. SWAT: spawn fanteria su un tetto del pool.
6. (Solo se interessa) `fuoco.usaCargoFisico = true`: spawn cargo su acqua.
7. (Solo se interessa) beacon: mettere il file `.ogg` nella .miz e attivare
   `sar.montagna.beacon.abilitato`.
