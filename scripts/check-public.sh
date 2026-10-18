#!/usr/bin/env bash
# =============================================================================
# check-public.sh : vérifie qu'aucune donnée personnelle ou secrète ne part
# sur GitHub. Appelé par les hooks Git (.githooks/) et par la CI.
#
# Usage :
#   scripts/check-public.sh --staged            fichiers prêts à être commités (défaut)
#   scripts/check-public.sh --all               tous les fichiers suivis par Git
#   scripts/check-public.sh --history           tout l'historique : fichiers, messages, auteurs
#   scripts/check-public.sh --message FICHIER   un message de commit
#   Option --require-blacklist : échoue si la liste noire personnelle est absente ou vide.
#
# Liste noire : $HOMELAB_BLACKLIST, sinon ~/.config/homelab/blacklist.txt
# (un terme par ligne, HORS du dépôt). Modèle : config/blacklist.example.txt
#
# En CI (variable CI=true), le contenu des lignes trouvées n'est jamais affiché :
# les journaux d'un dépôt public sont publics.
#
# Code de sortie : 0 = rien trouvé, 1 = problème trouvé, 2 = erreur d'utilisation.
# =============================================================================
set -uo pipefail

usage() {
  cat <<'EOF'
Usage : scripts/check-public.sh [--staged | --all | --history | --message FICHIER] [--require-blacklist]
  --staged            fichiers prêts à être commités (défaut)
  --all               tous les fichiers suivis par Git
  --history           tout l'historique : fichiers, messages et auteurs des commits
  --message FICHIER   un message de commit
  --require-blacklist échoue si la liste noire personnelle est absente ou vide
EOF
  exit "${1:-2}"
}

# ── Arguments ────────────────────────────────────────────────────────────────
MODE="staged"
MSG_FILE=""
REQUIRE_BL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --staged)            MODE="staged" ;;
    --all)               MODE="all" ;;
    --history)           MODE="history" ;;
    --message)           MODE="message"; MSG_FILE="${2:-}"; [ $# -gt 1 ] && shift ;;
    --require-blacklist) REQUIRE_BL=1 ;;
    -h|--help)           usage 0 ;;
    *)                   echo "Option inconnue : $1" >&2; usage 2 ;;
  esac
  shift
done

if [ "$MODE" = "message" ]; then
  [ -n "$MSG_FILE" ] && [ -f "$MSG_FILE" ] || { echo "Fichier de message introuvable : ${MSG_FILE:-(aucun)}" >&2; exit 2; }
  MSG_FILE=$(realpath -- "$MSG_FILE")
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Erreur : à lancer dans un dépôt Git." >&2; exit 2; }
ROOT=$(realpath -- "$ROOT")
cd "$ROOT" || exit 2

# ── Affichage ────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; DIM=$'\e[2m'; RST=$'\e[0m'
else
  RED=""; YEL=""; GRN=""; DIM=""; RST=""
fi
QUIET=0
[ "${CI:-}" = "true" ] && QUIET=1
PROBLEMS=0
WARNINGS=0
TERMS=()

TMP=$(mktemp) || exit 2
TERMS_FILE=$(mktemp) || exit 2
trap 'rm -f "$TMP" "$TERMS_FILE"' EXIT

# Affiche un emplacement. En CI, masque ceux qui contiennent un terme de la liste noire.
show() {
  if [ "$QUIET" -eq 1 ] && [ "${#TERMS[@]}" -gt 0 ] && printf '%s\n' "$1" | grep -qFiw -f "$TERMS_FILE"; then
    printf '(emplacement masqué)'
  else
    printf '%s' "$1"
  fi
}

fail() { # fail EMPLACEMENT RAISON [EXTRAIT]
  PROBLEMS=$((PROBLEMS + 1))
  printf '  %s✗%s %s : %s\n' "$RED" "$RST" "$(show "$1")" "$2"
  if [ "$QUIET" -eq 0 ] && [ -n "${3:-}" ]; then
    printf '      %s%s%s\n' "$DIM" "${3:0:160}" "$RST"
  fi
}

warn() {
  WARNINGS=$((WARNINGS + 1))
  printf '  %s!%s %s\n' "$YEL" "$RST" "$1"
}

# ── Motifs génériques ────────────────────────────────────────────────────────
# Certains motifs sont écrits en deux morceaux pour que ce script ne se détecte pas lui-même.
RE_PRIVKEY='-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY( BLOCK)?-----'
RE_WGKEY='PrivateKey[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{42,43}='
RE_MAC='([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}'
RE_TS4='100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}'
RE_TS6='fd7a:115c:''a1e0:'
RE_TSKEY='tskey-[a-z]+-[A-Za-z0-9_-]{8,}'
# Valeurs fictives autorisées (documentation, modèles).
MAC_OK=' AA:BB:CC:DD:EE:FF 00:00:00:00:00:00 FF:FF:FF:FF:FF:FF 00:11:22:33:44:55 '
TS4_OK=' 100.64.0.0 100.100.100.100 100.127.255.255 '

# ── Liste noire personnelle ──────────────────────────────────────────────────
BL_FILE="${HOMELAB_BLACKLIST:-$HOME/.config/homelab/blacklist.txt}"

case "$MODE" in
  staged)  printf 'Vérification avant publication : fichiers prêts à être commités\n' ;;
  all)     printf 'Vérification avant publication : tous les fichiers suivis\n' ;;
  history) printf "Vérification avant publication : tout l'historique\n" ;;
  message) printf 'Vérification avant publication : message de commit\n' ;;
esac

if [ -f "$BL_FILE" ]; then
  BL_REAL=$(realpath -- "$BL_FILE")
  case "$BL_REAL" in
    "$ROOT"/*)
      echo "${RED}✗ La liste noire se trouve DANS le dépôt ($BL_FILE) : déplace-la hors du dépôt.${RST}" >&2
      exit 1 ;;
  esac
  if [ -n "$(find "$BL_FILE" -maxdepth 0 -perm /077 2>/dev/null)" ]; then
    warn "la liste noire est lisible par d'autres comptes : chmod 600 $BL_FILE"
  fi
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in ''|'#'*) continue ;; esac
    if [ "${#line}" -lt 3 ]; then
      warn "liste noire, ligne $n : terme de moins de 3 caractères ignoré"
      continue
    fi
    TERMS+=("$line")
  done < "$BL_FILE"
  [ "${#TERMS[@]}" -gt 0 ] && printf '%s\n' "${TERMS[@]}" > "$TERMS_FILE"
fi

if [ "${#TERMS[@]}" -eq 0 ]; then
  if [ "$REQUIRE_BL" -eq 1 ]; then
    if [ -f "$BL_FILE" ]; then
      echo "${RED}✗ Liste noire vide : $BL_FILE${RST}" >&2
    else
      echo "${RED}✗ Liste noire introuvable : $BL_FILE${RST}" >&2
    fi
    echo "  Lance scripts/install-hooks.sh, puis ajoute tes identifiants (un par ligne)." >&2
    exit 1
  fi
  warn "liste noire absente ou vide ($BL_FILE) : seules les vérifications génériques sont faites"
fi

# ── Vérification d'un nom de fichier ─────────────────────────────────────────
check_path() {
  local p=$1 base=${1##*/} i=0 term
  case "$base" in
    homelab.conf.example|.env.example|blacklist.example.txt) ;;
    homelab.conf|.env|.env.*|*.nmconnection|authorized_keys*|known_hosts*|key.properties)
      fail "$p" "fichier de configuration réel ou sensible" ;;
    id_rsa*|id_ed25519*|id_ecdsa*|id_dsa*)
      fail "$p" "fichier de clé SSH" ;;
    *.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|*.kdbx|*.ovpn)
      fail "$p" "clé, certificat ou coffre de mots de passe" ;;
    *.log)
      fail "$p" "fichier journal (peut contenir des noms et des adresses)" ;;
    blacklist*.txt)
      fail "$p" "liste noire personnelle (ne doit jamais être publiée)" ;;
  esac
  [ "${#TERMS[@]}" -gt 0 ] || return 0
  printf '%s\n' "$p" | grep -qFiw -f "$TERMS_FILE" || return 0
  for term in "${TERMS[@]}"; do
    i=$((i + 1))
    if printf '%s\n' "$p" | grep -qFiw -e "$term"; then
      fail "$p" "le chemin contient le terme n°$i de ta liste noire"
    fi
  done
}

# ── Vérification d'un contenu ────────────────────────────────────────────────
scan_file() { # scan_file EMPLACEMENT FICHIER
  local label=$1 f=$2 hit ln val norm i term
  [ -s "$f" ] || return 0
  if ! grep -Iq -e '' "$f"; then
    warn "$(show "$label") : fichier binaire non analysé, vérifie-le à la main (métadonnées d'image…)"
    return 0
  fi

  while IFS= read -r hit; do
    fail "$label:${hit%%:*}" "clé privée"
  done < <(grep -nE -e "$RE_PRIVKEY" "$f")

  while IFS= read -r hit; do
    fail "$label:${hit%%:*}" "clé privée WireGuard"
  done < <(grep -nE -e "$RE_WGKEY" "$f")

  while IFS= read -r hit; do
    ln=${hit%%:*}; val=${hit#*:}
    norm=$(printf '%s' "$val" | tr 'a-f-' 'A-F:')
    case "$MAC_OK" in *" $norm "*) continue ;; esac
    fail "$label:$ln" "adresse MAC (identifiant matériel)" "$val"
  done < <(grep -noEw -e "$RE_MAC" "$f")

  while IFS= read -r hit; do
    ln=${hit%%:*}; val=${hit#*:}
    case "$TS4_OK" in *" $val "*) continue ;; esac
    fail "$label:$ln" "adresse Tailscale (plage 100.64.0.0/10)" "$val"
  done < <(grep -noEw -e "$RE_TS4" "$f")

  while IFS= read -r hit; do
    fail "$label:${hit%%:*}" "adresse IPv6 Tailscale" "${hit#*:}"
  done < <(grep -niF -e "$RE_TS6" "$f")

  while IFS= read -r hit; do
    fail "$label:${hit%%:*}" "clé d'authentification Tailscale"
  done < <(grep -nE -e "$RE_TSKEY" "$f")

  # Liste noire : un premier passage rapide, puis le détail seulement si besoin.
  [ "${#TERMS[@]}" -gt 0 ] || return 0
  grep -qFiw -f "$TERMS_FILE" "$f" || return 0
  i=0
  for term in "${TERMS[@]}"; do
    i=$((i + 1))
    while IFS= read -r hit; do
      fail "$label:${hit%%:*}" "terme n°$i de ta liste noire" "${hit#*:}"
    done < <(grep -nFiw -e "$term" "$f")
  done
}

# ── Modes ────────────────────────────────────────────────────────────────────
scan_staged() {
  local p
  while IFS= read -r -d '' p; do
    check_path "$p"
    if git show ":$p" > "$TMP" 2>/dev/null; then
      scan_file "$p" "$TMP"
    fi
  done < <(git diff --cached --name-only --diff-filter=ACMR -z)
}

scan_all() {
  local p
  while IFS= read -r -d '' p; do
    check_path "$p"
    if [ -f "$p" ] && [ ! -L "$p" ]; then
      scan_file "$p" "$p"
    fi
  done < <(git ls-files -z)
}

scan_history() {
  local type sha path c
  local -A seen=()
  if [ -z "$(git rev-list -n 1 --all 2>/dev/null)" ]; then
    printf '  (aucun commit pour le moment)\n'
    return 0
  fi
  # Chaque version de chaque fichier, une seule fois.
  while read -r type sha path; do
    [ "$type" = "blob" ] || continue
    if [ -n "$path" ] && [ -z "${seen[$path]+x}" ]; then
      seen[$path]=1
      check_path "$path"
    fi
    git cat-file blob "$sha" > "$TMP" 2>/dev/null || continue
    scan_file "${path:-objet} @${sha:0:8}" "$TMP"
  done < <(git rev-list --all --objects | git cat-file --batch-check='%(objecttype) %(objectname) %(rest)')
  # Messages de commit.
  while read -r c; do
    git log -1 --format=%B "$c" > "$TMP"
    scan_file "message du commit ${c:0:8}" "$TMP"
  done < <(git rev-list --all)
  # Noms et e-mails des auteurs.
  git log --all --format='%h  %an <%ae>  %cn <%ce>' > "$TMP"
  scan_file "auteurs des commits" "$TMP"
}

scan_message() {
  grep -v '^#' "$MSG_FILE" > "$TMP" || true
  scan_file "message de commit" "$TMP"
}

case "$MODE" in
  staged)  scan_staged ;;
  all)     scan_all ;;
  history) scan_history ;;
  message) scan_message ;;
esac

# ── Bilan ────────────────────────────────────────────────────────────────────
if [ "$PROBLEMS" -gt 0 ]; then
  printf '%s✗ %d problème(s) trouvé(s) : publication bloquée.%s\n' "$RED" "$PROBLEMS" "$RST"
  case "$MODE" in
    staged)  printf '  Corrige le fichier, ou retire-le du commit : git restore --staged FICHIER\n' ;;
    message) printf '  Reformule le message de commit.\n' ;;
    *)       printf '  La donnée est déjà dans un commit : voir docs/SECURITY.md, « En cas de fuite ».\n' ;;
  esac
  exit 1
fi
if [ "$WARNINGS" -gt 0 ]; then
  printf '%s✓ Aucun problème bloquant (%d avertissement(s)).%s\n' "$GRN" "$WARNINGS" "$RST"
else
  printf '%s✓ Aucun problème détecté.%s\n' "$GRN" "$RST"
fi
exit 0
