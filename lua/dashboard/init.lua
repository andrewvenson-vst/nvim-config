local M = {}

function M.setup(opts)
  opts = opts or {}
  require('dashboard.jira').setup(opts.jira)

  vim.api.nvim_create_user_command('Dashboard', function()
    require('dashboard.ui').open()
  end, { desc = 'Open status dashboard (GitHub + Jira)' })

  vim.keymap.set('n', '<leader>od', function()
    require('dashboard.ui').open()
  end, { desc = '[O]pen [D]ashboard' })
end

return M
