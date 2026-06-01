-- PR review queue display for M5StickS3.
-- The worker prepends PR_DATA / PR_COUNT / PR_BEEP (a real table/number/bool)
-- each time the queue changes. When they're absent (standalone / validator)
-- we fall back to sample data so the app still runs.
local data, count, beep
if type(PR_COUNT) == "number" then
  data, count, beep = PR_DATA, PR_COUNT, PR_BEEP
else
  data = {
    { n = 101, t = "Add retry logic to the chunked uploader path", r = "acme/api" },
    { n = 98,  t = "Fix flaky clock test on CI",                   r = "acme/web" },
  }
  count, beep = 2, false
end

local cur = 1

-- A new PR plays a short rising triad (do-mi-sol) instead of one harsh blast.
-- buzzer.beep is fire-and-forget, so we space the notes out across on_tick
-- rather than calling them back-to-back (which would only sound the last).
local FANFARE = { 1047, 1319, 1568 } -- C6, E6, G6
local NOTE_GAP = 120                 -- ms between note onsets
local NOTE_LEN = 95                  -- ms each note rings
local fanfare_t                      -- elapsed ms while playing, nil when idle
local fanfare_i = 0                  -- notes sounded so far

local function start_fanfare()
  fanfare_t = 0
  buzzer.beep(FANFARE[1], NOTE_LEN)
  fanfare_i = 1
end

local function clamp_cur()
  local n = #data
  if n == 0 then
    cur = 1
  elseif cur < 1 then
    cur = n
  elseif cur > n then
    cur = 1
  end
end

-- Break s into up to maxlines slices of perline chars; mark the last with "~"
-- if the string was truncated.
local function wrap(s, perline, maxlines)
  local lines = {}
  local i = 1
  local len = #s
  while i <= len and #lines < maxlines do
    lines[#lines + 1] = string.sub(s, i, i + perline - 1)
    i = i + perline
  end
  if i <= len and #lines > 0 then
    lines[#lines] = string.sub(lines[#lines], 1, perline - 1) .. "~"
  end
  return lines
end

-- A ◕ "eye": a filled circle with one upper quadrant notched out. The TFT has
-- no circle primitive, so fill row-by-row (half-width sqrt(r^2 - dy^2)); on the
-- upper rows we keep only one half, leaving the opposite upper quarter bare.
-- Default notches the upper-left; notch_right notches the upper-right instead.
local function eye(cx, cy, r, red, grn, blu, notch_right)
  for dy = -r, r do
    local dx = math.floor(math.sqrt(r * r - dy * dy) + 0.5)
    if dy < 0 and notch_right then
      screen.fill_rect(cx - dx, cy + dy, dx + 1, 1, red, grn, blu) -- left half only
    elseif dy < 0 then
      screen.fill_rect(cx, cy + dy, dx + 1, 1, red, grn, blu) -- right half only
    else
      screen.fill_rect(cx - dx, cy + dy, dx * 2 + 1, 1, red, grn, blu)
    end
  end
end

-- A 1px outline circle via the midpoint algorithm (8-way symmetry).
local function circle(cx, cy, r, red, grn, blu)
  local x, y, err = r, 0, 1 - r
  while x >= y do
    screen.pixel(cx + x, cy + y, red, grn, blu)
    screen.pixel(cx - x, cy + y, red, grn, blu)
    screen.pixel(cx + x, cy - y, red, grn, blu)
    screen.pixel(cx - x, cy - y, red, grn, blu)
    screen.pixel(cx + y, cy + x, red, grn, blu)
    screen.pixel(cx - y, cy + x, red, grn, blu)
    screen.pixel(cx + y, cy - x, red, grn, blu)
    screen.pixel(cx - y, cy - x, red, grn, blu)
    y = y + 1
    if err < 0 then
      err = err + 2 * y + 1
    else
      x = x - 1
      err = err + 2 * (y - x) + 1
    end
  end
end

-- A ‿-shaped smile: a shallow parabola that dips lowest at the centre and
-- curls up at both ends. Drawn column-by-column, a few px thick.
local function draw_smile(cx, cy, w, depth, red, grn, blu)
  for x = -w, w do
    local t = x / w
    local y = cy + math.floor(depth * (1 - t * t) + 0.5)
    screen.fill_rect(cx + x, y, 2, 3, red, grn, blu)
  end
end

-- ｡◕‿◕｡ — drawn when the review queue is empty: two round eyes, a smile, and
-- a pair of outlined cheeks.
local function draw_face()
  circle(62, 70, 7, 235, 235, 235)         -- left cheek (outline)
  circle(178, 70, 7, 235, 235, 235)        -- right cheek
  eye(90, 54, 14, 235, 235, 235, true)     -- left eye  (notch faces inward, upper-right)
  eye(150, 54, 14, 235, 235, 235)          -- right eye (notch faces inward, upper-left)
  draw_smile(120, 77, 13, 6, 235, 235, 235)
end

local function draw()
  screen.clear()

  if count == 0 then
    -- Empty queue: just a happy little face on black, nothing else.
    draw_face()
    screen.flip()
    return
  end

  -- Header: big count + label.
  screen.text(8, 8, tostring(count), 4, 255, 190, 0)
  local cx = 8 + #tostring(count) * 24 + 12
  screen.text(cx, 10, count == 1 and "PR" or "PRs", 2, 235, 235, 235)
  screen.text(cx, 30, "to review", 1, 170, 170, 170)
  screen.line(0, 52, 240, 52, 70, 70, 70)

  -- Current PR card.
  local pr = data[cur]
  if pr then
    -- Show just the repo name, dropping any "org/" prefix.
    local repo = (pr.r or ""):match("[^/]+$") or ""
    local head = "#" .. tostring(pr.n) .. "  " .. repo
    screen.text(6, 56, string.sub(head, 1, 38), 1, 0, 230, 90)
    local lines = wrap(pr.t, 18, 2)
    for idx = 1, #lines do
      screen.text(6, 52 + idx * 19, lines[idx], 2, 235, 235, 235)
    end
  end

  -- Footer: position, overflow, hint.
  screen.text(6, 118, tostring(cur) .. "/" .. tostring(#data), 1, 150, 150, 150)
  if count > #data then
    screen.text(56, 118, "+" .. tostring(count - #data) .. " more", 1, 150, 150, 150)
  end
  screen.text(150, 118, "BTN0 next", 1, 150, 150, 150)
  screen.flip()
end

function init(ctx)
  clamp_cur()
  if beep then
    start_fanfare()
  end
  draw()
end

function on_tick(ctx, dt_ms)
  if not fanfare_t then return end
  fanfare_t = fanfare_t + dt_ms
  -- note N starts once elapsed time crosses (N-1)*NOTE_GAP
  local want = math.floor(fanfare_t / NOTE_GAP) + 1
  while fanfare_i < want and fanfare_i < #FANFARE do
    fanfare_i = fanfare_i + 1
    buzzer.beep(FANFARE[fanfare_i], NOTE_LEN)
  end
  if fanfare_i >= #FANFARE then
    fanfare_t = nil
  end
end

function on_event(ctx, e)
  if e.name == "button" then
    local n = #data
    if n > 0 then
      if e.index == 0 then
        cur = cur % n + 1
      else
        cur = (cur - 2) % n + 1
      end
      buzzer.beep(660, 40)
      draw()
    end
  end
end
