#!/bin/bash
# Moves every target to the next version, one step per commit:
#   3.x -> 4.0.1; then x.y.z+1 up to x.y.20; x.y.20 -> x.(y+1).0 up to x.9.20; x.9.20 -> (x+1).0.0.
# The build number (CURRENT_PROJECT_VERSION) goes up by one each time.
# Prints the new "version (build)".
set -euo pipefail
proj="$(cd "$(dirname "$0")/.." && pwd)/tvosApp/NuvioTV.xcodeproj/project.pbxproj"
current=$(grep -m1 "MARKETING_VERSION = " "$proj" | sed -E 's/.*= ([0-9.]+);/\1/')
build=$(grep -m1 "CURRENT_PROJECT_VERSION = " "$proj" | sed -E 's/.*= ([0-9]+);/\1/')
IFS=. read -r major minor patch <<< "$current"
patch=${patch:-0}
if [ "$major" -lt 4 ]; then
  major=4; minor=0; patch=1
elif [ "$patch" -lt 20 ]; then
  patch=$((patch + 1))
elif [ "$minor" -lt 9 ]; then
  minor=$((minor + 1)); patch=0
else
  major=$((major + 1)); minor=0; patch=0
fi
next="$major.$minor.$patch"
build=$((build + 1))
sed -i '' -E "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = $next;/; s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $build;/" "$proj"
echo "$next ($build)"
