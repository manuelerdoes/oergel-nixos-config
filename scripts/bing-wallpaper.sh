# Download Bing's "image of the day" and set it as the Noctalia wallpaper.
# Old images are kept in $DIR, so the folder grows into a collection.
set -euo pipefail

DIR="${BING_WALLPAPER_DIR:-$HOME/Pictures/Wallpapers/bing}"
MARKET="${BING_WALLPAPER_MARKET:-en-US}"
mkdir -p "$DIR"

json=$(curl -fsSL "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=$MARKET")
base=$(jq -r '.images[0].urlbase' <<<"$json")   # e.g. /th?id=OHR.SomePlace_EN-US123
date=$(jq -r '.images[0].startdate' <<<"$json") # e.g. 20261103
name=${base##*OHR.}; name=${name%%_*}           # e.g. SomePlace
file="$DIR/$date-$name.jpg"

pending="$DIR/.pending"
if [ ! -s "$file" ]; then
  curl -fsSL -o "$file.part" "https://www.bing.com${base}_UHD.jpg"
  mv "$file.part" "$file"
  echo "$file" >"$pending"
  echo "Downloaded $file"
fi

# Only switch when there is a new image, so a wallpaper you picked by hand
# stays until tomorrow's. If Noctalia isn't running yet, retry on the next run.
if [ -s "$pending" ]; then
  if noctalia msg wallpaper-set "$(cat "$pending")"; then
    rm -f "$pending"
  else
    echo "Noctalia not reachable, will retry"
  fi
fi
