#!/bin/bash
# ===========================================================
# check_network_debug.sh – robuster Netzwerkcheck mit Fehleranalyse
# ===========================================================
# Schreibt detailliertes Log mit Timestamps in ~/netz_check_debug.log
# Bricht nie die Gesamtschleife ab; liefert immer eine Zusammenfassung
# ===========================================================

# WICHTIG: Nicht bei Fehlern abbrechen, Schleife soll immer weiterlaufen
set -Eo pipefail

CLIENTS=("computer02@192.168.1.2" "computer03@192.168.1.3" "computer04@192.168.1.4")
IMAGE_DIR="bilder"
LOGFILE="${HOME}/netz_check_debug.log"

timestamp(){ date '+%F %T'; }

say(){ echo "[$(timestamp)] $*"; }
log(){ say "$*" | tee -a "$LOGFILE"; }

echo "===================================================" | tee "$LOGFILE"
log "Netzwerk-Diagnose gestartet"
echo "===================================================" | tee -a "$LOGFILE"

ok_count=0
fail_count=0

for host in "${CLIENTS[@]}"; do
  user="${host%@*}"
  ip="${host#*@}"

  echo | tee -a "$LOGFILE"
  log "🔹 Prüfe $user ($ip)"
  echo "-------------------------------------------" | tee -a "$LOGFILE"

  # 1) Ping mit hartem Timeout (2s)
  log "[INFO] → Ping-Test"
  if ping -c 1 -W 2 "$ip" >/dev/null 2>>"$LOGFILE"; then
    log "✅ Ping OK ($ip erreichbar)"
  else
    log "❌ Ping FEHLGESCHLAGEN – $ip nicht erreichbar!"
    ((fail_count++))
    continue
  fi

  # 2) SSH reachable (BatchMode, kein Prompt). Timeout hart (6s).
  log "[INFO] → SSH-Verbindung testen"
  if timeout 6 ssh -vvv -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "$user@$ip" "echo Verbindung OK" >>"$LOGFILE" 2>&1; then
    log "✅ SSH OK (passwortloser Zugriff funktioniert)"
  else
    log "❌ SSH FEHLGESCHLAGEN – Details siehe $LOGFILE"
    ((fail_count++))
    continue
  fi

  # 3) Ordner /home/<user>/bilder vorhanden?
  remote_dir="/home/${user}/${IMAGE_DIR}"
  log "[INFO] → Prüfe Bilder-Ordner: $remote_dir"
  if timeout 5 ssh -o BatchMode=yes "$user@$ip" "[ -d '$remote_dir' ]" >>"$LOGFILE" 2>&1; then
    log "✅ Ordner vorhanden"
  else
    log "❌ Ordner existiert NICHT"
    ((fail_count++))
    continue
  fi

  # 4) Schreibtest
  log "[INFO] → Teste Schreibrechte"
  if timeout 5 ssh -o BatchMode=yes "$user@$ip" "touch '$remote_dir/.testfile' && rm -f '$remote_dir/.testfile'" >>"$LOGFILE" 2>&1; then
    log "✅ Schreibrechte OK"
  else
    log "⚠️ Keine Schreibrechte in $remote_dir (siehe $LOGFILE)"
    ((fail_count++))
    continue
  fi

  # 5) Prüfe benötigte Programme
  log "[INFO] → Prüfe benötigte Programme (mpv, socat, inotifywait)"
  if timeout 5 ssh -o BatchMode=yes "$user@$ip" "command -v mpv >/dev/null && command -v socat >/dev/null && command -v inotifywait >/dev/null" >>"$LOGFILE" 2>&1; then
    log "✅ mpv/socat/inotifywait vorhanden"
  else
    log "⚠️ Eines fehlt (mpv/socat/inotifywait) – Client zeigt ggf. nicht live an"
    # kein Fail, nur Warnung
  fi

  # 6) Optionale Sichtprüfung: Playlist-Datei vorhanden?
  pl="/tmp/playlist_client${user: -1}.txt"
  log "[INFO] → Prüfe Playlist-Datei: $pl"
  if timeout 5 ssh -o BatchMode=yes "$user@$ip" "test -s '$pl'" >>"$LOGFILE" 2>&1; then
    log "✅ Playlist existiert & ist nicht leer"
  else
    log "⚠️ Playlist fehlt oder ist leer – Master hat evtl. noch nicht gesendet"
  fi

  log "✅ Prüfung $user abgeschlossen"
  ((ok_count++))
  echo "-------------------------------------------" | tee -a "$LOGFILE"
done

echo | tee -a "$LOGFILE"
echo "===================================================" | tee -a "$LOGFILE"
log "Prüfung abgeschlossen"
log "Erfolgreiche Clients: $ok_count"
log "Fehlerhafte Clients: $fail_count"
echo "===================================================" | tee -a "$LOGFILE"

if ((fail_count > 0)); then
  echo "❌ Es gab Fehler – Details siehe $LOGFILE."
else
  echo "✅ Alles OK – alle Clients bereit!"
fi
 