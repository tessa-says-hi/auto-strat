# auto-strat

Tower Defense Simulator tools with an in-game strategy recorder and replay core.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/tessa-says-hi/auto-strat/main/Main.Luau", true))()
```

Open the **Main** tab and use **Strategy Recorder**:

1. Enter a strategy name.
2. Start recording before placing towers.
3. Play normally.
4. Stop, then copy or save the generated strategy.

The recorder currently captures:

- loadout, golden perks, map, mode, and difficulty
- exact placement position and rotation
- upgrades, sells, abilities, skips, targeting modes, and tower options
- stable tower IDs and millisecond action timestamps
- raw fallback calls for other Troops, Voting, and LobbyVoting actions

The first replay milestone supports the recorded in-match actions. Automated lobby
loadout changes, matchmaking, map retries, and result handling are the next build
stage.
