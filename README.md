# cph.nvim

`cph` 现在提供了标准化的 `setup(opts)` 配置结构，并给公开入口补了 LuaLS 类型标注。

如果你的 Neovim 配置能被 Lua Language Server 扫描到，在写下面这段配置时会直接拿到字段补全和文档提示：

```lua
require("cph").setup({
	window = {
		dir = "left",
		width = 100,
		height = 80,
	},
	compile = {
		cpp = {
			compiler = "clang++",
			arg = "-O2 -std=c++20",
		},
		c = {
			compiler = "clang",
			arg = "-O2",
		},
	},
	run = {
		time_limit = 2000,
		memory_limit = 2048,
	},
})
```

配置项说明：

- `window.dir`: `"left"`、`"right"`、`"above"`、`"below"`、`"floating"`
- `window.width`: 面板宽度
- `window.height`: 浮窗高度
- `compile`: 按文件类型配置编译器
- `compile.<filetype>.compiler`: 编译命令
- `compile.<filetype>.arg`: 编译参数字符串
- `run.time_limit`: 运行超时，单位毫秒
- `run.memory_limit`: 内存限制，单位 MB（配置项保留，当前版本运行时暂不强制生效）
