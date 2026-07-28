local home = os.getenv 'HOME'
local config = home .. '/.config/nvim'

-- ######## UTILS ##################################
vim.api.nvim_create_user_command('Config', function()
  vim.cmd('cd ' .. config)
  vim.cmd 'edit init.lua'
end, {})

vim.api.nvim_create_user_command('Tm', function()
  vim.cmd('cd ' .. home)
  vim.cmd 'edit .tmux.conf'
end, {})

vim.api.nvim_create_user_command('Cl', function()
  vim.cmd('cd ' .. home .. '/.claude')
  vim.cmd 'edit settings.json'
end, {})

vim.api.nvim_create_user_command('Zs', function()
  vim.cmd('cd ' .. home)
  vim.cmd 'edit .zshrc'
end, {})

vim.api.nvim_create_user_command('Note', function()
  local current_date = os.date '%Y-%m-%d'
  local file = current_date .. '.txt'
  vim.cmd('cd ' .. home .. '/notes')
  os.execute('touch ' .. file)
  vim.cmd('edit ' .. file)
end, {})

vim.api.nvim_create_user_command('Aro', function()
  vim.cmd('cd ' .. home)
  vim.cmd 'edit .aerospace.toml'
end, {})

vim.api.nvim_create_user_command('Temp', function()
  vim.cmd('cd ' .. home .. '/temp')
  vim.cmd 'edit temp_readme.md'
end, {})
-- #################################################
