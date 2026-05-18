local M = {}

local QUERY = [[
query {
  mine: search(query: "is:pr is:open archived:false author:@me -org:VirdocsSoftware sort:updated-desc", type: ISSUE, first: 30) {
    nodes {
      ... on PullRequest {
        number
        title
        url
        body
        isDraft
        updatedAt
        repository { nameWithOwner }
        reviewDecision
        latestReviews(first: 20) { nodes { state } }
        reviewThreads(first: 100) { totalCount nodes { isResolved } }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      }
    }
  }
  reviews: search(query: "is:pr is:open archived:false review-requested:@me -org:VirdocsSoftware sort:updated-desc", type: ISSUE, first: 30) {
    nodes {
      ... on PullRequest {
        number
        title
        url
        body
        updatedAt
        repository { nameWithOwner }
        reviewDecision
        latestReviews(first: 20) { nodes { state } }
        reviewThreads(first: 100) { totalCount nodes { isResolved } }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      }
    }
  }
}
]]

local function flatten(nodes)
  local out = {}
  for _, n in ipairs(nodes or {}) do
    local rollup
    local commits = (n.commits and n.commits.nodes) or {}
    if commits[1] and commits[1].commit and commits[1].commit.statusCheckRollup then
      rollup = commits[1].commit.statusCheckRollup.state
    end
    local approvals = 0
    for _, r in ipairs((n.latestReviews and n.latestReviews.nodes) or {}) do
      if r.state == 'APPROVED' then
        approvals = approvals + 1
      end
    end

    local unresolved = 0
    for _, t in ipairs((n.reviewThreads and n.reviewThreads.nodes) or {}) do
      if not t.isResolved then
        unresolved = unresolved + 1
      end
    end

    table.insert(out, {
      number = n.number,
      title = n.title,
      url = n.url,
      body = n.body,
      isDraft = n.isDraft,
      updatedAt = n.updatedAt,
      repository = n.repository,
      reviewDecision = n.reviewDecision,
      approvalCount = approvals,
      ciStatus = rollup,
      unresolvedThreads = unresolved,
    })
  end
  return out
end

function M.fetch_prs(callback)
  vim.system({ 'gh', 'api', 'graphql', '-f', 'query=' .. QUERY }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        callback(nil, (obj.stderr ~= '' and obj.stderr) or ('exit ' .. obj.code))
        return
      end
      local ok, parsed = pcall(vim.json.decode, obj.stdout, { luanil = { object = true, array = true } })
      if not ok then
        callback(nil, 'json parse error')
        return
      end
      if parsed.errors then
        callback(nil, (parsed.errors[1] and parsed.errors[1].message) or 'graphql error')
        return
      end
      local data = parsed.data or {}
      callback {
        my_prs = flatten(data.mine and data.mine.nodes),
        reviews = flatten(data.reviews and data.reviews.nodes),
      }
    end)
  end)
end

local THREADS_QUERY = [[
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes {
          isResolved
          isOutdated
          path
          line
          originalLine
          startLine
          originalStartLine
          diffSide
          comments(first: 50) {
            nodes {
              databaseId
              author { login }
              createdAt
              body
              diffHunk
            }
          }
        }
      }
    }
  }
}
]]

function M.fetch_review_threads(repo, number, callback)
  local owner, name = repo:match '^([^/]+)/(.+)$'
  if not owner then
    callback(nil, 'invalid repo: ' .. tostring(repo))
    return
  end
  vim.system({
    'gh',
    'api',
    'graphql',
    '-f',
    'query=' .. THREADS_QUERY,
    '-F',
    'owner=' .. owner,
    '-F',
    'repo=' .. name,
    '-F',
    'number=' .. tostring(number),
  }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        callback(nil, (obj.stderr ~= '' and obj.stderr) or ('exit ' .. obj.code))
        return
      end
      local ok, parsed = pcall(vim.json.decode, obj.stdout, { luanil = { object = true, array = true } })
      if not ok or type(parsed) ~= 'table' then
        callback(nil, 'json parse error')
        return
      end
      if parsed.errors then
        callback(nil, (parsed.errors[1] and parsed.errors[1].message) or 'graphql error')
        return
      end
      local pr = parsed.data and parsed.data.repository and parsed.data.repository.pullRequest
      local nodes = (pr and pr.reviewThreads and pr.reviewThreads.nodes) or {}
      callback(nodes)
    end)
  end)
end

local function api_url_to_web(url)
  if not url then
    return nil
  end
  url = url:gsub('://api%.github%.com/repos/', '://github.com/')
  url = url:gsub('/pulls/(%d)', '/pull/%1')
  return url
end

function M.fetch_notifications(callback)
  vim.system({ 'gh', 'api', '-H', 'Accept: application/vnd.github+json', 'notifications' }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        callback(nil, (obj.stderr ~= '' and obj.stderr) or ('exit ' .. obj.code))
        return
      end
      local ok, parsed = pcall(vim.json.decode, obj.stdout, { luanil = { object = true, array = true } })
      if not ok or type(parsed) ~= 'table' then
        callback(nil, 'json parse error')
        return
      end
      local out = {}
      for _, n in ipairs(parsed) do
        table.insert(out, {
          id = n.id,
          reason = n.reason,
          unread = n.unread,
          updated_at = n.updated_at,
          title = n.subject and n.subject.title or '(untitled)',
          type = n.subject and n.subject.type or '',
          url = api_url_to_web(n.subject and n.subject.url) or (n.repository and n.repository.html_url),
          repo = n.repository and n.repository.full_name or '?',
          subject_url = n.subject and n.subject.url or nil,
          latest_comment_url = n.subject and n.subject.latest_comment_url or nil,
        })
      end
      callback(out)
    end)
  end)
end

function M.enrich_notifications(notifications, callback)
  if not notifications or type(notifications) ~= 'table' or #notifications == 0 then
    callback(notifications)
    return
  end
  local pending = 0
  local fired = false
  local function check_done()
    if pending == 0 and not fired then
      fired = true
      callback(notifications)
    end
  end
  for _, n in ipairs(notifications) do
    local url = n.latest_comment_url
    if url and url ~= '' and url ~= n.subject_url then
      pending = pending + 1
      local path = url:gsub('^https://api%.github%.com', '')
      vim.system({ 'gh', 'api', path }, { text = true }, function(obj)
        vim.schedule(function()
          pending = pending - 1
          if obj.code == 0 then
            local ok, parsed = pcall(vim.json.decode, obj.stdout, { luanil = { object = true, array = true } })
            if ok and type(parsed) == 'table' then
              n.comment_author = parsed.user and parsed.user.login or nil
              n.comment_body = parsed.body or nil
              n.comment_created_at = parsed.created_at or parsed.updated_at or nil
            end
          end
          check_done()
        end)
      end)
    end
  end
  check_done()
end

function M.fetch_actions(repo, callback)
  if not repo or repo == '' then
    callback(nil, 'no repo')
    return
  end
  vim.system({
    'gh',
    'run',
    'list',
    '--repo',
    repo,
    '--limit',
    '20',
    '--json',
    'conclusion,createdAt,displayTitle,event,headBranch,name,number,startedAt,status,updatedAt,url,workflowName',
  }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        callback(nil, (obj.stderr ~= '' and obj.stderr) or ('gh exit ' .. obj.code))
        return
      end
      local ok, parsed = pcall(vim.json.decode, obj.stdout, { luanil = { object = true, array = true } })
      if not ok or type(parsed) ~= 'table' then
        callback(nil, 'json parse error')
        return
      end
      local out = {}
      for _, r in ipairs(parsed) do
        table.insert(out, {
          number = r.number,
          workflow = r.workflowName or r.name or '?',
          title = r.displayTitle or '',
          branch = r.headBranch or '',
          event = r.event or '',
          status = r.status or '',
          conclusion = r.conclusion or '',
          created_at = r.createdAt,
          started_at = r.startedAt,
          updated_at = r.updatedAt,
          url = r.url,
        })
      end
      callback(out)
    end)
  end)
end

local function reconstruct_diff_from_files(files)
  local out = {}
  for _, f in ipairs(files or {}) do
    if f.patch and f.patch ~= '' then
      local new_path = f.filename or '?'
      local old_path
      if f.status == 'added' then
        old_path = '/dev/null'
      elseif f.status == 'renamed' then
        old_path = 'a/' .. (f.previous_filename or new_path)
      else
        old_path = 'a/' .. new_path
      end
      local new_marker = (f.status == 'removed') and '/dev/null' or ('b/' .. new_path)
      local header = 'diff --git a/'
        .. (f.previous_filename or new_path)
        .. ' b/'
        .. new_path
        .. '\n--- '
        .. old_path
        .. '\n+++ '
        .. new_marker
        .. '\n'
      table.insert(out, header .. f.patch)
    end
  end
  return table.concat(out, '\n')
end

function M.fetch_pr_diff(repo, number, url, callback)
  vim.system({ 'gh', 'pr', 'diff', url }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code == 0 then
        callback(obj.stdout)
        return
      end
      local stderr = obj.stderr or ''
      local too_large = stderr:find('too_large')
        or stderr:find('exceeded the maximum number of files')
        or stderr:find('HTTP 406')
      if not too_large then
        callback(nil, stderr ~= '' and stderr or ('gh exit ' .. obj.code))
        return
      end
      vim.system({
        'gh',
        'api',
        '--paginate',
        '/repos/' .. repo .. '/pulls/' .. tostring(number) .. '/files',
      }, { text = true }, function(fobj)
        vim.schedule(function()
          if fobj.code ~= 0 then
            callback(nil, (fobj.stderr ~= '' and fobj.stderr) or ('gh exit ' .. fobj.code))
            return
          end
          local ok, parsed = pcall(vim.json.decode, fobj.stdout, { luanil = { object = true, array = true } })
          if not ok or type(parsed) ~= 'table' then
            callback(nil, 'json parse error reading /pulls/N/files')
            return
          end
          callback(reconstruct_diff_from_files(parsed))
        end)
      end)
    end)
  end)
end

function M.fetch_pr_overview(repo, number, callback)
  vim.system({
    'gh',
    'pr',
    'view',
    tostring(number),
    '--repo',
    repo,
    '--json',
    'number,title,body,author,state,baseRefName,headRefName,headRefOid,labels',
  }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        callback(nil, (obj.stderr ~= '' and obj.stderr) or ('gh exit ' .. obj.code))
        return
      end
      local ok, parsed = pcall(vim.json.decode, obj.stdout, { luanil = { object = true, array = true } })
      if not ok or type(parsed) ~= 'table' then
        callback(nil, 'json parse error')
        return
      end
      local labels = {}
      for _, l in ipairs(parsed.labels or {}) do
        table.insert(labels, l.name)
      end
      callback {
        number = parsed.number,
        title = parsed.title,
        body = parsed.body,
        author = (parsed.author and parsed.author.login) or '?',
        state = parsed.state,
        base = parsed.baseRefName,
        head = parsed.headRefName,
        head_sha = parsed.headRefOid,
        labels = labels,
      }
    end)
  end)
end

return M
