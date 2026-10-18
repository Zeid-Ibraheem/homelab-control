#!/usr/bin/env bash
# =============================================================================
# server/install.sh : installe le point d'entrée « homelab » sur le serveur.
#
# À lancer en root, depuis une copie du dépôt sur le serveur :
#   sudo server/install.sh                  installe ou met à jour
#   sudo server/install.sh add-key "CLÉ"    autorise une clé publique « actions »
#   sudo server/install.sh uninstall        retire scripts, minuteur, règle sudo et réglage SSH
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
BIN=/usr/local/bin/homelab
LIBDIR=/usr/local/lib/homelab
SUDOERS=/etc/sudoers.d/homelab
SSHD_DROPIN=/etc/ssh/sshd_config.d/50-homelab.conf
LOGDIR=/var/log/homelab
UNITDIR=/etc/systemd/system

say() { printf '%s\n' "$*"; }
ok()  { printf '✓ %s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "À lancer avec sudo."
# shellcheck source=../common/lib.sh
. "$REPO/common/lib.sh"

reload_ssh() {
  sshd -t || return 1
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
}

# Allumage programmé : WAKE_SCHEDULE contient une ou plusieurs dates au format
# systemd (OnCalendar), séparées par « ; ». Affiche une date valide par ligne.
wake_specs() {
  local spec specs=()
  [ -n "${WAKE_SCHEDULE:-}" ] || return 0
  IFS=';' read -r -a specs <<< "$WAKE_SCHEDULE"
  for spec in "${specs[@]}"; do
    spec=${spec#"${spec%%[![:space:]]*}"}
    spec=${spec%"${spec##*[![:space:]]}"}
    [ -n "$spec" ] || continue
    if ! [[ $spec =~ ^[A-Za-z0-9\ ,:*./~-]{1,80}$ ]] || ! systemd-analyze calendar "$spec" >/dev/null 2>&1; then
      say "  ✗ WAKE_SCHEDULE : « $spec » n'est pas une date systemd valide (exemple : Mon..Fri *-*-* 07:45:00)" >&2
      return 1
    fi
    printf '%s\n' "$spec"
  done
}

install_wake_timer() {
  local svc="$UNITDIR/homelab-wake.service" tmr="$UNITDIR/homelab-wake.timer" tmp spec
  if [ -z "${WAKE_SCHEDULE:-}" ]; then
    if [ -e "$tmr" ]; then
      systemctl disable --now homelab-wake.timer 2>/dev/null || true
      rm -f "$svc" "$tmr"
      systemctl daemon-reload
      ok "allumage programmé désactivé"
    fi
    return 0
  fi
  printf '[Unit]\nDescription=Allumage programmé de la tour (homelab)\n\n[Service]\nType=oneshot\nUser=%s\nExecStart=%s wake\n' \
    "$HL_USER" "$BIN" > "$svc"
  tmp=$(mktemp)
  {
    printf '[Unit]\nDescription=Allumage programmé de la tour (homelab)\n\n[Timer]\n'
    while IFS= read -r spec; do printf 'OnCalendar=%s\n' "$spec"; done < <(wake_specs)
    printf 'AccuracySec=30s\n\n[Install]\nWantedBy=timers.target\n'
  } > "$tmp"
  install -m 644 "$tmp" "$tmr"
  rm -f "$tmp"
  chmod 644 "$svc"
  systemctl daemon-reload
  systemctl enable --now homelab-wake.timer
  systemctl restart homelab-wake.timer
  ok "allumage programmé : $(wake_specs | paste -sd ';' | sed 's/;/ ; /g')"
}

check_conf() {
  local bad=0
  hl_load_conf "$CONF" || die "configuration illisible : $CONF"
  hl_valid_iface "${LINK_INTERFACE:-}" || { say "  ✗ LINK_INTERFACE invalide"; bad=1; }
  hl_valid_mac "${TOWER_MAC:-}"        || { say "  ✗ TOWER_MAC invalide"; bad=1; }
  hl_valid_ipv4 "${LINK_TOWER_IP:-}"   || { say "  ✗ LINK_TOWER_IP invalide"; bad=1; }
  hl_valid_host "${TOWER_HOST:-}"      || { say "  ✗ TOWER_HOST invalide"; bad=1; }
  case "${TOWER_MAC:-}" in
    [Aa][Aa]:[Bb][Bb]:[Cc][Cc]:[Dd][Dd]:[Ee][Ee]:[Ff][Ff])
      say "  ✗ TOWER_MAC contient encore la valeur d'exemple"; bad=1 ;;
  esac
  case "${ACTION_LOG:-$LOGDIR/actions.log}" in
    "$LOGDIR"/*) ;;
    *) say "  ✗ ACTION_LOG doit se trouver dans $LOGDIR/"; bad=1 ;;
  esac
  if [ -n "${ACTIONS_KEY_FROM:-}" ] && ! hl_valid_from "$ACTIONS_KEY_FROM"; then
    say "  ✗ ACTIONS_KEY_FROM invalide"; bad=1
  fi
  wake_specs >/dev/null || bad=1
  [ "$bad" -eq 0 ] || die "corrige $CONF (sudoedit $CONF), puis relance."
  [ -e "/sys/class/net/$LINK_INTERFACE" ] || say "  ! l'interface $LINK_INTERFACE n'est pas branchée pour l'instant"
  ok "configuration valide"
}

do_install() {
  local missing=() tmp

  # 1. Dépendances
  command -v etherwake >/dev/null 2>&1 || missing+=(etherwake)
  command -v ping >/dev/null 2>&1      || missing+=(iputils-ping)
  command -v flock >/dev/null 2>&1     || missing+=(util-linux)
  command -v sudo >/dev/null 2>&1      || missing+=(sudo)
  command -v ssh >/dev/null 2>&1       || missing+=(openssh-client)
  if [ "${#missing[@]}" -gt 0 ]; then
    say "→ Installation de : ${missing[*]}"
    apt-get install -y --no-install-recommends "${missing[@]}"
  fi
  ok "dépendances présentes"

  # 2. Configuration (créée à partir du modèle au premier lancement)
  if [ ! -f "$CONF" ]; then
    install -d -m 755 "$(dirname "$CONF")"
    install -m 640 "$REPO/config/homelab.conf.example" "$CONF"
    say "→ Configuration créée : $CONF"
    say "  Remplace les valeurs d'exemple : sudoedit $CONF"
    say "  Puis relance : sudo $0"
    exit 0
  fi
  check_conf

  # 3. Compte dédié, sans mot de passe ni droits d'administrateur
  if ! id "$HL_USER" >/dev/null 2>&1; then
    if getent group "$HL_USER" >/dev/null; then   # groupe resté d'une ancienne installation
      useradd --system --gid "$HL_USER" --create-home --home-dir "$HL_HOME" --shell /bin/bash "$HL_USER"
    else
      useradd --system --user-group --create-home --home-dir "$HL_HOME" --shell /bin/bash "$HL_USER"
    fi
    ok "compte $HL_USER créé"
  fi
  # Aucun mot de passe utilisable (« * ») : connexion par clé uniquement.
  usermod -p '*' "$HL_USER"
  chmod 750 "$HL_HOME"
  install -d -o "$HL_USER" -g "$HL_USER" -m 700 "$HL_HOME/.ssh"
  [ -f "$HL_HOME/.ssh/authorized_keys" ] \
    || install -o "$HL_USER" -g "$HL_USER" -m 600 /dev/null "$HL_HOME/.ssh/authorized_keys"
  install -d -o "$HL_USER" -g "$HL_USER" -m 750 "$HL_HOME/state"
  install -d -o "$HL_USER" -g "$HL_USER" -m 750 "$LOGDIR"

  # 4. Configuration : lisible par homelab, modifiable par root uniquement
  chown root:"$HL_USER" "$CONF"
  chmod 640 "$CONF"

  # 5. Scripts, propriété de root : le compte homelab ne peut pas les modifier
  install -d -m 755 "$LIBDIR"
  install -m 644 "$REPO/common/lib.sh" "$LIBDIR/lib.sh"
  install -m 755 "$HERE/homelab-root" "$LIBDIR/homelab-root"
  install -m 755 "$HERE/homelab" "$BIN"
  ok "scripts installés"

  # 6. sudo : uniquement « homelab-root wake », rien d'autre
  tmp=$(mktemp)
  printf '%s ALL=(root) NOPASSWD: %s wake\n' "$HL_USER" "$LIBDIR/homelab-root" > "$tmp"
  if ! visudo -cf "$tmp" >/dev/null; then rm -f "$tmp"; die "règle sudo invalide"; fi
  install -m 440 "$tmp" "$SUDOERS"
  rm -f "$tmp"
  tmp=$(sudo -l -U "$HL_USER" 2>/dev/null || true)
  grep -qF "$LIBDIR/homelab-root wake" <<< "$tmp" \
    || die "sudo ne lit pas $SUDOERS : vérifie la ligne « @includedir /etc/sudoers.d » de /etc/sudoers (sudo visudo)"
  ok "règle sudo limitée à « homelab-root wake »"

  # 7. SSH : le compte homelab ne peut lancer que le script
  install -d -m 755 "$(dirname "$SSHD_DROPIN")"
  install -m 644 "$HERE/sshd-homelab.conf" "$SSHD_DROPIN"
  if ! reload_ssh; then
    rm -f "$SSHD_DROPIN"
    reload_ssh || true
    die "configuration SSH refusée : le réglage a été retiré, rien n'a changé côté SSH"
  fi
  hl_forcecommand_ok "$BIN" \
    || die "sshd n'applique pas le réglage : vérifie que /etc/ssh/sshd_config contient « Include /etc/ssh/sshd_config.d/*.conf » au début"
  ok "SSH : le compte $HL_USER est limité au script"
  hl_sshd_filter_warning

  # 8. Clé du serveur vers la tour, restreinte côté tour au script « tour »
  if [ ! -f "$HL_HOME/.ssh/id_tower" ]; then
    sudo -u "$HL_USER" ssh-keygen -q -t ed25519 -N "" -C "homelab-serveur" -f "$HL_HOME/.ssh/id_tower" \
      || die "création de la clé vers la tour impossible (paquet openssh-client installé ?)"
    ok "clé du serveur vers la tour créée"
  fi
  # Copie publique, lue en tant que homelab (jamais en root dans son dossier).
  tmp=$(mktemp)
  if sudo -u "$HL_USER" cat "$HL_HOME/.ssh/id_tower.pub" > "$tmp" 2>/dev/null \
     && [[ $(cat "$tmp") =~ ^ssh-ed25519\ [A-Za-z0-9+/]+={0,3}\ homelab-serveur$ ]]; then
    install -m 644 "$tmp" "$(dirname "$CONF")/server-relay.pub"
    ok "clé publique pour la tour : $(dirname "$CONF")/server-relay.pub"
  else
    say "  ! clé publique du serveur illisible : relance l'installation"
  fi
  rm -f "$tmp"

  # 9. Allumage programmé (WAKE_SCHEDULE), ou rien si la valeur est vide
  install_wake_timer

  # 10. L'administrateur peut lire le journal (groupe homelab)
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    usermod -aG "$HL_USER" "$SUDO_USER"
    ok "$SUDO_USER peut lire le journal (groupe $HL_USER, à la prochaine connexion)"
  fi

  # 11. Premier test
  say
  say "Test : sudo -u $HL_USER homelab status"
  sudo -u "$HL_USER" "$BIN" status || true
  say
  ok "Installation terminée."
  say "Clé « actions » du téléphone : sudo $0 add-key \"ssh-ed25519 AAAA… commentaire\""
  say "Pilotage de la tour : installer tower/install.sh sur la tour, puis y autoriser"
  say "  la clé publique du serveur ($(dirname "$CONF")/server-relay.pub)."
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
  blob=$(printf '%s' "$key" | cut -d' ' -f2)
  if grep -qF -- "$blob" "$auth" 2>/dev/null; then ok "clé déjà autorisée : $fp"; return 0; fi
  opts="restrict,command=\"$BIN\""
  if [ -n "${ACTIONS_KEY_FROM:-}" ]; then
    hl_valid_from "$ACTIONS_KEY_FROM" || die "ACTIONS_KEY_FROM invalide"
    opts+=",from=\"$ACTIONS_KEY_FROM\""
  fi
  printf '%s %s\n' "$opts" "$key" >> "$auth"
  chown "$HL_USER:$HL_USER" "$auth"
  chmod 600 "$auth"
  ok "clé autorisée : $fp"
  say "Test depuis le téléphone : ssh -i ~/.ssh/homelab_actions $HL_USER@<serveur> status"
}

do_uninstall() {
  if [ -e "$UNITDIR/homelab-wake.timer" ]; then
    systemctl disable --now homelab-wake.timer 2>/dev/null || true
    rm -f "$UNITDIR/homelab-wake.service" "$UNITDIR/homelab-wake.timer"
    systemctl daemon-reload
  fi
  rm -f "$BIN" "$SUDOERS" "$LIBDIR/homelab-root"
  [ -e /usr/local/bin/tour ] || rm -rf "$LIBDIR"     # tour installée ici aussi : on garde lib.sh
  if [ -f "$SSHD_DROPIN" ]; then
    rm -f "$SSHD_DROPIN"
    reload_ssh || true
  fi
  ok "scripts, minuteur, règle sudo et réglage SSH retirés"
  say "Conservés : $CONF, $LOGDIR, le compte $HL_USER et ses clés."
  say "Pour tout effacer : sudo userdel -r $HL_USER; sudo groupdel $HL_USER; sudo rm -rf $LOGDIR /etc/homelab"
}

case "${1:-install}" in
  install)   do_install ;;
  add-key)   [ "$#" -eq 2 ] || die "usage : $0 add-key \"ssh-ed25519 AAAA… commentaire\""
             do_add_key "$2" ;;
  uninstall) do_uninstall ;;
  *)         die "usage : $0 [install | add-key \"CLÉ\" | uninstall]" ;;
esac
