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

ipc_loadfile(){
  local idx="$1" img="$2" s; s="$(sock_path "$idx")"
  wait_for_socket "$s" || return
  [[ -f "$img" ]] || img="$BLACK_IMG"
  printf '{ "command": ["loadfile", "%s", "replace"] }\n' "$img" \
    | socat - "UNIX-CONNECT:$s" >/dev/null 2>&1 || true
}

start_mpv(){
  for i in $(seq 0 $((MONITORS_PER_CLIENT-1))); do
    local s g; s="$(sock_path "$i")"; g="${CLIENT_GEOMETRIES[$i]}"
    [[ -S "$s" ]] && rm -f "$s"
    nohup mpv --no-terminal --really-quiet --idle=yes --keep-open=yes \
      --no-border --geometry="$g" --fs --force-window=yes \
      --image-display-duration=0 --osc=no --osd-level=0 \
      --input-ipc-server="$s" "$BLACK_IMG" >/dev/null 2>&1 &
    sleep 0.15
  done
  sleep 1
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

cleanup(){ pkill -u "$(id -u)" -f "mpv.*mpv_client${CLIENT_ID}_" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# --------- Start ---------
log "Starte Client${CLIENT_ID}"
mkdir -p "$IMAGE_DIR"
start_mpv
show_playlist

last_update=0
while true; do
  if inotifywait -e close_write --quiet "$(dirname "$PLAYLIST_FILE")" >/dev/null 2>&1; then
    if [[ -s "$PLAYLIST_FILE" ]]; then
      now=$(date +%s)
      (( now - last_update < 1 )) && continue
      last_update=$now
      log "Playlist aktualisiert"
      show_playlist
    fi
  else
    # Falls inotifywait fehlschlägt, kurz warten und neu versuchen
    sleep 1
  fi
done
