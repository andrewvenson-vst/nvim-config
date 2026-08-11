return { -- Fuzzy Finder (files, lsp, etc)
  'nvim-telescope/telescope.nvim',
  event = 'VimEnter',
  branch = '0.1.x',
  dependencies = {
    'nvim-lua/plenary.nvim',
    {
      'nvim-telescope/telescope-fzf-native.nvim',
      build = 'make',
      cond = function()
        return vim.fn.executable 'make' == 1
      end,
    },
    { 'nvim-telescope/telescope-ui-select.nvim' },
    { 'nvim-tree/nvim-web-devicons', enabled = vim.g.have_nerd_font },
  },
  config = function()
    require('telescope').setup {
      extensions = {
        ['ui-select'] = {
          require('telescope.themes').get_dropdown(),
        },
      },
      -- Add safety defaults to prevent cursor errors
      defaults = {
        prompt_prefix = ' ',
        selection_caret = '▸ ',
        entry_prefix = ' ',
        path_display = { 'truncate' },
        file_ignore_patterns = { 'node_modules', '.git' },
        set_env = { COLORTERM = 'truecolor' },
        -- Prevent cursor position errors
        layout_strategy = 'horizontal',
        layout_config = {
          horizontal = {
            prompt_position = 'top',
            preview_width = 0.55,
            results_width = 0.8,
          },
        },
      },
      pickers = {
        -- Add safety for LSP operations
        lsp_definitions = {
          jump_type = 'never', -- Don't jump automatically
        },
        lsp_references = {
          jump_type = 'never',
        },
        lsp_implementations = {
          jump_type = 'never',
        },
        lsp_type_definitions = {
          jump_type = 'never',
        },
      },
    }

    pcall(require('telescope').load_extension, 'fzf')
    pcall(require('telescope').load_extension, 'ui-select')

    local builtin = require 'telescope.builtin'

    -- Safe LSP navigation functions with error handling
    local function safe_lsp_call(builtin_func, desc)
      return function()
        local ok, result = pcall(builtin_func)
        if not ok then
          vim.notify('Telescope LSP call failed: ' .. desc, vim.log.levels.WARN)
        end
      end
    end

    vim.keymap.set('n', '<leader>sh', builtin.help_tags, { desc = '[S]earch [H]elp' })
    vim.keymap.set('n', '<leader>sk', builtin.keymaps, { desc = '[S]earch [K]eymaps' })
    vim.keymap.set('n', '<leader>sf', builtin.find_files, { desc = '[S]earch [F]iles' })
    vim.keymap.set('n', '<leader>ss', builtin.builtin, { desc = '[S]earch [S]elect Telescope' })
    vim.keymap.set('n', '<leader>sw', builtin.grep_string, { desc = '[S]earch current [W]ord' })
    vim.keymap.set('n', '<leader>sg', builtin.live_grep, { desc = '[S]earch by [G]rep' })
    vim.keymap.set('n', '<leader>sgf', builtin.git_files, { desc = '[S]earch [G]it [F]iles' })
    vim.keymap.set('n', '<leader>sgs', builtin.git_status, { desc = '[S]earch [G]it [S]tatus (changed files)' })
    vim.keymap.set('n', '<leader>sgc', builtin.git_commits, { desc = '[S]earch [Git] [C]ommits' })
    vim.keymap.set('n', '<leader>sgb', builtin.git_branches, { desc = '[S]earch [Git] [B]ranches' })
    vim.keymap.set('n', '<leader>sd', builtin.diagnostics, { desc = '[S]earch [D]iagnostics' })
    vim.keymap.set('n', '<leader>sr', builtin.resume, { desc = '[S]earch [R]esume' })
    vim.keymap.set('n', '<leader>s.', builtin.oldfiles, { desc = '[S]earch Recent Files ("." for repeat)' })
    vim.keymap.set('n', '<leader><leader>', builtin.buffers, { desc = '[ ] Find existing buffers' })

    vim.keymap.set('n', '<leader>/', function()
      builtin.current_buffer_fuzzy_find(require('telescope.themes').get_dropdown {
        winblend = 10,
        previewer = false,
      })
    end, { desc = '[/] Fuzzily search in current buffer' })

    vim.keymap.set('n', '<leader>s/', function()
      builtin.live_grep {
        grep_open_files = true,
        prompt_title = 'Live Grep in Open Files',
      }
    end, { desc = '[S]earch [/] in Open Files' })

    vim.keymap.set('n', '<leader>sn', function()
      builtin.find_files { cwd = vim.fn.stdpath 'config' }
    end, { desc = '[S]earch [N]eovim files' })

    -- ######## PROJECT / SCRIPT SWITCHER ##################################
    local home = os.getenv 'HOME'

    local function list_entries(path, want_dirs)
      local entries = {}
      local ok, files = pcall(vim.fn.readdir, path)
      if not ok then
        return entries
      end
      for _, name in ipairs(files) do
        local is_dir = vim.fn.isdirectory(path .. '/' .. name) == 1
        if not vim.startswith(name, '.') and is_dir == want_dirs then
          table.insert(entries, name)
        end
      end
      table.sort(entries)
      return entries
    end

    local function project_picker()
      local pickers = require 'telescope.pickers'
      local finders = require 'telescope.finders'
      local conf = require('telescope.config').values
      local actions = require 'telescope.actions'
      local action_state = require 'telescope.actions.state'
      local themes = require 'telescope.themes'

      local projects_dir = home .. '/projects'

      pickers.new(themes.get_dropdown(), {
        prompt_title = 'Projects',
        finder = finders.new_table { results = list_entries(projects_dir, true) },
        sorter = conf.generic_sorter {},
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if not selection then
              return
            end

            local project_path = projects_dir .. '/' .. selection[1]
            vim.cmd('cd ' .. vim.fn.fnameescape(project_path))

            local readme = project_path .. '/README.md'
            local pkg = project_path .. '/package.json'
            if vim.fn.filereadable(readme) == 1 then
              vim.cmd('edit ' .. vim.fn.fnameescape(readme))
            elseif vim.fn.filereadable(pkg) == 1 then
              vim.cmd('edit ' .. vim.fn.fnameescape(pkg))
            end
          end)
          return true
        end,
      }):find()
    end

    local function scripts_picker()
      local pickers = require 'telescope.pickers'
      local finders = require 'telescope.finders'
      local conf = require('telescope.config').values
      local actions = require 'telescope.actions'
      local action_state = require 'telescope.actions.state'
      local themes = require 'telescope.themes'

      local scripts_dir = home .. '/scripts'

      pickers.new(themes.get_dropdown(), {
        prompt_title = 'Scripts',
        finder = finders.new_table { results = list_entries(scripts_dir, false) },
        sorter = conf.generic_sorter {},
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if not selection then
              return
            end

            vim.cmd('cd ' .. vim.fn.fnameescape(scripts_dir))
            vim.cmd('edit ' .. vim.fn.fnameescape(scripts_dir .. '/' .. selection[1]))
          end)
          return true
        end,
      }):find()
    end

    vim.keymap.set('n', '<leader>sp', project_picker, { desc = '[S]earch [P]rojects' })
    vim.keymap.set('n', '<leader>sc', scripts_picker, { desc = '[S]earch s[C]ripts' })

    -- ######## CSV -> SQLITE TABLE ########################################
    local function csv_to_sqlite(path)
      if vim.fn.executable 'csv2sqlite' ~= 1 then
        vim.notify('csv2sqlite is not on your PATH', vim.log.levels.ERROR)
        return
      end

      local output = vim.trim(vim.fn.system { 'csv2sqlite', path })
      if vim.v.shell_error ~= 0 then
        vim.notify(output ~= '' and output or 'csv2sqlite failed', vim.log.levels.ERROR)
        return
      end

      vim.notify(output)
    end

    local function csv_picker()
      local pickers = require 'telescope.pickers'
      local finders = require 'telescope.finders'
      local conf = require('telescope.config').values
      local actions = require 'telescope.actions'
      local action_state = require 'telescope.actions.state'
      local themes = require 'telescope.themes'

      local downloads_dir = home .. '/Downloads'

      pickers.new(themes.get_dropdown(), {
        prompt_title = 'CSV -> sqlite table',
        finder = finders.new_oneshot_job({ 'rg', '--files', '--glob', '*.csv' }, { cwd = downloads_dir }),
        sorter = conf.generic_sorter {},
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if not selection then
              return
            end

            csv_to_sqlite(downloads_dir .. '/' .. selection[1])
          end)
          return true
        end,
      }):find()
    end

    vim.keymap.set('n', '<leader>sq', csv_picker, { desc = '[S]earch csv -> s[Q]lite table' })

    -- ######## DBUI SAVED QUERY FINDER ####################################
    local function saved_query_picker()
      local pickers = require 'telescope.pickers'
      local finders = require 'telescope.finders'
      local conf = require('telescope.config').values
      local actions = require 'telescope.actions'
      local action_state = require 'telescope.actions.state'
      local themes = require 'telescope.themes'

      local save_location = vim.fn.expand(vim.g.db_ui_save_location or '~/.local/share/db_ui')

      require('lazy').load { plugins = { 'vim-dadbod-ui' } }

      local connection_names = {}
      for _, c in ipairs(vim.fn['db_ui#connections_list']()) do
        connection_names[c.name] = true
      end

      local all_files = vim.fn.systemlist(
        string.format("cd %s && rg --files --glob '!connections.json'", vim.fn.shellescape(save_location))
      )
      local files = {}
      for _, rel in ipairs(all_files) do
        local top = rel:match '^([^/]+)'
        if top and connection_names[top] then
          table.insert(files, rel)
        end
      end

      pickers.new(themes.get_dropdown(), {
        prompt_title = 'DBUI Saved Queries',
        finder = finders.new_table { results = files },
        sorter = conf.generic_sorter {},
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if not selection then
              return
            end

            vim.cmd('edit ' .. vim.fn.fnameescape(save_location .. '/' .. selection[1]))
            vim.fn['db_ui#find_buffer_silent']()
          end)
          return true
        end,
      }):find()
    end

    vim.keymap.set('n', '<leader>sQ', saved_query_picker, { desc = '[S]earch saved [Q]ueries (all dbs)' })

    -- ######## DBUI OPEN (INCL. TEMPORARY) QUERY BUFFERS ##################
    local function dbui_buffer_picker()
      local pickers = require 'telescope.pickers'
      local finders = require 'telescope.finders'
      local conf = require('telescope.config').values
      local actions = require 'telescope.actions'
      local action_state = require 'telescope.actions.state'
      local themes = require 'telescope.themes'

      local entries = {}
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
          local ok, db_key = pcall(vim.api.nvim_buf_get_var, buf, 'dbui_db_key_name')
          if ok and db_key ~= '' then
            local name = vim.api.nvim_buf_get_name(buf)
            table.insert(entries, {
              bufnr = buf,
              db = db_key,
              name = name ~= '' and vim.fn.fnamemodify(name, ':t') or '[No Name]',
            })
          end
        end
      end

      if #entries == 0 then
        vim.notify('No open DBUI query/result buffers', vim.log.levels.INFO)
        return
      end

      pickers.new(themes.get_dropdown(), {
        prompt_title = 'DBUI Open Queries (incl. unsaved)',
        finder = finders.new_table {
          results = entries,
          entry_maker = function(entry)
            return {
              value = entry,
              display = string.format('%s  %s', entry.db, entry.name),
              ordinal = entry.db .. ' ' .. entry.name,
            }
          end,
        },
        sorter = conf.generic_sorter {},
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if not selection then
              return
            end

            vim.api.nvim_set_current_buf(selection.value.bufnr)
          end)
          return true
        end,
      }):find()
    end

    vim.keymap.set('n', '<leader>sB', dbui_buffer_picker, { desc = '[S]earch open db [B]uffers (incl. temp queries)' })

    -- ######## CONNECT TO DB (picker instead of clicking the tree) ########

    local function connect_to_db(db_name)
      vim.fn['db_ui#new_query_buffer'](db_name)
    end

    local function db_connect_picker()
      local pickers = require 'telescope.pickers'
      local finders = require 'telescope.finders'
      local conf = require('telescope.config').values
      local actions = require 'telescope.actions'
      local action_state = require 'telescope.actions.state'
      local themes = require 'telescope.themes'

      require('lazy').load { plugins = { 'vim-dadbod-ui' } }

      local connections = vim.fn['db_ui#connections_list']()
      if #connections == 0 then
        vim.notify('No DBUI connections found', vim.log.levels.ERROR)
        return
      end

      pickers.new(themes.get_dropdown(), {
        prompt_title = 'Connect to DB',
        finder = finders.new_table {
          results = connections,
          entry_maker = function(entry)
            return {
              value = entry,
              display = entry.name .. (entry.is_connected == 1 and '  (connected)' or ''),
              ordinal = entry.name,
            }
          end,
        },
        sorter = conf.generic_sorter {},
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if not selection then
              return
            end

            connect_to_db(selection.value.name)
          end)
          return true
        end,
      }):find()
    end

    vim.keymap.set('n', '<leader>sD', db_connect_picker, { desc = '[S]earch/connect to [D]b' })
    -- #################################################
  end,
}
