local M = {}

local valid_window_dirs = {
	left = true,
	right = true,
	above = true,
	below = true,
	floating = true,
}

---@type cph.Config
local default_opts = {
	window = {
		width = 100,
		height = 80,
		dir = "left",
	},
	compile = {
		cpp = {
			compiler = "clang++",
			arg = "-O2",
		},
	},
	run = {
		time_limit = 2000,
		memory_limit = 2048,
	},
}

---@type cph.Config
M.opts = vim.deepcopy(default_opts)

---@type cph.Config
M.defaults = vim.deepcopy(default_opts)

---@param value unknown
---@param name string
local function validate_positive_integer(value, name)
	vim.validate({
		[name] = { value, "number" },
	})

	if value < 1 or math.floor(value) ~= value then
		error(string.format("cph.setup(): %s must be a positive integer", name))
	end
end

---@param compile table<string, cph.CompileRule>
local function validate_compile(compile)
	vim.validate({
		compile = { compile, "table" },
	})

	for filetype, item in pairs(compile) do
		if type(filetype) ~= "string" or filetype == "" then
			error("cph.setup(): compile keys must be non-empty filetype strings")
		end

		if type(item) ~= "table" then
			error(string.format("cph.setup(): compile.%s must be a table", filetype))
		end

		vim.validate({
			compiler = { item.compiler, "string" },
			arg = { item.arg, "string", true },
		})
	end
end

---@param config cph.Config
local function validate_config(config)
	vim.validate({
		window = { config.window, "table" },
		compile = { config.compile, "table" },
		run = { config.run, "table" },
	})

	validate_positive_integer(config.window.width, "window.width")
	validate_positive_integer(config.window.height, "window.height")

	if not valid_window_dirs[config.window.dir] then
		error("cph.setup(): window.dir must be one of left, right, above, below, floating")
	end

	validate_compile(config.compile)
	validate_positive_integer(config.run.time_limit, "run.time_limit")
	validate_positive_integer(config.run.memory_limit, "run.memory_limit")
end

---@param opts? cph.SetupOpts
function M.setup(opts)
	opts = opts or {}

	local merged = vim.tbl_deep_extend("force", vim.deepcopy(default_opts), opts)
	if opts.compile ~= nil then
		merged.compile = vim.deepcopy(opts.compile)
	end

	validate_config(merged)
	M.opts = merged
end

---@return cph.Config
function M.get()
	return M.opts
end

return M
