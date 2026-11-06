# ShardFall

**Shardfall Survivors** is a single-file browser survivor game (`index.html`). Open it in a browser, or serve the folder (`python3 -m http.server`) and visit `/index.html`.

- Four heroes, four stages, a boss per stage, then a choice of portal: Golden Sanctuary (bank the run) or Crimson Rift (Endless Delve).
- Ascendancy at level 5, hybrid class at level 10, elemental damage over time, relics, Blood Shrines, the Malakor nemesis, a Phantom Mirror clone and points of interest on the map.
- Controls: drag anywhere to move on touch, WASD or the arrow keys on a keyboard. Double-tap or Space/Shift to roll, Esc or P to pause.

## Optional files

The game runs without these. When they're missing it draws its own shapes and uses system fonts.

- `sprites/`: `warden.jpg`, `sparkcaller.jpg`, `emberwitch.jpg`, `stormwright.jpg`, `malakor.jpg`, `bosses.jpg`, `enemies.jpg`, `pois.jpg`
- `vendor/fonts.css` (Bungee and Barlow Condensed) and `vendor/three.min.js` (if this is missing, three.js loads from cdnjs instead)

## Renderer

The game draws in 2D. A Three.js renderer is included but turned off (`USE_3D = false`) because it's unfinished: it draws pickups and projectiles but not the hero, enemies or ground.
