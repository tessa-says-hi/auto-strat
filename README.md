# auto-strat

Tower Defense Simulator tools with an in-game strategy recorder and replay core.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/tessa-says-hi/auto-strat/main/Main.Luau", true))()
```

## Runtime endpoints

- `Main.Luau` is the stable Auto Gatlin entrypoint backed by FlowAuth.
- `src/Strategy.Luau` is the complete public strategy replay core.
- `src/Recorder.Luau` is the public recorder and tools entrypoint.

Generated strategies and teleport resumes load the public Strategy source from
the repository's `main` branch. Auto Stacker remains a separate FlowAuth-backed
tool and is loaded on demand by Recorder.

Load the standalone recorder and utility UI:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/tessa-says-hi/auto-strat/main/src/Recorder.Luau", true))()
```

Use the **Strategy Recorder** window to:

1. Enter a strategy name.
2. Start recording before placing towers.
3. Play normally.
4. Stop, then copy or save the generated strategy.

The separate **Recorder Tools** window includes Auto Skip and an authenticated
Auto Stack toggle with a stack amount control, tower upgrade and sell controls,
and the upgrade-range viewer. Auto Chain Commander becomes available when Auto
Gatlin is also loaded.

The recorder currently captures:

- loadout, golden perks, map, mode, and difficulty
- exact placement position and rotation
- upgrades, sells, abilities, skips, targeting modes, and tower options
- stable tower IDs and millisecond action timestamps
- raw fallback calls for other Troops, Voting, and LobbyVoting actions

Replay now starts solo matchmaking from the lobby, queues itself across teleport,
selects the recorded map when needed, and then runs the recorded in-match actions.
Automatic loadout changes and result handling are the next build stage.
