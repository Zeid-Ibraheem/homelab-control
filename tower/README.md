# tower/

Pilotage de la **tour allumée à la demande** (phases 2 et 4) : un script appelé par le serveur, l'extinction automatique, et la santé de la tour.

## Contenu

| Fichier | Installé dans | Rôle |
|---|---|---|
| `tour` | `/usr/local/bin/tour` | Script lancé par la clé du serveur : liste fermée d'actions, réponses en JSON, journal |
| `tour-root` | `/usr/local/lib/homelab/tour-root` | Les seules actions root : éteindre, redémarrer, lire la santé des disques et les journaux de sécurité, redémarrer un service autorisé ; permises par `sudo` avec des arguments fixes |
| `homelab-autooff` | `/usr/local/lib/homelab/homelab-autooff` | Vérifie l'échéance et éteint la tour |
| `homelab-autooff.service` et `.timer` | `/etc/systemd/system/` | Lancent la vérification chaque minute |
| `sshd-homelab-tower.conf` | `/etc/ssh/sshd_config.d/50-homelab-tower.conf` | Le compte `homelab` de la tour ne peut lancer que le script |
| `install.sh` | | Installation, ajout de la clé du serveur, désinstallation |

La bibliothèque commune vient de [`common/lib.sh`](../common/lib.sh).

## L'extinction automatique

| Règle | Valeur par défaut |
|---|---|
| Allumée **à la main** (bouton, retour du courant…) : échéance = démarrage + `AUTO_OFF_DEFAULT_HOURS` | 8 h |
| Allumée **par le serveur** (réveil par le réseau, ou redémarrage demandé à distance) : échéance = démarrage + `AUTO_OFF_WAKE_HOURS` | 4 h |
| « Prolonger » repousse l'échéance affichée de la durée choisie (`extend-min`), ou de `AUTO_OFF_EXTEND_HOURS` sans durée | 2 h |
| « Éteindre dans N minutes » fixe l'échéance à maintenant + N minutes, et annule « ne pas éteindre » | |
| « Ne pas éteindre » repousse jusqu'au plafond ; l'annuler ramène l'échéance d'avant | |
| Plafond : aucune demande ne dépasse démarrage + `AUTO_OFF_MAX_HOURS` | 8 h |

Comment la tour sait qui l'a allumée : après avoir envoyé le paquet de réveil, le serveur attend qu'elle réponde (9 minutes au plus) et le lui signale (`woke-by-server`), dans ses 15 premières minutes. Un redémarrage demandé à distance est noté juste avant ; le démarrage qui suit dans les 5 minutes compte aussi comme « par le serveur ». Tout autre démarrage compte comme « à la main ».

Avec un plafond de 8 h, une tâche plus longue doit être protégée (voir plus bas) : sinon, la tour s'éteint au plafond, même si on a prolongé.

À l'échéance, la tour ne s'éteint **pas** si elle est utilisée. L'extinction est repoussée, puis a lieu un certain délai après la dernière fois où elle était utilisée (vérifié chaque minute) :

| La tour est utilisée si… | Extinction, après la dernière utilisation vue |
|---|---|
| une session graphique locale est ouverte et **déverrouillée** | `AUTO_OFF_SESSION_GRACE_MIN` (30 min) |
| une mise à jour `pacman` est en cours | 10 min |
| un programme bloque l'extinction avec `systemd-inhibit` (voir plus bas) | 10 min |

- La vérification tourne **sur la tour**, chaque minute : elle marche même si le serveur ou le téléphone sont hors ligne.
- Ces reports sont les seuls à dépasser le plafond : la tour ne s'éteint jamais sous tes yeux, ni au milieu d'une mise à jour.
- Chaque démarrage remet tout à zéro : les demandes d'un démarrage précédent sont ignorées.
- Événements dans le journal système : `journalctl -t homelab-autooff`.

### Protéger une tâche longue

Pour qu'une tâche (sauvegarde, calcul, agent…) ne soit jamais coupée par l'extinction automatique, on la lance avec le mécanisme standard de systemd :

```bash
systemd-inhibit --what=shutdown --why="sauvegarde" rsync -a ~/projets /mnt/sauvegarde/
```

Tant que la commande tourne, l'extinction automatique attend ; elle reprend 10 minutes après la fin. Le bouton « Éteindre » reste prioritaire : c'est une demande explicite. Voir les verrous en cours : `systemd-inhibit --list`.

Depuis un terminal ouvert sur le bureau, aucun mot de passe n'est demandé. En SSH, le système refuse ce verrou à un compte ordinaire : il faut passer par `sudo`, la commande gardant ton compte :

```bash
sudo systemd-inhibit --what=shutdown --why="sauvegarde" sudo -u "$USER" rsync -a ~/projets /mnt/sauvegarde/
```

## Les protections

1. **Compte dédié** `homelab` : sans mot de passe ni droits d'administrateur.
2. **La clé du serveur** est enregistrée avec `restrict,command="…",from="…"` : uniquement depuis le serveur (câble et VPN), sans terminal ni tunnel.
3. **SSH impose le script** à ce compte (`ForceCommand`).
4. **Le script** compare la commande reçue à une liste fermée et vérifie chaque argument.
5. **`sudo`** n'autorise que `tour-root poweroff`, `tour-root reboot`, `tour-root health` (lecture seule), et `tour-root restart NOM` pour chaque service de `TOWER_RESTARTABLE`, un par un.
6. **Root n'écrit jamais dans un dossier du compte `homelab`** : il lit ses demandes (« prolonger », « ne pas éteindre »…), en vérifie les valeurs, et garde son propre état dans `/var/lib/homelab-autooff`. Le plafond est appliqué par root, quoi que contiennent les demandes.

## Installation

Prérequis : `/etc/ssh/sshd_config` doit contenir la ligne `Include /etc/ssh/sshd_config.d/*.conf` (présente par défaut sur Arch récent ; l'installation vérifie et s'arrête sinon).

Sur la tour, depuis une copie du dépôt :

```bash
sudo tower/install.sh       # 1er lancement : crée /etc/homelab/homelab.conf
sudoedit /etc/homelab/homelab.conf    # TOWER_KEY_FROM et la partie « Extinction automatique »
sudo tower/install.sh       # installe, active le minuteur, lance un premier test
```

L'installation vérifie aussi que `sudo` lit bien `/etc/sudoers.d`, et prévient si SSH n'accepte qu'une liste de comptes (`AllowUsers`…) : `homelab` doit alors y être ajouté.

Puis autoriser la clé du serveur, publiée par `server/install.sh` :

```bash
sudo tower/install.sh add-key "$(ssh utilisateur@serveur cat /etc/homelab/server-relay.pub)"
```

Si un pare-feu est actif sur la tour, il doit laisser entrer SSH (port 22) depuis l'adresse du serveur sur le câble. Sur Arch, SSH n'est pas lancé par défaut : `sudo systemctl enable --now sshd`.

Pour le terminal de l'application (clé séparée, accès complet à **ton** compte), l'application affiche la commande ; elle se lance avec `sudo` depuis ton compte, dans le dossier du dépôt :

```bash
sudo tower/install.sh add-terminal-key "ssh-ed25519 AAAA… homelab-terminal"
```

La clé est acceptée seulement depuis les adresses de `TOWER_KEY_FROM` : le terminal de l'application arrive toujours **du serveur** (par le câble ou par le VPN), jamais directement du téléphone. Options `restrict,pty` : un terminal, sans tunnel ni transfert d'agent. Relancer la commande remplace la ligne de cette clé.

### À vérifier une fois sur la tour

**Le verrouillage de l'écran est-il détecté ?** La règle « devant la tour » s'appuie sur l'indicateur de verrouillage de la session. Dans ta session graphique :

```bash
loginctl show-session "$XDG_SESSION_ID" -p LockedHint   # doit afficher « LockedHint=no »
```

Puis verrouille l'écran et, depuis un autre appareil, en SSH sur la tour, relance la commande avec l'identifiant de la session (`loginctl list-sessions`) : elle doit afficher `LockedHint=yes`. Sinon, l'extinction serait repoussée tant que la session reste ouverte.

**La mise en veille automatique est-elle désactivée sur secteur ?** Une tour en veille ne répond plus et ne vérifie plus son échéance. Dans les paramètres du système, partie gestion de l'énergie, onglet « Sur secteur » : désactiver la mise en veille quand l'ordinateur est inactif. La mise en veille de l'**écran** et son verrouillage, eux, peuvent rester.

## Actions

Appelées par le serveur (`ssh hl tower-off`, `ssh hl extend 3`…), ou en local sur la tour avec `sudo -u homelab tour …` :

| Commande | Effet |
|---|---|
| `tour status` | État de la tour et de l'échéance (`auto_off.origin` : `server` ou `button`) |
| `tour health` | Santé : services suivis (`TOWER_SERVICES`), disques (SMART, `TOWER_SMART_DEVICES`), sécurité sur 24 h |
| `tour shutdown` / `tour reboot` | Éteint ou redémarre dans 3 secondes |
| `tour extend [H]` | Repousse l'échéance de H heures (1 à 720), dans la limite du plafond |
| `tour extend-min M` | Repousse l'échéance de M minutes (1 à 43200), dans la limite du plafond |
| `tour off-in N` | Échéance dans N minutes (1 à 10080) |
| `tour hold on` / `tour hold off` | « Ne pas éteindre » jusqu'au plafond, ou annuler |
| `tour restart S` | Redémarre le service S, s'il est dans `TOWER_RESTARTABLE` (voir plus bas) |
| `tour woke-by-server` | Réservé au serveur, juste après un réveil : ce démarrage prend la durée `AUTO_OFF_WAKE_HOURS` |

Dans la réponse à `status` :

- `wifi` : signal Wi-Fi en dBm (`{"iface":…,"signal_dbm":-58}`), ou `null` si la tour n'est pas connectée en Wi-Fi ;
- `session_active` : une session graphique locale est ouverte et déverrouillée ;
- `busy` : ce qui empêche l'extinction en ce moment (mise à jour, programme qui bloque), sinon `null` ;
- `auto_off.deadline` et `auto_off.remaining_s` : heure de l'extinction et secondes restantes ;
- `auto_off.hold` : « ne pas éteindre » est actif ;
- `auto_off.delayed` : l'extinction a été repoussée parce que la tour est utilisée ;
- `auto_off.cap` : le plafond ;
- `auto_off.origin` : `server` (allumée par le serveur) ou `button` (à la main).

## Santé

`tour health` lit, en lecture seule :

- l'état des services de `TOWER_SERVICES` (`systemctl is-active`) et le nombre de services en échec sur la machine ;
- la santé des disques de `TOWER_SMART_DEVICES` (SMART : verdict du disque, température, heures de fonctionnement, usure des SSD, secteurs abîmés), avec `smartctl` et `jq` (`sudo pacman -S --needed smartmontools jq`). Un disque en veille n'est pas réveillé pour la lecture ;
- la sécurité sur 24 h : connexions SSH réussies (hors compte `homelab`, utilisé par les scripts), tentatives refusées, paquets bloqués par le pare-feu ufw.

Les disques et les journaux ne se lisent qu'en root : c'est `tour-root health` qui le fait, seule commande de lecture autorisée par `sudo`. Pour des noms de disques stables d'un démarrage à l'autre, préférer `/dev/disk/by-id/…`.

## Redémarrer un service

Pour qu'un service de la tour puisse être redémarré depuis l'application, l'ajouter à `TOWER_RESTARTABLE` dans `/etc/homelab/homelab.conf` **de la tour**, sans « .service », puis relancer `tower/install.sh` :

```bash
TOWER_SERVICES="sshd tailscaled cups"
TOWER_RESTARTABLE="cups"
```

L'installation ajoute à la règle `sudo` une entrée `tour-root restart cups` par service : `sudo` refuse tout autre nom, et `tour-root` revérifie la liste. Le serveur ne fait que relayer : c'est la configuration de la tour qui décide. Mêmes règles que sur le serveur (voir [`server/README.md`](../server/README.md#redémarrer-un-service)) : noms en minuscules, chiffres et tirets, présents dans `TOWER_SERVICES`, et jamais `ssh`, `sshd`, `tailscaled`, `dbus`, `polkit`, `networking`, `iwd` ni `systemd-…`.

## En cas de problème

| Symptôme | Où regarder |
|---|---|
| La tour ne s'éteint pas à l'échéance | `journalctl -t homelab-autooff` (raison du report), `systemctl list-timers homelab-autooff.timer`, `systemd-inhibit --list` |
| `power_failed` en réponse à « Éteindre » | `sudo -l -U homelab` doit lister `tour-root poweroff` |
| `restart_failed` en réponse à « Redémarrer » un service | `journalctl -u NOM` sur la tour (le service n'a pas redémarré) |
| Le serveur n'arrive pas à joindre la tour | Voir [`server/README.md`](../server/README.md#en-cas-de-problème) |

## Désinstaller

```bash
sudo tower/install.sh uninstall
```

Retire les scripts, le minuteur, la règle `sudo` et le réglage SSH. La configuration, le journal et le compte `homelab` sont conservés : la commande pour les effacer est affichée.
