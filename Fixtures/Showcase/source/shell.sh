#!/usr/bin/env bash
# Report the current count.
count=42
label="Glimt"
if [ "$count" -gt 0 ]; then
    printf "%s %s\n" "$label" "$count"
fi

# A quoted collection and nested indentation.
formats=("Shell" "JSON" "YAML")
for format in "${formats[@]}"; do
    if [ -n "$format" ]; then
        printf 'Hello from %s — previewing %s\n' "$label" "$format"
    fi
done
