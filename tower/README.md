# tower/

Scripts et services de la **tour allumée à la demande** (phase 2).

À venir :

- `tour` : le script appelé par le serveur (clé restreinte) : état, extinction, redémarrage, échéance.
- L'extinction automatique : un minuteur systemd local, qui fonctionne même si le serveur et le téléphone sont hors ligne.
- Le modèle `sudoers`, limité aux seules commandes nécessaires.

Aucune valeur propre à une installation n'est écrite en dur ici : tout vient de la configuration locale.
