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

    vim.api.nvim_create_autocmd('FileType', {
      pattern = { 'sql', 'mysql', 'plsql', 'dbout' },
      callback = function()
        local is_dbout = vim.bo.filetype == 'dbout'
        if is_dbout or vim.fn.exists 'b:db' == 1 then
          vim.wo.winbar = '%#DbConnectedWinbar#%{db_ui#statusline()}%*'
        end

        -- Hide the DBUI drawer once a query buffer is opened, whether via
        -- the tree or the Telescope db-connect picker.
        if not is_dbout and vim.fn.exists 'b:db' == 1 then
          vim.cmd 'DBUIClose'
        end
      end,
    })
  end,
}
