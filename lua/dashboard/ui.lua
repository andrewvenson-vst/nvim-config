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
}

local pending_hls = {}

local open_result_window

local PAD = '   '
local BAR = '┃'

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
  mention = { label = '@mention', hl = 'DiagnosticInfo' },
  team_mention = { label = 'team @', hl = 'DiagnosticInfo' },
  review_requested = { label = 'review', hl = '@keyword' },
  assign = { label = 'assign', hl = '@keyword' },
  author = { label = 'author', hl = 'Comment' },
  comment = { label = 'comment', hl = 'Comment' },
  subscribed = { label = 'watching', hl = 'NonText' },
  state_change = { label = 'state', hl = 'NonText' },
  security_alert = { label = 'security', hl = 'DiagnosticError' },
  ci_activity = { label = 'ci', hl = 'DiagnosticWarn' },
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
    })
  end
  pending_hls = {}
end

local function emit_blank(lines)
  table.insert(lines, '')
end

local function emit_divider(lines, label)
  local total = 78
  local label_part = '  ' .. label .. '  '
  local side = math.floor((total - #label_part) / 2)
  local left = string.rep('━', side)
  local right = string.rep('━', total - side - #label_part)
  local idx, cols = emit(lines, {
    { text = ' ', hl = nil },
    { text = left, hl = 'NonText' },
    { text = '  ', hl = nil },
    { text = label, hl = 'Title' },
    { text = '  ', hl = nil },
    { text = right, hl = 'NonText' },
  })
  paint(idx, cols)
end

local function emit_subhead(lines, title, count)
  local count_str = count and string.format('  (%d)', count) or ''
  local idx, cols = emit(lines, {
    { text = '  ', hl = nil },
    { text = title, hl = '@keyword' },
    { text = count_str, hl = 'Comment' },
  })
  paint(idx, cols)
end

local function emit_status(lines, kind, text)
  local hl = kind == 'loading' and 'Comment' or kind == 'error' and 'DiagnosticError' or 'Comment'
  local prefix = kind == 'loading' and '…' or kind == 'error' and '✗' or '·'
  local idx, cols = emit(lines, {
    { text = PAD, hl = nil },
    { text = BAR .. ' ', hl = 'NonText' },
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

local function emit_pr(lines, meta, pr, opts)
  opts = opts or {}
  local repo = (pr.repository and pr.repository.nameWithOwner) or '?'
  local num = '#' .. tostring(pr.number)
  local ci_glyph, ci_hl = ci_badge(pr.ciStatus)
  local rv_glyph, rv_hl = review_badge(pr.reviewDecision, pr.approvalCount)
  local age_label, age_hl = relative_time(pr.updatedAt)
  local segments = {
    { text = PAD, hl = nil },
    { text = BAR .. ' ', hl = 'NonText' },
    { text = pad_right(num, 8), hl = '@number' },
    { text = ci_glyph, hl = ci_hl },
    { text = ' ', hl = nil },
    { text = rv_glyph, hl = rv_hl },
    { text = '  ', hl = nil },
    { text = pad_right(repo, 30), hl = '@string' },
    { text = string.format('%5s', age_label), hl = age_hl },
    { text = '  ', hl = nil },
    { text = pr.title, hl = 'Normal' },
  }
  if opts.draft and pr.isDraft then
    table.insert(segments, { text = '  [draft]', hl = 'Comment' })
  end
  local idx, cols = emit(lines, segments)
  paint(idx, cols)
  meta[idx + 1] = { url = pr.url, pr = { number = pr.number, repo = repo }, kind = 'pr' }

  if pr.unresolvedThreads and pr.unresolvedThreads > 0 then
    local sidx, scols = emit(lines, {
      { text = '       ┊ ', hl = 'NonText' },
      { text = tostring(pr.unresolvedThreads) .. ' unresolved', hl = 'DiagnosticWarn' },
    })
    paint(sidx, scols)
  end
end

local function emit_issue(lines, meta, issue, opts)
  opts = opts or {}
  local segments = {
    { text = PAD, hl = nil },
    { text = BAR .. ' ', hl = 'NonText' },
    { text = pad_right(issue.key, 13), hl = '@number' },
  }
  if opts.show_status then
    local hl = jira_status_hl(issue.status)
    table.insert(segments, { text = pad_right('[' .. (issue.status or '?') .. ']', 20), hl = hl })
  end
  table.insert(segments, { text = issue.summary or '', hl = 'Normal' })
  local idx, cols = emit(lines, segments)
  paint(idx, cols)
  meta[idx + 1] = { url = issue.url, kind = 'jira', key = issue.key }

  local sub = { { text = '       ┊ ', hl = 'NonText' } }
  local has_meta = false
  if issue.qa_assignee then
    table.insert(sub, { text = 'QA: ', hl = 'Comment' })
    table.insert(sub, { text = issue.qa_assignee, hl = '@string' })
    has_meta = true
  end
  if issue.status_change_at then
    if has_meta then
      table.insert(sub, { text = '  ·  ', hl = 'Identifier' })
    end
    local age, age_hl = relative_time(issue.status_change_at)
    table.insert(sub, { text = 'in status ', hl = 'Comment' })
    table.insert(sub, { text = age, hl = age_hl })
    has_meta = true
  end
  if has_meta then
    local sidx, scols = emit(lines, sub)
    paint(sidx, scols)
  end

  local matches = related_prs(issue.key, opts.pr_pool or {})
  for _, pr in ipairs(matches) do
    local repo = (pr.repository and pr.repository.nameWithOwner) or '?'
    local sub_idx, sub_cols = emit(lines, {
      { text = '       ', hl = nil },
      { text = '↳ ', hl = 'NonText' },
      { text = pad_right(repo .. '#' .. pr.number, 30), hl = '@string' },
      { text = pr.title or '', hl = 'Comment' },
    })
    paint(sub_idx, sub_cols)
    meta[sub_idx + 1] = { url = pr.url, pr = { number = pr.number, repo = repo }, kind = 'pr' }
  end
end

local function emit_notification(lines, meta, n)
  local label, hl = notification_reason(n.reason)
  local age_label, age_hl = relative_time(n.updated_at)
  local idx, cols = emit(lines, {
    { text = PAD, hl = nil },
    { text = BAR .. ' ', hl = 'NonText' },
    { text = pad_right(n.repo or '?', 30), hl = '@string' },
    { text = pad_right(label, 12), hl = hl },
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

local function emit_section(lines, meta, title, items, emit_item, empty_label)
  local count = type(items) == 'table' and #items or nil
  emit_subhead(lines, title, count)
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
  emit_blank(lines)
end

local function emit_segments(lines, segments)
  local idx, cols = emit(lines, segments)
  paint(idx, cols)
  return idx
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
  emit_legend(lines, {
    OPEN_BR,
    { text = '<CR>', hl = '@keyword' },
    { text = ' open · ', hl = 'Comment' },
    { text = 'y', hl = '@keyword' },
    { text = ' yank · ', hl = 'Comment' },
    { text = 'f', hl = '@keyword' },
    { text = ' filter · ', hl = 'Comment' },
    { text = 'r', hl = '@keyword' },
    { text = ' refresh · ', hl = 'Comment' },
    { text = 'q', hl = '@keyword' },
    { text = ' close', hl = 'Comment' },
    CLOSE_BR,
  })
  if state.filter and state.filter ~= '' then
    emit_legend(lines, {
      { text = 'Filter: ', hl = 'Comment' },
      { text = state.filter, hl = '@string' },
      { text = '   (', hl = 'Comment' },
      { text = 'f', hl = '@keyword' },
      { text = ' edit · empty to clear)', hl = 'Comment' },
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
  emit_divider(lines, 'GitHub')
  emit_github_legend(lines)
  emit_blank(lines)
  emit_section(lines, meta, 'My PRs', my_prs, function(ls, m, pr)
    emit_pr(ls, m, pr, { draft = true })
  end, 'No open PRs')
  emit_section(lines, meta, 'Awaiting my review', reviews, function(ls, m, pr)
    emit_pr(ls, m, pr)
  end, 'Inbox zero')

  emit_divider(lines, 'Notifications')
  emit_notifications_legend(lines)
  emit_blank(lines)
  emit_section(lines, meta, 'Inbox', notifications, function(ls, m, n)
    emit_notification(ls, m, n)
  end, 'No notifications')

  emit_divider(lines, 'Jira')
  emit_jira_legend(lines)
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
    for _, status in ipairs(config.jira_status_order) do
      seen[status] = true
      local items = groups[status]
      if items and #items > 0 then
        emit_section(lines, meta, status, items, function(ls, m, issue)
          emit_issue(ls, m, issue, { pr_pool = pr_pool })
        end, '')
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
      emit_section(lines, meta, 'Other', other, function(ls, m, issue)
        emit_issue(ls, m, issue, { show_status = true, pr_pool = pr_pool })
      end, '')
    end
  end

  emit_footer(lines)

  state.line_meta = meta

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
  if m and m.url then
    vim.ui.open(m.url)
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

function M.checkout_under_cursor()
  local m = under_cursor()
  if not m or not m.pr then
    return
  end
  if not in_tmux() then
    vim.notify('Not in a tmux session', vim.log.levels.WARN)
    return
  end
  local repo_path = config.repo_paths[m.pr.repo]
  if not repo_path then
    vim.notify('No local path configured for ' .. m.pr.repo, vim.log.levels.WARN)
    return
  end
  repo_path = vim.fn.expand(repo_path)
  local shell = vim.env.SHELL or '/bin/sh'
  local cmd_str = string.format('gh pr checkout %d; exec %s', m.pr.number, shell)
  tmux_run({ cmd_str }, repo_path)
end

local function open_diff_window(title, body)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(body, '\n', { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'diff'
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'

  local width = math.min(160, math.floor(vim.o.columns * 0.9))
  local height = math.min(50, math.floor(vim.o.lines * 0.9))
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

  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].number = true

  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set('n', 'q', close, opts)
  vim.keymap.set('n', '<Esc>', close, opts)
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

local function format_review_threads(threads, ctx_id)
  local lines = {}
  table.insert(lines, '# Review threads · ' .. ctx_id)
  table.insert(lines, '')

  local unresolved = {}
  for _, t in ipairs(threads or {}) do
    if not t.isResolved then
      table.insert(unresolved, t)
    end
  end

  if #unresolved == 0 then
    table.insert(lines, '_No unresolved review threads._')
    return table.concat(lines, '\n')
  end

  table.insert(lines, string.format('_%d unresolved %s_', #unresolved, #unresolved == 1 and 'thread' or 'threads'))
  table.insert(lines, '')

  for _, t in ipairs(unresolved) do
    local cs = (t.comments and t.comments.nodes) or {}
    local first = cs[1]
    local opened_by = (first and first.author and first.author.login) or '?'
    local path = t.path or '?'
    local line_num = t.line or t.originalLine or '?'
    local tag = t.isOutdated and ' _[outdated]_' or ''

    table.insert(lines, string.format('## %s:%s%s', path, tostring(line_num), tag))
    if first then
      table.insert(lines, string.format('_%s opened %s_', opened_by, ago(first.createdAt)))
    end
    table.insert(lines, '')

    if first and first.diffHunk and first.diffHunk ~= '' then
      table.insert(lines, '```diff')
      for _, l in ipairs(vim.split(first.diffHunk, '\n', { plain = true })) do
        table.insert(lines, l)
      end
      table.insert(lines, '```')
      table.insert(lines, '')
    end

    for _, c in ipairs(cs) do
      table.insert(lines, string.format('**%s** · %s', (c.author and c.author.login) or '?', ago(c.createdAt)))
      for _, l in ipairs(vim.split(c.body or '', '\n', { plain = true })) do
        table.insert(lines, '> ' .. l)
      end
      table.insert(lines, '')
    end

    table.insert(lines, '---')
    table.insert(lines, '')
  end

  return table.concat(lines, '\n')
end

function M.threads_under_cursor()
  local m = under_cursor()
  if not m or m.kind ~= 'pr' or not m.pr or not m.pr.repo or not m.pr.number then
    return
  end
  local title = string.format('Threads · %s#%d', m.pr.repo, m.pr.number)
  local handle = open_result_window(title, nil, 'Loading review threads…')
  require('dashboard.github').fetch_review_threads(m.pr.repo, m.pr.number, function(threads, err)
    if not threads then
      handle.set_error(err or 'failed to fetch threads')
      return
    end
    handle.set_content(format_review_threads(threads, m.pr.repo .. '#' .. m.pr.number))
  end)
end

function M.diff_under_cursor()
  local m = under_cursor()
  if not m or not m.pr then
    return
  end
  vim.notify('Loading diff…', vim.log.levels.INFO)
  vim.system({ 'gh', 'pr', 'diff', m.url }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        vim.notify('Failed to fetch diff: ' .. (obj.stderr or ''), vim.log.levels.ERROR)
        return
      end
      local title = string.format('%s#%d', m.pr.repo, m.pr.number)
      open_diff_window(title, obj.stdout)
    end)
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
  end
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set('n', 'q', close, opts)
  vim.keymap.set('n', '<Esc>', close, opts)

  local function set_content(text)
    stop_spinner()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    set_lines(vim.split(text, '\n', { plain = true }))
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
    local hints = {}
    for i, key in ipairs(order) do
      table.insert(hints, string.format('%d %s', i, (prompts_tbl[key].label or key):lower()))
    end
    local footer = '\n\n— ' .. table.concat(hints, ' · ') .. ' · q close'
    handle.set_content(result.text .. footer)
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

function M.refresh()
  state.data = {
    my_prs = nil,
    reviews = nil,
    notifications = nil,
    jira_active = nil,
  }
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

  vim.wo[state.win].cursorline = true
  vim.wo[state.win].wrap = false
  vim.wo[state.win].winhighlight = 'Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:PmenuSel'
  vim.wo[state.win].sidescrolloff = 4

  local opts = { buffer = state.buf, nowait = true, silent = true }
  vim.keymap.set('n', 'q', M.close, opts)
  vim.keymap.set('n', '<Esc>', M.close, opts)
  vim.keymap.set('n', 'r', M.refresh, opts)
  vim.keymap.set('n', '<CR>', M.open_under_cursor, opts)
  vim.keymap.set('n', 'y', M.yank_under_cursor, opts)
  vim.keymap.set('n', 'c', M.checkout_under_cursor, opts)
  vim.keymap.set('n', 'D', M.diff_under_cursor, opts)
  vim.keymap.set('n', 't', M.threads_under_cursor, opts)
  vim.keymap.set('n', 'x', M.mark_read_under_cursor, opts)
  vim.keymap.set('n', 's', function()
    M.analyze_under_cursor 'summary'
  end, opts)
  vim.keymap.set('n', '?', M.pick_prompt_under_cursor, opts)
  vim.keymap.set('n', 'f', M.filter_prompt, opts)

  vim.api.nvim_create_autocmd('FocusGained', {
    buffer = state.buf,
    callback = function()
      if state.last_refresh and (os.time() - state.last_refresh) > config.refresh_after then
        M.refresh()
      end
    end,
  })

  M.refresh()
end

return M
