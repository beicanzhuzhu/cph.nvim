local M = {}

local initialized = false
local group = vim.api.nvim_create_augroup("CphHighlights", { clear = true })

local links = {
	CphCurrentTest = "CursorLine",
	CphTitle = "Title",
	CphHeading = "Statement",
	CphLabel = "Identifier",
	CphMuted = "Comment",
	CphSelected = "DiagnosticOk",
	CphSelectedBlock = "DiffAdd",
	CphAccent = "Special",
	CphCompiling = "IncSearch",
	CphRunning = "Search",
	CphPass = "DiffAdd",
	CphFailed = "DiffDelete",
	CphMetric = "Special",
}

function M.apply()
	for name, target in pairs(links) do
		vim.api.nvim_set_hl(0, name, {
			default = true,
			link = target,
		})
	end
end

function M.setup()
	M.apply()

	if initialized then
		return
	end

	initialized = true

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = function()
			M.apply()
		end,
	})
end

return M
