# Net CPU

A macOS menu bar app that shows Wi-Fi throughput, CPU load and memory use the way the i3status-rs net, cpu and memory blocks do on a Regolith bar: `rx 4.8K tx  20K`, then CPU and memory as a percentage beside their icons. The numbers turn yellow at the warning level and red at the critical one (CPU 60% and 90%, memory 80% and 95%).

Each item opens a menu in the style of the system Battery menu:

- Wi-Fi: an on/off switch, the network name, signal, channel and band, rate and IP address, and Open Wi-Fi Settings. It can stand in for the system Wi-Fi icon.
- CPU: user and system load, load average, cores, thermal state, and the top three processes.
- Memory: used memory with its app, wired and compressed parts, pressure, swap, and the top three processes.

Open Activity Monitor, and each process row, opens Activity Monitor on the CPU or Memory tab, quitting and reopening it when it is already open, since it reads its tab only at launch.

macOS shares the Wi-Fi network name only with apps that have Location access, so Net CPU asks for it on first launch.

## Install

```
make install
```

This builds `Net CPU.app` with the Swift compiler from the Xcode Command Line Tools, signs the whole app, and copies it to `/Applications` (set `PREFIX` to change that). The signature gives the app its bundle id in the menu bar; macOS 27 keeps an app's items visible beside a menu bar manager such as Hidden Bar only when it runs from `/Applications` under its bundle id.

Start it at login from System Settings, General, Login Items. To stop it, quit `NetCPU` in Activity Monitor.
