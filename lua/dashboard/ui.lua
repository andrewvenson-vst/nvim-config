local github = require 'dashboard.github'
local jira = require 'dashboard.jira'
local seen = require 'dashboard.seen'

local M = {}

local ns = vim.api.nvim_create_namespace 'dashboard'

local state = {
  buf = nil,
  win = nil,
  line_meta = {},
  data = {},
  last_refresh = nil,
  filter = nil,
  last_result_win = nil,
  diff_left_win = nil,
  diff_right_win = nil,
}

local pending_hls = {}
local pending_line_bgs = {}
local pending_sections = {}
local pending_subsections = {}
local current_section_accent = nil
local cursor_ns = vim.api.nvim_create_namespace 'dashboard_cursor'

local open_result_window
local stop_spinner
local emit_pr_header_card
local wrap_text

local PAD = '   '
local BAR = '┃'

local SECTION_ICONS = {
  GitHub = '',
  Notifications = '',
  Jira = '',
  Notes = '',
}

local function setup_hl()
  local function set(name, opts)
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end
  set('DashboardPillWarn', { bg = '#5a4a1c', fg = '#ffe48a' })
  set('DashboardPillInfo', { bg = '#1c3a5a', fg = '#88c8f0' })
  set('DashboardPillError', { bg = '#5a1c1c', fg = '#ff9a9a' })
  set('DashboardPillOk', { bg = '#1c5a2e', fg = '#88e8a0' })
  set('DashboardPillMuted', { bg = '#3a3f4d', fg = '#b0b8c5' })
  set('DashboardPillReview', { bg = '#3a2a5a', fg = '#c8a8ff' })
  set('DashboardPillQA', { bg = '#1c4a5a', fg = '#88e0e8' })
  set('DashboardPillRefinement', { bg = '#4a3a1c', fg = '#e8c890' })
  set('DashboardAccentGithub', { fg = '#88c0e0' })
  set('DashboardAccentNotifs', { fg = '#e0d088' })
  set('DashboardAccentJira', { fg = '#88d090' })
  set('DashboardAccentNotes', { fg = '#e088a0' })
  set('DashboardNormal', { bg = '#12141c' })
  set('DashboardCursorLine', { bg = '#3d4570' })
  set('DashboardFloatBorder', { fg = '#3a3f50', bg = '#12141c' })
  set('DashboardSectionBg', { bg = '#2a3045' })
  set('DashboardCardBg', { bg = '#181c26' })
  set('DashboardCardBgAlt', { bg = '#262d3f' })
  set('DashboardOk', { fg = '#3ddc84', bold = true })
  set('DashboardError', { fg = '#ff5c5c', bold = true })
  set('DashboardDiffAdd', { bg = '#1c6630' })
  set('DashboardDiffDelete', { bg = '#8a2828' })
  set('DashboardDiffLineNr', { fg = '#9aa4b5' })
  set('DashboardDiffLineNrAdd', { fg = '#eaffea', bold = true })
  set('DashboardDiffLineNrDel', { fg = '#ffeaea', bold = true })
  set('DashboardBadgeAlert', { bg = '#c73838', fg = '#ffffff', bold = true })
  set('DashboardBadgeMuted', { bg = '#2a3045', fg = '#7a8090', bold = false })
  set('DashboardWinBar', { bg = '#1c2030', fg = '#9aa4b5' })
  -- Markdown inline groups for ADF-rendered Jira descriptions/comments.
  set('@markup.strong', { bold = true })
  set('@markup.italic', { italic = true })
  set('@markup.raw', { fg = '#e0c890' })
  set('@markup.link.label', { fg = '#88c8f0', underline = true })
end

local SECTION_COLORS = {
  GitHub = 'DashboardAccentGithub',
  Notifications = 'DashboardAccentNotifs',
  Jira = 'DashboardAccentJira',
  Notes = 'DashboardAccentNotes',
}

local function section_color(label)
  for key, color in pairs(SECTION_COLORS) do
    if label == key or label:sub(1, #key + 1) == (key .. ' ') then
      return color
    end
  end
  return '@function'
end

setup_hl()
vim.api.nvim_create_autocmd('ColorScheme', {
  pattern = '*',
  callback = setup_hl,
})

local function section_icon(label)
  for key, icon in pairs(SECTION_ICONS) do
    if label == key or label:sub(1, #key + 1) == (key .. ' ') then
      return icon
    end
  end
  return nil
end

local config = {
  repo_paths = {},
  refresh_after = 60,
  jira_status_order = {
    'In Progress',
    'Peer Review',
    'Needs QA',
    'In QA',
    'Passed QA',
    'Refinement',
  },
}

local function is_dashboard_window(w)
  if not w then
    return false
  end
  if state.win == w then
    return true
  end
  if state.diff_left_win == w or state.diff_right_win == w then
    return true
  end
  if state.viewer_wins then
    for _, vw in ipairs(state.viewer_wins) do
      if vw == w then
        return true
      end
    end
  end
  return false
end

local function setup_focus_handlers()
  local group = vim.api.nvim_create_augroup('DashboardFocus', { clear = true })
  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = function()
      local w = vim.api.nvim_get_current_win()
      if is_dashboard_window(w) then
        state.last_dashboard_win = w
      end
    end,
  })
  vim.api.nvim_create_autocmd('FocusGained', {
    group = group,
    callback = function()
      local w = state.last_dashboard_win
      if w and vim.api.nvim_win_is_valid(w) and is_dashboard_window(w) then
        pcall(vim.api.nvim_set_current_win, w)
      end
    end,
  })
end

local function tmux_navigate(direction)
  if not (vim.env.TMUX and vim.env.TMUX ~= '') then
    return
  end
  vim.system({ 'tmux', 'select-pane', '-' .. direction }, {}, function() end)
end

local function apply_tmux_nav_keymaps(buf)
  local kopts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set('n', '<C-h>', function()
    tmux_navigate 'L'
  end, kopts)
  vim.keymap.set('n', '<C-j>', function()
    tmux_navigate 'D'
  end, kopts)
  vim.keymap.set('n', '<C-k>', function()
    tmux_navigate 'U'
  end, kopts)
  vim.keymap.set('n', '<C-l>', function()
    tmux_navigate 'R'
  end, kopts)
end

function M.setup(opts)
  opts = opts or {}
  setup_focus_handlers()
  if opts.repo_paths then
    config.repo_paths = opts.repo_paths
  end
  if opts.refresh_after then
    config.refresh_after = opts.refresh_after
  end
  if opts.jira_status_order then
    config.jira_status_order = opts.jira_status_order
  end
end

local function in_tmux()
  return vim.env.TMUX ~= nil and vim.env.TMUX ~= ''
end

local function repo_from_url(url)
  if not url then
    return nil
  end
  return url:match 'github%.com/([^/]+/[^/]+)'
end

local function relative_time(iso)
  if not iso then
    return '', 'NonText'
  end
  local y, mo, d, h, mi, s = iso:match '(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)'
  if not y then
    return '', 'NonText'
  end
  local utc_table = {
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
  }
  local as_local = os.time(utc_table)
  local now = os.time()
  local tz_offset = os.difftime(now, os.time(os.date '!*t'))
  local epoch = as_local + tz_offset
  local diff = now - epoch
  local label
  if diff < 60 then
    label = 'now'
  elseif diff < 3600 then
    label = string.format('%dm', math.floor(diff / 60))
  elseif diff < 86400 then
    label = string.format('%dh', math.floor(diff / 3600))
  elseif diff < 7 * 86400 then
    label = string.format('%dd', math.floor(diff / 86400))
  elseif diff < 30 * 86400 then
    label = string.format('%dd', math.floor(diff / 86400))
  elseif diff < 365 * 86400 then
    label = string.format('%dmo', math.floor(diff / (30 * 86400)))
  else
    label = string.format('%dy', math.floor(diff / (365 * 86400)))
  end
  local hl
  if diff < 7 * 86400 then
    hl = 'NonText'
  elseif diff < 30 * 86400 then
    hl = 'DiagnosticWarn'
  else
    hl = 'DashboardError'
  end
  return label, hl
end

local NOTIFICATION_REASON = {
  mention = { label = '@mention', hl = 'DashboardPillInfo' },
  team_mention = { label = 'team @', hl = 'DashboardPillInfo' },
  review_requested = { label = 'review', hl = 'DashboardPillInfo' },
  assign = { label = 'assign', hl = 'DashboardPillInfo' },
  author = { label = 'author', hl = 'DashboardPillMuted' },
  comment = { label = 'comment', hl = 'DashboardPillMuted' },
  subscribed = { label = 'watching', hl = 'DashboardPillMuted' },
  state_change = { label = 'state', hl = 'DashboardPillMuted' },
  security_alert = { label = 'security', hl = 'DashboardPillError' },
  ci_activity = { label = 'ci', hl = 'DashboardPillWarn' },
}

local function notification_reason(reason)
  local entry = NOTIFICATION_REASON[reason]
  if entry then
    return entry.label, entry.hl
  end
  return reason or '?', 'Comment'
end

local function buf_valid()
  return state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

local function compute_dashboard_geom()
  local w = math.min(155, math.floor(vim.o.columns * 0.92))
  local h = math.min(44, math.floor(vim.o.lines * 0.85))
  local statusline = vim.o.laststatus > 0 and 1 or 0
  local avail = vim.o.lines - vim.o.cmdheight - statusline
  return {
    relative = 'editor',
    width = w,
    height = h,
    row = math.floor((avail - h) / 2),
    col = math.floor((vim.o.columns - w) / 2),
  }
end

local function compute_viewer_geom()
  local w = math.min(220, math.floor(vim.o.columns * 0.97))
  local h = math.min(70, math.floor(vim.o.lines * 0.94))
  local statusline = vim.o.laststatus > 0 and 1 or 0
  local avail = vim.o.lines - vim.o.cmdheight - statusline
  return {
    relative = 'editor',
    width = w,
    height = h,
    row = math.floor((avail - h) / 2),
    col = math.floor((vim.o.columns - w) / 2),
  }
end

local function show_loading(text)
  vim.api.nvim_echo({ { text, 'Comment' } }, false, {})
end
local function clear_loading()
  vim.api.nvim_echo({}, false, {})
end

local LEGEND_ITEMS = {
  { key = '1', label = 'Notes', target = 'Notes' },
  { key = '2', label = 'GitHub', target = 'GitHub' },
  { key = '3', label = 'Notifications', target = 'Notifications' },
  { key = '4', label = 'Jira', target = 'Jira' },
}

local function hide_dashboard()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    if state.win == vim.api.nvim_get_current_win() then
      state.dashboard_cursor = vim.api.nvim_win_get_cursor(state.win)
    end
    pcall(vim.api.nvim_win_close, state.win, true)
    state.win = nil
  end
end

local function restore_dashboard()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_set_current_win, state.win)
    return
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    M.open()
  end
end

local function on_viewer_open(win)
  state.viewer_wins = state.viewer_wins or {}
  if win then
    table.insert(state.viewer_wins, win)
  end
  if #state.viewer_wins == 1 then
    hide_dashboard()
  end
end

local function on_viewer_close(win)
  if not state.viewer_wins then
    state.viewer_wins = {}
  end
  if win then
    for i, w in ipairs(state.viewer_wins) do
      if w == win then
        table.remove(state.viewer_wins, i)
        break
      end
    end
  end
  if state.suppress_restore then
    return
  end
  vim.schedule(function()
    if state.suppress_restore then
      return
    end
    if #(state.viewer_wins or {}) == 0 then
      restore_dashboard()
    end
  end)
end

local function refocus_dashboard(win)
  on_viewer_close(win)
end

local function close_all_viewers()
  state.suppress_restore = true
  local wins = state.viewer_wins or {}
  state.viewer_wins = {}
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  state.suppress_restore = false
end

local function emit(lines, segments)
  local text = ''
  local cols = {}
  for _, seg in ipairs(segments) do
    local clean = (seg.text or ''):gsub('[\r\n]', ' ')
    cols[#cols + 1] = { col_start = #text, col_end = #text + #clean, hl = seg.hl }
    text = text .. clean
  end
  table.insert(lines, text)
  return #lines - 1, cols
end

local function paint(line_idx, cols)
  for _, c in ipairs(cols) do
    if c.hl then
      table.insert(pending_hls, { line = line_idx, col_start = c.col_start, col_end = c.col_end, group = c.hl })
    end
  end
end

local function flush_hls()
  for _, h in ipairs(pending_hls) do
    vim.api.nvim_buf_set_extmark(state.buf, ns, h.line, h.col_start, {
      end_col = h.col_end,
      hl_group = h.group,
      priority = 100,
    })
  end
  pending_hls = {}
  for _, h in ipairs(pending_line_bgs) do
    vim.api.nvim_buf_set_extmark(state.buf, ns, h.line, 0, {
      line_hl_group = h.hl,
      priority = 100,
    })
  end
  pending_line_bgs = {}
end

local function emit_blank(lines)
  table.insert(lines, '')
end

local function emit_divider(lines, label)
  local section, suffix = label:match '^(.-) · (.*)$'
  if not section then
    section = label
    suffix = nil
  end
  emit_blank(lines)
  local accent = section_color(label)
  current_section_accent = accent
  local win_w = (state.win and vim.api.nvim_win_is_valid(state.win)) and vim.api.nvim_win_get_width(state.win) or 140
  local rule_idx, rule_cols = emit(lines, {
    { text = ' ', hl = nil },
    { text = string.rep('─', math.max(10, win_w - 2)), hl = accent },
  })
  paint(rule_idx, rule_cols)

  local icon = vim.g.have_nerd_font and section_icon(label) or nil
  local segments = {
    { text = ' ', hl = nil },
    { text = '▎  ', hl = accent },
  }
  if icon then
    table.insert(segments, { text = icon, hl = accent })
    table.insert(segments, { text = '   ', hl = nil })
  end
  table.insert(segments, { text = section:upper(), hl = 'Title' })
  if suffix then
    table.insert(segments, { text = '   ' .. suffix, hl = 'Comment' })
  end
  local idx, cols = emit(lines, segments)
  paint(idx, cols)
  table.insert(pending_line_bgs, { line = idx, hl = 'DashboardSectionBg' })
  table.insert(pending_sections, idx)
  if state.section_lines then
    state.section_lines[label] = idx
  end
end

local function emit_subhead(lines, title, count, pill_hl, collapsed)
  local count_str = count and tostring(count) or ''
  local segments = { { text = '  ', hl = nil } }
  if collapsed ~= nil then
    local arrow = collapsed and '▸' or '▾'
    table.insert(segments, { text = arrow .. ' ', hl = 'DashboardAccentGithub' })
  end
  if pill_hl then
    local inner = count_str ~= '' and (count_str .. '  ' .. title) or title
    table.insert(segments, { text = ' ' .. inner .. ' ', hl = pill_hl })
  else
    if count_str ~= '' then
      table.insert(segments, { text = count_str .. '  ', hl = '@number' })
    end
    table.insert(segments, { text = title, hl = '@keyword' })
  end
  local idx, cols = emit(lines, segments)
  paint(idx, cols)
  table.insert(pending_subsections, idx)
  if state.section_lines then
    state.section_lines[title] = idx
  end
  return idx
end

local SPINNER_FRAMES = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local spinner_state = { timer = nil, frame_i = 1 }

local function emit_status(lines, kind, text)
  local hl = kind == 'loading' and 'Comment' or kind == 'error' and 'DashboardError' or 'Comment'
  local prefix
  if kind == 'loading' then
    prefix = SPINNER_FRAMES[spinner_state.frame_i]
  elseif kind == 'error' then
    prefix = '✗'
  else
    prefix = '·'
  end
  local idx, cols = emit(lines, {
    { text = '    ', hl = nil },
    { text = prefix .. ' ', hl = hl },
    { text = text, hl = hl },
  })
  paint(idx, cols)
end

local function pad_right(s, n)
  if #s >= n then
    return s:sub(1, n - 1) .. '…'
  end
  return s .. string.rep(' ', n - #s)
end

local function matches_filter(text, filter)
  if not filter or filter == '' then
    return true
  end
  if not text or text == '' then
    return false
  end
  return tostring(text):lower():find(filter:lower(), 1, true) ~= nil
end

local function pr_matches(pr, filter)
  if not filter or filter == '' then
    return true
  end
  return matches_filter(pr.title, filter)
    or matches_filter(pr.body, filter)
    or matches_filter('#' .. tostring(pr.number), filter)
    or matches_filter(pr.repository and pr.repository.nameWithOwner or '', filter)
end

local function issue_matches(issue, filter)
  if not filter or filter == '' then
    return true
  end
  return matches_filter(issue.key, filter)
    or matches_filter(issue.summary, filter)
    or matches_filter(issue.qa_assignee, filter)
    or matches_filter(issue.status, filter)
end

local function notification_matches(n, filter)
  if not filter or filter == '' then
    return true
  end
  return matches_filter(n.title, filter)
    or matches_filter(n.repo, filter)
    or matches_filter(n.reason, filter)
end

local function filter_list(items, predicate)
  if type(items) ~= 'table' or not predicate then
    return items
  end
  local out = {}
  for _, it in ipairs(items) do
    if predicate(it) then
      table.insert(out, it)
    end
  end
  return out
end

local function sort_prs_by_repo(prs)
  if type(prs) ~= 'table' then
    return prs
  end
  table.sort(prs, function(a, b)
    local ra = (a.repository and a.repository.nameWithOwner) or ''
    local rb = (b.repository and b.repository.nameWithOwner) or ''
    if ra == rb then
      return (a.number or 0) < (b.number or 0)
    end
    return ra < rb
  end)
  return prs
end

local function contains_key(text, key)
  if not text or text == '' then
    return false
  end
  text = text:upper()
  key = key:upper()
  local start = 1
  while true do
    local i, j = text:find(key, start, true)
    if not i then
      return false
    end
    local before = i > 1 and text:sub(i - 1, i - 1) or ''
    local after = j < #text and text:sub(j + 1, j + 1) or ''
    if not before:match '%w' and not after:match '%w' then
      return true
    end
    start = j + 1
  end
end

local function all_known_prs()
  local seen = {}
  local out = {}
  local function ingest(list)
    if type(list) ~= 'table' then
      return
    end
    for _, pr in ipairs(list) do
      if pr.url and not seen[pr.url] then
        seen[pr.url] = true
        table.insert(out, pr)
      end
    end
  end
  ingest(state.data.my_prs)
  ingest(state.data.reviews)
  ingest(state.data.tagged)
  return out
end

local function related_prs(issue_key, prs)
  local matches = {}
  for _, pr in ipairs(prs) do
    if contains_key(pr.title, issue_key) or contains_key(pr.body, issue_key) then
      table.insert(matches, pr)
    end
  end
  table.sort(matches, function(a, b)
    local ra = (a.repository and a.repository.nameWithOwner) or ''
    local rb = (b.repository and b.repository.nameWithOwner) or ''
    return ra < rb
  end)
  return matches
end

local function ci_badge(status)
  if status == 'SUCCESS' then
    return '✓', 'DashboardOk'
  end
  if status == 'FAILURE' or status == 'ERROR' then
    return '✗', 'DashboardError'
  end
  if status == 'PENDING' or status == 'EXPECTED' then
    return '●', 'DiagnosticWarn'
  end
  return '·', 'NonText'
end

local function review_badge(decision, approvals)
  if decision == 'CHANGES_REQUESTED' then
    return '✗', 'DashboardError'
  end
  approvals = approvals or 0
  if approvals >= 2 then
    return '✓', 'DashboardOk'
  end
  if approvals == 1 then
    return '◐', 'DiagnosticWarn'
  end
  if decision == 'REVIEW_REQUIRED' then
    return '○', 'DiagnosticWarn'
  end
  return '·', 'NonText'
end

local function jira_status_hl(status)
  local s = (status or ''):lower()
  if s:find 'progress' then
    return 'DiagnosticWarn'
  end
  if s:find 'review' then
    return 'DiagnosticInfo'
  end
  if s:find 'block' or s:find 'impedi' then
    return 'DashboardError'
  end
  if s:find 'done' or s:find 'closed' or s:find 'resolved' then
    return 'DashboardOk'
  end
  if s:find 'todo' or s:find 'to do' or s:find 'backlog' or s:find 'open' then
    return 'Comment'
  end
  return '@constant'
end

local function jira_status_pill(status)
  local s = (status or ''):lower()
  if s:find 'passed' then
    return 'DashboardPillOk'
  end
  if s:find 'progress' then
    return 'DashboardPillWarn'
  end
  if s:find 'peer review' or s:find 'code review' then
    return 'DashboardPillReview'
  end
  if s:find 'qa' then
    return 'DashboardPillQA'
  end
  if s:find 'refinement' then
    return 'DashboardPillRefinement'
  end
  if s:find 'block' or s:find 'impedi' or s:find 'hold' then
    return 'DashboardPillError'
  end
  if s:find 'done' or s:find 'closed' or s:find 'resolved' then
    return 'DashboardPillOk'
  end
  return 'DashboardPillMuted'
end

local SECTION_COLLAPSE_DEFAULT = {
  ['My PRs'] = true,
  ['Awaiting my review'] = true,
  ['Tagged in'] = true,
}

local SECTION_LEVEL_COLLAPSE_DEFAULT = {
  ['In Progress'] = true,
  ['Peer Review'] = true,
  ['Needs QA'] = true,
  ['In QA'] = true,
  ['Passed QA'] = true,
  ['Refinement'] = true,
  ['Other'] = true,
  ['Developer Verify'] = true,
}

local function is_section_collapsed(title)
  state.collapsed_sections = state.collapsed_sections or {}
  local explicit = state.collapsed_sections[title]
  if explicit ~= nil then
    return explicit
  end
  return SECTION_LEVEL_COLLAPSE_DEFAULT[title] or false
end

local function toggle_section_collapsed(title)
  state.collapsed_sections = state.collapsed_sections or {}
  state.collapsed_sections[title] = not is_section_collapsed(title)
end

local function is_repo_collapsed(section, repo)
  state.collapsed_repos = state.collapsed_repos or {}
  state.collapsed_repos[section] = state.collapsed_repos[section] or {}
  local explicit = state.collapsed_repos[section][repo]
  if explicit ~= nil then
    return explicit
  end
  return SECTION_COLLAPSE_DEFAULT[section] or false
end

local function toggle_repo_collapsed(section, repo)
  state.collapsed_repos = state.collapsed_repos or {}
  state.collapsed_repos[section] = state.collapsed_repos[section] or {}
  state.collapsed_repos[section][repo] = not is_repo_collapsed(section, repo)
end

local function emit_repo_header(lines, meta, section, name, count, collapsed)
  local arrow = collapsed and '▸' or '▾'
  local idx, cols = emit(lines, {
    { text = '    ', hl = nil },
    { text = arrow .. ' ', hl = 'DashboardAccentGithub' },
    { text = tostring(count) .. '  ', hl = '@number' },
    { text = name, hl = '@string' },
  })
  paint(idx, cols)
  meta[idx + 1] = { kind = 'pr_repo_header', section = section, repo = name }
end

local function emit_pr(lines, meta, pr, opts)
  opts = opts or {}
  local repo = (pr.repository and pr.repository.nameWithOwner) or '?'
  local num = '#' .. tostring(pr.number)
  local ci_glyph, ci_hl = ci_badge(pr.ciStatus)
  local rv_glyph, rv_hl = review_badge(pr.reviewDecision, pr.approvalCount)
  local age_label, age_hl = relative_time(pr.updatedAt)
  local short_repo = repo:match '/(.+)$' or repo
  local is_draft = opts.draft and pr.isDraft

  local indent = opts.deep_indent and '      ' or '    '
  local prefix_w = vim.fn.strdisplaywidth(indent) + 1 + 1 + 1 + 2
  local draft_w = is_draft and 9 or 0
  local win_w = (state.win and vim.api.nvim_win_is_valid(state.win)) and vim.api.nvim_win_get_width(state.win) or 140

  local repo_text = opts.skip_repo and num or (short_repo .. num)
  local meta_w = 5 + vim.fn.strdisplaywidth(repo_text) + 5 + vim.fn.strdisplaywidth(age_label or '')

  local title = pr.title or ''
  local title_max = win_w - prefix_w - meta_w - draft_w - 3
  if title_max < 20 then
    title_max = 20
  end
  if vim.fn.strdisplaywidth(title) > title_max then
    title = title:sub(1, title_max - 1) .. '…'
  end

  local segments = {
    { text = indent, hl = nil },
    { text = ci_glyph, hl = ci_hl },
    { text = ' ', hl = nil },
    { text = rv_glyph, hl = rv_hl },
    { text = '  ', hl = nil },
    { text = title, hl = 'Normal' },
    { text = '  ·  ', hl = 'NonText' },
    { text = repo_text, hl = 'Comment' },
    { text = '  ·  ', hl = 'NonText' },
    { text = age_label, hl = age_hl },
  }
  if is_draft then
    table.insert(segments, { text = '  ', hl = nil })
    table.insert(segments, { text = ' draft ', hl = 'DashboardPillMuted' })
  end

  local idx, cols = emit(lines, segments)
  paint(idx, cols)
  meta[idx + 1] = { url = pr.url, pr = { number = pr.number, repo = repo }, kind = 'pr' }

  if pr.unresolvedThreads and pr.unresolvedThreads > 0 then
    local sidx, scols = emit(lines, {
      { text = '       ┊ ', hl = 'NonText' },
      { text = ' ' .. tostring(pr.unresolvedThreads) .. ' unresolved ', hl = 'DashboardPillWarn' },
    })
    paint(sidx, scols)
  end
end

local function emit_issue(lines, meta, issue, opts)
  opts = opts or {}
  local QA_SECTIONS = { ['Needs QA'] = true, ['In QA'] = true, ['Passed QA'] = true }
  local show_qa = QA_SECTIONS[opts.section_status or ''] or opts.show_status

  local indent = '    '
  local key_padded = pad_right(issue.key, 13)
  local title = issue.summary or ''

  local segments = {
    { text = indent, hl = nil },
    { text = key_padded, hl = '@number' },
    { text = '  ', hl = nil },
    { text = title, hl = 'Normal' },
  }

  if issue.status_change_at then
    local age_label, age_hl = relative_time(issue.status_change_at)
    if age_label and age_label ~= '' then
      table.insert(segments, { text = '  ·  ', hl = 'NonText' })
      table.insert(segments, { text = age_label, hl = age_hl })
    end
  end

  if issue.comment_count and issue.comment_count > 0 then
    local glyph = vim.g.have_nerd_font and '' or 'c'
    table.insert(segments, { text = '  ·  ', hl = 'NonText' })
    table.insert(segments, { text = tostring(issue.comment_count) .. ' ' .. glyph, hl = 'Comment' })
  end

  if opts.show_status then
    local pill_hl = jira_status_pill(issue.status)
    table.insert(segments, { text = '  ', hl = nil })
    table.insert(segments, { text = ' ' .. (issue.status or '?') .. ' ', hl = pill_hl })
  end

  if show_qa and issue.qa_assignee then
    table.insert(segments, { text = '  ', hl = nil })
    table.insert(segments, { text = ' QA: ' .. issue.qa_assignee .. ' ', hl = 'DashboardPillInfo' })
  end

  local idx, cols = emit(lines, segments)
  paint(idx, cols)
  meta[idx + 1] = { url = issue.url, kind = 'jira', key = issue.key }

  local matches = related_prs(issue.key, opts.pr_pool or {})
  for _, pr in ipairs(matches) do
    local repo = (pr.repository and pr.repository.nameWithOwner) or '?'
    local short = repo:match '/(.+)$' or repo
    local repo_num = short .. '#' .. pr.number
    local sub_idx, sub_cols = emit(lines, {
      { text = '       ', hl = nil },
      { text = '↳ ', hl = 'NonText' },
      { text = repo_num, hl = '@string' },
    })
    paint(sub_idx, sub_cols)
    meta[sub_idx + 1] = { url = pr.url, pr = { number = pr.number, repo = repo }, kind = 'pr' }
  end
end

local function emit_notification(lines, meta, n)
  local label, hl = notification_reason(n.reason)
  local age_label, age_hl = relative_time(n.updated_at)
  local pill_text = ' ' .. label .. ' '
  local pill_w = 14
  local pill_pad = pill_w - #pill_text
  if pill_pad < 1 then
    pill_pad = 1
  end
  local idx, cols = emit(lines, {
    { text = '    ', hl = nil },
    { text = pill_text, hl = hl },
    { text = string.rep(' ', pill_pad), hl = nil },
    { text = pad_right(n.repo or '?', 30), hl = 'Comment' },
    { text = string.format('%5s', age_label), hl = age_hl },
    { text = '  ', hl = nil },
    { text = n.title or '', hl = 'Normal' },
  })
  paint(idx, cols)
  local pr_meta = nil
  if n.type == 'PullRequest' then
    local repo = repo_from_url(n.url)
    local pr_num = n.url and tonumber(n.url:match '/pull/(%d+)$') or nil
    if repo and pr_num then
      pr_meta = { number = pr_num, repo = repo }
    end
  end
  meta[idx + 1] = {
    url = n.url,
    pr = pr_meta,
    notification_id = n.id,
    kind = pr_meta and 'pr' or nil,
  }
  if n.comment_author and n.comment_body and n.comment_body ~= '' then
    local snippet = n.comment_body:gsub('\r', ''):gsub('\n+', ' ⏎ '):gsub('%s+', ' ')
    snippet = vim.trim(snippet)
    local win_w = (state.win and vim.api.nvim_win_is_valid(state.win)) and vim.api.nvim_win_get_width(state.win) or 140
    local prefix_w = 21
    local author_w = vim.fn.strdisplaywidth(n.comment_author)
    local max_snippet = math.max(40, win_w - prefix_w - author_w - 6)
    if vim.fn.strdisplaywidth(snippet) > max_snippet then
      snippet = snippet:sub(1, max_snippet - 1) .. '…'
    end
    local sub_idx, sub_cols = emit(lines, {
      { text = '              ┊ ', hl = 'NonText' },
      { text = '💬 ', hl = 'Comment' },
      { text = n.comment_author, hl = 'Title' },
      { text = '  ', hl = nil },
      { text = snippet, hl = 'Comment' },
    })
    paint(sub_idx, sub_cols)
    meta[sub_idx + 1] = meta[idx + 1]
  end
end

local function emit_jira_activity(lines, meta, items)
  local count = (type(items) == 'table') and #items or 0
  local latest_key, latest_age = '', ''
  local latest_age_hl = 'Comment'
  if count > 0 then
    local first = items[1]
    latest_key = first.key or '?'
    local age, hl = relative_time(first.status_change_at or first.updated)
    latest_age = age or ''
    latest_age_hl = hl or 'Comment'
  end
  local pill_text = ' ' .. tostring(count) .. ' '
  local label_text = count == 1 and ' recent update' or ' recent updates'
  local segments = {
    { text = '    ', hl = nil },
    { text = pill_text, hl = 'DashboardPillInfo' },
    { text = label_text, hl = 'Normal' },
  }
  if count > 0 then
    table.insert(segments, { text = '  ·  ', hl = 'NonText' })
    table.insert(segments, { text = 'latest ', hl = 'Comment' })
    table.insert(segments, { text = latest_key, hl = 'Title' })
    table.insert(segments, { text = '  ', hl = nil })
    table.insert(segments, { text = latest_age, hl = latest_age_hl })
  end
  local idx, cols = emit(lines, segments)
  paint(idx, cols)
  meta[idx + 1] = {
    kind = 'jira_activity_summary',
    items = items,
  }
end

local function subsection_box(lines, kind)
  if not current_section_accent then
    return
  end
  local win_w = (state.win and vim.api.nvim_win_is_valid(state.win)) and vim.api.nvim_win_get_width(state.win) or 140
  local box_w = math.max(10, win_w - 4)
  local chars = kind == 'top' and ('╭' .. string.rep('─', box_w) .. '╮') or ('╰' .. string.rep('─', box_w) .. '╯')
  local idx, cols = emit(lines, {
    { text = ' ', hl = nil },
    { text = chars, hl = current_section_accent },
  })
  paint(idx, cols)
end

local function emit_section(lines, meta, title, items, emit_item, empty_label, opts)
  opts = opts or {}
  local count = type(items) == 'table' and #items or nil
  local collapsible = opts.collapsible and type(items) == 'table' and #items > 0
  local collapsed = collapsible and is_section_collapsed(title) or false
  subsection_box(lines, 'top')
  local subhead_idx = emit_subhead(lines, title, count, opts.pill_hl, collapsible and collapsed or nil)
  if collapsible then
    meta[subhead_idx + 1] = { kind = 'jira_section_header', title = title }
  end
  if items == nil then
    emit_status(lines, 'loading', 'Loading…')
  elseif items == false then
    emit_status(lines, 'error', 'Failed to load')
  elseif type(items) == 'string' then
    emit_status(lines, 'error', items)
  elseif #items == 0 then
    emit_status(lines, 'empty', empty_label or 'Nothing here')
  elseif not collapsed then
    for _, item in ipairs(items) do
      emit_item(lines, meta, item)
    end
  end
  subsection_box(lines, 'bottom')
  emit_blank(lines)
end

local function emit_segments(lines, segments)
  local idx, cols = emit(lines, segments)
  paint(idx, cols)
  return idx
end

local function emit_pr_section(lines, meta, title, prs, empty_label, pr_opts)
  local count = type(prs) == 'table' and #prs or nil
  subsection_box(lines, 'top')
  emit_subhead(lines, title, count, 'DashboardPillInfo')
  if prs == nil then
    emit_status(lines, 'loading', 'Loading…')
  elseif prs == false then
    emit_status(lines, 'error', 'Failed to load')
  elseif type(prs) == 'string' then
    emit_status(lines, 'error', prs)
  elseif #prs == 0 then
    emit_status(lines, 'empty', empty_label or 'Nothing here')
  else
    local groups = {}
    local order = {}
    for _, pr in ipairs(prs) do
      local repo = (pr.repository and pr.repository.nameWithOwner) or '?'
      local short = repo:match '/(.+)$' or repo
      if not groups[short] then
        groups[short] = {}
        table.insert(order, short)
      end
      table.insert(groups[short], pr)
    end
    for i, repo_name in ipairs(order) do
      if i > 1 then
        emit_blank(lines)
      end
      local collapsed = is_repo_collapsed(title, repo_name)
      emit_repo_header(lines, meta, title, repo_name, #groups[repo_name], collapsed)
      if not collapsed then
        for _, pr in ipairs(groups[repo_name]) do
          local pr_inner_opts = { skip_repo = true, deep_indent = true }
          if pr_opts then
            for k, v in pairs(pr_opts) do
              pr_inner_opts[k] = v
            end
          end
          emit_pr(lines, meta, pr, pr_inner_opts)
        end
      end
    end
  end
  subsection_box(lines, 'bottom')
  emit_blank(lines)
end

local function emit_legend(lines, segments)
  local prefixed = { { text = '  ', hl = nil } }
  for _, s in ipairs(segments) do
    table.insert(prefixed, s)
  end
  emit_segments(lines, prefixed)
end

local OPEN_BR = { text = '[ ', hl = 'NonText' }
local CLOSE_BR = { text = ' ]', hl = 'NonText' }
local GAP = { text = '   ', hl = nil }

local function count_unread_notifications()
  local n = state.data.notifications
  if type(n) ~= 'table' then
    return nil
  end
  local c = 0
  for _, it in ipairs(n) do
    if it.unread then
      c = c + 1
    end
  end
  return c
end

local function latest_author_of(item)
  local c = item.latest_comment_created or ''
  local h = item.latest_change_created or ''
  if c == '' and h == '' then
    return nil
  end
  if c >= h then
    return item.latest_comment_author_id, item.latest_comment_author
  end
  return item.latest_change_author_id, item.latest_change_author
end

local function filtered_jira_recent()
  local j = state.data.jira_activity
  if type(j) ~= 'table' then
    return j
  end
  local me_id = state.me_account_id
  local out = {}
  for _, item in ipairs(j) do
    local drop = false
    if seen.is_seen(item.key, item.updated_at) then
      drop = true
    end
    if not drop and me_id then
      local author_id = latest_author_of(item)
      if author_id and author_id == me_id then
        drop = true
      end
    end
    if not drop then
      table.insert(out, item)
    end
  end
  return out
end

local function count_jira_recent()
  local j = filtered_jira_recent()
  if type(j) ~= 'table' then
    return nil
  end
  return #j
end

local function count_reviews()
  local r = state.data.reviews
  if type(r) ~= 'table' then
    return nil
  end
  return #r
end

local function count_passed_qa()
  local j = state.data.jira_active
  if type(j) ~= 'table' then
    return nil
  end
  local c = 0
  for _, issue in ipairs(j) do
    if issue.status == 'Passed QA' then
      c = c + 1
    end
  end
  return c
end

local function count_developer_verify()
  local j = state.data.qa_active
  if type(j) ~= 'table' then
    return nil
  end
  return #j
end

function M.winbar()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return ''
  end
  local items = {
    { 'GH Inbox', count_unread_notifications() },
    { 'Jira Inbox', count_jira_recent() },
    { 'Passed QA', count_passed_qa() },
    { 'Review', count_reviews() },
    { 'Verify', count_developer_verify() },
  }
  local parts = {}
  for _, it in ipairs(items) do
    local hl = (it[2] and it[2] > 0) and 'DashboardBadgeAlert' or 'DashboardBadgeMuted'
    local count = it[2] == nil and '…' or tostring(it[2])
    table.insert(parts, '%#' .. hl .. '# ' .. it[1] .. '  ' .. count .. ' %#DashboardWinBar#')
  end
  return '%#DashboardWinBar#  ' .. table.concat(parts, '   ') .. '  '
end

local function badge_segments(label, count)
  local hl = (count and count > 0) and 'DashboardBadgeAlert' or 'DashboardBadgeMuted'
  local display = count == nil and '…' or tostring(count)
  return {
    { text = ' ' .. label .. ' ', hl = hl },
    { text = ' ' .. display .. ' ', hl = hl },
  }
end

local function emit_header(lines)
  emit_segments(lines, { { text = '  ★  Status Dashboard', hl = 'Title' } })
  emit_segments(lines, {
    { text = '  ', hl = nil },
    { text = 'g?', hl = '@keyword' },
    { text = ' keymaps', hl = 'Comment' },
  })
  if state.filter and state.filter ~= '' then
    emit_segments(lines, {
      { text = '  ', hl = nil },
      { text = 'filter: ', hl = 'Comment' },
      { text = state.filter, hl = '@string' },
    })
  end
  emit_blank(lines)
end

local function emit_github_legend(lines)
  emit_legend(lines, {
    OPEN_BR,
    { text = 'CI: ', hl = 'Comment' },
    { text = '✓', hl = 'DashboardOk' },
    { text = ' pass · ', hl = 'Comment' },
    { text = '✗', hl = 'DashboardError' },
    { text = ' fail · ', hl = 'Comment' },
    { text = '●', hl = 'DiagnosticWarn' },
    { text = ' pending', hl = 'Comment' },
    CLOSE_BR,
    GAP,
    OPEN_BR,
    { text = 'Review: ', hl = 'Comment' },
    { text = '✓', hl = 'DashboardOk' },
    { text = ' 2+ · ', hl = 'Comment' },
    { text = '◐', hl = 'DiagnosticWarn' },
    { text = ' 1 · ', hl = 'Comment' },
    { text = '○', hl = 'DiagnosticWarn' },
    { text = ' 0 · ', hl = 'Comment' },
    { text = '✗', hl = 'DashboardError' },
    { text = ' changes', hl = 'Comment' },
    CLOSE_BR,
    GAP,
    OPEN_BR,
    { text = 'c', hl = '@keyword' },
    { text = ' checkout · ', hl = 'Comment' },
    { text = 'i', hl = '@keyword' },
    { text = ' claude · ', hl = 'Comment' },
    { text = 'D', hl = '@keyword' },
    { text = ' diff · ', hl = 'Comment' },
    { text = 't', hl = '@keyword' },
    { text = ' threads · ', hl = 'Comment' },
    { text = 's', hl = '@keyword' },
    { text = ' summary · ', hl = 'Comment' },
    { text = '?', hl = '@keyword' },
    { text = ' prompts', hl = 'Comment' },
    CLOSE_BR,
  })
end

local function emit_notifications_legend(lines)
  emit_legend(lines, {
    OPEN_BR,
    { text = 'x', hl = '@keyword' },
    { text = ' mark read', hl = 'Comment' },
    CLOSE_BR,
  })
end

local function emit_notes_legend(lines)
  emit_legend(lines, {
    OPEN_BR,
    { text = 'n', hl = '@keyword' },
    { text = ' note · ', hl = 'Comment' },
    { text = 'T', hl = '@keyword' },
    { text = ' todo · ', hl = 'Comment' },
    { text = 'x', hl = '@keyword' },
    { text = ' toggle · ', hl = 'Comment' },
    { text = '<CR>', hl = '@keyword' },
    { text = ' open file', hl = 'Comment' },
    CLOSE_BR,
  })
end

local function note_kind(line)
  if line:match '^%s*%-%s*%[%s%]' then
    return 'todo_open'
  end
  if line:match '^%s*%-%s*%[[xX]%]' then
    return 'todo_done'
  end
  return 'note'
end

local function rank_kind(k)
  if k == 'todo_open' then
    return 1
  end
  if k == 'note' then
    return 2
  end
  return 3
end

local function note_segments(line, kind)
  if kind == 'todo_open' then
    local _, e = line:find '^%s*%-%s*%[%s%]'
    return {
      { text = line:sub(1, e), hl = 'DiagnosticWarn' },
      { text = line:sub(e + 1), hl = 'Normal' },
    }
  elseif kind == 'todo_done' then
    local _, e = line:find '^%s*%-%s*%[[xX]%]'
    return {
      { text = line:sub(1, e), hl = 'DashboardOk' },
      { text = line:sub(e + 1), hl = 'Comment' },
    }
  end
  return { { text = line, hl = 'Normal' } }
end

local function parse_note_entries(raw, filter)
  local entries = {}
  for i, line in ipairs(raw or {}) do
    if line and line:gsub('%s', '') ~= '' then
      table.insert(entries, { text = line, file_line = i, kind = note_kind(line) })
    end
  end
  if filter and filter ~= '' then
    local kept = {}
    for _, e in ipairs(entries) do
      if matches_filter(e.text, filter) then
        table.insert(kept, e)
      end
    end
    entries = kept
  end
  table.sort(entries, function(a, b)
    if rank_kind(a.kind) ~= rank_kind(b.kind) then
      return rank_kind(a.kind) < rank_kind(b.kind)
    end
    return a.file_line < b.file_line
  end)
  return entries
end

local function render_note_entries(lines, meta, path, entries)
  for _, e in ipairs(entries) do
    local segs = { { text = '    ', hl = nil } }
    for _, s in ipairs(note_segments(e.text, e.kind)) do
      table.insert(segs, s)
    end
    local idx, cols = emit(lines, segs)
    paint(idx, cols)
    meta[idx + 1] = { kind = 'note', path = path, file_line = e.file_line, todo_kind = e.kind }
  end
end

local function emit_notes_section(lines, meta, filter)
  local notes_mod = require 'dashboard.notes'
  local today_path = notes_mod.path_for_today()
  local today_entries = parse_note_entries(notes_mod.read_today(), filter)

  emit_divider(lines, 'Notes')
  emit_blank(lines)

  if #today_entries == 0 then
    local msg = (filter and filter ~= '') and '(no matching notes)' or '(no notes yet — press n to add one)'
    local idx, cols = emit(lines, {
      { text = '    ', hl = nil },
      { text = msg, hl = 'Comment' },
    })
    paint(idx, cols)
    meta[idx + 1] = { kind = 'note', path = today_path }
  else
    render_note_entries(lines, meta, today_path, today_entries)
  end

  local prev_path, prev_date = notes_mod.find_previous(os.date '%Y-%m-%d')
  if prev_path then
    local prev_entries = parse_note_entries(notes_mod.read_file(prev_path), filter)
    if #prev_entries > 0 then
      emit_blank(lines)
      local idx, cols = emit(lines, {
        { text = '  Previous · ', hl = 'Comment' },
        { text = prev_date or '', hl = '@string' },
      })
      paint(idx, cols)
      meta[idx + 1] = { kind = 'note', path = prev_path }
      render_note_entries(lines, meta, prev_path, prev_entries)
    end
  end

  emit_blank(lines)
end

local function emit_jira_legend(lines)
  emit_legend(lines, {
    OPEN_BR,
    { text = 's', hl = '@keyword' },
    { text = ' summary · ', hl = 'Comment' },
    { text = '?', hl = '@keyword' },
    { text = ' prompts', hl = 'Comment' },
    CLOSE_BR,
  })
end

local function emit_footer(lines)
  emit_blank(lines)
  local stamp = state.last_refresh and os.date('%H:%M:%S', state.last_refresh) or '—'
  local idx, cols = emit(lines, {
    { text = '  Last refresh: ', hl = 'Comment' },
    { text = stamp, hl = '@string' },
  })
  paint(idx, cols)
end

local function render()
  if not buf_valid() then
    return
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)

  local lines = {}
  local meta = {}
  pending_hls = {}
  pending_line_bgs = {}
  pending_sections = {}
  pending_subsections = {}
  state.section_lines = {}
  current_section_accent = nil

  sort_prs_by_repo(state.data.my_prs)
  sort_prs_by_repo(state.data.reviews)
  sort_prs_by_repo(state.data.tagged)
  local pr_pool = all_known_prs()

  local f = state.filter
  local function maybe_filter(items, pred)
    if not f or f == '' then
      return items
    end
    return filter_list(items, pred)
  end
  local my_prs = maybe_filter(state.data.my_prs, function(p)
    return pr_matches(p, f)
  end)
  local reviews = maybe_filter(state.data.reviews, function(p)
    return pr_matches(p, f)
  end)
  local tagged = maybe_filter(state.data.tagged, function(p)
    return pr_matches(p, f)
  end)
  local notifications = maybe_filter(state.data.notifications, function(n)
    return notification_matches(n, f)
  end)
  local jira_active = maybe_filter(state.data.jira_active, function(i)
    return issue_matches(i, f)
  end)

  emit_header(lines)
  emit_notes_section(lines, meta, f)
  emit_divider(lines, 'GitHub')
  emit_blank(lines)
  emit_pr_section(lines, meta, 'My PRs', my_prs, 'No open PRs', { draft = true })
  emit_pr_section(lines, meta, 'Awaiting my review', reviews, 'Inbox zero', {})
  emit_pr_section(lines, meta, 'Tagged in', tagged, 'Nothing tagged', {})

  emit_divider(lines, 'Notifications')
  emit_blank(lines)
  emit_section(lines, meta, 'GitHub Inbox', notifications, function(ls, m, n)
    emit_notification(ls, m, n)
  end, 'No notifications')

  -- Jira recent activity as a single compact summary row.
  local jira_items = filtered_jira_recent()
  subsection_box(lines, 'top')
  emit_subhead(lines, 'Jira recent', (type(jira_items) == 'table') and #jira_items or nil, 'DashboardPillInfo')
  if jira_items == nil then
    emit_status(lines, 'loading', 'Loading…')
  elseif jira_items == false or type(jira_items) == 'string' then
    emit_status(lines, 'error', type(jira_items) == 'string' and jira_items or 'Failed to load')
  elseif #jira_items == 0 then
    emit_status(lines, 'empty', 'No recent activity')
  else
    emit_jira_activity(lines, meta, jira_items)
  end
  subsection_box(lines, 'bottom')
  emit_blank(lines)

  emit_divider(lines, 'Jira')
  emit_blank(lines)
  local active = jira_active
  if active == nil then
    emit_section(lines, meta, 'Active', nil, function() end, '')
  elseif active == false or type(active) == 'string' then
    emit_section(lines, meta, 'Active', active, function() end, '')
  else
    local groups = {}
    for _, issue in ipairs(active) do
      local s = issue.status or 'Unknown'
      groups[s] = groups[s] or {}
      table.insert(groups[s], issue)
    end
    local seen = {}
    local function sort_by_has_pr(list)
      table.sort(list, function(a, b)
        local ha = #related_prs(a.key, pr_pool) > 0
        local hb = #related_prs(b.key, pr_pool) > 0
        return ha and not hb
      end)
    end
    for _, status in ipairs(config.jira_status_order) do
      seen[status] = true
      local items = groups[status]
      if items and #items > 0 then
        sort_by_has_pr(items)
        emit_section(lines, meta, status, items, function(ls, m, issue)
          emit_issue(ls, m, issue, { pr_pool = pr_pool, section_status = status })
        end, '', { pill_hl = jira_status_pill(status), collapsible = true })
      end
    end
    local other = {}
    for status, issues in pairs(groups) do
      if not seen[status] then
        for _, issue in ipairs(issues) do
          table.insert(other, issue)
        end
      end
    end
    if #other > 0 then
      sort_by_has_pr(other)
      emit_section(lines, meta, 'Other', other, function(ls, m, issue)
        emit_issue(ls, m, issue, { show_status = true, pr_pool = pr_pool })
      end, '', { collapsible = true })
    end
  end

  local qa_active = state.data.qa_active
  if state.filter and state.filter ~= '' and type(qa_active) == 'table' then
    qa_active = filter_list(qa_active, function(i)
      return issue_matches(i, state.filter)
    end)
  end
  emit_section(lines, meta, 'Developer Verify', qa_active, function(ls, m, issue)
    emit_issue(ls, m, issue, { show_status = true, pr_pool = pr_pool })
  end, 'Nothing to verify', { pill_hl = 'DashboardPillQA', collapsible = true })

  emit_footer(lines)

  state.line_meta = meta

  local total = #lines
  for i, section_start in ipairs(pending_sections) do
    local section_end = pending_sections[i + 1] and (pending_sections[i + 1] - 1) or (total - 1)
    local subs_in_section = {}
    for _, sub_idx in ipairs(pending_subsections) do
      if sub_idx > section_start and sub_idx <= section_end then
        table.insert(subs_in_section, sub_idx)
      end
    end
    if #subs_in_section == 0 then
      for ln = section_start + 1, section_end do
        table.insert(pending_line_bgs, { line = ln, hl = 'DashboardCardBg' })
      end
    else
      for si, sub_start in ipairs(subs_in_section) do
        local sub_actual_start = (si == 1) and (section_start + 1) or sub_start
        local sub_end = subs_in_section[si + 1] and (subs_in_section[si + 1] - 1) or section_end
        for ln = sub_actual_start, sub_end do
          table.insert(pending_line_bgs, { line = ln, hl = 'DashboardCardBg' })
        end
      end
    end
  end

  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  flush_hls()
  vim.bo[state.buf].modifiable = false
end

local function under_cursor()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
  return state.line_meta[lnum]
end

function M.open_under_cursor()
  local m = under_cursor()
  if not m then
    return
  end
  if m.kind == 'pr_repo_header' then
    toggle_repo_collapsed(m.section, m.repo)
    render()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      for i, mm in ipairs(state.line_meta) do
        if mm and mm.kind == 'pr_repo_header' and mm.section == m.section and mm.repo == m.repo then
          pcall(vim.api.nvim_win_set_cursor, state.win, { i, 0 })
          break
        end
      end
    end
    return
  end
  if m.kind == 'jira_section_header' then
    toggle_section_collapsed(m.title)
    render()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      for i, mm in ipairs(state.line_meta) do
        if mm and mm.kind == 'jira_section_header' and mm.title == m.title then
          pcall(vim.api.nvim_win_set_cursor, state.win, { i, 0 })
          break
        end
      end
    end
    return
  end
  if m.kind == 'note' and m.path then
    M.close()
    vim.cmd('edit ' .. vim.fn.fnameescape(m.path))
    return
  end
  if m.kind == 'jira_activity_summary' then
    M.show_jira_activity(m.items)
    return
  end
  if m.url then
    vim.ui.open(m.url)
  end
end

function M.add_note()
  vim.ui.input({ prompt = 'Note: ' }, function(input)
    if not input or input == '' then
      return
    end
    if not input:match '^%s*%-' then
      input = '- ' .. input
    end
    local ok, err = require('dashboard.notes').append(input)
    if not ok then
      vim.notify('Failed to save note: ' .. (err or 'unknown'), vim.log.levels.ERROR)
      return
    end
    if buf_valid() then
      render()
    end
  end)
end

function M.add_todo()
  vim.ui.input({ prompt = 'Todo: ' }, function(input)
    if not input or input == '' then
      return
    end
    if not input:match '^%s*%-?%s*%[' then
      input = input:gsub('^%s*%-?%s*', '')
      input = '- [ ] ' .. input
    end
    local ok, err = require('dashboard.notes').append(input)
    if not ok then
      vim.notify('Failed to save todo: ' .. (err or 'unknown'), vim.log.levels.ERROR)
      return
    end
    if buf_valid() then
      render()
    end
  end)
end

function M.toggle_todo()
  local m = under_cursor()
  if not m or m.kind ~= 'note' or not m.file_line or not m.path then
    return
  end
  local lines = vim.fn.readfile(m.path)
  local original = lines[m.file_line]
  if not original then
    return
  end
  local toggled
  if original:match '^%s*%-%s*%[%s%]' then
    toggled = original:gsub('(%[)%s(%])', '%1x%2', 1)
  elseif original:match '^%s*%-%s*%[[xX]%]' then
    toggled = original:gsub('(%[)[xX](%])', '%1 %2', 1)
  else
    return
  end
  lines[m.file_line] = toggled
  vim.fn.writefile(lines, m.path)
  if buf_valid() then
    render()
  end
end

local function tmux_run(args, cwd)
  local cmd = { 'tmux', 'split-window', '-h' }
  if cwd then
    table.insert(cmd, '-c')
    table.insert(cmd, cwd)
  end
  for _, a in ipairs(args) do
    table.insert(cmd, a)
  end
  vim.system(cmd)
end

local function resolve_repo_path(repo)
  local raw = config.repo_paths[repo]
  if not raw then
    return nil
  end
  return vim.fn.expand(raw)
end

function M.checkout_under_cursor()
  local m = under_cursor()
  if not m or not m.pr then
    return
  end
  local repo_path = resolve_repo_path(m.pr.repo)
  if not repo_path then
    vim.notify('No local path configured for ' .. m.pr.repo, vim.log.levels.WARN)
    return
  end
  vim.notify(string.format('Checking out %s#%d…', m.pr.repo, m.pr.number), vim.log.levels.INFO)
  vim.system({ 'gh', 'pr', 'checkout', tostring(m.pr.number) }, { cwd = repo_path, text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        vim.notify('Checkout failed: ' .. (obj.stderr or 'unknown'), vim.log.levels.ERROR)
        return
      end
      M.close()
      vim.cmd('tcd ' .. vim.fn.fnameescape(repo_path))
      local readme = repo_path .. '/README.md'
      if vim.fn.filereadable(readme) == 1 then
        vim.cmd('edit ' .. vim.fn.fnameescape(readme))
      else
        vim.cmd('edit ' .. vim.fn.fnameescape(repo_path))
      end
    end)
  end)
end

function M.interactive_claude_under_cursor()
  local m = under_cursor()
  if not m or not m.pr then
    return
  end
  if not in_tmux() then
    vim.notify('Not in a tmux session', vim.log.levels.WARN)
    return
  end
  local repo_path = resolve_repo_path(m.pr.repo)
  if not repo_path then
    vim.notify('No local path configured for ' .. m.pr.repo, vim.log.levels.WARN)
    return
  end
  vim.notify(string.format('Checking out %s#%d for Claude…', m.pr.repo, m.pr.number), vim.log.levels.INFO)
  vim.system({ 'gh', 'pr', 'checkout', tostring(m.pr.number) }, { cwd = repo_path, text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        vim.notify('Checkout failed: ' .. (obj.stderr or 'unknown'), vim.log.levels.ERROR)
        return
      end
      tmux_run({ 'claude' }, repo_path)
    end)
  end)
end

local function parse_diff(diff_text)
  local lines = vim.split(diff_text or '', '\n', { plain = true })
  local files = {}
  local current
  for i, line in ipairs(lines) do
    if line:match '^diff %-%-git ' then
      if current then
        table.insert(files, current)
      end
      local b_path = line:match ' b/(.+)$' or '?'
      current = { path = b_path, start_line = i, add = 0, del = 0 }
    elseif current then
      if line:match '^%+%+%+' or line:match '^%-%-%-' then
        -- header line, skip
      elseif line:sub(1, 1) == '+' then
        current.add = current.add + 1
      elseif line:sub(1, 1) == '-' then
        current.del = current.del + 1
      end
    end
  end
  if current then
    table.insert(files, current)
  end
  return files
end

local function diff_viewer_open()
  return (state.diff_left_win and vim.api.nvim_win_is_valid(state.diff_left_win))
    or (state.diff_right_win and vim.api.nvim_win_is_valid(state.diff_right_win))
end

local function focus_diff_viewer()
  if state.diff_left_win and vim.api.nvim_win_is_valid(state.diff_left_win) then
    vim.api.nvim_set_current_win(state.diff_left_win)
    return true
  end
  if state.diff_right_win and vim.api.nvim_win_is_valid(state.diff_right_win) then
    vim.api.nvim_set_current_win(state.diff_right_win)
    return true
  end
  return false
end

-- Apply per-language treesitter highlights to a list of pre-built blocks.
-- Each block has { lang, lines = { { buf_row, content } } } where `content`
-- is the code text with any +/-/space (and possibly indent) prefix stripped.
-- `col_offset` is added to every column so the highlights land on the code
-- portion of the buffer line (1 for raw diff, more if the line is indented).
local function apply_ts_highlights_blocks(buf, blocks, col_offset)
  if not (vim.treesitter and vim.treesitter.get_string_parser) then
    return
  end
  for _, block in ipairs(blocks) do
    if block.lang and #block.lines > 0 then
      local src_lines = {}
      for _, item in ipairs(block.lines) do
        table.insert(src_lines, item.content)
      end
      local source = table.concat(src_lines, '\n')
      if source ~= '' then
        local ok_lang = pcall(vim.treesitter.language.add, block.lang)
        if ok_lang then
          local ok_parser, parser = pcall(vim.treesitter.get_string_parser, source, block.lang)
          if ok_parser and parser then
            local trees = parser:parse()
            local tree = trees and trees[1]
            local ok_q, query = pcall(vim.treesitter.query.get, block.lang, 'highlights')
            if tree and ok_q and query then
              for id, node in query:iter_captures(tree:root(), source, 0, -1) do
                local capture_name = query.captures[id]
                local hl_group = '@' .. capture_name .. '.' .. block.lang
                local srow, scol, erow, ecol = node:range()
                local s_item = block.lines[srow + 1]
                local e_item = block.lines[erow + 1] or s_item
                if s_item then
                  pcall(vim.api.nvim_buf_set_extmark, buf, ns, s_item.buf_row, scol + col_offset, {
                    end_row = e_item and e_item.buf_row or s_item.buf_row,
                    end_col = ecol + col_offset,
                    hl_group = hl_group,
                    priority = 250,
                  })
                end
              end
            end
          end
        end
      end
    end
  end
end

local function detect_ts_lang(path)
  local ok, ft = pcall(vim.filetype.match, { filename = path })
  local lang = ok and ft or nil
  if lang then
    local ok2, ts_lang = pcall(vim.treesitter.language.get_lang, lang)
    if ok2 and ts_lang then
      lang = ts_lang
    end
  end
  return lang
end

-- Build blocks from a standard unified diff body (with file headers).
local function diff_body_blocks(body_lines, header_len)
  local blocks = {}
  local current
  for i, line in ipairs(body_lines) do
    if line:match '^diff %-%-git ' then
      if current and #current.lines > 0 then
        table.insert(blocks, current)
      end
      local path = line:match ' b/(.+)$' or ''
      local lang = detect_ts_lang(path)
      current = lang and { lang = lang, lines = {} } or nil
    elseif line:match '^index ' or line:match '^%+%+%+' or line:match '^%-%-%-' or line:match '^@@' then
      -- diff metadata: skip
    elseif current then
      table.insert(current.lines, { buf_row = i - 1 + header_len, content = line:sub(2) })
    end
  end
  if current and #current.lines > 0 then
    table.insert(blocks, current)
  end
  return blocks
end

local function apply_diff_language_highlights(buf, body_lines, header_len)
  apply_ts_highlights_blocks(buf, diff_body_blocks(body_lines, header_len), 1)
end

-- Pattern-based markdown highlighting for ADF-converted text (description /
-- comment bodies). Handles headings, bold, italic, inline code, link text.
-- col_offset is the byte position in the buffer where the line's content
-- starts (after any indent / border chars).
local function apply_markdown_line_hl(buf, buf_row, col_offset, line)
  if not line or line == '' then
    return
  end
  -- Heading: ^#+ followed by space — color the whole line as Title
  local hashes_match = line:match '^(#+)%s+'
  if hashes_match and #hashes_match <= 6 then
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, buf_row, col_offset, {
      end_row = buf_row,
      end_col = col_offset + #line,
      hl_group = 'Title',
      priority = 200,
    })
    return
  end
  -- Inline patterns: bold, italic, inline code, links
  local function paint(pattern, hl_group)
    local i = 1
    while true do
      local s, e = line:find(pattern, i)
      if not s then
        break
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, buf_row, col_offset + s - 1, {
        end_row = buf_row,
        end_col = col_offset + e,
        hl_group = hl_group,
        priority = 200,
      })
      i = e + 1
    end
  end
  paint('%*%*[^%*]+%*%*', '@markup.strong')
  paint('`[^`]+`', '@markup.raw')
  -- Italic: single * but not part of ** — match `_text_` instead which is
  -- unambiguous and what adf_to_text could emit; bare * is too noisy to
  -- pattern-match reliably.
  paint('_[^_]+_', '@markup.italic')
  -- Link [text](url) — color the [text] part as a link label
  local i = 1
  while true do
    local s, e = line:find('%[[^%]]+%]%([^%)]+%)', i)
    if not s then
      break
    end
    local close = line:find(']', s, true)
    if close then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, buf_row, col_offset + s - 1, {
        end_row = buf_row,
        end_col = col_offset + close,
        hl_group = '@markup.link.label',
        priority = 200,
      })
    end
    i = e + 1
  end
end

local function build_file_tree(files)
  local root = { name = '', path = '', children = {}, child_map = {} }
  for _, f in ipairs(files or {}) do
    local parts = vim.split(f.path or '', '/', { plain = true })
    local node = root
    for i, part in ipairs(parts) do
      local existing = node.child_map[part]
      if not existing then
        local is_leaf = (i == #parts)
        local new_path = node.path == '' and part or (node.path .. '/' .. part)
        existing = {
          name = part,
          path = new_path,
          children = {},
          child_map = {},
          file = is_leaf and f or nil,
        }
        node.child_map[part] = existing
        table.insert(node.children, existing)
      end
      node = existing
    end
  end
  return root
end

local function flatten_file_tree(root, collapsed)
  local rows = {}
  local function walk(node, depth)
    for _, child in ipairs(node.children) do
      local is_file = child.file ~= nil
      table.insert(rows, { node = child, depth = depth, kind = is_file and 'file' or 'dir' })
      if not is_file and not collapsed[child.path] then
        walk(child, depth + 1)
      end
    end
  end
  walk(root, 0)
  return rows
end

local function open_diff_window(title, body, overview, opts)
  opts = opts or {}
  clear_loading()
  local files, body_lines, row_info, body_row_to_file
  local file_tree
  local collapsed_dirs = {}
  local rendered_rows = {}
  local update_diff_winbar
  local thread_counts = {}
  local function rebuild_thread_counts()
    for k in pairs(thread_counts) do
      thread_counts[k] = nil
    end
    if not opts.threads then
      return
    end
    for _, t in ipairs(opts.threads) do
      if t.path then
        local c = thread_counts[t.path] or { total = 0, unresolved = 0 }
        c.total = c.total + 1
        if not t.isResolved then
          c.unresolved = c.unresolved + 1
        end
        thread_counts[t.path] = c
      end
    end
  end
  rebuild_thread_counts()


  local function parse_body(b)
    files = parse_diff(b)
    body_lines = vim.split(b or '', '\n', { plain = true })
    row_info = {}
    body_row_to_file = {}
    local current_file = nil
    local old_l, new_l = 0, 0
    local max_old, max_new = 1, 1
    for i, line in ipairs(body_lines) do
      local info = {}
      if line:match '^diff %-%-git ' then
        old_l, new_l = 0, 0
        info.is_file_header = true
        current_file = line:match ' b/(.+)$'
      elseif line:match '^index ' or line:match '^%+%+%+' or line:match '^%-%-%-' then
        -- file metadata header: no gutter, no bg
      elseif line:match '^@@' then
        local o, n = line:match '^@@ %-(%d+)%S* %+(%d+)'
        old_l = (tonumber(o) or 1) - 1
        new_l = (tonumber(n) or 1) - 1
        info.bg = 'DiffChange'
      elseif line:sub(1, 1) == '+' then
        new_l = new_l + 1
        info.new = new_l
        info.bg = 'DashboardDiffAdd'
      elseif line:sub(1, 1) == '-' then
        old_l = old_l + 1
        info.old = old_l
        info.bg = 'DashboardDiffDelete'
      else
        old_l = old_l + 1
        new_l = new_l + 1
        info.old = old_l
        info.new = new_l
      end
      if info.old and #tostring(info.old) > max_old then
        max_old = #tostring(info.old)
      end
      if info.new and #tostring(info.new) > max_new then
        max_new = #tostring(info.new)
      end
      info.new_l_state = new_l
      info.old_l_state = old_l
      row_info[i] = info
      body_row_to_file[i] = current_file
    end
    row_info._max_old = max_old
    row_info._max_new = max_new
    for _, f in ipairs(files) do
      f._raw_start = f.start_line
    end
    file_tree = build_file_tree(files)
  end

  parse_body(body)

  local function compute_geom()
    local dash = compute_viewer_geom()
    local total_w = dash.width
    local left_content_w = 35
    local right_content_w = total_w - left_content_w - 4
    if right_content_w < 40 then
      left_content_w = math.max(20, total_w - 44)
      right_content_w = total_w - left_content_w - 4
    end
    local left_col = dash.col + 1
    local right_col = left_col + left_content_w + 2
    return {
      total_w = total_w,
      left_content_w = left_content_w,
      right_content_w = right_content_w,
      height = dash.height,
      row = dash.row,
      total_col_start = dash.col,
      left_col = left_col,
      right_col = right_col,
    }
  end

  local geom = compute_geom()

  -- Right (diff) buffer
  local right_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[right_buf].filetype = ''
  vim.bo[right_buf].buftype = 'nofile'
  vim.bo[right_buf].bufhidden = 'wipe'

  -- Renders or re-renders the right buffer for the given width.
  local function render_right(content_w)
    local header_lines = {}
    local header_bgs = {}
    local header_hls = {}
    local function h_push_raw(text)
      table.insert(header_lines, text)
      return #header_lines - 1
    end
    local function h_push_bg(text, bg)
      local idx = h_push_raw(text)
      if bg then
        table.insert(header_bgs, { line = idx, hl = bg })
      end
      return idx
    end
    local function h_push_seg(segs)
      local text = ''
      local local_hls = {}
      for _, s in ipairs(segs) do
        local col_start = #text
        text = text .. s.text
        if s.hl then
          table.insert(local_hls, { col_start = col_start, col_end = #text, hl = s.hl })
        end
      end
      local idx = h_push_raw(text)
      for _, h in ipairs(local_hls) do
        table.insert(header_hls, { line = idx, col_start = h.col_start, col_end = h.col_end, hl = h.hl })
      end
      return idx
    end

    emit_pr_header_card(content_w, overview, h_push_raw, h_push_bg, h_push_seg)
    local header_len = #header_lines

    local combined = {}
    for _, l in ipairs(header_lines) do
      table.insert(combined, l)
    end
    for _, l in ipairs(body_lines) do
      table.insert(combined, l)
    end

    vim.bo[right_buf].modifiable = true
    vim.api.nvim_buf_clear_namespace(right_buf, ns, 0, -1)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, combined)
    vim.bo[right_buf].modifiable = false

    for _, h in ipairs(header_hls) do
      vim.api.nvim_buf_set_extmark(right_buf, ns, h.line, h.col_start, {
        end_col = h.col_end,
        hl_group = h.hl,
        priority = 100,
      })
    end
    for _, bg in ipairs(header_bgs) do
      vim.api.nvim_buf_set_extmark(right_buf, ns, bg.line, 0, {
        end_line = bg.line + 1,
        end_col = 0,
        hl_group = bg.hl,
        hl_eol = true,
        priority = 10,
      })
    end

    local max_old = row_info._max_old
    local max_new = row_info._max_new
    local empty_old = string.rep(' ', max_old)
    local empty_new = string.rep(' ', max_new)
    local fmt_old = '%' .. max_old .. 'd'
    local fmt_new = '%' .. max_new .. 'd'

    for i, line in ipairs(body_lines) do
      local info = row_info[i]
      local buf_line = i - 1 + header_len
      if info.is_file_header then
        local fname = line:match ' b/(.+)$' or '?'
        local label = ' ' .. fname .. ' '
        if #label > content_w - 10 then
          local visible = math.max(3, content_w - 14)
          label = ' …' .. fname:sub(#fname - visible + 1) .. ' '
        end
        local pad_total = content_w - #label
        if pad_total < 2 then
          pad_total = 2
        end
        local pad_left = math.floor(pad_total / 2)
        local pad_right = pad_total - pad_left
        vim.api.nvim_buf_set_extmark(right_buf, ns, buf_line, 0, {
          virt_lines = {
            { { '', '' } },
            {
              { string.rep('━', pad_left), 'NonText' },
              { label, 'Title' },
              { string.rep('━', pad_right), 'NonText' },
            },
            { { '', '' } },
          },
          virt_lines_above = true,
        })
      end
      if info.old or info.new then
        local old_s = info.old and string.format(fmt_old, info.old) or empty_old
        local new_s = info.new and string.format(fmt_new, info.new) or empty_new
        local gutter = ' ' .. old_s .. ' ' .. new_s .. ' │ '
        local nr_hl = 'DashboardDiffLineNr'
        if info.bg == 'DashboardDiffAdd' then
          nr_hl = 'DashboardDiffLineNrAdd'
        elseif info.bg == 'DashboardDiffDelete' then
          nr_hl = 'DashboardDiffLineNrDel'
        end
        vim.api.nvim_buf_set_extmark(right_buf, ns, buf_line, 0, {
          virt_text = { { gutter, nr_hl } },
          virt_text_pos = 'inline',
        })
      end
      if info.bg then
        vim.api.nvim_buf_set_extmark(right_buf, ns, buf_line, 0, {
          line_hl_group = info.bg,
        })
      end
    end

    -- Update files[*].start_line for jump_to_file (header_len changes per width)
    for i, f in ipairs(files) do
      f.start_line = f._raw_start + header_len
    end

    apply_diff_language_highlights(right_buf, body_lines, header_len)

    if opts.threads and #opts.threads > 0 then
      local function thread_anchor_row(thread)
        if not thread.line or not thread.path then
          return nil
        end
        local f
        for _, fi in ipairs(files) do
          if fi.path == thread.path then
            f = fi
            break
          end
        end
        if not f then
          return nil
        end
        local end_idx = #body_lines
        for _, fi in ipairs(files) do
          if fi._raw_start > f._raw_start then
            end_idx = fi._raw_start - 1
            break
          end
        end
        local side = thread.diffSide or 'RIGHT'
        for i = f._raw_start + 1, end_idx do
          local info = row_info[i]
          if info then
            if side == 'RIGHT' and info.new == thread.line then
              return i
            elseif side == 'LEFT' and info.old == thread.line then
              return i
            end
          end
        end
        return nil
      end

      local function build_virt_lines(thread)
        local comments = (thread.comments and thread.comments.nodes) or {}
        local count = #comments
        if thread.isResolved then
          return {
            {
              { '    ', 'Comment' },
              { '↪ resolved · ', 'Comment' },
              { tostring(count) .. (count == 1 and ' comment' or ' comments'), 'Comment' },
            },
          }
        end
        local lines = {}
        table.insert(lines, { { '    ', 'Comment' }, { '╭ unresolved thread', 'DashboardPillWarn' } })
        for i, c in ipairs(comments) do
          local author = (c.author and c.author.login) or '?'
          local age = relative_time(c.createdAt)
          table.insert(lines, {
            { '    ', 'Comment' },
            { '│ ', 'Comment' },
            { '💬 ' .. author, 'Title' },
            { '  ' .. (age or ''), 'Comment' },
          })
          local max_w = math.max(20, (geom.right_content_w or 100) - 8)
          for _, ln in ipairs(wrap_text(c.body or '', max_w)) do
            if ln ~= '' then
              table.insert(lines, { { '    ', 'Comment' }, { '│ ', 'Comment' }, { ln, 'Normal' } })
            end
          end
          if i < count then
            table.insert(lines, { { '    ', 'Comment' }, { '│', 'Comment' } })
          end
        end
        table.insert(lines, { { '    ', 'Comment' }, { '╰', 'DashboardPillWarn' } })
        return lines
      end

      for _, thread in ipairs(opts.threads) do
        local body_row = thread_anchor_row(thread)
        if body_row then
          local buf_line = body_row - 1 + header_len
          pcall(vim.api.nvim_buf_set_extmark, right_buf, ns, buf_line, 0, {
            virt_lines = build_virt_lines(thread),
          })
        end
      end
    end
  end

  local right_win = vim.api.nvim_open_win(right_buf, false, {
    relative = 'editor',
    width = geom.right_content_w,
    height = geom.height,
    row = geom.row,
    col = geom.right_col,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. title .. ' ',
    title_pos = 'center',
    zindex = 60,
  })
  vim.wo[right_win].cursorline = true
  vim.wo[right_win].wrap = false
  vim.wo[right_win].number = false
  vim.wo[right_win].signcolumn = 'no'
  vim.wo[right_win].winhighlight =
    'Normal:DashboardNormal,NormalFloat:DashboardNormal,FloatBorder:DashboardFloatBorder,CursorLine:DashboardCursorLine'

  on_viewer_open(right_win)

  render_right(geom.right_content_w)

  if opts.initial_cursor then
    local row = math.max(1, math.min(opts.initial_cursor[1] or 1, vim.api.nvim_buf_line_count(right_buf)))
    pcall(vim.api.nvim_win_set_cursor, right_win, { row, opts.initial_cursor[2] or 0 })
  end

  -- Left (file list) buffer + window
  local left_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[left_buf].buftype = 'nofile'
  vim.bo[left_buf].bufhidden = 'hide'

  local function left_win_config()
    return {
      relative = 'editor',
      width = geom.left_content_w,
      height = geom.height,
      row = geom.row,
      col = geom.left_col,
      style = 'minimal',
      border = 'rounded',
      title = string.format(' Files (%d) ', #files),
      title_pos = 'center',
      zindex = 60,
    }
  end
  local function right_win_config_split()
    return {
      relative = 'editor',
      width = geom.right_content_w,
      height = geom.height,
      row = geom.row,
      col = geom.right_col,
    }
  end
  local function right_win_config_full()
    return {
      relative = 'editor',
      width = geom.total_w - 2,
      height = geom.height,
      row = geom.row,
      col = geom.total_col_start + 1,
    }
  end

  local left_win = vim.api.nvim_open_win(left_buf, false, left_win_config())
  local function apply_left_winopts()
    vim.wo[left_win].cursorline = true
    vim.wo[left_win].wrap = false
    vim.wo[left_win].winhighlight =
      'Normal:DashboardNormal,NormalFloat:DashboardNormal,FloatBorder:DashboardFloatBorder,CursorLine:DashboardCursorLine'
  end
  apply_left_winopts()
  pcall(vim.api.nvim_set_current_win, right_win)

  vim.api.nvim_create_autocmd({ 'CursorMoved', 'WinScrolled', 'BufWinEnter' }, {
    buffer = right_buf,
    callback = function()
      update_diff_winbar()
    end,
  })
  vim.schedule(function()
    if update_diff_winbar then
      update_diff_winbar()
    end
  end)

  local function render_left(content_w)
    rendered_rows = flatten_file_tree(file_tree, collapsed_dirs)
    local list_lines = {}
    local extmarks = {}
    for _, row in ipairs(rendered_rows) do
      local indent = string.rep('  ', row.depth)
      if row.kind == 'dir' then
        local arrow = collapsed_dirs[row.node.path] and '▸' or '▾'
        local name = row.node.name .. '/'
        local line = indent .. arrow .. ' ' .. name
        if vim.fn.strdisplaywidth(line) > content_w then
          line = line:sub(1, math.max(1, content_w - 1)) .. '…'
        end
        table.insert(list_lines, line)
        local lidx = #list_lines - 1
        local arrow_col = #indent
        table.insert(extmarks, { line = lidx, col_start = arrow_col, col_end = arrow_col + #arrow, hl = 'DashboardAccentGithub' })
        table.insert(extmarks, { line = lidx, col_start = arrow_col + #arrow + 1, col_end = #line, hl = '@string' })
      else
        local f = row.node.file
        local add_str = '+' .. f.add
        local del_str = '-' .. f.del
        local stats = add_str .. ' ' .. del_str
        local tc = thread_counts[f.path]
        local thread_str = (tc and tc.unresolved and tc.unresolved > 0) and ('💬' .. tc.unresolved .. ' ') or ''
        local right_chunk = thread_str .. stats
        local right_w = vim.fn.strdisplaywidth(right_chunk)
        local name = row.node.name
        local prefix = indent .. '  '
        local label = prefix .. name
        local label_max = content_w - right_w - 1
        if vim.fn.strdisplaywidth(label) > label_max and label_max > 1 then
          local keep = label_max - #prefix - 1
          if keep < 1 then keep = 1 end
          label = prefix .. '…' .. name:sub(math.max(1, #name - keep + 2))
        end
        local gap = content_w - vim.fn.strdisplaywidth(label) - right_w
        if gap < 1 then gap = 1 end
        local line = label .. string.rep(' ', gap) .. right_chunk
        table.insert(list_lines, line)
        local lidx = #list_lines - 1
        local tcol = #label + gap
        if thread_str ~= '' then
          table.insert(extmarks, { line = lidx, col_start = tcol, col_end = tcol + #thread_str, hl = 'DashboardPillWarn' })
        end
        local add_start = tcol + #thread_str
        local add_end = add_start + #add_str
        local del_start = add_end + 1
        local del_end = del_start + #del_str
        table.insert(extmarks, { line = lidx, col_start = add_start, col_end = add_end, hl = 'DashboardOk' })
        table.insert(extmarks, { line = lidx, col_start = del_start, col_end = del_end, hl = 'DashboardError' })
      end
    end
    if #list_lines == 0 then
      list_lines = { '(no files in diff)' }
    end

    vim.bo[left_buf].modifiable = true
    vim.api.nvim_buf_clear_namespace(left_buf, ns, 0, -1)
    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, list_lines)
    for _, e in ipairs(extmarks) do
      pcall(vim.api.nvim_buf_set_extmark, left_buf, ns, e.line, e.col_start, { end_col = e.col_end, hl_group = e.hl })
    end
    vim.bo[left_buf].modifiable = false
  end

  render_left(geom.left_content_w)

  state.last_result_win = right_win
  state.diff_left_win = left_win
  state.diff_right_win = right_win

  local closing = false
  local function persist_cursor()
    if opts.on_close and right_win and vim.api.nvim_win_is_valid(right_win) then
      local ok, cur = pcall(vim.api.nvim_win_get_cursor, right_win)
      if ok then
        opts.on_close(cur)
      end
    end
  end
  local close = function()
    if closing then
      return
    end
    closing = true
    persist_cursor()
    if left_win and vim.api.nvim_win_is_valid(left_win) then
      pcall(vim.api.nvim_win_close, left_win, true)
    end
    if right_win and vim.api.nvim_win_is_valid(right_win) then
      pcall(vim.api.nvim_win_close, right_win, true)
    end
    if left_buf and vim.api.nvim_buf_is_valid(left_buf) then
      pcall(vim.api.nvim_buf_delete, left_buf, { force = true })
    end
    if state.diff_left_win == left_win then
      state.diff_left_win = nil
    end
    if state.diff_right_win == right_win then
      state.diff_right_win = nil
    end
    refocus_dashboard(right_win)
  end

  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(right_win),
    callback = function()
      vim.schedule(close)
    end,
  })

  local function current_file_path_in_right()
    if not (right_win and vim.api.nvim_win_is_valid(right_win)) then
      return nil
    end
    local buf_row = vim.api.nvim_win_get_cursor(right_win)[1] - 1
    local computed_header_len = (files[1] and files[1].start_line and files[1]._raw_start)
        and (files[1].start_line - files[1]._raw_start)
      or 0
    local body_row = buf_row + 1 - computed_header_len
    if body_row < 1 or body_row > #body_lines then
      return nil
    end
    return body_row_to_file[body_row]
  end

  local function expand_ancestors_of(path)
    if not path then
      return
    end
    local parts = vim.split(path, '/', { plain = true })
    local acc = ''
    for i = 1, #parts - 1 do
      acc = acc == '' and parts[i] or (acc .. '/' .. parts[i])
      collapsed_dirs[acc] = nil
    end
  end

  local function sync_left_to_path(current_path)
    if not (left_win and vim.api.nvim_win_is_valid(left_win)) or not current_path then
      return
    end
    expand_ancestors_of(current_path)
    render_left(geom.left_content_w)
    for i, r in ipairs(rendered_rows) do
      if r.kind == 'file' and r.node.file and r.node.file.path == current_path then
        pcall(vim.api.nvim_win_set_cursor, left_win, { i, 0 })
        break
      end
    end
  end

  local function sync_left_cursor_to_right()
    sync_left_to_path(current_file_path_in_right())
  end

  local function toggle_files()
    local saved_right_cursor
    if right_win and vim.api.nvim_win_is_valid(right_win) then
      saved_right_cursor = vim.api.nvim_win_get_cursor(right_win)
    end
    if left_win and vim.api.nvim_win_is_valid(left_win) then
      if vim.api.nvim_get_current_win() == left_win and vim.api.nvim_win_is_valid(right_win) then
        vim.api.nvim_set_current_win(right_win)
      end
      pcall(vim.api.nvim_win_close, left_win, true)
      left_win = nil
      state.diff_left_win = nil
      if right_win and vim.api.nvim_win_is_valid(right_win) then
        vim.api.nvim_win_set_config(right_win, right_win_config_full())
        render_right(geom.total_w - 2)
      end
    else
      local current_path = current_file_path_in_right()
      if right_win and vim.api.nvim_win_is_valid(right_win) then
        vim.api.nvim_win_set_config(right_win, right_win_config_split())
        render_right(geom.right_content_w)
      end
      if not (left_buf and vim.api.nvim_buf_is_valid(left_buf)) then
        return
      end
      left_win = vim.api.nvim_open_win(left_buf, false, left_win_config())
      apply_left_winopts()
      state.diff_left_win = left_win
      sync_left_to_path(current_path)
      pcall(vim.api.nvim_set_current_win, left_win)
    end
    if saved_right_cursor and right_win and vim.api.nvim_win_is_valid(right_win) then
      local max_row = vim.api.nvim_buf_line_count(right_buf)
      saved_right_cursor[1] = math.max(1, math.min(saved_right_cursor[1], max_row))
      pcall(vim.api.nvim_win_set_cursor, right_win, saved_right_cursor)
    end
  end

  local function on_resize()
    geom = compute_geom()
    if left_win and vim.api.nvim_win_is_valid(left_win) then
      pcall(vim.api.nvim_win_set_config, left_win, left_win_config())
      pcall(vim.api.nvim_win_set_config, right_win, right_win_config_split())
      render_right(geom.right_content_w)
      render_left(geom.left_content_w)
    else
      pcall(vim.api.nvim_win_set_config, right_win, right_win_config_full())
      render_right(geom.total_w - 2)
    end
  end

  vim.api.nvim_create_autocmd('VimResized', {
    buffer = right_buf,
    callback = function()
      vim.schedule(on_resize)
    end,
  })
  vim.api.nvim_create_autocmd('VimResized', {
    buffer = left_buf,
    callback = function()
      vim.schedule(on_resize)
    end,
  })

  local function jump_right_to_file(f, focus)
    if not f or not (right_win and vim.api.nvim_win_is_valid(right_win)) then
      return
    end
    local header_len = f.start_line - f._raw_start
    local target_body = f._raw_start
    for j = f._raw_start + 1, #body_lines do
      local l = body_lines[j]
      if l:match '^diff %-%-git ' then
        break
      end
      if l:match '^@@' then
        target_body = j
        break
      end
    end
    local target_row = target_body + header_len
    if focus then
      vim.api.nvim_set_current_win(right_win)
    end
    vim.api.nvim_win_set_cursor(right_win, { target_row, 0 })
    vim.api.nvim_win_call(right_win, function()
      local topline = math.max(1, f.start_line - 1)
      pcall(vim.fn.winrestview, { topline = topline })
    end)
  end

  update_diff_winbar = function()
    if not (right_win and vim.api.nvim_win_is_valid(right_win)) then
      return
    end
    if not files or #files == 0 then
      vim.wo[right_win].winbar = ''
      return
    end
    local topline_1based = vim.api.nvim_win_call(right_win, function()
      return vim.fn.line 'w0'
    end)
    local topline_0 = topline_1based - 1
    local computed_header_len = (files[1] and files[1].start_line and files[1]._raw_start)
        and (files[1].start_line - files[1]._raw_start)
      or 0
    local body_row = topline_0 + 1 - computed_header_len
    if body_row < 1 then
      vim.wo[right_win].winbar = ''
      return
    end
    local cur
    for _, f in ipairs(files) do
      if f._raw_start <= body_row then
        cur = f
      else
        break
      end
    end
    if not cur then
      vim.wo[right_win].winbar = ''
      return
    end
    local path = (cur.path or '?'):gsub('%%', '%%%%')
    vim.wo[right_win].winbar = ' %#Title# '
      .. path
      .. ' %#DashboardOk#+'
      .. cur.add
      .. ' %#DashboardError#-'
      .. cur.del
      .. ' %#Normal#'
  end

  local function file_idx_for_buf_row(buf_row)
    local computed_header_len = (files[1] and files[1].start_line and files[1]._raw_start)
        and (files[1].start_line - files[1]._raw_start)
      or 0
    local body_row = buf_row + 1 - computed_header_len
    if body_row < 1 then
      return nil
    end
    local idx = nil
    for i, f in ipairs(files) do
      if f._raw_start <= body_row then
        idx = i
      else
        break
      end
    end
    return idx
  end

  local function next_file_in_right()
    if not (right_win and vim.api.nvim_win_is_valid(right_win)) or #files == 0 then
      return
    end
    local buf_row = vim.api.nvim_win_get_cursor(right_win)[1] - 1
    local idx = file_idx_for_buf_row(buf_row) or 0
    local target = math.min(idx + 1, #files)
    if target ~= idx then
      jump_right_to_file(files[target], false)
    end
  end

  local function prev_file_in_right()
    if not (right_win and vim.api.nvim_win_is_valid(right_win)) or #files == 0 then
      return
    end
    local buf_row = vim.api.nvim_win_get_cursor(right_win)[1] - 1
    local idx = file_idx_for_buf_row(buf_row) or (#files + 1)
    local target = math.max(1, idx - 1)
    if target ~= idx then
      jump_right_to_file(files[target], false)
    end
  end

  local function jump_to_file()
    if not left_win or not vim.api.nvim_win_is_valid(left_win) then
      return
    end
    local lnum = vim.api.nvim_win_get_cursor(left_win)[1]
    local row = rendered_rows[lnum]
    if not row then
      return
    end
    if row.kind == 'dir' then
      if collapsed_dirs[row.node.path] then
        collapsed_dirs[row.node.path] = nil
      else
        collapsed_dirs[row.node.path] = true
      end
      local target_path = row.node.path
      render_left(geom.left_content_w)
      for i, r in ipairs(rendered_rows) do
        if r.node.path == target_path then
          pcall(vim.api.nvim_win_set_cursor, left_win, { i, 0 })
          break
        end
      end
      return
    end
    jump_right_to_file(row.node.file, true)
  end

  local refreshing = false
  local function refresh()
    if not opts.refresh_fn or refreshing then
      return
    end
    refreshing = true
    show_loading('Refreshing diff…')
    opts.refresh_fn(function(new_body, err)
      refreshing = false
      clear_loading()
      if err then
        vim.notify('Refresh failed: ' .. err, vim.log.levels.ERROR)
        return
      end
      if not new_body or new_body:gsub('%s', '') == '' then
        vim.notify('No local changes', vim.log.levels.INFO)
        return
      end
      parse_body(new_body)
      local content_w = (left_win and vim.api.nvim_win_is_valid(left_win))
          and geom.right_content_w
        or (geom.total_w - 2)
      render_right(content_w)
      if left_win and vim.api.nvim_win_is_valid(left_win) then
        pcall(vim.api.nvim_win_set_config, left_win, left_win_config())
        render_left(geom.left_content_w)
      end
    end)
  end

  -- Opens the file under the cursor in the right pane, at the new-side line
  -- number from that diff row. Closes the diff viewer.
  local function open_at_cursor()
    if not opts.cwd then
      return
    end
    if not (right_win and vim.api.nvim_win_is_valid(right_win)) then
      return
    end
    local buf_row = vim.api.nvim_win_get_cursor(right_win)[1] - 1
    local header_len = buf_row - (buf_row) -- placeholder; compute below
    -- header_len is the count of header lines (PR overview card). For local
    -- diff there's no overview so header_len == 0 — but compute properly via
    -- the upvalue captured by render_right. Instead of plumbing it, infer
    -- the body index by walking back to find the nearest 'diff --git'.
    local body_row = buf_row + 1
    -- If we're inside the PR header (above the first diff --git), body_row
    -- maps to a position before any file; walk forward in body_lines to skip.
    -- For local diff, buf row 0 == body line 1 anyway since header_len == 0.
    -- For PR diff (with overview), find header_len from the first file's
    -- start: parse_diff returns f.start_line in body coords, and we patch
    -- f.start_line = f._raw_start + header_len in render_right. Reverse it:
    local computed_header_len = (files[1] and files[1].start_line and files[1]._raw_start)
        and (files[1].start_line - files[1]._raw_start)
      or 0
    body_row = buf_row + 1 - computed_header_len
    if body_row < 1 or body_row > #body_lines then
      return
    end
    local info = row_info[body_row]
    local file = body_row_to_file[body_row]
    if not file then
      return
    end
    local line_num = (info and (info.new or info.old)) or 1
    -- Resolve file relative to cwd (or git root). git diff paths are repo-root
    -- relative; if user runs from repo root, this matches cwd directly.
    local path = opts.cwd .. '/' .. file
    -- Tear down the hidden dashboard so it doesn't reopen behind the file.
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
    end
    state.buf = nil
    state.win = nil
    state.dashboard_cursor = nil
    state.viewer_count = 0
    close()
    vim.schedule(function()
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
      pcall(vim.api.nvim_win_set_cursor, 0, { line_num, 0 })
      vim.cmd 'normal! zz'
    end)
  end

  local left_opts = { buffer = left_buf, nowait = true, silent = true }
  apply_tmux_nav_keymaps(left_buf)
  vim.keymap.set('n', 'q', close, left_opts)
  vim.keymap.set('n', '<Esc>', close, left_opts)
  vim.keymap.set('n', '<CR>', jump_to_file, left_opts)
  vim.keymap.set('n', '\\', toggle_files, left_opts)
  if opts.refresh_fn then
    vim.keymap.set('n', 'r', refresh, left_opts)
  end
  vim.keymap.set('n', '<Tab>', function()
    if vim.api.nvim_win_is_valid(right_win) then
      vim.api.nvim_set_current_win(right_win)
    end
  end, left_opts)

  local function row_to_line_meta(buf_row_0)
    local computed_header_len = (files[1] and files[1].start_line and files[1]._raw_start)
        and (files[1].start_line - files[1]._raw_start)
      or 0
    local body_row = buf_row_0 + 1 - computed_header_len
    if body_row < 1 or body_row > #body_lines then
      return nil, 'Place cursor on a diff line'
    end
    local info = row_info[body_row]
    if not info or (not info.new and not info.old) then
      return nil, 'Place cursor on a code line (not a hunk header)'
    end
    local file = body_row_to_file[body_row]
    if not file then
      return nil, 'No file at cursor'
    end
    local side, line_num
    if info.new and not info.old then
      side, line_num = 'RIGHT', info.new
    elseif info.old and not info.new then
      side, line_num = 'LEFT', info.old
    else
      side, line_num = 'RIGHT', info.new
    end
    return { file = file, line = line_num, side = side, body_row = body_row }
  end

  local function existing_thread_at(file, side, line_num)
    if not opts.threads then
      return nil
    end
    for _, t in ipairs(opts.threads) do
      if t.path == file and (t.diffSide or 'RIGHT') == side and t.line == line_num then
        return t
      end
    end
    return nil
  end

  local function parse_post_error(obj)
    local stderr = (obj.stderr or ''):gsub('%s+$', '')
    local stdout = (obj.stdout or ''):gsub('%s+$', '')
    if stdout ~= '' then
      local ok, parsed = pcall(vim.json.decode, stdout, { luanil = { object = true, array = true } })
      if ok and type(parsed) == 'table' then
        local parts = {}
        if parsed.message then
          table.insert(parts, parsed.message)
        end
        for _, e in ipairs(parsed.errors or {}) do
          if type(e) == 'table' then
            table.insert(parts, (e.field or '?') .. ': ' .. (e.message or e.code or '?'))
          elseif type(e) == 'string' then
            table.insert(parts, e)
          end
        end
        if #parts > 0 then
          return table.concat(parts, ' · ')
        end
      end
    end
    if stderr ~= '' then
      return stderr
    end
    if stdout ~= '' then
      return stdout
    end
    return 'gh exit ' .. obj.code
  end

  local function refresh_threads_and_render()
    require('dashboard.github').fetch_review_threads(overview.repo, overview.number, function(new_threads)
      opts.threads = new_threads or {}
      rebuild_thread_counts()
      local content_w = (left_win and vim.api.nvim_win_is_valid(left_win)) and geom.right_content_w
        or (geom.total_w - 2)
      render_right(content_w)
      if left_win and vim.api.nvim_win_is_valid(left_win) then
        render_left(geom.left_content_w)
      end
    end)
  end

  local function comment_on_lines(mode)
    if not (overview and overview.repo and overview.number and overview.head_sha) then
      vim.notify('Commenting only works on PR diffs', vim.log.levels.INFO)
      return
    end
    if not (right_win and vim.api.nvim_win_is_valid(right_win)) then
      return
    end
    local start_buf_row, end_buf_row
    if mode == 'visual' then
      local s = vim.fn.getpos('v')[2]
      local e = vim.fn.getpos('.')[2]
      if s == 0 or e == 0 then
        vim.notify('No visual selection found', vim.log.levels.INFO)
        return
      end
      if s > e then
        s, e = e, s
      end
      start_buf_row, end_buf_row = s - 1, e - 1
    else
      local cur = vim.api.nvim_win_get_cursor(right_win)[1] - 1
      start_buf_row, end_buf_row = cur, cur
    end
    local start_meta, serr = row_to_line_meta(start_buf_row)
    if not start_meta then
      vim.notify(serr, vim.log.levels.INFO)
      return
    end
    local end_meta, eerr = row_to_line_meta(end_buf_row)
    if not end_meta then
      vim.notify(eerr, vim.log.levels.INFO)
      return
    end
    if start_meta.file ~= end_meta.file then
      vim.notify('Multi-line comment must stay within one file', vim.log.levels.WARN)
      return
    end
    local is_range = start_meta.body_row ~= end_meta.body_row
    local reply_to
    if not is_range then
      local thread = existing_thread_at(end_meta.file, end_meta.side, end_meta.line)
      if thread and thread.comments and thread.comments.nodes and thread.comments.nodes[1] then
        reply_to = thread.comments.nodes[1].databaseId
      end
    end
    local prompt
    if reply_to then
      prompt = string.format('Reply on %s:%d: ', end_meta.file, end_meta.line)
    elseif is_range then
      prompt = string.format('Comment on %s:%d-%d: ', end_meta.file, start_meta.line, end_meta.line)
    else
      prompt = string.format('Comment on %s:%d (%s): ', end_meta.file, end_meta.line, end_meta.side)
    end
    vim.ui.input({ prompt = prompt }, function(body)
      if not body or body == '' then
        return
      end
      local args
      if reply_to then
        args = {
          'gh',
          'api',
          '-X',
          'POST',
          '-H',
          'Accept: application/vnd.github+json',
          '/repos/' .. overview.repo .. '/pulls/' .. tostring(overview.number) .. '/comments/' .. tostring(reply_to) .. '/replies',
          '-f',
          'body=' .. body,
        }
      else
        args = {
          'gh',
          'api',
          '-X',
          'POST',
          '-H',
          'Accept: application/vnd.github+json',
          '/repos/' .. overview.repo .. '/pulls/' .. tostring(overview.number) .. '/comments',
          '-f',
          'commit_id=' .. overview.head_sha,
          '-f',
          'path=' .. end_meta.file,
          '-F',
          'line=' .. tostring(end_meta.line),
          '-f',
          'side=' .. end_meta.side,
          '-f',
          'body=' .. body,
        }
        if is_range then
          table.insert(args, '-F')
          table.insert(args, 'start_line=' .. tostring(start_meta.line))
          table.insert(args, '-f')
          table.insert(args, 'start_side=' .. start_meta.side)
        end
      end
      vim.notify(reply_to and 'Posting reply…' or 'Posting comment…', vim.log.levels.INFO)
      vim.system(args, { text = true }, function(obj)
        vim.schedule(function()
          if obj.code == 0 then
            vim.notify(reply_to and 'Reply posted' or 'Comment posted', vim.log.levels.INFO)
            refresh_threads_and_render()
          else
            vim.notify('Failed to post: ' .. parse_post_error(obj), vim.log.levels.ERROR)
          end
        end)
      end)
    end)
  end

  local function submit_review()
    if not (overview and overview.repo and overview.number) then
      vim.notify('Review submission only works on PR diffs', vim.log.levels.INFO)
      return
    end
    local choice = vim.fn.confirm('Submit review:', '&Approve\n&Request changes\n&Comment\nCa&ncel', 4, 'Question')
    if choice == 0 or choice == 4 then
      return
    end
    local events = { 'APPROVE', 'REQUEST_CHANGES', 'COMMENT' }
    local event = events[choice]
    if not event then
      return
    end
    local body = vim.fn.input { prompt = 'Review body (optional): ' }
    local args = {
      'gh',
      'api',
      '-X',
      'POST',
      '-H',
      'Accept: application/vnd.github+json',
      '/repos/' .. overview.repo .. '/pulls/' .. tostring(overview.number) .. '/reviews',
      '-f',
      'event=' .. event,
    }
    if body and body ~= '' then
      table.insert(args, '-f')
      table.insert(args, 'body=' .. body)
    end
    vim.notify('Submitting ' .. event .. '…', vim.log.levels.INFO)
    vim.system(args, { text = true }, function(obj)
      vim.schedule(function()
        if obj.code == 0 then
          vim.notify('Review submitted: ' .. event, vim.log.levels.INFO)
        else
          vim.notify('Failed to submit review: ' .. parse_post_error(obj), vim.log.levels.ERROR)
        end
      end)
    end)
  end

  local right_opts = { buffer = right_buf, nowait = true, silent = true }
  apply_tmux_nav_keymaps(right_buf)
  vim.keymap.set('n', 'q', close, right_opts)
  vim.keymap.set('n', '<Esc>', close, right_opts)
  vim.keymap.set('n', '\\', toggle_files, right_opts)
  vim.keymap.set('n', '}', next_file_in_right, right_opts)
  vim.keymap.set('n', '{', prev_file_in_right, right_opts)
  if overview then
    vim.keymap.set('n', 'c', function()
      comment_on_lines 'single'
    end, right_opts)
    vim.keymap.set('x', 'c', function()
      comment_on_lines 'visual'
    end, right_opts)
    vim.keymap.set('n', 'R', submit_review, right_opts)
  end
  if opts.refresh_fn then
    vim.keymap.set('n', 'r', refresh, right_opts)
  end
  if opts.cwd then
    vim.keymap.set('n', '<CR>', open_at_cursor, right_opts)
  end
  vim.keymap.set('n', '<Tab>', function()
    if not left_win or not vim.api.nvim_win_is_valid(left_win) then
      toggle_files()
      if left_win and vim.api.nvim_win_is_valid(left_win) then
        vim.api.nvim_set_current_win(left_win)
      end
    else
      sync_left_cursor_to_right()
      vim.api.nvim_set_current_win(left_win)
    end
  end, right_opts)
end

wrap_text = function(text, max_w)
  text = (text or ''):gsub('\r', '')
  local out = {}
  for line in (text .. '\n'):gmatch '([^\n]*)\n' do
    if line == '' then
      table.insert(out, '')
    elseif vim.fn.strdisplaywidth(line) <= max_w then
      table.insert(out, line)
    else
      local current = ''
      for word in line:gmatch '%S+' do
        if current == '' then
          current = word
        elseif vim.fn.strdisplaywidth(current .. ' ' .. word) > max_w then
          table.insert(out, current)
          current = word
        else
          current = current .. ' ' .. word
        end
      end
      if current ~= '' then
        table.insert(out, current)
      end
    end
  end
  return out
end

function emit_pr_header_card(content_w, overview, push_raw, push_bg, push_seg)
  if not overview then
    return
  end
  local indent = '  '
  local hbg = 'DashboardCardBgAlt'
  local dash_w = math.max(10, content_w - 4)

  push_bg('', hbg)
  push_seg({
    { text = indent, hl = nil },
    { text = '▎  ', hl = 'DashboardAccentGithub' },
    { text = '#' .. tostring(overview.number or '?'), hl = '@number' },
    { text = '   ', hl = nil },
    { text = overview.state or '', hl = 'Comment' },
  }, hbg)
  push_seg({
    { text = indent, hl = nil },
    { text = '     ', hl = nil },
    { text = overview.title or '', hl = 'Title' },
  }, hbg)
  push_bg('', hbg)
  push_seg({
    { text = indent, hl = nil },
    { text = 'Author:', hl = 'Comment' },
    { text = ' ' .. (overview.author or '?'), hl = 'Normal' },
    { text = '  ·  ', hl = 'NonText' },
    { text = 'Branch:', hl = 'Comment' },
    { text = ' ' .. (overview.base or '?') .. ' ← ' .. (overview.head or '?'), hl = 'Normal' },
  }, hbg)
  if overview.labels and #overview.labels > 0 then
    push_seg({
      { text = indent, hl = nil },
      { text = 'Labels:', hl = 'Comment' },
      { text = ' ' .. table.concat(overview.labels, ', '), hl = '@string' },
    }, hbg)
  end
  push_bg('', hbg)
  push_seg({
    { text = indent, hl = nil },
    { text = 'DESCRIPTION', hl = 'Title' },
  }, hbg)
  push_seg({
    { text = indent, hl = nil },
    { text = string.rep('╌', dash_w), hl = 'NonText' },
  }, hbg)
  local body = overview.body or ''
  if body:gsub('%s', '') == '' then
    push_seg({
      { text = indent, hl = nil },
      { text = '(no description)', hl = 'Comment' },
    }, hbg)
  else
    local body_max = math.max(20, content_w - 4)
    for _, l in ipairs(wrap_text(body, body_max)) do
      push_bg(indent .. l, hbg)
    end
  end
  push_bg('', hbg)

  local comments = overview.issue_comments or {}
  if #comments > 0 then
    push_seg({
      { text = indent, hl = nil },
      { text = 'DISCUSSION (' .. tostring(#comments) .. ')', hl = 'Title' },
    }, hbg)
    push_seg({
      { text = indent, hl = nil },
      { text = string.rep('╌', dash_w), hl = 'NonText' },
    }, hbg)
    local body_max = math.max(20, content_w - 4)
    for i, c in ipairs(comments) do
      local age = relative_time(c.created_at)
      push_seg({
        { text = indent, hl = nil },
        { text = '💬 ' .. (c.author or '?'), hl = 'Title' },
        { text = '  ' .. (age or ''), hl = 'Comment' },
      }, hbg)
      for _, l in ipairs(wrap_text(c.body or '', body_max)) do
        push_bg(indent .. l, hbg)
      end
      if i < #comments then
        push_bg('', hbg)
      end
    end
    push_bg('', hbg)
  end
end

local function ago(iso)
  local label = (relative_time(iso))
  if label == '' then
    return '?'
  end
  if label == 'now' then
    return 'just now'
  end
  return label .. ' ago'
end


-- Renders a list of recent Jira tickets as bordered cards. Returns a map of
-- buf_row -> issue so a parent caller can wire <CR> to navigate into a card.
local function action_badge(status, conclusion)
  if status == 'in_progress' or status == 'queued' or status == 'waiting' or status == 'requested' or status == 'pending' then
    return '●', 'DiagnosticWarn', status
  end
  if conclusion == 'success' then
    return '✓', 'DashboardOk', 'success'
  elseif conclusion == 'failure' or conclusion == 'timed_out' or conclusion == 'startup_failure' then
    return '✗', 'DashboardError', conclusion
  elseif conclusion == 'cancelled' then
    return '⊘', 'NonText', 'cancelled'
  elseif conclusion == 'skipped' or conclusion == 'neutral' or conclusion == 'stale' then
    return '·', 'NonText', conclusion
  elseif conclusion == 'action_required' then
    return '!', 'DiagnosticWarn', 'action required'
  end
  return '·', 'NonText', status or '?'
end

local function render_actions_list(buf, win, items, repo)
  vim.bo[buf].filetype = ''
  local content_w = vim.api.nvim_win_get_width(win) - 2
  local border_w = math.max(20, content_w - 4)

  local lines = {}
  local range_hls = {}
  local line_to_item = {}

  local function push_raw(text)
    table.insert(lines, text)
    return #lines - 1
  end
  local function push_seg(segs)
    local text = ''
    local local_hls = {}
    for _, s in ipairs(segs) do
      local col_start = #text
      text = text .. s.text
      if s.hl then
        table.insert(local_hls, { col_start = col_start, col_end = #text, hl = s.hl })
      end
    end
    local idx = push_raw(text)
    for _, h in ipairs(local_hls) do
      table.insert(range_hls, { line = idx, col_start = h.col_start, col_end = h.col_end, hl = h.hl })
    end
    return idx
  end

  push_raw('')
  push_seg {
    { text = '  ', hl = nil },
    { text = 'GITHUB ACTIONS', hl = 'Title' },
    { text = '   ' .. (repo or '?'), hl = 'Comment' },
    { text = '   · ' .. tostring(#items) .. ' runs', hl = 'NonText' },
  }
  push_raw('')
  push_seg {
    { text = '  ', hl = nil },
    { text = '<CR>', hl = 'DashboardPillInfo' },
    { text = '  open run in browser    ', hl = 'Comment' },
    { text = ' q ', hl = 'DashboardPillMuted' },
    { text = '  close', hl = 'Comment' },
  }
  push_raw('')

  if #items == 0 then
    push_seg { { text = '  ', hl = nil }, { text = 'No workflow runs found.', hl = 'Comment' } }
  end

  local indent = '  '
  local wf_w = 0
  local branch_w = 0
  for _, r in ipairs(items) do
    wf_w = math.max(wf_w, vim.fn.strdisplaywidth(r.workflow or ''))
    branch_w = math.max(branch_w, vim.fn.strdisplaywidth(r.branch or ''))
  end
  wf_w = math.min(wf_w, 32)
  branch_w = math.min(branch_w, 28)

  for _, r in ipairs(items) do
    local glyph, glyph_hl, label = action_badge(r.status, r.conclusion)
    local age, age_hl = relative_time(r.updated_at or r.created_at)
    local wf = r.workflow or '?'
    if vim.fn.strdisplaywidth(wf) > wf_w then
      wf = wf:sub(1, wf_w - 1) .. '…'
    end
    local branch = r.branch or ''
    if vim.fn.strdisplaywidth(branch) > branch_w then
      branch = branch:sub(1, branch_w - 1) .. '…'
    end
    local title = r.title or ''
    local title_max = math.max(20, border_w - wf_w - branch_w - 30)
    if vim.fn.strdisplaywidth(title) > title_max then
      title = title:sub(1, title_max - 1) .. '…'
    end
    local card_start = #lines
    push_seg {
      { text = indent, hl = nil },
      { text = glyph, hl = glyph_hl },
      { text = '  ', hl = nil },
      { text = pad_right(label, 10), hl = glyph_hl },
      { text = '  ', hl = nil },
      { text = pad_right(wf, wf_w + 2), hl = 'Title' },
      { text = pad_right(branch, branch_w + 2), hl = '@string' },
      { text = pad_right(r.event or '', 18), hl = 'Comment' },
      { text = string.format('%6s', age or ''), hl = age_hl or 'Comment' },
    }
    push_seg {
      { text = indent, hl = nil },
      { text = '     ', hl = nil },
      { text = title, hl = 'Normal' },
    }
    push_raw('')
    for i = card_start, #lines - 1 do
      line_to_item[i] = r
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  for _, h in ipairs(range_hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, h.line, h.col_start, {
      end_col = h.col_end,
      hl_group = h.hl,
      priority = 100,
    })
  end
  return line_to_item
end

local function render_jira_activity_list(buf, win, items)
  vim.bo[buf].filetype = ''
  local content_w = vim.api.nvim_win_get_width(win) - 2
  local border_w = math.max(20, content_w - 4)

  local lines = {}
  local range_hls = {}
  local line_to_item = {}

  local function push_raw(text)
    table.insert(lines, text)
    return #lines - 1
  end
  local function push_seg(segs)
    local text = ''
    local local_hls = {}
    for _, s in ipairs(segs) do
      local col_start = #text
      text = text .. s.text
      if s.hl then
        table.insert(local_hls, { col_start = col_start, col_end = #text, hl = s.hl })
      end
    end
    local idx = push_raw(text)
    for _, h in ipairs(local_hls) do
      table.insert(range_hls, { line = idx, col_start = h.col_start, col_end = h.col_end, hl = h.hl })
    end
    return idx
  end

  push_raw('')
  push_seg {
    { text = '  ', hl = nil },
    { text = 'JIRA RECENT ACTIVITY', hl = 'Title' },
    { text = '   ' .. tostring(#items) .. ' tickets', hl = 'Comment' },
  }
  push_raw('')
  push_seg {
    { text = '  ', hl = nil },
    { text = '<CR>', hl = 'DashboardPillInfo' },
    { text = '  open ticket    ', hl = 'Comment' },
    { text = ' q ', hl = 'DashboardPillMuted' },
    { text = '  close', hl = 'Comment' },
  }
  push_raw('')

  local indent = '  '
  for _, issue in ipairs(items) do
    local card_start = #lines
    push_seg {
      { text = indent, hl = nil },
      { text = '╭' .. string.rep('─', border_w) .. '╮', hl = 'DashboardAccentJira' },
    }
    local age, age_hl = relative_time(issue.status_change_at)
    local head_segs = {
      { text = indent, hl = nil },
      { text = '  ', hl = nil },
      { text = issue.key or '?', hl = 'Title' },
      { text = '   ', hl = nil },
      { text = ' ' .. (issue.status or '?') .. ' ', hl = jira_status_pill(issue.status) },
    }
    if issue.qa_assignee then
      table.insert(head_segs, { text = '   ', hl = nil })
      table.insert(head_segs, { text = ' QA: ' .. issue.qa_assignee .. ' ', hl = 'DashboardPillInfo' })
    end
    table.insert(head_segs, { text = '   ', hl = nil })
    table.insert(head_segs, { text = age or '', hl = age_hl or 'Comment' })
    if issue.comment_count and issue.comment_count > 0 then
      table.insert(head_segs, { text = '  ·  ', hl = 'NonText' })
      table.insert(head_segs, { text = tostring(issue.comment_count) .. ' comments', hl = 'Comment' })
    end
    push_seg(head_segs)

    local body_max = math.max(20, border_w - 4)
    for _, l in ipairs(wrap_text(issue.summary or '', body_max)) do
      push_seg {
        { text = indent, hl = nil },
        { text = '  ', hl = nil },
        { text = l, hl = 'Normal' },
      }
    end

    if issue.latest_change_author and issue.latest_change_items and #issue.latest_change_items > 0 then
      push_raw('')
      local change_age, change_age_hl = relative_time(issue.latest_change_created)
      push_seg {
        { text = indent, hl = nil },
        { text = '  ', hl = nil },
        { text = '↻ ', hl = 'DashboardAccentJira' },
        { text = issue.latest_change_author, hl = 'Title' },
        { text = '  ', hl = nil },
        { text = change_age or '', hl = change_age_hl or 'Comment' },
      }
      for _, it in ipairs(issue.latest_change_items) do
        local from = it.from and it.from ~= '' and it.from or '∅'
        local to = it.to and it.to ~= '' and it.to or '∅'
        local segs = {
          { text = indent, hl = nil },
          { text = '    ', hl = nil },
          { text = it.field, hl = 'Comment' },
          { text = '  ', hl = nil },
        }
        if from == '∅' then
          table.insert(segs, { text = '+ ', hl = 'DashboardOk' })
          table.insert(segs, { text = to, hl = 'Normal' })
        elseif to == '∅' then
          table.insert(segs, { text = '- ', hl = 'DashboardError' })
          table.insert(segs, { text = from, hl = 'Normal' })
        else
          table.insert(segs, { text = from, hl = 'Normal' })
          table.insert(segs, { text = '  →  ', hl = 'NonText' })
          table.insert(segs, { text = to, hl = 'Normal' })
        end
        push_seg(segs)
      end
    end

    if issue.latest_comment_author and issue.latest_comment_body and issue.latest_comment_body ~= '' then
      push_raw('')
      local comment_age, comment_age_hl = relative_time(issue.latest_comment_created)
      push_seg {
        { text = indent, hl = nil },
        { text = '  ', hl = nil },
        { text = '💬 ', hl = 'Comment' },
        { text = issue.latest_comment_author, hl = 'Title' },
        { text = '  ', hl = nil },
        { text = comment_age or '', hl = comment_age_hl or 'Comment' },
      }
      local body_text = (issue.latest_comment_body or ''):gsub('%s+$', '')
      local snippet_max_chars = math.max(80, (border_w - 6) * 3)
      if #body_text > snippet_max_chars then
        body_text = body_text:sub(1, snippet_max_chars) .. '…'
      end
      for _, l in ipairs(wrap_text(body_text, body_max)) do
        push_seg {
          { text = indent, hl = nil },
          { text = '  ', hl = nil },
          { text = l, hl = 'Comment' },
        }
      end
    end

    push_seg {
      { text = indent, hl = nil },
      { text = '╰' .. string.rep('─', border_w) .. '╯', hl = 'DashboardAccentJira' },
    }
    push_raw('')
    for i = card_start, #lines - 1 do
      line_to_item[i] = issue
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  for _, h in ipairs(range_hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, h.line, h.col_start, {
      end_col = h.col_end,
      hl_group = h.hl,
      priority = 100,
    })
  end
  return line_to_item
end

local function render_jira_issue(buf, win, issue)
  vim.bo[buf].filetype = ''
  local content_w = vim.api.nvim_win_get_width(win) - 2
  local dash_w = math.max(10, content_w - 4)

  local lines = {}
  local line_bgs = {}
  local range_hls = {}
  local desc_lines = {} -- { buf_row, content } for markdown highlight pass
  local comment_md_lines = {} -- { buf_row, col_offset, content }

  local function push_raw(text)
    table.insert(lines, text)
    return #lines - 1
  end
  local function push_bg(text, bg)
    local idx = push_raw(text)
    if bg then
      table.insert(line_bgs, { line = idx, hl = bg })
    end
    return idx
  end
  local function push_seg(segs, bg)
    local text = ''
    local local_hls = {}
    for _, s in ipairs(segs) do
      local col_start = #text
      text = text .. s.text
      if s.hl then
        table.insert(local_hls, { col_start = col_start, col_end = #text, hl = s.hl })
      end
    end
    local idx = push_raw(text)
    for _, h in ipairs(local_hls) do
      table.insert(range_hls, { line = idx, col_start = h.col_start, col_end = h.col_end, hl = h.hl })
    end
    if bg then
      table.insert(line_bgs, { line = idx, hl = bg })
    end
    return idx
  end

  -- HEADER CARD
  local hbg = 'DashboardCardBgAlt'
  push_bg('', hbg)
  push_seg({
    { text = '  ', hl = nil },
    { text = '▎  ', hl = 'DashboardAccentJira' },
    { text = issue.key, hl = '@number' },
  }, hbg)
  push_seg({
    { text = '     ', hl = nil },
    { text = issue.title or '', hl = 'Title' },
  }, hbg)
  push_bg('', hbg)
  push_seg({
    { text = '  ', hl = nil },
    { text = 'Status:', hl = 'Comment' },
    { text = ' ' .. (issue.status or '?'), hl = 'Normal' },
    { text = '  ·  ', hl = 'NonText' },
    { text = 'Priority:', hl = 'Comment' },
    { text = ' ' .. (issue.priority or '?'), hl = 'Normal' },
    { text = '  ·  ', hl = 'NonText' },
    { text = 'Type:', hl = 'Comment' },
    { text = ' ' .. (issue.type or '?'), hl = 'Normal' },
  }, hbg)
  push_seg({
    { text = '  ', hl = nil },
    { text = 'Reporter:', hl = 'Comment' },
    { text = ' ' .. (issue.reporter or '?'), hl = 'Normal' },
    { text = '  ·  ', hl = 'NonText' },
    { text = 'Assignee:', hl = 'Comment' },
    { text = ' ' .. (issue.assignee or '?'), hl = 'Normal' },
  }, hbg)
  if issue.labels and #issue.labels > 0 then
    push_seg({
      { text = '  ', hl = nil },
      { text = 'Labels:', hl = 'Comment' },
      { text = ' ' .. table.concat(issue.labels, ', '), hl = '@string' },
    }, hbg)
  end
  push_bg('', hbg)
  push_seg({
    { text = '  ', hl = nil },
    { text = 'DESCRIPTION', hl = 'Title' },
  }, hbg)
  push_seg({
    { text = '  ', hl = nil },
    { text = string.rep('╌', dash_w), hl = 'NonText' },
  }, hbg)
  local desc = issue.description or ''
  if desc:gsub('%s', '') == '' then
    push_seg({
      { text = '  ', hl = nil },
      { text = '(no description)', hl = 'Comment' },
    }, hbg)
  else
    for _, l in ipairs(vim.split(desc, '\n', { plain = true })) do
      local idx = push_bg('  ' .. l, hbg)
      table.insert(desc_lines, { buf_row = idx, content = l })
    end
  end
  push_bg('', hbg)

  push_raw('')
  push_raw('')

  -- COMMENTS heading
  local total = issue.comment_total or #issue.comments
  push_seg({
    { text = '  ', hl = nil },
    { text = 'COMMENTS', hl = 'Title' },
    { text = '  ' .. tostring(total), hl = 'Comment' },
  })
  if total > #issue.comments then
    push_raw('')
    push_seg({
      { text = '  ', hl = nil },
      { text = 'Showing ' .. #issue.comments .. ' of ' .. total, hl = 'Comment' },
    })
  end
  push_raw('')

  if #issue.comments == 0 then
    push_seg({
      { text = '  ', hl = nil },
      { text = '(no comments yet)', hl = 'Comment' },
    })
  else
    local function emit_top(c)
      local indent = '  '
      local author = c.author or '?'
      local age = c.created and ago(c.created) or ''
      local prefix_w = vim.fn.strdisplaywidth(indent .. '  ' .. author)
      local age_w = vim.fn.strdisplaywidth(age)
      local pad_w = content_w - prefix_w - age_w - 4
      if pad_w < 2 then
        pad_w = 2
      end
      local border_w = math.max(10, content_w - 6)
      push_seg {
        { text = indent, hl = nil },
        { text = '╭' .. string.rep('─', border_w) .. '╮', hl = 'DashboardAccentJira' },
      }
      push_seg {
        { text = indent, hl = nil },
        { text = '  ', hl = nil },
        { text = author, hl = 'Title' },
        { text = string.rep(' ', pad_w), hl = nil },
        { text = age, hl = 'Comment' },
      }
      local body_max = math.max(20, border_w - 4)
      for _, l in ipairs(wrap_text(c.body or '', body_max)) do
        local idx = push_raw(indent .. '  ' .. l)
        table.insert(comment_md_lines, { buf_row = idx, col_offset = 4, content = l })
      end
      push_seg {
        { text = indent, hl = nil },
        { text = '╰' .. string.rep('─', border_w) .. '╯', hl = 'DashboardAccentJira' },
      }
    end

    local function emit_reply(c)
      local bar_prefix = '  │  '
      local bar_w = vim.fn.strdisplaywidth(bar_prefix)
      local author = c.author or '?'
      local age = c.created and ago(c.created) or ''
      local prefix_w = bar_w + 2 + vim.fn.strdisplaywidth(author)
      local age_w = vim.fn.strdisplaywidth(age)
      local pad_w = content_w - prefix_w - age_w - 4
      if pad_w < 2 then
        pad_w = 2
      end
      local border_w = math.max(10, content_w - bar_w - 4)

      push_seg {
        { text = '  ', hl = nil },
        { text = '│', hl = 'DashboardAccentJira' },
      }
      push_seg {
        { text = '  ', hl = nil },
        { text = '│  ', hl = 'DashboardAccentJira' },
        { text = '╭' .. string.rep('─', border_w) .. '╮', hl = 'DashboardAccentJira' },
      }
      push_seg {
        { text = '  ', hl = nil },
        { text = '│  ', hl = 'DashboardAccentJira' },
        { text = '  ', hl = nil },
        { text = author, hl = 'Title' },
        { text = string.rep(' ', pad_w), hl = nil },
        { text = age, hl = 'Comment' },
      }
      local body_max = math.max(20, border_w - 4)
      for _, l in ipairs(wrap_text(c.body or '', body_max)) do
        local idx = push_seg {
          { text = '  ', hl = nil },
          { text = '│  ', hl = 'DashboardAccentJira' },
          { text = '  ' .. l, hl = 'Normal' },
        }
        -- 2 (indent) + 5 ('│  ' = 3 bytes + 2 spaces) + 2 (inner spaces) = 9
        table.insert(comment_md_lines, { buf_row = idx, col_offset = 9, content = l })
      end
      push_seg {
        { text = '  ', hl = nil },
        { text = '│  ', hl = 'DashboardAccentJira' },
        { text = '╰' .. string.rep('─', border_w) .. '╯', hl = 'DashboardAccentJira' },
      }
    end

    local top_level = {}
    local replies_by_parent = {}
    for _, c in ipairs(issue.comments) do
      if c.parent_id then
        replies_by_parent[c.parent_id] = replies_by_parent[c.parent_id] or {}
        table.insert(replies_by_parent[c.parent_id], c)
      else
        table.insert(top_level, c)
      end
    end
    table.sort(top_level, function(a, b)
      return (a.created or '') > (b.created or '')
    end)
    for _, replies in pairs(replies_by_parent) do
      table.sort(replies, function(a, b)
        return (a.created or '') < (b.created or '')
      end)
    end

    for ti, tc in ipairs(top_level) do
      emit_top(tc)
      for _, rc in ipairs(replies_by_parent[tc.id] or {}) do
        emit_reply(rc)
      end
      if ti < #top_level then
        push_raw('')
      end
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, h in ipairs(range_hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, h.line, h.col_start, {
      end_col = h.col_end,
      hl_group = h.hl,
      priority = 100,
    })
  end
  for _, bg in ipairs(line_bgs) do
    vim.api.nvim_buf_set_extmark(buf, ns, bg.line, 0, {
      end_line = bg.line + 1,
      end_col = 0,
      hl_group = bg.hl,
      hl_eol = true,
      priority = 10,
    })
  end

  -- Markdown highlights over the description region (2-space indent prefix).
  for _, dl in ipairs(desc_lines) do
    apply_markdown_line_hl(buf, dl.buf_row, 2, dl.content)
  end
  -- ...and over comment bodies (per-line offset since replies are indented further).
  for _, cl in ipairs(comment_md_lines) do
    apply_markdown_line_hl(buf, cl.buf_row, cl.col_offset, cl.content)
  end

  vim.bo[buf].modifiable = false
end

function M.comments_under_cursor()
  local m = under_cursor()
  if not m or m.kind ~= 'jira' or not m.key then
    return
  end
  local handle = open_result_window(m.key, nil, 'Loading ticket…')
  require('dashboard.jira').fetch_issue(m.key, function(issue, err)
    if not issue then
      handle.set_error(err or 'failed to fetch')
      return
    end
    handle.set_content(function(buf, win)
      render_jira_issue(buf, win, issue)
    end)
  end)
end

function M.show_jira_activity(items)
  if not items or type(items) ~= 'table' or #items == 0 then
    vim.notify('No recent Jira activity', vim.log.levels.INFO)
    return
  end
  local current_items = items
  local handle = open_result_window('Jira recent activity', nil, 'Loading…')
  local line_to_item
  local function show_list()
    handle.set_content(function(buf, win)
      line_to_item = render_jira_activity_list(buf, win, current_items)
      local list_opts = { buffer = buf, nowait = true, silent = true }
      vim.keymap.set('n', '<CR>', function()
        local row = vim.api.nvim_win_get_cursor(win)[1] - 1
        local issue_meta = line_to_item and line_to_item[row]
        if not issue_meta or not issue_meta.key then
          return
        end
        handle.set_content(function(b2, _w2)
          vim.bo[b2].modifiable = true
          vim.api.nvim_buf_set_lines(b2, 0, -1, false, { '', '  ⠋  Loading ' .. issue_meta.key .. '…', '' })
          vim.bo[b2].modifiable = false
        end)
        require('dashboard.jira').fetch_issue(issue_meta.key, function(issue, err)
          if not issue then
            handle.set_error(err or 'failed to fetch')
            return
          end
          handle.set_content(function(b3, w3)
            render_jira_issue(b3, w3, issue)
            local back_opts = { buffer = b3, nowait = true, silent = true }
            vim.keymap.set('n', 'b', show_list, back_opts)
            vim.keymap.set('n', 'q', show_list, back_opts)
            vim.keymap.set('n', '<Esc>', show_list, back_opts)
          end)
        end)
      end, list_opts)
      vim.keymap.set('n', 'x', function()
        local row = vim.api.nvim_win_get_cursor(win)[1] - 1
        local issue_meta = line_to_item and line_to_item[row]
        if not issue_meta or not issue_meta.key then
          return
        end
        seen.mark(issue_meta.key, issue_meta.updated_at or issue_meta.status_change_at)
        local remaining = {}
        for _, it in ipairs(current_items) do
          if it.key ~= issue_meta.key then
            table.insert(remaining, it)
          end
        end
        current_items = remaining
        if #current_items == 0 then
          handle.close()
          if buf_valid() then
            render()
          end
          return
        end
        show_list()
        if buf_valid() then
          render()
        end
      end, list_opts)
    end)
  end
  show_list()
end

function M.actions_under_cursor()
  local m = under_cursor()
  local repo
  if m and m.pr and m.pr.repo then
    repo = m.pr.repo
  end
  if not repo then
    vim.notify('Place cursor on a PR or PR notification row first', vim.log.levels.INFO)
    return
  end
  local handle = open_result_window('Actions · ' .. repo, nil, 'Loading workflow runs…')
  require('dashboard.github').fetch_actions(repo, function(items, err)
    if not items then
      handle.set_error(err or 'failed to fetch')
      return
    end
    handle.set_content(function(buf, win)
      local line_to_item = render_actions_list(buf, win, items, repo)
      vim.keymap.set('n', '<CR>', function()
        local row = vim.api.nvim_win_get_cursor(win)[1] - 1
        local run = line_to_item and line_to_item[row]
        if run and run.url then
          vim.ui.open(run.url)
        end
      end, { buffer = buf, nowait = true, silent = true })
    end)
  end)
end

-- Detect a base branch to diff against. Tries common base branches in order.
local function detect_base_branch(cwd, callback)
  local candidates = { 'origin/develop', 'develop', 'origin/main', 'main', 'origin/master', 'master' }
  local idx = 1
  local function try_next()
    if idx > #candidates then
      callback(nil)
      return
    end
    local c = candidates[idx]
    idx = idx + 1
    vim.system({ 'git', '-C', cwd, 'rev-parse', '--verify', '--quiet', c }, { text = true }, function(obj)
      vim.schedule(function()
        if obj.code == 0 then
          callback(c)
        else
          try_next()
        end
      end)
    end)
  end
  try_next()
end

-- Fetch local diff (vs detected base branch, or user-supplied target) including
-- untracked files. Callback receives (diff_text, err, label). diff_text is ''
-- for no changes. target_override, if provided, skips base detection.
local function fetch_local_diff(callback, target_override)
  local cwd = vim.fn.getcwd()
  vim.system({ 'git', '-C', cwd, 'rev-parse', '--is-inside-work-tree' }, { text = true }, function(check)
    vim.schedule(function()
      if check.code ~= 0 then
        callback(nil, 'Not inside a git repository', nil)
        return
      end
      local function with_target(target, label)
        local results = { tracked = nil, untracked = nil }
        local pending = 2
        local function done_inner()
          pending = pending - 1
          if pending > 0 then
            return
          end
          local diff = (results.tracked or '') .. (results.untracked or '')
          callback(diff, nil, label)
        end
        vim.system({ 'git', '-C', cwd, 'merge-base', target, 'HEAD' }, { text = true }, function(mb)
          vim.schedule(function()
            local diff_target = (mb.code == 0 and mb.stdout and mb.stdout ~= '')
                and vim.trim(mb.stdout)
              or target
            vim.system({ 'git', '-C', cwd, 'diff', diff_target }, { text = true }, function(obj)
              vim.schedule(function()
                if obj.code ~= 0 then
                  results.tracked = ''
                else
                  results.tracked = obj.stdout or ''
                end
                done_inner()
              end)
            end)
          end)
        end)
        vim.system(
          { 'git', '-C', cwd, 'ls-files', '--others', '--exclude-standard' },
          { text = true },
          function(ls)
            vim.schedule(function()
              if ls.code ~= 0 then
                results.untracked = ''
                done_inner()
                return
              end
              local files = {}
              for f in (ls.stdout or ''):gmatch '[^\n]+' do
                table.insert(files, f)
              end
              if #files == 0 then
                results.untracked = ''
                done_inner()
                return
              end
              local remaining = #files
              local chunks = {}
              for i, file in ipairs(files) do
                vim.system(
                  { 'git', '-C', cwd, 'diff', '--no-index', '--', '/dev/null', file },
                  { text = true },
                  function(d)
                    vim.schedule(function()
                      if (d.code == 0 or d.code == 1) and d.stdout and d.stdout ~= '' then
                        chunks[i] = d.stdout
                      else
                        chunks[i] = ''
                      end
                      remaining = remaining - 1
                      if remaining == 0 then
                        local parts = {}
                        for j = 1, #files do
                          if chunks[j] and chunks[j] ~= '' then
                            table.insert(parts, chunks[j])
                          end
                        end
                        results.untracked = table.concat(parts, '\n')
                        done_inner()
                      end
                    end)
                  end
                )
              end
            end)
          end
        )
      end

      if target_override and target_override ~= '' then
        with_target(target_override, target_override)
        return
      end

      detect_base_branch(cwd, function(base)
        if base then
          with_target(base, base)
        else
          vim.system(
            { 'git', '-C', cwd, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}' },
            { text = true },
            function(up)
              vim.schedule(function()
                local target, label
                if up.code == 0 then
                  target = vim.trim(up.stdout or '')
                  label = target
                else
                  target = 'HEAD'
                  label = 'HEAD'
                end
                with_target(target, label)
              end)
            end
          )
        end
      end)
    end)
  end)
end


local function open_local_diff(target_override)
  if diff_viewer_open() then
    focus_diff_viewer()
    return
  end
  show_loading('Loading local diff…')
  fetch_local_diff(function(diff, err, label)
    if err then
      clear_loading()
      vim.notify(err, vim.log.levels.WARN)
      return
    end
    if not diff or diff:gsub('%s', '') == '' then
      clear_loading()
      vim.notify('No local changes vs ' .. (label or '?'), vim.log.levels.INFO)
      return
    end
    local cwd = vim.fn.getcwd()
    local branch = vim.fn.fnamemodify(cwd, ':t')
    local title = string.format('%s · local vs %s', branch, label)
    open_diff_window(title, diff, nil, {
      cwd = cwd,
      refresh_fn = function(cb)
        fetch_local_diff(function(new_diff, new_err)
          cb(new_diff, new_err)
        end, target_override)
      end,
      initial_cursor = state.local_diff_cursor,
      on_close = function(cur)
        state.local_diff_cursor = cur
      end,
    })
  end, target_override)
end

function M.show_local_diff()
  open_local_diff(nil)
end

local function list_branches(callback)
  local cwd = vim.fn.getcwd()
  vim.system({
    'git',
    '-C',
    cwd,
    'for-each-ref',
    '--format=%(refname:short)',
    'refs/heads',
    'refs/remotes',
  }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        callback({})
        return
      end
      local branches = {}
      local seen = {}
      for line in (obj.stdout or ''):gmatch '[^\n]+' do
        local b = vim.trim(line)
        if b ~= '' and not b:match '/HEAD$' and not seen[b] then
          seen[b] = true
          table.insert(branches, b)
        end
      end
      callback(branches)
    end)
  end)
end

local function pick_branch(callback)
  list_branches(function(branches)
    if #branches == 0 then
      vim.notify('No branches found', vim.log.levels.WARN)
      return
    end
    local ok, pickers = pcall(require, 'telescope.pickers')
    if ok then
      local finders = require 'telescope.finders'
      local conf = require('telescope.config').values
      local actions = require 'telescope.actions'
      local action_state = require 'telescope.actions.state'
      pickers
        .new({}, {
          prompt_title = 'Diff vs branch/commit',
          finder = finders.new_table { results = branches },
          sorter = conf.generic_sorter {},
          attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
              local entry = action_state.get_selected_entry()
              actions.close(prompt_bufnr)
              if entry then
                local val = entry.value or entry[1]
                if val and val ~= '' then
                  callback(val)
                end
              end
            end)
            return true
          end,
        })
        :find()
    else
      vim.ui.select(branches, { prompt = 'Diff vs branch/commit' }, function(choice)
        if choice and choice ~= '' then
          callback(choice)
        end
      end)
    end
  end)
end

local function list_commits(callback)
  local cwd = vim.fn.getcwd()
  vim.system({
    'git',
    '-C',
    cwd,
    'log',
    '-n',
    '50',
    '--date=format:%Y-%m-%d %H:%M',
    '--pretty=format:%h\31%cd\31%cr\31%s\31%an',
  }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        callback({})
        return
      end
      local commits = {}
      for line in (obj.stdout or ''):gmatch '[^\n]+' do
        local sha, date, age, subject, author = line:match '^([^\31]+)\31([^\31]*)\31([^\31]*)\31([^\31]*)\31(.*)$'
        if sha then
          table.insert(commits, { sha = sha, date = date, age = age, subject = subject, author = author })
        end
      end
      callback(commits)
    end)
  end)
end

local function pick_commit(callback)
  list_commits(function(commits)
    if #commits == 0 then
      vim.notify('No commits found', vim.log.levels.WARN)
      return
    end
    local function fmt(c)
      return string.format('%s  %s  %s  · %s', c.sha, c.date, c.subject, c.age)
    end
    local ok, pickers = pcall(require, 'telescope.pickers')
    if ok then
      local finders = require 'telescope.finders'
      local conf = require('telescope.config').values
      local actions = require 'telescope.actions'
      local action_state = require 'telescope.actions.state'
      pickers
        .new({}, {
          prompt_title = 'Diff vs commit',
          finder = finders.new_table {
            results = commits,
            entry_maker = function(c)
              return {
                value = c.sha,
                display = fmt(c),
                ordinal = c.sha .. ' ' .. c.subject .. ' ' .. c.author,
              }
            end,
          },
          sorter = conf.generic_sorter {},
          attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
              local entry = action_state.get_selected_entry()
              actions.close(prompt_bufnr)
              if entry and entry.value then
                callback(entry.value)
              end
            end)
            return true
          end,
        })
        :find()
    else
      local items = {}
      for _, c in ipairs(commits) do
        table.insert(items, fmt(c))
      end
      vim.ui.select(items, { prompt = 'Diff vs commit' }, function(_, idx)
        if idx and commits[idx] then
          callback(commits[idx].sha)
        end
      end)
    end
  end)
end

function M.show_local_diff_with_prompt()
  vim.ui.select({ 'Branch', 'Commit' }, { prompt = 'Diff vs:' }, function(choice)
    if choice == 'Branch' then
      pick_branch(function(target)
        open_local_diff(target)
      end)
    elseif choice == 'Commit' then
      pick_commit(function(target)
        open_local_diff(target)
      end)
    end
  end)
end

function M.diff_under_cursor()
  local m = under_cursor()
  if not m or not m.pr then
    return
  end
  if diff_viewer_open() then
    focus_diff_viewer()
    return
  end
  show_loading('Loading diff…')

  local results = { diff = nil, overview = nil, threads = nil, issue_comments = nil }
  local pending = 4
  local errored = false
  local function done()
    pending = pending - 1
    if pending > 0 or errored then
      return
    end
    if results.overview then
      results.overview.issue_comments = results.issue_comments or {}
    end
    local title = string.format('%s#%d', m.pr.repo, m.pr.number)
    open_diff_window(title, results.diff, results.overview, { threads = results.threads })
  end

  require('dashboard.github').fetch_pr_diff(m.pr.repo, m.pr.number, m.url, function(diff, err)
    if not diff then
      errored = true
      vim.notify('Failed to fetch diff: ' .. (err or ''), vim.log.levels.ERROR)
      return
    end
    results.diff = diff
    done()
  end)
  require('dashboard.github').fetch_review_threads(m.pr.repo, m.pr.number, function(threads)
    results.threads = threads or {}
    done()
  end)
  require('dashboard.github').fetch_issue_comments(m.pr.repo, m.pr.number, function(comments)
    results.issue_comments = comments or {}
    done()
  end)
  require('dashboard.github').fetch_pr_overview(m.pr.repo, m.pr.number, function(overview)
    if overview then
      overview.repo = m.pr.repo
    end
    results.overview = overview
    done()
  end)
end

function open_result_window(title, on_reprompt, loading_text)
  loading_text = loading_text or 'Loading…'
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'

  local dash = compute_dashboard_geom()
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = dash.width,
    height = dash.height,
    row = dash.row,
    col = dash.col,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. title .. ' ',
    title_pos = 'center',
    zindex = 60,
  })
  state.last_result_win = win
  vim.wo[win].cursorline = false
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight =
    'Normal:DashboardNormal,NormalFloat:DashboardNormal,FloatBorder:DashboardFloatBorder'

  on_viewer_open(win)

  local frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
  local frame_i = 1
  local timer = vim.uv.new_timer()
  local stopped = false
  local function stop_spinner()
    if stopped then
      return
    end
    stopped = true
    timer:stop()
    timer:close()
  end

  local function set_lines(text_lines)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, text_lines)
    vim.bo[buf].modifiable = false
  end

  set_lines { '', '  ⠋  ' .. loading_text, '' }

  timer:start(
    80,
    80,
    vim.schedule_wrap(function()
      if stopped or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
        stop_spinner()
        return
      end
      vim.bo[buf].modifiable = true
      pcall(vim.api.nvim_buf_set_lines, buf, 1, 2, false, { '  ' .. frames[frame_i] .. '  ' .. loading_text })
      vim.bo[buf].modifiable = false
      frame_i = (frame_i % #frames) + 1
    end)
  )

  local closed = false
  local close = function()
    if closed then
      return
    end
    closed = true
    stop_spinner()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    refocus_dashboard(win)
  end
  local opts = { buffer = buf, nowait = true, silent = true }
  apply_tmux_nav_keymaps(buf)
  vim.keymap.set('n', 'q', close, opts)
  vim.keymap.set('n', '<Esc>', close, opts)

  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function()
      if not closed then
        closed = true
        stop_spinner()
        vim.schedule(function()
          refocus_dashboard(win)
        end)
      end
    end,
  })

  local function set_content(text_or_renderer)
    stop_spinner()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    -- Re-establish close keymaps in case a previous renderer remapped them
    -- (e.g. detail views that rebind q to a "back" action).
    vim.keymap.set('n', 'q', close, opts)
    vim.keymap.set('n', '<Esc>', close, opts)
    if type(text_or_renderer) == 'function' then
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
      vim.bo[buf].modifiable = false
      text_or_renderer(buf, win)
    else
      set_lines(vim.split(text_or_renderer, '\n', { plain = true }))
    end
    if on_reprompt then
      local _, order = require('dashboard.claude').prompts()
      for i, key in ipairs(order) do
        if i <= 9 then
          vim.keymap.set('n', tostring(i), function()
            close()
            on_reprompt(key)
          end, opts)
        end
      end
    end
  end

  local function set_error(msg)
    stop_spinner()
    set_lines { '', '  ✗  ' .. (msg or 'unknown error'), '' }
  end

  return { set_content = set_content, set_error = set_error, close = close }
end

local function row_id(meta)
  if meta.kind == 'pr' and meta.pr then
    return meta.pr.repo .. '#' .. meta.pr.number
  end
  if meta.kind == 'jira' and meta.key then
    return meta.key
  end
  return '?'
end

local function run_claude(meta, prompt_key)
  local claude = require 'dashboard.claude'
  local prompts_tbl = claude.prompts()
  local label = (prompts_tbl[prompt_key] and prompts_tbl[prompt_key].label) or prompt_key
  local title = string.format('%s · %s', label, row_id(meta))
  local handle = open_result_window(title, function(next_key)
    run_claude(meta, next_key)
  end, 'Asking Claude…')
  claude.analyze(meta, prompt_key, function(result, err)
    if not result then
      handle.set_error(err or 'unknown')
      return
    end
    local prompts_tbl, order = claude.prompts()
    handle.set_content(function(buf, _win)
      local text = (result.text or ''):gsub('\r', '')
      local body_lines = vim.split(text, '\n', { plain = true })
      while #body_lines > 0 and body_lines[#body_lines] == '' do
        table.remove(body_lines)
      end

      local footer_segs = { { text = '  ', hl = nil } }
      for i, key in ipairs(order) do
        if i > 1 then
          table.insert(footer_segs, { text = '  ', hl = nil })
        end
        table.insert(footer_segs, { text = ' ' .. tostring(i) .. ' ', hl = 'DashboardPillInfo' })
        table.insert(footer_segs, { text = ' ' .. (prompts_tbl[key].label or key):lower(), hl = 'Comment' })
      end
      table.insert(footer_segs, { text = '  ', hl = nil })
      table.insert(footer_segs, { text = ' q ', hl = 'DashboardPillMuted' })
      table.insert(footer_segs, { text = ' close', hl = 'Comment' })

      local footer_text = ''
      local footer_hls = {}
      for _, s in ipairs(footer_segs) do
        local col_start = #footer_text
        footer_text = footer_text .. s.text
        if s.hl then
          table.insert(footer_hls, { col_start = col_start, col_end = #footer_text, hl = s.hl })
        end
      end

      local lines = {}
      for _, l in ipairs(body_lines) do
        table.insert(lines, l)
      end
      table.insert(lines, '')
      table.insert(lines, '')
      local footer_line_idx = #lines
      table.insert(lines, footer_text)

      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false

      for _, h in ipairs(footer_hls) do
        vim.api.nvim_buf_set_extmark(buf, ns, footer_line_idx, h.col_start, {
          end_col = h.col_end,
          hl_group = h.hl,
          priority = 100,
        })
      end
    end)
  end)
end

function M.analyze_under_cursor(prompt_key)
  local m = under_cursor()
  if not m or not m.kind then
    return
  end
  run_claude(m, prompt_key or 'summary')
end

function M.pick_prompt_under_cursor()
  local m = under_cursor()
  if not m or not m.kind then
    return
  end
  local claude = require 'dashboard.claude'
  local prompts, order = claude.prompts()
  local labels = {}
  for _, k in ipairs(order) do
    table.insert(labels, prompts[k].label)
  end
  vim.ui.select(labels, { prompt = 'Claude prompt:' }, function(_, idx)
    if not idx then
      return
    end
    run_claude(m, order[idx])
  end)
end

function M.mark_read_under_cursor()
  local m = under_cursor()
  if not m or not m.notification_id then
    return
  end
  local id = m.notification_id
  vim.system({ 'gh', 'api', '-X', 'PATCH', 'notifications/threads/' .. id }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        vim.notify('Failed to mark as read: ' .. (obj.stderr or ''), vim.log.levels.ERROR)
        return
      end
      if type(state.data.notifications) == 'table' then
        local kept = {}
        for _, n in ipairs(state.data.notifications) do
          if n.id ~= id then
            table.insert(kept, n)
          end
        end
        state.data.notifications = kept
        render()
      end
    end)
  end)
end

function M.yank_under_cursor()
  local m = under_cursor()
  if m and m.url then
    vim.fn.setreg('+', m.url)
    vim.notify('Yanked: ' .. m.url)
  end
end

function M.close()
  stop_spinner()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.win = nil
  state.buf = nil
  state.line_meta = {}
  state.dashboard_cursor = nil
  state.viewer_count = 0
end

function M.focus_last_result()
  local w = state.last_result_win
  if w and vim.api.nvim_win_is_valid(w) then
    vim.api.nvim_set_current_win(w)
  else
    vim.notify('No active result window', vim.log.levels.INFO)
  end
end

local HELP_TEXT = [[# Status Dashboard — Keymaps

## Global
  <CR>    open url in browser; on a repo / jira section header: collapse / expand
  y       yank url
  f       filter every section by substring
  r       refresh now
  q       close dashboard
  g?      this help
  J       open the centered jump picker (one key to pick a section)
  1       jump to Notes
  2       jump to GitHub
  3       jump to Notifications
  4       jump to Jira
  <leader>od   open / refocus dashboard
  <leader>or   focus last result window
  <leader>gd   local git diff (vs detected base: develop → main → master)
  <leader>gD   local git diff vs custom branch/commit (prompts)

## Notes section
  n       new note (auto-prepends "- ")
  T       new todo (auto-prepends "- [ ] ")
  x       toggle todo checkbox on the cursor row
  <CR>    open today's notes file for editing

## GitHub PR rows
  c       checkout PR, open repo in nvim
  i       checkout + claude interactive in tmux pane
  D       two-pane diff viewer (file list + diff, inline review threads)
  a       last 20 GitHub Actions runs for this PR's repo
  s       claude summary
  ?       claude prompt picker (summary / understand / risks / next / code review)

## Jira rows
  C       read ticket description + comments in a panel

## Notifications
  x       mark notification as read

## Jira recent (inside <CR> list)
  x       mark ticket as seen (hides until it updates again)
  <CR>    open ticket details

## Diff viewer
  <CR>    on file: jump to that file's first hunk; on dir: collapse/expand
  <Tab>   toggle focus (files ↔ content); re-opens files if hidden
  }       next file in the diff (right pane)
  {       previous file in the diff (right pane)
  c       (PR diff) comment on line under cursor; visual: range; on a thread: reply
  R       (PR diff) submit review: approve / request changes / comment
  \       toggle the file explorer pane (full-screen the content)
  r       refresh (local diff viewer only)
  q       close both panes

## Claude / threads window
  1-5     re-prompt against cached context
  q       close

## Badge legend
  CI:        ✓ pass   ✗ fail   ● pending   · n/a
  Review:    ✓ 2+ approvals   ◐ 1 approval   ○ none yet   ✗ changes requested   · no review required
]]

function M.show_help()
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(HELP_TEXT, '\n', { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'

  local width = math.min(82, math.floor(vim.o.columns * 0.6))
  local height = math.min(40, math.floor(vim.o.lines * 0.85))
  local statusline = vim.o.laststatus > 0 and 1 or 0
  local available = vim.o.lines - vim.o.cmdheight - statusline
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((available - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' Keymaps ',
    title_pos = 'center',
    zindex = 60,
  })
  vim.wo[win].cursorline = false
  vim.wo[win].wrap = false

  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    refocus_dashboard()
  end
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set('n', 'q', close, opts)
  vim.keymap.set('n', '<Esc>', close, opts)
  vim.keymap.set('n', 'g?', close, opts)
end

function M.section_picker()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return
  end
  local lines = { '' }
  local width = 0
  for _, item in ipairs(LEGEND_ITEMS) do
    local row = '   ' .. item.key .. '   ' .. item.label .. '   '
    table.insert(lines, row)
    width = math.max(width, vim.fn.strdisplaywidth(row))
  end
  table.insert(lines, '')
  width = math.max(width, 20)
  local height = #lines

  local dash = vim.api.nvim_win_get_config(state.win)
  local row = dash.row + math.floor((dash.height - height) / 2)
  local col = dash.col + 2

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' Jump to section ',
    title_pos = 'center',
    zindex = 200,
  })
  vim.wo[win].winhighlight =
    'Normal:DashboardCardBgAlt,NormalFloat:DashboardCardBgAlt,FloatBorder:DashboardFloatBorder,FloatTitle:Title'
  vim.wo[win].cursorline = false

  local ns_p = vim.api.nvim_create_namespace 'dashboard_picker'
  for i, item in ipairs(LEGEND_ITEMS) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns_p, i, 3, {
      end_col = 3 + #item.key,
      hl_group = '@keyword',
    })
  end

  local function close_and_jump(target)
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      pcall(vim.api.nvim_set_current_win, state.win)
    end
    if target then
      M.jump_to_section(target)
    end
  end

  local kopts = { buffer = buf, nowait = true, silent = true }
  for _, item in ipairs(LEGEND_ITEMS) do
    vim.keymap.set('n', item.key, function()
      close_and_jump(item.target)
    end, kopts)
  end
  vim.keymap.set('n', 'q', function()
    close_and_jump(nil)
  end, kopts)
  vim.keymap.set('n', '<Esc>', function()
    close_and_jump(nil)
  end, kopts)
end

function M.jump_to_section(title)
  if not buf_valid() or not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return
  end
  local idx = state.section_lines and state.section_lines[title]
  if not idx then
    vim.notify('Section not found: ' .. title, vim.log.levels.INFO)
    return
  end
  local row = idx + 1
  pcall(vim.api.nvim_win_set_cursor, state.win, { row, 0 })
  vim.api.nvim_win_call(state.win, function()
    vim.cmd 'normal! zt'
  end)
end

function M.filter_prompt()
  vim.ui.input({ prompt = 'Filter: ', default = state.filter or '' }, function(input)
    if input == nil then
      return
    end
    state.filter = (input ~= '' and input) or nil
    if buf_valid() then
      render()
    end
  end)
end

local function any_loading()
  return state.data.my_prs == nil
    or state.data.reviews == nil
    or state.data.tagged == nil
    or state.data.notifications == nil
    or state.data.jira_active == nil
    or state.data.qa_active == nil
    or state.data.jira_activity == nil
end

function stop_spinner()
  if spinner_state.timer then
    spinner_state.timer:stop()
    spinner_state.timer:close()
    spinner_state.timer = nil
  end
end

local function start_spinner()
  if spinner_state.timer then
    return
  end
  spinner_state.timer = vim.uv.new_timer()
  spinner_state.timer:start(
    80,
    80,
    vim.schedule_wrap(function()
      if not buf_valid() or not any_loading() then
        stop_spinner()
        return
      end
      spinner_state.frame_i = (spinner_state.frame_i % #SPINNER_FRAMES) + 1
      render()
    end)
  )
end

function M.refresh()
  state.data = {
    my_prs = nil,
    reviews = nil,
    tagged = nil,
    notifications = nil,
    jira_active = nil,
    qa_active = nil,
    jira_activity = nil,
  }
  start_spinner()
  render()

  local function update(key)
    return function(result, err)
      if not result and err then
        state.data[key] = err
      else
        state.data[key] = result or false
      end
      state.last_refresh = os.time()
      render()
    end
  end

  github.fetch_prs(function(result, err)
    if not result then
      state.data.my_prs = err or false
      state.data.reviews = err or false
      state.data.tagged = err or false
    else
      state.data.my_prs = result.my_prs
      state.data.reviews = result.reviews
      state.data.tagged = result.tagged
    end
    state.last_refresh = os.time()
    render()
  end)
  github.fetch_notifications(function(result, err)
    if not result then
      state.data.notifications = err or false
    else
      state.data.notifications = result
    end
    state.last_refresh = os.time()
    render()
    if type(result) == 'table' and #result > 0 then
      github.enrich_notifications(result, function()
        if buf_valid() then
          render()
        end
      end)
    end
  end)
  jira.assigned_active(update 'jira_active')
  jira.qa_assignee_active(update 'qa_active')
  jira.recent_activity(update 'jira_activity')
  if not state.me_account_id then
    jira.fetch_myself(function(id)
      if id then
        state.me_account_id = id
        if buf_valid() then
          render()
        end
      end
    end)
  end
end

local function apply_dashboard_win_opts()
  vim.wo[state.win].cursorline = false
  vim.wo[state.win].wrap = false
  vim.wo[state.win].winhighlight =
    'Normal:DashboardNormal,NormalFloat:DashboardNormal,FloatBorder:DashboardFloatBorder,WinBar:DashboardWinBar,WinBarNC:DashboardWinBar'
  vim.wo[state.win].sidescrolloff = 4
  vim.wo[state.win].winbar = '%{%v:lua.require("dashboard.ui").winbar()%}'
end

function M.open()
  close_all_viewers()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  local restoring = state.buf and vim.api.nvim_buf_is_valid(state.buf)

  if not restoring then
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.buf].bufhidden = 'hide'
    vim.bo[state.buf].filetype = 'dashboard'
  end

  local geom = compute_dashboard_geom()
  state.win = vim.api.nvim_open_win(state.buf, true, vim.tbl_extend('force', geom, {
    style = 'minimal',
    border = 'rounded',
    title = ' Status Dashboard ',
    title_pos = 'center',
  }))

  apply_dashboard_win_opts()

  if restoring then
    if state.dashboard_cursor then
      pcall(vim.api.nvim_win_set_cursor, state.win, state.dashboard_cursor)
    end
    return
  end

  local opts = { buffer = state.buf, nowait = true, silent = true }
  apply_tmux_nav_keymaps(state.buf)
  vim.keymap.set('n', 'q', M.close, opts)
  vim.keymap.set('n', '<Esc>', M.close, opts)
  vim.keymap.set('n', 'r', M.refresh, opts)
  vim.keymap.set('n', '<CR>', M.open_under_cursor, opts)
  vim.keymap.set('n', 'y', M.yank_under_cursor, opts)
  vim.keymap.set('n', 'c', M.checkout_under_cursor, opts)
  vim.keymap.set('n', 'i', M.interactive_claude_under_cursor, opts)
  vim.keymap.set('n', 'D', M.diff_under_cursor, opts)
  vim.keymap.set('n', 'a', M.actions_under_cursor, opts)
  for _, item in ipairs(LEGEND_ITEMS) do
    vim.keymap.set('n', item.key, function()
      M.jump_to_section(item.target)
    end, opts)
  end
  vim.keymap.set('n', 'J', M.section_picker, opts)
  vim.keymap.set('n', 'C', M.comments_under_cursor, opts)
  vim.keymap.set('n', 'x', function()
    local m = under_cursor()
    if not m then
      return
    end
    if m.notification_id then
      M.mark_read_under_cursor()
    elseif m.kind == 'note' and m.file_line then
      M.toggle_todo()
    end
  end, opts)
  vim.keymap.set('n', 'T', M.add_todo, opts)
  vim.keymap.set('n', 's', function()
    M.analyze_under_cursor 'summary'
  end, opts)
  vim.keymap.set('n', '?', M.pick_prompt_under_cursor, opts)
  vim.keymap.set('n', 'f', M.filter_prompt, opts)
  vim.keymap.set('n', 'g?', M.show_help, opts)
  vim.keymap.set('n', 'n', M.add_note, opts)

  vim.api.nvim_create_autocmd('FocusGained', {
    buffer = state.buf,
    callback = function()
      if state.last_refresh and (os.time() - state.last_refresh) > config.refresh_after then
        M.refresh()
      end
    end,
  })

  vim.api.nvim_create_autocmd('VimResized', {
    buffer = state.buf,
    callback = function()
      if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
        return
      end
      pcall(vim.api.nvim_win_set_config, state.win, compute_dashboard_geom())
      render()
    end,
  })

  local function update_cursor_hl()
    if not buf_valid() then
      return
    end
    vim.api.nvim_buf_clear_namespace(state.buf, cursor_ns, 0, -1)
    if state.win and vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_get_current_win() == state.win then
      local row = vim.api.nvim_win_get_cursor(state.win)[1] - 1
      vim.api.nvim_buf_set_extmark(state.buf, cursor_ns, row, 0, {
        end_line = row + 1,
        end_col = 0,
        hl_group = 'DashboardCursorLine',
        hl_eol = true,
        priority = 1000,
      })
    end
  end

  vim.api.nvim_create_autocmd({ 'CursorMoved', 'WinEnter', 'BufEnter' }, {
    buffer = state.buf,
    callback = update_cursor_hl,
  })
  vim.api.nvim_create_autocmd({ 'WinLeave', 'BufLeave' }, {
    buffer = state.buf,
    callback = function()
      if buf_valid() then
        vim.api.nvim_buf_clear_namespace(state.buf, cursor_ns, 0, -1)
      end
    end,
  })

  M.refresh()
  update_cursor_hl()
end

return M
