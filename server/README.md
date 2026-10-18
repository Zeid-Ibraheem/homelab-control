# server/

Point d'entrée du téléphone sur le **serveur toujours allumé** (phase 1).

## Contenu

| Fichier | Installé dans | Rôle |
|---|---|---|
| `homelab` | `/usr/local/bin/homelab` | Script lancé par la clé « actions » : liste fermée d'actions, réponses en JSON, journal |
| `homelab-root` | `/usr/local/lib/homelab/homelab-root` | La seule action qui demande les droits root (le réveil), autorisée par `sudo` avec un argument fixe |
| `lib.sh` | `/usr/local/lib/homelab/lib.sh` | Lecture sûre de la configuration, validations, JSON |
| `sshd-homelab.conf` | `/etc/ssh/sshd_config.d/50-homelab.conf` | Le compte `homelab` ne peut lancer que le script |
| `install.sh` | | Installation, ajout d'une clé, désinstallation |

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
git archive HEAD | ssh utilisateur@serveur 'mkdir -p ~/homelab-control && tar -x -C ~/homelab-control'
```

Sur le serveur :

```bash
sudo ~/homelab-control/server/install.sh   # 1er lancement : crée /etc/homelab/homelab.conf
sudoedit /etc/homelab/homelab.conf         # remplacer les valeurs d'exemple
sudo ~/homelab-control/server/install.sh   # installe et lance un premier test
```

Puis autoriser la clé « actions » du téléphone (voir ci-dessous).

## Clé « actions » du téléphone

Dans le terminal du téléphone, créer une clé **dédiée** :

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
| `ssh hl status` | État du serveur, du câble et de la tour |
| `ssh hl wake` | Allume la tour : `sent`, `already_on`, `ignored_recent` ou `busy` |
| `ssh hl log 10` | Les 10 dernières actions (1 à 200) |
| `ssh hl actions` | Liste des actions |
| `ssh hl version` | Version du script |

Toute autre commande est refusée (code de sortie 2) et inscrite dans le journal.

Exemple de réponse à `status`, avec des valeurs fictives :

```json
{"ok":true,"api":1,"time":"2026-01-01T12:00:00+01:00",
 "server":{"uptime_s":345600,"load":[0.08,0.12,0.10],"cpu_pct":2.3,"mem_used_pct":21.4,
           "temp_c":41.0,"disk_used_pct":12,"battery_pct":64,"on_ac":true},
 "link":{"present":true,"carrier":true},
 "tower":{"online":false,"via":null,"uptime_s":null,"auto_off":null}}
```

(sur une seule ligne en réalité ; `ssh hl status | jq` pour l'afficher joliment)

## Journal

`/var/log/homelab/actions.log` : une ligne JSON par action qui change quelque chose (réveil) et par commande refusée, avec l'heure et l'adresse d'origine. Au-delà de 1 Mo, l'ancien journal devient `actions.log.1`.

## Désinstaller

```bash
sudo ~/homelab-control/server/install.sh uninstall
```

Retire les scripts, la règle `sudo` et le réglage SSH. La configuration, le journal et le compte `homelab` sont conservés : la commande pour les effacer est affichée.
