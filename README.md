# Clash Verge Monitor · 码表

A tiny always-on-top desktop widget for macOS that shows **Clash Verge live traffic, CPU, GPU, memory** and **the processes eating your CPU** — two real needle gauges included.

macOS 桌面小浮窗：Clash Verge 实时网速、CPU / GPU 指针表、内存、进程排行。原生 SwiftUI，无第三方依赖。

![screenshot](screenshot.png)

## Features

- **Live traffic** — upload / download read straight from Clash Verge's mihomo API (`/connections`, unix socket), so the numbers match Clash Verge itself
- **Two real needle gauges** — CPU and GPU utilisation
- **Click a gauge** → a separate card slides up above the widget listing the top 6 CPU processes. The widget itself never moves or resizes.
- **Click the traffic area** → opens Clash Verge
- **×** on a process row → quit it (with confirmation) — the honest way to "free" CPU/GPU
- **↻** re-sample instantly, **📌** toggle always-on-top
- **Resizable** — drag the ↖ grip in the top-left corner (0.6×–2.0×), or use the menu bar
- Dark translucent frosted glass, pin position, remembers size & position across launches

## Build

Requires Xcode command line tools (Swift 5.9+). No dependencies, no package manager.

```bash
./build.sh          # compiles straight into /Applications/码表.app and relaunches it
```

The app runs as an `LSUIElement` (menu-bar only, no Dock icon). To start it at login:

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/码表.app", hidden:false}'
```

## How it reads data

| Metric | Source |
|---|---|
| ↑ ↓ traffic | mihomo `GET /connections` over unix socket, diffing `downloadTotal` / `uploadTotal` every second |
| CPU | `host_statistics(HOST_CPU_LOAD_INFO)` delta |
| GPU | IOKit `IOAccelerator` → `PerformanceStatistics["Device Utilization %"]` |
| Memory | `host_statistics64` — active + wired + compressed |
| Processes | `/bin/ps -A -o pcpu=,pid=,comm=`, aggregated by name |

Traffic needs Clash Verge running with its service mode enabled. Default socket path:

`/var/run/clash-verge-service/users/501/verge-mihomo.sock`

If yours differs, edit `Clash.candidates` in [Sources/main.swift](Sources/main.swift).

## Notes

- CPU / GPU usage is not a cache you can flush. The only way to lower it is to quit whatever is using it — that is what the **×** button is for.
- The window is anchored to the bottom-right of the screen; the process list is a **second window** on purpose, so the main panel never resizes (a resizing window visibly "jumps").
- Icon: `assets/logo.jpg` → `tools/mkicon.py` → `build/AppIcon.icns`.

## License

MIT
