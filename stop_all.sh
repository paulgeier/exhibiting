#!/bin/bash
# ===========================================================
# stop_all.sh – Beendet alle Skripte, Services und mpv-Prozesse
# auf Master + Clients
# ===========================================================

set -Eeo pipefail

# Liste der Hosts (inkl. Master)
HOSTS=("computer01@localhost" "computer02@192.168.1.2" "computer03@192.168.1.3" "computer04@192.168.1.4")

echo "==================================================="
echo "Beende alle Skripte und mpv-Prozesse auf allen Rechnern"
echo "Startzeit: $(date)"
echo "==================================================="

for host in "${HOSTS[@]}"; do
  CLIENT_ID=$(echo "$host" | sed -E 's/.*computer([0-9]{2})@.*/\1/')
  echo "→ Verbinde zu $host ..."
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" CLIENT_ID="$CLIENT_ID" 'bash -s' <<'EOS'; then
    echo "⚠️ Verbindung zu $host fehlgeschlagen."
    continue
EOS
    echo "[STOP] Beende Prozesse auf $(hostname)..."
    if command -v systemctl >/dev/null 2>&1; then
      systemctl --user stop "improved_client@${CLIENT_ID}.service" >/dev/null 2>&1 || true
    fi
    pkill -f "mpv" 2>/dev/null || true
    pkill -f "improved_master.sh" 2>/dev/null || true
    pkill -f "improved_client.sh" 2>/dev/null || true
    pkill -f "inotifywait" 2>/dev/null || true
    echo "[STOP] Fertig auf $(hostname)."
EOS
  fi
done

echo
echo "==================================================="
echo "Alle Skripte und mpv-Prozesse wurden beendet."
echo "Fertig um $(date)"
echo "==================================================="
