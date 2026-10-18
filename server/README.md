# server/

Point d'entrée du téléphone sur le **serveur toujours allumé** (phases 1 et 2) : il répond lui-même, ou relaie vers la tour.

## Contenu

| Fichier | Installé dans | Rôle |
|---|---|---|
| `homelab` | `/usr/local/bin/homelab` | Script lancé par la clé « actions » : liste fermée d'actions, réponses en JSON, journal |
| `homelab-root` | `/usr/local/lib/homelab/homelab-root` | La seule action qui demande les droits root (le réveil), autorisée par `sudo` avec un argument fixe |
| `sshd-homelab.conf` | `/etc/ssh/sshd_config.d/50-homelab.conf` | Le compte `homelab` ne peut lancer que le script |
| `install.sh` | | Installation, ajout d'une clé, désinstallation |

La bibliothèque commune ([`common/lib.sh`](../common/lib.sh)) est installée dans `/usr/local/lib/homelab/lib.sh`.

Pour piloter la tour, le serveur utilise sa **propre clé**, créée par l'installation (`/var/lib/homelab/.ssh/id_tower`), dont la partie publique est copiée dans `/etc/homelab/server-relay.pub`. Sur la tour, elle ne peut lancer que le script `tour` (voir [`tower/README.md`](../tower/README.md)).

Le serveur joint la tour par le câble direct s'il répond, sinon par le VPN, toujours en IPv4. Si la connexion SSH échoue sur le câble, il réessaie par le VPN ; il ne réessaie **jamais** quand la commande a pu être lancée, pour qu'une action ne soit jamais exécutée deux fois. L'empreinte de la tour est enregistrée à la toute première connexion (`/var/lib/homelab/.ssh/known_hosts_tower`) et vérifiée ensuite par les deux chemins.

## Les protections, de l'extérieur vers l'intérieur

1. **Compte dédié** `homelab` : sans mot de passe, sans droits d'administrateur.
2. **La clé « actions »** est enregistrée avec `restrict,command="…",from="…"` : pas de terminal, pas de tunnel, uniquement depuis le VPN.
3. **SSH impose le script** à ce compte (`ForceCommand`), même si une clé était ajoutée sans restriction.
4. **Le script** n'exécute jamais le texte reçu : il le compare à une liste fermée d'actions, n'accepte que des minuscules, chiffres, espaces et tirets (64 caractères au plus) et vérifie chaque argument.
5. **`sudo`** n'autorise qu'une seule commande, avec un argument fixe : `homelab-root wake`.
6. **La configuration est lue sans être exécutée**, et chaque valeur est validée avant d'être utilisée dans une commande.

## Installation

Sur la machine où se trouve le dépôt, copier vers le serveur **uniquement les fichiers commités** (donc déjà vérifiés par les verrous) :

```bash
git archive HEAD | ssh utilisateur@serveur 'rm -rf ~/hl-new && mkdir ~/hl-new && tar -x -C ~/hl-new && rm -rf ~/homelab-control && mv ~/hl-new ~/homelab-control'
```

L'ancienne copie n'est remplacée que si l'archive est arrivée en entier. Coller une commande à la fois : quand plusieurs lignes sont collées d'un coup, les suivantes peuvent être lues par la commande en cours (par exemple une demande de mot de passe).

Sur le serveur :

```bash
sudo ~/homelab-control/server/install.sh   # 1er lancement : crée /etc/homelab/homelab.conf
sudoedit /etc/homelab/homelab.conf         # remplacer les valeurs d'exemple
sudo ~/homelab-control/server/install.sh   # installe et lance un premier test
```

L'installation vérifie que SSH applique vraiment le réglage (`sshd -T`) et que `sudo` lit `/etc/sudoers.d`, et prévient si SSH n'accepte qu'une liste de comptes (`AllowUsers`…) : `homelab` doit alors y être ajouté. Pour une mise à jour, recopier le dépôt et relancer la même commande.

Puis autoriser la clé « actions » du téléphone (voir ci-dessous).

## Clé « actions » du téléphone

L'**application** crée sa propre clé et affiche la commande `add-key` à lancer (voir [`app/README.md`](../app/README.md)). Pour un **terminal** sur le téléphone (Termux…), créer une autre clé, dédiée : chaque appareil a la sienne, et chacune se retire séparément.

Dans le terminal du téléphone :

```bash
ssh-keygen -t ed25519 -f ~/.ssh/homelab_actions -C telephone-actions
```

L'envoyer sur le serveur, puis l'autoriser :

```bash
cat ~/.ssh/homelab_actions.pub | ssh utilisateur@serveur 'cat > /tmp/actions.pub'
# sur le serveur :
sudo ~/homelab-control/server/install.sh add-key "$(cat /tmp/actions.pub)" && rm /tmp/actions.pub
```

Dans `~/.ssh/config` du téléphone :

```
Host hl
    HostName serveur
    User homelab
    IdentityFile ~/.ssh/homelab_actions
    IdentitiesOnly yes
    AddressFamily inet
```

## Actions

| Commande | Effet |
|---|---|
| `ssh hl status` | État du serveur, du câble et de la tour (avec l'échéance d'extinction si elle est allumée) |
| `ssh hl wake` | Allume la tour : `sent`, `already_on`, `ignored_recent` ou `busy` |
| `ssh hl tower-off` | Éteint la tour (`already_off` si elle l'est déjà) |
| `ssh hl tower-reboot` | Redémarre la tour |
| `ssh hl extend` ou `ssh hl extend 3` | Repousse l'extinction automatique (durée par défaut, ou 3 h), dans la limite du plafond |
| `ssh hl off-in 30` | Extinction automatique dans 30 minutes (1 à 10080) |
| `ssh hl hold on` / `ssh hl hold off` | « Ne pas éteindre » jusqu'au plafond, ou annuler |
| `ssh hl log 10` | Les 10 dernières actions du serveur (1 à 200) |
| `ssh hl actions` | Liste des actions |
| `ssh hl version` | Version du script |

Toute autre commande est refusée (code de sortie 2) et inscrite dans le journal.

Exemple de réponse à `status`, tour allumée, avec des valeurs fictives :

```json
{"ok":true,"api":1,"time":"2026-01-01T12:00:00+01:00",
 "server":{"uptime_s":345600,"load":[0.08,0.12,0.10],"cpu_pct":2.3,"mem_used_pct":21.4,
           "temp_c":41.0,"disk_used_pct":12,"battery_pct":64,"on_ac":true},
 "link":{"present":true,"carrier":true},
 "tower":{"online":true,"via":"link","detail":{"ok":true,"api":1,"time":"…",
          "uptime_s":5400,"boot_time":"2026-01-01T10:30:00+01:00","cpu_pct":3.1,
          "mem_used_pct":18.2,"cpu_temp_c":44.0,"gpu_temp_c":39.0,"disk_used_pct":35,
          "session_active":false,"busy":null,
          "auto_off":{"deadline":"2026-01-01T18:30:00+01:00","remaining_s":23400,
                      "hold":false,"cap":"2026-01-03T10:30:00+01:00","delayed":false}}}}
```

(sur une seule ligne en réalité ; `ssh hl status | jq` pour l'afficher joliment)

- `tower.via` : `link` (le câble), `vpn`, ou `null` si la tour est éteinte.
- `tower.detail` : la réponse du script de la tour (champs expliqués dans [`tower/README.md`](../tower/README.md#actions)), ou `null` si elle ne répond pas encore (par exemple en plein démarrage).

Une action relayée renvoie la réponse de la tour dans `tower`. Erreurs possibles : `tower_offline` (tour éteinte ou injoignable), `relay_failed` (la tour n'a pas répondu correctement), `tower_error` (la tour a refusé ; sa réponse est jointe).

## Allumage programmé

Dans `/etc/homelab/homelab.conf`, `WAKE_SCHEDULE` contient une ou plusieurs dates au format des minuteurs systemd (`OnCalendar`), séparées par `;` :

```bash
WAKE_SCHEDULE="Mon..Fri *-*-* 07:45:00; Sat *-*-* 10:00:00"
```

Puis relancer `sudo ~/homelab-control/server/install.sh` : il vérifie chaque date (`systemd-analyze calendar`), crée le minuteur `homelab-wake.timer` et affiche les dates retenues. À l'heure dite, le serveur lance `homelab wake` avec le compte `homelab`, exactement comme le téléphone (inscrit `timer` dans le journal). Une valeur vide supprime le minuteur.

- Prochains allumages : `systemctl list-timers homelab-wake.timer`
- Tester une date avant de l'écrire : `systemd-analyze calendar "Mon..Fri *-*-* 07:45:00"`
- Si la tour est déjà allumée, rien ne se passe (`already_on`) ; l'extinction automatique de la tour s'applique ensuite normalement.

## Journal

`/var/log/homelab/actions.log` : une ligne JSON par action qui change quelque chose (réveil, extinction, prolongation…) et par commande refusée, avec l'heure et l'adresse d'origine. Au-delà de 1 Mo, l'ancien journal devient `actions.log.1`. La tour tient son propre journal, au même emplacement.

## En cas de problème

| Symptôme | Cause probable, et solution |
|---|---|
| `wake` répond `sent` mais la tour ne s'allume pas | Réveil par le réseau désactivé dans le BIOS ou dans la carte réseau de la tour ; câble débranché (`link.carrier` à `false`) |
| `relay_failed` alors que la tour est allumée | Clé du serveur pas encore autorisée sur la tour (`tower/install.sh add-key`), `TOWER_KEY_FROM` sans l'adresse du serveur, ou pare-feu de la tour |
| `relay_failed` après une réinstallation de la tour | Son empreinte a changé : `sudo -u homelab rm /var/lib/homelab/.ssh/known_hosts_tower`, puis réessayer |
| Test à la main depuis le serveur | `sudo -u homelab ssh -i /var/lib/homelab/.ssh/id_tower -o HostKeyAlias=homelab-tower -o UserKnownHostsFile=/var/lib/homelab/.ssh/known_hosts_tower homelab@ADRESSE_DE_LA_TOUR status` |

## Désinstaller

```bash
sudo ~/homelab-control/server/install.sh uninstall
```

Retire les scripts, le minuteur d'allumage, la règle `sudo` et le réglage SSH. La configuration, le journal et le compte `homelab` sont conservés : la commande pour les effacer est affichée.
