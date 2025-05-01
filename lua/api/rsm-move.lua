local home = os.getenv 'HOME'
local projects = home .. '/projects'
local mono = projects .. '/rsm-monorepo'
local domains = mono .. '/domains'
local config = home .. '/.config/nvim'

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

vim.api.nvim_create_user_command('Billing', function()
  vim.cmd('cd ' .. domains .. '/billing-ts')
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

vim.api.nvim_create_user_command('Port', function(opts)
  local port_name = opts.args
  local dbs_object = {
    localhost = 5432,
    ['dev-uni'] = 63342,
    ['dev-identity'] = 63343,
    ['dev-product'] = 63344,
    ['dev-delivery'] = 63350,
    ['dev-adopt'] = 63349,
    ['dev-partner'] = 63351,
    ['dev-orders'] = 63352,
    ['uat-identity'] = 63345,
    ['uat-delivery'] = 63346,
    ['uat-product'] = 63347,
    ['uat-uni'] = 63348,
    ['uat-orders'] = 63353,
    ['prod-uni'] = 63333,
    ['prod-delivery'] = 63334,
    ['prod-identity'] = 63337,
    ['prod-product'] = 63335,
    ['prod-orders'] = 63341,
    REDSHIFT = 63340,
  }

  if dbs_object[port_name] then
    local port = tostring(dbs_object[port_name])
    vim.fn.setreg('+', port)
    vim.notify("Port '" .. port .. "' copied to clipboard.", vim.log.levels.INFO)
  else
    vim.notify("Database with name '" .. port_name .. "' not found in the port object.", vim.log.levels.ERROR)
  end
end, { nargs = 1, desc = 'Copy database port to clipboard from the defined object. Usage: :Port <database_name>' })

-- vim.api.nvim_create_user_command('Aws', function(opts)
--   local args = vim.split(opts.args, ' ')
--   local env = args[1]
--   local accessCode = args[2]
--
--   if env == '' or accessCode == '' then
--     print 'Must provide a env'
--     return
--   end
--   os.execute('. set-creds ' .. env .. ' ' .. accessCode)
-- end, { nargs = '*' })
