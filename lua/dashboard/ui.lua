local github = require 'dashboard.github'
local jira = require 'dashboard.jira'

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

function M.setup(opts)
  opts = opts or {}
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
    hl = 'DiagnosticError'
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

local function refocus_dashboard()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_set_current_win, state.win)
  end
end

local function emit(lines, segments)
  local text = ''
  local cols = {}
  for _, seg in ipairs(segments) do
    cols[#cols + 1] = { col_start = #text, col_end = #text + #seg.text, hl = seg.hl }
    text = text .. seg.text
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
end

local function emit_subhead(lines, title, count, pill_hl)
  local count_str = count and tostring(count) or ''
  local segments = { { text = '  ', hl = nil } }
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
end

local SPINNER_FRAMES = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local spinner_state = { timer = nil, frame_i = 1 }

local function emit_status(lines, kind, text)
  local hl = kind == 'loading' and 'Comment' or kind == 'error' and 'DiagnosticError' or 'Comment'
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
    return '✓', 'DiagnosticOk'
  end
  if status == 'FAILURE' or status == 'ERROR' then
    return '✗', 'DiagnosticError'
  end
  if status == 'PENDING' or status == 'EXPECTED' then
    return '●', 'DiagnosticWarn'
  end
  return '·', 'NonText'
end

local function review_badge(decision, approvals)
  if decision == 'CHANGES_REQUESTED' then
    return '✗', 'DiagnosticError'
  end
  approvals = approvals or 0
  if approvals >= 2 then
    return '✓', 'DiagnosticOk'
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
    return 'DiagnosticError'
  end
  if s:find 'done' or s:find 'closed' or s:find 'resolved' then
    return 'DiagnosticOk'
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

local function emit_repo_header(lines, name, count)
  local idx, cols = emit(lines, {
    { text = '    ', hl = nil },
    { text = tostring(count) .. '  ', hl = '@number' },
    { text = name, hl = '@string' },
  })
  paint(idx, cols)
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
  local count = type(items) == 'table' and #items or nil
  subsection_box(lines, 'top')
  emit_subhead(lines, title, count, opts and opts.pill_hl or nil)
  if items == nil then
    emit_status(lines, 'loading', 'Loading…')
  elseif items == false then
    emit_status(lines, 'error', 'Failed to load')
  elseif type(items) == 'string' then
    emit_status(lines, 'error', items)
  elseif #items == 0 then
    emit_status(lines, 'empty', empty_label or 'Nothing here')
  else
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
      emit_repo_header(lines, repo_name, #groups[repo_name])
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
    { text = '✓', hl = 'DiagnosticOk' },
    { text = ' pass · ', hl = 'Comment' },
    { text = '✗', hl = 'DiagnosticError' },
    { text = ' fail · ', hl = 'Comment' },
    { text = '●', hl = 'DiagnosticWarn' },
    { text = ' pending', hl = 'Comment' },
    CLOSE_BR,
    GAP,
    OPEN_BR,
    { text = 'Review: ', hl = 'Comment' },
    { text = '✓', hl = 'DiagnosticOk' },
    { text = ' 2+ · ', hl = 'Comment' },
    { text = '◐', hl = 'DiagnosticWarn' },
    { text = ' 1 · ', hl = 'Comment' },
    { text = '○', hl = 'DiagnosticWarn' },
    { text = ' 0 · ', hl = 'Comment' },
    { text = '✗', hl = 'DiagnosticError' },
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
      { text = line:sub(1, e), hl = 'DiagnosticOk' },
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
  current_section_accent = nil

  sort_prs_by_repo(state.data.my_prs)
  sort_prs_by_repo(state.data.reviews)
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

  emit_divider(lines, 'Notifications')
  emit_blank(lines)
  emit_section(lines, meta, 'Inbox', notifications, function(ls, m, n)
    emit_notification(ls, m, n)
  end, 'No notifications')

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
        end, '', { pill_hl = jira_status_pill(status) })
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
      end, '')
    end
  end

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
  if m.kind == 'note' and m.path then
    M.close()
    vim.cmd('edit ' .. vim.fn.fnameescape(m.path))
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

local function parse_diff(diff_text)
  local lines = vim.split(diff_text or '', '\n', { plain = true })
  local files = {}
  local current
  for i, line in ipairs(lines) do
    if line:match '^diff %-%-git ' then
      if current then
        table.insert(files, current)
      end
      local b_path = line:match 'b/(.+)$' or '?'
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

local function open_diff_window(title, body, overview)
  local files = parse_diff(body)

  -- Layout: two abutting floating windows.
  -- total visual width = left_content + right_content + 4 (four borders).
  local total_w = math.min(160, math.floor(vim.o.columns * 0.9))
  local left_content_w = 35
  local right_content_w = total_w - left_content_w - 4
  if right_content_w < 40 then
    -- Narrow terminals: shrink left pane.
    left_content_w = math.max(20, total_w - 44)
    right_content_w = total_w - left_content_w - 4
  end
  local height = math.min(50, math.floor(vim.o.lines * 0.9))
  local statusline = vim.o.laststatus > 0 and 1 or 0
  local available = vim.o.lines - vim.o.cmdheight - statusline
  local row = math.floor((available - height) / 2)
  local total_col_start = math.floor((vim.o.columns - total_w) / 2)
  local left_col = total_col_start + 1
  local right_col = left_col + left_content_w + 2

  -- Build PR header lines
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

  emit_pr_header_card(right_content_w, overview, h_push_raw, h_push_bg, h_push_seg)
  local header_len = #header_lines

  -- Right (diff) buffer + window
  local right_buf = vim.api.nvim_create_buf(false, true)
  local body_lines = vim.split(body or '', '\n', { plain = true })
  local combined = {}
  for _, l in ipairs(header_lines) do
    table.insert(combined, l)
  end
  for _, l in ipairs(body_lines) do
    table.insert(combined, l)
  end
  vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, combined)
  vim.bo[right_buf].filetype = ''
  vim.bo[right_buf].buftype = 'nofile'
  vim.bo[right_buf].modifiable = false
  vim.bo[right_buf].bufhidden = 'wipe'

  -- Apply header extmarks
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

  -- Pass 1: classify each line, compute old/new line numbers, find max widths
  local row_info = {}
  local old_l, new_l = 0, 0
  local max_old, max_new = 1, 1
  for i, line in ipairs(body_lines) do
    local info = {}
    if line:match '^diff %-%-git ' then
      old_l, new_l = 0, 0
      info.is_file_header = true
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
      info.bg = 'DiffAdd'
    elseif line:sub(1, 1) == '-' then
      old_l = old_l + 1
      info.old = old_l
      info.bg = 'DiffDelete'
    else
      -- context
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
    row_info[i] = info
  end

  local empty_old = string.rep(' ', max_old)
  local empty_new = string.rep(' ', max_new)
  local fmt_old = '%' .. max_old .. 'd'
  local fmt_new = '%' .. max_new .. 'd'

  -- Pass 2: apply extmarks (separator above each file, gutter, background)
  for i, line in ipairs(body_lines) do
    local info = row_info[i]
    local buf_line = i - 1 + header_len
    if info.is_file_header then
      local fname = line:match 'b/(.+)$' or '?'
      local label = ' ' .. fname .. ' '
      if #label > right_content_w - 10 then
        local visible = math.max(3, right_content_w - 14)
        label = ' …' .. fname:sub(#fname - visible + 1) .. ' '
      end
      local pad_total = right_content_w - #label
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
      vim.api.nvim_buf_set_extmark(right_buf, ns, buf_line, 0, {
        virt_text = { { gutter, 'LineNr' } },
        virt_text_pos = 'inline',
      })
    end
    if info.bg then
      vim.api.nvim_buf_set_extmark(right_buf, ns, buf_line, 0, {
        line_hl_group = info.bg,
      })
    end
  end

  for _, f in ipairs(files) do
    f.start_line = f.start_line + header_len
  end

  local right_win = vim.api.nvim_open_win(right_buf, false, {
    relative = 'editor',
    width = right_content_w,
    height = height,
    row = row,
    col = right_col,
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

  -- Left (file list) buffer + window
  local left_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[left_buf].buftype = 'nofile'
  vim.bo[left_buf].bufhidden = 'wipe'

  local left_win = vim.api.nvim_open_win(left_buf, true, {
    relative = 'editor',
    width = left_content_w,
    height = height,
    row = row,
    col = left_col,
    style = 'minimal',
    border = 'rounded',
    title = string.format(' Files (%d) ', #files),
    title_pos = 'center',
    zindex = 60,
  })
  vim.wo[left_win].cursorline = true
  vim.wo[left_win].wrap = false
  vim.wo[left_win].winhighlight =
    'Normal:DashboardNormal,NormalFloat:DashboardNormal,FloatBorder:DashboardFloatBorder,CursorLine:DashboardCursorLine'

  -- Render file list
  local list_lines = {}
  local hl_ranges = {}
  for _, f in ipairs(files) do
    local add_str = '+' .. f.add
    local del_str = '-' .. f.del
    local stats = add_str .. ' ' .. del_str
    local path = f.path
    local path_max = left_content_w - #stats - 1
    if #path > path_max and path_max > 1 then
      path = '…' .. path:sub(#path - path_max + 2)
    end
    local gap = left_content_w - #path - #stats
    if gap < 1 then
      gap = 1
    end
    local line = path .. string.rep(' ', gap) .. stats
    table.insert(list_lines, line)
    local add_start = #path + gap
    local add_end = add_start + #add_str
    local del_start = add_end + 1
    local del_end = del_start + #del_str
    table.insert(
      hl_ranges,
      { line = #list_lines - 1, ranges = { { add_start, add_end, 'DiagnosticOk' }, { del_start, del_end, 'DiagnosticError' } } }
    )
  end
  if #list_lines == 0 then
    list_lines = { '(no files in diff)' }
  end

  vim.bo[left_buf].modifiable = true
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, list_lines)
  for _, h in ipairs(hl_ranges) do
    for _, r in ipairs(h.ranges) do
      vim.api.nvim_buf_set_extmark(left_buf, ns, h.line, r[1], { end_col = r[2], hl_group = r[3] })
    end
  end
  vim.bo[left_buf].modifiable = false

  state.last_result_win = right_win
  state.diff_left_win = left_win
  state.diff_right_win = right_win

  local closing = false
  local close = function()
    if closing then
      return
    end
    closing = true
    for _, w in ipairs { left_win, right_win } do
      if vim.api.nvim_win_is_valid(w) then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    if state.diff_left_win == left_win then
      state.diff_left_win = nil
    end
    if state.diff_right_win == right_win then
      state.diff_right_win = nil
    end
    refocus_dashboard()
  end

  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = { tostring(left_win), tostring(right_win) },
    callback = function()
      vim.schedule(close)
    end,
  })

  local function jump_to_file()
    local lnum = vim.api.nvim_win_get_cursor(left_win)[1]
    local f = files[lnum]
    if not f or not vim.api.nvim_win_is_valid(right_win) then
      return
    end
    vim.api.nvim_set_current_win(right_win)
    vim.api.nvim_win_set_cursor(right_win, { f.start_line, 0 })
    vim.cmd 'normal! zt'
  end

  local left_opts = { buffer = left_buf, nowait = true, silent = true }
  vim.keymap.set('n', 'q', close, left_opts)
  vim.keymap.set('n', '<Esc>', close, left_opts)
  vim.keymap.set('n', '<CR>', jump_to_file, left_opts)
  vim.keymap.set('n', '<Tab>', function()
    if vim.api.nvim_win_is_valid(right_win) then
      vim.api.nvim_set_current_win(right_win)
    end
  end, left_opts)

  local right_opts = { buffer = right_buf, nowait = true, silent = true }
  vim.keymap.set('n', 'q', close, right_opts)
  vim.keymap.set('n', '<Esc>', close, right_opts)
  vim.keymap.set('n', '<Tab>', function()
    if vim.api.nvim_win_is_valid(left_win) then
      vim.api.nvim_set_current_win(left_win)
    end
  end, right_opts)
end

local function wrap_text(text, max_w)
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

local function group_threads_by_file(threads)
  local unresolved = {}
  for _, t in ipairs(threads or {}) do
    if not t.isResolved then
      table.insert(unresolved, t)
    end
  end
  local by_file = {}
  local files = {}
  for _, t in ipairs(unresolved) do
    local path = t.path or '?'
    if not by_file[path] then
      by_file[path] = {}
      table.insert(files, path)
    end
    table.insert(by_file[path], t)
  end
  table.sort(files)
  local ordered = {}
  for _, f in ipairs(files) do
    table.insert(ordered, { path = f, threads = by_file[f] })
  end
  return ordered, #unresolved
end

local function open_threads_window(title, threads, ctx_id, overview)
  local groups, total = group_threads_by_file(threads)

  local total_w = math.min(160, math.floor(vim.o.columns * 0.9))
  local left_content_w = 38
  local right_content_w = total_w - left_content_w - 4
  if right_content_w < 40 then
    left_content_w = math.max(20, total_w - 44)
    right_content_w = total_w - left_content_w - 4
  end
  local height = math.min(50, math.floor(vim.o.lines * 0.9))
  local statusline = vim.o.laststatus > 0 and 1 or 0
  local available = vim.o.lines - vim.o.cmdheight - statusline
  local row = math.floor((available - height) / 2)
  local total_col_start = math.floor((vim.o.columns - total_w) / 2)
  local left_col = total_col_start + 1
  local right_col = left_col + left_content_w + 2

  -- Right (threads) buffer + window
  local right_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[right_buf].buftype = 'nofile'
  vim.bo[right_buf].bufhidden = 'wipe'

  local right_win = vim.api.nvim_open_win(right_buf, false, {
    relative = 'editor',
    width = right_content_w,
    height = height,
    row = row,
    col = right_col,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. title .. ' ',
    title_pos = 'center',
    zindex = 60,
  })
  state.last_result_win = right_win
  vim.wo[right_win].cursorline = false
  vim.wo[right_win].wrap = false
  vim.wo[right_win].number = false
  vim.wo[right_win].signcolumn = 'no'
  vim.wo[right_win].winhighlight =
    'Normal:DashboardNormal,NormalFloat:DashboardNormal,FloatBorder:DashboardFloatBorder'

  -- Render threads grouped by file; record per-file start line
  local lines = {}
  local line_bgs = {}
  local range_hls = {}
  local file_start_lines = {}

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

  emit_pr_header_card(right_content_w, overview, push_raw, push_bg, push_seg)

  push_raw('')
  push_seg {
    { text = '  ', hl = nil },
    { text = 'REVIEW THREADS', hl = 'Title' },
    { text = '  ' .. ctx_id, hl = 'Comment' },
  }
  push_raw('')
  if total == 0 then
    push_seg {
      { text = '  ', hl = nil },
      { text = '(no unresolved review threads)', hl = 'Comment' },
    }
  else
    push_seg {
      { text = '  ', hl = nil },
      { text = ' ' .. total .. ' unresolved ', hl = 'DashboardPillWarn' },
    }
  end
  push_raw('')
  push_raw('')

  local indent = '  '
  local bar_prefix = '  │  '
  local bar_w = vim.fn.strdisplaywidth(bar_prefix)
  local reply_border_w = math.max(10, right_content_w - bar_w - 4)

  for gi, group in ipairs(groups) do
    local fname = group.path
    local label = ' ' .. fname .. ' '
    if vim.fn.strdisplaywidth(label) > right_content_w - 10 then
      local visible = math.max(3, right_content_w - 14)
      label = ' …' .. fname:sub(#fname - visible + 1) .. ' '
    end
    local pad_total = right_content_w - vim.fn.strdisplaywidth(label)
    if pad_total < 2 then
      pad_total = 2
    end
    local pad_left = math.floor(pad_total / 2)
    local pad_right = pad_total - pad_left

    file_start_lines[gi] = #lines
    push_seg {
      { text = string.rep('━', pad_left), hl = 'NonText' },
      { text = label, hl = 'Title' },
      { text = string.rep('━', pad_right), hl = 'NonText' },
    }
    push_raw('')

    for _, t in ipairs(group.threads) do
      local cs = (t.comments and t.comments.nodes) or {}
      local first = cs[1]
      local line_num = t.line or t.originalLine or '?'

      local header_segs = {
        { text = indent, hl = nil },
        { text = 'line ' .. tostring(line_num), hl = 'Comment' },
      }
      if t.isOutdated then
        table.insert(header_segs, { text = '  ', hl = nil })
        table.insert(header_segs, { text = ' outdated ', hl = 'DashboardPillMuted' })
      end
      push_seg(header_segs)
      if first and first.diffHunk and first.diffHunk ~= '' then
        for _, hline in ipairs(vim.split(first.diffHunk, '\n', { plain = true })) do
          local f = hline:sub(1, 1)
          local hunk_bg
          if hline:match '^@@' then
            hunk_bg = 'DiffChange'
          elseif f == '+' and not hline:match '^%+%+%+' then
            hunk_bg = 'DiffAdd'
          elseif f == '-' and not hline:match '^%-%-%-' then
            hunk_bg = 'DiffDelete'
          end
          push_bg(indent .. hline, hunk_bg)
        end
      end

      for _, c in ipairs(cs) do
        local author = (c.author and c.author.login) or '?'
        local age = ago(c.createdAt)
        local prefix_w = bar_w + 2 + vim.fn.strdisplaywidth(author)
        local age_w = vim.fn.strdisplaywidth(age)
        local pad_w = right_content_w - prefix_w - age_w - 4
        if pad_w < 2 then
          pad_w = 2
        end
        push_seg {
          { text = '  ', hl = nil },
          { text = '│', hl = 'DashboardAccentGithub' },
        }
        push_seg {
          { text = '  ', hl = nil },
          { text = '│  ', hl = 'DashboardAccentGithub' },
          { text = '╭' .. string.rep('─', reply_border_w) .. '╮', hl = 'DashboardAccentGithub' },
        }
        push_seg {
          { text = '  ', hl = nil },
          { text = '│  ', hl = 'DashboardAccentGithub' },
          { text = '  ', hl = nil },
          { text = author, hl = 'Title' },
          { text = string.rep(' ', pad_w), hl = nil },
          { text = age, hl = 'Comment' },
        }
        local body_max = math.max(20, reply_border_w - 4)
        for _, l in ipairs(wrap_text(c.body or '', body_max)) do
          push_seg {
            { text = '  ', hl = nil },
            { text = '│  ', hl = 'DashboardAccentGithub' },
            { text = '  ' .. l, hl = 'Normal' },
          }
        end
        push_seg {
          { text = '  ', hl = nil },
          { text = '│  ', hl = 'DashboardAccentGithub' },
          { text = '╰' .. string.rep('─', reply_border_w) .. '╯', hl = 'DashboardAccentGithub' },
        }
      end

      push_raw('')
    end
    push_raw('')
  end

  vim.bo[right_buf].modifiable = true
  vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, lines)
  for _, h in ipairs(range_hls) do
    vim.api.nvim_buf_set_extmark(right_buf, ns, h.line, h.col_start, {
      end_col = h.col_end,
      hl_group = h.hl,
      priority = 100,
    })
  end
  for _, bg in ipairs(line_bgs) do
    vim.api.nvim_buf_set_extmark(right_buf, ns, bg.line, 0, {
      end_line = bg.line + 1,
      end_col = 0,
      hl_group = bg.hl,
      hl_eol = true,
      priority = 10,
    })
  end
  vim.bo[right_buf].modifiable = false

  -- Left (file list) buffer + window
  local left_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[left_buf].buftype = 'nofile'
  vim.bo[left_buf].bufhidden = 'wipe'

  local left_win = vim.api.nvim_open_win(left_buf, true, {
    relative = 'editor',
    width = left_content_w,
    height = height,
    row = row,
    col = left_col,
    style = 'minimal',
    border = 'rounded',
    title = string.format(' Files (%d) ', #groups),
    title_pos = 'center',
    zindex = 60,
  })
  vim.wo[left_win].cursorline = true
  vim.wo[left_win].wrap = false
  vim.wo[left_win].winhighlight =
    'Normal:DashboardNormal,NormalFloat:DashboardNormal,FloatBorder:DashboardFloatBorder,CursorLine:DashboardCursorLine'

  local list_lines = {}
  local list_hls = {}
  local right_pad = 1
  for _, group in ipairs(groups) do
    local count_pill = ' ' .. tostring(#group.threads) .. ' '
    local count_w = #count_pill
    local path = group.path
    local max_path = left_content_w - count_w - right_pad - 1
    if #path > max_path and max_path > 1 then
      path = '…' .. path:sub(#path - max_path + 2)
    end
    local gap = left_content_w - #path - count_w - right_pad
    if gap < 1 then
      gap = 1
    end
    local line = path .. string.rep(' ', gap) .. count_pill .. string.rep(' ', right_pad)
    table.insert(list_lines, line)
    local count_start = #path + gap
    table.insert(list_hls, { line = #list_lines - 1, col_start = count_start, col_end = count_start + count_w })
  end
  if #list_lines == 0 then
    list_lines = { '(no files with threads)' }
  end

  vim.bo[left_buf].modifiable = true
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, list_lines)
  for _, h in ipairs(list_hls) do
    vim.api.nvim_buf_set_extmark(left_buf, ns, h.line, h.col_start, {
      end_col = h.col_end,
      hl_group = 'DashboardPillWarn',
      priority = 100,
    })
  end
  vim.bo[left_buf].modifiable = false

  local close = function()
    for _, w in ipairs { left_win, right_win } do
      if vim.api.nvim_win_is_valid(w) then
        vim.api.nvim_win_close(w, true)
      end
    end
    refocus_dashboard()
  end

  local function jump_to_file()
    local lnum = vim.api.nvim_win_get_cursor(left_win)[1]
    local start_line = file_start_lines[lnum]
    if not start_line or not vim.api.nvim_win_is_valid(right_win) then
      return
    end
    vim.api.nvim_set_current_win(right_win)
    vim.api.nvim_win_set_cursor(right_win, { start_line + 1, 0 })
    vim.cmd 'normal! zt'
  end

  local left_opts = { buffer = left_buf, nowait = true, silent = true }
  vim.keymap.set('n', 'q', close, left_opts)
  vim.keymap.set('n', '<Esc>', close, left_opts)
  vim.keymap.set('n', '<CR>', jump_to_file, left_opts)
  vim.keymap.set('n', '<Tab>', function()
    if vim.api.nvim_win_is_valid(right_win) then
      vim.api.nvim_set_current_win(right_win)
    end
  end, left_opts)

  local right_opts = { buffer = right_buf, nowait = true, silent = true }
  vim.keymap.set('n', 'q', close, right_opts)
  vim.keymap.set('n', '<Esc>', close, right_opts)
  vim.keymap.set('n', '<Tab>', function()
    if vim.api.nvim_win_is_valid(left_win) then
      vim.api.nvim_set_current_win(left_win)
    end
  end, right_opts)
end

local function render_review_threads(buf, win, threads, ctx_id)
  vim.bo[buf].filetype = ''
  local content_w = vim.api.nvim_win_get_width(win) - 2

  local lines = {}
  local line_bgs = {}
  local range_hls = {}

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
  local function push_seg_with_bg(segs, bg)
    local idx = push_seg(segs)
    if bg then
      table.insert(line_bgs, { line = idx, hl = bg })
    end
    return idx
  end

  local unresolved = {}
  for _, t in ipairs(threads or {}) do
    if not t.isResolved then
      table.insert(unresolved, t)
    end
  end

  push_raw('')
  push_seg {
    { text = '  ', hl = nil },
    { text = 'REVIEW THREADS', hl = 'Title' },
    { text = '  ' .. ctx_id, hl = 'Comment' },
  }
  push_raw('')
  if #unresolved == 0 then
    push_seg {
      { text = '  ', hl = nil },
      { text = '(no unresolved review threads)', hl = 'Comment' },
    }
  else
    push_seg {
      { text = '  ', hl = nil },
      { text = ' ' .. #unresolved .. ' unresolved ', hl = 'DashboardPillWarn' },
    }
  end
  push_raw('')
  push_raw('')

  local indent = '  '
  local border_w = math.max(10, content_w - 6)
  local bar_prefix = '  │  '
  local bar_w = vim.fn.strdisplaywidth(bar_prefix)
  local reply_border_w = math.max(10, content_w - bar_w - 4)

  for ti, t in ipairs(unresolved) do
    local cs = (t.comments and t.comments.nodes) or {}
    local first = cs[1]
    local path = t.path or '?'
    local line_num = t.line or t.originalLine or '?'

    -- Header card with file:line + diff hunk
    push_seg {
      { text = indent, hl = nil },
      { text = '╭' .. string.rep('─', border_w) .. '╮', hl = 'DashboardAccentGithub' },
    }
    local header_segs = {
      { text = indent, hl = nil },
      { text = '  ', hl = nil },
      { text = path .. ':' .. tostring(line_num), hl = 'Title' },
    }
    if t.isOutdated then
      table.insert(header_segs, { text = '  ', hl = nil })
      table.insert(header_segs, { text = ' outdated ', hl = 'DashboardPillMuted' })
    end
    push_seg(header_segs)
    if first and first.diffHunk and first.diffHunk ~= '' then
      push_raw('')
      for _, hl in ipairs(vim.split(first.diffHunk, '\n', { plain = true })) do
        local f = hl:sub(1, 1)
        local hunk_bg
        if hl:match '^@@' then
          hunk_bg = 'DiffChange'
        elseif f == '+' and not hl:match '^%+%+%+' then
          hunk_bg = 'DiffAdd'
        elseif f == '-' and not hl:match '^%-%-%-' then
          hunk_bg = 'DiffDelete'
        end
        push_bg(indent .. '  ' .. hl, hunk_bg)
      end
    end
    push_seg {
      { text = indent, hl = nil },
      { text = '╰' .. string.rep('─', border_w) .. '╯', hl = 'DashboardAccentGithub' },
    }

    -- Comments as reply cards
    for _, c in ipairs(cs) do
      local author = (c.author and c.author.login) or '?'
      local age = ago(c.createdAt)
      local prefix_w = bar_w + 2 + vim.fn.strdisplaywidth(author)
      local age_w = vim.fn.strdisplaywidth(age)
      local pad_w = content_w - prefix_w - age_w - 4
      if pad_w < 2 then
        pad_w = 2
      end
      push_seg {
        { text = '  ', hl = nil },
        { text = '│', hl = 'DashboardAccentGithub' },
      }
      push_seg {
        { text = '  ', hl = nil },
        { text = '│  ', hl = 'DashboardAccentGithub' },
        { text = '╭' .. string.rep('─', reply_border_w) .. '╮', hl = 'DashboardAccentGithub' },
      }
      push_seg {
        { text = '  ', hl = nil },
        { text = '│  ', hl = 'DashboardAccentGithub' },
        { text = '  ', hl = nil },
        { text = author, hl = 'Title' },
        { text = string.rep(' ', pad_w), hl = nil },
        { text = age, hl = 'Comment' },
      }
      for _, l in ipairs(vim.split(c.body or '', '\n', { plain = true })) do
        push_seg {
          { text = '  ', hl = nil },
          { text = '│  ', hl = 'DashboardAccentGithub' },
          { text = '  ' .. l, hl = 'Normal' },
        }
      end
      push_seg {
        { text = '  ', hl = nil },
        { text = '│  ', hl = 'DashboardAccentGithub' },
        { text = '╰' .. string.rep('─', reply_border_w) .. '╯', hl = 'DashboardAccentGithub' },
      }
    end

    if ti < #unresolved then
      push_raw('')
      push_raw('')
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
  vim.bo[buf].modifiable = false
end

local function render_jira_issue(buf, win, issue)
  vim.bo[buf].filetype = ''
  local content_w = vim.api.nvim_win_get_width(win) - 2
  local dash_w = math.max(10, content_w - 4)

  local lines = {}
  local line_bgs = {}
  local range_hls = {}

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
      push_bg('  ' .. l, hbg)
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
        push_raw(indent .. '  ' .. l)
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
        push_seg {
          { text = '  ', hl = nil },
          { text = '│  ', hl = 'DashboardAccentJira' },
          { text = '  ' .. l, hl = 'Normal' },
        }
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

function M.threads_under_cursor()
  local m = under_cursor()
  if not m or m.kind ~= 'pr' or not m.pr or not m.pr.repo or not m.pr.number then
    return
  end
  local title = string.format('Threads · %s#%d', m.pr.repo, m.pr.number)
  vim.notify('Loading review threads…', vim.log.levels.INFO)

  local results = { threads = nil, overview = nil }
  local pending = 2
  local errored = false
  local function done()
    pending = pending - 1
    if pending > 0 or errored then
      return
    end
    open_threads_window(title, results.threads, m.pr.repo .. '#' .. m.pr.number, results.overview)
  end

  require('dashboard.github').fetch_review_threads(m.pr.repo, m.pr.number, function(threads, err)
    if not threads then
      errored = true
      vim.notify('Failed to fetch threads: ' .. (err or 'unknown'), vim.log.levels.ERROR)
      return
    end
    results.threads = threads
    done()
  end)
  require('dashboard.github').fetch_pr_overview(m.pr.repo, m.pr.number, function(overview)
    results.overview = overview
    done()
  end)
end

function M.show_local_diff()
  if diff_viewer_open() then
    focus_diff_viewer()
    return
  end
  local cwd = vim.fn.getcwd()
  vim.system({ 'git', '-C', cwd, 'rev-parse', '--is-inside-work-tree' }, { text = true }, function(check)
    vim.schedule(function()
      if check.code ~= 0 then
        vim.notify('Not inside a git repository', vim.log.levels.WARN)
        return
      end
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
            vim.notify('Loading local diff vs ' .. label .. '…', vim.log.levels.INFO)
            vim.system({ 'git', '-C', cwd, 'diff', target }, { text = true }, function(obj)
              vim.schedule(function()
                if obj.code ~= 0 then
                  vim.notify('git diff failed: ' .. (obj.stderr or ''), vim.log.levels.ERROR)
                  return
                end
                local diff = obj.stdout or ''
                if diff:gsub('%s', '') == '' then
                  vim.notify('No local changes vs ' .. label, vim.log.levels.INFO)
                  return
                end
                local branch = vim.fn.fnamemodify(cwd, ':t')
                local title = string.format('%s · local vs %s', branch, label)
                open_diff_window(title, diff, nil)
              end)
            end)
          end)
        end
      )
    end)
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
  vim.notify('Loading diff…', vim.log.levels.INFO)

  local results = { diff = nil, overview = nil }
  local pending = 2
  local errored = false
  local function done()
    pending = pending - 1
    if pending > 0 or errored then
      return
    end
    local title = string.format('%s#%d', m.pr.repo, m.pr.number)
    open_diff_window(title, results.diff, results.overview)
  end

  vim.system({ 'gh', 'pr', 'diff', m.url }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        errored = true
        vim.notify('Failed to fetch diff: ' .. (obj.stderr or ''), vim.log.levels.ERROR)
        return
      end
      results.diff = obj.stdout
      done()
    end)
  end)
  require('dashboard.github').fetch_pr_overview(m.pr.repo, m.pr.number, function(overview)
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

  local width = math.min(110, math.floor(vim.o.columns * 0.75))
  local height = math.min(35, math.floor(vim.o.lines * 0.7))
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

  local close = function()
    stop_spinner()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    refocus_dashboard()
  end
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set('n', 'q', close, opts)
  vim.keymap.set('n', '<Esc>', close, opts)

  local function set_content(text_or_renderer)
    stop_spinner()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
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
  state.win = nil
  state.buf = nil
  state.line_meta = {}
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
  <CR>    open url in browser
  y       yank url
  f       filter every section by substring
  r       refresh now
  q       close dashboard
  g?      this help
  <leader>od   open / refocus dashboard
  <leader>or   focus last result window

## Notes section
  n       new note (auto-prepends "- ")
  T       new todo (auto-prepends "- [ ] ")
  x       toggle todo checkbox on the cursor row
  <CR>    open today's notes file for editing

## GitHub PR rows
  c       checkout PR, open repo in nvim
  i       checkout + claude interactive in tmux pane
  D       two-pane diff viewer (file list + diff)
  t       review threads pane
  s       claude summary
  ?       claude prompt picker (summary / understand / risks / next / code review)

## Jira rows
  C       read ticket description + comments in a panel

## Notifications
  x       mark notification as read

## Diff viewer
  <CR>    jump diff to selected file's hunk + focus diff pane
  <Tab>   toggle focus (files ↔ diff)
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
    or state.data.notifications == nil
    or state.data.jira_active == nil
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
    notifications = nil,
    jira_active = nil,
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
    else
      state.data.my_prs = result.my_prs
      state.data.reviews = result.reviews
    end
    state.last_refresh = os.time()
    render()
  end)
  github.fetch_notifications(update 'notifications')
  jira.assigned_active(update 'jira_active')
end

function M.open()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = 'wipe'
  vim.bo[state.buf].filetype = 'dashboard'

  local width = math.min(155, math.floor(vim.o.columns * 0.92))
  local height = math.min(44, math.floor(vim.o.lines * 0.85))
  local statusline = vim.o.laststatus > 0 and 1 or 0
  local available = vim.o.lines - vim.o.cmdheight - statusline
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((available - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' Status Dashboard ',
    title_pos = 'center',
  })

  vim.wo[state.win].cursorline = false
  vim.wo[state.win].wrap = false
  vim.wo[state.win].winhighlight =
    'Normal:DashboardNormal,NormalFloat:DashboardNormal,FloatBorder:DashboardFloatBorder'
  vim.wo[state.win].sidescrolloff = 4

  local opts = { buffer = state.buf, nowait = true, silent = true }
  vim.keymap.set('n', 'q', M.close, opts)
  vim.keymap.set('n', '<Esc>', M.close, opts)
  vim.keymap.set('n', 'r', M.refresh, opts)
  vim.keymap.set('n', '<CR>', M.open_under_cursor, opts)
  vim.keymap.set('n', 'y', M.yank_under_cursor, opts)
  vim.keymap.set('n', 'c', M.checkout_under_cursor, opts)
  vim.keymap.set('n', 'i', M.interactive_claude_under_cursor, opts)
  vim.keymap.set('n', 'D', M.diff_under_cursor, opts)
  vim.keymap.set('n', 't', M.threads_under_cursor, opts)
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
