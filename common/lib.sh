# shellcheck shell=bash
# =============================================================================
# lib.sh : fonctions communes aux scripts du serveur et de la tour.
# Fichier sourcé, jamais exécuté. Installé dans /usr/local/lib/homelab/lib.sh,
# propriété de root.
# =============================================================================

HOMELAB_VERSION="0.2.0"
HOMELAB_API=1

# Sources du système (constantes, modifiables seulement dans une copie de test).
HL_PROC_STAT=/proc/stat
HL_BOOT_ID_FILE=/proc/sys/kernel/random/boot_id
# Échéance d'extinction de la tour :
#  - demandes « prolonger » et « ne pas éteindre », écrites par le compte homelab ;
#  - délai accordé après une session locale, écrit par root uniquement.
HL_AO_REQ=/var/lib/homelab/state/autooff
HL_AO_ROOT=/var/lib/homelab-autooff/grace

# Seules ces clés sont lues dans la configuration ; tout le reste est ignoré.
HL_CONF_KEYS="SERVER_HOST SERVER_USER TOWER_HOST TOWER_USER LINK_INTERFACE \
LINK_SERVER_IP LINK_TOWER_IP TOWER_MAC AUTO_OFF_DEFAULT_HOURS AUTO_OFF_EXTEND_HOURS \
AUTO_OFF_MAX_HOURS AUTO_OFF_SESSION_GRACE_MIN SERVER_SERVICES TOWER_SERVICES \
SERVER_SMART_DEVICES TOWER_SMART_DEVICES ACTION_LOG ACTIONS_KEY_FROM TOWER_KEY_FROM \
WAKE_COOLDOWN_S WAKE_SCHEDULE"

# ── Configuration ────────────────────────────────────────────────────────────
# Lue SANS être exécutée : uniquement des lignes CLÉ="valeur" ou CLÉ=valeur,
# avec une clé de la liste ci-dessus. Le reste est ignoré.
hl_load_conf() { # hl_load_conf FICHIER
  local f=$1 line key val
  local re='^[[:space:]]*([A-Z_][A-Z0-9_]*)=("[^"]*"|[^[:space:]#"]*)[[:space:]]*(#.*)?$'
  [ -r "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [[ $line =~ $re ]] || continue
    key=${BASH_REMATCH[1]}
    val=${BASH_REMATCH[2]}
    val=${val#\"}
    val=${val%\"}
    case " $HL_CONF_KEYS " in
      *" $key "*) printf -v "$key" '%s' "$val" ;;
    esac
  done < "$f"
}

# ── Validations : toute valeur utilisée dans une commande passe par ici ───────
hl_valid_iface() { [[ ${1:-} =~ ^[A-Za-z0-9._-]{1,15}$ ]]; }
hl_valid_mac()   { [[ ${1:-} =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; }
hl_valid_ipv4()  { [[ ${1:-} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
hl_valid_host()  { [[ ${1:-} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; }
# Entier sans zéro en tête : « 08 » serait lu en octal par l'arithmétique du shell.
hl_valid_uint()  { [[ ${1:-} =~ ^(0|[1-9][0-9]{0,11})$ ]]; }
hl_valid_from()  { [[ ${1:-} =~ ^[0-9A-Fa-f:.,/]{1,200}$ ]]; }
hl_in_range()    { hl_valid_uint "${1:-}" && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }

# ── JSON ─────────────────────────────────────────────────────────────────────
hl_json_str() { # chaîne JSON échappée, guillemets compris
  local s=${1:-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
  printf '"%s"' "$s"
}

hl_fmt1() { # dixièmes -> « 41.5 »
  local x=${1:-0}
  printf '%d.%d' $((x / 10)) $((x % 10))
}

hl_bool() { if "$@"; then printf 'true'; else printf 'false'; fi; }

hl_now() { date --iso-8601=seconds; }
hl_iso() { date -d "@$1" --iso-8601=seconds; }

# ── Commande reçue, réponses, journal ────────────────────────────────────────
# Variables globales utilisées : VIA, FROM, RAW, ARGS, ACTION_LOG.

hl_sanitize() { printf '%s' "${1:-}" | tr -c 'a-z0-9 -' '?' | cut -c1-40; }

hl_log_action() { # hl_log_action ACTION RÉSULTAT
  local size
  [ -n "${ACTION_LOG:-}" ] || return 0
  if [ -f "$ACTION_LOG" ]; then
    size=$(stat -c %s "$ACTION_LOG" 2>/dev/null || echo 0)
    [ "$size" -gt 1048576 ] && mv -f "$ACTION_LOG" "$ACTION_LOG.1" 2>/dev/null
  fi
  printf '{"ts":%s,"action":%s,"result":%s,"via":%s,"from":%s}\n' \
    "$(hl_json_str "$(hl_now)")" "$(hl_json_str "$1")" "$(hl_json_str "$2")" \
    "$(hl_json_str "${VIA:-?}")" "$(hl_json_str "${FROM:-?}")" >> "$ACTION_LOG" 2>/dev/null || true
}

hl_fail_json() { # hl_fail_json CODE MESSAGE : échec, code de sortie 1
  printf '{"ok":false,"error":%s,"message":%s}\n' "$(hl_json_str "$1")" "$(hl_json_str "$2")"
  exit 1
}

hl_refuse() { # hl_refuse CODE MESSAGE : commande non autorisée, journalisée, code 2
  hl_log_action "$(hl_sanitize "${RAW:-}")" "refused"
  printf '{"ok":false,"error":%s,"message":%s}\n' "$(hl_json_str "$1")" "$(hl_json_str "$2")"
  exit 2
}

# Remplit VIA, FROM, RAW et ARGS. Via SSH, le texte reçu est filtré avant tout :
# minuscules, chiffres, espaces et tirets seulement, 64 caractères au plus.
# Il n'est jamais exécuté : il est seulement découpé en mots.
hl_parse_command() {
  ARGS=()
  if [ -n "${SSH_CONNECTION:-}" ]; then
    VIA="ssh"
    FROM=${SSH_CONNECTION%% *}
    [[ $FROM =~ ^[0-9A-Fa-f:.]{2,45}$ ]] || FROM="?"
    RAW=${SSH_ORIGINAL_COMMAND:-}
    if [ "${#RAW}" -gt 64 ] || ! [[ $RAW =~ ^[a-z0-9\ -]*$ ]]; then
      hl_refuse "forbidden" "commande refusée"
    fi
    read -r -a ARGS <<< "$RAW"
  else
    if [ -n "${INVOCATION_ID:-}" ]; then
      VIA="timer"; FROM="systemd"     # lancé par un minuteur systemd
    else
      VIA="local"; FROM="local"
    fi
    RAW="$*"
    ARGS=("$@")
  fi
}

# ── Mesures ──────────────────────────────────────────────────────────────────
hl_uptime_s() { local u; read -r u _ < /proc/uptime; printf '%s' "${u%%.*}"; }

hl_cpu_pct() { # occupation du processeur sur 0,3 s, en %
  local -a a b
  local k ta=0 tb=0 ia ib
  read -r -a a < "$HL_PROC_STAT"
  sleep 0.3
  read -r -a b < "$HL_PROC_STAT"
  for k in 1 2 3 4 5 6 7 8; do
    ta=$((ta + ${a[k]:-0}))
    tb=$((tb + ${b[k]:-0}))
  done
  ia=$((${a[4]:-0} + ${a[5]:-0}))
  ib=$((${b[4]:-0} + ${b[5]:-0}))
  if [ $((tb - ta)) -le 0 ]; then printf 'null'; return; fi
  hl_fmt1 $((1000 * ((tb - ta) - (ib - ia)) / (tb - ta)))
}

hl_mem_used_pct() {
  local k v total="" avail=""
  while read -r k v _; do
    case "$k" in
      MemTotal:)     total=$v ;;
      MemAvailable:) avail=$v ;;
    esac
  done < /proc/meminfo
  if [ -z "$total" ] || [ -z "$avail" ] || [ "$total" -le 0 ]; then printf 'null'; return; fi
  hl_fmt1 $((1000 * (total - avail) / total))
}

hl_disk_used_pct() {
  local pct=""
  { read -r _; read -r _ _ _ _ pct _; } < <(df -P / 2>/dev/null)
  pct=${pct%\%}
  if [[ $pct =~ ^[0-9]{1,3}$ ]]; then printf '%s' "$pct"; else printf 'null'; fi
}

# Température d'un capteur hwmon, en dixièmes de degré (rien si introuvable).
hl_hwmon_temp() { # hl_hwmon_temp NOM_DU_PILOTE [ÉTIQUETTE]
  local h f v
  for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = "$1" ] || continue
    for f in "$h"/temp*_input; do
      [ -r "$f" ] || continue
      if [ -n "${2:-}" ] && [ "$(cat "${f%_input}_label" 2>/dev/null)" != "$2" ]; then continue; fi
      v=$(cat "$f" 2>/dev/null)
      if [[ $v =~ ^[0-9]+$ ]]; then printf '%s' $((v / 100)); return 0; fi
    done
  done
  return 1
}

hl_thermal_zone_temp() { # zone « x86_pkg_temp », sinon la plus chaude, en dixièmes
  local z v best=""
  for z in /sys/class/thermal/thermal_zone*; do
    [ "$(cat "$z/type" 2>/dev/null)" = "x86_pkg_temp" ] || continue
    v=$(cat "$z/temp" 2>/dev/null)
    if [[ $v =~ ^[0-9]+$ ]]; then printf '%s' $((v / 100)); return 0; fi
  done
  for z in /sys/class/thermal/thermal_zone*; do
    v=$(cat "$z/temp" 2>/dev/null) || continue
    [[ $v =~ ^[0-9]+$ ]] || continue
    if [ -z "$best" ] || [ "$v" -gt "$best" ]; then best=$v; fi
  done
  [ -n "$best" ] || return 1
  printf '%s' $((best / 100))
}

hl_cpu_temp() { # température du processeur (Intel ou AMD), ou « null »
  local t
  t=$(hl_hwmon_temp coretemp "Package id 0") \
    || t=$(hl_hwmon_temp k10temp Tctl) \
    || t=$(hl_hwmon_temp zenpower Tdie) \
    || t=$(hl_thermal_zone_temp) \
    || { printf 'null'; return; }
  hl_fmt1 "$t"
}

hl_gpu_temp() { # température d'une carte graphique AMD, ou « null »
  local t
  t=$(hl_hwmon_temp amdgpu edge) || { printf 'null'; return; }
  hl_fmt1 "$t"
}

# ── Extinction automatique de la tour ────────────────────────────────────────
hl_boot_id() { head -c 64 "$HL_BOOT_ID_FILE" 2>/dev/null | tr -cd '0-9a-f-'; }

hl_btime() { # heure du démarrage, en secondes depuis 1970
  local k v
  while read -r k v _; do
    if [ "$k" = "btime" ]; then printf '%s' "$v"; return 0; fi
  done < "$HL_PROC_STAT"
  return 1
}

# Écriture atomique : fichier temporaire au nom aléatoire, puis renommage.
hl_state_write() { # hl_state_write FICHIER CONTENU
  local f=$1 tmp
  tmp=$(mktemp "${f%/*}/.tmp.XXXXXX") || return 1
  if printf '%s\n' "$2" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$f"; then return 0; fi
  rm -f "$tmp"
  return 1
}

# Lit « ID_DÉMARRAGE VALEUR_A VALEUR_B » dans ST_A et ST_B.
# Les valeurs d'un démarrage précédent, ou invalides, sont ignorées (0).
# Seul un fichier ordinaire est lu (pas de lien, pas de tube), 200 octets au plus.
hl_read_state() { # hl_read_state FICHIER
  local id="" a="" b=""
  ST_A=0
  ST_B=0
  [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] || return 0
  read -r id a b < <(timeout 2 head -c 200 "$1" 2>/dev/null) || true
  [ -n "$id" ] && [ "$id" = "$(hl_boot_id)" ] || return 0
  hl_valid_uint "$a" && ST_A=$a
  hl_valid_uint "$b" && ST_B=$b
  return 0
}

# Calcule l'échéance (heures en secondes depuis 1970) :
#   base     = démarrage + AUTO_OFF_DEFAULT_HOURS
#   demande  = échéance choisie (« prolonger », « éteindre dans N min »), sinon la base
#   maintien = « ne pas éteindre », jusqu'au plafond
#   plafond  = démarrage + AUTO_OFF_MAX_HOURS : aucune demande ne le dépasse
#   prévue   = la demande (ou la base), le maintien, limités au plafond
#   délai    = report accordé par root quand la tour est utilisée (session
#              locale, mise à jour, tâche protégée) ; seul à dépasser le plafond
#   effective = la plus tardive entre « prévue » et « délai »
# Définit AO_BTIME AO_BASE AO_CAP AO_TARGET AO_HOLD AO_GRACE AO_PLANNED AO_EFFECTIVE.
hl_autooff_compute() {
  local def=${AUTO_OFF_DEFAULT_HOURS:-8} max=${AUTO_OFF_MAX_HOURS:-48} e
  hl_in_range "$def" 1 720 || def=8
  hl_in_range "$max" 1 720 || max=48
  [ "$max" -ge "$def" ] || max=$def
  AO_BTIME=$(hl_btime) || AO_BTIME=$(date +%s)
  AO_BASE=$((AO_BTIME + def * 3600))
  AO_CAP=$((AO_BTIME + max * 3600))
  hl_read_state "$HL_AO_REQ";  AO_TARGET=$ST_A; AO_HOLD=$ST_B
  hl_read_state "$HL_AO_ROOT"; AO_GRACE=$ST_A
  e=$AO_BASE
  [ "$AO_TARGET" -gt 0 ] && e=$AO_TARGET
  [ "$AO_HOLD" -gt "$e" ] && e=$AO_HOLD
  [ "$e" -gt "$AO_CAP" ] && e=$AO_CAP
  AO_PLANNED=$e
  [ "$AO_GRACE" -gt "$e" ] && e=$AO_GRACE
  AO_EFFECTIVE=$e
}

# Un programme bloque-t-il l'extinction avec le mécanisme standard de systemd ?
# (verrou « shutdown » en mode « block », pris par exemple avec
#  systemd-inhibit --what=shutdown --why="sauvegarde" COMMANDE, ou par
#  PackageKit pendant une mise à jour lancée depuis Discover)
# Affiche « QUI (POURQUOI) » pour le premier verrou trouvé.
hl_shutdown_blocker() {
  local out
  # Format de busctl : "QUOI" "QUI" "POURQUOI" "MODE" UID PID, répété.
  local re='"([a-z:-]+)" "((\\.|[^"\\])*)" "((\\.|[^"\\])*)" "([a-z-]+)" [0-9]+ [0-9]+'
  command -v busctl >/dev/null 2>&1 || return 1
  out=$(timeout 3 busctl call org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager ListInhibitors 2>/dev/null) || return 1
  while [[ $out =~ $re ]]; do
    out=${out#*"${BASH_REMATCH[0]}"}
    case ":${BASH_REMATCH[1]}:" in *:shutdown:*) ;; *) continue ;; esac
    case "${BASH_REMATCH[6]}" in block|block-weak) ;; *) continue ;; esac
    printf '%s (%s)' "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}"
    return 0
  done
  return 1
}

# La tour fait-elle quelque chose qu'il ne faut pas interrompre ? Affiche la raison.
hl_busy_reason() {
  if pgrep -x pacman >/dev/null 2>&1; then
    printf 'mise à jour pacman en cours'
    return 0
  fi
  local who
  who=$(hl_shutdown_blocker) || return 1
  printf 'extinction bloquée par %s' "$who"
}

# Vérifie que sshd impose bien la commande au compte homelab (réglage effectif,
# après lecture de tous les fichiers de configuration).
hl_forcecommand_ok() { # hl_forcecommand_ok COMMANDE_ATTENDUE
  local line
  line=$(sshd -T -C user=homelab,host=localhost,addr=127.0.0.1 2>/dev/null | grep -i '^forcecommand ' || true)
  [ "${line,,}" = "forcecommand ${1,,}" ]
}

# Avertit si sshd n'accepte qu'une liste de comptes : homelab doit en faire partie.
hl_sshd_filter_warning() {
  local f
  f=$(sshd -T -C user=homelab,host=localhost,addr=127.0.0.1 2>/dev/null \
      | grep -Ei '^(allowusers|allowgroups|denyusers|denygroups) ' || true)
  [ -z "$f" ] || printf '  ! sshd filtre les comptes (%s) : vérifie que « homelab » est autorisé\n' \
    "$(printf '%s' "$f" | cut -d' ' -f1 | sort -u | paste -sd ',' -)"
}

# Une session graphique locale est-elle ouverte, active et déverrouillée ?
hl_session_active() {
  local id k v typ act lock rem cls
  command -v loginctl >/dev/null 2>&1 || return 1
  while read -r id _; do
    [[ $id =~ ^[A-Za-z0-9]+$ ]] || continue
    typ=""; act=""; lock=""; rem=""; cls=""
    while IFS='=' read -r k v; do
      case "$k" in
        Type)       typ=$v ;;
        Active)     act=$v ;;
        LockedHint) lock=$v ;;
        Remote)     rem=$v ;;
        Class)      cls=$v ;;
      esac
    done < <(loginctl show-session "$id" -p Type -p Active -p LockedHint -p Remote -p Class 2>/dev/null)
    if [ "$cls" = "user" ] && [ "$rem" = "no" ] && [ "$act" = "yes" ] && [ "$lock" = "no" ]; then
      case "$typ" in wayland|x11) return 0 ;; esac
    fi
  done < <(loginctl list-sessions --no-legend 2>/dev/null)
  return 1
}
