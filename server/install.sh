#!/usr/bin/env bash
# =============================================================================
# server/install.sh : installe le point d'entrée « homelab » sur le serveur.
#
# À lancer en root, depuis une copie du dépôt sur le serveur :
#   sudo server/install.sh                  installe ou met à jour
#   sudo server/install.sh add-key "CLÉ"    autorise une clé publique « actions »
#                                           (relancer install applique aussi les
#                                           réglages actuels aux clés déjà autorisées)
#   sudo server/install.sh add-terminal-key "CLÉ"
#                                           autorise la clé du terminal de l'application
#                                           sur TON compte (accès complet), depuis les
#                                           adresses de ACTIONS_KEY_FROM seulement
#   sudo server/install.sh uninstall        retire scripts, minuteurs, webcam, règle sudo et réglage SSH
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

# Webcam : serveur vidéo ustreamer géré par le homelab (WEBCAM_DEVICE), qui
# n'écoute que sur 127.0.0.1:WEBCAM_PORT. Vide : rien n'est installé (un autre
# serveur vidéo peut alors être utilisé, avec WEBCAM_PORT seul).
install_webcam() {
  local unit="$UNITDIR/homelab-webcam.service" tmp state lines="" i
  if [ -z "${WEBCAM_DEVICE:-}" ]; then
    if [ -e "$unit" ]; then
      systemctl disable --now homelab-webcam.service 2>/dev/null || true
      rm -f "$unit"
      systemctl daemon-reload
      ok "webcam : serveur vidéo du homelab retiré"
    fi
    return 0
  fi
  if ! command -v ustreamer >/dev/null 2>&1; then
    say "→ Installation de : ustreamer"
    apt-get install -y --no-install-recommends ustreamer
  fi
  # Valeurs vérifiées par check_conf : lettres, chiffres, « / . _ : - x » seulement.
  tmp=$(mktemp)
  sed -e "s|@DEVICE@|$WEBCAM_DEVICE|" -e "s|@PORT@|$WEBCAM_PORT|" \
      -e "s|@RESOLUTION@|${WEBCAM_RESOLUTION:-1280x720}|" -e "s|@FPS@|${WEBCAM_FPS:-5}|" \
      "$HERE/homelab-webcam.service" > "$tmp"
  install -m 644 "$tmp" "$unit"
  rm -f "$tmp"
  systemctl daemon-reload
  # Un souci de webcam ne doit pas arrêter le reste de l'installation : l'état
  # est vérifié juste après.
  systemctl enable homelab-webcam.service || true
  systemctl restart homelab-webcam.service || true
  # Qui écoute sur ce port ? Il faut ustreamer, et seulement sur 127.0.0.1 :
  # sinon le tunnel de l'application mènerait à un autre programme.
  for i in 1 2 3 4 5 6 7 8 9 10; do
    lines=$(ss -Hltnp "sport = :$WEBCAM_PORT" 2>/dev/null || true)
    [ -n "$lines" ] && break
    sleep 0.5
  done
  state=$(systemctl is-active homelab-webcam.service 2>/dev/null || true)
  if [ -n "$lines" ] && { grep -qv '"ustreamer"' <<< "$lines" || awk '{print $4}' <<< "$lines" | grep -qvxF "127.0.0.1:$WEBCAM_PORT"; }; then
    systemctl stop homelab-webcam.service 2>/dev/null || true
    die "le port $WEBCAM_PORT est déjà pris par un autre programme ($(awk '{print $4, $6}' <<< "$lines" | paste -sd ' ' -)) : choisis un autre WEBCAM_PORT"
  fi
  if [ "$state" = "active" ] && [ -n "$lines" ]; then
    ok "webcam : ustreamer en écoute sur 127.0.0.1:$WEBCAM_PORT seulement ($WEBCAM_DEVICE, ${WEBCAM_RESOLUTION:-1280x720}, ${WEBCAM_FPS:-5} images/s)"
  else
    say "  ! le serveur vidéo ne démarre pas ($state) : journalctl -u homelab-webcam -n 20"
  fi
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

# Options d'une clé « actions » : commande forcée, rien d'autre, sauf le tunnel
# vers la webcam si elle est configurée (et seulement vers son port local).
key_options() {
  local o="restrict"
  if hl_in_range "${WEBCAM_PORT:-}" 1 65535; then
    o+=",port-forwarding,permitopen=\"127.0.0.1:$WEBCAM_PORT\""
  fi
  o+=",command=\"$BIN\""
  [ -z "${ACTIONS_KEY_FROM:-}" ] || o+=",from=\"$ACTIONS_KEY_FROM\""
  printf '%s' "$o"
}

KEY_RE='(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-nistp256|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+={0,3}( [A-Za-z0-9@._-]{1,64})?'

# Applique les options actuelles à toutes les clés « actions » déjà autorisées.
# Lecture et écriture avec les droits du compte homelab, jamais en root.
sync_keys() {
  local auth="$HL_HOME/.ssh/authorized_keys" line old new="" opts n=0
  [ -f "$auth" ] && [ ! -L "$auth" ] || return 0
  opts=$(key_options)
  old=$(sudo -u "$HL_USER" cat "$auth") || die "lecture impossible : $auth"
  while IFS= read -r line; do
    if [[ $line == *"command=\"$BIN\""* && $line =~ $KEY_RE$ ]]; then
      line="$opts ${BASH_REMATCH[0]}"
      n=$((n + 1))
    fi
    [ -z "$line" ] || new+="$line"$'\n'
  done <<< "$old"
  if [ "$new" != "$old"$'\n' ] && [ -n "$new" ]; then
    printf '%s' "$new" | sudo -u "$HL_USER" sh -c 'umask 077; cat > "$1.new" && mv -f "$1.new" "$1"' sh "$auth" \
      || die "écriture impossible : $auth"
  fi
  [ "$n" -eq 0 ] || ok "réglages appliqués aux $n clé(s) « actions » déjà autorisée(s)"
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
  local bad=0 u
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
  if [ -n "${WEBCAM_PORT:-}" ] && ! hl_in_range "$WEBCAM_PORT" 1 65535; then
    say "  ✗ WEBCAM_PORT doit être un port (1 à 65535), ou vide"; bad=1
  fi
  if [ -n "${WEBCAM_DEVICE:-}" ]; then
    hl_valid_video "$WEBCAM_DEVICE" \
      || { say "  ✗ WEBCAM_DEVICE : « $WEBCAM_DEVICE » n'est pas une caméra (/dev/video0, /dev/v4l/by-id/…)"; bad=1; }
    # Le compte du serveur vidéo n'a aucun droit : pas de port réservé (< 1024).
    hl_in_range "${WEBCAM_PORT:-}" 1024 65535 \
      || { say "  ✗ WEBCAM_DEVICE est rempli : il faut aussi WEBCAM_PORT, entre 1024 et 65535 (par exemple 8080)"; bad=1; }
    hl_valid_resolution "${WEBCAM_RESOLUTION:-1280x720}" \
      || { say "  ✗ WEBCAM_RESOLUTION : largeur x hauteur, par exemple 1280x720"; bad=1; }
    hl_in_range "${WEBCAM_FPS:-5}" 1 60 || { say "  ✗ WEBCAM_FPS doit être un nombre entre 1 et 60"; bad=1; }
  fi
  for u in ${SERVER_SMART_DEVICES:-}; do
    hl_valid_disk "$u" || { say "  ✗ SERVER_SMART_DEVICES : « $u » n'est pas un disque (/dev/nvme0n1, /dev/sda, /dev/disk/by-id/…)"; bad=1; }
  done
  for u in ${SERVER_SERVICES:-}; do
    hl_valid_unit "$u" || { say "  ✗ SERVER_SERVICES : « $u » n'est pas un nom de service"; bad=1; }
  done
  check_restartable SERVER_RESTARTABLE "${SERVER_RESTARTABLE:-}" "${SERVER_SERVICES:-}" || bad=1
  [ "$bad" -eq 0 ] || die "corrige $CONF (sudoedit $CONF), puis relance."
  [ -e "/sys/class/net/$LINK_INTERFACE" ] || say "  ! l'interface $LINK_INTERFACE n'est pas branchée pour l'instant"
  if [ -n "${WEBCAM_DEVICE:-}" ] && [ ! -e "$WEBCAM_DEVICE" ]; then
    say "  ! $WEBCAM_DEVICE n'existe pas pour l'instant (caméra débranchée ?) : le serveur vidéo l'attendra"
    say "    caméras vues maintenant : $(ls /dev/v4l/by-id/ 2>/dev/null | grep -- '-index0$' | paste -sd ' ' - || true)"
  fi
  ok "configuration valide"
}

do_install() {
  local missing=() tmp u

  # 1. Dépendances
  command -v etherwake >/dev/null 2>&1 || missing+=(etherwake)
  command -v ping >/dev/null 2>&1      || missing+=(iputils-ping)
  command -v flock >/dev/null 2>&1     || missing+=(util-linux)
  command -v sudo >/dev/null 2>&1      || missing+=(sudo)
  command -v ssh >/dev/null 2>&1       || missing+=(openssh-client)
  command -v smartctl >/dev/null 2>&1  || missing+=(smartmontools)
  command -v jq >/dev/null 2>&1        || missing+=(jq)
  command -v ss >/dev/null 2>&1        || missing+=(iproute2)
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
  # Dossiers vérifiés un par un : jamais de lien suivi (voir hl_safe_dir).
  hl_safe_dir "$HL_HOME" "$HL_USER" 750 || die "dossier $HL_HOME non sûr"
  hl_safe_dir "$HL_HOME/.ssh" "$HL_USER" 700 || die "dossier $HL_HOME/.ssh non sûr"
  [ ! -L "$HL_HOME/.ssh/authorized_keys" ] || die "$HL_HOME/.ssh/authorized_keys est un lien : arrêt"
  [ -f "$HL_HOME/.ssh/authorized_keys" ] \
    || install -o "$HL_USER" -g "$HL_USER" -m 600 /dev/null "$HL_HOME/.ssh/authorized_keys"
  hl_safe_dir "$HL_HOME/state" "$HL_USER" 750 || die "dossier $HL_HOME/state non sûr"
  hl_safe_dir "$LOGDIR" "$HL_USER" 750 || die "dossier $LOGDIR non sûr"

  # 4. Configuration : lisible par homelab, modifiable par root uniquement
  chown root:"$HL_USER" "$CONF"
  chmod 640 "$CONF"

  # 5. Scripts, propriété de root : le compte homelab ne peut pas les modifier
  install -d -m 755 "$LIBDIR"
  install -m 644 "$REPO/common/lib.sh" "$LIBDIR/lib.sh"
  install -m 755 "$HERE/homelab-root" "$LIBDIR/homelab-root"
  install -m 755 "$HERE/homelab" "$BIN"
  ok "scripts installés"

  # 6. sudo : uniquement « homelab-root wake », « homelab-root health », et le
  #    redémarrage de chaque service autorisé
  tmp=$(mktemp)
  hl_sudoers_line "$HL_USER" "$LIBDIR/homelab-root" "wake health" "${SERVER_RESTARTABLE:-}" > "$tmp"
  if ! visudo -cf "$tmp" >/dev/null; then rm -f "$tmp"; die "règle sudo invalide"; fi
  install -m 440 "$tmp" "$SUDOERS"
  rm -f "$tmp"
  tmp=$(sudo -l -U "$HL_USER" 2>/dev/null || true)
  grep -qF "$LIBDIR/homelab-root wake" <<< "$tmp" \
    || die "sudo ne lit pas $SUDOERS : vérifie la ligne « @includedir /etc/sudoers.d » de /etc/sudoers (sudo visudo)"
  for u in ${SERVER_RESTARTABLE:-}; do
    grep -qF "$LIBDIR/homelab-root restart $u" <<< "$tmp" || die "règle sudo incomplète pour « $u »"
  done
  ok "règle sudo limitée à « homelab-root wake » et « homelab-root health »"
  [ -z "${SERVER_RESTARTABLE:-}" ] || ok "services redémarrables depuis l'application : $SERVER_RESTARTABLE"

  # 7. SSH : le compte homelab ne peut lancer que le script ; avec une webcam,
  #    il peut aussi ouvrir un tunnel, vers son seul port local.
  install -d -m 755 "$(dirname "$SSHD_DROPIN")"
  tmp=$(mktemp)
  if hl_in_range "${WEBCAM_PORT:-}" 1 65535; then
    sed "s|^    AllowTcpForwarding no\$|    AllowTcpForwarding local\n    PermitOpen 127.0.0.1:$WEBCAM_PORT|" \
      "$HERE/sshd-homelab.conf" > "$tmp"
  else
    cp "$HERE/sshd-homelab.conf" "$tmp"
  fi
  install -m 644 "$tmp" "$SSHD_DROPIN"
  rm -f "$tmp"
  if ! reload_ssh; then
    rm -f "$SSHD_DROPIN"
    reload_ssh || true
    die "configuration SSH refusée : le réglage a été retiré, rien n'a changé côté SSH"
  fi
  hl_forcecommand_ok "$BIN" \
    || die "sshd n'applique pas le réglage : vérifie que /etc/ssh/sshd_config contient « Include /etc/ssh/sshd_config.d/*.conf » au début"
  ok "SSH : le compte $HL_USER est limité au script"
  if hl_in_range "${WEBCAM_PORT:-}" 1 65535; then
    tmp=$(sshd -T -C user=homelab,host=localhost,addr=127.0.0.1 2>/dev/null | grep -i '^permitopen ' || true)
    [ "${tmp,,}" = "permitopen 127.0.0.1:$WEBCAM_PORT" ] \
      || die "sshd n'applique pas la limite du tunnel vers la webcam (PermitOpen)"
    ok "webcam : tunnel autorisé vers 127.0.0.1:$WEBCAM_PORT seulement"
  fi
  hl_sshd_filter_warning
  sync_keys

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

  # 9 bis. Serveur vidéo de la webcam (WEBCAM_DEVICE), ou rien si la valeur est vide
  install_webcam

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
  say "Clé du terminal du téléphone : sudo $0 add-terminal-key \"ssh-ed25519 AAAA… homelab-terminal\""
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
  if [ -n "${ACTIONS_KEY_FROM:-}" ]; then
    hl_valid_from "$ACTIONS_KEY_FROM" || die "ACTIONS_KEY_FROM invalide"
  fi
  if [ -n "${WEBCAM_PORT:-}" ]; then
    hl_in_range "$WEBCAM_PORT" 1 65535 || die "WEBCAM_PORT invalide"
  fi
  tmp=$(mktemp)
  printf '%s\n' "$key" > "$tmp"
  if ! fp=$(ssh-keygen -l -f "$tmp" 2>/dev/null); then rm -f "$tmp"; die "clé publique illisible"; fi
  rm -f "$tmp"
  [ ! -L "$auth" ] || die "$auth est un lien : arrêt"
  blob=$(printf '%s' "$key" | cut -d' ' -f2)
  if grep -qF -- "$blob" "$auth" 2>/dev/null; then ok "clé déjà autorisée : $fp"; return 0; fi
  opts=$(key_options)
  # Écrit avec les droits du compte homelab, jamais en root dans son dossier.
  printf '%s %s\n' "$opts" "$key" | sudo -u "$HL_USER" sh -c 'umask 077; cat >> "$1"' sh "$auth" \
    || die "écriture impossible dans $auth"
  ok "clé autorisée : $fp"
  say "Test depuis le téléphone : ssh -i ~/.ssh/homelab_actions $HL_USER@<serveur> status"
}

do_uninstall() {
  if [ -e "$UNITDIR/homelab-wake.timer" ]; then
    systemctl disable --now homelab-wake.timer 2>/dev/null || true
    rm -f "$UNITDIR/homelab-wake.service" "$UNITDIR/homelab-wake.timer"
    systemctl daemon-reload
  fi
  if [ -e "$UNITDIR/homelab-webcam.service" ]; then
    systemctl disable --now homelab-webcam.service 2>/dev/null || true
    rm -f "$UNITDIR/homelab-webcam.service"
    systemctl daemon-reload
  fi
  rm -f "$BIN" "$SUDOERS" "$LIBDIR/homelab-root"
  [ -e /usr/local/bin/tour ] || rm -rf "$LIBDIR"     # tour installée ici aussi : on garde lib.sh
  if [ -f "$SSHD_DROPIN" ]; then
    rm -f "$SSHD_DROPIN"
    reload_ssh || true
  fi
  ok "scripts, minuteurs, serveur vidéo, règle sudo et réglage SSH retirés"
  say "Conservés : $CONF, $LOGDIR, le compte $HL_USER et ses clés."
  say "Pour tout effacer : sudo userdel -r $HL_USER; sudo groupdel $HL_USER; sudo rm -rf $LOGDIR /etc/homelab"
}

case "${1:-install}" in
  install)   do_install ;;
  add-key)   [ "$#" -eq 2 ] || die "usage : $0 add-key \"ssh-ed25519 AAAA… commentaire\""
             do_add_key "$2" ;;
  add-terminal-key)
             # Le téléphone arrive des mêmes adresses que pour la clé « actions ».
             # Tunnels permis : le terminal de la tour passe par ce serveur.
             [ "$#" -eq 2 ] || die "usage : sudo $0 add-terminal-key \"ssh-ed25519 AAAA… homelab-terminal\""
             hl_load_conf "$CONF" || die "configuration illisible : $CONF"
             hl_add_terminal_key "$2" "${ACTIONS_KEY_FROM:-}" "restrict,pty,port-forwarding" || exit 1 ;;
  uninstall) do_uninstall ;;
  *)         die "usage : $0 [install | add-key \"CLÉ\" | add-terminal-key \"CLÉ\" | uninstall]" ;;
esac
