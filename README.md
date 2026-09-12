# cmd_rpg_that_plays_itself

A command-line RPG that plays itself, built in Erlang. Each character and enemy is its own spawned process, communicating via message passing through a central world server.

## How it works

- **5 hero processes** wander a 10x10 grid, seeking out enemies to fight
- **8 enemy processes** (Goblins, Dragons, Demon Lords, etc.) roam the map
- Heroes gain XP from kills, level up, and collect random loot drops
- Dead heroes and enemies respawn after a short delay
- PvP combat happens when heroes collide

## Architecture

```
rpg_app (entry point)
  -> world_server (gen_server: owns map, resolves combat, manages state)
     -> character processes (spawned per hero, AI movement loop)
     -> enemy processes (spawned per mob, random wandering)
     -> display process (differential ANSI renderer: full first frame, then only changed cells)
```

## Running

Requires Erlang/OTP 25+ and a terminal at least 85 columns by 75 rows: the renderer addresses cells absolutely and does not measure the terminal.

```bash
make run
```

Press Ctrl+C twice to stop.

## Original

Started as a Python prototype in 2017 (see `main.py`).
