#!/bin/bash

# Set the primary search directory (default is ./apps)
SEARCH_DIR="${1:-./apps}"

# Additional directory to scan

# Command to execute when a .env file is found
EXECUTE_COMMAND="echo Found .env file at"

# Aggregate directories to search
SEARCH_DIRS=("$SEARCH_DIR")

# Find and process .env files in all specified directories
find "${SEARCH_DIRS[@]}" -type f -name ".env" | while read -r env_file; do
    echo "$EXECUTE_COMMAND $env_file"
    # Extract the directory
    DIR_PATH=$(dirname "$env_file")
    SECRET_NAME=$(basename "$DIR_PATH")

    # Determine namespace based on file path
    namespace="default"

    # Create and seal the secret with the proper namespace
    kubectl --context k3s -n "$namespace" create secret generic "$SECRET_NAME" \
      -o yaml --from-env-file "$env_file" --dry-run=client \
      | kubeseal --context k3s --controller-namespace=infrastructure -o yaml > "$DIR_PATH"/sealedSecret.yaml
done