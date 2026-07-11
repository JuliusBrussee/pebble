Pebble for Windows

Requirements:
- Windows 10 19041 or newer, x64
- Vulkan 1.2-capable graphics driver

Run Pebble.exe for client or pebserver.exe --help for dedicated server.
Game data defaults to PebbleData beside current working directory. Override with:

  Pebble.exe --data-dir C:\Games\PebbleData

Pass --validation during development when Vulkan validation layers are installed.
Press F2 to save Pebble-screenshot.png. Press F11 to toggle fullscreen.
Use --resource-pack <zip> to override the bundled Faithful pack.

Current Windows renderer includes chunks, shadows, animated entities, particles,
procedural skies/clouds, UI, and postprocessing. This build remains experimental
until matching Windows runtime evidence is published.

This project is independent from Mojang Studios and Microsoft.
