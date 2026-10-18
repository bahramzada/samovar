# Samovar

A small, personal macOS app for playing single-player Windows **Steam** games on Apple Silicon.

Samovar runs the Windows Steam client silently inside a Wine prefix and gives it a clean native
SwiftUI library. Each game launches with its own graphics backend and settings.

> Personal project. No anti-cheat / multiplayer-protected games — single-player only.

> Samovar is an unofficial project and is not affiliated with Valve, Apple, or CodeWeavers. Steam is a trademark of Valve; Apple, Game Porting Toolkit and Rosetta are trademarks of Apple Inc.; CrossOver is a trademark of CodeWeavers. Samovar does not include or redistribute any of their software.

## How it works

```
game.exe (x86_64, DirectX)
  └─ Graphics:  D3DMetal · DXMT · DXVK+MoltenVK   (DirectX → Metal)
  └─ Wine:      Windows API → macOS               (one shared Steam prefix)
  └─ CPU:       Rosetta 2                          (x86_64 → arm64)
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design.

## Requirements

- Apple Silicon Mac, macOS 26+
- Xcode 26+
- Apple's *Evaluation environment for Windows games* DMG (3.0 and/or 4.0 beta), downloaded
  manually from [Apple Developer Downloads](https://developer.apple.com/download/all/?q=game%20porting%20toolkit).
  Samovar extracts D3DMetal from it locally. These DMGs are **not** redistributable and are git-ignored.

## License

MIT. See [LICENSE](LICENSE). Third-party components downloaded at runtime keep their own licenses.
