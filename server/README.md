# server/

Scripts et services du **serveur toujours allumé** (phase 1).

À venir :

- `homelab` : le script appelé par la clé « actions » (commande forcée). Il n'accepte qu'une liste fermée d'actions, répond en JSON et inscrit chaque action dans le journal.
- Le modèle de ligne `authorized_keys` pour la clé « actions ».
- Le script d'installation, qui lit `/etc/homelab/homelab.conf`.

Aucune valeur propre à une installation n'est écrite en dur ici : tout vient de la configuration locale.
