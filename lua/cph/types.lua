---@meta

---@alias cph.WindowDirection
---| "left"
---| "right"
---| "above"
---| "below"
---| "floating"

---@alias cph.SplitWindowDirection
---| "left"
---| "right"
---| "above"
---| "below"

---@class cph.RunConfig
---@field time_limit integer
---@field memory_limit integer

---@class cph.WindowConfig
---@field width integer
---@field height integer
---@field dir cph.WindowDirection

---@class cph.CompileRule
---@field compiler string
---@field arg? string

---@class cph.Config
---@field window cph.WindowConfig
---@field compile table<string, cph.CompileRule>
---@field run cph.RunConfig

---@class cph.SetupRunConfig
---@field time_limit? integer
---@field memory_limit? integer

---@class cph.SetupWindowConfig
---@field width? integer
---@field height? integer
---@field dir? cph.WindowDirection

---@class cph.SetupOpts
---@field window? cph.SetupWindowConfig
---@field compile? table<string, cph.CompileRule>
---@field run? cph.SetupRunConfig

return {}
