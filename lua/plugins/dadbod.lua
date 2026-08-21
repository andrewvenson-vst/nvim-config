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
          grid.refresh_winbar(vim.api.nvim_get_current_win())
        end

        -- Hide the DBUI drawer once a query buffer is opened, whether via
        -- the tree or the Telescope db-connect picker.
        if not is_dbout and vim.fn.exists 'b:db' == 1 then
          vim.cmd 'DBUIClose'
        end

        if is_dbout then
          vim.opt_local.conceallevel = 2
          vim.opt_local.concealcursor = 'nc'
          vim.opt_local.wrap = false
          vim.opt_local.sidescroll = 1
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
          grid.refresh_winbar(vim.api.nvim_get_current_win())
        end)
      end,
    })

    -- The winbar isn't a lazy %{...} expression -- we write it directly via
    -- grid.refresh_winbar, since Neovim only re-runs a statusline expression
    -- when its own heuristics decide it's dirty, and pure horizontal/
    -- vertical scrolling doesn't reliably trigger that.
    --
    -- CursorMoved covers ordinary navigation (h/l/j/k/w/$/etc.): by the time
    -- it fires, Neovim has already settled any resulting scroll, so it's
    -- safe to read the view synchronously.
    vim.api.nvim_create_autocmd('CursorMoved', {
      callback = function()
        grid.refresh_winbar(vim.api.nvim_get_current_win())
      end,
    })

    -- WinScrolled covers view changes with no cursor move (zl/zh, mouse
    -- wheel, <C-e>/<C-d> etc). v:event is keyed by the window IDs that
    -- changed (plus an "all" summary key), which also makes this correct
    -- for a split query/results layout instead of only handling the first
    -- window named in <amatch>. Deferred one tick via vim.schedule: a
    -- vertical move that also resets leftcol (e.g. j/k snapping the view
    -- back to column 0) can fire WinScrolled before that reset is fully
    -- settled, so reading it synchronously here can grab a leftcol that's
    -- already stale by the time the screen finishes updating.
    vim.api.nvim_create_autocmd('WinScrolled', {
      callback = function()
        for winid_str, _ in pairs(vim.v.event) do
          local win = tonumber(winid_str)
          if win then
            vim.schedule(function()
              grid.refresh_winbar(win)
            end)
          end
        end
      end,
    })
  end,
}
