#!/bin/bash
# Installs omext arrange (omarchy-extended) on Omarchy, from this folder: links,
# so a git pull here updates it. Safe to run again. To undo: ./uninstall.sh
set -euo pipefail

dir=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
bin=$HOME/.local/bin
plugins=$HOME/.config/omarchy/plugins
hypr_conf=$HOME/.config/hypr/hyprland.lua
mark=omext-arrange

die() { echo "install: $*" >&2; exit 1; }
info() { echo "install: $*"; }

for cmd in python3 hyprctl omarchy omarchy-shell; do
  command -v "$cmd" >/dev/null || die "needs $cmd (Omarchy, with python)"
done

# omext core (what the omext addons share): installed too when it's missing,
# and brought up to date when it's the copy installed this way.
core=${XDG_DATA_HOME:-$HOME/.local/share}/omext-core
if [[ ! -e $HOME/.config/omarchy/plugins/omext.core ]]; then
  [[ -d $core ]] || git clone -q https://github.com/omarchy-extended/core.git "$core" || die "needs omext core (https://github.com/omarchy-extended/core)"
  "$core/install.sh" >/dev/null || die "omext core's install failed"
elif [[ -d $core/.git && $(readlink -f "$HOME/.config/omarchy/plugins/omext.core") == "$core"/* ]]; then
  git -C "$core" pull -q --ff-only 2>/dev/null || info "couldn't update omext core (run: git -C $core pull)"
fi
[[ -e $HOME/.local/share/omarchy-addons/enabled/arrange ]] && die "arrange is already deployed by omx here"
[[ -f $hypr_conf ]] || die "no $hypr_conf"

link() {  # link <source> <target>: ours, or nothing there yet
  if [[ -e $2 && ! -L $2 ]]; then die "$2 is there already (not a link); move it away first"; fi
  mkdir -p "$(dirname "$2")"
  ln -sfn "$1" "$2"
}
link "$dir/bin/omext-layout" "$bin/omext-layout"
link "$dir/bin/omext-zone" "$bin/omext-zone"
link "$dir/plugins/omext.arrange" "$plugins/omext.arrange"
link "$dir/plugins/omext.zones" "$plugins/omext.zones"

# Hyprland: this folder's hypr/*.lua, loaded at every (re)load, between marks
# (uninstall.sh removes them).
sed -i "/^-- BEGIN $mark\$/,/^-- END $mark\$/d" "$hypr_conf"
{
  echo "-- BEGIN $mark"
  # (By folder, each time Hyprland reads its config: a file added by an update
  # is loaded without installing again.)
  echo "for f in io.popen('ls \"$dir\"/hypr/*.lua 2>/dev/null'):lines() do pcall(dofile, f) end"
  echo "-- END $mark"
} >> "$hypr_conf"
info "loads its Hyprland rules and keys from $hypr_conf"

# The plugins: the zone picker, and the Arrange widget on the bar.
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
sleep 1  # the rescan finishes in the background
conf=$HOME/.config/omarchy/shell.json
grep -q '"omext.zones"' "$conf" 2>/dev/null || omarchy plugin enable omext.zones >/dev/null
grep -q '"omext.arrange"' "$conf" 2>/dev/null || omarchy plugin enable omext.arrange >/dev/null
hyprctl reload >/dev/null
info "done. Arrange is on the bar; Super + Z opens the zone picker."
