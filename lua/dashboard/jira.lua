local M = {}

local config = {
  base_url = 'https://vitalsource.atlassian.net',
}

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
    fields = { 'summary', 'status', 'priority' },
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
        callback(nil, 'json parse error')
        return
      end
      if parsed.errorMessages and #parsed.errorMessages > 0 then
        callback(nil, table.concat(parsed.errorMessages, '; '))
        return
      end
      local issues = {}
      for _, issue in ipairs(parsed.issues or {}) do
        table.insert(issues, {
          key = issue.key,
          summary = (issue.fields and issue.fields.summary) or '',
          status = (issue.fields and issue.fields.status and issue.fields.status.name) or '',
          url = config.base_url .. '/browse/' .. issue.key,
        })
      end
      callback(issues)
    end)
  end)
end

function M.in_progress(callback)
  search('assignee = currentUser() AND status = "In Progress" ORDER BY updated DESC', callback)
end

function M.assigned(callback)
  search(
    'assignee = currentUser() AND statusCategory != Done AND status != "In Progress" ORDER BY updated DESC',
    callback
  )
end

return M
