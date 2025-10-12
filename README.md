# exhibiting

Multimedia installation with 16 monitors and 4 PCs. This repository contains hardened shell scripts for distributing still images across a wall of displays using `mpv`, SSH and now user-level `systemd` services.

## Components

- `improved_master.sh` – orchestrates image selection, playlist distribution and local playback on the master machine.
- `improved_client.sh` – watches the playlist on each client, keeps four `mpv` instances alive and reacts to updates.
- `improved_client@.service` – template for a user `systemd` service that keeps `improved_client.sh` running with automatic restarts.
- `start_all.sh` – copies scripts + service units to each client, enables/starts the user service and finally launches the master.
- `stop_all.sh` – stops the user service (if available) and cleans up all helper processes on every host.
- `check_network.sh` – optional helper to verify connectivity.

## Prerequisites

- Linux desktop on each node with a running graphical session (X11).
- `mpv`, `socat`, `inotify-tools`, `ssh`, `scp`, `rsync` available on every client.
- User lingering enabled so that `systemd --user` is active after logout: `sudo loginctl enable-linger <username>` (run once per client account).
- SSH key-based login from the master to every client.

## Deployment Steps

1. Copy the repository files into `$HOME` of the master user.
2. Ensure the same directory (especially `improved_client.sh` and `improved_client@.service`) is accessible on every client – `start_all.sh` will synchronise them automatically.
3. Adjust hostnames, IP addresses, monitor geometries and directories inside the scripts to match your environment.
4. On each client, create the image directory (`~/bilder` by default).
5. Run `./start_all.sh` on the master. The script will:
   - verify SSH connectivity,
   - upload the client script + service unit,
   - `systemctl --user enable --now improved_client@XX.service` on each host (falling back to the legacy `nohup` start if the user service is unavailable),
   - start the master controller locally.
6. Inspect `~/start_all.log`, `~/master.log` and `journalctl --user -u improved_client@XX.service` when troubleshooting.

## Shutdown

Execute `./stop_all.sh` on the master. It connects to every machine, stops the user service (if present) and terminates any remaining `mpv`/helper processes. Services remain enabled for the next boot so the clients will auto-start again once the graphical session appears.

## Notes

- `improved_client.sh` now contains a watchdog that restarts individual `mpv` windows whenever an IPC socket disappears or becomes unresponsive. The script also falls back to polling the playlist if `inotifywait` fails.
- The service template exposes `CLIENT_ID=%i`, so `improved_client@02.service` will run with `CLIENT_ID=02` automatically.
- Chrony tuning, playlist replication and existing image handling from earlier versions remain unchanged.
