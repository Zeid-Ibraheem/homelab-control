#!/usr/bin/env bash
# =============================================================================
# tower/install.sh : installe le pilotage de la tour (script « tour ») et son
# extinction automatique.
#
# À lancer en root, depuis une copie du dépôt sur la tour :
#   sudo tower/install.sh                  installe ou met à jour
#   sudo tower/install.sh add-key "CLÉ"    autorise la clé publique du serveur
#   sudo tower/install.sh uninstall        retire scripts, minuteur, règle sudo et réglage SSH
#
# Aucune valeur personnelle ici : tout vient de /etc/homelab/homelab.conf.
# =============================================================================
set -euo pipefail
umask 022

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
CONF=/etc/homelab/homelab.conf
HL_USER=homelab
HL_HOME=/var/lib/homelab
BIN=/usr/local/bin/tour
LIBDIR=/usr/local/lib/homelab
SUDOERS=/etc/sudoers.d/homelab-tower
SSHD_DROPIN=/etc/ssh/sshd_config.d/50-homelab-tower.conf
UNITDIR=/etc/systemd/system
LOGDIR=/var/log/homelab
ROOT_STATE=/var/lib/homelab-autooff

say() { printf '%s\n' "$*"; }
ok()  { printf '✓ %s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "À lancer avec sudo."
# shellcheck source=../common/lib.sh
. "$REPO/common/lib.sh"

reload_ssh() {
  sshd -t || return 1
  systemctl reload sshd 2>/dev/null || systemctl reload ssh
}

check_int() { # check_int NOM VALEUR MIN MAX
  if ! hl_valid_uint "$2" || [ "$2" -lt "$3" ] || [ "$2" -gt "$4" ]; then
    say "  ✗ $1 doit être un nombre entre $3 et $4"
    return 1
  fi
}

# Services redémarrables depuis l'application : format, liste interdite, et
# présence parmi les services suivis (sinon l'application ne les affiche pas).
check_restartable() { # check_restartable NOM_CLÉ "REDÉMARRABLES" "SUIVIS"
  local u bad=0
  for u in $2; do
    if ! hl_valid_restartable "$u"; then
      say "  ✗ $1 : « $u » : minuscules, chiffres et tirets seulement, sans « .service »"; bad=1
    elif hl_restart_denied "$u"; then
      say "  ✗ $1 : « $u » ne peut pas être redémarré à distance (un échec couperait l'accès à la machine)"; bad=1
    elif ! hl_in_list "$u" "$3"; then
      say "  ✗ $1 : « $u » doit aussi figurer dans les services suivis"; bad=1
    fi
  done
  return "$bad"
}

check_conf() {
  local bad=0
  hl_load_conf "$CONF" || die "configuration illisible : $CONF"
  local max=${AUTO_OFF_MAX_HOURS:-8} def=${AUTO_OFF_DEFAULT_HOURS:-8} wake=${AUTO_OFF_WAKE_HOURS:-${AUTO_OFF_DEFAULT_HOURS:-8}} u
  check_int AUTO_OFF_DEFAULT_HOURS "$def" 1 720 || bad=1
  check_int AUTO_OFF_WAKE_HOURS "$wake" 1 720 || bad=1
  check_int AUTO_OFF_EXTEND_HOURS "${AUTO_OFF_EXTEND_HOURS:-2}" 1 720 || bad=1
  check_int AUTO_OFF_MAX_HOURS "$max" 1 720 || bad=1
  check_int AUTO_OFF_SESSION_GRACE_MIN "${AUTO_OFF_SESSION_GRACE_MIN:-30}" 1 1440 || bad=1
  if [ "$bad" -eq 0 ] && { [ "$max" -lt "$def" ] || [ "$max" -lt "$wake" ]; }; then
    say "  ✗ AUTO_OFF_MAX_HOURS (plafond) doit être supérieur ou égal à AUTO_OFF_DEFAULT_HOURS et à AUTO_OFF_WAKE_HOURS"; bad=1
  fi
  for u in ${TOWER_SMART_DEVICES:-}; do
    hl_valid_disk "$u" || { say "  ✗ TOWER_SMART_DEVICES : « $u » n'est pas un disque (/dev/nvme0n1, /dev/sda, /dev/disk/by-id/…)"; bad=1; }
  done
  for u in ${TOWER_SERVICES:-}; do
    hl_valid_unit "$u" || { say "  ✗ TOWER_SERVICES : « $u » n'est pas un nom de service"; bad=1; }
  done
  check_restartable TOWER_RESTARTABLE "${TOWER_RESTARTABLE:-}" "${TOWER_SERVICES:-}" || bad=1
  case "${ACTION_LOG:-$LOGDIR/actions.log}" in
    "$LOGDIR"/*) ;;
    *) say "  ✗ ACTION_LOG doit se trouver dans $LOGDIR/"; bad=1 ;;
  esac
  if [ -n "${TOWER_KEY_FROM:-}" ] && ! hl_valid_from "$TOWER_KEY_FROM"; then
    say "  ✗ TOWER_KEY_FROM invalide"; bad=1
  fi
  [ "$bad" -eq 0 ] || die "corrige $CONF (sudoedit $CONF), puis relance."
  grep -Eq '^[[:space:]]*AUTO_OFF_WAKE_HOURS=' "$CONF" \
    || say "  ! AUTO_OFF_WAKE_HOURS absent : une tour allumée par le serveur gardera $def h (ajoute la ligne AUTO_OFF_WAKE_HOURS=4)"
  [ -n "${TOWER_KEY_FROM:-}" ] || say "  ! TOWER_KEY_FROM est vide : la clé du serveur sera acceptée depuis n'importe quelle adresse"
  case ",${TOWER_KEY_FROM:-}," in
    *,192.0.2.*) say "  ! TOWER_KEY_FROM contient encore l'adresse d'exemple 192.0.2.x : mets celle du serveur sur le câble" ;;
  esac
  ok "configuration valide"
}

do_install() {
  local tmp u

  # 1. Outils nécessaires (présents sur une installation Arch avec SSH)
  for u in sudo sshd systemctl systemd-run loginctl busctl visudo pgrep logger; do
    command -v "$u" >/dev/null 2>&1 || die "commande « $u » introuvable (Arch : sudo pacman -Syu --needed sudo openssh procps-ng util-linux)"
  done
  grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
    || die "Ajoute la ligne « Include /etc/ssh/sshd_config.d/*.conf » au début de /etc/ssh/sshd_config, puis relance."
  ok "outils présents"
  if ! command -v smartctl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    say "  ! santé des disques indisponible sans smartctl et jq : sudo pacman -S --needed smartmontools jq"
  fi

  # 2. Configuration (créée à partir du modèle au premier lancement)
  if [ ! -f "$CONF" ]; then
    install -d -m 755 "$(dirname "$CONF")"
    install -m 640 "$REPO/config/homelab.conf.example" "$CONF"
    say "→ Configuration créée : $CONF"
    say "  Vérifie la partie « Extinction automatique » et TOWER_KEY_FROM : sudoedit $CONF"
    say "  Puis relance : sudo $0"
    exit 0
  fi
  check_conf

  # 3. Compte dédié, sans mot de passe ni droits d'administrateur
  if ! id "$HL_USER" >/dev/null 2>&1; then
    if getent group "$HL_USER" >/dev/null; then
      useradd --system --gid "$HL_USER" --create-home --home-dir "$HL_HOME" --shell /bin/bash "$HL_USER"
    else
      useradd --system --user-group --create-home --home-dir "$HL_HOME" --shell /bin/bash "$HL_USER"
    fi
    ok "compte $HL_USER créé"
  fi
  # Aucun mot de passe utilisable (« * ») : connexion par clé uniquement.
  usermod -p '*' "$HL_USER"
  # Dossiers vérifiés un par un : jamais de lien suivi (voir hl_safe_dir).
  hl_safe_dir "$HL_HOME" "$HL_USER" 750 || die "dossier $HL_HOME non sûr"
  hl_safe_dir "$HL_HOME/.ssh" "$HL_USER" 700 || die "dossier $HL_HOME/.ssh non sûr"
  [ ! -L "$HL_HOME/.ssh/authorized_keys" ] || die "$HL_HOME/.ssh/authorized_keys est un lien : arrêt"
  [ -f "$HL_HOME/.ssh/authorized_keys" ] \
    || install -o "$HL_USER" -g "$HL_USER" -m 600 /dev/null "$HL_HOME/.ssh/authorized_keys"
  hl_safe_dir "$HL_HOME/state" "$HL_USER" 750 || die "dossier $HL_HOME/state non sûr"
  hl_safe_dir "$LOGDIR" "$HL_USER" 750 || die "dossier $LOGDIR non sûr"
  hl_safe_dir "$ROOT_STATE" root 755 || die "dossier $ROOT_STATE non sûr"

  # 4. Configuration : lisible par homelab, modifiable par root uniquement
  chown root:"$HL_USER" "$CONF"
  chmod 640 "$CONF"

  # 5. Scripts, propriété de root
  install -d -m 755 "$LIBDIR"
  install -m 644 "$REPO/common/lib.sh" "$LIBDIR/lib.sh"
  install -m 755 "$HERE/tour-root" "$LIBDIR/tour-root"
  install -m 755 "$HERE/homelab-autooff" "$LIBDIR/homelab-autooff"
  install -m 755 "$HERE/tour" "$BIN"
  ok "scripts installés"

  # 6. sudo : éteindre, redémarrer, lire la santé de la tour, et redémarrer
  #    chaque service autorisé ; arguments fixes
  tmp=$(mktemp)
  hl_sudoers_line "$HL_USER" "$LIBDIR/tour-root" "poweroff reboot health" "${TOWER_RESTARTABLE:-}" > "$tmp"
  if ! visudo -cf "$tmp" >/dev/null; then rm -f "$tmp"; die "règle sudo invalide"; fi
  install -m 440 "$tmp" "$SUDOERS"
  rm -f "$tmp"
  tmp=$(sudo -l -U "$HL_USER" 2>/dev/null || true)
  grep -qF "$LIBDIR/tour-root poweroff" <<< "$tmp" \
    || die "sudo ne lit pas $SUDOERS : vérifie la ligne « @includedir /etc/sudoers.d » de /etc/sudoers (sudo visudo)"
  for u in ${TOWER_RESTARTABLE:-}; do
    grep -qF "$LIBDIR/tour-root restart $u" <<< "$tmp" || die "règle sudo incomplète pour « $u »"
  done
  ok "règle sudo limitée à « tour-root poweroff », « reboot » et « health »"
  [ -z "${TOWER_RESTARTABLE:-}" ] || ok "services redémarrables depuis l'application : $TOWER_RESTARTABLE"

  # 7. Extinction automatique : vérification chaque minute
  install -m 644 "$HERE/homelab-autooff.service" "$UNITDIR/homelab-autooff.service"
  install -m 644 "$HERE/homelab-autooff.timer" "$UNITDIR/homelab-autooff.timer"
  systemctl daemon-reload
  systemctl enable --now homelab-autooff.timer
  ok "extinction automatique active (homelab-autooff.timer)"

  # 8. SSH : le compte homelab ne peut lancer que le script « tour »
  install -m 644 "$HERE/sshd-homelab-tower.conf" "$SSHD_DROPIN"
  if ! reload_ssh; then
    rm -f "$SSHD_DROPIN"
    reload_ssh || true
    die "configuration SSH refusée : le réglage a été retiré, rien n'a changé côté SSH"
  fi
  hl_forcecommand_ok "$BIN" \
    || die "sshd n'applique pas le réglage : vérifie la ligne « Include /etc/ssh/sshd_config.d/*.conf » de /etc/ssh/sshd_config"
  ok "SSH : le compte $HL_USER est limité au script « tour »"
  hl_sshd_filter_warning

  # 9. L'administrateur peut lire le journal (groupe homelab)
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    usermod -aG "$HL_USER" "$SUDO_USER"
    ok "$SUDO_USER peut lire le journal (groupe $HL_USER, à la prochaine connexion)"
  fi

  # 10. Premier test
  say
  say "Test : sudo -u $HL_USER tour status"
  sudo -u "$HL_USER" "$BIN" status || true
  say
  ok "Installation terminée."
  say "Étape suivante, autoriser la clé du serveur :"
  say "  sudo $0 add-key \"\$(ssh <utilisateur>@<serveur> cat /etc/homelab/server-relay.pub)\""
}

do_add_key() { # do_add_key "CLÉ PUBLIQUE"
  local key=$1 fp tmp blob opts auth="$HL_HOME/.ssh/authorized_keys"
  local re='^(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-nistp256|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+={0,3}( [A-Za-z0-9@._-]{1,64})?$'
  id "$HL_USER" >/dev/null 2>&1 || die "installe d'abord : sudo $0"
  hl_load_conf "$CONF" || die "configuration illisible : $CONF"
  key=$(printf '%s' "$key" | tr -d '\r\n')
  [[ $key =~ $re ]] || die "clé publique invalide (attendu : « ssh-ed25519 AAAA… commentaire »)"
  tmp=$(mktemp)
  printf '%s\n' "$key" > "$tmp"
  if ! fp=$(ssh-keygen -l -f "$tmp" 2>/dev/null); then rm -f "$tmp"; die "clé publique illisible"; fi
  rm -f "$tmp"
  [ ! -L "$auth" ] || die "$auth est un lien : arrêt"
  blob=$(printf '%s' "$key" | cut -d' ' -f2)
  if grep -qF -- "$blob" "$auth" 2>/dev/null; then ok "clé déjà autorisée : $fp"; return 0; fi
  opts="restrict,command=\"$BIN\""
  if [ -n "${TOWER_KEY_FROM:-}" ]; then
    hl_valid_from "$TOWER_KEY_FROM" || die "TOWER_KEY_FROM invalide"
    opts+=",from=\"$TOWER_KEY_FROM\""
  fi
  # Écrit avec les droits du compte homelab, jamais en root dans son dossier.
  printf '%s %s\n' "$opts" "$key" | sudo -u "$HL_USER" sh -c 'umask 077; cat >> "$1"' sh "$auth" \
    || die "écriture impossible dans $auth"
  ok "clé autorisée : $fp"
}

do_uninstall() {
  systemctl disable --now homelab-autooff.timer 2>/dev/null || true
  rm -f "$UNITDIR/homelab-autooff.service" "$UNITDIR/homelab-autooff.timer"
  systemctl daemon-reload
  rm -f "$BIN" "$SUDOERS" "$LIBDIR/tour-root" "$LIBDIR/homelab-autooff"
  [ -e /usr/local/bin/homelab ] || rm -rf "$LIBDIR"
  if [ -f "$SSHD_DROPIN" ]; then
    rm -f "$SSHD_DROPIN"
    reload_ssh || true
  fi
  ok "scripts, minuteur, règle sudo et réglage SSH retirés"
  say "Conservés : $CONF, $LOGDIR, $ROOT_STATE, le compte $HL_USER et ses clés."
  say "Pour tout effacer : sudo userdel -r $HL_USER; sudo groupdel $HL_USER; sudo rm -rf $LOGDIR $ROOT_STATE /etc/homelab"
}

case "${1:-install}" in
  install)   do_install ;;
  add-key)   [ "$#" -eq 2 ] || die "usage : $0 add-key \"ssh-ed25519 AAAA… commentaire\""
             do_add_key "$2" ;;
  uninstall) do_uninstall ;;
  *)         die "usage : $0 [install | add-key \"CLÉ\" | uninstall]" ;;
esac
