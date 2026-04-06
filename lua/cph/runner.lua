---@class CPHtest
---@field std_input string
---@field std_output string
---@field real_output string
---@field time_limit integer
---@field mem_limit integer


local M = {


}

---@type integer
local buf = nil
local win = nil


local lines = {}


---@type CPHtest[]
local tests = {}
---@type integer
local current = 1
---@type string
local file_path = ""
local in_create_ui = false

local group = vim.api.nvim_create_augroup("MyPluginTrackSource", { clear = true })

local function get_config()
	return require("cph.config").get()
end

local function get_tests_path()
	return vim.fn.fnamemodify(file_path, ":h")
		.. "/.cph/"
		.. vim.fn.fnamemodify(file_path, ":t")
		.. ".json"
end

local function cph_exits()
	return vim.uv.fs_stat(get_tests_path()) ~= nil
end

local function creat_test()
	local cph_dir = vim.fn.fnamemodify(get_tests_path(), ":h")
	vim.fn.mkdir(cph_dir, "p")
	vim.fn.writefile({ "[]" }, get_tests_path())
end

local function get_tests()
	local tests_path = get_tests_path()
	local content = table.concat(vim.fn.readfile(tests_path), "\n")
	tests = vim.json.decode(content)
end

local function set_creat_ui()
	in_create_ui = true
	lines = (function()
		local prompts = {
			"当前文件还没有创建 cph",
			"按下 c 创建",
		}
		local width = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or
			get_config().window.width
		local height = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_height(win) or #prompts
		local centered = {}
		local top_pad = math.max(1, math.floor(height * 0.2))

		for _ = 1, top_pad do
			centered[#centered + 1] = ""
		end

		for _, line in ipairs(prompts) do
			local left_pad = math.max(0, math.floor((width - vim.fn.strdisplaywidth(line)) / 2))
			centered[#centered + 1] = string.rep(" ", left_pad) .. line
		end

		return centered
	end)()
end


local function set_welcome()
	in_create_ui = false
	lines = (function()
		local art = {
			"  _____ ____  _   _ ",
			" / ____|  _ \\| | | |",
			"| |    | |_) | |_| |",
			"| |    |  __/|  _  |",
			"| |____| |   | | | |",
			" \\_____|_|   |_| |_|",
		}
		local width = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or
			get_config().window.width
		local height = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_height(win) or #art
		local centered = {}
		local top_pad = math.max(0, math.floor((height - #art) / 2))

		for _ = 1, top_pad do
			centered[#centered + 1] = ""
		end

		for _, line in ipairs(art) do
			local left_pad = math.max(0, math.floor((width - vim.fn.strdisplaywidth(line)) / 2))
			centered[#centered + 1] = string.rep(" ", left_pad) .. line
		end

		return centered
	end)()
end

local function build_lines()
	local config = get_config()

	local type = vim.uv.fs_stat(file_path)

	if not type or type.type == "directory" then
		set_welcome()
	elseif not cph_exits() then
		set_creat_ui()
	else
		in_create_ui = false
		get_tests()
		lines = {
			file_path,
			vim.fn.fnamemodify(file_path, ":f"),
			vim.fn.fnamemodify(file_path, ":e"),
			config.compile["cpp"].compiler
		}
	end
end


local function ensure_buf()
	if buf and vim.api.nvim_buf_is_valid(buf) then
		return buf
	end

	buf = vim.api.nvim_create_buf(false, true)

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "cph-tree"

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = buf, silent = true })

	vim.keymap.set("n", "<CR>", function()
		local line = vim.api.nvim_get_current_line()
		vim.notify("selected: " .. line)
	end, { buffer = buf, silent = true })

	vim.keymap.set("n", "c", function()
		if in_create_ui then
			creat_test()
			M.refresh()
		end
	end, { buffer = buf, silent = true })
end

function M.render()
	ensure_buf()

	vim.bo[buf].modifiable = true
	build_lines()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
end

function M.refresh()
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_set_width(win, get_config().window.width)
		M.render()
	end
end

function M.open()
	local config = get_config();
	file_path = vim.api.nvim_buf_get_name(0)
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_set_current_win(win)
		M.refresh()
		return
	end

	ensure_buf()

	win = vim.api.nvim_open_win(buf, true, {
		split = config.window.dir,
		win = -1,
	})

	vim.api.nvim_win_set_width(win, get_config().window.width)

	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].foldcolumn = "0"
	vim.wo[win].wrap = false
	vim.wo[win].cursorline = true
	vim.wo[win].winfixwidth = true
	vim.wo[win].statuscolumn = ""
	vim.wo[win].fillchars = "eob: "

	M.render()
end

function M.close()
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	end
	win = nil
end

function M.toggle()
	if win and vim.api.nvim_win_is_valid(win) then
		M.close()
	else
		M.open()
	end
end

function M.next_test()
	if current < #tests then
		current = current + 1
	end
end

function M.last_test()
	if current > 2 then
		current = current - 1
	end
end

function M.setup()
	vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "TabEnter" }, {
		group = group,
		callback = function(args)
			if buf ~= args.buf then
				file_path = vim.api.nvim_buf_get_name(args.buf)
				M.refresh()
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
		group = group,
		callback = function(args)
			if vim.api.nvim_buf_get_name(args.buf) == file_path then
				local win_ = vim.api.nvim_get_current_win()
				file_path = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win_))
				M.refresh()
			end
		end,
	})
end

return M
