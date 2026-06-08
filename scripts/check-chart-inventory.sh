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

  if ! grep -q "path: $chart_dir$" "$inventory"; then
    echo "$inventory is missing $chart_dir" >&2
    status=1
  fi

  if ! grep -q "name: $name$" "$inventory"; then
    echo "$inventory is missing chart name $name for $chart_dir" >&2
    status=1
  fi

  if ! grep -q "chartVersion: $version$" "$inventory"; then
    echo "$inventory has no chartVersion $version for $chart_dir" >&2
    status=1
  fi
done

inventory_count=$(grep -c '^    - path: charts/' "$inventory")

if [ "$inventory_count" -ne "$chart_count" ]; then
  echo "$inventory has $inventory_count charts but charts/ has $chart_count Chart.yaml files" >&2
  status=1
fi

exit "$status"
