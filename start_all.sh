#!/bin/bash
# ===========================================================
# start_all.sh – robuster Start von Clients + Master
# - synced client script, fixes CRLF, ensures exec + deps,
#   starts, and verifies with live log snippet on failure
# ===========================================================

set -Eeuo pipefail

CLIENTS=("computer02@192.168.1.2" "computer03@192.168.1.3" "computer04@192.168.1.4")
MASTER_SCRIPT="${HOME}/improved_master.sh"
CLIENT_SCRIPT_LOCAL="${HOME}/improved_client.sh"
SERVICE_UNIT_LOCAL="${HOME}/improved_client@.service"
LOGFILE="${HOME}/start_all.log"

log(){ echo "[$(date '+%H:%M:%S')] [START] $*" | tee -a "$LOGFILE"; }

# --- Preflight: Master-Dateien prüfen
[[ -f "$CLIENT_SCRIPT_LOCAL" ]] || { echo "Client-Skript fehlt lokal: $CLIENT_SCRIPT_LOCAL"; exit 1; }
[[ -f "$MASTER_SCRIPT"       ]] || { echo "Master-Skript fehlt: $MASTER_SCRIPT"; exit 1; }
[[ -f "$SERVICE_UNIT_LOCAL"  ]] || { echo "Service-Unit fehlt lokal: $SERVICE_UNIT_LOCAL"; exit 1; }

echo "===================================================" | tee "$LOGFILE"
echo "Starte alle Rechner ($(date))" | tee -a "$LOGFILE"
echo "===================================================" | tee -a "$LOGFILE"

# ---------- 1) SSH-Check ----------
for host in "${CLIENTS[@]}"; do
  printf "Prüfe Verbindung zu %s ... " "$host" | tee -a "$LOGFILE"
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" "echo OK" >/dev/null 2>&1; then
    echo "OK" | tee -a "$LOGFILE"
  else
    echo "FEHLGESCHLAGEN" | tee -a "$LOGFILE"
  fi
done

# ---------- 2) Clients vorbereiten + starten ----------
for host in "${CLIENTS[@]}"; do
  CLIENT_ID=$(echo "$host" | sed -E 's/.*computer([0-9]{2})@.*/\1/')
  log "→ $host • Setup & Start (CLIENT_ID=$CLIENT_ID)"

  # a) Logs & binäre Pfade vorbereiten
  ssh -o BatchMode=yes "$host" "mkdir -p ~/logs ~/bin ~/.config/systemd/user >/dev/null 2>&1 || true"

  # b) Client-Skript übertragen, CRLF entfernen, ausführbar machen
  scp -q "$CLIENT_SCRIPT_LOCAL" "$host:~/improved_client.sh"
  ssh -o BatchMode=yes "$host" "
    sed -i 's/\r$//' ~/improved_client.sh
    chmod +x ~/improved_client.sh
  "

  # c) Minimal-Check auf benötigte Programme
  MISSING=$(ssh -o BatchMode=yes "$host" "for c in mpv socat inotifywait systemctl; do command -v \$c >/dev/null || echo \$c; done")
  if [[ -n "$MISSING" ]]; then
    log "WARN: $host fehlt: $MISSING"
    log "     → Bitte auf $host installieren: sudo apt install -y mpv socat inotify-tools"
  fi

  # d) Service-Unit übertragen
  scp -q "$SERVICE_UNIT_LOCAL" "$host:~/improved_client@.service"
  ssh -o BatchMode=yes "$host" "
    mv -f ~/improved_client@.service ~/.config/systemd/user/
    chmod 644 ~/.config/systemd/user/improved_client@.service
  "

  SERVICE_OK=true
  if ssh -o BatchMode=yes "$host" "systemctl --user daemon-reload"; then
    ssh -o BatchMode=yes "$host" "systemctl --user stop improved_client@${CLIENT_ID}.service >/dev/null 2>&1 || true"
    if ssh -o BatchMode=yes "$host" "systemctl --user enable --now improved_client@${CLIENT_ID}.service"; then
      sleep 1
      if ssh -o BatchMode=yes "$host" "systemctl --user is-active --quiet improved_client@${CLIENT_ID}.service"; then
        log "OK: Service improved_client@${CLIENT_ID}.service aktiv"
      else
        log "FEHLER: Service improved_client@${CLIENT_ID}.service nicht aktiv"
        ssh -o BatchMode=yes "$host" "journalctl --user -u improved_client@${CLIENT_ID}.service -n 40 --no-pager" | sed 's/^/[JOURNAL] /' | tee -a "$LOGFILE"
        SERVICE_OK=false
      fi
    else
      log "WARN: enable/start von improved_client@${CLIENT_ID}.service schlug fehl"
      ssh -o BatchMode=yes "$host" "journalctl --user -u improved_client@${CLIENT_ID}.service -n 40 --no-pager" | sed 's/^/[JOURNAL] /' | tee -a "$LOGFILE"
      SERVICE_OK=false
    fi
  else
    log "WARN: systemctl --user auf $host nicht verfügbar – Fallback auf nohup"
    SERVICE_OK=false
  fi

  if [[ "$SERVICE_OK" == false ]]; then
    ssh -o BatchMode=yes "$host" "pkill -f 'improved_client.sh' >/dev/null 2>&1 || true"
    ssh -o BatchMode=yes "$host" "CLIENT_ID=${CLIENT_ID} nohup ~/improved_client.sh >> ~/logs/client${CLIENT_ID}.log 2>&1 & echo \
$! > ~/logs/client${CLIENT_ID}.pid" \
      || log "WARN: $host Startkommando (Fallback) schlug fehl"
  fi

  # e) Kurz warten & prüfen
  sleep 1
  if ssh -o BatchMode=yes "$host" "systemctl --user is-active --quiet improved_client@${CLIENT_ID}.service"; then
    :
  elif ssh -o BatchMode=yes "$host" "pgrep -f 'improved_client.sh' >/dev/null"; then
    log "OK (Fallback): Client ${CLIENT_ID} läuft ohne Service"
  else
    log "FEHLER: Client ${CLIENT_ID} läuft NICHT – Logauszug:"
    ssh -o BatchMode=yes "$host" "journalctl --user -u improved_client@${CLIENT_ID}.service -n 40 --no-pager" | sed 's/^/[JOURNAL] /' | tee -a "$LOGFILE"
    ssh -o BatchMode=yes "$host" "tail -n 40 ~/logs/client${CLIENT_ID}.log || echo '(kein Log vorhanden)'" | sed 's/^/[LOG] /' | tee -a "$LOGFILE"
  fi

done

# ---------- 3) Master lokal starten ----------
log "Starte Master lokal ..."
pkill -f improved_master.sh >/dev/null 2>&1 || true
nohup bash "$MASTER_SCRIPT" > ~/master.log 2>&1 &
sleep 2
if pgrep -fa improved_master.sh >/dev/null; then
  log "→ Master gestartet"
else
  log "WARN: Master nicht aktiv – siehe ~/master.log"
fi

log "==================================================="
log "Fertig. Logs: ~/master.log und ~/logs/clientX.log (je Client)"
log "==================================================="
