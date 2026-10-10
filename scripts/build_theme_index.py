#!/usr/bin/env python3
"""Regenerates themes/index.json from themes/*.piertheme (run before committing a new theme)."""
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent / "themes"
entries, errors = [], []
for path in sorted(root.glob("*.piertheme")):
    try:
        theme = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        errors.append(f"{path.name}: {exc}")
        continue
    if not theme.get("id") or not theme.get("name"):
        errors.append(f"{path.name}: needs an id and a name")
        continue
    entries.append({"file": path.name, "id": theme["id"], "name": theme["name"],
                    "author": theme.get("author", "Unknown")})

if errors:
    sys.exit("\n".join(errors))
(root / "index.json").write_text(json.dumps({"version": 1, "themes": entries}, indent=2) + "\n")
print(f"Indexed {len(entries)} themes")
