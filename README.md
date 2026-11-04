# Monitr

A small, native macOS utility that shows what your Mac is doing: every running process, which
app it belongs to, and how much CPU, memory, power and network it uses, with live stats in the
menu bar.

Built for Apple Silicon Macs on macOS 15 or later. Swift and SwiftUI, no dependencies.

## What it does

- **Processes:** every running process with CPU, memory, power draw, network rate and status.
  Sort any column, search by process, app or pid, and filter to non-critical, idle or system
  processes.
- **The app behind each process:** helpers, renderers and command-line tools are grouped under
  the app that launched them (the "responsible" app macOS tracks). Pick an app in the sidebar to
  see only its processes.
- **Overview:** CPU, memory, network, CPU temperature and whole-Mac power, each with a short
  history, plus the busiest apps. Click any of the five for its detail page:
  - **Memory:** app, wired, compressed and cached memory, swap used and swap activity, pressure.
  - **CPU:** apps versus macOS share, load per core (performance and efficiency), load average,
    uptime.
  - **Network:** data used today, in the last 7 and 30 days, per day for two weeks and per app,
    plus each connection's totals since the Mac started.
  - **Temperature:** heat level and every sensor, grouped (CPU cores, chip, storage, battery).
  - **Power and battery:** charging status, time to full or empty, adapter, what the Mac is
    drawing, battery health (maximum capacity, cycles), voltage and current.
- **Running but not used:** apps you have not switched to in 15 minutes and background
  processes idle for 2 minutes, sorted by memory, each with a Quit button.
- **One-click stop:** Stop or Quit next to every process you own. Apps get a normal quit so they
  can save; other processes get SIGTERM. Option-click forces it. macOS processes and other
  users' processes have no stop button.
- **Menu bar:** choose any of CPU, memory, temperature, network, power and battery. Click for a
  panel with the key numbers and busiest apps.
- **Prevent sleep:** keep the Mac awake until turned off or for 30 minutes to 4 hours,
  optionally with the display on, from the menu bar panel or its right-click menu. A cup shows in
  the menu bar while it is on. Closing a MacBook's lid still sleeps it unless an external display
  is connected.
- **Quick quit:** a saved list of apps to quit together in one click (from the sidebar, the
  menu bar panel or its menu). Apps get a normal quit, so they can ask to save.
- **Disk clean:** sizes and clears regenerable data (app caches, logs, Xcode build data,
  simulator caches, and optionally Gradle and npm caches) plus folders you add. Items move to
  the Trash, so nothing is lost until you empty it. Personal folders and macOS folders can't be
  added.
- **Open at login:** a switch in Settings.

## How it stays light

- With the window and panel closed, Monitr reads only whole-Mac counters, one pass every 2
  seconds on a low-priority queue with timer leeway so macOS can batch the wakeups. About 0.7%
  CPU and 45 MB on an M4 MacBook Air, data-usage tracking included.
- Per-process figures are measured only while the window or the menu bar panel is visible.
  The window refreshes every 2 seconds while it is the active window and every 6 seconds when
  it sits behind other apps (about 4% CPU); covered or minimised, it pauses.
- Charts and bars are Core Animation layers, so their motion runs in the system compositor
  rather than costing Monitr work on every frame.
- CPU, memory, energy, temperature and battery come from system calls in-process (`sysctl`,
  `proc_pid_rusage`, Mach host statistics, IOKit). Per-app network uses one-shot `nettop`
  snapshots (about 10 ms of CPU each): every few seconds while the window is open, once a
  minute otherwise. macOS gives full per-app network counters only to Apple's own entitled
  tools; an app reading them directly misses most traffic.
- The menu bar label is drawn once per change into a small bitmap.

## Limits

- **Processes owned by root or other users** (for example `WindowServer`, `kernel_task`): macOS
  gives their CPU and memory only to administrators. Turn on Settings > "Show usage for system
  processes" to add a small read-only helper that runs as root (approved once in System
  Settings > Login Items). Without it they show a dash; whole-Mac totals include them either way.
  The helper only reads usage counters, answers only Monitr signed by the same developer team,
  and exits when idle.
- **Temperature** is the hottest CPU die sensor, read through a private IOKit HID interface.
  macOS has no per-process temperature; per-process power is the closest measure of which
  process is heating the Mac.
- **Data usage** is counted from when Monitr first ran, and only while it is running. The
  whole-Mac total is exact; per-app totals can miss traffic from an app that quits between
  minute-long checks. Stored in `~/Library/Application Support/Monitr/usage.json` for 90 days.
- Because of those private interfaces and the need to see other apps' processes, Monitr cannot
  ship on the Mac App Store. It is built and run locally.

## Tests

```bash
swift test
```

Covers the pure logic in `Sources/MonitrCore`: Disk clean's safety rules (which folders may
never be emptied), process naming, `nettop` parsing, number formatting and chart history.

## Build and run

```bash
./scripts/build-app.sh --install
```

This builds a release `Monitr.app` with its helper, signs both with the Developer ID certificate
when it is in the keychain (ad hoc otherwise, without the helper), and copies it to
`/Applications`. Set `MONITR_SIGN_IDENTITY` to use another certificate; the helper's code
signing checks in `Sources/MonitrShared/HelperProtocol.swift` name the team ID. Without
`--install` the app is left in `build/`.

## Licence

MIT
