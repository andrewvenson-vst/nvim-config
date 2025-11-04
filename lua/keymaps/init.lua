vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')
vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })
vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Move focus to the upper window' })
vim.keymap.set('n', '<leader>p', ':DBUIToggle<CR>', { desc = 'Toggle dbui drawer' })

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
