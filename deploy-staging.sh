#!/bin/bash
# Deploys index_STAGING.html as index.html on the invento-staging repo, without
# disturbing the main branch (which stays production-correct: index.html there
# is the production build). Run this after any change to index_STAGING.html.
set -e
cd "$(dirname "$0")"

git branch -D staging-deploy 2>/dev/null || true
git checkout -b staging-deploy

cp index_STAGING.html index.html
git add index.html
git commit -m "Deploy staging build" --allow-empty -q

git push staging staging-deploy:main --force

git checkout main
git branch -D staging-deploy

echo "Deployed to staging: https://bollinclinic.github.io/invento-staging/"
