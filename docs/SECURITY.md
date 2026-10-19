# Sécurité

## Le principe : tout peut être public, sauf les clés

Ce dépôt applique le **principe de Kerckhoffs** : un système doit rester sûr même si tout son fonctionnement est connu. Le code est donc publiable tel quel. Ce qui est secret (les clés) ou personnel (les noms, les adresses) ne vit **que** sur les machines et sur le téléphone, jamais dans le dépôt.

## Ce contre quoi on se protège

| Menace | Protection |
|---|---|
| Quelqu'un lit le code public | Le code ne contient ni secret ni identifiant : il ne donne aucun accès |
| Une donnée part sur GitHub par erreur | Les quatre verrous décrits plus bas |
| Écoute du réseau | Tout passe par SSH, chiffré, à l'intérieur d'un VPN. Aucun service en clair. L'application vérifie la clé du serveur à chaque connexion et refuse qu'elle change en cours de route ; sa bibliothèque SSH applique l'échange de clés strict (protection contre l'attaque Terrapin) |
| Vol du téléphone | Application verrouillée (empreinte ou code) au démarrage et après 1 min en arrière-plan, clés créées sur le téléphone et gardées chiffrées (AES-GCM, clé protégée par le Keystore d'Android), sauvegardes désactivées, révocation des clés sur les machines |
| Vol de la clé « actions » | Compte dédié sans droits, commande forcée par la clé **et** par SSH, liste fermée d'actions aux arguments vérifiés, clé acceptée seulement depuis le VPN. Détail : [`server/README.md`](../server/README.md) |
| Vol de la clé « terminal » | Clé séparée de la clé « actions », empreinte ou code redemandé à chaque ouverture du terminal, acceptée seulement depuis les adresses prévues (`from=` posé par `install.sh add-terminal-key` : le téléphone pour le serveur, le serveur pour la tour), sans transfert d'agent ni tunnel sur la tour (`restrict,pty`), révocable seule |
| Commande piégée envoyée au script | Le texte reçu n'est jamais exécuté : caractères limités, longueur limitée, comparaison à une liste fermée, refus journalisé |
| Redémarrage de service détourné | Seuls les services listés dans la configuration (propriété de root) sont redémarrables ; `sudo` n'autorise que ces noms, un par un, et l'aide root revérifie la liste. SSH, VPN, réseau, dbus, polkit et `systemd-*` sont refusés même s'ils sont listés |
| Configuration modifiée pour injecter une commande | Elle appartient à root, elle est lue sans être exécutée, et chaque valeur est validée avant usage |
| Serveur compromis | La tour n'accepte du serveur qu'un script restreint, depuis ses seules adresses, et ses droits administrateur sont limités à éteindre, redémarrer, lire la santé des disques et des journaux, et redémarrer les services que **la tour** autorise. Le plafond d'extinction est appliqué par root sur la tour, quoi que demande le serveur |
| Fichiers du compte `homelab` de la tour modifiés | Root ne fait que les lire : fichier ordinaire seulement (pas de lien, pas de tube), 200 octets au plus, valeurs vérifiées, liées au démarrage en cours. Au pire, l'échéance avance ou recule dans la limite du plafond |
| Action exécutée deux fois par le relais | Le serveur ne réessaie par l'autre chemin que si la connexion a échoué avant de lancer la commande |
| Webcam regardée par un tiers | Le serveur vidéo n'écoute que sur la machine elle-même, et son service ne peut échanger avec aucune autre machine (`IPAddressDeny=any`) : on n'y accède que par un tunnel SSH. La clé « actions » ne peut ouvrir que ce tunnel-là, vers `127.0.0.1:WEBCAM_PORT` (limite posée deux fois : dans la clé et dans le réglage SSH). L'installation vérifie que c'est bien le serveur vidéo qui répond sur ce port |
| Serveur vidéo piraté (faille dans ustreamer) | Il tourne avec un compte temporaire sans aucun droit, qui n'a accès qu'aux caméras, sur un système en lecture seule, sans réseau vers l'extérieur |
| Journal piégé (texte forgé dans une tentative de connexion) | Des journaux, root ne renvoie que des champs vérifiés : des nombres et, pour les connexions réussies, un nom de compte et une adresse filtrés, en JSON échappé. Les tentatives refusées sont seulement comptées |

Hors périmètre, choix assumé : les disques ne sont pas chiffrés, pour que les machines puissent redémarrer sans personne devant. En cas de vol physique d'une machine, changer immédiatement les mots de passe qu'elle contenait et la retirer du VPN.

## Ce qui ne doit jamais être publié

| Donnée | Où elle vit |
|---|---|
| Clés SSH privées | Générées sur chaque appareil, jamais copiées ailleurs |
| Noms des machines, utilisateurs, adresse MAC, noms des cartes réseau, adresses VPN | `/etc/homelab/homelab.conf` sur chaque machine |
| Réglages de l'application (adresses, clés) | Saisis dans l'application, stockés chiffrés sur le téléphone |
| `authorized_keys` et `sudoers` réels | Générés à l'installation à partir de modèles |
| Journaux, captures d'écran, enregistrements vidéo | Restent sur les machines. Dans la documentation, uniquement des captures floutées |

## Les quatre verrous

1. **`.gitignore`** : la configuration réelle, les clés, les certificats et les journaux sont ignorés par Git.
2. **Hooks Git** (activés par `scripts/install-hooks.sh`) :
   - avant chaque commit : `scripts/check-public.sh --staged`, puis gitleaks sur les fichiers prêts à être commités ;
   - sur chaque message de commit : `scripts/check-public.sh --message` ;
   - avant chaque push : `scripts/check-public.sh --history` et gitleaks sur **tout l'historique**, ce qui rattrape un commit fait avec `--no-verify`.
3. **Liste noire personnelle**, stockée **hors du dépôt** (`~/.config/homelab/blacklist.txt`, droits 600) : tes identifiants réels, recherchés en mot entier et sans tenir compte de la casse. Modèle : `config/blacklist.example.txt`.
4. **Vérification sur GitHub** à chaque push (`.github/workflows/public-safety.yml`), plus la protection native de GitHub contre les secrets.

### Ce que `check-public.sh` bloque

- Les fichiers sensibles : `homelab.conf`, `.env`, clés SSH, certificats, `authorized_keys`, `known_hosts`, profils NetworkManager, journaux, liste noire.
- Les clés privées (OpenSSH, PEM, PGP) et les clés privées WireGuard.
- Les adresses MAC, sauf les valeurs fictives (`AA:BB:CC:DD:EE:FF`, `00:00:00:00:00:00`…).
- Les adresses Tailscale (plage `100.64.0.0/10` et préfixe IPv6 de Tailscale), et ses clés d'authentification.
- Chaque terme de la liste noire, dans le contenu des fichiers, leurs noms, les messages de commit et les auteurs des commits.

En mode CI, le script n'affiche jamais le contenu des lignes trouvées : les journaux d'un dépôt public sont publics.

### Pourquoi deux outils

- **gitleaks** connaît des centaines de formats de secrets (jetons, clés d'API, mots de passe).
- **check-public.sh** connaît **ton** installation : ta liste noire, les adresses MAC, les adresses du VPN. Aucun outil générique ne peut savoir que le nom de ta machine est une donnée personnelle.

## Mise en place

```bash
scripts/install-hooks.sh                                 # hooks + liste noire
$EDITOR ~/.config/homelab/blacklist.txt                  # ajouter tes identifiants
gh secret set HOMELAB_BLACKLIST < ~/.config/homelab/blacklist.txt   # liste noire pour la CI
```

Puis, sur GitHub : **Settings → Code security**, activer la détection des secrets (*secret scanning*) et le blocage des envois (*push protection*).

## Avant de rendre le dépôt public

- [ ] `scripts/check-public.sh --history` ne signale rien
- [ ] `scripts/gitleaks-scan.sh history` ne signale rien
- [ ] Relire la documentation et les images : aucun nom réel, aucune capture non floutée
- [ ] La détection des secrets et le blocage des envois sont activés sur GitHub
- [ ] La vérification GitHub (onglet *Actions*) est au vert

## En cas de fuite

1. **Considérer le secret comme compromis**, même si le commit est supprimé aussitôt : des robots analysent GitHub en continu.
2. **Le remplacer immédiatement** : nouvelle clé SSH (et retrait de l'ancienne de tous les `authorized_keys`), nouveau mot de passe.
3. **Ensuite seulement**, nettoyer l'historique (`git filter-repo`) et forcer l'envoi.

## Signaler un problème

Pour une faille de sécurité, utiliser le signalement privé de GitHub (onglet *Security*, « Report a vulnerability ») plutôt qu'un ticket public.
