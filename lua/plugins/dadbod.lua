return {
  'andrewvenson-vst/vim-dadbod-ui',
  dependencies = {
    { 'andrewvenson-vst/vim-dadbod', lazy = true },
    { 'kristijanhusak/vim-dadbod-completion', ft = { 'sql', 'mysql', 'plsql' }, lazy = true }, -- Optional
  },
  cmd = {
    'DBUI',
    'DBUIToggle',
    'DBUIAddConnection',
    'DBUIFindBuffer',
  },
  init = function()
    -- Your DBUI configuration
    vim.g.db_ui_use_nerd_fonts = 1

    vim.api.nvim_set_hl(0, 'DbConnectedWinbar', { bg = '#00ff00', fg = '#000000', bold = true })
    vim.api.nvim_set_hl(0, 'DbUiGridHeader', { link = 'Title' })
    vim.api.nvim_set_hl(0, 'DbUiGridRowAlt', { link = 'CursorLine' })

    local grid = require 'dbui_grid'

    vim.api.nvim_create_autocmd('FileType', {
      pattern = { 'sql', 'mysql', 'plsql', 'dbout' },
      callback = function(args)
        local is_dbout = vim.bo.filetype == 'dbout'
        if is_dbout or vim.fn.exists 'b:db' == 1 then
          vim.wo.winbar = '%{%luaeval("require(\'dbui_grid\').winbar()")%}'
        end

        -- Hide the DBUI drawer once a query buffer is opened, whether via
        -- the tree or the Telescope db-connect picker.
        if not is_dbout and vim.fn.exists 'b:db' == 1 then
          vim.cmd 'DBUIClose'
        end

        if is_dbout then
          vim.opt_local.conceallevel = 2
          vim.opt_local.concealcursor = 'nc'
          grid.render(args.buf)
        end
      end,
    })

    -- Results land asynchronously; re-render the grid decorations whenever
    -- a query finishes (same events vim-dadbod-ui uses for its progress bar).
    vim.api.nvim_create_autocmd('User', {
      pattern = { 'DBQueryPost', '*DBExecutePost' },
      callback = function()
        vim.schedule(function()
          grid.render(0)
        end)
      end,
    })
  end,
}
