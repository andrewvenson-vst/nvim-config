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
}

local pending_hls = {}

local PAD = '   '
local BAR = '┃'

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

local function review_badge(decision)
  if decision == 'APPROVED' then
    return '✓', 'DiagnosticOk'
  end
  if decision == 'CHANGES_REQUESTED' then
    return '✗', 'DiagnosticError'
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
  local rv_glyph, rv_hl = review_badge(pr.reviewDecision)
  local segments = {
    { text = PAD, hl = nil },
    { text = BAR .. ' ', hl = 'NonText' },
    { text = pad_right(num, 8), hl = '@number' },
    { text = ci_glyph, hl = ci_hl },
    { text = ' ', hl = nil },
    { text = rv_glyph, hl = rv_hl },
    { text = '  ', hl = nil },
    { text = pad_right(repo, 30), hl = '@string' },
    { text = pr.title, hl = 'Normal' },
  }
  if opts.draft and pr.isDraft then
    table.insert(segments, { text = '  [draft]', hl = 'Comment' })
  end
  local idx, cols = emit(lines, segments)
  paint(idx, cols)
  meta[idx + 1] = { url = pr.url }
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
  meta[idx + 1] = { url = issue.url }

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
    meta[sub_idx + 1] = { url = pr.url }
  end
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

local function emit_header(lines)
  local title = '  ★  Status Dashboard'
  local idx, cols = emit(lines, {
    { text = title, hl = 'Title' },
  })
  paint(idx, cols)

  local hint = '  <CR> open · y yank · r refresh · q close   │   PR cols: CI · Review   ✓ ok  ✗ fail  ● pending  ○ awaiting'
  local idx2, cols2 = emit(lines, {
    { text = hint, hl = 'Comment' },
  })
  paint(idx2, cols2)
  emit_blank(lines)
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

  emit_header(lines)
  emit_divider(lines, 'GitHub')
  emit_blank(lines)
  emit_section(lines, meta, 'My PRs', state.data.my_prs, function(ls, m, pr)
    emit_pr(ls, m, pr, { draft = true })
  end, 'No open PRs')
  emit_section(lines, meta, 'Awaiting my review', state.data.reviews, function(ls, m, pr)
    emit_pr(ls, m, pr)
  end, 'Inbox zero')

  emit_divider(lines, 'Jira')
  emit_blank(lines)
  emit_section(lines, meta, 'In Progress', state.data.jira_in_progress, function(ls, m, issue)
    emit_issue(ls, m, issue, { pr_pool = pr_pool })
  end, 'No tickets in progress')
  emit_section(lines, meta, 'Other assigned', state.data.jira_assigned, function(ls, m, issue)
    emit_issue(ls, m, issue, { show_status = true, pr_pool = pr_pool })
  end, 'Nothing else assigned')

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

function M.refresh()
  state.data = {
    my_prs = nil,
    reviews = nil,
    jira_in_progress = nil,
    jira_assigned = nil,
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
  jira.in_progress(update 'jira_in_progress')
  jira.assigned(update 'jira_assigned')
end

function M.open()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = 'wipe'
  vim.bo[state.buf].filetype = 'dashboard'

  local width = math.min(110, math.floor(vim.o.columns * 0.85))
  local height = math.min(44, math.floor(vim.o.lines * 0.85))
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
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

  M.refresh()
end

return M
