local M = {}

local config = {
  model = nil,
  max_diff_lines = 2000,
  jira_base_url = 'https://vitalsource.atlassian.net',
}

function M.setup(opts)
  opts = opts or {}
  for k, v in pairs(opts) do
    config[k] = v
  end
end

local context_cache = {}

local PROMPTS = {
  summary = {
    label = 'Summary',
    instruction = 'Summarize this in 2-3 sentences. What is it doing and why? Focus on the goal, not implementation details. No preamble.',
  },
  understand = {
    label = 'Understand',
    instruction = 'Explain this to a senior engineer who has not seen the codebase. State the goal in plain language, define any project-specific terms, and list the components or files involved. Use brief bullet points. No preamble.',
  },
  risks = {
    label = 'Risks',
    instruction = 'List the risks, edge cases, and likely missing tests for this change. Bullet points. Be specific — name files, scenarios, or concrete failure modes rather than generic advice. No preamble.',
  },
  next_step = {
    label = 'Next step',
    instruction = 'Read the state and tell me the most useful next action for me as the assignee/author/reviewer. One short paragraph or 2-3 bullets, no more. Be concrete (e.g. "fix CI on commit X", "reply to <reviewer>\'s comment about Y", "move to In QA"). No preamble.',
  },
  code_review = {
    label = 'Code review',
    instruction = [[Review this PR as a senior engineer. Be direct and specific. Cite file:line where possible.

Structure your review as:

**Blocking** — must fix before merge (correctness bugs, security, breaking changes, data loss, broken contracts). Propose a concrete fix.

**Should fix** — worth addressing now (maintainability, missing tests, performance, API design, error handling, race conditions).

**Nits** — minor style or preference; safe to skip.

**LGTM if** — what conditions would make you approve as-is.

Skip what is obvious from the diff. If the PR is small or simple, your review should be too. If you would approve outright, say so briefly and explain why. If this is not a PR with a diff, say so and stop. No preamble.]],
  },
}

local PROMPT_ORDER = { 'summary', 'understand', 'risks', 'next_step', 'code_review' }

function M.prompts()
  return PROMPTS, PROMPT_ORDER
end

local function call_claude(prompt, callback)
  if vim.fn.executable 'claude' ~= 1 then
    callback(nil, "'claude' CLI not found in PATH")
    return
  end
  local cmd = { 'claude', '-p' }
  if config.model and config.model ~= '' then
    table.insert(cmd, '--model')
    table.insert(cmd, config.model)
  end
  vim.system(cmd, { text = true, stdin = prompt }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        local err = (obj.stderr and obj.stderr ~= '') and obj.stderr or ('claude exited ' .. obj.code)
        callback(nil, err)
        return
      end
      local text = obj.stdout
      if not text or text == '' then
        callback(nil, 'no output from claude')
        return
      end
      callback(text)
    end)
  end)
end


local function fetch_pr_context(meta, callback)
  local url = meta.url
  local repo = meta.pr and meta.pr.repo or nil
  local number = meta.pr and meta.pr.number or nil

  local results = { view = nil, diff = nil, inline = nil }
  local pending = (repo and number) and 3 or 2
  if not (repo and number) then
    results.inline = {}
  end

  local function finalize()
    local view = results.view
    if not view then
      callback(nil, 'gh pr view failed')
      return
    end

    local diff = results.diff or '(no diff)'
    local diff_lines = vim.split(diff, '\n', { plain = true })
    if #diff_lines > config.max_diff_lines then
      diff_lines = vim.list_slice(diff_lines, 1, config.max_diff_lines)
      table.insert(diff_lines, '... (diff truncated)')
      diff = table.concat(diff_lines, '\n')
    end

    local labels = {}
    for _, l in ipairs(view.labels or {}) do
      table.insert(labels, l.name)
    end

    local comments = {}
    for _, c in ipairs(view.comments or {}) do
      if c.body and c.body ~= '' then
        table.insert(comments, {
          author = (c.author and c.author.login) or '?',
          body = c.body,
        })
      end
    end

    local reviews = {}
    for _, r in ipairs(view.reviews or {}) do
      if r.body and r.body ~= '' then
        table.insert(reviews, {
          author = (r.author and r.author.login) or '?',
          state = r.state or '',
          body = r.body,
        })
      end
    end

    local inline = {}
    for _, c in ipairs(results.inline or {}) do
      table.insert(inline, {
        path = c.path,
        line = c.line or c.original_line,
        author = (c.user and c.user.login) or '?',
        body = c.body or '',
      })
    end

    callback {
      kind = 'pr',
      repo = repo or '?',
      number = view.number,
      title = view.title,
      body = view.body,
      author = (view.author and view.author.login) or '?',
      state = view.state,
      base = view.baseRefName,
      head = view.headRefName,
      labels = labels,
      diff = diff,
      reviews = reviews,
      comments = comments,
      inline_comments = inline,
    }
  end

  local function tick()
    pending = pending - 1
    if pending == 0 then
      finalize()
    end
  end

  vim.system({
    'gh',
    'pr',
    'view',
    url,
    '--json',
    'title,body,author,labels,state,number,baseRefName,headRefName,comments,reviews',
  }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code == 0 then
        local ok, parsed = pcall(vim.json.decode, obj.stdout, { luanil = { object = true, array = true } })
        if ok then
          results.view = parsed
        end
      end
      tick()
    end)
  end)

  vim.system({ 'gh', 'pr', 'diff', url }, { text = true }, function(obj)
    vim.schedule(function()
      results.diff = obj.code == 0 and obj.stdout or nil
      tick()
    end)
  end)

  if repo and number then
    vim.system(
      { 'gh', 'api', string.format('repos/%s/pulls/%d/comments', repo, number), '--paginate' },
      { text = true },
      function(obj)
        vim.schedule(function()
          if obj.code == 0 then
            local ok, parsed = pcall(vim.json.decode, obj.stdout, { luanil = { object = true, array = true } })
            results.inline = (ok and type(parsed) == 'table') and parsed or {}
          else
            results.inline = {}
          end
          tick()
        end)
      end
    )
  end
end

local function fetch_jira_context(meta, callback)
  local key = meta.key
  if not key then
    callback(nil, 'no jira key')
    return
  end
  require('dashboard.jira').fetch_issue(key, function(issue, err)
    if not issue then
      callback(nil, err)
      return
    end
    issue.kind = 'jira'
    callback(issue)
  end)
end

local function fetch_context(meta, callback)
  local cache_key = meta.kind == 'jira' and meta.key or meta.url
  if context_cache[cache_key] then
    callback(context_cache[cache_key])
    return
  end
  local function done(ctx, err)
    if ctx then
      context_cache[cache_key] = ctx
    end
    callback(ctx, err)
  end
  if meta.kind == 'pr' then
    fetch_pr_context(meta, done)
  elseif meta.kind == 'jira' then
    fetch_jira_context(meta, done)
  else
    callback(nil, 'unsupported row kind for analyze')
  end
end

local function format_pr_context(ctx)
  local parts = {}
  table.insert(
    parts,
    string.format(
      [[<pr_context>
Repository: %s
PR #%d: %s
Author: %s · State: %s · Base: %s ← Head: %s
Labels: %s

Description:
%s]],
      ctx.repo,
      ctx.number,
      ctx.title or '',
      ctx.author or '?',
      ctx.state or '?',
      ctx.base or '?',
      ctx.head or '?',
      table.concat(ctx.labels or {}, ', '),
      ctx.body or '(no description)'
    )
  )

  if ctx.reviews and #ctx.reviews > 0 then
    table.insert(parts, '\nReviews:')
    for _, r in ipairs(ctx.reviews) do
      table.insert(parts, string.format('%s (%s):\n%s\n---', r.author, r.state, r.body))
    end
  end

  if ctx.comments and #ctx.comments > 0 then
    table.insert(parts, '\nComments:')
    for _, c in ipairs(ctx.comments) do
      table.insert(parts, string.format('%s:\n%s\n---', c.author, c.body))
    end
  end

  if ctx.inline_comments and #ctx.inline_comments > 0 then
    table.insert(parts, '\nInline review comments:')
    local cap = 50
    local n = math.min(cap, #ctx.inline_comments)
    for i = 1, n do
      local c = ctx.inline_comments[i]
      table.insert(
        parts,
        string.format('%s:%s  %s: %s', c.path or '?', tostring(c.line or '?'), c.author or '?', c.body or '')
      )
    end
    if #ctx.inline_comments > cap then
      table.insert(parts, string.format('... (%d more inline comments truncated)', #ctx.inline_comments - cap))
    end
  end

  table.insert(parts, '\nDiff (may be truncated):')
  table.insert(parts, ctx.diff or '(no diff)')
  table.insert(parts, '</pr_context>')

  return table.concat(parts, '\n')
end

local function format_jira_context(ctx)
  local comments_text
  if ctx.comments and #ctx.comments > 0 then
    local strs = {}
    for _, c in ipairs(ctx.comments) do
      table.insert(strs, c.author .. ':\n' .. (c.body or ''))
    end
    comments_text = table.concat(strs, '\n---\n')
  else
    comments_text = '(no comments)'
  end
  return string.format(
    [[<jira_context>
Issue: %s
Type: %s · Status: %s · Priority: %s
Reporter: %s · Assignee: %s
Labels: %s

Summary: %s

Description:
%s

Comments:
%s
</jira_context>]],
    ctx.key,
    ctx.type,
    ctx.status,
    ctx.priority,
    ctx.reporter,
    ctx.assignee,
    table.concat(ctx.labels or {}, ', '),
    ctx.title or '',
    ctx.description or '(no description)',
    comments_text
  )
end

local function format_context(ctx)
  if ctx.kind == 'pr' then
    return format_pr_context(ctx)
  end
  if ctx.kind == 'jira' then
    return format_jira_context(ctx)
  end
  return ''
end

function M.analyze(meta, prompt_key, callback)
  local prompt = PROMPTS[prompt_key]
  if not prompt then
    callback(nil, 'unknown prompt: ' .. tostring(prompt_key))
    return
  end
  fetch_context(meta, function(ctx, err)
    if not ctx then
      callback(nil, err or 'failed to fetch context')
      return
    end
    local system = 'You help a senior engineer scan a busy work dashboard. Be concise. No preamble. Get to the point.'
    local full_prompt = table.concat({
      system,
      format_context(ctx),
      prompt.instruction,
    }, '\n\n')
    call_claude(full_prompt, function(text, err2)
      if not text then
        callback(nil, err2)
        return
      end
      callback {
        text = text,
        prompt = prompt_key,
        label = prompt.label,
        ctx_kind = ctx.kind,
        ctx_id = ctx.kind == 'pr' and (ctx.repo .. '#' .. ctx.number) or ctx.key,
      }
    end)
  end)
end

function M.fetch_jira(meta, callback)
  fetch_jira_context(meta, callback)
end

return M
