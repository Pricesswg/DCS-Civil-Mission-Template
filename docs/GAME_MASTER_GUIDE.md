# Game Master guide (emergency command center)

You are the emergency command center: you decide what happens on the map,
where, and how bad it is. The players fly the response; you direct the
session. This guide covers everything you can do and how to do it well.

## 1. Your slot

Take a **Game Master / Tactical Commander** slot: full F10 map view of the
whole session, SRS works, and if you own Combined Arms you can also drive
AI units natively. None of that is required though: every command below
works from ANY slot, including a parked aircraft.

## 2. How commands work

Place an **F10 map marker** where you want the effect, type the command as
the marker text, close it. The script executes it and deletes the marker.
Commands start with `civil` (case does not matter). If nothing happens,
check the text and try `civil help` for the in-game reminder.

## 3. Taking and releasing control

```
civil director off     you direct: automatic event generation pauses
civil director on      hand back to automatic generation
```

Safety net: if you disconnect or just stop issuing commands for 30 minutes
(configurable), the mission notices the silence and resumes automatic mode
on its own. Nobody gets stuck in a frozen session because you had to leave.

## 4. Creating events

The marker position is the event position. The optional number is the
severity (1-10); leave it out for a random roll.

```
civil fire 8           wildfire under the marker (kind is rolled: forest,
                       landfill or industrial)
civil sarm 5           mountain SAR subject at the marker
civil sars 6           sea SAR subject (marker must be on open water)
civil medevac 9        civilian casualty, criticality scales with severity
civil casevac          battlefield casualty, random severity
civil swat 7           SWAT objective (announces the operators required)
civil chase 9          chase from the crossroad nearest to the marker
civil cargo heavy 9    loading point: tier light/medium/heavy/heavy_lift,
                       then priority
civil recon 6          corridor anomaly at the marker
civil vip 7            passenger shuttle, pickup at the pad nearest to
                       the marker
civil transfer 8       medical transfer (air ambulance): patient from the
                       pad nearest to the marker to a distant pad, with a
                       criticality clock
civil inspect 7        coast guard inspection on the merchant nearest to
                       the marker (needs merchant traffic at sea)
civil ship             extra merchant ship on the sea lanes
civil flight           extra ambient civil flight between the airports
```

Note on the aviation tasks: recon, VIP and transfer started by the
DIRECTOR go on the task board as offers the pilots accept via F10. Your
marker commands bypass the board and start the event immediately: use
them when you want something to happen NOW.

What severity means for the players: 3 is a warm-up, 5 is standard, 7
needs a competent crew, 9-10 is an all-hands emergency with a short clock.
Announcements always include it, so use it honestly: players learn to
trust the number.

## 5. Extra assets and movement

```
civil spawn <fragment> [count]   clone any late-activated template whose
                                 name contains the fragment, at the marker
                                 (e.g. civil spawn accident, civil spawn
                                 survivor 3)
civil move <fragment> [speed] [road]   send the ME ground/ship group whose
                                 name contains the fragment to the marker
                                 (single-word fragment; add "road" for road
                                 pathfinding; no Combined Arms needed)
civil cancel                     call off the event nearest to the marker,
                                 no points awarded
```

Air groups cannot be moved this way on purpose; use Combined Arms or the
ME for those.

## 6. Directing well

- **Pace, do not flood.** Two or three concurrent events keep a four-ship
  busy. The automatic caps (max fires, max rescues) do not apply to your
  commanded events, so the restraint is yours.
- **Read the room.** Slow night? One severity 8 fire near the water points
  makes an evening. Full server? Spread events across regions so flights
  do not stack on the same objective.
- **Play the intel game.** Rescue events you create still start with the
  approximate circle: if nobody brought a spotter airplane, either accept
  slower searches or spawn events closer to the players.
- **Use the story.** A fire at severity 9, then a `civil medevac 8` next
  to it two minutes later reads as "a firefighter went down". Chains like
  that are what a human director adds over the random generator.
- **Cancel is not failure.** If an event is stale or the session moves on,
  `civil cancel` clears it quietly. Better than letting windows expire on
  people who never saw the callout.
- **Night sessions.** Players have the illumination assist on a 10 minute
  cooldown per player. If they burn it early, that was their call: resist
  the urge to spawn flares for them.

## 7. Permissions and configuration

By default anyone can issue marker commands. To restrict it, set
`command.restrict.enabled = true` and list the allowed player names in
`command.restrict.playerNames` (top of `01_CivilCore.lua`). Note that
marks placed from GM slots may reach the script without a readable player
name: `allowUnidentified` decides how those are treated.

All the knobs live in `CIV.Config`: severity ranges, caps, windows,
cooldowns, the auto-resume timeout, and the command prefix itself.

## 8. Troubleshooting

- Marker did nothing: wrong prefix or typo. `civil help` lists commands.
  The command reply appears as a coalition message, watch the top right.
- `sars` refused: the marker was not on open water.
- `chase` refused: no free crossroad in the police pool near the marker.
- `spawn` found nothing: the fragment must match a late-activated template
  name placed in the ME.
- Every executed command is logged in `dcs.log` with the prefix `[CIVIL]`,
  and every scored task as `SCORE|player|type|points|...`: useful for the
  post-session recap.
