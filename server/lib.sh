# shellcheck shell=bash
# =============================================================================
# lib.sh : fonctions communes aux scripts du serveur (fichier sourcé, pas exécuté).
# Installé dans /usr/local/lib/homelab/lib.sh, propriété de root.
# =============================================================================

HOMELAB_VERSION="0.1.0"
HOMELAB_API=1

# Seules ces clés sont lues dans la configuration ; tout le reste est ignoré.
HL_CONF_KEYS="SERVER_HOST SERVER_USER TOWER_HOST TOWER_USER LINK_INTERFACE \
LINK_SERVER_IP LINK_TOWER_IP TOWER_MAC AUTO_OFF_DEFAULT_HOURS AUTO_OFF_EXTEND_HOURS \
AUTO_OFF_MAX_HOURS SERVER_SERVICES TOWER_SERVICES SERVER_SMART_DEVICES \
TOWER_SMART_DEVICES ACTION_LOG ACTIONS_KEY_FROM WAKE_COOLDOWN_S"

# Lit la configuration SANS l'exécuter : uniquement des lignes CLÉ="valeur"
# ou CLÉ=valeur, avec une clé de la liste ci-dessus. Le reste est ignoré.
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
hl_valid_uint()  { [[ ${1:-} =~ ^[0-9]{1,12}$ ]]; }

# ── JSON ─────────────────────────────────────────────────────────────────────
# Chaîne JSON correctement échappée, guillemets compris.
hl_json_str() {
  local s=${1:-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
  printf '"%s"' "$s"
}

# Nombre exprimé en dixièmes -> « 41.5 ».
hl_fmt1() {
  local x=${1:-0}
  printf '%d.%d' $((x / 10)) $((x % 10))
}

hl_now() { date --iso-8601=seconds; }
