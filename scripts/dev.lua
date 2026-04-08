local root = vim.fn.getcwd()
local test_theme_root = root .. "/test/tokyonight.nvim"

vim.opt.rtp:prepend(root)
if vim.uv.fs_stat(test_theme_root) ~= nil then
	vim.opt.rtp:prepend(test_theme_root)
end
vim.opt.termguicolors = true

local function apply_colorscheme()
	pcall(vim.cmd.colorscheme, "tokyonight")
end

local function reload()
	for name in pairs(package.loaded) do
		if name == "cph" or name:match("^cph%.") then
			package.loaded[name] = nil
		end
	end

	return require("cph")
end

vim.g.mapleader = " "

require("cph.types")

---@type cph.SetupOpts
local config = {
	compile = {
		cpp = {
			compiler = "g++",
		},
		c = {
			compiler = "clang",
		},
	},
	run = {
		time_limit = 2000,
	},
	window = {
		dir = "floating",
		width = 100,
		height = 20,
	}
}

vim.api.nvim_create_user_command("DevReload", function()
	reload().setup(config)
	apply_colorscheme()
	vim.notify("cph reloaded")
end, {})

reload().setup(config)
apply_colorscheme()

vim.keymap.set("n", "<leader>r", "<cmd>DevReload<CR>")
vim.keymap.set("n", "<leader>o", "<cmd>ToggleCPH<CR>")
