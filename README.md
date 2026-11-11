# homelab-control

Une appli Android pour piloter mon petit homelab depuis mon téléphone : allumer ma tour à distance, voir si tout va bien, ouvrir un terminal, jeter un œil à la webcam.

<!-- CAPTURES : supprimer cette ligne et la ligne « FIN CAPTURES » quand les images sont dans docs/captures/
<p align="center">
  <img src="docs/captures/1-tableau-de-bord.jpg" width="230" alt="Tableau de bord : état du serveur et de la tour">
  <img src="docs/captures/2-allumage.jpg" width="230" alt="Choix de la durée avant l'extinction automatique">
  <img src="docs/captures/3-sante.jpg" width="230" alt="Santé des machines : services, disques, sécurité">
</p>
<p align="center">
  <img src="docs/captures/4-terminal.jpg" width="230" alt="Terminal SSH vers la tour">
  <img src="docs/captures/6-journal.jpg" width="230" alt="Journal des actions">
</p>
FIN CAPTURES -->

## Pourquoi je l'ai fait

<!-- À TOI : ta dictée remplacera ce paragraphe. -->
Ma tour me sert pour les gros travaux, mais je ne veux pas la laisser allumée jour et nuit : ce serait environ 140 € d'électricité par an, plus le bruit dans la chambre. Je voulais pouvoir l'allumer de n'importe où, et qu'elle s'éteigne toute seule quand je ne m'en sers plus.

## Le vrai défi : le réseau de ma résidence

J'habite en résidence universitaire. Le réseau est partagé : pas de box à moi, pas d'accès au routeur, et les appareils ne se voient pas forcément entre eux. Les solutions habituelles pour réveiller un PC à distance (le bouton de la box, une prise connectée) ne marchent pas ici.

Au départ, je ne voulais aucun intermédiaire entre le téléphone et la tour. Le réseau m'a fait changer d'avis : tour éteinte, il faut forcément une machine allumée pour recevoir la demande. J'ai donc transformé un vieux portable en petit serveur allumé en permanence (environ 10 W). Il est relié à la tour par un câble Ethernet direct, et c'est lui qui envoie le paquet de réveil (Wake-on-LAN). Le téléphone le joint de partout par un VPN, sans ouvrir aucun port.

```mermaid
flowchart LR
    P["Téléphone<br/>l'appli"]
    S["Vieux portable<br/>serveur allumé 24 h/24"]
    T["Tour<br/>allumée à la demande"]

    P -->|"VPN + SSH<br/>liste fermée de commandes"| S
    S -->|"câble direct<br/>paquet de réveil"| T
    S -->|"SSH, clé limitée"| T
```

## Ce que fait l'appli

- Allumer, éteindre ou redémarrer la tour, ou programmer son allumage.
- L'éteindre toute seule : après 4 h si le serveur l'a allumée, 8 h si c'est moi. Je peux prolonger ou dire « ne pas éteindre », et elle ne s'éteint jamais pendant que je l'utilise.
- Surveiller les deux machines : processeur, mémoire, températures, réseau, disques (SMART), services, avec un bouton pour redémarrer ceux que j'autorise.
- Ouvrir un terminal SSH sur le serveur ou sur la tour.
- Regarder la webcam, sans exposer aucun port (elle passe par un tunnel SSH).
- Garder un journal de toutes les actions.

## La sécurité

Tout passe par un réseau que je ne contrôle pas, donc j'ai été strict :

- **Un seul moyen d'entrer : SSH.** Pas d'API web, pas de base de données, aucun port ouvert en plus.
- **Moindre privilège.** La clé de l'appli ne peut lancer qu'une liste fermée de commandes. Le terminal a sa propre clé, et l'empreinte du téléphone est redemandée à chaque ouverture.
- **La clé ne quitte jamais le téléphone.** Elle y est créée, puis stockée chiffrée et protégée par le Keystore d'Android.
- **Code public, configuration privée.** Aucun secret ni identifiant dans le dépôt. Des hooks Git et une vérification sur GitHub bloquent tout envoi qui contiendrait une adresse MAC, une adresse du VPN ou un mot de ma liste noire.

## Ce qui m'a posé problème

<!-- À TOI : remplace ou complète avec tes vraies galères (Wake-on-LAN, SSH, systemd…). -->
- **Le réseau partagé**, raconté plus haut : c'est lui qui a dicté toute l'architecture.
- **Publier sans rien laisser fuiter.** Un dépôt public sur un homelab, c'est vite une liste d'adresses et de noms de machines. J'ai écrit un script de vérification qui tourne avant chaque commit, chaque push, et sur GitHub.

## Le dépôt

```
homelab-control/
├── app/        appli Android (Flutter)
├── common/     bibliothèque commune au serveur et à la tour
├── server/     scripts et services du serveur
├── tower/      scripts et services de la tour
├── config/     modèles de configuration, avec des valeurs fictives
├── docs/       feuille de route et modèle de sécurité
├── scripts/    vérifications avant publication, installation des hooks
└── .githooks/  hooks Git (avant commit, message, avant push)
```

<details>
<summary><b>Installer</b></summary>

```bash
git clone <adresse-du-dépôt>
cd homelab-control
scripts/install-hooks.sh   # active les verrous de publication (une fois par clone)
```

La configuration de chaque machine part du modèle `config/homelab.conf.example`, copié hors du dépôt dans `/etc/homelab/homelab.conf`. Ensuite :

- [`server/README.md`](server/README.md) : installer le serveur, les actions, l'allumage programmé
- [`tower/README.md`](tower/README.md) : installer la tour, l'extinction automatique
- [`app/README.md`](app/README.md) : construire et installer l'appli

</details>

Pour aller plus loin : [`docs/PLAN.md`](docs/PLAN.md) (feuille de route et choix techniques) et [`docs/SECURITY.md`](docs/SECURITY.md) (modèle de sécurité).

Fait avec Flutter, Bash, OpenSSH, systemd et Tailscale. Licence [MIT](LICENSE).
