-- Cosmetic grid rendering for vim-dadbod-ui's `dbout` result buffers.
-- Only decorates via extmarks (conceal + highlight) -- never edits buffer
-- text, so yank_header/get_cell_value/jump_to_foreign_table/foldexpr/
-- export_csv (all of which scan the raw +/-/| characters) keep working.
local M = {}

local ns = vim.api.nvim_create_namespace 'dbui_grid'

local function is_border(line)
  return line ~= nil and line:match '^%+[%+%-]*%+$' ~= nil
end

-- Scans mysql-style `+---+` blocks: top border, header, header-sep border,
-- data rows, bottom border. Not applicable to postgres/sqlserver output
-- (no closing border line), which this simply won't match on.
local function find_blocks(lines)
  local blocks = {}
  local i = 1
  local n = #lines
  while i <= n do
    if is_border(lines[i]) then
      local top = i
      local header_line = i + 1
      if header_line <= n and not is_border(lines[header_line]) then
        local headersep = header_line + 1
        if headersep <= n and is_border(lines[headersep]) then
          local j = headersep + 1
          while j <= n and not is_border(lines[j]) do
            j = j + 1
          end
          if j <= n then
            table.insert(blocks, {
              top = top,
              header_line = header_line,
              headersep = headersep,
              data_start = headersep + 1,
              data_end = j - 1,
              bottom = j,
            })
            i = j
          end
        end
      end
    end
    i = i + 1
  end
  return blocks
end

local function border_char(ch, pos, kind)
  if ch == '-' then
    return '─'
  end
  if ch ~= '+' then
    return nil
  end
  local corners = {
    top = { left = '┌', right = '┐', mid = '┬' },
    mid = { left = '├', right = '┤', mid = '┼' },
    bottom = { left = '└', right = '┘', mid = '┴' },
  }
  return corners[kind][pos]
end

local function conceal_border_line(bufnr, lnum0, line, kind)
  local len = #line
  for col = 1, len do
    local pos = (col == 1) and 'left' or (col == len and 'right' or 'mid')
    local rep = border_char(line:sub(col, col), pos, kind)
    if rep then
      vim.api.nvim_buf_set_extmark(bufnr, ns, lnum0, col - 1, { end_col = col, conceal = rep })
    end
  end
end

local function conceal_pipes(bufnr, lnum0, line)
  for col = 1, #line do
    if line:sub(col, col) == '|' then
      vim.api.nvim_buf_set_extmark(bufnr, ns, lnum0, col - 1, { end_col = col, conceal = '│' })
    end
  end
end

local function highlight_line(bufnr, lnum0, len, hl_group)
  vim.api.nvim_buf_set_extmark(bufnr, ns, lnum0, 0, { end_row = lnum0, end_col = len, hl_group = hl_group })
end

function M.render(bufnr)
  bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= 'dbout' then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks = find_blocks(lines)
  vim.b[bufnr].dbui_grid_blocks = blocks

  for _, b in ipairs(blocks) do
    conceal_border_line(bufnr, b.top - 1, lines[b.top], 'top')
    conceal_border_line(bufnr, b.headersep - 1, lines[b.headersep], 'mid')
    conceal_border_line(bufnr, b.bottom - 1, lines[b.bottom], 'bottom')

    conceal_pipes(bufnr, b.header_line - 1, lines[b.header_line])
    highlight_line(bufnr, b.header_line - 1, #lines[b.header_line], 'DbUiGridHeader')

    for row = b.data_start, b.data_end do
      conceal_pipes(bufnr, row - 1, lines[row])
      if (row - b.data_start) % 2 == 1 then
        highlight_line(bufnr, row - 1, #lines[row], 'DbUiGridRowAlt')
      end
    end
  end
end

-- Sticky header: once a block's header row scrolls above the top of the
-- window, show it in the winbar instead of the connection status. Built as
-- a statusline "smart eval" string (embedded %#Group# switches), and
-- padded to match the window's number/signcolumn/foldcolumn gutter width
-- so it lines up with the real header row underneath.
--
-- With 'nowrap' set on dbout buffers, the table can be scrolled
-- horizontally ('leftcol' > 0). The header text is sliced at the same
-- leftcol so it always shows exactly the columns currently visible below
-- it, instead of always showing the unscrolled left edge of the header.
--
-- Computed for an explicit `win` via nvim_win_call rather than trusting
-- "current window" context, and written directly into that window's
-- 'winbar' option (M.refresh_winbar) instead of being wired up as a lazy
-- %{luaeval(...)} expression -- Neovim only re-runs those when its own
-- heuristics decide the statusline is dirty, which pure horizontal/vertical
-- scrolling doesn't reliably trigger. Setting the option ourselves on every
-- relevant event is the only way to guarantee it's actually current.
local function compute(win)
  local bufnr = vim.api.nvim_win_get_buf(win)

  local blocks = vim.b[bufnr].dbui_grid_blocks
  if blocks then
    local topline, leftcol = unpack(vim.api.nvim_win_call(win, function()
      return { vim.fn.line 'w0', vim.fn.winsaveview().leftcol }
    end))
    for _, b in ipairs(blocks) do
      if topline > b.header_line and topline <= b.bottom then
        local ok, header = pcall(vim.api.nvim_buf_get_lines, bufnr, b.header_line - 1, b.header_line, false)
        if ok and header[1] then
          local info = vim.fn.getwininfo(win)[1]
          local textoff = info and info.textoff or 0
          local pad = string.rep(' ', textoff)
          local textwidth = vim.api.nvim_win_get_width(win) - textoff
          -- Cap to the window's visible text width *before* handing this to
          -- 'winbar'. Without this, an oversized string just gets truncated
          -- by Vim's own statusline renderer instead -- which, absent an
          -- explicit '%<', truncates from the left and inserts its own '<'
          -- marker, undoing the leftcol slice above and showing an
          -- unrelated chunk of the header.
          local visible = header[1]:sub(leftcol + 1, leftcol + textwidth)
          return pad .. '%#DbUiGridHeader#' .. visible:gsub('|', '│') .. '%*'
        end
      end
    end
  end
  return '%#DbConnectedWinbar#' .. vim.fn['db_ui#statusline']() .. '%*'
end

function M.refresh_winbar(win)
  win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[bufnr].filetype
  if ft ~= 'dbout' and vim.fn.getbufvar(bufnr, 'db') == '' then
    return
  end
  vim.wo[win].winbar = compute(win)
end

return M
