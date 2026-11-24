#!/usr/bin/env python3
# Greet each enabled format.
count = 42
def greet(label: str) -> str:
    return f"Glimt {label}: {count}"


formats = ["Python", "JSON", "YAML"]
preview = {"name": "Glimt", "version": 1, "enabled": True}
for format_name in formats:
    if preview["enabled"]:
        message = greet(format_name)
        # One line per format.
        print(message)
