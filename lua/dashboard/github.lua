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
        latestReviews(first: 20) { nodes { state author { login } submittedAt } }
        comments(last: 1) { totalCount nodes { author { login } createdAt } }
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
        latestReviews(first: 20) { nodes { state author { login } submittedAt } }
        comments(last: 1) { totalCount nodes { author { login } createdAt } }
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
    local last_review_at, last_review_author
    local latest = (n.latestReviews and n.latestReviews.nodes) or {}
    for _, r in ipairs(latest) do
      if r.state == 'APPROVED' then
        approvals = approvals + 1
      end
      if r.submittedAt and (not last_review_at or r.submittedAt > last_review_at) then
        last_review_at = r.submittedAt
        last_review_author = r.author and r.author.login
      end
    end

    local last_comment_at, last_comment_author
    local cnodes = (n.comments and n.comments.nodes) or {}
    if cnodes[1] then
      last_comment_at = cnodes[1].createdAt
      last_comment_author = cnodes[1].author and cnodes[1].author.login
    end

    local last_activity_at, last_activity_author
    if last_comment_at and (not last_review_at or last_comment_at > last_review_at) then
      last_activity_at, last_activity_author = last_comment_at, last_comment_author
    elseif last_review_at then
      last_activity_at, last_activity_author = last_review_at, last_review_author
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
      lastActivityAt = last_activity_at,
      lastActivityAuthor = last_activity_author,
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
        })
      end
      callback(out)
    end)
  end)
end

return M
