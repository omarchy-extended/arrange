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

-- A layout that is its screens' own (omext-layout auto) is applied by itself
-- when those screens are the ones connected: as a screen comes or goes, and at
-- login. The tool waits for the change to settle, and runs once at a time.
local function screens_changed() hl.exec_cmd(tool .. " screens") end
hl.on("monitor.added", screens_changed)
hl.on("monitor.removed", screens_changed)
o.exec_on_start(tool .. " screens")
