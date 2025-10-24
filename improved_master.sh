#!/bin/bash
# ===========================================================
# improved_master.sh – stabile Mastersteuerung mit Chrony-Check
# ===========================================================

set -Eeuo pipefail
INTERVAL=10
IMAGE_DIR="${HOME}/bilder"
MONITORS_PER_CLIENT=4
MASTER_ID=1

MASTER_GEOMETRIES=(
  "1920x1080+0+0"
  "1680x1050+1920+0"
  "1920x1080+3600+0"
  "1920x1080+5280+0"
)

CLIENT_USERS=("computer01" "computer02" "computer03" "computer04")
CLIENT_HOSTS=("localhost"  "192.168.1.2" "192.168.1.3" "192.168.1.4")

SYNC_IMAGES=true
RSYNC_OPTS="-az --delete"
export DISPLAY="${DISPLAY:-:0}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1"; exit 1; }; }
need mpv; need socat; need shuf; need scp; need rsync
have(){ command -v "$1" >/dev/null 2>&1; }

log(){ echo "[$(date '+%H:%M:%S')] [MASTER] $*"; }

chrony_check(){
  if have chronyc; then
    local off
    off=$(chronyc tracking 2>/dev/null | awk '/System time/ {print $4" "$5" "$6}')
    log "Chrony-Status: ${off:-keine Daten}"
  else
    log "Chrony nicht installiert."
  fi
}

BLACK_IMG="/tmp/black.ppm"
[[ -f "$BLACK_IMG" ]] || printf "P3\n1 1\n255\n0 0 0\n" >"$BLACK_IMG"

sock_path(){ printf '/tmp/mpv_master_%s.sock' "$1"; }

wait_for_socket(){
  local s="$1" t=0
  while [[ ! -S "$s" && $t -lt 50 ]]; do sleep 0.1; ((t++)); done
  [[ -S "$s" ]]
}

ipc_loadfile(){
  local idx="$1" img="$2" s; s="$(sock_path "$idx")"
  wait_for_socket "$s" || return
  [[ -f "$img" ]] || img="$BLACK_IMG"
  printf '{ "command": ["loadfile", "%s", "replace"] }\n' "$img" \
  | socat - "UNIX-CONNECT:$s" >/dev/null 2>&1 || true
}

start_mpv(){
  for i in $(seq 0 $((MONITORS_PER_CLIENT-1))); do
    local s g; s="$(sock_path "$i")"; g="${MASTER_GEOMETRIES[$i]}"
    [[ -S "$s" ]] && rm -f "$s"
    nohup mpv --no-terminal --really-quiet --idle=yes --keep-open=yes \
      --no-border --geometry="$g" --fs --force-window=yes \
      --image-display-duration=0 --osc=no --osd-level=0 \
      --input-ipc-server="$s" "$BLACK_IMG" >/dev/null 2>&1 &
    log "Monitor $i gestartet (Geometrie $g)"
    sleep 0.2
  done
  sleep 1
}

init_ticks(){
  local now next
  now=$(date +%s)
  next=$(( now - (now % INTERVAL) + INTERVAL ))
  NEXT_TICK=$next
  log "Ausgerichtet auf Takt: $(date -d "@$NEXT_TICK" '+%H:%M:%S')"
}

sleep_until_next_tick(){
  local now sleep_s
  now=$(date +%s)
  sleep_s=$(( NEXT_TICK - now ))
  ((sleep_s > 0)) && sleep "$sleep_s"
  NEXT_TICK=$(( NEXT_TICK + INTERVAL ))
}

get_images(){
  mapfile -t IMAGES < <(
    find "$IMAGE_DIR" -maxdepth 1 -type f \
      \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.bmp' -o -iname '*.gif' \) \
      -printf '%f\n' | shuf
  )
}

declare -a LAST_IMAGES MASTER_PLAYLIST

choose_new_images(){
  MASTER_PLAYLIST=()
  mapfile -t picks < <(printf '%s\n' "${IMAGES[@]}" | shuf | head -n $MONITORS_PER_CLIENT)
  for i in $(seq 0 $((MONITORS_PER_CLIENT-1))); do
    local c="${picks[$i]:-}"
    [[ -n "${LAST_IMAGES[$i]:-}" && "$c" == "${LAST_IMAGES[$i]}" ]] && \
      c=$(printf '%s\n' "${IMAGES[@]}" | grep -v -F "$c" | shuf | head -n 1)
    MASTER_PLAYLIST[$i]="$c"
    LAST_IMAGES[$i]="$c"
  done
}

show_on_master(){
  for i in $(seq 0 $((MONITORS_PER_CLIENT-1))); do
    local f="${MASTER_PLAYLIST[$i]:-}" img
    [[ -z "$f" ]] && img="$BLACK_IMG" || img="$IMAGE_DIR/$f"
    ipc_loadfile "$i" "$img"
    log "Monitor $i → $(basename "$img")"
  done
}

sync_images_to_clients(){
  [[ "$SYNC_IMAGES" != true ]] && return
  for idx in "${!CLIENT_HOSTS[@]}"; do
    CID=$((idx+1))
    [[ "$CID" -eq "$MASTER_ID" ]] && continue
    local host="${CLIENT_HOSTS[$idx]}" user="${CLIENT_USERS[$idx]}"
    local remote="/home/${user}/bilder"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "${user}@${host}" "mkdir -p '$remote'" || true
    rsync $RSYNC_OPTS "$IMAGE_DIR/" "${user}@${host}:$remote/" \
      && log "Bilder an ${user}@${host} synchronisiert" \
      || log "WARN: rsync zu ${user}@${host} fehlgeschlagen"
  done
}

publish_playlists(){
  for idx in "${!CLIENT_HOSTS[@]}"; do
    CID=$((idx+1))
    local host="${CLIENT_HOSTS[$idx]}" user="${CLIENT_USERS[$idx]}"
    local tmp="/tmp/playlist_client${CID}.txt"
    : >"$tmp"; echo "$(date +%s)" >"$tmp"
    for i in $(seq 0 $((MONITORS_PER_CLIENT-1))); do
      local j=$(( (CID-1)*MONITORS_PER_CLIENT + i ))
      if [[ $j -lt ${#IMAGES[@]} ]]; then
        echo "${IMAGES[$j]}" >>"$tmp"
      else
        echo "" >>"$tmp"
      fi
    done
    [[ "$CID" -eq "$MASTER_ID" ]] && continue
    scp -q "$tmp" "${user}@${host}:/tmp/.playlist_client${CID}.tmp" && \
    ssh -o BatchMode=yes "${user}@${host}" "mv /tmp/.playlist_client${CID}.tmp /tmp/playlist_client${CID}.txt" && \
    log "Playlist an ${user}@${host} gesendet" || \
    log "WARN: SCP zu ${user}@${host} fehlgeschlagen"
  done
}

cleanup(){ log "Beende mpv"; pkill -f "mpv.*mpv_master_" || true; }
trap cleanup EXIT

# -------- Start --------
log "Starte Master (INTERVAL=${INTERVAL}s)"
chrony_check
mkdir -p "$IMAGE_DIR"
start_mpv
init_ticks

while true; do
  sleep_until_next_tick
  get_images
  choose_new_images
  sync_images_to_clients
  publish_playlists
  show_on_master
done
