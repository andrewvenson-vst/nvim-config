local M = {}

local config = {
  notes_dir = '~/notes',
  filename_format = '%Y-%m-%d.txt',
}

function M.setup(opts)
  opts = opts or {}
  for k, v in pairs(opts) do
    config[k] = v
  end
end

function M.path_for_today()
  local dir = vim.fn.expand(config.notes_dir)
  local name = os.date(config.filename_format)
  return dir .. '/' .. name
end

function M.read_today()
  local path = M.path_for_today()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  return vim.fn.readfile(path)
end

function M.read_file(path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  return vim.fn.readfile(path)
end

function M.find_previous(today_date)
  local dir = vim.fn.expand(config.notes_dir)
  if vim.fn.isdirectory(dir) ~= 1 then
    return nil, nil
  end
  local files = vim.fn.glob(dir .. '/*.txt', false, true)
  local best, best_date = nil, nil
  for _, f in ipairs(files) do
    local name = vim.fn.fnamemodify(f, ':t:r')
    if name:match '^%d%d%d%d%-%d%d%-%d%d$' and name < today_date then
      if not best_date or name > best_date then
        best, best_date = f, name
      end
    end
  end
  return best, best_date
end

function M.append(line)
  local path = M.path_for_today()
  local dir = vim.fn.fnamemodify(path, ':h')
  vim.fn.mkdir(dir, 'p')
  local f = io.open(path, 'a')
  if not f then
    return false, 'could not open ' .. path
  end
  f:write(line .. '\n')
  f:close()
  return true
end

return M
