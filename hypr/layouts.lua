-- Shortcuts for saved layouts: each layout's JSON may carry a "key"
-- (set with `omext-layout key <id> "SUPER + ALT + R"`).
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "."
local tool = here .. "/../bin/omext-layout"
local binds = io.popen(tool .. " binds 2>/dev/null")
if binds then
  for line in binds:lines() do
    local key, id, name = line:match("^([^\t]+)\t([^\t]+)\t(.*)$")
    if key then
      pcall(hl.unbind, key)
      o.bind(key, "Layout: " .. name, tool .. " apply " .. id)
    end
  end
  binds:close()
end
