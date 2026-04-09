---@class CPHtest
---@field std_input string
---@field std_output string
---@field real_output string
---@field time_limit integer
---@field mem_limit integer
---@field passed string|nil
---@field selected boolean
---@field collapsed boolean
---@field runtime_ms integer|nil

local executor = require("cph.executor")

local M = {}

local STATUS_COMPILING = "compiling"
local STATUS_RUNNING = "running"
local STATUS_PASS = "pass"
local STATUS_FAILED = "failed"
local VALID_STATUSES = {
	[STATUS_COMPILING] = true,
	[STATUS_RUNNING] = true,
	[STATUS_PASS] = true,
	[STATUS_FAILED] = true,
}

local highlight_ns = vim.api.nvim_create_namespace("cph-runner-highlight")
local decor_ns = vim.api.nvim_create_namespace("cph-runner-decor")
local popup_group = vim.api.nvim_create_augroup("CphRunnerPopup", { clear = true })
local group = vim.api.nvim_create_augroup("CphTrackSource", { clear = true })

---@type integer?
local buf = nil
---@type integer?
local win = nil
---@type integer?
local edit_buf = nil
---@type integer?
local edit_win = nil
local edit_sync_pending = false

local lines = {}
local line_meta = {}
local test_layouts = {}
local selected_test_indexes = {}
local selected_count = 0

---@type CPHtest[]
local tests = {}

---@type integer
local current = 1
---@type string
local file_path = ""
---@type string
local ui_file_path = ""
local in_create_ui = false
local in_tests_ui = false
local run_active = false
---@type string?
local active_run_file = nil
---@type integer?
local active_run_test_index = nil

local function get_config()
	return require("cph.config").get()
end

local function get_tests_path(target_file_path)
	target_file_path = target_file_path or file_path

	return vim.fn.fnamemodify(target_file_path, ":h")
		.. "/.cph/"
		.. vim.fn.fnamemodify(target_file_path, ":t")
		.. ".json"
end

local function tests_file_exists(target_file_path)
	return vim.uv.fs_stat(get_tests_path(target_file_path)) ~= nil
end

---@param status any
---@return string|nil
local function normalize_status(status)
	if status == true then
		return STATUS_PASS
	end

	if status == false then
		return STATUS_FAILED
	end

	if type(status) == "string" and VALID_STATUSES[status] then
		return status
	end

	return nil
end

---@param test table
---@return CPHtest
local function normalize_test(test)
	local config = get_config()
	test.real_output = test.real_output or ""
	test.passed = normalize_status(test.passed)
	test.selected = test.selected or false
	test.collapsed = test.collapsed or false
	test.time_limit = test.time_limit or config.run.time_limit
	test.mem_limit = test.mem_limit or config.run.memory_limit
	test.runtime_ms = test.runtime_ms
	return test
end

local function read_tests(target_file_path)
	local tests_path = get_tests_path(target_file_path)
	if vim.uv.fs_stat(tests_path) == nil then
		return {}
	end

	local ok, content = pcall(vim.fn.readfile, tests_path)
	if not ok then
		return {}
	end

	local ok_decode, decoded = pcall(vim.json.decode, table.concat(content, "\n"))
	if not ok_decode then
		return {}
	end
	decoded = decoded or {}
	local loaded = {}

	for _, test in ipairs(decoded) do
		loaded[#loaded + 1] = normalize_test(test)
	end

	return loaded
end

local function write_tests_for(target_file_path, items)
	local tests_path = get_tests_path(target_file_path)
	local cph_dir = vim.fn.fnamemodify(tests_path, ":h")
	local persisted = {}

	for _, test in ipairs(items) do
		persisted[#persisted + 1] = {
			std_input = test.std_input,
			std_output = test.std_output,
			time_limit = test.time_limit,
			mem_limit = test.mem_limit,
			selected = test.selected,
			collapsed = test.collapsed,
		}
	end

	vim.fn.mkdir(cph_dir, "p")
	vim.fn.writefile({ vim.json.encode(persisted) }, tests_path)
end

local function write_tests()
	write_tests_for(file_path, tests)
end

local function rebuild_selected_state()
	selected_count = 0
	selected_test_indexes = {}

	for i, test in ipairs(tests) do
		if test.selected then
			selected_count = selected_count + 1
			selected_test_indexes[#selected_test_indexes + 1] = i
		end
	end
end

local function is_file_running(target_file_path)
	target_file_path = target_file_path or file_path
	return run_active and active_run_file == target_file_path
end

local function ensure_run_idle(target_file_path)
	if is_file_running(target_file_path) then
		vim.notify("cph: test run in progress", vim.log.levels.WARN)
		return false
	end

	return true
end

local function create_test_template()
	local config = get_config()

	return {
		std_input = "",
		std_output = "",
		real_output = "",
		time_limit = config.run.time_limit,
		mem_limit = config.run.memory_limit,
		passed = nil,
		selected = false,
		collapsed = false,
		runtime_ms = nil,
	}
end

local function create_test_set()
	tests = {
		create_test_template(),
	}
	selected_count = 0
	selected_test_indexes = {}
	write_tests()
end

local function remove_test(index)
	table.remove(tests, index)
	rebuild_selected_state()
end

local function add_test()
	if not ensure_run_idle() then
		return
	end

	tests[#tests + 1] = create_test_template()
	write_tests()
	M.refresh()
end

local function escape_statusline(text)
	return text:gsub("%%", "%%%%")
end

local function split_text(text)
	if text == "" then
		return { "" }
	end

	return vim.split(text, "\n", {
		plain = true,
		trimempty = false,
	})
end

local function normalize_expected_text(text)
	text = text or ""
	text = text:gsub("\r\n", "\n")
	text = text:gsub("\r", "\n")

	local normalized = {}
	for _, line in ipairs(split_text(text)) do
		line = line:gsub("%s+", " ")
		line = vim.trim(line)

		if line ~= "" then
			normalized[#normalized + 1] = line
		end
	end

	return table.concat(normalized, "\n")
end

local function join_lines(input_lines)
	return table.concat(input_lines, "\n")
end

local function push_line(text, meta)
	lines[#lines + 1] = text
	line_meta[#lines] = meta or {}
end

local function push_test_line(index, text, meta)
	meta = meta or {}
	meta.test_index = index
	push_line(text, meta)
end

local function trim_display_text(text, max_width)
	max_width = math.max(1, max_width)
	if vim.fn.strdisplaywidth(text) <= max_width then
		return text
	end

	local trimmed = text
	while trimmed ~= "" and vim.fn.strdisplaywidth(trimmed .. "...") > max_width do
		local length = vim.fn.strchars(trimmed)
		trimmed = vim.fn.strcharpart(trimmed, 0, math.max(0, length - 1))
	end

	if trimmed == "" then
		return "..."
	end

	return trimmed .. "..."
end

local function build_preview(label, text, width)
	local preview = (text or ""):gsub("\n", " \\n "):gsub("\t", "  "):gsub("^%s+", ""):gsub("%s+$", "")
	local line_count = #split_text(text or "")

	if preview == "" then
		preview = "<empty>"
	end

	local suffix = line_count > 1 and string.format(" (%d lines)", line_count) or ""
	local prefix = label .. ": "
	local preview_width = width - vim.fn.strdisplaywidth(prefix) - vim.fn.strdisplaywidth(suffix) - 1
	preview = trim_display_text(preview, math.max(12, preview_width))

	return prefix .. preview .. suffix
end

local function append_labeled_block(index, label, text)
	push_test_line(index, label .. ":", { kind = "label" })

	local content_lines = split_text(text or "")
	if #content_lines == 1 and content_lines[1] == "" then
		push_test_line(index, "  <empty>", { kind = "empty" })
		return
	end

	for _, line in ipairs(content_lines) do
		push_test_line(index, "  " .. line, { kind = "content" })
	end
end

local function set_winbar(content)
	if win and vim.api.nvim_win_is_valid(win) then
		vim.wo[win].winbar = content
	end
end

local function clear_winbar()
	set_winbar("")
end

local function set_tests_winbar()
	local title = "File: " .. vim.fn.fnamemodify(file_path, ":t")
	local passed = 0
	for _, test in ipairs(tests) do
		if test.passed == STATUS_PASS then
			passed = passed + 1
		end
	end
	local ratio = string.format("%d/%d", passed, #tests)
	local summary = ratio
	local summary_hl = "CphSelected"

	if is_file_running() then
		if active_run_test_index then
			summary = string.format("running on test %d", active_run_test_index)
			summary_hl = "CphRunning"
		else
			summary = "compiling"
			summary_hl = "CphCompiling"
		end
	end

	set_winbar(
		"%#CphTitle#"
			.. escape_statusline(title)
			.. "%="
			.. "%#"
			.. summary_hl
			.. "#"
			.. escape_statusline(summary)
			.. "%*"
	)
end

local function close_edit_popup()
	if edit_win and vim.api.nvim_win_is_valid(edit_win) then
		vim.api.nvim_win_close(edit_win, true)
	end

	edit_win = nil
	edit_buf = nil
	edit_sync_pending = false
end

local function sync_edit_popup(field)
	if not (edit_buf and vim.api.nvim_buf_is_valid(edit_buf)) then
		return
	end

	if not ensure_run_idle() then
		return
	end

	local test = tests[current]
	if not test then
		close_edit_popup()
		return
	end

	local value = join_lines(vim.api.nvim_buf_get_lines(edit_buf, 0, -1, false))
	if field == "std_output" then
		value = normalize_expected_text(value)
		if edit_buf and vim.api.nvim_buf_is_valid(edit_buf) then
			local normalized_lines = split_text(value)
			local current_lines = vim.api.nvim_buf_get_lines(edit_buf, 0, -1, false)
			if not vim.deep_equal(current_lines, normalized_lines) then
				edit_sync_pending = true
				vim.bo[edit_buf].modifiable = true
				vim.api.nvim_buf_set_lines(edit_buf, 0, -1, false, normalized_lines)
				edit_sync_pending = false
			end
		end
	end

	test[field] = value
	write_tests()
	M.refresh()
	if edit_win and vim.api.nvim_win_is_valid(edit_win) then
		vim.api.nvim_set_current_win(edit_win)
	end
end

local function open_edit_popup(field, title)
	if not in_tests_ui or #tests == 0 then
		return
	end

	if not ensure_run_idle() then
		return
	end

	local test = tests[current]
	if not test then
		return
	end

	close_edit_popup()

	local content_lines = split_text(test[field] or "")
	local width = math.max(40, math.min(vim.o.columns - 8, 80))
	local height = math.max(8, math.min(vim.o.lines - 6, #content_lines + 2))

	edit_buf = vim.api.nvim_create_buf(false, true)
	vim.b[edit_buf].cph_popup = true
	vim.bo[edit_buf].buftype = "nofile"
	vim.bo[edit_buf].bufhidden = "wipe"
	vim.bo[edit_buf].swapfile = false
	vim.bo[edit_buf].filetype = "text"

	vim.api.nvim_buf_set_lines(edit_buf, 0, -1, false, content_lines)

	edit_win = vim.api.nvim_open_win(edit_buf, true, {
		relative = "editor",
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " ",
		title_pos = "center",
	})

	vim.wo[edit_win].wrap = true
	vim.wo[edit_win].linebreak = true
	vim.wo[edit_win].breakindent = true
	vim.wo[edit_win].showbreak = "  "
	vim.wo[edit_win].number = false
	vim.wo[edit_win].relativenumber = false
	vim.wo[edit_win].signcolumn = "no"
	vim.wo[edit_win].list = false

	vim.keymap.set("n", "q", close_edit_popup, { buffer = edit_buf, silent = true })
	vim.keymap.set("n", "<Esc>", close_edit_popup, { buffer = edit_buf, silent = true })

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = popup_group,
		buffer = edit_buf,
		once = true,
		callback = function()
			edit_win = nil
			edit_buf = nil
		end,
	})

	vim.api.nvim_buf_attach(edit_buf, false, {
		on_lines = function()
			if edit_sync_pending then
				return
			end

			edit_sync_pending = true
			vim.schedule(function()
				edit_sync_pending = false
				sync_edit_popup(field)
			end)
		end,
	})

	vim.cmd("startinsert")
end

local function format_status(test)
	if test.passed ~= nil then
		return test.passed
	end

	return "-"
end

local function format_runtime(test)
	if test.runtime_ms == nil then
		return "-"
	end

	return string.format("%d ms", test.runtime_ms)
end

local function apply_decorations()
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end

	vim.api.nvim_buf_clear_namespace(buf, decor_ns, 0, -1)

	if #lines == 0 then
		return
	end

	for i, line in ipairs(lines) do
		local meta = line_meta[i] or {}
		local row = i - 1

		local function add_decoration(hl_group, col_start, col_end, priority)
			col_start = math.max(0, col_start)
			if col_end < 0 then
				col_end = #line
			end
			col_end = math.max(col_start, math.min(col_end, #line))

			vim.api.nvim_buf_set_extmark(buf, decor_ns, row, col_start, {
				end_col = col_end,
				hl_group = hl_group,
				priority = priority,
			})
		end

		if meta.kind == "heading" then
			add_decoration("CphHeading", 0, -1)
			add_decoration("CphAccent", 0, math.min(3, #line), 200)

			local selected_start = line:find("%[selected%]")
			if selected_start then
				local start_col = selected_start - 1
				add_decoration("CphSelected", start_col, start_col + #" [selected]" - 1, 200)
			end

			if meta.status_col then
				local group_name = "CphMuted"
				if meta.status == STATUS_COMPILING then
					group_name = "CphCompiling"
				elseif meta.status == STATUS_RUNNING then
					group_name = "CphRunning"
				elseif meta.status == STATUS_PASS then
					group_name = "CphPass"
				elseif meta.status == STATUS_FAILED then
					group_name = "CphFailed"
				end

				add_decoration(group_name, meta.status_col, meta.status_end_col or -1, 150)
			end
		elseif meta.kind == "metric" then
			local prefix_end = line:find(": ", 1, true)
			if prefix_end then
				add_decoration("CphLabel", 0, prefix_end + 1)
				add_decoration("CphMetric", prefix_end + 1, -1, 120)
			end
		elseif meta.kind == "preview" then
			local prefix_end = line:find(": ", 1, true)
			if prefix_end then
				add_decoration("CphLabel", 0, prefix_end + 1)
				add_decoration("CphMuted", prefix_end + 1, -1, 120)
			end
		elseif meta.kind == "label" then
			add_decoration("CphLabel", 0, -1)
		elseif meta.kind == "empty" then
			add_decoration("CphMuted", 0, -1)
		elseif not in_tests_ui and line ~= "" then
			add_decoration("CphMuted", 0, -1)
		end
	end
end

local function refresh_tests_ui()
	rebuild_selected_state()

	if #tests == 0 then
		current = 1
	else
		current = math.max(1, math.min(current, #tests))
	end

	local width = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win)
		or get_config().window.width

	lines = {}
	line_meta = {}
	test_layouts = {}

	for i, test in ipairs(tests) do
		local start_row = #lines + 1
		local heading = (test.collapsed and "[+]" or "[-]") .. " Test " .. tostring(i)
		if test.selected then
			heading = heading .. " [selected]"
		end
		local status_text = format_status(test)
		local status_gap = math.max(1, width - vim.fn.strdisplaywidth(heading) - vim.fn.strdisplaywidth(status_text))
		local heading_line = heading .. string.rep(" ", status_gap) .. status_text

		push_test_line(i, heading_line, {
			kind = "heading",
			selected = test.selected,
			collapsed = test.collapsed,
			status = test.passed,
			status_col = #heading + status_gap,
			status_end_col = #heading_line,
		})
		push_test_line(i, "time: " .. format_runtime(test), {
			kind = "metric",
		})

		if test.collapsed then
			push_test_line(i, build_preview("  input", test.std_input, width), { kind = "preview" })
			push_test_line(i, build_preview("  expected", test.std_output, width), { kind = "preview" })

			if test.real_output ~= "" or test.passed ~= nil then
				push_test_line(i, build_preview("  output", test.real_output, width), { kind = "preview" })
			end
		else
			append_labeled_block(i, "  input", test.std_input)
			append_labeled_block(i, "  expected", test.std_output)

			if test.real_output ~= "" or test.passed ~= nil then
				append_labeled_block(i, "  output", test.real_output)
			end
		end

		if i < #tests then
			push_test_line(i, "", { kind = "separator" })
		end

		test_layouts[i] = {
			start_row = start_row,
			header_row = start_row,
			end_row = #lines,
		}
	end

	set_tests_winbar()
end

local function update_current_test_highlight()
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end

	vim.api.nvim_buf_clear_namespace(buf, highlight_ns, 0, -1)
	if not in_tests_ui or #tests == 0 then
		return
	end

	local layout = test_layouts[current]
	if not layout then
		return
	end

	vim.api.nvim_buf_set_extmark(buf, highlight_ns, layout.header_row - 1, 0, {
		line_hl_group = "CphCurrentTest",
		priority = 250,
	})
end

local function move_cursor_to_row(row, preferred_topline)
	if not (win and vim.api.nvim_win_is_valid(win)) then
		return
	end

	pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
	pcall(vim.api.nvim_win_call, win, function()
		local height = math.max(1, vim.api.nvim_win_get_height(win))
		local view = vim.fn.winsaveview()
		local topline = preferred_topline or view.topline
		local bottomline = topline + height - 1

		if row < topline then
			topline = math.max(1, row - 1)
		elseif row > bottomline then
			topline = math.max(1, row - height + 1)
		end

		vim.fn.winrestview({
			lnum = row,
			col = 0,
			topline = topline,
			leftcol = 0,
		})
	end)
end

local function capture_cursor_state()
	if not (win and vim.api.nvim_win_is_valid(win)) then
		return nil
	end
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return nil
	end

	local cursor = vim.api.nvim_win_get_cursor(win)
	local row = cursor[1]
	local meta = line_meta[row] or {}
	local state = {
		test_index = meta.test_index or current,
		offset = 0,
		view = vim.api.nvim_win_call(win, function()
			return vim.fn.winsaveview()
		end),
	}
	local layout = meta.test_index and test_layouts[meta.test_index]

	if layout then
		state.offset = row - layout.start_row
	end

	return state
end

local function restore_cursor_state(state)
	if not in_tests_ui or #tests == 0 then
		update_current_test_highlight()
		return
	end

	if state and state.test_index then
		current = math.max(1, math.min(state.test_index, #tests))
	end

	local layout = test_layouts[current]
	if not layout then
		update_current_test_highlight()
		return
	end

	local row = layout.header_row
	if state and tests[current] and not tests[current].collapsed then
		row = layout.start_row + (state.offset or 0)
		row = math.max(layout.start_row, math.min(row, layout.end_row))
	end

	local topline = state and state.view and state.view.topline or nil
	move_cursor_to_row(row, topline)
	set_tests_winbar()
	update_current_test_highlight()
end

local function sync_current_from_cursor()
	if not in_tests_ui or #tests == 0 then
		update_current_test_highlight()
		return
	end
	if not (win and vim.api.nvim_win_is_valid(win)) then
		return
	end

	local row = vim.api.nvim_win_get_cursor(win)[1]
	local meta = line_meta[row] or {}
	if meta.test_index then
		current = meta.test_index
	end

	set_tests_winbar()
	update_current_test_highlight()
end

local function jump_to_test(index)
	if not in_tests_ui or #tests == 0 then
		return
	end

	current = math.max(1, math.min(index, #tests))
	local layout = test_layouts[current]

	if layout then
		move_cursor_to_row(layout.header_row)
	end

	set_tests_winbar()
	update_current_test_highlight()
end

local function toggle_current_fold()
	if not in_tests_ui or #tests == 0 then
		return
	end

	local test = tests[current]
	if not test then
		return
	end

	test.collapsed = not test.collapsed
	write_tests()
	M.render()
end

local function set_all_tests_collapsed(collapsed)
	if not in_tests_ui or #tests == 0 then
		return
	end

	local changed = false
	for _, test in ipairs(tests) do
		if test.collapsed ~= collapsed then
			test.collapsed = collapsed
			changed = true
		end
	end

	if not changed then
		return
	end

	write_tests()
	M.render()
end

local function set_create_ui()
	clear_winbar()
	lines = {}
	line_meta = {}

	local prompts = {
		"File: " .. vim.fn.fnamemodify(file_path, ":t"),
		"当前文件还没有创建 cph",
		"按下 c 创建",
	}
	local width = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win)
		or get_config().window.width
	local height = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_height(win) or #prompts
	local top_pad = math.max(1, math.floor(height * 0.2))

	for _ = 1, top_pad do
		push_line("", { kind = "welcome" })
	end

	for _, text in ipairs(prompts) do
		local left_pad = math.max(0, math.floor((width - vim.fn.strdisplaywidth(text)) / 2))
		push_line(string.rep(" ", left_pad) .. text, { kind = "welcome" })
	end
end

local function set_welcome()
	clear_winbar()
	lines = {}
	line_meta = {}

	local art = {
		"  _____ ____  _   _ ",
		" / ____|  _ \\| | | |",
		"| |    | |_) | |_| |",
		"| |    |  __/|  _  |",
		"| |____| |   | | | |",
		" \\_____|_|   |_| |_|",
	}
	local width = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win)
		or get_config().window.width
	local height = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_height(win) or #art
	local top_pad = math.max(0, math.floor((height - #art) / 2))

	for _ = 1, top_pad do
		push_line("", { kind = "welcome" })
	end

	for _, text in ipairs(art) do
		local left_pad = math.max(0, math.floor((width - vim.fn.strdisplaywidth(text)) / 2))
		push_line(string.rep(" ", left_pad) .. text, { kind = "welcome" })
	end
end

local function build_lines()
	lines = {}
	line_meta = {}

	local stat = vim.uv.fs_stat(file_path)
	if not stat or stat.type == "directory" then
		ui_file_path = file_path
		in_create_ui = false
		in_tests_ui = false
		set_welcome()
		return
	end

	local file_changed = ui_file_path ~= file_path
	if file_changed then
		ui_file_path = file_path
		in_create_ui = false
		in_tests_ui = false
		close_edit_popup()
	end

	if in_tests_ui or tests_file_exists(file_path) then
		if file_changed or not in_tests_ui then
			tests = read_tests(file_path)
		end
		in_create_ui = false
		in_tests_ui = true
		refresh_tests_ui()
		return
	end

	in_tests_ui = false
	in_create_ui = true
	set_create_ui()
end

local function patch_test(target_file_path, index, patch, skip_refresh)
	if target_file_path ~= file_path then
		return
	end

	local target = tests[index]
	if not target then
		return
	end

	for key, value in pairs(patch) do
		if key == "passed" then
			target[key] = normalize_status(value)
		else
			target[key] = value
		end
	end

	if not skip_refresh then
		M.refresh()
	end
end

local function save_source_buffer(target_file_path)
	local source_buf = vim.fn.bufnr(target_file_path)
	if source_buf < 0 or not vim.api.nvim_buf_is_valid(source_buf) then
		return true
	end

	if not vim.bo[source_buf].modified then
		return true
	end

	local ok, err = pcall(vim.api.nvim_buf_call, source_buf, function()
		vim.cmd("silent update")
	end)

	if not ok then
		vim.notify("cph: failed to save source buffer: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end

	return true
end

local function collect_run_targets()
	if #tests == 0 then
		return {}
	end

	local indexes = #selected_test_indexes > 0 and vim.deepcopy(selected_test_indexes) or { current }
	local queue = {}

	for _, index in ipairs(indexes) do
		local test = tests[index]
		if test then
			queue[#queue + 1] = {
				index = index,
				test = vim.deepcopy(test),
			}
		end
	end

	return queue
end

local function run_tests()
	if not in_tests_ui or #tests == 0 then
		return
	end
	if run_active then
		vim.notify("cph: another test run is already active", vim.log.levels.WARN)
		return
	end
	if not save_source_buffer(file_path) then
		return
	end

	close_edit_popup()

	local target_file_path = file_path
	local queue = collect_run_targets()
	if #queue == 0 then
		return
	end

	run_active = true
	active_run_file = target_file_path
	active_run_test_index = nil

	for _, item in ipairs(queue) do
		patch_test(target_file_path, item.index, {
			real_output = "",
			passed = STATUS_COMPILING,
			runtime_ms = nil,
		}, true)
	end
	M.refresh()

	executor.run({
		file_path = target_file_path,
		tests = queue,
		on_compile_error = function(message)
			for _, item in ipairs(queue) do
				patch_test(target_file_path, item.index, {
					real_output = message,
					passed = STATUS_FAILED,
					runtime_ms = nil,
				}, true)
			end
			M.refresh()
			vim.notify("cph: compilation failed", vim.log.levels.ERROR)
		end,
		on_test_start = function(index)
			active_run_test_index = index
			patch_test(target_file_path, index, {
				real_output = "",
				passed = STATUS_RUNNING,
				runtime_ms = nil,
			})
		end,
		on_test_done = function(index, result)
			patch_test(target_file_path, index, {
				real_output = result.real_output,
				passed = result.passed,
				runtime_ms = result.runtime_ms,
			})
		end,
		on_done = function()
			run_active = false
			active_run_file = nil
			active_run_test_index = nil
			if target_file_path == file_path then
				M.refresh()
			end
		end,
	})
end

local function map_multi(modes, lhs_list, rhs, opts)
	if type(lhs_list) == "string" then
		lhs_list = { lhs_list }
	end

	for _, lhs in ipairs(lhs_list) do
		vim.keymap.set(modes, lhs, rhs, opts)
	end
end

local function set_keymaps()
	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = buf, silent = true })

	map_multi("n", { "<CR>", "r" }, run_tests, { buffer = buf, silent = true })

	vim.keymap.set("n", "c", function()
		if in_create_ui and ensure_run_idle() then
			create_test_set()
			M.refresh()
		end
	end, { buffer = buf, silent = true })

	vim.keymap.set("n", "a", function()
		if in_tests_ui then
			add_test()
		end
	end, { buffer = buf, silent = true })

	vim.keymap.set("n", "<Space>", function()
		if not in_tests_ui or #tests == 0 then
			return
		end
		if not ensure_run_idle() then
			return
		end

		local test = tests[current]
		if not test then
			return
		end

		test.selected = not test.selected
		write_tests()
		M.refresh()
	end, { buffer = buf, silent = true })

	vim.keymap.set("n", "i", function()
		open_edit_popup("std_input", "Edit input")
	end, { buffer = buf, silent = true })

	vim.keymap.set("n", "o", function()
		open_edit_popup("std_output", "Edit expected output")
	end, { buffer = buf, silent = true })

	vim.keymap.set("n", "d", function()
		if not in_tests_ui or #tests == 0 then
			return
		end
		if not ensure_run_idle() then
			return
		end

		if #selected_test_indexes == 0 then
			remove_test(current)
			write_tests()
			M.refresh()
			return
		end

		for i = #selected_test_indexes, 1, -1 do
			remove_test(selected_test_indexes[i])
		end
		write_tests()
		M.refresh()
	end, { buffer = buf, silent = true })

	map_multi("n", { "<Tab>", "za" }, toggle_current_fold, { buffer = buf, silent = true })
	vim.keymap.set("n", "zM", function()
		set_all_tests_collapsed(true)
	end, { buffer = buf, silent = true })
	vim.keymap.set("n", "zR", function()
		set_all_tests_collapsed(false)
	end, { buffer = buf, silent = true })
	map_multi("n", { "]t", "]]" }, M.next_test, { buffer = buf, silent = true })
	map_multi("n", { "[t", "[[" }, M.last_test, { buffer = buf, silent = true })
end

---@return integer
local function ensure_buf()
	if buf and vim.api.nvim_buf_is_valid(buf) then
		return buf
	end

	buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "cph-tree"

	vim.api.nvim_create_autocmd("CursorMoved", {
		group = popup_group,
		buffer = buf,
		callback = function()
			sync_current_from_cursor()
		end,
	})

	set_keymaps()

	return buf
end

function M.render()
	local render_buf = ensure_buf()

	local cursor_state = capture_cursor_state()

	vim.bo[render_buf].modifiable = true
	vim.api.nvim_buf_clear_namespace(render_buf, highlight_ns, 0, -1)
	vim.api.nvim_buf_clear_namespace(render_buf, decor_ns, 0, -1)
	build_lines()
	vim.api.nvim_buf_set_lines(render_buf, 0, -1, false, lines)
	vim.bo[render_buf].modifiable = false
	apply_decorations()
	restore_cursor_state(cursor_state)
end

function M.refresh()
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_set_width(win, get_config().window.width)
		M.render()
	end
end

function M.open()
	local config = get_config()
	file_path = vim.api.nvim_buf_get_name(0)

	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_set_current_win(win)
		M.refresh()
		return
	end

	local panel_buf = ensure_buf()
	if config.window.dir == "floating" then
		win = vim.api.nvim_open_win(panel_buf, true, {
			relative = "win",
			height = config.window.height,
			width = config.window.width,
			row = (vim.o.lines / 2) - (config.window.height / 2),
			col = (vim.o.columns / 2) - (config.window.width / 2),
			anchor = "NW",
			border = "rounded",
		})
	else
		local split_dir = config.window.dir
		---@cast split_dir cph.SplitWindowDirection
		win = vim.api.nvim_open_win(panel_buf, true, {
			split = split_dir,
			win = -1,
		})
	end

	vim.api.nvim_win_set_width(win, config.window.width)
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].foldcolumn = "0"
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].breakindent = true
	vim.wo[win].showbreak = "  "
	vim.wo[win].cursorline = true
	vim.wo[win].winfixwidth = true
	vim.wo[win].statuscolumn = ""
	vim.wo[win].fillchars = "eob: "
	vim.wo[win].list = false

	M.render()
end

function M.close()
	close_edit_popup()
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
	if in_tests_ui and current < #tests then
		jump_to_test(current + 1)
	end
end

function M.last_test()
	if in_tests_ui and current > 1 then
		jump_to_test(current - 1)
	end
end

function M.setup()
	vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "TabEnter" }, {
		group = group,
		callback = function(args)
			if vim.b[args.buf].cph_popup then
				return
			end
			if buf ~= args.buf then
				file_path = vim.api.nvim_buf_get_name(args.buf)
				M.refresh()
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
		group = group,
		callback = function(args)
			if vim.b[args.buf].cph_popup then
				return
			end
			if vim.api.nvim_buf_get_name(args.buf) == file_path then
				local current_win = vim.api.nvim_get_current_win()
				file_path = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(current_win))
				M.refresh()
			end
		end,
	})
end

return M
