#!/usr/bin/env bash
# =============================================================================
# gitleaks-scan.sh : recherche les secrets génériques (mots de passe, jetons,
# clés d'API…) avec gitleaks, en choisissant la bonne syntaxe selon la version.
#
# Usage :
#   scripts/gitleaks-scan.sh staged    fichiers prêts à être commités
#   scripts/gitleaks-scan.sh history   tout l'historique
# =============================================================================
set -euo pipefail

MODE=${1:-}
case "$MODE" in
  staged|history) ;;
  *) echo "Usage : $0 staged|history" >&2; exit 2 ;;
esac

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "✗ gitleaks n'est pas installé : c'est lui qui détecte les mots de passe et les jetons." >&2
  echo "  Arch : sudo pacman -S gitleaks   ·   Debian : sudo apt install gitleaks" >&2
  exit 1
fi

CONFIG=(--config "$ROOT/.gitleaks.toml")

# La commande « gitleaks git » existe depuis la version 8.19.
version=$(gitleaks version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n 1 || true)
major=${version%%.*}
minor=${version#*.}
if [ -z "$version" ] || [ "$major" -gt 8 ] || { [ "$major" -eq 8 ] && [ "$minor" -ge 19 ]; }; then
  case "$MODE" in
    staged)  exec gitleaks git --pre-commit --staged --redact -v "${CONFIG[@]}" ;;
    history) exec gitleaks git --redact -v "${CONFIG[@]}" ;;
  esac
else
  case "$MODE" in
    staged)  exec gitleaks protect --staged --redact -v "${CONFIG[@]}" ;;
    history) exec gitleaks detect --redact -v "${CONFIG[@]}" ;;
  esac
fi
