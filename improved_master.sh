#!/bin/bash
# ===========================================================
# improved_master.sh – robuste Mastersteuerung mit deterministischer Verteilung
# - Sofortige Erstanzeige (kein 10s-Leerlauf)
# - Alle 10s Taktung via NEXT_TICK (Chrony empfohlen)
# - Deterministische, duplikatfreie Zuordnung (Seed = NEXT_TICK)
# - rsync optional & entkoppelt (SYNC_EVERY)
# - Atomare Playlist-Deploys (tmp + mv) + Symlink (gepadet/unpadded)
# - NEU: Zufällige Schwarz-Slots pro Client-Slot
# - NEU: Monitoring & Statistik (Client Health, Playlist Verify, Distribution Stats)
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

# --- Schwarz-Slots ---
# BLACK_SLOTS_MODE: off | prob
BLACK_SLOTS_MODE="${BLACK_SLOTS_MODE:-prob}"
# Integer-Prozent 0..100 (ohne Anführungszeichen möglich, keine Kommazahl)
BLACK_SLOT_PCT=${BLACK_SLOT_PCT:-25}

# Globale Bildliste (von get_images gefüllt)
declare -ag IMAGES

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

# Liefert "m0 m1 m2 m3" (1=schwarz, 0=bild) – robust, integer-basiert
choose_black_mask_for_client(){
  local client_id="$1"
  
  if [[ "$BLACK_SLOTS_MODE" != "prob" ]] || (( BLACK_SLOT_PCT <= 0 )); then
    echo "0 0 0 0"; return 0
  fi
  if (( BLACK_SLOT_PCT >= 100 )); then
    echo "1 1 1 1"; return 0
  fi

  local mask=() i threshold
  for i in 0 1 2 3; do
    threshold=$BLACK_SLOT_PCT
    
    # Sonderregel: Master bekommt 10% mehr Schwarz-Chance
    [[ "$client_id" -eq "$MASTER_ID" ]] && threshold=$(( threshold + 10 ))
    
    # Caps bei 100%
    (( threshold > 100 )) && threshold=100
    
    if (( (RANDOM % 100) < threshold )); then
      mask+=(1)
    else
      mask+=(0)
    fi
  done
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
  for i in $(seq 0 $((MONITORS_PER_CLIENT-1))); do start_one_mpv "$i"; sleep 0.15; done
  sleep 0.8
}

show_on_master(){
  local playlist="/tmp/playlist_client01.txt"
  
  # Warte kurz, falls Playlist gerade geschrieben wird
  sleep 0.1
  
  if [[ ! -f "$playlist" ]]; then
    log "WARN: Master-Playlist nicht gefunden: $playlist"
    return 1
  fi
  
  # Lese Playlist (Zeile 1 = Timestamp, Zeilen 2-5 = Slots)
  local lines=()
  mapfile -t lines < "$playlist"
  
  # Verarbeite die 4 Slots (Index 1-4 im Array, da Zeile 0 = Timestamp)
  for i in 0 1 2 3; do
    local line_idx=$((i + 1))
    local filename="${lines[$line_idx]}"
    
    local img
    if [[ -z "$filename" ]]; then
      img="/tmp/black.ppm"
      log "Master Monitor $i → BLACK (leere Zeile in Playlist)"
    elif [[ -f "$IMAGE_DIR/$filename" ]]; then
      img="$IMAGE_DIR/$filename"
      log "Master Monitor $i → $filename"
    else
      img="/tmp/black.ppm"
      log "WARN: Master Monitor $i → BLACK (Datei nicht gefunden: $filename)"
    fi
    
    ipc_loadfile "$i" "$img"
    restart_if_dead "$i"
  done
}

# ----------------- Monitoring & Statistik -----------------

show_distribution_stats(){
  local total_images=0 total_black=0
  
  # Nur Master-Playlist auswerten (Clients sind remote)
  local playlist="/tmp/playlist_client01.txt"
  if [[ -f "$playlist" ]]; then
    local img_count=0 black_count=0
    while IFS= read -r line; do
      [[ -z "$line" ]] && ((black_count++)) || ((img_count++))
    done < <(tail -n +2 "$playlist")
    
    log "═══ Master: $img_count Bilder, $black_count Schwarz (von 4 Slots) ═══"
  fi
}

verify_playlists(){
  local errors=0
  
  for idx in "${!CLIENT_HOSTS[@]}"; do
    local CID=$((idx+1))
    local playlist="/tmp/playlist_client$(printf '%02d' "$CID").txt"
    
    if [[ ! -f "$playlist" ]]; then
      log "⚠ Playlist fehlt: CID=$CID"
      ((errors++))
      continue
    fi
    
    local lines=$(wc -l < "$playlist")
    if [[ "$lines" -ne 5 ]]; then
      log "⚠ Playlist CID=$CID defekt ($lines Zeilen, erwartet: 5)"
      ((errors++))
    fi
  done
  
  return $errors
}

check_client_health(){
  local down=0
  
  for idx in "${!CLIENT_HOSTS[@]}"; do
    local CID=$((idx+1))
    [[ "$CID" -eq "$MASTER_ID" ]] && continue
    
    local user="${CLIENT_USERS[$idx]}" 
    local host="${CLIENT_HOSTS[$idx]}"
    
    if ! ssh -o BatchMode=yes -o ConnectTimeout=2 "${user}@${host}" ":" >/dev/null 2>&1; then
      log "⚠ Client CID=$CID (${host}) nicht erreichbar!"
      ((down++))
    fi
  done
  
  if [[ $down -eq 0 ]]; then
    log "✓ Alle Clients online"
  else
    log "WARNUNG: $down Client(s) offline!"
  fi
  
  return $down
}

# ----------------- Bilder-Sync -----------------

RSYNC_OPTS="${RSYNC_OPTS:--az --delete --inplace}"
sync_images_to_clients(){
  [[ "$SYNC_IMAGES" != true ]] && return 0
  command -v rsync >/dev/null 2>&1 || { log "WARN: rsync fehlt"; return 0; }
  
  for idx in "${!CLIENT_HOSTS[@]}"; do
    local CID=$((idx+1))
    [[ "$CID" -eq "$MASTER_ID" ]] && continue
    
    local user="${CLIENT_USERS[$idx]}" 
    local host="${CLIENT_HOSTS[$idx]}"
    local remote="/home/${user}/bilder"
    
    ssh -o BatchMode=yes -o ConnectTimeout=5 "${user}@${host}" \
      "mkdir -p '$remote'" >/dev/null 2>&1 || continue
      
    if rsync $RSYNC_OPTS "$IMAGE_DIR/" "${user}@${host}:$remote/" >/dev/null 2>&1; then
      log "Bilder an ${user}@${host} synchronisiert"
    else
      log "WARN: rsync zu ${user}@${host} fehlgeschlagen"
    fi
  done
  return 0
}

# ----------------- Bildauswahl -----------------

get_images() {
  local ALL=() SHUF=()

  # Bildliste (Basename) robust einsammeln
  mapfile -t ALL < <(
    find "$IMAGE_DIR" -maxdepth 1 -type f \
      \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.bmp' -o -iname '*.gif' \) \
      -printf '%f\n' | LC_ALL=C sort
  )

  local total=${#ALL[@]}
  log "Gefundene Bilder gesamt: $total"
  if (( total == 0 )); then
    IMAGES=()
    return 0
  fi

  log "DEBUG ALL.len=${#ALL[@]} – first few: ${ALL[@]:0:3}"

  # deterministisch mischen (Seed = NEXT_TICK)
  local seed="$NEXT_TICK"
  mapfile -t SHUF < <(
    printf '%s\n' "${ALL[@]}" \
    | awk -v s="$seed" 'BEGIN{srand(s)} {print rand() "\t" $0}' \
    | sort -n | cut -f2-
  )

  log "DEBUG SHUF.len=${#SHUF[@]} – first few: ${SHUF[@]:0:3}"

  local need=$(( MONITORS_PER_CLIENT * ${#CLIENT_HOSTS[@]} ))
  local n=$(( need < ${#SHUF[@]} ? need : ${#SHUF[@]} ))

  log "DEBUG set IMAGES with need=$need, n=$n"

  IMAGES=( "${SHUF[@]:0:n}" )

  log "DEBUG IMAGES.len=${#IMAGES[@]} – first few: ${IMAGES[@]:0:4}"
  log "Tick-Auswahl: ${#IMAGES[@]} Dateien (Need=$need, Seed=$seed)"
  ((${#IMAGES[@]})) && log "Tick-Preview[0..3]: ${IMAGES[*]:0:4}"
  return 0
}

# ----------------- Playlists bauen & veröffentlichen -----------------

publish_playlists(){
  local idx CID CID_PAD user host build_tmp
  local i j mask_val

  log "DEBUG publish: IMAGES.len=${#IMAGES[@]}"

  for idx in "${!CLIENT_HOSTS[@]}"; do
    CID=$((idx+1))
    CID_PAD="$(printf '%02d' "$CID")"
    user="${CLIENT_USERS[$idx]}"
    host="${CLIENT_HOSTS[$idx]}"

    # tmp-Datei bauen
    build_tmp="$(mktemp "/tmp/.playlist_build_${CID_PAD}.XXXXXX" 2>/dev/null || echo "/tmp/.playlist_build_${CID_PAD}.$$")" || continue
    : >"$build_tmp" || { log "WARN: konnte $build_tmp nicht schreiben"; continue; }

    # Kopf (Timestamp)
    printf '%s\n' "$(date +%s)" >"$build_tmp"

    # Maske wählen - MIT Client-ID!
    read -r m0 m1 m2 m3 < <( choose_black_mask_for_client "$CID" )
    log "DEBUG MASK CID=${CID_PAD}: $m0 $m1 $m2 $m3"

    # vier Slots schreiben (schwarz nur bei Bedarf)
    for i in 0 1 2 3; do
      j=$(( (CID-1)*MONITORS_PER_CLIENT + i ))
      mask_val=$(eval "echo \$m$i")

      if [[ "$mask_val" -eq 1 ]]; then
        printf '\n' >>"$build_tmp"     # schwarz
      else
        if [[ $j -lt ${#IMAGES[@]} && -n "${IMAGES[$j]}" ]]; then
          printf '%s\n' "${IMAGES[$j]}" >>"$build_tmp"
        else
          printf '\n' >>"$build_tmp"
        fi
      fi
    done

    # Debug: wie viele nicht-leere Slots (Zeilen 2..5)?
    local nonempty=0
    while IFS= read -r ln; do [[ -n "$ln" ]] && ((nonempty++)); done < <(tail -n +2 "$build_tmp")
    log "DEBUG: Client ${CID_PAD}: nicht-leere Slots=$nonempty (von 4)"

    # Deploy: Master lokal atomar + Symlink, andere per scp+mv+Symlink
    local final_pad="/tmp/playlist_client${CID_PAD}.txt"
    local final_unpad="/tmp/playlist_client${CID}.txt"

    if [[ "$CID" -eq "$MASTER_ID" ]]; then
      mv -f "$build_tmp" "$final_pad" 2>/dev/null || cp -f "$build_tmp" "$final_pad"
      ln -sf "$final_pad" "$final_unpad"
      rm -f "$build_tmp" >/dev/null 2>&1 || true
      log "Playlist (Master) → $final_pad (Symlink: $final_unpad)"
    else
      local remote_tmp="/tmp/.playlist_client${CID_PAD}.tmp"
      if scp -q "$build_tmp" "${user}@${host}:${remote_tmp}" >/dev/null 2>&1; then
        if ssh -o BatchMode=yes -o ConnectTimeout=5 "${user}@${host}" \
             "mv -f '$remote_tmp' '$final_pad' 2>/dev/null || cp -f '$remote_tmp' '$final_pad'; ln -sf '$final_pad' '$final_unpad'"; then
          log "Playlist an ${user}@${host} → $final_pad (Symlink: $final_unpad)"
        else
          log "WARN: mv/ln auf ${user}@${host} fehlgeschlagen"
        fi
      else
        log "WARN: SCP zu ${user}@${host} fehlgeschlagen"
      fi
      rm -f "$build_tmp" >/dev/null 2>&1 || true
    fi
  done

  return 0
}

# ----------------- Hauptprogramm -----------------

log "=== START improved_master.sh ==="
mkdir -p "$IMAGE_DIR" >/dev/null 2>&1 || true
chrony_check

# schwarze 1×1 PPM erzeugen, falls nicht vorhanden
[[ -f /tmp/black.ppm ]] || printf "P3\n1 1\n255\n0 0 0\n" > /tmp/black.ppm

# MPV am Master starten
start_mpv

# Initiales Client-Health-Check
check_client_health

# Sofortiger erster Durchlauf
NOW=$(date +%s)
NEXT_TICK=$(( (NOW/INTERVAL+1)*INTERVAL ))
get_images
publish_playlists || true
verify_playlists || log "⚠ Playlist-Validierung fehlgeschlagen!"
show_on_master
show_distribution_stats

# Endlosschleife im 10s-Takt (auf NEXT_TICK ausgerichtet)
while true; do
  NOW=$(date +%s)
  NEXT_TICK=$(( (NOW/INTERVAL+1)*INTERVAL ))
  SLEEP=$(( NEXT_TICK - NOW ))
  (( SLEEP > 0 )) && sleep "$SLEEP"

  # Client-Health-Check alle 60s
  if (( NOW % 60 == 0 )); then
    check_client_health
  fi

  # Bilder ggf. syncen
  if [[ "$SYNC_IMAGES" == true ]]; then
    if (( NOW % SYNC_EVERY == 0 )); then
      sync_images_to_clients
    fi
  fi

  get_images
  publish_playlists || true
  verify_playlists || log "⚠ Playlist-Validierung fehlgeschlagen!"
  show_on_master
  show_distribution_stats
done
