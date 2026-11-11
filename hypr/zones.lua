-- Zones (omext-zone): Super + Shift + arrows move a floating window to the next
-- zone, onto the next screen at the edge; on a tiled window they still swap,
-- as Omarchy has them. Super + Z opens the zone picker for the active window.
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "."
local tool = here .. "/../bin/omext-zone"

for key, dir in pairs({ LEFT = "left", RIGHT = "right", UP = "up", DOWN = "down" }) do
  pcall(hl.unbind, "SUPER + SHIFT + " .. key)
  o.bind("SUPER + SHIFT + " .. key, "Move window to the zone " .. dir, tool .. " move " .. dir)
end

pcall(hl.unbind, "SUPER + Z")
o.bind("SUPER + Z", "Zone picker", tool .. " pick")

-- A zones button on the titlebars Omarchy gives floating windows: a small map of
-- the screen's zones opens at the pointer, and a click puts the window there.
-- The plugin is there only once something has floated this session, and its
-- buttons reset on every config load, so this runs on each load.
if hl.plugin and hl.plugin.hyprbars then
  local colors = {}
  local file = io.open(os.getenv("HOME") .. "/.local/state/omarchy/current/theme/colors.toml", "r")
  if file then
    for line in file:lines() do
      local key, value = line:match('^%s*([%w_]+)%s*=%s*"#(%x%x%x%x%x%x)"')
      if key then
        colors[key] = "rgb(" .. value .. ")"
      end
    end
    file:close()
  end
  -- The same titlebar color Omarchy picks for its buttons.
  local background = colors.background or "rgb(1a1b26)"
  local titlebar = colors.lighter_background
  if not titlebar or titlebar == background then
    titlebar = colors.selection or background
  end
  hl.plugin.hyprbars.add_button({
    bg_color = titlebar,
    fg_color = colors.foreground or "rgb(c0caf5)",
    size = 20,
    icon = "▦",
    action = tool .. " quick --window %WINDOW%",
  })
end
