-- Magnet: a floating window dragged near a screen edge or another window
-- snaps against it, keeping the usual gaps.
hl.config({
  general = {
    snap = {
      enabled = true,
      window_gap = 10,
      monitor_gap = 10,
      border_overlap = false,
      respect_gaps = true,
    },
  },
})
