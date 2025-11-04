local lazypath = vim.fn.stdpath 'data' .. '/lazy/lazy.nvim'

-- Disable swap files to prevent conflicts
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false

-- Buffer safety settings
vim.opt.hidden = true
vim.opt.autowrite = true
vim.opt.autowriteall = true

vim.g.loaded_netrwPlugin = 1
vim.g.loaded_netrw = 1
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.mouse = 'a'
vim.opt.showmode = false
vim.schedule(function()
  vim.opt.clipboard = 'unnamedplus'
end)
vim.opt.breakindent = true
vim.opt.undofile = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.signcolumn = 'yes'
vim.opt.updatetime = 250
vim.opt.timeoutlen = 300
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.list = true
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }
vim.opt.inccommand = 'split'
vim.opt.cursorline = true
vim.opt.background = 'dark'
vim.opt.scrolloff = 10
vim.g.have_nerd_font = true
vim.opt.rtp:prepend(lazypath)
-- views can only be fully collapsed with the global statusline
vim.opt.laststatus = 3
require 'sets.db'
