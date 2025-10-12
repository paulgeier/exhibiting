#!/bin/bash
# ===========================================================
# stop_all.sh – Beendet alle Skripte und mpv-Prozesse
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
  echo "→ Verbinde zu $host ..."
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" '
    echo "[STOP] Beende Prozesse auf $(hostname)..."
    # Alle mpv-Instanzen beenden
    pkill -f "mpv" 2>/dev/null || true
    # Alle improved_* Skripte beenden
    pkill -f "improved_master.sh" 2>/dev/null || true
    pkill -f "improved_client.sh" 2>/dev/null || true
    # Optional: inotifywait (Client-Dateiüberwachung)
    pkill -f "inotifywait" 2>/dev/null || true
    sleep 0.3
    echo "[STOP] Fertig auf $(hostname)."
  ' || echo "⚠️ Verbindung zu $host fehlgeschlagen."
done

echo
echo "==================================================="
echo "Alle Skripte und mpv-Prozesse wurden beendet."
echo "Fertig um $(date)"
echo "==================================================="