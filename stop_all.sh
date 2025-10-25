#!/bin/bash
# ===========================================================
# stop_all.sh – stoppt Master & alle Clients sauber
# ===========================================================
set -E

CLIENTS=("computer02@192.168.1.2" "computer03@192.168.1.3" "computer04@192.168.1.4")
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o ForwardX11=no -o ForwardX11Trusted=no)

log(){ echo "[$(date '+%H:%M:%S')] [STOP] $*"; }

log "Stoppe Master ..."
pkill -f improved_master.sh >/dev/null 2>&1 || true
pkill -f "mpv.*mpv_master_" >/dev/null 2>&1 || true
rm -f /tmp/mpv_master_*.sock >/dev/null 2>&1 || true

# Playlists optional aufräumen (auskommentiert lassen, wenn du sie behalten willst)
# rm -f /tmp/playlist_client*.txt >/dev/null 2>&1 || true

for entry in "${CLIENTS[@]}"; do
  user="${entry%@*}"
  host="${entry#*@}"
  CID="$(sed -E 's/.*computer([0-9]{2}).*/\1/' <<<"$user")"

  log "→ $user@$host (CLIENT_ID=$CID) stoppen"

  # 1) Service stoppen (falls aktiv)
  ssh "${SSH_OPTS[@]}" "$entry" \
     "systemctl --user stop improved_client@${CID}.service >/dev/null 2>&1 || true"

  # 2) Lose laufende Skripte beenden (falls je per nohup gestartet)
  ssh "${SSH_OPTS[@]}" "$entry" \
     "pkill -f 'improved_client.sh' >/dev/null 2>&1 || true"

  # 3) mpv + Sockets aufräumen
  ssh "${SSH_OPTS[@]}" "$entry" \
     "pkill -f 'mpv.*mpv_client$((10#${CID}))_' >/dev/null 2>&1 || true; \
      rm -f /tmp/mpv_client$((10#${CID}))_*.sock >/dev/null 2>&1 || true; \
      rm -f /tmp/improved_client_${CID}.lock >/dev/null 2>&1 || true"
done

log "fertig."
