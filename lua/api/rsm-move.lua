local home = os.getenv 'HOME'
local projects = home .. '/projects'
local config = home .. '/.config/nvim'

-- ######## UTILS ##################################
vim.api.nvim_create_user_command('Config', function()
  vim.cmd('cd ' .. config)
  vim.cmd 'edit init.lua'
end, {})

vim.api.nvim_create_user_command('Dad', function()
  vim.cmd('cd ' .. home .. '/.local/share/nvim/lazy/vim-dadbod-ui/autoload')
  vim.cmd 'edit db_ui.vim'
end, {})

vim.api.nvim_create_user_command('Tm', function()
  vim.cmd('cd ' .. home)
  vim.cmd 'edit .tmux.conf'
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

vim.api.nvim_create_user_command('Models', function()
  vim.cmd('cd ' .. domains .. '/models')
  vim.cmd 'edit package.json'
end, {})
-- #################################################

-- ######## VST ##################################
vim.api.nvim_create_user_command('Bc', function()
  vim.cmd('cd ' .. projects .. '/business-center')
  vim.cmd 'edit README.md'
end, {})

vim.api.nvim_create_user_command('Con', function()
  vim.cmd('cd ' .. projects .. '/connect')
  vim.cmd 'edit README.md'
end, {})

vim.api.nvim_create_user_command('Dm', function()
  vim.cmd('cd ' .. projects .. '/doorman')
  vim.cmd 'edit README.md'
end, {})

vim.api.nvim_create_user_command('Po', function()
  vim.cmd('cd ' .. projects .. '/program-orders')
  vim.cmd 'edit README.md'
end, {})

vim.api.nvim_create_user_command('Co', function()
  vim.cmd('cd ' .. projects .. '/connect')
  vim.cmd 'edit README.md'
end, {})

vim.api.nvim_create_user_command('Ns', function()
  vim.cmd('cd ' .. projects .. '/nsync')
  vim.cmd 'edit README.md'
end, {})
-- #################################################

-- ####### REDSHELF ################################
local mono = projects .. '/rsm-monorepo'
local domains = mono .. '/domains'

vim.api.nvim_create_user_command('Mono', function()
  vim.cmd('cd ' .. mono)
end, {})

vim.api.nvim_create_user_command('Uni', function()
  vim.cmd('cd ' .. domains .. '/university-ts')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('Product', function()
  vim.cmd('cd ' .. domains .. '/product-ts')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('Identity', function()
  vim.cmd('cd ' .. domains .. '/identity-ts')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('Delivery', function()
  vim.cmd('cd ' .. domains .. '/delivery-ts')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('PartnerTs', function()
  vim.cmd('cd ' .. domains .. '/partner-ts')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('BillingTs', function()
  vim.cmd('cd ' .. domains .. '/billing-ts')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('BillingPy', function()
  vim.cmd('cd ' .. domains .. '/billing_py')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('Graphs', function()
  vim.cmd('cd ' .. domains .. '/graphs')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('Adopt', function()
  vim.cmd('cd ' .. domains .. '/adopt-ts')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('Subs', function()
  vim.cmd('cd ' .. domains .. '/subgraphs')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('Dp', function()
  vim.cmd('cd ' .. domains .. '/delivery-provider-ts')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('Up', function()
  vim.cmd('cd ' .. domains .. '/university-provider-ts')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('Ip', function()
  vim.cmd('cd ' .. domains .. '/identity-provider-ts')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('Pbp', function()
  vim.cmd('cd ' .. domains .. '/publisher-provider-ts')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('Di', function()
  vim.cmd('cd ' .. domains .. '/data-ingestion')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('Shelf', function()
  vim.cmd('cd ' .. projects .. '/shelf-app')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('Toolbox', function()
  vim.cmd('cd ' .. projects .. '/toolbox')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('Manager', function()
  vim.cmd('cd ' .. projects .. '/manager-app')
  vim.cmd 'edit package.json'
end, {})

vim.api.nvim_create_user_command('Scripts', function()
  vim.cmd('cd ' .. home .. '/scripts')
end, {})

vim.api.nvim_create_user_command('Orders', function()
  vim.cmd('cd ' .. projects .. '/orders-service')
  vim.cmd 'edit package.json'
end, {})
