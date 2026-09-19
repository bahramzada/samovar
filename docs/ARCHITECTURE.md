# Samovar — Architecture

## Decisions

| Topic | Choice | Why |
|---|---|---|
| Language / UI | Swift 6 + SwiftUI, macOS 26 minimum | Native, light, modern look |
| Layout | Xcode app + local Swift package `SamovarCore` + `samovar` CLI | All logic testable without UI |
| Engine | Prebuilt Wine (Gcenx wine-crossover) first, own build later | Building Wine is a project of its own |
| Prefix | One shared Steam prefix | Steam installed once, all games share it |
| Data | JSON files in Application Support | Simple, inspectable, hand-editable |
| Sandbox | Off, ad-hoc signed | Must spawn Wine binaries; personal use only |

## Layers

```
App (SwiftUI)        Library grid · Game detail · Settings sheet · First-run setup
  │  @Observable view models
SamovarCore
  SteamService       libraryfolders.vdf / appmanifest_*.acf parsing, artwork, steam://install
  GameLauncher       builds per-game environment, spawns process, tracks lifecycle
  ProfileStore       per-game settings + bundled KnownFixes.json
  PrefixManager      prefix creation, registry tweaks, fonts
  EngineManager      Wine engines + graphics backends, versions, manifests
  ProcessRunner      Process wrapper, log streaming, wineserver -k
  │  WineEngine protocol (swap Rosetta build for ARM64EC+FEX later)
Engines on disk      wine-crossover (x86_64) · D3DMetal · DXMT · DXVK+MoltenVK
```

## Launch model

`steam.exe -applaunch <id>` makes the game inherit Steam's environment, which blocks per-game
backends. Instead:

1. Steam runs in the background with `-silent`; its UI is never the primary interface.
2. Samovar launches the game `.exe` directly in the same prefix with its own environment.
   Steamworks DRM talks to the running Steam client through the shared `wineserver`.
3. A `steam_appid.txt` next to the exe stops the game from relaunching itself via Steam.
4. Graphics backends are never copied into the prefix's `system32`; they are selected per launch
   via DLL overrides and search paths, so the shared prefix stays clean.

New installs are triggered with `steam://install/<appid>` sent to the Wine Steam client.

## On-disk layout

```
~/Library/Application Support/Samovar/
├── Engines/wine-crossover-<ver>/        manifest.json + binaries
├── Backends/{d3dmetal,dxmt,dxvk}-<ver>/
├── Prefixes/steam/
├── Profiles/<appid>.json
├── Cache/artwork/<appid>.jpg
└── Logs/<appid>-<date>.log
```

## D3DMetal source

Apple's *Evaluation environment for Windows games* DMG (3.0, 4.0 beta 2) contains:

```
redist/lib/external/D3DMetal.framework
redist/lib/external/libd3dshared.dylib
redist/lib/wine/x86_64-unix/    {d3d10,d3d11,d3d12,dxgi,atidxx64,nvapi64,nvngx-on-metalfx}.so
redist/lib/wine/x86_64-windows/ {d3d10,d3d11,d3d12,dxgi,atidxx64,nvapi64,nvngx-on-metalfx}.dll
```

The user downloads the DMG; Samovar extracts `redist/` into `Backends/d3dmetal-<ver>/`.
It is never committed or redistributed.
