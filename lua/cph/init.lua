---@class cph.Module
---@field toggle fun()
---@field setup fun(opts?: cph.SetupOpts)

---@type cph.Module
local M = {}

local config = require("cph.config")
local highlights = require("cph.highlights")
local runner = require("cph.runner")

highlights.setup()

function M.toggle()
	runner.toggle()
end

---@param opts? cph.SetupOpts
function M.setup(opts)
	config.setup(opts)
	highlights.setup()
	runner.setup()
end

return M
