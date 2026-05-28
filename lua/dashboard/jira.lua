local M = {}

local config = {
  base_url = 'https://vitalsource.atlassian.net',
}

local adf_to_text -- forward declaration; defined further below

function M.setup(opts)
  opts = opts or {}
  if opts.base_url then
    config.base_url = opts.base_url
  end
  local env_url = vim.env.JIRA_BASE_URL
  if env_url and env_url ~= '' then
    config.base_url = env_url
  end
end

local function creds()
  local email = vim.env.JIRA_EMAIL
  local token = vim.env.JIRA_API_TOKEN
  if not email or email == '' or not token or token == '' then
    return nil, 'JIRA_EMAIL or JIRA_API_TOKEN not set'
  end
  return vim.base64.encode(email .. ':' .. token)
end

local function search(jql, callback)
  local auth, err = creds()
  if not auth then
    vim.schedule(function()
      callback(nil, err)
    end)
    return
  end

  local body = vim.json.encode({
    jql = jql,
    fields = { 'summary', 'status', 'priority', 'statuscategorychangedate', 'customfield_11615', 'comment', 'updated' },
    expand = 'changelog',
    maxResults = 30,
  })

  vim.system({
    'curl',
    '-sS',
    '-X',
    'POST',
    config.base_url .. '/rest/api/3/search/jql',
    '-H',
    'Authorization: Basic ' .. auth,
    '-H',
    'Accept: application/json',
    '-H',
    'Content-Type: application/json',
    '-d',
    body,
  }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        callback(nil, (obj.stderr ~= '' and obj.stderr) or ('curl exit ' .. obj.code))
        return
      end
      local ok, parsed = pcall(vim.json.decode, obj.stdout, { luanil = { object = true, array = true } })
      if not ok then
        callback(nil, 'json parse error: ' .. tostring(parsed):sub(1, 80) .. ' | body: ' .. (obj.stdout or ''):sub(1, 120))
        return
      end
      if type(parsed) ~= 'table' then
        callback(nil, 'unexpected response: ' .. tostring(parsed))
        return
      end
      if parsed.errorMessages and #parsed.errorMessages > 0 then
        callback(nil, table.concat(parsed.errorMessages, '; '))
        return
      end
      if parsed.status and tonumber(parsed.status) and tonumber(parsed.status) >= 400 then
        local msg = parsed.message
        if not msg or msg == '' then
          msg = 'Jira HTTP ' .. tostring(parsed.status)
        end
        callback(nil, msg)
        return
      end
      local issues = {}
      for _, issue in ipairs(parsed.issues or {}) do
        local f = issue.fields or {}
        local qa = f.customfield_11615
        local latest_author, latest_author_id, latest_body, latest_created
        local raw_comments = (f.comment and f.comment.comments) or {}
        if #raw_comments > 0 then
          local last = raw_comments[#raw_comments]
          latest_author = (last.author and last.author.displayName) or nil
          latest_author_id = (last.author and last.author.accountId) or nil
          latest_created = last.created
          latest_body = adf_to_text(last.body)
        end

        local change_author, change_author_id, change_created, change_items
        local histories = (issue.changelog and issue.changelog.histories) or {}
        if #histories > 0 then
          local newest = histories[1]
          for _, h in ipairs(histories) do
            if (h.created or '') > (newest.created or '') then
              newest = h
            end
          end
          change_author = (newest.author and newest.author.displayName) or nil
          change_author_id = (newest.author and newest.author.accountId) or nil
          change_created = newest.created
          change_items = {}
          for _, it in ipairs(newest.items or {}) do
            table.insert(change_items, {
              field = it.field or it.fieldId or '?',
              from = it.fromString,
              to = it.toString,
            })
          end
        end

        table.insert(issues, {
          key = issue.key,
          summary = f.summary or '',
          status = (f.status and f.status.name) or '',
          url = config.base_url .. '/browse/' .. issue.key,
          qa_assignee = (qa and qa.displayName) or nil,
          status_change_at = f.statuscategorychangedate,
          updated_at = f.updated,
          comment_count = (f.comment and f.comment.total) or 0,
          latest_comment_author = latest_author,
          latest_comment_author_id = latest_author_id,
          latest_comment_body = latest_body,
          latest_comment_created = latest_created,
          latest_change_author = change_author,
          latest_change_author_id = change_author_id,
          latest_change_created = change_created,
          latest_change_items = change_items,
        })
      end
      callback(issues)
    end)
  end)
end

local cached_account_id = nil

function M.fetch_myself(callback)
  if cached_account_id then
    callback(cached_account_id)
    return
  end
  local auth, err = creds()
  if not auth then
    callback(nil, err)
    return
  end
  vim.system({
    'curl',
    '-sS',
    config.base_url .. '/rest/api/3/myself',
    '-H',
    'Authorization: Basic ' .. auth,
    '-H',
    'Accept: application/json',
  }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        callback(nil, (obj.stderr ~= '' and obj.stderr) or ('curl exit ' .. obj.code))
        return
      end
      local ok, parsed = pcall(vim.json.decode, obj.stdout, { luanil = { object = true, array = true } })
      if not ok or type(parsed) ~= 'table' or not parsed.accountId then
        callback(nil, 'unexpected response')
        return
      end
      cached_account_id = parsed.accountId
      callback(cached_account_id)
    end)
  end)
end

function M.assigned_active(callback)
  search(
    'assignee = currentUser() AND statusCategory != Done '
      .. 'AND status NOT IN ("New Ticket", "On Prod", "Done", "Closed") ORDER BY updated DESC',
    callback
  )
end

function M.qa_assignee_active(callback)
  search(
    '"QA Assignee" = currentUser() AND status NOT IN ("Passed QA", "Done", "Closed", "On Prod") '
      .. 'AND statusCategory != Done ORDER BY updated DESC',
    callback
  )
end

function M.recent_activity(callback)
  search(
    '(assignee = currentUser() OR reporter = currentUser() OR "QA Assignee" = currentUser()) '
      .. 'AND updated >= -7d ORDER BY updated DESC',
    callback
  )
end

adf_to_text = function(node)
  if type(node) ~= 'table' then
    return ''
  end
  local out = {}
  if node.type == 'text' and node.text then
    local text = node.text
    if node.marks then
      for _, mark in ipairs(node.marks) do
        if mark.type == 'link' and mark.attrs and mark.attrs.href then
          text = '[' .. text .. '](' .. mark.attrs.href .. ')'
          break
        end
      end
    end
    table.insert(out, text)
  elseif node.type == 'mention' then
    local name = (node.attrs and (node.attrs.text or ('@' .. (node.attrs.id or '?')))) or '@?'
    table.insert(out, name)
  elseif node.type == 'hardBreak' then
    table.insert(out, '\n')
  elseif node.type == 'rule' then
    table.insert(out, '\n---\n')
  elseif node.type == 'inlineCard' or node.type == 'blockCard' then
    local url = (node.attrs and node.attrs.url) or ''
    table.insert(out, url)
  end
  for _, child in ipairs(node.content or {}) do
    table.insert(out, adf_to_text(child))
  end
  local result = table.concat(out, '')
  if node.type == 'paragraph' then
    result = result .. '\n\n'
  elseif node.type == 'heading' then
    local level = (node.attrs and node.attrs.level) or 1
    result = string.rep('#', level) .. ' ' .. result .. '\n\n'
  elseif node.type == 'listItem' then
    result = '- ' .. result .. '\n'
  elseif node.type == 'codeBlock' then
    local lang = (node.attrs and node.attrs.language) or ''
    result = '```' .. lang .. '\n' .. result .. '\n```\n\n'
  elseif node.type == 'blockquote' then
    local quoted = {}
    for line in result:gmatch '[^\n]+' do
      table.insert(quoted, '> ' .. line)
    end
    result = table.concat(quoted, '\n') .. '\n\n'
  end
  return result
end

local function creds()
  local email = vim.env.JIRA_EMAIL
  local token = vim.env.JIRA_API_TOKEN
  if not email or email == '' or not token or token == '' then
    return nil
  end
  return vim.base64.encode(email .. ':' .. token)
end

function M.fetch_issue(key, callback)
  if not key then
    callback(nil, 'no key')
    return
  end
  local auth = creds()
  if not auth then
    callback(nil, 'JIRA_EMAIL or JIRA_API_TOKEN not set')
    return
  end

  local results = { issue = nil, comments_resp = nil }
  local errors = {}
  local pending = 2

  local function finalize()
    if #errors > 0 then
      callback(nil, table.concat(errors, '; '))
      return
    end
    local issue = results.issue
    if not issue then
      callback(nil, 'issue fetch failed')
      return
    end
    local f = issue.fields or {}
    local comments_resp = results.comments_resp or {}
    local raw_comments = comments_resp.comments or {}
    local comments = {}
    for _, c in ipairs(raw_comments) do
      table.insert(comments, {
        id = c.id and tostring(c.id) or nil,
        parent_id = c.parentId and tostring(c.parentId) or nil,
        author = (c.author and c.author.displayName) or '?',
        body = adf_to_text(c.body),
        created = c.created,
        updated = c.updated,
      })
    end
    callback {
      key = issue.key or key,
      title = f.summary or '',
      description = adf_to_text(f.description),
      status = (f.status and f.status.name) or '?',
      priority = (f.priority and f.priority.name) or '?',
      type = (f.issuetype and f.issuetype.name) or '?',
      reporter = (f.reporter and f.reporter.displayName) or '?',
      assignee = (f.assignee and f.assignee.displayName) or '?',
      labels = f.labels or {},
      comments = comments,
      comment_total = comments_resp.total or #comments,
    }
  end

  local function tick()
    pending = pending - 1
    if pending == 0 then
      finalize()
    end
  end

  local function parse_response(obj, key_in_results)
    if obj.code ~= 0 then
      table.insert(errors, (obj.stderr ~= '' and obj.stderr) or ('curl exit ' .. obj.code))
      tick()
      return
    end
    local ok, parsed = pcall(vim.json.decode, obj.stdout, { luanil = { object = true, array = true } })
    if not ok or type(parsed) ~= 'table' then
      table.insert(errors, 'json parse error')
      tick()
      return
    end
    if parsed.errorMessages and #parsed.errorMessages > 0 then
      table.insert(errors, table.concat(parsed.errorMessages, '; '))
      tick()
      return
    end
    if parsed.status and tonumber(parsed.status) and tonumber(parsed.status) >= 400 then
      table.insert(errors, parsed.message or ('Jira HTTP ' .. tostring(parsed.status)))
      tick()
      return
    end
    results[key_in_results] = parsed
    tick()
  end

  vim.system({
    'curl',
    '-sS',
    '-G',
    config.base_url .. '/rest/api/3/issue/' .. key,
    '--data-urlencode',
    'fields=summary,description,status,priority,issuetype,reporter,assignee,labels',
    '-H',
    'Authorization: Basic ' .. auth,
    '-H',
    'Accept: application/json',
  }, { text = true }, function(obj)
    vim.schedule(function()
      parse_response(obj, 'issue')
    end)
  end)

  vim.system({
    'curl',
    '-sS',
    '-G',
    config.base_url .. '/rest/api/3/issue/' .. key .. '/comment',
    '--data-urlencode',
    'maxResults=100',
    '--data-urlencode',
    'orderBy=created',
    '-H',
    'Authorization: Basic ' .. auth,
    '-H',
    'Accept: application/json',
  }, { text = true }, function(obj)
    vim.schedule(function()
      parse_response(obj, 'comments_resp')
    end)
  end)
end

return M
