# Sécurité

## Le principe : tout peut être public, sauf les clés

Ce dépôt applique le **principe de Kerckhoffs** : un système doit rester sûr même si tout son fonctionnement est connu. Le code est donc publiable tel quel. Ce qui est secret (les clés) ou personnel (les noms, les adresses) ne vit **que** sur les machines et sur le téléphone, jamais dans le dépôt.

## Ce contre quoi on se protège

| Menace | Protection |
|---|---|
| Quelqu'un lit le code public | Le code ne contient ni secret ni identifiant : il ne donne aucun accès |
| Une donnée part sur GitHub par erreur | Les quatre verrous décrits plus bas |
| Écoute du réseau | Tout passe par SSH, chiffré, à l'intérieur d'un VPN. Aucun service en clair |
| Vol du téléphone | Application verrouillée par l'empreinte digitale, clés dans le stockage sécurisé d'Android, révocation des clés |
| Vol de la clé « actions » | Commande forcée : seule une liste fermée d'actions est possible, et leurs arguments sont vérifiés |
| Serveur compromis | La tour n'accepte du serveur qu'un script restreint, et ses droits administrateur sont limités aux commandes nécessaires |
| Webcam regardée par un tiers | Le serveur vidéo n'écoute que sur la machine elle-même : on n'y accède que par un tunnel SSH |

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
