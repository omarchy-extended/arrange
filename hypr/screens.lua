-- omext arrange: where the screens are, as arranged in the panel (Arrange
-- screens) and kept by omext-screens, per set of screens connected. The rules
-- are in a file of its own, loaded here: after your own monitors.lua, so for
-- the screens it names, its places are the ones in force. When a screen comes
-- or goes the tool looks again (another set of screens: its own arrangement,
-- or none).
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "."
local tool = here .. "/../bin/omext-screens"
local state = os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")
pcall(dofile, state .. "/omext/arrange/screens.lua")
local function screens_changed() hl.exec_cmd(tool .. " apply") end
hl.on("monitor.added", screens_changed)
hl.on("monitor.removed", screens_changed)
