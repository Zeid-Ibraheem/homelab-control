#!/usr/bin/env bash
# =============================================================================
# install-hooks.sh : active les verrous de publication pour ce clone du dépôt.
#   1. hooks Git versionnés (.githooks/) : avant commit, message, avant push ;
#   2. vérifie que gitleaks est installé ;
#   3. crée la liste noire personnelle HORS du dépôt si elle n'existe pas ;
#   4. lance une première vérification de tous les fichiers suivis.
# =============================================================================
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
OK=1

# 1. Hooks
git config core.hooksPath .githooks
chmod +x .githooks/* scripts/*.sh
echo "✓ Hooks activés (core.hooksPath = .githooks)"

# 2. gitleaks
if command -v gitleaks >/dev/null 2>&1; then
  echo "✓ gitleaks installé ($(gitleaks version 2>/dev/null || echo 'version inconnue'))"
else
  OK=0
  echo "✗ gitleaks n'est pas installé : les commits seront bloqués tant qu'il manque."
  echo "    Arch   : sudo pacman -S gitleaks"
  echo "    Debian : sudo apt install gitleaks"
fi

# 3. Liste noire personnelle
BL="${HOMELAB_BLACKLIST:-$HOME/.config/homelab/blacklist.txt}"
if [ -f "$BL" ]; then
  count=$(grep -cvE '^[[:space:]]*(#|$)' "$BL" || true)
  echo "✓ Liste noire : $BL ($count terme(s))"
  [ "$count" -gt 0 ] || { OK=0; echo "    Elle est vide : ajoute tes identifiants, un par ligne."; }
else
  install -d -m 700 "$(dirname "$BL")"
  install -m 600 /dev/null "$BL"
  grep '^#' config/blacklist.example.txt > "$BL"
  OK=0
  echo "→ Liste noire créée : $BL (droits 600)"
  echo "    Ajoute tes identifiants, un par ligne : noms des machines, utilisateurs,"
  echo "    adresse MAC, noms des cartes réseau, identifiant universitaire, e-mail…"
  echo "    Jamais de mot de passe."
fi

# 4. Première vérification
echo
scripts/check-public.sh --all || OK=0

echo
if [ "$OK" -eq 1 ]; then
  echo "✓ Tout est prêt : chaque commit et chaque push seront vérifiés."
else
  echo "! Termine les points ci-dessus avant ton premier commit."
fi
