#!/bin/bash
# ===========================================================
# start_all.sh – Master via nohup starten, dann Clients
# Wartet vor Client-Start auf Playlists. Robust & ohne Doppelstart.
# ===========================================================

set -E  # KEIN -e, damit kleine SSH-Fehler das Skript nicht killen

CLIENTS=("computer02@192.168.1.2" "computer03@192.168.1.3" "computer04@192.168.1.4")
MASTER_SCRIPT="${HOME}/improved_master.sh"
LOGFILE="${HOME}/start_all.log"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o ForwardX11=no -o ForwardX11Trusted=no)

log(){ echo "[$(date '+%H:%M:%S')] [START] $*" | tee -a "$LOGFILE"; }

echo "===================================================" | tee "$LOGFILE"
echo "Starte alle Rechner ($(date))" | tee -a "$LOGFILE"
echo "===================================================" | tee -a "$LOGFILE"

# 0) Reachability
for host in "${CLIENTS[@]}"; do
  printf "Prüfe Verbindung zu %s ... " "$host" | tee -a "$LOGFILE"
  if ssh "${SSH_OPTS[@]}" "$host" "echo OK" >/dev/null 2>&1; then
    echo "OK" | tee -a "$LOGFILE"
  else
    echo "FEHLGESCHLAGEN" | tee -a "$LOGFILE"
  fi
done

# 1) Master lokal via nohup starten (kein Service mehr)
log "→ Master per nohup starten"
pkill -f improved_master.sh >/dev/null 2>&1 || true
nohup bash "$MASTER_SCRIPT" > "$HOME/master.log" 2>&1 &
sleep 1
if pgrep -fa improved_master.sh >/dev/null; then
  log "✓ Master (nohup) läuft"
else
  log "✗ Master nicht aktiv – siehe ~/master.log"; exit 1
fi

# 2) Auf Playlists auf den Clients warten (gepadet + unpadded)
wait_playlists(){
  local deadline=$(( $(date +%s) + 30 ))   # bis zu 30s (~3 Ticks)
  local ok CID PAD UNPAD
  while :; do
    ok=1
    for host in "${CLIENTS[@]}"; do
      CID="$(echo "$host" | sed -E 's/.*computer([0-9]{2})@.*/\1/')"
      PAD="/tmp/playlist_client${CID}.txt"
      UNPAD="/tmp/playlist_client$((10#$CID)).txt"
      # Datei existiert & mind. 2 Zeilen?
      if ! ssh "${SSH_OPTS[@]}" "$host" \
           "test -s '$PAD' -a \$(wc -l < '$PAD' 2>/dev/null || echo 0) -ge 2 || \
            test -s '$UNPAD' -a \$(wc -l < '$UNPAD' 2>/dev/null || echo 0) -ge 2" >/dev/null 2>&1; then
        ok=0
      fi
    done
    (( ok == 1 )) && return 0
    (( $(date +%s) >= deadline )) && return 1
    sleep 1
  done
}

log "Warte auf Playlists auf allen Clients ..."
if wait_playlists; then
  log "✓ Playlists vorhanden (mind. 2 Zeilen) auf allen Clients"
else
  log "⚠ Playlists noch nicht überall gefunden – Clients starten trotzdem (sie poll’en weiter)"
fi

# 3) Clients starten (Service bevorzugt, Fallback: nohup)

for host in "${CLIENTS[@]}"; do
  CID="$(echo "$host" | sed -E 's/.*computer([0-9]{2})@.*/\1/')"
  log "→ $host • Start (CLIENT_ID=${CID})"

if ssh "$user@$host" "systemctl --user is-active improved_client@${CID}.service >/dev/null 2>&1"; then
  echo "[START]    ✓ Service läuft bereits (improved_client@${CID}.service) – überspringe Start"
else
  ssh "$user@$host" "systemctl --user start improved_client@${CID}.service"
fi

  if ssh "${SSH_OPTS[@]}" "$host" \
       "XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user restart improved_client@${CID}.service" >/dev/null 2>&1; then
    sleep 1
    if ssh "${SSH_OPTS[@]}" "$host" \
         "XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user is-active --quiet improved_client@${CID}.service"; then
      log "   ✓ Service läuft (improved_client@${CID}.service)"
    else
      log "   ⚠ Service nicht aktiv – Fallback auf nohup"
      ssh "${SSH_OPTS[@]}" "$host" \
        "pkill -f improved_client.sh >/dev/null 2>&1 || true; CLIENT_ID=${CID} nohup bash ~/improved_client.sh >> ~/client${CID}.log 2>&1 &" \
        && log "   ✓ Fallback gestartet" || log "   ✗ Fallback fehlgeschlagen"
    fi
  else
    log "   ⚠ systemctl --user nicht erreichbar – Fallback auf nohup"
    ssh "${SSH_OPTS[@]}" "$host" \
      "pkill -f improved_client.sh >/dev/null 2>&1 || true; CLIENT_ID=${CID} nohup bash ~/improved_client.sh >> ~/client${CID}.log 2>&1 &" \
      && log "   ✓ Fallback gestartet" || log "   ✗ Fallback fehlgeschlagen"
  fi
done

# 4) Kurzer Check: mpv pro Client
sleep 4
for host in "${CLIENTS[@]}"; do
  CID="$(echo "$host" | sed -E 's/.*computer([0-9]{2})@.*/\1/')"
  if ssh "${SSH_OPTS[@]}" "$host" \
       "pgrep -fa 'mpv.*mpv_client$((10#$CID))_' >/dev/null"; then
    log "   ✓ Client ${CID}: mpv läuft"
  else
    log "   ✗ Client ${CID}: mpv nicht gefunden (siehe ~/client${CID}.log oder ~/logs/client${CID}.log auf Client)"
  fi
done

log "==================================================="
log "Fertig. Logs: ~/master.log (Master) & ~/clientXX.log (Clients)"
log "==================================================="
