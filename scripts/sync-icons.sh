#!/bin/bash
# sync-icons.sh
# Audits icon inventory against stats_definitions.json and regenerates CATALOG.md.
# Icons are stored as the canonical source in style/shared_icons/.
#
# Usage: ./scripts/sync-icons.sh
#        (run from style repo root, or the script finds its own location)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STYLE_ROOT="$(dirname "$SCRIPT_DIR")"
export ICONS_DIR="$STYLE_ROOT/shared_icons"
export CATALOG="$ICONS_DIR/CATALOG.md"

echo "=== doxx.net Icon Audit ==="
echo ""

# --- 1. Fetch stats_definitions.json ---
export STATS_JSON=$(mktemp)
echo "Fetching stats_definitions.json from infra.doxx.net..."
if curl -sf "https://infra.doxx.net/api/v1/stats_definitions" -o "$STATS_JSON" 2>/dev/null; then
    echo "  OK: $(wc -l < "$STATS_JSON" | tr -d ' ') lines"
else
    echo "  WARN: Could not fetch from API. Trying local fallback..."
    # Try to find a local copy in a sibling doxx-www repo
    for candidate in "$STYLE_ROOT/../doxx-www/public/ops/pages/stats_definitions.json" \
                     "$HOME/workspace/doxx/doxx-www/public/ops/pages/stats_definitions.json" \
                     "$HOME/workspace/sessions/doxx-www-dev/public/ops/pages/stats_definitions.json"; do
        if [ -f "$candidate" ]; then
            cp "$candidate" "$STATS_JSON"
            echo "  OK: Using local copy from $candidate"
            break
        fi
    done
fi

if [ ! -s "$STATS_JSON" ]; then
    echo "ERROR: No stats_definitions.json available"
    rm -f "$STATS_JSON"
    exit 1
fi

# --- 2. Audit icon files ---
echo ""
echo "Auditing icon files..."
MISSING=0
FOUND=0
TOTAL=0

# Parse JSON and check each icon path
# Uses python3 for reliable JSON parsing
python3 << 'PYEOF'
import json, os, sys

stats_json = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("STATS_JSON", "")
icons_dir = os.environ.get("ICONS_DIR", "")

with open(stats_json) as f:
    data = json.load(f)

missing = []
found = []

def check_icon(event_type, category, entry):
    path = entry.get("icon_image_dark_theme")
    if not path:
        return
    # Convert web path to local path: /assets/shared_icons/... -> shared_icons/...
    local_path = path.replace("/assets/shared_icons/", "")
    full_path = os.path.join(icons_dir, local_path)
    if os.path.exists(full_path):
        found.append((event_type, category, path, entry))
    else:
        missing.append((event_type, category, path, entry))

for et_key, et_val in data.get("event_types", data).items():
    check_icon(et_key, None, et_val)
    cats = et_val.get("categories")
    if cats:
        for cat_key, cat_val in cats.items():
            check_icon(et_key, cat_key, cat_val)

print(f"  Found: {len(found)} icons")
print(f"  Missing: {len(missing)} icons")
if missing:
    print("")
    for et, cat, path, _ in missing:
        label = f"{et}.{cat}" if cat else et
        print(f"  MISSING: {label} -> {path}")

# Write counts for bash
with open("/tmp/icon_audit_counts.txt", "w") as f:
    f.write(f"{len(found)}\n{len(missing)}\n")
PYEOF

# --- 3. Generate CATALOG.md ---
echo ""
echo "Generating CATALOG.md..."

python3 << 'PYEOF'
import json, os, glob

icons_dir = os.environ.get("ICONS_DIR", "")
catalog_path = os.environ.get("CATALOG", "")
stats_json = os.environ.get("STATS_JSON", "")

with open(stats_json) as f:
    data = json.load(f)

# Build two lookups from stats_definitions:
# 1. icon_path -> metadata (for icons referenced by image path)
# 2. (event_type, category) -> metadata (for ALL categories, including emoji-only)
icon_meta = {}       # keyed by relative icon path
all_categories = {}  # keyed by (event_type, category)

def register(event_type, category, entry):
    meta = {
        "event_type": event_type,
        "category": category,
        "label": entry.get("label", ""),
        "color": entry.get("color_dark_theme", ""),
        "icon_type": entry.get("icon_type", ""),
        "emoji": entry.get("emoji", ""),
    }
    if category:
        all_categories[(event_type, category)] = meta
    path = entry.get("icon_image_dark_theme")
    if path:
        local = path.replace("/assets/shared_icons/", "")
        icon_meta[local] = meta

for et_key, et_val in data.get("event_types", data).items():
    register(et_key, None, et_val)
    cats = et_val.get("categories")
    if cats:
        for cat_key, cat_val in cats.items():
            register(et_key, cat_key, cat_val)

# Discover all icon files (excluding svg/ source directory)
all_icons = sorted(
    glob.glob(os.path.join(icons_dir, "**/*.*"), recursive=True)
)
all_icons = [f for f in all_icons if f.endswith((".png", ".svg")) and "/svg/" not in f]

# Determine source origin for each icon
def get_source(rel_path, full_path):
    """Infer where this icon was originally sourced from."""
    if full_path.endswith(".svg"):
        return "style (created)"
    # PNGs originated from iOS app assets (copied via doxx-www)
    return "iOS"

# Try to match an icon file to stats_definitions metadata by path or by name convention
def get_meta_for_icon(rel_path):
    """Look up stats-defs metadata for an icon, first by path, then by name heuristic."""
    if rel_path in icon_meta:
        return icon_meta[rel_path], True  # (meta, has_stats_ref)
    # Try matching by directory structure: event_types/{et}/categories/{cat}/ or event_types/{et}/{cat}/
    parts = rel_path.replace(os.sep, "/").split("/")
    if len(parts) >= 4 and parts[0] == "event_types":
        et = parts[1]
        cat = parts[-2]  # parent dir of the icon file
        key = (et, cat)
        if key in all_categories:
            return all_categories[key], False  # matched by name, but not referenced by image path
    if len(parts) >= 5 and parts[2] == "categories":
        et = parts[1]
        cat = parts[3]
        key = (et, cat)
        if key in all_categories:
            return all_categories[key], False
    return {}, False

# Group by top-level directory
groups = {}
for icon_path in all_icons:
    rel = os.path.relpath(icon_path, icons_dir)
    parts = rel.split(os.sep)
    group = parts[0] if parts[0] != "event_types" else f"event_types/{parts[1]}" if len(parts) > 1 else parts[0]
    groups.setdefault(group, []).append((rel, icon_path))

# First pass: count stats and build table rows
has_ref_count = 0
no_ref_count = 0
group_lines = {}

for group_name in sorted(groups.keys()):
    items = groups[group_name]
    rows = []
    for rel, full in items:
        name = os.path.splitext(os.path.basename(rel))[0]
        meta, has_ref = get_meta_for_icon(rel)
        et = meta.get("event_type", "")
        cat = meta.get("category", "")
        label = meta.get("label", "")
        color = meta.get("color", "")
        color_badge = f"![](https://img.shields.io/badge/-%20-{color.lstrip('#')})" if color else ""
        source = get_source(rel, full)
        if has_ref:
            stats_badge = "yes"
            has_ref_count += 1
        elif meta:
            stats_badge = "no (emoji)"
            no_ref_count += 1
        else:
            stats_badge = "no"
            no_ref_count += 1
        rows.append(f"| <img src=\"{rel}\" width=\"24\" height=\"24\"> | `{name}` | {et}{('.' + cat) if cat else ''} | {label} | {color_badge} | {stats_badge} | {source} |")
    group_lines[group_name] = rows

# Second pass: emit markdown with summary at top
lines = []
lines.append("# Shared Icons Catalog")
lines.append("")
lines.append("> Auto-generated by `scripts/sync-icons.sh`. Do not edit manually.")
lines.append("")
lines.append(f"**Total icons:** {len(all_icons)}")
lines.append(f"- **{has_ref_count}** referenced in `stats_definitions.json` (icon_type: image)")
lines.append(f"- **{no_ref_count}** not yet referenced (need API update or are generic/utility icons)")
lines.append("")
lines.append("**Columns:**")
lines.append("- **Stats Ref**: whether `stats_definitions.json` has an `icon_image_dark_theme` path pointing to this icon")
lines.append("- **Source**: where the icon file was originally created (`iOS` = from iOS app assets, `style (created)` = SVG created in this repo)")
lines.append("")

for group_name in sorted(group_lines.keys()):
    nice_name = group_name.replace("event_types/", "").replace("_", " ").title()
    lines.append(f"## {nice_name}")
    lines.append("")
    lines.append("| Icon | Name | Event Type | Label | Color | Stats Ref | Source |")
    lines.append("|------|------|------------|-------|-------|-----------|--------|")
    lines.extend(group_lines[group_name])
    lines.append("")

with open(catalog_path, "w") as f:
    f.write("\n".join(lines))

print(f"  Written: {catalog_path} ({len(all_icons)} icons, {has_ref_count} with stats ref, {no_ref_count} without)")
PYEOF

rm -f "$STATS_JSON"
echo ""
echo "Done."
