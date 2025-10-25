#!/bin/bash
# ===========================================================
# improved_master.sh – robuste Mastersteuerung mit deterministischer Verteilung
# - Sofortige Erstanzeige (kein 10s-Leerlauf)
# - Alle 10s Taktung via NEXT_TICK (Chrony empfohlen)
# - Deterministische, duplikatfreie Zuordnung (Seed = NEXT_TICK)
# - rsync optional & entkoppelt (SYNC_EVERY)
# - Atomare Playlist-Deploys (tmp + mv) + Symlink (gepadet/unpadded)
# - NEU: Zufällige Schwarz-Slots pro Client-Slot
# ===========================================================

set -E   # robust (ohne -e/-u/pipefail)

# ----------------- Konfiguration -----------------
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

# Index 1..4 (1 = Master)
CLIENT_USERS=("computer01" "computer02" "computer03" "computer04")
CLIENT_HOSTS=("localhost"  "192.168.1.2" "192.168.1.3" "192.168.1.4")

# --- Schwarz-Slots-Konfiguration (pro Slot Wahrscheinlichkeit) ---
BLACK_SLOTS_MODE="prob"   # aktuell nur "prob" unterstützt
BLACK_SLOT_PROB="0.00"    # 0.0–1.0: Wahrscheinlichkeit je Slot, schwarz zu bleiben

# Bilder-Sync
SYNC_IMAGES=true           # auf true lassen, wenn rsync genutzt werden soll
SYNC_EVERY=30              # alle N Sekunden Bilder syncen (wenn SYNC_IMAGES=true)

# Logging
LOGFILE="${HOME}/master.log"
log(){ echo "[$(date '+%H:%M:%S')] [MASTER] $*" | tee -a "$LOGFILE"; }

# ----------------- Tools/Checks -----------------
need(){ command -v "$1" >/dev/null 2>&1 || log "WARN: $1 fehlt"; }
have(){ command -v "$1" >/dev/null 2>&1; }

need mpv; need socat; need inotifywait; need awk; need scp
# rsync optional; wenn nicht vorhanden: Sync deaktivieren
if ! command -v rsync >/dev/null 2>&1; then
  log "Hinweis: rsync nicht gefunden – SYNC_IMAGES wird deaktiviert."
  SYNC_IMAGES=false
fi

chrony_check(){
  if have chronyc; then
    local off
    off=$(chronyc tracking 2>/dev/null | awk '/System time/ {print $4" "$5" "$6}')
    log "Chrony: ${off:-keine Daten}"
  else
    log "Chrony nicht gefunden (optional)"
  fi
}

# Zufallszahl [0,1) (über $RANDOM)
rand_float(){
  awk -v r="$RANDOM" 'BEGIN { printf("%.6f", r/32768) }'
}

# Liefert eine Maskenzeile "m0 m1 m2 m3" (1=schwarz, 0=bild)
choose_black_mask_for_client(){
  local prob="${BLACK_SLOT_PROB}"
  local mask=() i p
  case "$BLACK_SLOTS_MODE" in
    prob)
      for i in 0 1 2 3; do
        p="$(rand_float)"
        if awk -v a="$p" -v b="$prob" 'BEGIN{exit (a<b)?0:1}'; then
          mask+=("1")
        else
          mask+=("0")
        fi
      done
      ;;
    *) mask=(0 0 0 0) ;;
  esac
  echo "${mask[*]}"
}

# ----------------- Master-Fenster (optional) -----------------
sock_path(){ printf '/tmp/mpv_master_%d.sock' "$1"; }
wait_for_socket(){ local s="$1" t=0; while [[ ! -S "$s" && $t -lt 60 ]]; do sleep 0.1; ((t++)); done; [[ -S "$s" ]]; }

start_one_mpv(){
  local idx="$1" s g; s="$(sock_path "$idx")"; g="${MASTER_GEOMETRIES[$idx]}"
  [[ -S "$s" ]] && rm -f "$s" || true
  nohup mpv --no-terminal --really-quiet --idle=yes --keep-open=yes \
    --no-border --geometry="$g" --fs --force-window=yes \
    --image-display-duration=0 --osc=no --osd-level=0 \
    --input-ipc-server="$s" /tmp/black.ppm >/dev/null 2>&1 &
  wait_for_socket "$s" || log "WARN: Socket Master $idx erschien nicht"
}

ipc_ping(){
  local idx="$1" s; s="$(sock_path "$idx")"
  [[ -S "$s" ]] || return 1
  printf '{ "command": ["get_property", "idle-active"] }\n' \
    | socat - "UNIX-CONNECT:$s" >/dev/null 2>&1
}

restart_if_dead(){
  local idx="$1" s g; s="$(sock_path "$idx")"; g="${MASTER_GEOMETRIES[$idx]}"
  if ! ipc_ping "$idx"; then
    log "WARN: IPC tot auf Master Monitor $idx → starte mpv neu"
    pkill -f "mpv.*$(basename "$s")" >/dev/null 2>&1 || true
    sleep 0.2
    [[ -S "$s" ]] && rm -f "$s" || true
    nohup mpv --no-terminal --really-quiet --idle=yes --keep-open=yes \
      --no-border --geometry="$g" --fs --force-window=yes \
      --image-display-duration=0 --osc=no --osd-level=0 \
      --input-ipc-server="$s" /tmp/black.ppm >/dev/null 2>&1 &
    wait_for_socket "$s" || log "WARN: Socket $s erschien nicht nach Neustart"
  fi
}

ipc_loadfile(){
  local idx="$1" img="$2" s; s="$(sock_path "$idx")"
  wait_for_socket "$s" || { log "WARN: Socket fehlt ($s)"; return 0; }
  [[ -f "$img" ]] || img="/tmp/black.ppm"
  local ok=0 a
  for a in 1 2 3 4 5; do
    printf '{ "command": ["loadfile", "%s", "replace"] }\n' "$img" \
    | socat - "UNIX-CONNECT:$s" >/dev/null 2>&1 && { ok=1; break; }
    sleep 0.15
  done
  (( ok == 1 )) || { log "WARN: socat/loadfile fehlgeschlagen nach 5 Versuchen ($img, sock=$(basename "$s"))"; restart_if_dead "$idx"; }
  return 0
}

start_mpv(){
  # parallel ist hier nicht entscheidend; bei Bedarf wie Client umbauen
  for i in $(seq 0 $((MONITORS_PER_CLIENT-1))); do start_one_mpv "$i"; sleep 0.15; done
  sleep 0.8
}

show_on_master(){
  for i in $(seq 0 $((MONITORS_PER_CLIENT-1))); do
    local j=$(( (MASTER_ID-1)*MONITORS_PER_CLIENT + i ))
    local f=""; [[ $j -lt ${#IMAGES[@]} ]] && f="${IMAGES[$j]}"
    local img; [[ -z "$f" ]] && img="/tmp/black.ppm" || img="$IMAGE_DIR/$f"
    ipc_loadfile "$i" "$img"
    restart_if_dead "$i"
    log "Master Monitor $i → $(basename "$img")"
  done
}

# ----------------- Bildauswahl & Sync -----------------
get_images(){
  # Globale Ausgabe: IMAGES=() mit bis zu 16 Dateinamen
  local ALL=() SHUF=()
  mapfile -t ALL < <(find "$IMAGE_DIR" -maxdepth 1 -type f -iregex '.*\.\(jpe?g\|png\|bmp\|gif\)$' \
                    | xargs -I{} basename "{}" | sort)
  local total=${#ALL[@]}
  log "Gefundene Bilder gesamt: $total"
  if (( total == 0 )); then
    IMAGES=()        # global leeren
    return 0
  fi

  # deterministisch mischen (Seed = NEXT_TICK)
  local seed="$NEXT_TICK"
  mapfile -t SHUF < <(printf '%s\n' "${ALL[@]}" \
                      | awk -v s="$seed" 'BEGIN{srand(s)} {print rand() "\t" $0}' \
                      | sort -n | cut -f2-)

  local need=$(( MONITORS_PER_CLIENT * ${#CLIENT_HOSTS[@]} ))  # i.d.R. 16
  local n=$(( need<${#SHUF[@]} ? need : ${#SHUF[@]} ))

  # WICHTIG: global setzen (kein 'local'!
  IMAGES=( "${SHUF[@]:0:n}" )

  # kurzer Debug: wie viele gehen ins Schreiben?
  log "Tick-Auswahl: ${#IMAGES[@]} Dateien (Need=$need, Seed=$seed)"
  return 0
}


RSYNC_OPTS="${RSYNC_OPTS:--az --delete --inplace}"

sync_images_to_clients(){
  [[ "$SYNC_IMAGES" != true ]] && return 0
  command -v rsync >/dev/null 2>&1 || { log "WARN: rsync fehlt – überspringe Bildersync"; return 0; }

  for idx in "${!CLIENT_HOSTS[@]}"; do
    CID=$((idx+1))
    [[ "$CID" -eq "$MASTER_ID" ]] && continue
    local user="${CLIENT_USERS[$idx]}" host="${CLIENT_HOSTS[$idx]}"
    local remote="/home/${user}/bilder"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "${user}@${host}" "mkdir -p '$remote'" >/dev/null 2>&1 || log "WARN: mkdir auf ${user}@${host} scheiterte"
    if rsync $RSYNC_OPTS "$IMAGE_DIR/" "${user}@${host}:$remote/" >/dev/null 2>&1; then
      log "Bilder an ${user}@${host} synchronisiert"
    else
      log "WARN: rsync zu ${user}@${host} fehlgeschlagen"
    fi
  done
  return 0
}

# ----------------- Playlists bauen & veröffentlichen -----------------
publish_playlists(){
  # Erwartet: IMAGES[], CLIENT_USERS[], CLIENT_HOSTS[], MONITORS_PER_CLIENT, MASTER_ID
  local idx CID CID_PAD user host build_tmp
  local i j mask_val

  for idx in "${!CLIENT_HOSTS[@]}"; do
    CID=$((idx+1))
    CID_PAD="$(printf '%02d' "$CID")"
    user="${CLIENT_USERS[$idx]}"
    host="${CLIENT_HOSTS[$idx]}"

    # Build-Datei lokal erzeugen
    build_tmp="$(mktemp "/tmp/.playlist_build_${CID_PAD}.XXXXXX" 2>/dev/null || echo "/tmp/.playlist_build_${CID_PAD}.$$")" || continue
    : >"$build_tmp" || { log "WARN: konnte $build_tmp nicht schreiben"; continue; }

    # Kopf (Timestamp)
    printf '%s\n' "$(date +%s)" >"$build_tmp"

    # Schwarz-Maske für diesen Client wählen (m0..m3; 1=schwarz, 0=bild)
    read -r m0 m1 m2 m3 < <( choose_black_mask_for_client )

    # Slots 0..3 schreiben (leer = schwarz; sonst Bild aus IMAGES)
    for i in 0 1 2 3; do
      j=$(( (CID-1)*MONITORS_PER_CLIENT + i ))
      mask_val=$(eval "echo \$m$i")
      if [[ "$mask_val" -eq 1 ]]; then
        printf '\n' >>"$build_tmp"    # absichtlich schwarz
      else
        if [[ $j -lt ${#IMAGES[@]} && -n "${IMAGES[$j]}" ]]; then
          printf '%s\n' "${IMAGES[$j]}" >>"$build_tmp"
        else
          printf '\n' >>"$build_tmp"
        fi
      fi
    done

    # Master lokal deployen (atomar) + Symlink
    if [[ "$CID" -eq "$MASTER_ID" ]]; then
      final_pad="/tmp/playlist_client${CID_PAD}.txt"
      final_unpad="/tmp/playlist_client${CID}.txt"
      mv -f "$build_tmp" "$final_pad" 2>/dev/null || cp -f "$build_tmp" "$final_pad"
      ln -sf "$final_pad" "$final_unpad"
      rm -f "$build_tmp" >/dev/null 2>&1 || true
      log "Playlist (Master) → $final_pad (Symlink: $final_unpad)"
      continue
    fi

    # Remote: tmp hochladen → atomar mv → Symlink
    remote_tmp="/tmp/.playlist_client${CID_PAD}.tmp"
    remote_final_pad="/tmp/playlist_client${CID_PAD}.txt"
    remote_final_unpad="/tmp/playlist_client${CID}.txt"

    if scp -q "$build_tmp" "${user}@${host}:${remote_tmp}" >/dev/null 2>&1; then
      if ssh -o BatchMode=yes -o ConnectTimeout=5 "${user}@${host}" \
           "mv -f '$remote_tmp' '$remote_final_pad' 2>/dev/null || cp -f '$remote_tmp' '$remote_final_pad'; ln -sf '$remote_final_pad' '$remote_final_unpad'"; then
        log "Playlist an ${user}@${host} → $remote_final_pad (Symlink: $remote_final_unpad)"
      else
        log "WARN: mv/ln auf ${user}@${host} fehlgeschlagen"
      fi
    else
      log "WARN: SCP zu ${user}@${host} fehlgeschlagen"
    fi

    rm -f "$build_tmp" >/dev/null 2>&1 || true
  done

  return 0
}

# ----------------- Hauptprogramm -----------------
log "=== START improved_master.sh ==="
mkdir -p "$IMAGE_DIR" >/dev/null 2>&1 || true
chrony_check

# schwarze 1×1 PPM erzeugen, falls nicht vorhanden
[[ -f /tmp/black.ppm ]] || printf "P3\n1 1\n255\n0 0 0\n" > /tmp/black.ppm

# MPV am Master starten (optional)
start_mpv

# Sofortiger erster Durchlauf
NOW=$(date +%s)
NEXT_TICK=$(( (NOW/INTERVAL+1)*INTERVAL ))
get_images
publish_playlists || true
show_on_master

# Endlosschleife im 10s-Takt (auf NEXT_TICK ausgerichtet)
while true; do
  NOW=$(date +%s)
  NEXT_TICK=$(( (NOW/INTERVAL+1)*INTERVAL ))
  SLEEP=$(( NEXT_TICK - NOW ))
  (( SLEEP > 0 )) && sleep "$SLEEP"

  # Bilder ggf. syncen
  if [[ "$SYNC_IMAGES" == true ]]; then
    # nur alle SYNC_EVERY Sekunden
    if (( NOW % SYNC_EVERY == 0 )); then
      sync_images_to_clients
    fi
  fi

  get_images
  publish_playlists || true
  show_on_master
done
