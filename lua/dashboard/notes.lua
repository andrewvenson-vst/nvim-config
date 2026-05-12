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
