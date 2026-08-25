#!/usr/bin/env bash
TARGET_DIR=$1
if [ -z "$TARGET_DIR" ]; then
    echo "Usage: $0 <target_directory>"
    exit 1
fi
COUNT=$(find "$TARGET_DIR" -type f \( -name "*.res" -o -name "*.resi" -o -name "bsconfig.json" -o -name "rescript.json" \) -not -path "*/developer-ecosystem/rescript-ecosystem/*" -not -path "*/proven/*" -not -path "*/node_modules/*" 2>/dev/null | wc -l)
echo $COUNT
