local M = {}

local STATUS_PASS = "pass"
local STATUS_FAILED = "failed"

local function emit(callback, ...)
	if not callback then
		return
	end

	local args = { ... }
	vim.schedule(function()
		callback(unpack(args))
	end)
end

local function normalize_text(text)
	text = text or ""
	text = text:gsub("\r\n", "\n")
	text = text:gsub("\r", "\n")
	return text
end

local function normalize_expected_text(text)
	local normalized = {}

	for _, line in ipairs(vim.split(normalize_text(text), "\n", {
		plain = true,
		trimempty = false,
	})) do
		line = line:gsub("%s+", " ")
		line = vim.trim(line)

		if line ~= "" then
			normalized[#normalized + 1] = line
		end
	end

	return table.concat(normalized, "\n")
end

local function split_args(raw)
	if type(raw) ~= "string" or raw == "" then
		return {}
	end

	return vim.split(raw, "%s+", {
		trimempty = true,
	})
end

local function get_compile_config(file_path)
	local config = require("cph.config").get()
	local extension = vim.fn.fnamemodify(file_path, ":e")
	local item = config.compile[extension]

	if item then
		return item
	end

	local detected = vim.filetype.match({
		filename = file_path,
	}) or ""

	if detected ~= "" then
		return config.compile[detected]
	end
end

local function build_binary_path(file_path)
	local stem = vim.fn.fnamemodify(file_path, ":t:r")
	return vim.fn.tempname() .. "-" .. stem
end

local function delete_file(path)
	if not path or path == "" then
		return
	end

	pcall(vim.uv.fs_unlink, path)
end

local function compile_source(file_path, output_path, callback)
	local compile_opt = get_compile_config(file_path)
	if not compile_opt then
		emit(callback, {
			ok = false,
			error = string.format("No compiler configured for %s", vim.fn.fnamemodify(file_path, ":e")),
		})
		return
	end

	local command = { compile_opt.compiler }
	vim.list_extend(command, split_args(compile_opt.arg))
	command[#command + 1] = file_path
	command[#command + 1] = "-o"
	command[#command + 1] = output_path

	vim.system(command, {
		text = true,
		cwd = vim.fn.fnamemodify(file_path, ":h"),
	}, function(result)
		if result.code == 0 then
			emit(callback, {
				ok = true,
			})
			return
		end

		local error_message = normalize_text(result.stderr)
		if error_message == "" then
			error_message = normalize_text(result.stdout)
		end
		if error_message == "" then
			error_message = "Compilation failed"
		end

		emit(callback, {
			ok = false,
			error = error_message,
		})
	end)
end

local function run_single_test(binary_path, test, callback)
	local start = vim.uv.hrtime()
	local command = {
		binary_path,
	}

	vim.system(command, {
		text = true,
		stdin = test.std_input or "",
		cwd = vim.fn.fnamemodify(binary_path, ":h"),
		timeout = tonumber(test.time_limit) or nil,
	}, function(result)
		local runtime_ms = math.floor((vim.uv.hrtime() - start) / 1000000 + 0.5)
		local stdout = normalize_text(result.stdout)
		local normalized_stdout = normalize_expected_text(stdout)
		local stderr = normalize_text(result.stderr)
		local real_output = stdout ~= "" and normalized_stdout or stderr

		if result.code == 124 and real_output == "" then
			real_output = "Time limit exceeded"
		end

		emit(callback, {
			real_output = real_output,
			passed = result.code == 0
				and normalized_stdout == normalize_expected_text(test.std_output)
				and STATUS_PASS
				or STATUS_FAILED,
			runtime_ms = runtime_ms,
			exit_code = result.code,
			signal = result.signal,
		})
	end)
end

---@param opts { file_path: string, tests: table[], on_compile_error?: fun(message: string), on_test_start?: fun(index: integer), on_test_done?: fun(index: integer, result: table), on_done?: fun() }
function M.run(opts)
	local binary_path = build_binary_path(opts.file_path)

	compile_source(opts.file_path, binary_path, function(result)
		if not result.ok then
			delete_file(binary_path)
			emit(opts.on_compile_error, result.error)
			emit(opts.on_done)
			return
		end

		local function run_next(position)
			local item = opts.tests[position]
			if not item then
				delete_file(binary_path)
				emit(opts.on_done)
				return
			end

			emit(opts.on_test_start, item.index)
			run_single_test(binary_path, item.test, function(test_result)
				emit(opts.on_test_done, item.index, test_result)
				run_next(position + 1)
			end)
		end

		run_next(1)
	end)
end

return M
