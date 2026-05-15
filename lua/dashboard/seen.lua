local M = {}

local function path()
  return vim.fn.stdpath 'data' .. '/dashboard-seen.json'
end

local cache = nil

local function load()
  if cache then
    return cache
  end
  cache = {}
  local p = path()
  if vim.fn.filereadable(p) ~= 1 then
    return cache
  end
  local ok_read, content = pcall(vim.fn.readfile, p)
  if not ok_read or not content or #content == 0 then
    return cache
  end
  local ok_parse, parsed = pcall(vim.json.decode, table.concat(content, '\n'))
  if ok_parse and type(parsed) == 'table' then
    cache = parsed
  end
  return cache
end

local function save()
  if not cache then
    return
  end
  local encoded = vim.json.encode(cache)
  pcall(vim.fn.writefile, vim.split(encoded, '\n', { plain = true }), path())
end

function M.is_seen(key, updated_iso)
  if not key or not updated_iso then
    return false
  end
  local marked = load()[key]
  if not marked then
    return false
  end
  return marked >= updated_iso
end

function M.mark(key, updated_iso)
  if not key or not updated_iso then
    return
  end
  load()[key] = updated_iso
  save()
end

function M.unmark(key)
  if not key then
    return
  end
  load()[key] = nil
  save()
end

return M
