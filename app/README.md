# app/

Application **Android** (Flutter) : la télécommande du homelab (phases 3 à 6).

Elle ne parle qu'au serveur, en SSH, avec sa propre clé ; le serveur relaie vers la tour. Tout ce qu'elle fait marche aussi depuis un terminal (`ssh hl …`, voir [`server/README.md`](../server/README.md)).

## Ce qu'elle fait

- **Tableau de bord** : état du serveur (temps depuis l'allumage, processeur, mémoire, température, disque, batterie, signal Wi-Fi, câble vers la tour) et de la tour (allumée ou non, par le câble ou par le VPN, températures, signal Wi-Fi, échéance de l'extinction automatique, « ne pas éteindre », session ouverte devant la tour, tâche en cours).
- **Boutons** : allumer, prolonger (durée au choix, par pas de 5 minutes, jusqu'au plafond), éteindre dans… (durée au choix), ne pas éteindre, redémarrer, éteindre. Redémarrer et éteindre demandent une confirmation.
- **Comment la tour a été allumée** (par le serveur : 4 h ; à la main : 8 h) et **prochain allumage programmé**.
- **Santé** : services suivis, disques (SMART : verdict, température, usure, secteurs abîmés), sécurité sur 24 h (connexions SSH, tentatives refusées, blocages du pare-feu), pour le serveur et la tour. Bouton **Redémarrer** à côté des services autorisés dans la configuration de chaque machine (`SERVER_RESTARTABLE`, `TOWER_RESTARTABLE`), avec confirmation.
- **Webcam** : flux vidéo du serveur, à travers un tunnel SSH vers son seul port local.
- **Terminal** vers le serveur, et vers la tour en passant par le serveur, avec une clé séparée.
- **Journal** des actions du serveur (réveils, extinctions, commandes refusées…).
- L'état est relu toutes les 30 s quand l'application est ouverte, et toutes les 5 s pendant 2 min après un allumage. Rien ne tourne en arrière-plan.

## Sécurité

| Mesure | Détail |
|---|---|
| Clé propre à l'application | Clé SSH Ed25519 créée **sur le téléphone**, à partir du générateur aléatoire cryptographique du système. La partie privée ne le quitte jamais : seule la partie publique est affichée, et les sauvegardes Android de l'application sont désactivées |
| Stockage chiffré | La clé et les réglages sont chiffrés en AES-GCM, par une clé elle-même protégée par le Keystore d'Android, gardé par le matériel du téléphone : elle ne peut pas en être extraite |
| Bibliothèque SSH à jour | dartssh2 4 : échange de clés strict (protection contre l'attaque Terrapin), refus d'une clé de machine qui change en cours de connexion, vérification des valeurs reçues pendant l'échange de clés |
| Verrou | Empreinte ou code du téléphone au démarrage, puis après 1 minute en arrière-plan. Tant que l'application est verrouillée, rien n'est chargé en mémoire |
| Serveur vérifié | À la première connexion, tu compares l'empreinte de la clé du serveur avec celle qu'affiche `ssh-keygen` sur le serveur. Ensuite, toute connexion qui présente une autre clé est refusée : personne ne peut se faire passer pour le serveur |
| Droits limités | Côté serveur, c'est une clé « actions » comme les autres : compte `homelab`, commande forcée, liste fermée d'actions, acceptée seulement depuis le VPN, et un seul tunnel possible, vers le port local de la webcam. L'application ne fabrique d'ailleurs que ces commandes |
| Terminal | Clé séparée (`homelab-terminal`), avec un accès complet à ton compte : l'empreinte ou le code est redemandé à chaque ouverture. La clé de la tour est vérifiée à la première connexion, comme celle du serveur |
| Réseau | Aucune autre connexion : ni service tiers, ni statistiques, ni services Google |
| Révocation | Retirer la ligne qui finit par `homelab-app` de `/var/lib/homelab/.ssh/authorized_keys` sur le serveur, et celle qui finit par `homelab-terminal` des `~/.ssh/authorized_keys` de ton compte |

## Construire l'application

L'APK se construit sur ta machine : aucun service extérieur, et la signature reste chez toi. Exemple sur Arch, à faire une fois :

```bash
sudo pacman -S --needed git unzip jdk17-openjdk
git clone --depth 1 -b stable https://github.com/flutter/flutter.git ~/.local/share/flutter
echo 'export PATH="$HOME/.local/share/flutter/bin:$PATH"' >> ~/.bashrc
```

Puis les outils Android en ligne de commande : sur la page de téléchargement d'Android Studio, partie *Command line tools only*, prendre le fichier `commandlinetools-linux-…_latest.zip`, et :

```bash
mkdir -p ~/Android/Sdk/cmdline-tools
unzip ~/Downloads/commandlinetools-linux-*_latest.zip -d ~/Android/Sdk/cmdline-tools
mv ~/Android/Sdk/cmdline-tools/cmdline-tools ~/Android/Sdk/cmdline-tools/latest
exec bash                                   # recharge le terminal (Flutter dans le PATH)
flutter config --android-sdk ~/Android/Sdk --jdk-dir /usr/lib/jvm/java-17-openjdk
flutter doctor --android-licenses           # accepter les licences
flutter doctor                              # la ligne « Android toolchain » doit être cochée
```

Il faut Flutter 3.38 ou plus récent (`flutter --version`). Construire :

```bash
cd app
# Une seule fois : crée les fichiers Android manquants (ceux du dépôt sont gardés).
flutter create --platforms=android --org dev.homelab --project-name homelab_control .
flutter pub get
flutter test
flutter build apk --release
```

L'APK se trouve dans `build/app/outputs/flutter-apk/app-release.apk`. Les fichiers créés par `flutter create` (dossier `android/`, `pubspec.lock`, `.metadata`) peuvent être commités : ils ne contiennent rien de personnel, et les fichiers locaux (`local.properties`, `build/`) sont ignorés par Git.

**Signature** : l'APK est signé avec la clé de développement de ta machine (`~/.android/debug.keystore`). Garde ce fichier (et sauvegarde-le) : une mise à jour signée par une autre clé ne s'installe pas par-dessus, il faudrait désinstaller l'application et donc recréer sa clé SSH.

## Installer sur le téléphone

- **Par câble** (le plus simple pour les mises à jour) : activer les options pour les développeurs et le débogage USB sur le téléphone, le brancher, puis `~/Android/Sdk/platform-tools/adb install -r build/app/outputs/flutter-apk/app-release.apk` (`platform-tools` s'installe avec `~/Android/Sdk/cmdline-tools/latest/bin/sdkmanager platform-tools`).
- **Par fichier** : copier l'APK sur le téléphone et l'ouvrir avec l'application Fichiers, en autorisant l'installation depuis cette source.

Pour une mise à jour : `git pull`, `flutter build apk --release`, puis la même commande `adb install -r` : la clé et les réglages sont conservés.

**Depuis la version 0.6** (stockage chiffré changé de méthode) : les réglages enregistrés par la 0.6 ne sont pas relus. Refaire la première utilisation (nouvelle clé), puis retirer l'ancienne ligne `homelab-app` de `/var/lib/homelab/.ssh/authorized_keys` sur le serveur.

## Première utilisation

1. Ouvrir l'application et la déverrouiller (empreinte ou code du téléphone).
2. **Créer la clé** : l'application affiche la commande qui l'autorise sur le serveur. La copier, puis la lancer sur le serveur (par exemple dans Termux, connecté en SSH avec ton compte habituel).
3. Saisir l'adresse du serveur (son nom sur le VPN, ou son adresse en `100.x.y.z`), le port (22) et le compte (`homelab`).
4. **Se connecter** : l'application affiche l'empreinte de la clé du serveur et la commande `ssh-keygen` à lancer sur le serveur pour l'afficher aussi. Si les deux sont identiques, appuyer sur **Identique**.
5. Le tableau de bord s'affiche.

Le VPN doit être actif dans le même profil Android que l'application.

## Terminal

Dans les réglages, **Créer la clé du terminal** : l'application affiche alors deux commandes à copier, à lancer avec `sudo` depuis ton compte.

```bash
# sur le serveur
sudo ~/homelab-control/server/install.sh add-terminal-key "ssh-ed25519 AAAA… homelab-terminal"
# sur la tour, dans le dossier du dépôt
sudo tower/install.sh add-terminal-key "ssh-ed25519 AAAA… homelab-terminal"
```

Chacune ajoute la clé à `~/.ssh/authorized_keys` de ton compte, limitée aux adresses d'où elle arrive (`from="…"`), prises dans la configuration de la machine :

| Machine | La connexion arrive de… | Adresses utilisées |
|---|---|---|
| Serveur | du téléphone, par le VPN | `ACTIONS_KEY_FROM` |
| Tour | du **serveur** (pas du téléphone), par le câble ou par le VPN | `TOWER_KEY_FROM` |

Relancer une commande remplace la ligne de la clé (par exemple après un changement d'adresses).

Toujours dans les réglages, renseigner ton compte sur le serveur, ton compte sur la tour, et les adresses de la tour **vues depuis le serveur** : une ou deux, séparées par un espace, par exemple son adresse sur le câble puis son nom sur le VPN (`10.0.0.2 ma-tour`). L'application essaie la première, puis la seconde si la tour ne répond pas par là. La connexion à la tour passe par le serveur : le compte du serveur doit pouvoir ouvrir un tunnel vers le port 22 de la tour (c'est le cas par défaut avec OpenSSH). Changer ces adresses fait revérifier la clé de la tour à la connexion suivante.

Une barre de touches ajoute ce qui manque au clavier du téléphone : Échap, Tab, Ctrl (enclenché, puis la lettre : Ctrl+C, Ctrl+D…), flèches.

## Webcam

Côté serveur, brancher la webcam, renseigner `WEBCAM_DEVICE` et `WEBCAM_PORT` dans `/etc/homelab/homelab.conf`, puis relancer `server/install.sh` : il installe et lance le serveur vidéo (voir [`server/README.md`](../server/README.md#webcam)). Le bouton **Webcam** du tableau de bord s'active alors. L'image passe par un tunnel SSH : aucun port vidéo n'est ouvert sur le réseau.

## En cas de problème

| Message | Cause probable |
|---|---|
| Serveur « … » injoignable : le VPN est-il actif ? | VPN coupé, ou un autre VPN actif à sa place |
| Clé refusée par le serveur | Commande `add-key` pas encore lancée sur le serveur, ou `ACTIONS_KEY_FROM` sans la plage IPv4 du VPN |
| La clé du serveur a changé | Si le serveur a été réinstallé : Réglages, puis « Changer de serveur ». Sinon, **ne pas continuer** : quelqu'un essaie peut-être de se faire passer pour lui |
| Déverrouillage impossible | Aucun verrouillage d'écran configuré sur le téléphone |
| Webcam injoignable | Serveur vidéo arrêté (sur le serveur : `systemctl status homelab-webcam`), ou `install.sh` pas relancé après un changement de `WEBCAM_PORT` |
| Webcam (non configurée) | `WEBCAM_PORT` vide sur le serveur |
| Service non autorisé au redémarrage | Le service n'est pas dans `SERVER_RESTARTABLE` (ou `TOWER_RESTARTABLE` sur la tour), ou `install.sh` pas relancé après l'avoir ajouté |
| Le serveur ne joint pas la tour (terminal) | Tour éteinte, SSH arrêté sur la tour (`sudo systemctl enable --now sshd`), ou adresses de la tour (vues du serveur) incorrectes dans les réglages |
| Clé refusée par la tour (terminal) | Commande `add-terminal-key` pas lancée sur la tour, ou `TOWER_KEY_FROM` sans l'adresse par laquelle arrive le serveur |
| Erreur à la compilation | Envoyer la sortie de `flutter analyze` et de `flutter build apk` |

## Organisation du code

| Fichier | Rôle |
|---|---|
| `lib/main.dart` | Démarrage, verrou, choix entre configuration et tableau de bord |
| `lib/src/app_key.dart` | Création de la clé Ed25519 au format OpenSSH |
| `lib/src/ssh_link.dart` | Connexions SSH, vérification des clés des machines, tunnel |
| `lib/src/remote_shell.dart` | Session du terminal, vers le serveur ou vers la tour par le serveur |
| `lib/src/mjpeg.dart` | Découpage du flux vidéo MJPEG en images |
| `lib/src/duration_sheet.dart` | Choix d'une durée au curseur |
| `lib/src/api.dart` | Commandes envoyées et lecture des réponses JSON |
| `lib/src/store.dart` | Stockage chiffré |
| `lib/src/lock.dart` | Verrou (empreinte ou code) |
| `lib/src/*_screen.dart` | Écrans : configuration, tableau de bord, santé, webcam, terminal, journal, réglages |
| `test/` | Tests : format de la clé (vecteur de la RFC 8032), lecture des réponses, flux vidéo, mise en forme |
