#!/usr/bin/env sh
set -eu

inventory="charts-index.yaml"

if [ ! -f "$inventory" ]; then
  echo "missing $inventory" >&2
  exit 1
fi

status=0
chart_count=0

for chart_yaml in charts/*/Chart.yaml; do
  [ -f "$chart_yaml" ] || continue

  chart_dir=${chart_yaml%/Chart.yaml}
  chart_count=$((chart_count + 1))

  name=$(awk -F ': *' '$1 == "name" { print $2; exit }' "$chart_yaml")
  version=$(awk -F ': *' '$1 == "version" { print $2; exit }' "$chart_yaml")
  api_version=$(awk -F ': *' '$1 == "apiVersion" { print $2; exit }' "$chart_yaml")

  if [ -z "$name" ] || [ -z "$version" ] || [ -z "$api_version" ]; then
    echo "$chart_yaml is missing apiVersion, name, or version" >&2
    status=1
  fi

  if ! awk \
    -v inventory="$inventory" \
    -v path="$chart_dir" \
    -v name="$name" \
    -v version="$version" '
      BEGIN {
        path_line = "    - path: " path
        name_line = "      name: " name
        version_line = "      chartVersion: " version
      }
      $0 == path_line {
        in_block = 1
        found_path = 1
        next
      }
      in_block && /^    - path: charts\// {
        in_block = 0
      }
      in_block && $0 == name_line {
        found_name = 1
      }
      in_block && $0 == version_line {
        found_version = 1
      }
      END {
        if (!found_path) {
          print inventory " is missing " path > "/dev/stderr"
          exit 1
        }
        if (!found_name) {
          print inventory " has no name " name " in block for " path > "/dev/stderr"
          exit 1
        }
        if (!found_version) {
          print inventory " has no chartVersion " version " in block for " path > "/dev/stderr"
          exit 1
        }
      }
    ' "$inventory"; then
    status=1
  fi
done

inventory_count=$(grep -c '^    - path: charts/' "$inventory")

if [ "$inventory_count" -ne "$chart_count" ]; then
  echo "$inventory has $inventory_count charts but charts/ has $chart_count Chart.yaml files" >&2
  status=1
fi

exit "$status"
