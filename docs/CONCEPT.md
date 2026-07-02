# Missioni Civili DCS — Bozza Concept

Brief di design consolidato per l'implementazione (Lua puro nativo, nessun MIST/MOOSE/CTLD). Raccoglie le decisioni prese, le verifiche tecniche fatte su documentazione nativa, e i punti che restano da testare in-game o da decidere.

## Principi architetturali condivisi

Regole valide per **tutti** gli script, non solo per l'antincendio:

- **Carico/peso**: dove possibile si usa il sistema Cargo nativo di DCS (oggetti statici con massa, caricabili via comando radio F8 sui moduli che lo supportano) così il peso è reale sul modello di volo. Dove non esiste un equivalente nativo (es. ritardante per il C-130), il carico resta uno **stato logico** (variabile per unità) con notifica a schermo, non un vero peso fisico.
- **Eventi paralleli**: qualunque contatore/stato (pressione inseguimento, carico, timer di attivazione) va tenuto **per unità/gruppo**, mai in variabili globali. Deve essere possibile avere più incendi, più inseguimenti o più SAR attivi in contemporanea senza che si sporchino a vicenda.
- **Posizionamento eventi**: niente spawn su punti totalmente casuali nel terreno (rischio di finire in acqua bassa, dentro edifici, su strada trafficata). Sistema a due livelli:
  - **Macro-regione** (poligono ME) per raggruppare tematicamente un'area (es. zona incendi, zona SAR montagna, zona città per la polizia).
  - **Pool di punti curati** dentro la regione, piazzati a mano, tra cui lo script sceglie a random (con controllo di distanza minima da altri eventi attivi). Eccezione: aree davvero omogenee (es. bosco uniforme) dove un punto random con singolo controllo di validazione può bastare.
- **Variabilità**: i parametri di variazione (velocità di salita/decadimento, timing) vanno **randomizzati una sola volta all'inizio dell'evento**, non ad ogni tick. Jitter continuo tende a livellarsi statisticamente e diventa solo rumore illeggibile; un valore fissato per tutta la durata dà invece "carattere" riconoscibile all'evento.
- **Rilevamento hover condiviso (`HoverZoneTrigger`)**: un unico modulo riusato da qualunque operazione senza atterraggio pulito garantito — prelievo acqua antincendio, SAR montagna, SAR mare, MedEvac in scenario ostile, inserimento SWAT via fast-rope. Tecnicamente NON è un task assegnato a un controller AI (gli elicotteri operativi sono pilotati dai giocatori): è **polling dello stato dell'unità del giocatore** — `Unit:getVelocity()` per il modulo di velocità, `Unit:getPoint()` per posizione e quota, controllo di appartenenza alla zona, sostenuto per un tempo minimo. L'azione al successo (spawn, despawn, cambio stato) è specifica per missione e passata come callback, non incorporata nel modulo. Per la meccanica di completamento e i tempi, vedi sezione "Meccanica di hover e completamento".

## Meccanica di hover e completamento

Vale per tutte le operazioni basate su `HoverZoneTrigger` (SAR, MedEvac ostile, prelievo acqua, fast-rope).

- **T = tempo minimo richiesto** per l'operazione (fisso per tipo di task, es. 5 minuti). È un pavimento: non può mai scendere sotto questo valore.
- **B = fattore di stabilità dell'hover**, agisce **solo come malus**. Più il pilota è instabile (velocità/deviazione dal centro alte), più il timer avanza lentamente, allungando il tempo effettivo oltre T. Non può mai accelerare il completamento sotto T. Questo modella realisticamente il fatto che un hover ballerino prolunga il recupero, senza rendere T variabile verso il basso.
- **Finestra temporale**: dall'ingresso in hover parte una finestra più ampia di T (es. 20–25 min per un task da 5) entro cui completare. Scaduta la finestra → missione fallita con esito narrativo (il disperso è affogato, il paziente è deceduto, ecc.). La finestra serve proprio ad assorbire il tempo perso quando l'hover è impreciso e il timer rallenta.
- **Meteo**: il vento in DCS agisce già sul modello di volo, quindi condizioni ventose rendono l'hover oggettivamente più difficile **senza codice aggiuntivo** — il malus B lo cattura in automatico misurando la deviazione reale. Partire con questo solo effetto passivo; NON aggiungere una riduzione scriptata della tolleranza legata al meteo senza test, perché sommata all'effetto fisico del vento si rischia di penalizzare due volte la stessa causa e rendere l'operazione ingiocabile.
- Fattibilità nativa: stabilità e deviazione si misurano con `Unit:getVelocity()` e `Unit:getPoint()` campionati nel loop. Nessun framework esterno.

## Punteggio e leaderboard

- **Punteggio di sessione** (deciso): variabile Lua in memoria, incrementata per task completato, azzerata a fine missione. Nessun file, nessun hook, nessuna persistenza. È un feedback intra-sessione, non una classifica storica.
- **Peso di difficoltà per tipo di task (da fissare ORA, non dopo)**: i punti di ogni task vanno scalati da un moltiplicatore di difficoltà deciso per tipo (un SAR in mare con onde vale più di un trasporto cargo su terreno piano), altrimenti chi fa dieci task facili supera chi fa due task difficili fatti bene. Questo va dentro la funzione di punteggio: cambiarlo dopo significa ricalcolare tutto.
- **Funzione di punteggio pura**: progettare il calcolo come funzione `task + qualità + tempo → punti`, indipendente da dove vive il totale. Così il punteggio di sessione oggi e un'eventuale leaderboard persistente domani usano lo stesso calcolo; la persistenza è uno strato aggiunto sopra, non un prerequisito.
- **Competizione live intra-sessione**: un punteggio di sessione condiviso e visibile a tutti (`outTextForCoalition` o pannello F10) crea competizione in tempo reale tra i presenti, senza problemi di persistenza.
- **Persistenza tra sessioni (DECISIONE APERTA)**: non abbiamo i valori DCS classici (kill/morti), la metrica è tutta empirica nostra, quindi `S_EVENT_SCORE` non serve; il problema è **conservare** i nostri valori. Tre opzioni, la scelta dipende da un requisito ancora da fissare — la classifica deve aggiornarsi **durante** la sessione o basta che si consolidi **a fine missione**?
  - *Persistenza nativa* (`world.setPersistenceHandler`): commette a fine simulazione. Ok per classifica consolidata a fine missione/restart, NON live.
  - *Hook lato server + file esterno*: gli hook girano fuori dal sandbox, scrivono file liberamente, supportano aggiornamento live. Massima libertà.
  - *`env.info` su `dcs.log` + parser esterno*: la più semplice lato missione, sposta la logica di classifica fuori da DCS.

## Aree arredate (scenografia)

- **Decisione**: le aree arredate (campo profughi, centro medico da fronte, zona carico C-130) stanno in una **trigger zone fissa definita in ME**. Dentro la zona si spawnano static object scenici via `coalition.addStaticObject` (nativo). Non si crea nessuna trigger zone a runtime — non esiste un'API nativa per farlo, e non serve: la zona esiste già da ME.
- **Nessun check di planarità a runtime**: dato che il punto è scelto a mano in ME, la planarità è garantita in fase di design piazzando la zona su terreno piano. Il check `land.getHeight` serve solo per punti scelti a caso dal codice, che qui non è il caso.
- **Stesso pattern zona+condizione già usato altrove**: "unità in zona → può essere rifornita" (C-130), "player atterrato nel centro medico → consegna MedEvac" (rilevamento a zona, NON `S_EVENT_LAND`). L'arredamento è solo la veste scenica di zone che il sistema già gestisce.
- Preferire static object (passivi, economici) a unità AI per la pura scenografia; tenere d'occhio il conteggio se più aree sono attive in contemporanea (principio eventi paralleli).

## Antincendio

- **Elicotteri**: modulo `HoverZoneTrigger` sopra specchio d'acqua, quota di sicurezza (non radente), permanenza minima → al successo, spawn di un oggetto Cargo con massa (da validare se lo spawn funziona in modo affidabile su acqua aperta) → notifica al giocatore → carico via comando radio nativo → sgancio sopra zona incendio attiva.
- **C-130**: non fa scooping in volo (non è operativamente coerente con l'impiego reale, quello è compito di anfibi tipo Canadair CL-215/415). Ricarica a terra in una zona/FARP dedicata (stato logico, nessun "ritardante" nativo in DCS) e sgancia in linea sorvolando un corridoio poligonale a quota moderata (indicativamente 150–250 m, non 1–2 m).
- **C-130 come spotter**: se presente nell'area di una macro-regione antincendio, individua gli incendi attivi e ne passa le coordinate agli elicotteri (messaggio o marker F10), dando un motivo di gameplay per tenerlo in orbita sull'area.
- **FireZoneManager**: accensione random tra i punti del pool (o rejection sampling in aree omogenee), effetto fumo/fuoco con `effectSmokeBig`/`effectSmokeStop`, stato attivo/spento per zona.

## SAR Montagna

- Spawn di un disperso a terra con frequenza radio assegnata. **Un beacon scriptabile esiste** (`trigger.action.radioTransmission()` con frequenza in Hz a 9 cifre, oppure il comando `activateBeacon` per tipi NDB/VOR/TACAN), ma è utilizzabile solo dai moduli che sanno fare homing su radio beacon (Mi-8, Huey, Gazelle, AH-64D via NDB preset), richiede un file audio .ogg nella missione ed è segnalato come ostico da far funzionare in modo affidabile. Per gli altri moduli, fallback su coordinate passate via messaggio.
- Un C-130 presente in zona può fare da spotter e passare le coordinate a terra.
- **Estrazione**: stesso modulo `HoverZoneTrigger` usato per il prelievo acqua antincendio — l'elicottero deve restare in hover sopra la zona del disperso per un tempo minimo. Al successo: l'unità di terra che rappresenta il disperso viene despawnata (come se fosse stata caricata a bordo) e lo stato dell'elicottero registra il salvataggio. Alla consegna in ospedale non serve respawnare una persona: basta consumare un flag di stato "soggetto a bordo → salvato" (vedi sezione MedEvac per il meccanismo di rilevamento dell'atterraggio in ospedale, che NON può basarsi su `S_EVENT_LAND` a meno che la piazzola non sia un FARP/airbase definito).
- Possibile riuso parziale della logica già presente in `527th_CSARSystem.lua` (gestione frequenza, fallback ID missione).

## SAR Mare

- Naufraghi/imbarcazioni in panne come bersaglio (eventuale uso di mod di barche che affondano per l'effetto scenico).
- Il C-130 in area fa da spotter per la nave/imbarcazione e passa le coordinate agli elicotteri.
- **Estrazione**: stesso `HoverZoneTrigger` usato per SAR montagna e prelievo acqua antincendio, con l'unità/zattera posizionata su acqua aperta. A differenza dell'oggetto Cargo del prelievo acqua antincendio (spawn su acqua da verificare), un'unità/static galleggiante è un caso d'uso standard in DCS (spawn di unità navali su acqua), quindi il rischio tecnico qui è basso. Stessa logica di despawn-al-successo del SAR montagna.

## Polizia — Inseguimento

- Pool di 30–40 punti piazzati sugli incroci reali di una zona cittadina (macro-regione ravvicinata).
- Percorso generato scegliendo il prossimo waypoint tra i punti vicini al corrente (random walk locale, non salto casuale su tutta la mappa), con azione waypoint **"On Road"** per sfruttare il pathfinding stradale nativo di DCS. Da validare empiricamente l'affidabilità su incroci/salti diversi prima di fidarsi dell'intero pool.
- Meccanica di cattura: "pressione" che sale quando l'elicottero è nel raggio dell'auto e decade quando la si perde, soglia fissa al 100% per l'arresto. Rate di salita/decadimento randomizzati una volta a inizio inseguimento (non ad ogni tick), per dare varietà mantenendo leggibilità. Variabilità aggiuntiva possibile dando alla macchina una velocità massima casuale a inizio evento.
- Stato tenuto per unità/gruppo per supportare più inseguimenti paralleli nella stessa città.

## Polizia — SWAT

- Imbarco squadra, sbarco su tetti/palazzi per scenari tipo rapina/ostaggi.
- L'atterraggio di precisione su tetti non è affidabile su molte mesh degli edifici (carrello/skid senza collisione pulita). Non si usa un touchdown reale: l'inserimento è via **fast-rope**, stesso modulo `HoverZoneTrigger` già usato per antincendio/SAR/MedEvac — elicottero in hover sopra il tetto/LZ per un tempo minimo, poi spawn scriptato della squadra a terra (non esiste un equivalente nativo di fast-rope in DCS, quindi resta stato virtuale come per il ritardante del C-130).
- Il numero di soldati spawnati alla riuscita dell'hover deve provenire da uno stato tracciato al momento dell'imbarco alla base (stesso pattern usato per il tier di carico materiale), non da un valore deciso al momento dello sbarco.
- Da verificare: affidabilità dello spawn di unità di fanteria sulla mesh di un tetto. Rischio presumibilmente più basso rispetto a un touchdown di un elicottero (nessun contatto fisico da gestire), ma non dato per scontato senza test.
- **Nota verificata**: i task nativi di embark/disembark truppe (`embarking`, `embarkToTransport`) sono sistemi AI-to-AI, forzano l'atterraggio dell'elicottero AI e non permettono di scegliere liberamente la zona di sbarco. Non sono adatti a un fast-rope pilotato dal giocatore: la strada corretta è lo spawn scriptato del gruppo di fanteria via `coalition.addGroup` in Lua puro (nessuna dipendenza da framework esterni), al completamento dell'hover.

## Trasporto materiale civile — Sistema a tier

- Stessa logica a zone già validata altrove: macro-regione + pool di punti di carico curati, con generazione random del punto attivo.
- **Tier di massa fissi** (leggero / medio / pesante + un tier heavy-lift dedicato), non ricalcolati in base al mezzo che li seleziona: un carico fisico reale (trave, pallet di mattoni) ha una massa oggettiva indipendente da chi lo solleva, a differenza dell'acqua che si può dosare in volo — le bande relative sarebbero state incoerenti con la finzione simulativa.
- **Etichetta basata sulla soglia di capacità richiesta** ("richiede mezzo pesante"), non sul nome del velivolo specifico: evita di dover aggiungere una nuova etichetta esclusiva ogni volta che si introduce un nuovo mezzo pesante in roster.
- **Tier heavy-lift generato solo se in missione risulta presente almeno un tipo che soddisfa la soglia richiesta** (rilevamento dinamico, gate), altrimenti il punto resta al tier "pesante" normale — evita punti di carico strutturalmente irraggiungibili in sessioni senza il mezzo giusto.
- **Filtro all'arrivo sul punto**: avviso (non blocco) se il tipo di elicottero del giocatore non è adatto al tier generato in quel punto, calcolato dalla stessa tabella tipo→capacità già prevista per i limiti. Ricalcolato su `S_EVENT_BIRTH`, non solo allo spawn iniziale, per coprire i cambi di slot in corsa in multiplayer.
- **Cambio tier a richiesta**: voce radio F10 al punto di carico → sottomenu Leggero/Medio/Pesante, selezione libera in entrambe le direzioni (non solo declassamento: un mezzo heavy-lift può ricevere per caso un tier leggero, che per lui non è una sfida). Alla selezione: despawn del Cargo corrente, respawn con la massa del tier scelto nella stessa posizione, con un delay (20–30s, motivato come tempo di riequipaggiamento) per dare un costo reale al cambio — senza delay il sistema a tier diventa decorativo, perché ogni giocatore assesterebbe subito il carico al proprio mezzo.
- I valori kg effettivi per ciascun tier vanno ancorati alla capacità di carico esterno reale dei moduli previsti in missione (UH-1H, Mi-8, CH-47F ecc.), non inventati a tavolino — punto ancora da verificare con dati reali prima di fissare la tabella definitiva. Nota: la capacità di sollevamento NON è esposta dall'API per tipo di unità (il descrittore fornisce `massEmpty` e `fuelMassMax`, non un carico massimo esterno), quindi questa tabella va mantenuta a mano come dato di configurazione.
- **Verificato su documentazione nativa** (`coalition.addStaticObject`): gli oggetti cargo hanno i campi nativi `mass` (peso in kg) e `canCargo` (booleano, se sollevabile). Nessun framework esterno richiesto. **Precisazione importante**: la documentazione nativa avverte che *alcuni tipi* di oggetto cargo hanno massa fissa e ignorano il valore passato. Quindi il generatore di tier deve usare un tipo di cargo che accetta massa personalizzata, da confermare in ME per il tipo scelto — non è garantito che qualunque oggetto cargo accetti una massa arbitraria. La classe StaticObject non espone un metodo per modificare la massa a runtime, quindi il cambio tier va fatto con despawn + respawn dell'oggetto.

## MedEvac

- Recupero feriti verso un elipad ospedale, con timer di criticità che decade nel tempo come variabile di punteggio.
- **Consegna in ospedale — attenzione, correzione tecnica verificata**: `S_EVENT_LAND` scatta SOLO all'atterraggio su un oggetto Airbase, FARP o nave riconosciuto (campo `place` dell'evento), NON su terreno o coperture di edifici arbitrari. Le piazzole degli ospedali su Siria in genere non sono oggetti FARP/airbase definiti, quindi su di esse `S_EVENT_LAND` non scatta. La consegna va rilevata con lo stesso schema a zona (elicottero fermo/basso dentro una zona piazzata a mano sulla piazzola per X secondi), NON con `S_EVENT_LAND`. `S_EVENT_LAND` resta valido solo se la piazzola di consegna è effettivamente un FARP definito in ME.
- **Recupero in scenario ostile** (incidente, LZ non sicura, terreno da campo di battaglia): stesso modulo `HoverZoneTrigger` di antincendio/SAR — al successo, l'unità del ferito viene despawnata come se fosse stata caricata a bordo.
- Alla consegna non serve respawnare la persona: basta consumare il flag di stato "soggetto a bordo → salvato" al rilevamento dell'atterraggio in zona, a differenza del fast-rope SWAT dove la squadra deve restare fisicamente presente e operativa dopo lo sbarco.
- Riusabile anche in scenario insurgent/militare con lo stesso schema, cambiando solo la skin narrativa dell'unità recuperata.

## Altre idee proposte durante la discussione

- **Ricognizione infrastrutture** (linee elettriche, oleodotti): pattuglia a bassa quota lungo un corridoio, rilevamento anomalie casuali lungo il tracciato. Riusa lo stesso sistema di corridoio poligonale + quota AGL già previsto per il C-130 antincendio.
- **Soccorso alluvione**: consegna casse di rifornimento a zone isolate via elicottero, variante narrativa del trasporto materiale.

## Punti chiariti tramite verifica documentale

Fonti: documentazione nativa Hoggit wiki (`coalition.addStaticObject`, `DCS_event_land`, `radioTransmission`, `activateBeacon`). Tutte le API citate sono native del motore di scripting DCS: nessuna dipendenza da MIST, MOOSE o CTLD nell'implementazione. Dove le fonti di quei framework sono state consultate, è servito solo a confermare come richiamano le funzioni native sottostanti.

- **`S_EVENT_LAND` scatta solo su Airbase, FARP o nave riconosciuti** (campo `place`), NON su terreno o coperture arbitrarie. Impatta MedEvac e qualunque consegna in ospedale: usare rilevamento a zona, non l'evento, salvo piazzole che siano FARP definiti.
- **Beacon scriptabile: esiste** (`trigger.action.radioTransmission`, `activateBeacon`), ma solo alcuni moduli fanno homing (Mi-8, Huey, Gazelle, AH-64D via NDB), serve un file .ogg e può essere ostico. Fallback coordinate testuali per gli altri.
- **Capacità di sollevamento NON esposta per tipo** dall'API — tabella tipo→capacità da mantenere a mano come config.
- **Task nativi embark/disembark truppe = AI-to-AI**, forzano l'atterraggio e non lasciano scegliere la zona. Per il fast-rope pilotato dal giocatore serve spawn scriptato via `coalition.addGroup` in Lua puro.
- **Massa cargo = campi nativi `mass`/`canCargo`** in `coalition.addStaticObject`, ma alcuni tipi di oggetto cargo hanno massa fissa: il tipo scelto per i tier va verificato in ME. Per cambiarla va ricreato l'oggetto (nessun setter a runtime).
- **Pathfinding "On Road" è un problema noto** (bug report su più versioni, 2.8 fino al 2025), non solo un'incognita: le unità possono deviare o bloccarsi. Da testare presto e prevedere un fallback.

## Punti che richiedono test empirico in-game (non risolvibili a tavolino)

- Affidabilità dello spawn di oggetti Cargo sopra acqua aperta (il campo `mass` funziona, ma il comportamento su acqua va provato in ME).
- Comportamento reale del pathfinding "On Road" sui punti/incroci specifici della mappa scelta.
- Affidabilità dello spawn di unità di fanteria sulla mesh di un tetto (per il fast-rope SWAT).
- Quale sistema di trasporto/sbarco truppe espone il modulo Black Hawk previsto in missione (verificare se modulo ufficiale ED o mod terze parti, e cosa supporta effettivamente).
- Convenzione di naming delle nuove zone/punti, da definire in coerenza con lo schema già usato nel progetto principale (prefisso + indice numerico).
- Valori kg reali per ciascun tier di carico, da ancorare alla capacità di sollevamento effettiva dei moduli previsti.

## Domande aperte per il team

- Preferenze su realismo vs arcade per il C-130 antincendio (ground rearm + line drop, opzione già scelta, ma da confermare col gruppo).
- Leaderboard: aggiornamento live durante la sessione (serve hook lato server) o consolidamento a fine missione (basta persistenza nativa)? Decide quale delle tre opzioni implementare.
- Altre categorie di missione civile da aggiungere alla lista?
- Priorità di sviluppo: quale modulo partire per primo?

## Vincoli non negoziabili per l'implementazione

- **Lua puro nativo**: nessuna dipendenza da MIST, MOOSE, CTLD o altri framework. Tutte le API usate devono essere del motore di scripting DCS.
- Le voci nella sezione "Punti che richiedono test empirico in-game" NON sono risolvibili scrivendo codice a tavolino: vanno provate in Mission Editor prima o durante l'implementazione. Non assumere che funzionino come descritto senza verifica.
