#!/bin/bash
# ===========================================================
# improved_client.sh – stabiler Client für Multiscreen-Bildanzeige
# ===========================================================

set -Ee  # bewusst ohne -u/pipefail, um harmlose Lücken zu tolerieren

# --------- Konfiguration ---------
CLIENT_ID=${CLIENT_ID:-2}
IMAGE_DIR="${HOME}/bilder"
PLAYLIST_FILE="/tmp/playlist_client${CLIENT_ID}.txt"
MONITORS_PER_CLIENT=4

# Geometrien anpassen (Beispielwerte):
CLIENT_GEOMETRIES=(
  "1920x1080+0+0"
  "1920x1080+1920+0"
  "1920x1080+3840+0"
  "1920x1080+5760+0"
)

# --------- X11-Umgebung absichern ---------
export DISPLAY="${DISPLAY:-:0}"
# Falls $XAUTHORITY nicht gesetzt/ungültig ist: LightDM-Cookie benutzen
if [[ -z "${XAUTHORITY:-}" || ! -f "$XAUTHORITY" ]]; then
  for f in /var/run/lightdm/root/*; do
    [[ -f "$f" ]] && export XAUTHORITY="$f" && break
  done
fi
# Eigenen Benutzer für X11 autorisieren (idempotent)
if command -v xhost >/dev/null 2>&1; then
  xhost +SI:localuser:$(whoami) >/dev/null 2>&1 || true
fi

# --------- Hilfsfunktionen ---------
need(){ command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1" >&2; exit 1; }; }
need mpv; need socat; need inotifywait

log(){ echo "[$(date '+%H:%M:%S')] [Client${CLIENT_ID}] $*"; }

BLACK_IMG="/tmp/black.ppm"
[[ -f "$BLACK_IMG" ]] || printf "P3\n1 1\n255\n0 0 0\n" > "$BLACK_IMG"

# WICHTIG: richtige Expansion des CLIENT_ID im Socket-Namen
sock_path(){ printf "/tmp/mpv_client%d_%s.sock" "$CLIENT_ID" "$1"; }
wait_for_socket(){ local s="$1" t=0; while [[ ! -S "$s" && $t -lt 30 ]]; do sleep 0.1; ((t++)); done; [[ -S "$s" ]]; }

declare -a MPV_PIDS CURRENT_IMAGES

mpv_cmd(){
  mpv --no-terminal --really-quiet --idle=yes --keep-open=yes \
    --no-config --no-border --fs --force-window=yes \
    --geometry="$1" --image-display-duration=0 --osc=no --osd-level=0 \
    --input-ipc-server="$2" "$BLACK_IMG"
}

start_single_mpv(){
  local idx="$1" s g pid
  s="$(sock_path "$idx")"
  g="${CLIENT_GEOMETRIES[$idx]}"
  [[ -S "$s" ]] && rm -f "$s"
  mpv_cmd "$g" "$s" >/dev/null 2>&1 &
  pid=$!
  MPV_PIDS[$idx]=$pid
  log "mpv[$idx] gestartet (PID=$pid, Socket=$s)"
  wait_for_socket "$s" || log "WARN: Socket $s tauchte nicht auf"
}

ipc_loadfile(){
  local idx="$1" img="$2" s; s="$(sock_path "$idx")"
  wait_for_socket "$s" || return
  [[ -f "$img" ]] || img="$BLACK_IMG"
  printf '{ "command": ["loadfile", "%s", "replace"] }\n' "$img" \
    | socat - "UNIX-CONNECT:$s" >/dev/null 2>&1 || true
  CURRENT_IMAGES[$idx]="$img"
}

start_mpv(){
  for i in $(seq 0 $((MONITORS_PER_CLIENT-1))); do
    start_single_mpv "$i"
    sleep 0.1
  done
  sleep 1
}

ping_socket(){
  local s="$(sock_path "$1")"
  [[ -S "$s" ]] || return 1
  printf '{ "command": ["get_property", "idle-active"] }\n' |
    socat - "UNIX-CONNECT:$s" >/dev/null 2>&1
}

ensure_mpv(){
  local idx
  for idx in $(seq 0 $((MONITORS_PER_CLIENT-1))); do
    if [[ ! -S "$(sock_path "$idx")" ]] || ! ping_socket "$idx"; then
      log "WARN: mpv[$idx] reagiert nicht – Neustart"
      if [[ -n "${MPV_PIDS[$idx]:-}" ]]; then
        kill "${MPV_PIDS[$idx]}" >/dev/null 2>&1 || true
        wait "${MPV_PIDS[$idx]}" 2>/dev/null || true
      fi
      start_single_mpv "$idx"
      sleep 0.1
      ipc_loadfile "$idx" "${CURRENT_IMAGES[$idx]:-$BLACK_IMG}"
    fi
  done
}

LAST_TS=0
show_playlist(){
  if [[ ! -s "$PLAYLIST_FILE" ]]; then
    log "WARN: Playlist leer/fehlt – schwarz"
    for i in $(seq 0 $((MONITORS_PER_CLIENT-1))); do ipc_loadfile "$i" "$BLACK_IMG"; done
    return
  fi
  local ts; ts=$(head -n1 "$PLAYLIST_FILE" 2>/dev/null || echo 0)
  [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
  (( ts <= LAST_TS )) && return
  LAST_TS=$ts

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
        ipc_loadfile "$idx" "$BLACK_IMG"; log "Monitor $idx → schwarz (fehlt)"
      fi
    fi
    ((idx++))
  done < <(tail -n +2 "$PLAYLIST_FILE")

  while [[ $idx -lt $MONITORS_PER_CLIENT ]]; do
    ipc_loadfile "$idx" "$BLACK_IMG"; log "Monitor $idx → schwarz (fehlend)"
    ((idx++))
  done
}

cleanup(){
  for pid in "${MPV_PIDS[@]}"; do
    [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
  done
  pkill -u "$(id -u)" -f "mpv.*mpv_client${CLIENT_ID}_" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --------- Hauptlogik ---------
poll_playlist(){
  local mtime
  mtime=$(stat -c %Y "$PLAYLIST_FILE" 2>/dev/null || echo 0)
  if (( mtime > PLAYLIST_MTIME )); then
    PLAYLIST_MTIME=$mtime
    log "Playlist-Änderung erkannt (Polling)"
    show_playlist
  fi
}

main(){
  trap cleanup EXIT

  log "Starte Client${CLIENT_ID}"
  mkdir -p "$IMAGE_DIR"
  start_mpv
  show_playlist

  last_update=0
  PLAYLIST_MTIME=$(stat -c %Y "$PLAYLIST_FILE" 2>/dev/null || echo 0)

  while true; do
    ensure_mpv
    if inotifywait -e close_write --quiet "$(dirname "$PLAYLIST_FILE")" >/dev/null 2>&1; then
      if [[ -s "$PLAYLIST_FILE" ]]; then
        now=$(date +%s)
        (( now - last_update < 1 )) && continue
        last_update=$now
        log "Playlist aktualisiert"
        show_playlist
      fi
    else
      # Falls inotifywait fehlschlägt, kurz warten, Polling-Fallback nutzen
      sleep 1
      poll_playlist
    fi
  done
}

main "$@"
