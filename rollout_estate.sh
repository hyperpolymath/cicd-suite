#!/bin/bash
echo "Rolling out Centralized CI/CD Suite to all repositories in the estate..."

central_workflow="/home/hyperpolymath/developer/hyper-repos/cicd-suite/.github/workflows/main-estate-audit.yml"

for repo in /home/hyperpolymath/developer/hyper-repos/*; do
  if [ -d "$repo/.git" ] && [ "$(basename "$repo")" != "cicd-suite" ]; then
    echo "Migrating $repo..."
    mkdir -p "$repo/.github/workflows"
    cp "$central_workflow" "$repo/.github/workflows/main-estate-audit.yml"
  fi
done

echo "Rollout complete!"
