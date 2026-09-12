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
     -> display process (builds each frame as styled lines of the world)
        -> screen (the only module that speaks ANSI: clips the frame to the
           terminal, repaints in full when the size changes, otherwise diffs
           it against the last one and repaints just the changed runs)
```

## Running

Requires Erlang/OTP 25+. The renderer reads the terminal size on every frame and scales the 40x40 world down to fit, so resizing the window takes effect on the next tick. Below 20 columns or 10 rows it shows "Terminal too small". When the size cannot be read (stdin and stdout both not a terminal) it assumes 85x75.

```bash
make run
```

Press Ctrl+C twice to stop.

## Original

Started as a Python prototype in 2017 (see `main.py`).
