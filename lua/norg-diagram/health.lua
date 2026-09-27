local M = {}

local ok_fn = vim.health.ok or vim.health.report_ok
local warn_fn = vim.health.warn or vim.health.report_warn
local error_fn = vim.health.error or vim.health.report_error
local info_fn = vim.health.info or vim.health.report_info
local start_fn = vim.health.start or vim.health.report_start

local function check_renderer(name, r)
	if type(r) ~= "table" then
		error_fn(("renderer %q is not a table"):format(name))
		return
	end
	if not r.bin then
		error_fn(("renderer %q has no `bin`"):format(name))
		return
	end
	if not r.args then
		error_fn(("renderer %q has no `args` function"):format(name))
		return
	end

	local path = r.bin:match("/") and r.bin or vim.fn.exepath(r.bin)
	if path == "" or (not r.bin:match("/") and vim.fn.executable(r.bin) == 0) then
		warn_fn(("%s: `%s` not found"):format(name, r.bin), {
			("Install it, or set renderers.%s.bin to an absolute path."):format(name),
		})
		return
	end
	if r.bin:match("/") and vim.fn.executable(r.bin) == 0 then
		error_fn(("%s: `%s` is not executable"):format(name, r.bin))
		return
	end

	-- Ask the binary for its version: proves it runs, not just that it exists.
	local res = vim.system({ r.bin, "--version" }, { text = true, timeout = 3000 }):wait()
	local ver = vim.trim((res.stdout or "") .. (res.stderr or "")):gsub("\n.*", "")
	if res.code == 0 and ver ~= "" then
		ok_fn(("%s: %s (%s)"):format(name, ver, path ~= "" and path or r.bin))
	else
		ok_fn(("%s: found at %s"):format(name, path ~= "" and path or r.bin))
	end
end

function M.check()
	local nd = require("norg-diagram")

	start_fn("norg-diagram: environment")

	if vim.fn.has("nvim-0.11") == 1 then
		ok_fn("neovim 0.11+ (conceal_lines available)")
	else
		error_fn("neovim 0.11+ required for conceal_lines")
	end

	local rtp = vim.api.nvim_get_runtime_file("lua/norg-diagram/init.lua", true)
	info_fn("loaded from: " .. (rtp[1] or "unknown"))
	if #rtp > 1 then
		warn_fn(("%d copies on the runtimepath"):format(#rtp), {
			"The first one wins. This is expected while developing.",
			table.concat(rtp, "\n"),
		})
	end
	if vim.env.NORG_DIAGRAM_DEV then
		info_fn("NORG_DIAGRAM_DEV = " .. vim.env.NORG_DIAGRAM_DEV)
	end

	start_fn("norg-diagram: dependencies")

	if pcall(require, "neorg") then
		ok_fn("neorg found")
	else
		error_fn("neorg not found", { "This plugin renders inside .norg buffers." })
	end

	if pcall(vim.treesitter.language.inspect, "norg") then
		ok_fn("norg treesitter parser installed")
	else
		error_fn("norg treesitter parser missing", {
			"Blocks cannot be located without it.",
			"Install it via nvim-treesitter, or grammarPackages on nix.",
		})
	end

	start_fn("norg-diagram: renderers")

	local names = vim.tbl_keys(nd.config.renderers or {})
	table.sort(names)
	if #names == 0 then
		error_fn("no renderers configured")
	end
	for _, name in ipairs(names) do
		check_renderer(name, nd.config.renderers[name])
	end

	start_fn("norg-diagram: display")

	if vim.o.conceallevel >= 2 then
		ok_fn("conceallevel = " .. vim.o.conceallevel)
	else
		warn_fn("conceallevel = " .. vim.o.conceallevel, {
			"Source blocks will not be hidden. Neorg usually sets this to 2.",
		})
	end

	if vim.o.concealcursor:match("n") then
		ok_fn("concealcursor = " .. vim.o.concealcursor)
	else
		warn_fn("concealcursor does not include `n`", {
			"The block under the cursor will be revealed as you move over it.",
		})
	end

	if vim.o.termguicolors then
		ok_fn("termguicolors enabled")
	else
		warn_fn("termguicolors disabled", { "Diagram colors will be approximated." })
	end
end

return M
