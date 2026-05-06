#!/bin/bash

# Set the primary search directory (default is ./apps)
SEARCH_DIR="${1:-./apps}"
KUBE_CONTEXT="${KUBE_CONTEXT:-velocita}"
NAMESPACE="${NAMESPACE:-default}"
SEALED_SECRETS_NAMESPACE="${SEALED_SECRETS_NAMESPACE:-infrastructure}"

# Additional directory to scan

# Command to execute when a .env file is found
EXECUTE_COMMAND="echo Found .env file at"

# Aggregate directories to search
SEARCH_DIRS=("$SEARCH_DIR")

seal_env_file() {
    local env_file="$1"
    local dir_path secret_name

    dir_path=$(dirname "$env_file")
    secret_name=$(basename "$dir_path")

    case "$secret_name" in
      forgejo)
        secret_name="forgejo-credentials"
        ;;
    esac

    kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" create secret generic "$secret_name" \
      -o yaml --from-env-file "$env_file" --dry-run=client \
      | kubeseal --context "$KUBE_CONTEXT" --controller-namespace="$SEALED_SECRETS_NAMESPACE" -o yaml > "$dir_path"/sealedSecret.yaml
}

read_env_value() {
    local env_file="$1"
    local key="$2"

    awk -F= -v key="$key" '
        $1 == key {
            value = substr($0, length($1) + 2)
            if ((value ~ /^".*"$/) || (value ~ /^\047.*\047$/)) {
                value = substr(value, 2, length(value) - 2)
            }
            print value
            exit
        }
    ' "$env_file"
}

seal_postgres_credentials() {
    local env_file="$1"
    local dir_path app_name secret_name username password

    dir_path=$(dirname "$env_file")
    app_name=$(basename "$dir_path")
    secret_name="$app_name-postgres-credentials"
    username="$app_name-db-user"
    password=$(read_env_value "$env_file" "DB_PASSWORD")

    if [ -z "$password" ]; then
        return
    fi

    kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" create secret generic "$secret_name" \
      --type=kubernetes.io/basic-auth \
      --from-literal=username="$username" \
      --from-literal=password="$password" \
      --dry-run=client -o yaml \
      | kubectl label --local -f - cnpg.io/reload=true -o yaml \
      | kubeseal --context "$KUBE_CONTEXT" --controller-namespace="$SEALED_SECRETS_NAMESPACE" -o yaml > "$dir_path"/postgres-sealedSecret.yaml
}

seal_file_secrets() {
    local file_secrets="$1"
    local dir_path output_file tmp_dir doc count first_doc

    dir_path=$(dirname "$file_secrets")
    output_file="$dir_path/sealedFileSecrets.yaml"
    tmp_dir=$(mktemp -d)
    count=0
    first_doc=1

    # Split multi-document YAML so each Secret is sealed independently.
    awk -v out="$tmp_dir" '
        /^---[[:space:]]*$/ {
            if (has_content) {
                close(file)
                doc++
            }
            has_content=0
            next
        }
        {
            if (!has_content) {
                file=sprintf("%s/doc_%03d.yaml", out, doc)
                has_content=1
            }
            print >> file
        }
        END {
            if (has_content) {
                close(file)
            }
        }
    ' "$file_secrets"

    : > "$output_file"
    shopt -s nullglob
    for doc in "$tmp_dir"/doc_*.yaml; do
        if ! grep -Eq '^[[:space:]]*kind:[[:space:]]*Secret[[:space:]]*$' "$doc"; then
            continue
        fi

        if [ "$first_doc" -eq 0 ]; then
            echo "---" >> "$output_file"
        fi

        kubeseal --context "$KUBE_CONTEXT" --controller-namespace="$SEALED_SECRETS_NAMESPACE" -o yaml < "$doc" >> "$output_file"
        first_doc=0
        count=$((count + 1))
    done
    shopt -u nullglob

    if [ "$count" -eq 0 ]; then
        rm -f "$output_file"
    fi

    rm -rf "$tmp_dir"
}

# Find and process .env files in all specified directories
find "${SEARCH_DIRS[@]}" -type f -name ".env" | while read -r env_file; do
    echo "$EXECUTE_COMMAND $env_file"
    seal_env_file "$env_file"
    seal_postgres_credentials "$env_file"
done

# Find and process file-based secret manifests (supports both common and typo filename)
find "${SEARCH_DIRS[@]}" -type f \( -name "fileSecrets.yaml" -o -name "fileSecrects.yaml" \) | while read -r file_secrets; do
    echo "Found file secrets file at $file_secrets"
    seal_file_secrets "$file_secrets"
done
