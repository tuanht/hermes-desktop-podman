#!/usr/bin/env bash
# Sync Hermes `model_aliases` (provider ollama-local) with `ollama list`, and optionally set the default model.
# Usage: ./ollama-sync.sh [-n] [-d MODEL_OR_ALIAS] [-a NAME=MODEL]... [-r NAME]... [--no-sync]
#   Adds an alias for every Ollama model that has none, removes ollama-local aliases whose model is gone.
#   Existing aliases are kept as-is. The current default model is never removed unless --default replaces it.
#   -d/--default  set model.default (+ provider, base_url) to an alias name or an Ollama model name
#   -a/--alias NAME=MODEL  set an alias (repeatable); MODEL must be an installed Ollama model
#   -r/--remove-alias NAME  remove an alias (repeatable); sync will not re-add it in the same run
#   --no-sync  skip the automatic add/remove, only apply -a/-r/-d
set -euo pipefail

CONTAINER=hermes
PROVIDER=ollama-local
BASE_URL=http://host.containers.internal:11434/v1
HERMES_PY=/opt/hermes/.venv/bin/python

dry=0 default="" no_sync=0 set_aliases="" rm_aliases=""
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) dry=1 ;;
    -d|--default) default="${2:?--default needs a value}"; shift ;;
    -a|--alias)
      [[ "${2:-}" == ?*=?* ]] || { echo "--alias needs NAME=MODEL" >&2; exit 2; }
      set_aliases+="$2"$'\n'; shift ;;
    -r|--remove-alias) rm_aliases+="${2:?--remove-alias needs a name}"$'\n'; shift ;;
    --no-sync|--default-only) no_sync=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[ "$no_sync" = 0 ] || [ -n "$default$set_aliases$rm_aliases" ] || { echo "--no-sync needs -d, -a or -r" >&2; exit 2; }

models=$(ollama list | awk 'NR>1 && $1 != "" {print $1}')
[ -n "$models" ] || { echo "ollama list returned no models" >&2; exit 1; }

podman exec -i -u hermes -e HOME=/opt/data -e HERMES_HOME=/opt/data \
  -e DRY="$dry" -e DEFAULT="$default" -e NO_SYNC="$no_sync" -e SET_ALIASES="$set_aliases" -e RM_ALIASES="$rm_aliases" \
  -e PROVIDER="$PROVIDER" -e BASE_URL="$BASE_URL" -e MODELS="$models" \
  "$CONTAINER" "$HERMES_PY" - <<'PY'
import os, re, sys
from ruamel.yaml import YAML

path = "/opt/data/config.yaml"
yaml = YAML()
yaml.preserve_quotes = True
yaml.width = 4096
yaml.indent(mapping=2, sequence=4, offset=2)
with open(path) as f:
    cfg = yaml.load(f)

provider, base_url = os.environ["PROVIDER"], os.environ["BASE_URL"]
installed = os.environ["MODELS"].split()
aliases = cfg.setdefault("model_aliases", {})
model = cfg["model"]
current = model.get("default")

def slug(name):
    name = re.sub(r":latest$", "", name)
    return re.sub(r"[/:]+", "-", name)

d = os.environ["DEFAULT"]
new_default = (aliases[d]["model"] if d in aliases else d) if d else None
removed = set()

for name in os.environ["RM_ALIASES"].split():
    if name not in aliases:
        sys.exit(f"no such alias: {name!r}")
    removed.add(aliases[name]["model"])
    del aliases[name]
    print(f"- {name} (requested)")

for spec in os.environ["SET_ALIASES"].split():
    name, m = spec.split("=", 1)
    if m not in installed:
        sys.exit(f"{m!r} is not an installed Ollama model")
    aliases[name] = {"model": m, "provider": provider, "base_url": base_url}
    removed.discard(m)
    print(f"= {name} -> {m}")

if os.environ["NO_SYNC"] != "1":
    have = {a["model"]: k for k, a in aliases.items() if a.get("provider") == provider}
    for m in installed:
        if m not in have and m not in removed:
            key = slug(m)
            while key in aliases:
                key += "_"
            aliases[key] = {"model": m, "provider": provider, "base_url": base_url}
            print(f"+ {key} -> {m}")
    for key, a in list(aliases.items()):
        m = a.get("model")
        if a.get("provider") != provider or m in installed:
            continue
        if m == current and new_default != m:
            print(f"! keeping {key} ({m}): it is the current default; pass --default to replace it")
            continue
        del aliases[key]
        print(f"- {key} ({m})")

d = os.environ["DEFAULT"]
if d:
    name = aliases[d]["model"] if d in aliases else d
    if name not in installed:
        sys.exit(f"{d!r} is not an alias or an installed Ollama model")
    model["default"], model["provider"], model["base_url"] = name, provider, base_url
    print(f"default: {current} -> {name}")

if os.environ["DRY"] == "1":
    print("(dry run, nothing written)")
else:
    with open(path, "w") as f:
        yaml.dump(cfg, f)
PY
