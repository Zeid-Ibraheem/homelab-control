# homelab-control

Application mobile et scripts pour piloter un petit homelab depuis un téléphone :
allumer et éteindre une tour, suivre l'état des machines, ouvrir un terminal.

> **Statut : phase 0.** Squelette du dépôt et verrous de publication.
> Aucune fonctionnalité n'est encore disponible.

## Ce que fera le projet

- Allumer la tour à distance (Wake-on-LAN), l'éteindre, la redémarrer
- Extinction automatique de la tour : échéance prolongeable, bouton « ne pas éteindre », plafond absolu
- Allumage programmé
- Surveillance du serveur et de la tour : processeur, mémoire, températures, disques (SMART), services
- Tableau de bord sécurité et journal de toutes les actions
- Terminal SSH vers chaque machine
- Webcam, sans aucun port exposé (passage par un tunnel SSH)

## Architecture

```mermaid
flowchart LR
    P["Téléphone<br/>(application)"] -- "SSH · clé « actions »<br/>liste fermée de commandes" --> S["Serveur<br/>toujours allumé"]
    P -- "SSH · clé « terminal »" --> S
    S -- "paquet magique<br/>câble direct" --> T["Tour<br/>allumée à la demande"]
    S -- "SSH · clé restreinte" --> T
```

Principes :

- **Un seul transport : SSH.** Pas d'API web, pas de base de données, pas de nouveau port ouvert.
- **La ligne de commande d'abord.** Chaque fonction marche depuis un terminal avant d'exister dans l'application.
- **Moindre privilège.** La clé « actions » ne peut lancer qu'une liste fermée de commandes, la clé « terminal » est séparée, et les droits administrateur sont limités au strict nécessaire.
- **Code public, configuration privée.** Aucun secret ni identifiant personnel dans le dépôt : chaque installation garde ses valeurs dans un fichier local.

## Organisation du dépôt

```
homelab-control/
├── app/        Application Flutter (phase 3)
├── server/     Scripts et services du serveur (phase 1)
├── tower/      Scripts et services de la tour (phase 2)
├── config/     Modèles de configuration, avec des valeurs fictives
├── docs/       Feuille de route et modèle de sécurité
├── scripts/    Vérifications avant publication et installation des hooks
└── .githooks/  Hooks Git versionnés (avant commit, message, avant push)
```

## Démarrer

```bash
git clone <adresse-du-dépôt>
cd homelab-control
scripts/install-hooks.sh   # active les verrous de publication (une fois par clone)
```

La configuration de chaque machine part du modèle `config/homelab.conf.example`,
copié hors du dépôt dans `/etc/homelab/homelab.conf`.

## Documentation

- [`docs/PLAN.md`](docs/PLAN.md) : feuille de route, fonctionnalités et choix techniques
- [`docs/SECURITY.md`](docs/SECURITY.md) : modèle de sécurité et règles de publication

## Licence

[MIT](LICENSE)
