local function dbui_is_open()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == 'dbui' then
      return true
    end
  end

  return false
end

local function kill_bc_ports_and_refresh_dadbod()
  if vim.fn.executable 'killbcports' ~= 1 then
    vim.notify('killbcports is not on your PATH', vim.log.levels.ERROR)
    return
  end

  local was_dbui_open = dbui_is_open()
  local output = vim.fn.system { 'killbcports' }

  if vim.v.shell_error ~= 0 then
    local message = vim.trim(output)
    if message == '' then
      message = 'killbcports failed'
    end
    vim.notify(message, vim.log.levels.ERROR)
    return
  end

  if vim.fn.exists '*db_ui#reset_state' == 1 then
    if was_dbui_open and vim.fn.exists ':DBUIClose' == 2 then
      vim.cmd 'DBUIClose'
    end

    vim.fn['db_ui#reset_state']()

    if was_dbui_open and vim.fn.exists ':DBUI' == 2 then
      vim.cmd 'DBUI'
    end
  end

  vim.notify('Killed BC ports and refreshed dadbod')
end

vim.api.nvim_create_user_command('KillBcPorts', kill_bc_ports_and_refresh_dadbod, {
  desc = 'Kill BC ports and refresh dadbod',
})

local function any_dbui_buffer_open()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local ft = vim.bo[buf].filetype
      if ft == 'dbui' or ft == 'dbout' then
        return true
      end
      if pcall(vim.api.nvim_buf_get_var, buf, 'dbui_db_key_name') then
        return true
      end
    end
  end
  return false
end

local had_dbui_buffers = false
local check_timer = nil

local function check_dbui_buffers()
  if check_timer then
    check_timer:stop()
    check_timer:close()
  end
  check_timer = vim.defer_fn(function()
    check_timer = nil
    local now_open = any_dbui_buffer_open()
    if had_dbui_buffers and not now_open and vim.fn.executable 'killbcports' == 1 then
      vim.fn.system { 'killbcports' }
    end
    had_dbui_buffers = now_open
  end, 50)
end

vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout', 'FileType' }, {
  callback = check_dbui_buffers,
  desc = 'Kill BC ports once no DBUI buffers remain',
})

-- :qa tears everything down at once without firing BufDelete/BufWipeout for
-- each buffer, so the check above never gets a transition to react to.
-- Catch that case with one final check right before Neovim actually exits.
vim.api.nvim_create_autocmd('VimLeavePre', {
  callback = function()
    if had_dbui_buffers and vim.fn.executable 'killbcports' == 1 then
      vim.fn.system { 'killbcports' }
    end
  end,
  desc = 'Kill BC ports on exit if a DBUI buffer was still open',
})

local function resize_mode()
  vim.notify('-- RESIZE -- h/j/k/l to resize, any other key to exit', vim.log.levels.INFO)
  vim.cmd 'redraw'
  while true do
    local ok, char = pcall(vim.fn.getchar)
    if not ok then
      break
    end

    local key = type(char) == 'number' and vim.fn.nr2char(char) or char
    if key == 'h' then
      vim.cmd 'vertical resize -3'
    elseif key == 'l' then
      vim.cmd 'vertical resize +3'
    elseif key == 'k' then
      vim.cmd 'resize +2'
    elseif key == 'j' then
      vim.cmd 'resize -2'
    else
      break
    end
    vim.cmd 'redraw'
  end
  vim.cmd 'echo ""'
  vim.cmd 'redraw'
end

vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')
vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })
vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Move focus to the upper window' })
vim.keymap.set('n', '<leader>p', ':DBUIToggle<CR>', { desc = 'Toggle dbui drawer' })
vim.keymap.set('n', '<leader>kb', kill_bc_ports_and_refresh_dadbod, { desc = 'Kill BC ports + refresh dadbod' })
vim.keymap.set('n', '<leader>cc', '<cmd>ClaudeCode<CR>', { desc = 'Toggle Claude Code' })
vim.keymap.set('n', '<leader>R', resize_mode, { desc = 'Resize window (hjkl, any other key exits)' })

function OpenGitHub()
  local file = vim.fn.expand '%' -- Get current file path
  local line = vim.fn.line '.' -- Get current line number
  local remote = vim.fn.system('git config --get remote.origin.url'):gsub('\n', '')
  local branch = vim.fn.system('git rev-parse --abbrev-ref HEAD'):gsub('\n', '')

  if remote:find 'github.com' then
    remote = remote:gsub('git@github.com:', 'https://github.com/'):gsub('%.git$', '')
    local url = string.format('%s/blob/%s/%s#L%d', remote, branch, file, line)
    vim.fn.system(string.format("open '%s'", url)) -- MacOS: open, Linux: xdg-open
  else
    print 'Not a GitHub repository!'
  end
end

vim.api.nvim_set_keymap('n', '<leader>gh', ':lua OpenGitHub()<CR>', { noremap = true, silent = true })
