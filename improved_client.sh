#!/bin/bash
# ===========================================================
# improved_client.sh – stabile Client-Schleife mit mpv-Watchdog
# ===========================================================

set -E  # bewusst ohne -e/-u/pipefail

# --------- Konfiguration ---------
CLIENT_ID=${CLIENT_ID:-2}
IMAGE_DIR="${HOME}/bilder"
PLAYLIST_FILE="/tmp/playlist_client$(printf '%02d' "$CLIENT_ID").txt"
MONITORS_PER_CLIENT=4

# --- Singleton-Sperre pro Client-ID ---
lock="/tmp/improved_client_${CLIENT_ID}.lock"
exec 9>"$lock"
if ! flock -n 9; then
  log "Läuft bereits (Lock: $lock) – beende mich."
  exit 0
fi

LOGDIR="$HOME/logs"; mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/client$(printf '%02d' "$CLIENT_ID").log"
log(){ echo "[$(date '+%H:%M:%S')] [Client$(printf '%02d' "$CLIENT_ID")] $*" | tee -a "$LOGFILE"; }

export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"

CLIENT_GEOMETRIES=(
  "1920x1080+0+0"
  "1920x1080+1920+0"
  "1920x1080+3840+0"
  "1920x1080+5760+0"
)

need(){ command -v "$1" >/dev/null 2>&1 || log "WARN: $1 fehlt"; }
need mpv; need socat; need inotifywait

BLACK_IMG="/tmp/black.ppm"; [[ -f "$BLACK_IMG" ]] || printf "P3\n1 1\n255\n0 0 0\n" > "$BLACK_IMG"
sock_path(){ printf '/tmp/mpv_client%d_%d.sock' "$CLIENT_ID" "$1"; }

wait_for_socket(){
  local s="$1" t=0
  while [[ ! -S "$s" && $t -lt 60 ]]; do sleep 0.1; ((t++)); done
  [[ -S "$s" ]]
}

start_one_mpv(){
  local idx="$1" s g; s="$(sock_path "$idx")"; g="${CLIENT_GEOMETRIES[$idx]}"
  [[ -S "$s" ]] && rm -f "$s" || true
  nohup mpv --no-terminal --really-quiet --idle=yes --keep-open=yes \
    --no-border --fs --screen="$idx" --force-window=yes \
    --image-display-duration=0 --osc=no --osd-level=0 \
    --input-ipc-server="$s" "$BLACK_IMG" >/dev/null 2>&1 &
  log "mpv Monitor $idx gestartet (Geom=$g, Sock=$(basename "$s"))"
  wait_for_socket "$s" || log "WARN: Socket für Monitor $idx erschien nicht"
}

start_mpv(){
  log "Starte mpv-Instanzen für $MONITORS_PER_CLIENT Monitore."
  for i in $(seq 0 $((MONITORS_PER_CLIENT-1))); do
    start_one_mpv "$i"
    sleep 0.15
  done
  sleep 0.8
}

# --- Watchdog & IPC ---
ipc_ping(){
  # prüft, ob Socket ansprechbar ist
  local idx="$1" s; s="$(sock_path "$idx")"
  [[ -S "$s" ]] || return 1
  printf '{ "command": ["get_property", "idle-active"] }\n' \
    | socat - "UNIX-CONNECT:$s" >/dev/null 2>&1
}

restart_if_dead(){
  local idx="$1"
  if ! ipc_ping "$idx"; then
    log "WARN: IPC tot auf Monitor $idx → starte mpv neu"
    pkill -u "$(id -u)" -f "mpv.*$(basename "$(sock_path "$idx")")" >/dev/null 2>&1 || true
    sleep 0.2
    start_one_mpv "$idx"
  fi
}

ipc_loadfile(){
  local idx="$1" img="$2" s; s="$(sock_path "$idx")"
  wait_for_socket "$s" || { log "WARN: Socket fehlt ($s)"; return 0; }
  [[ -f "$img" ]] || img="$BLACK_IMG"

  local ok=0 try
  for try in 1 2 3; do
    printf '{ "command": ["loadfile", "%s", "replace"] }\n' "$img" \
      | socat - "UNIX-CONNECT:$s" >/dev/null 2>&1 && { ok=1; break; }
    sleep 0.12
  done
  if (( ok == 0 )); then
    log "WARN: socat/loadfile fehlgeschlagen ($img) – Watchdog greift"
    restart_if_dead "$idx"
    # einmaliger zweiter Versuch direkt nach Neustart
    printf '{ "command": ["loadfile", "%s", "replace"] }\n' "$img" \
      | socat - "UNIX-CONNECT:$s" >/dev/null 2>&1 || log "WARN: erneutes loadfile scheiterte ($img)"
  fi
  return 0
}

LAST_TS=0
show_playlist(){
  if [[ ! -s "$PLAYLIST_FILE" ]]; then
    log "WARN: Playlist leer/fehlt – setze schwarz"
    for i in $(seq 0 $((MONITORS_PER_CLIENT-1))); do ipc_loadfile "$i" "$BLACK_IMG"; done
    return 0
  fi

  local ts; ts=$(head -n1 "$PLAYLIST_FILE" 2>/dev/null || echo 0)
  [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
  (( ts <= LAST_TS )) && { log "Playlist unverändert (ts=$ts)"; return 0; }
  LAST_TS=$ts
  log "Neue Playlist (ts=$ts)"

  local idx=0
  while IFS= read -r line; do
    [[ $idx -ge $MONITORS_PER_CLIENT ]] && break
    if [[ -z "$line" ]]; then
      ipc_loadfile "$idx" "$BLACK_IMG"; log "Monitor $idx → schwarz (leer)"
    else
      local img="$IMAGE_DIR/$line"
      if [[ -f "$img" ]]; then
        ipc_loadfile "$idx" "$img"; log "Monitor $idx → $(basename "$img")"
      else
        ipc_loadfile "$idx" "$BLACK_IMG"; log "Monitor $idx → schwarz (fehlt: $(basename "$img"))"
      fi
    fi
    ((idx++))
  done < <(tail -n +2 "$PLAYLIST_FILE")

  while [[ $idx -lt $MONITORS_PER_CLIENT ]]; do
    ipc_loadfile "$idx" "$BLACK_IMG"; log "Monitor $idx → schwarz (fehlend)"
    ((idx++))
  done

  # Nach dem Setzen einmal kurz die Sockets abklopfen
  for i in $(seq 0 $((MONITORS_PER_CLIENT-1))); do restart_if_dead "$i"; done
  return 0
}

cleanup(){
  log "Beende mpv-Prozesse (SIGTERM/SIGINT)"
  pkill -u "$(id -u)" -f "mpv.*mpv_client${CLIENT_ID}_" >/dev/null 2>&1 || true
}
trap cleanup SIGTERM SIGINT

# --------- Hauptprogramm ---------
log "=== START improved_client.sh (CLIENT_ID=$(printf '%02d' "$CLIENT_ID")) ==="
log "IMAGE_DIR=$IMAGE_DIR"
log "PLAYLIST_FILE=$PLAYLIST_FILE"
mkdir -p "$IMAGE_DIR"
start_mpv
show_playlist

# Robust: reagiert auf move/create/attrib/close_write + 5s Timeout-Polling
while true; do
  inotifywait -t 5 -q -e close_write,move,create,attrib "$(dirname "$PLAYLIST_FILE")" || true

  # Mini-Debounce: scp/rename fertig werden lassen
  if [[ -e "$PLAYLIST_FILE" ]]; then
    sleep 0.05
  fi

  # Nur anzeigen, wenn die Datei Inhalt hat – show_playlist prüft dann ts/Änderung
  [[ -s "$PLAYLIST_FILE" ]] && show_playlist
done
