-- Snap bar: tells the zone picker (omext.zones) when a floating window is being
-- dragged and when it is let go. Hyprland has no event for either, and drags by
-- Omarchy's titlebars never reach mouse bindings (nor does the button's release),
-- so this watches the active window instead: a drag is the window moving along
-- with the pointer (a keyboard snap moves only the window).
--
-- The drop is the button let go of, and only that: a window held still goes
-- nowhere. To tell held from let go of, the watcher asks: once nothing has
-- moved for a moment, it moves the pointer two pixels and back. A window still
-- in hand comes along; one let go of stays, and is dropped.
--
-- Shift held while dragging: the zones over the whole screen, where they are,
-- in place of the snap bar at the top. Let go of before the button, the snap
-- is off: the drag goes on as a plain move.
local TICK = 50      -- ms between looks
local STILL = 250    -- ms at rest after which a drag that was called off is over
local ASK = 150      -- ms without moving before asking
local NUDGE = 2      -- px the pointer is moved to ask
local GONE = 14      -- px the pointer has gone on without the window: let go of

local last, dragging, still = nil, false, 0
local wide = false        -- Shift held: the zones over the whole screen
local away = 0            -- px the pointer has gone on since the window last moved
local cancelled = false   -- this drag was called off: nothing more until it's over
local probe = nil         -- a question asked last tick: { x, y, cx, cy, why }
-- Shift pressed in the middle of a drag: Hyprland lets go of the window at
-- any key (it ends a drag begun by the mouse; the window stops following the
-- pointer, the button still held), and nothing here can take hold of it again.
-- So for a moment after, a window that doesn't follow has not been dropped by
-- you: the drag is called off (no snap). Shift is for before the drag starts.
local resuming = 0        -- looks left of that moment


local function shell(call)
  hl.exec_cmd("omarchy-shell omext.zones " .. call)
end

local function shift_down()
  local ok, a = pcall(hl.is_key_down, "Shift_L")
  local ok2, b = pcall(hl.is_key_down, "Shift_R")
  return (ok and a == true) or (ok2 and b == true)
end

local function pointer_to(x, y)
  pcall(function() hl.dispatch(hl.dsp.cursor.move({ x = x, y = y })) end)
end

local function ask(now, why)
  probe = { x = now.x, y = now.y, cx = math.floor(now.cx + 0.5), cy = math.floor(now.cy + 0.5), why = why }
  pointer_to(probe.cx + NUDGE, probe.cy)
end

local function over()
  dragging, wide, away, still, probe = false, false, 0, 0, nil
end

local function drop()
  if resuming > 0 then
    over()
    resuming, cancelled = 0, true
    shell("dragCancel")
    return
  end
  over()
  shell("dragEnd")
end

-- One watcher, also after a config reload that keeps the Lua state.
if omext_zone_drag then
  pcall(function() omext_zone_drag:set_enabled(false) end)
end
omext_zone_drag = hl.timer(function()
  local win = hl.get_active_window()
  local cursor = hl.get_cursor_pos()
  if not (win and win.floating and cursor) then
    if dragging then drop() end
    last, cancelled, probe = nil, false, nil
    return
  end

  local at = win.at or {}
  local now = { address = win.address, x = at.x or at[1], y = at.y or at[2], cx = cursor.x, cy = cursor.y }

  -- Asked last tick: did the window come along with the pointer?
  if probe then
    local p = probe
    probe = nil
    local came = now.address == win.address and (now.x ~= p.x or now.y ~= p.y)
    pointer_to(p.cx, p.cy)   -- (and back)
    if came then
      still = 0
    else
      if dragging then drop() end
    end
    last = nil   -- (a look to let things settle after the pointer's way back)
    return
  end

  -- Nothing to compare with yet (the first look, or the one after asking).
  if not last then
    last = now
    return
  end
  -- Another window has the focus: whatever was being dragged is done with.
  if last.address ~= now.address then
    if dragging then drop() end
    cancelled, last = false, now
    return
  end

  local dx, dy = now.x - last.x, now.y - last.y
  local moved = dx ~= 0 or dy ~= 0
  local pointer_moved = now.cx ~= last.cx or now.cy ~= last.cy
  -- Along with the pointer, give or take the pointer's fractions.
  local with_pointer = moved and math.abs(dx - (now.cx - last.cx)) < 3 and math.abs(dy - (now.cy - last.cy)) < 3

  if not dragging then
    -- (A drag whose zones were put away with Shift is a plain move from then
    -- on: nothing shows, unless Shift is held again.)
    if with_pointer and (not cancelled or shift_down()) then
      dragging, cancelled, still, away = true, false, 0, 0
      wide = shift_down()
      -- (One call: two would race, and the view asked for could arrive first
      -- and be undone by the start.)
      shell((wide and "dragStartWide " or "dragStart ") .. now.address)
    elseif cancelled and not moved then
      -- A drag called off: over once the window has come to rest.
      still = still + TICK
      if still >= STILL then cancelled, still = false, 0 end
    elseif moved then
      still = 0
    end
  else
    if wide and not shift_down() then
      -- Shift let go of before the button: no snap. The drag goes on as a
      -- plain move (Shift again brings the zones back).
      over()
      cancelled = true
      shell("dragCancel")
      last = now
      return
    elseif not wide and shift_down() then
      wide = true
      shell("dragWide on")
      resuming, away, still = 12, 0, 0
    end
    if resuming > 0 then resuming = resuming - 1 end
    if with_pointer then
      resuming = 0
      still, away = 0, 0
    elseif moved then
      away = 0
    elseif pointer_moved then
      -- The pointer going on without it: let go of. (A pixel or two can pass
      -- before the window catches up: only well away counts.)
      away = away + math.abs(now.cx - last.cx) + math.abs(now.cy - last.cy)
      if away >= GONE then drop() end
    else
      still = still + TICK
      if still >= ASK then
        still = 0
        ask(now, "still")
      end
    end
  end
  last = now
end, { type = "repeat", timeout = TICK })
