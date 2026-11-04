# Monitr

A small, native macOS utility that shows what your Mac is doing: every running process, which
app it belongs to, and how much CPU, memory, power and network it uses, with live stats in the
menu bar.

Built for Apple Silicon Macs on macOS 14 or later. Swift, SwiftUI and AppKit, no dependencies.

## What it does

- **Processes:** every running process with CPU, memory, power draw, network rate and status.
  Sort any column, search by process, app or pid, and filter to non-critical, idle or system
  processes.
- **The app behind each process:** helpers, renderers and command-line tools are grouped under
  the app that launched them (the "responsible" app macOS tracks). Pick an app in the sidebar to
  see only its processes.
- **Overview:** CPU, memory, network, CPU temperature and whole-Mac power, each with a short
  history, plus the busiest apps.
- **Running but not used:** apps you have not switched to in 30 minutes and background
  processes idle for 5 minutes, sorted by memory, each with a Quit button.
- **One-click stop:** Stop or Quit next to every process you own. Apps get a normal quit so they
  can save; other processes get SIGTERM. Option-click forces it. macOS processes and other
  users' processes have no stop button.
- **Menu bar:** choose any of CPU, memory, temperature, network, power and battery. Click for a
  panel with the key numbers and busiest apps.
- **Open at login:** a switch in Settings.

## How it stays light

- With the window and panel closed, Monitr reads only whole-Mac counters, one pass every 2
  seconds on a low-priority queue with timer leeway so macOS can batch the wakeups. About 0.6%
  CPU and 40 MB on an M4 MacBook Air.
- Per-process figures are measured only while the window or the menu bar panel is open, and the
  whole view tree is released when they close.
- Everything comes from system calls in-process: `sysctl`, `proc_pid_rusage`, Mach host
  statistics, IOKit and the kernel's network statistics. No `ps`, `top` or `nettop`
  subprocesses.
- The menu bar label is drawn once per change into a small bitmap.

## Limits

- **Processes owned by root or other users** (for example `WindowServer`, `kernel_task`) are
  listed with their app, but macOS does not give an ordinary app their CPU or memory figures, so
  they show a dash. Whole-Mac CPU and memory still include them.
- **Temperature** is the hottest CPU die sensor, read through a private IOKit HID interface.
  macOS has no per-process temperature; per-process power is the closest measure of which
  process is heating the Mac.
- **Per-process network** uses the private NetworkStatistics framework, the same source as
  `nettop`.
- Because of those private interfaces and the need to see other apps' processes, Monitr cannot
  ship on the Mac App Store. It is built and run locally.

## Build and run

```bash
./scripts/build-app.sh --install
```

This builds a release `Monitr.app`, signs it ad hoc, and copies it to `/Applications`. Without
`--install` the app is left in `build/`.

## Licence

MIT
