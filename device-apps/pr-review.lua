-- PR review queue display for M5StickS3.
-- The worker prepends PR_DATA / PR_COUNT / PR_BEEP (a real table/number/bool)
-- each time the queue changes. When they're absent (standalone / validator)
-- we fall back to sample data so the app still runs.
local data, count, beep
if type(PR_COUNT) == "number" then
  data, count, beep = PR_DATA, PR_COUNT, PR_BEEP
else
  data = {
    { n = 101, t = "Add retry logic to the chunked uploader path", r = "acme/api", a = "octocat", adds = 260, dels = 32 },
    { n = 98,  t = "Fix flaky clock test on CI",                   r = "acme/web", a = "hubot",   adds = 14,  dels = 9 },
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

-- M5Unified's Speaker keeps the I2S amplifier powered after a tone ends, and an
-- idle amp hisses faintly. We silence it by calling buzzer.stop() a short moment
-- after the last note stops ringing. `clock` accumulates in on_tick; `quiet_at`
-- is when to cut the amp (nil = nothing pending, amp already quiet).
local clock = 0
local quiet_at
local QUIET_GUARD = 60 -- ms of slack after a note before we stop the amp

-- Beep, then (re)arm the silence timer for when this note will have finished.
local function sound(freq, len)
  buzzer.beep(freq, len)
  quiet_at = clock + len + QUIET_GUARD
end

local function start_fanfare()
  fanfare_t = 0
  sound(FANFARE[1], NOTE_LEN)
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

-- Largest text size (capped at maxsize) at which s fits in maxw px. The base
-- font is 6px wide per char at size 1, so a char is 6*size px wide.
local function fit_size(s, maxw, maxsize)
  local n = #s
  if n == 0 then return maxsize end
  local sz = math.floor(maxw / (n * 6))
  if sz > maxsize then sz = maxsize end
  if sz < 1 then sz = 1 end
  return sz
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
      screen.fill_rect(cx, cy + dy, dx + 1, 1, red, grn, blu)      -- right half only
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
  circle(62, 70, 7, 235, 235, 235)     -- left cheek (outline)
  circle(178, 70, 7, 235, 235, 235)    -- right cheek
  eye(90, 54, 14, 235, 235, 235, true) -- left eye  (notch faces inward, upper-right)
  eye(150, 54, 14, 235, 235, 235)      -- right eye (notch faces inward, upper-left)
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

  -- Status column (left): the count headline stacked vertically so it claims a
  -- narrow strip instead of a full-width band. Big number / "PRs" / "to review"
  local SX = 6   -- left padding of the column
  local DIV = 64 -- vertical divider between column + content
  local cn = tostring(count)
  screen.text(SX, 8, cn, #cn >= 3 and 3 or 4, 255, 190, 0)
  screen.text(SX, 48, count == 1 and "PR" or "PRs", 2, 235, 235, 235)
  screen.text(SX, 68, "to review", 1, 170, 170, 170)
  screen.line(DIV, 0, DIV, 135, 70, 70, 70)

  -- Content column (right), stacked: repo, author, big PR number, title.
  local CX = DIV + 8  -- content left edge (72)
  local CW = 240 - CX -- content width (168)
  local pr = data[cur]
  if pr then
    -- Repo (green) and author (cyan) each on their own line above the number.
    local repo = string.sub((pr.r or ""):match("[^/]+$") or "", 1, 26)
    screen.text(CX, 4, repo, 1, 0, 230, 90)
    local author = pr.a or ""
    if author ~= "" then
      screen.text(CX, 16, "@" .. string.sub(author, 1, 12), 2, 255, 140, 0)
    end

    -- Big PR number — the value you type into `gh`. Left-aligned at size 4,
    -- shrinking only if an unusually long number would overflow the column.
    local num = "#" .. tostring(pr.n)
    local nsize = fit_size(num, CW, 4)
    screen.text(CX, 40, num, nsize, 255, 255, 255)

    -- Title: smaller, wrapped to the content width (~28 chars/line).
    local lines = wrap(pr.t, math.floor(CW / 6), 3)
    local ty = 40 + nsize * 8 + 8
    for idx = 1, #lines do
      screen.text(CX, ty + (idx - 1) * 11, lines[idx], 1, 205, 205, 205)
    end
  end

  -- Footer (content column): position, overflow, and the PR's line diff
  -- (+adds in green, -dels in red), right-aligned where the hint used to be.
  screen.text(CX, 124, tostring(cur) .. "/" .. tostring(#data), 1, 150, 150, 150)
  if count > #data then
    screen.text(CX + 42, 124, "+" .. tostring(count - #data) .. " more", 1, 150, 150, 150)
  end
  if pr and (pr.adds or -1) >= 0 and (pr.dels or -1) >= 0 then
    local plus = "+" .. tostring(pr.adds)
    local minus = "-" .. tostring(pr.dels)
    local mx = 240 - #minus * 6     -- minus hugs the right edge
    local px = mx - (#plus + 1) * 6 -- plus sits to its left, one space gap
    screen.text(px, 124, plus, 1, 0, 220, 90)
    screen.text(mx, 124, minus, 1, 235, 60, 60)
  end
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
  clock = clock + dt_ms
  -- Once the last note has finished ringing, power the amp down so it stops
  -- hissing. Runs every tick, independent of whether a fanfare is playing.
  if quiet_at and clock >= quiet_at then
    buzzer.stop()
    quiet_at = nil
  end

  if not fanfare_t then return end
  fanfare_t = fanfare_t + dt_ms
  -- note N starts once elapsed time crosses (N-1)*NOTE_GAP
  local want = math.floor(fanfare_t / NOTE_GAP) + 1
  while fanfare_i < want and fanfare_i < #FANFARE do
    fanfare_i = fanfare_i + 1
    sound(FANFARE[fanfare_i], NOTE_LEN)
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
      sound(660, 40)
      draw()
    end
  end
end
