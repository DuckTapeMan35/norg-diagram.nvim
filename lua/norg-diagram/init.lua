local ansi = require("norg-diagram.ansi")
local classes = require("norg-diagram.classes")

local M = {}

local ns = vim.api.nvim_create_namespace("norg_diagram")
local cache = {}

M.config = {
	cmd = { "mermaid-ascii", "--file", "{file}" },
	conceal = true,
	border_padding = nil, -- -p, default 1
	padding_x = nil, -- -x, default 5
	padding_y = nil, -- -y, default 5
	max_width = "window", -- number | "auto" | "window" | nil
	coords = false, -- -c, debug
	verbose = false, -- -v
	classes = {}, -- ["className"] = "HlGroup"
	hl = "Comment",
	err_hl = "DiagnosticError",
	debounce_ms = 300,
	enabled = true,
}

local function window_width(buf)
	if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end
	local win = vim.fn.bufwinid(buf)
	if win == -1 then
		return nil
	end
	local info = vim.fn.getwininfo(win)[1]
	if not info then
		return nil
	end
	return math.max(20, info.width - (info.textoff or 0))
end

-- Resolved --max-width for this buffer, or nil to omit the flag.
local function max_width_for(buf)
	if M.config.max_width == "window" then
		return window_width(buf)
	end
	return M.config.max_width
end

local function build_cmd(tmp, buf)
	local cmd = vim.deepcopy(M.config.cmd)
	for i, a in ipairs(cmd) do
		cmd[i] = (a:gsub("{file}", tmp))
	end

	local c = M.config
	local function push(flag, val)
		if val ~= nil then
			vim.list_extend(cmd, { flag, tostring(val) })
		end
	end

	push("--borderPadding", c.border_padding)
	push("--paddingX", c.padding_x)
	push("--paddingY", c.padding_y)
	push("--max-width", max_width_for(buf))

	if c.coords then
		table.insert(cmd, "--coords")
	end
	if c.verbose then
		table.insert(cmd, "--verbose")
	end

	return cmd
end

local function text(node, buf)
	return vim.treesitter.get_node_text(node, buf)
end

local function find_blocks(buf)
	local ok, parser = pcall(vim.treesitter.get_parser, buf, "norg")
	if not ok or not parser then
		return {}
	end
	local root = parser:parse()[1]:root()
	local query = vim.treesitter.query.parse("norg", "(ranged_verbatim_tag) @block")

	local blocks = {}
	for _, node in query:iter_captures(root, buf, 0, -1) do
		local name, param, content
		for child in node:iter_children() do
			local t = child:type()
			if t == "tag_name" then
				name = text(child, buf)
			elseif t == "tag_parameters" then
				param = vim.trim(text(child, buf))
			elseif t == "ranged_verbatim_tag_content" then
				content = text(child, buf)
			end
		end
		if name == "code" and param == "mermaid" and content then
			local start_row, _, end_row, end_col = node:range()
			if end_col == 0 then
				end_row = end_row - 1
			end -- node ends on next line
			table.insert(blocks, { source = content, start_row = start_row, end_row = end_row })
		end
	end
	return blocks
end

local function place(buf, block, lines, hl)
	if M.config.conceal then
		for row = block.start_row, block.end_row - 1 do
			vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
				end_row = row + 1,
				conceal_lines = "",
				priority = 100,
			})
		end
	end

	local virt = {}
	for _, l in ipairs(lines) do
		table.insert(virt, ansi.parse_line(l, hl))
	end
	-- Attach to @end, render above it → diagram sits where content was.
	vim.api.nvim_buf_set_extmark(buf, ns, block.end_row + 1, 0, {
		virt_lines = virt,
		virt_lines_above = true,
		priority = 200,
	})
end

local function render_block(buf, block, done)
	-- Inject sentinel colors so class names survive into the ANSI output.
	local src, decode = classes.preprocess(block.source)

	-- Width affects layout, so it belongs in the cache key.
	local key = vim.fn.sha256(src .. "\0" .. tostring(max_width_for(buf)))
	if cache[key] then
		return done(cache[key], decode)
	end

	local tmp = vim.fn.tempname() .. ".mmd"
	vim.fn.writefile(vim.split(src, "\n"), tmp)
	local cmd = build_cmd(tmp, buf)

	local ok, err = pcall(vim.system, cmd, { text = true }, function(res)
		os.remove(tmp)
		local out
		if res.code == 0 then
			out = { lines = vim.split(vim.trim(res.stdout or ""), "\n") }
		else
			out = { err = vim.split(vim.trim(res.stderr or "render failed"), "\n") }
		end
		cache[key] = out
		vim.schedule(function()
			done(out, decode)
		end)
	end)
	if not ok then
		done({ err = { "norg-diagram: " .. tostring(err) } }, decode)
	end
end

function M.render(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local blocks = find_blocks(buf)
	local tick = vim.api.nvim_buf_get_changedtick(buf)

	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	if not M.config.enabled then
		return
	end

	for _, block in ipairs(blocks) do
		render_block(buf, block, function(out, decode)
			-- drop stale results if the buffer changed meanwhile
			if not vim.api.nvim_buf_is_valid(buf) then
				return
			end
			if vim.api.nvim_buf_get_changedtick(buf) ~= tick then
				return
			end
			-- Sentinels are per block, so set the map right before placing.
			ansi.map = classes.build_map(decode or {}, M.config.classes)
			if out.lines then
				place(buf, block, out.lines, M.config.hl)
			else
				place(buf, block, out.err, M.config.err_hl)
			end
		end)
	end
end

function M.toggle()
	M.config.enabled = not M.config.enabled
	M.render()
end

function M.clear_cache()
	cache = {}
	ansi.reset()
	M.render()
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
	ansi.map = {}

	local group = vim.api.nvim_create_augroup("NorgDiagram", { clear = true })
	local timers = {}

	local function schedule(buf)
		if timers[buf] then
			timers[buf]:stop()
		end
		timers[buf] = vim.defer_fn(function()
			timers[buf] = nil
			M.render(buf)
		end, M.config.debounce_ms)
	end

	vim.api.nvim_create_autocmd({ "BufEnter", "InsertLeave", "TextChanged" }, {
		group = group,
		pattern = "*.norg",
		callback = function(ev)
			schedule(ev.buf)
		end,
	})

	-- Re-render on resize: --max-width changed, so the layout did too.
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = group,
		callback = function()
			for _, win in ipairs(vim.api.nvim_list_wins()) do
				local buf = vim.api.nvim_win_get_buf(win)
				if vim.bo[buf].filetype == "norg" then
					schedule(buf)
				end
			end
		end,
	})

	-- Generated highlight groups are wiped when a colorscheme loads.
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = function()
			ansi.reset()
			M.render()
		end,
	})

	vim.api.nvim_create_user_command("NorgDiagramRender", function()
		M.render()
	end, {})
	vim.api.nvim_create_user_command("NorgDiagramToggle", M.toggle, {})
	vim.api.nvim_create_user_command("NorgDiagramClearCache", M.clear_cache, {})
end

return M
