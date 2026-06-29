local M = {}

function M.setup(opts)
  opts = opts or {}
  require('dashboard.jira').setup(opts.jira)
  require('dashboard.claude').setup(opts.claude)
  require('dashboard.notes').setup(opts.notes)
  require('dashboard.ui').setup {
    repo_paths = opts.repo_paths,
    refresh_after = opts.refresh_after,
    jira_status_order = opts.jira_status_order,
  }

  vim.api.nvim_create_user_command('Dashboard', function()
    require('dashboard.ui').open()
  end, { desc = 'Open status dashboard (GitHub + Jira)' })

  vim.keymap.set('n', '<leader>od', function()
    require('dashboard.ui').open()
  end, { desc = '[O]pen [D]ashboard' })

  vim.keymap.set('n', '<leader>or', function()
    require('dashboard.ui').focus_last_result()
  end, { desc = '[O]pen last [R]esult window' })

  vim.keymap.set('n', '<leader>jb', function()
    require('dashboard.ui').branch_picker()
  end, { desc = '[J]ira [B]ranch picker (tickets + existing local branches)' })
end

return M
