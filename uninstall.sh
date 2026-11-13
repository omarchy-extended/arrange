#!/bin/bash
# Removes what install.sh added. Your layouts and zone sets (~/.config/omext/)
# stay, for a later install.
set -uo pipefail

bin=$HOME/.local/bin
plugins=$HOME/.config/omarchy/plugins
hypr_conf=$HOME/.config/hypr/hyprland.lua
mark=omext-arrange

omarchy plugin disable omext.arrange >/dev/null 2>&1
omarchy plugin disable omext.zones >/dev/null 2>&1
for f in "$bin/omext-layout" "$bin/omext-zone" "$bin/omext-screens" "$plugins/omext.arrange" "$plugins/omext.zones"; do
  [[ -L $f ]] && rm "$f"
done
[[ -f $hypr_conf ]] && sed -i "/^-- BEGIN $mark\$/,/^-- END $mark\$/d" "$hypr_conf"
hyprctl reload >/dev/null
echo "uninstall: done (your layouts and zones are kept in ${XDG_CONFIG_HOME:-$HOME/.config}/omext/)"
