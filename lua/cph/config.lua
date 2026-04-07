local M = {}


---@class cphRunOpts
---@field time_limit integer
---@field memory_limit integer

---@class cphWinOpts
---@field width integer
---@field dir string

---@class cphCompileOpt
---@field compiler string
---@field arg? string

---@class cphOpts
---@field window cphWinOpts
---@field compile table<string, cphCompileOpt>
---@field run? cphRunOpts

---@type cphOpts
local default = {
	window = {
		width = 50,
		dir = "left",
	},
	compile = {
		cpp = {
			compiler = "clang++",
			arg = "-O2"
		},
	},
	run = {
		time_limit = 2000,
		memory_limit = 2048,
	}
}

---@type cphOpts
M.opts = vim.deepcopy(default)

---@param opts? cphOpts
function M.setup(opts)
	opts = opts or {}


	local options = vim.tbl_deep_extend("force", vim.deepcopy(default), opts)

	if opts.compile ~= nil then
		options.compile = opts.compile
	end

	for filetype, item in pairs(options.compile) do
		if type(filetype) ~= "string" then
			error("cph.setup(): compile keys must be filetype strings")
		end

		vim.validate({
			compiler = { item.compiler, "string" },
			arg = { item.arg, "string", true },
		})
	end

	vim.validate({
		window = { options.window, "table", true },
		compile = { options.compile, "table", true },
		run = { options.run, "table", true }
	})

	vim.validate({
		timeout = { options.run.timeout, "number" },
	})

	M.opts = options
end

function M.get()
	return M.opts
end

return M
