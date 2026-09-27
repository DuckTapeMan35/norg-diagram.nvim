local ansi = require("norg-diagram.ansi")
local classes = require("norg-diagram.classes")
local colorize = require("norg-diagram.colorize")
local links = require("norg-diagram.links")
local float = require("norg-diagram.float")

local M = {}

local ns = vim.api.nvim_create_namespace("norg_diagram")
local ns_watch = vim.api.nvim_create_namespace("norg_diagram_watch")
local cache = {}
local inflight = {}

M.gen = {}
M.blocks = {}

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

local function max_width_for(buf, c)
	c = c or M.config
	if c.max_width == "window" then
		return window_width(buf)
	end
	return c.max_width
end

M.config = {
	renderers = {
		mermaid = {
			bin = "mermaid-ascii",
			ext = ".mmd",
			classes = true, -- sentinel classDef injection
			colorize = true,

			border_padding = nil, -- -p, default 1
			padding_x = nil, -- -x, default 5
			padding_y = nil, -- -y, default 5
			coords = false, -- -c, debug overlay
			verbose = false, -- -v

			args = function(c, buf, file, r)
				local a = { "--file", file }
				local function push(flag, val)
					if val ~= nil then
						vim.list_extend(a, { flag, tostring(val) })
					end
				end
				push("--borderPadding", r.border_padding)
				push("--paddingX", r.padding_x)
				push("--paddingY", r.padding_y)
				push("--max-width", max_width_for(buf, c))
				if r.coords then
					table.insert(a, "--coords")
				end
				if r.verbose then
					table.insert(a, "--verbose")
				end
				return a
			end,
		},

		d2 = {
			bin = "d2",
			ext = ".d2",
			classes = false, -- d2's ascii renderer supports no styles
			colorize = true,

			layout = nil, -- "dagro" | "elk" | "tala"; nil uses d2's default
			ascii_mode = "extended", -- "extended" (unicode) | "standard"
			center = false, -- --center

			args = function(_, _, file, r)
				local a = { "--stdout-format", "ascii" }
				local function push(flag, val)
					if val ~= nil then
						vim.list_extend(a, { flag, tostring(val) })
					end
				end
				push("--ascii-mode", r.ascii_mode)
				push("--layout", r.layout)
				if r.sketch then
					table.insert(a, "--sketch")
				end
				if r.center then
					table.insert(a, "--center")
				end
				vim.list_extend(a, { file, "-" })
				return a
			end,
		},

		easy = {
			bin = "graph-easy",
			ext = ".txt",
			classes = false,

			as = "boxart", -- "boxart" (unicode) | "ascii"
			from = nil, -- nil for native syntax, or "dot"
			args = function(_, _, file, r)
				local a = {}
				if r.from then
					vim.list_extend(a, { "--from=" .. r.from })
				end
				vim.list_extend(a, { "--as=" .. r.as, file })
				return a
			end,
		},
	},

	max_width = "window", -- number | "auto" | "window" | nil
	conceal = true,
	fold = true,
	position = "replace", -- "replace" | "after"
	classes = {}, -- ["className"] = "HlGroup"
	box_color = true,
	hl = "Comment",
	err_hl = "DiagnosticError",
	edge_hl = "Comment",
	link_hl = "@neorg.links.description",
	debounce_ms = 300,
	enabled = true,
}

local function build_cmd(r, tmp, buf)
	local cmd = { r.bin }
	vim.list_extend(cmd, r.args(M.config, buf, tmp, r))
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
		if name == "code" and param and M.config.renderers[param] and content then
			local start_row, _, end_row, end_col = node:range()
			if end_col == 0 then
				end_row = end_row - 1
			end
			table.insert(blocks, {
				source = content,
				lang = param,
				start_row = start_row,
				end_row = end_row,
			})
		end
	end
	return blocks
end

-- Where to hang the art. "replace" puts it where the block sits, by
-- anchoring to the last visible line above it. "after" puts it below the
-- block, anchoring to the first visible line beneath.
local function anchor_for(block, blocks, buf)
	local hidden = {}
	for _, b in ipairs(blocks) do
		for row = b.start_row, b.end_row do
			hidden[row] = true
		end
	end

	if M.config.position == "after" then
		local total = vim.api.nvim_buf_line_count(buf)
		local row = block.end_row + 1
		while row < total and hidden[row] do
			row = row + 1
		end
		if row < total then
			return row, true -- above this line
		end
		return nil, nil
	end

	local row = block.start_row - 1
	while row >= 0 and hidden[row] do
		row = row - 1
	end
	if row >= 0 then
		return row, false -- below this line
	end
	return nil, nil
end

local function neorg_concealed(buf)
	local ns_id = vim.api.nvim_get_namespaces()["neorg-conceals.prettify-flag"]
	if not ns_id then
		return true -- concealer absent: nothing to follow, so stay on
	end
	return #vim.api.nvim_buf_get_extmarks(buf, ns_id, 0, -1, { limit = 1 }) > 0
end

local function conceal_on(buf)
	return M.config.conceal and neorg_concealed(buf)
end

local function watch_conceal()
	vim.api.nvim_set_decoration_provider(ns_watch, {
		on_win = function(_, _, buf)
			if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "norg" then
				return false
			end
			M.last_conceal = M.last_conceal or {}
			local now = conceal_on(buf)
			if M.last_conceal[buf] ~= now and M.blocks[buf] then
				M.last_conceal[buf] = now
				-- Cannot touch extmarks from inside the provider.
				vim.schedule(function()
					M.render(buf)
				end)
			end
			return false
		end,
	})
end

local function apply_folds(buf, blocks)
	if not M.config.fold then
		return
	end
	local win = vim.fn.bufwinid(buf)
	if win == -1 then
		return
	end

	local close = neorg_concealed(buf)

	vim.api.nvim_win_call(win, function()
		for _, b in ipairs(blocks) do
			local lnum = b.start_row + 1
			-- A fold must actually begin here, or foldclose climbs to the
			-- enclosing heading fold and swallows the section.
			if vim.fn.foldlevel(lnum) > vim.fn.foldlevel(lnum - 1) then
				local closed = vim.fn.foldclosed(lnum) ~= -1
				if close and not closed then
					pcall(function()
						vim.cmd(lnum .. "foldclose")
					end)
				elseif not close and closed then
					pcall(function()
						vim.cmd(lnum .. "foldopen")
					end)
				end
			end
		end
	end)
end

local function place(buf, block, blocks, lines, want, link_want, hl)
	if conceal_on(buf) then
		for row = block.start_row, block.end_row do
			vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
				conceal_lines = "",
				priority = 100,
			})
		end
	end

	local regions = {}
	local plain
	if (want and #want > 0) or (link_want and #link_want > 0) then
		plain = {}
		for i, l in ipairs(lines) do
			plain[i] = ansi.strip(l)
		end
	end

	if want and #want > 0 then
		regions = colorize.regions(plain, want)
	end

	if link_want and #link_want > 0 and M.config.link_hl then
		for _, h in ipairs(links.locate(plain, link_want)) do
			table.insert(regions, {
				row = h.row,
				col = h.col,
				len = h.len,
				hl = M.config.link_hl,
			})
		end
	end

	local virt = {}
	for i, l in ipairs(lines) do
		local chunks = ansi.parse_line(l, hl)
		if #regions > 0 then
			chunks = colorize.apply_regions(chunks, i - 1, regions, hl)
		end
		chunks = colorize.split_glyphs(chunks, hl, M.config.edge_hl)
		table.insert(virt, chunks)
	end

	local anchor, above = anchor_for(block, blocks, buf)
	if anchor then
		vim.api.nvim_buf_set_extmark(buf, ns, anchor, 0, {
			virt_lines = virt,
			virt_lines_above = above,
			priority = 200,
		})
	else
		-- Block starts the file: hang the art above the first visible line below.
		local row = block.end_row + 1
		while row < vim.api.nvim_buf_line_count(buf) do
			local inside = false
			for _, b in ipairs(blocks) do
				if row >= b.start_row and row <= b.end_row then
					inside = true
					break
				end
			end
			if not inside then
				break
			end
			row = row + 1
		end
		vim.api.nvim_buf_set_extmark(
			buf,
			ns,
			math.min(row, vim.api.nvim_buf_line_count(buf) - 1),
			0,
			{
				virt_lines = virt,
				virt_lines_above = true,
				priority = 200,
			}
		)
	end
end

local function render_block(buf, block, done)
	local r = M.config.renderers[block.lang]
	if not r then
		return
	end

	local src, want = colorize.extract(block.source)
	local link_want
	src, link_want = links.extract(src)

	local decode = {}
	if r.classes then
		src, decode = classes.preprocess(src)
	end

	local key = vim.fn.sha256(block.lang .. "\0" .. src .. "\0" .. tostring(max_width_for(buf)))
	if cache[key] then
		return done(cache[key], decode, want, link_want)
	end

	if inflight[key] then
		table.insert(inflight[key], function(out)
			done(out, decode, want, link_want)
		end)
		return
	end
	inflight[key] = {}

	local function finish(out)
		cache[key] = out
		local waiters = inflight[key]
		inflight[key] = nil
		done(out, decode, want, link_want)
		for _, w in ipairs(waiters or {}) do
			w(out)
		end
	end

	local tmp = vim.fn.tempname() .. r.ext
	vim.fn.writefile(vim.split(src, "\n"), tmp)
	local cmd = build_cmd(r, tmp, buf)

	local ok, err = pcall(vim.system, cmd, { text = true }, function(res)
		os.remove(tmp)
		local out
		if res.code == 0 then
			local raw = (res.stdout or ""):gsub("%s+$", "")
			out = { lines = vim.split(raw, "\n") }
		else
			local raw = (res.stderr or "render failed"):gsub("%s+$", "")
			out = { err = vim.split(raw, "\n") }
		end
		vim.schedule(function()
			finish(out)
		end)
	end)
	if not ok then
		inflight[key] = nil
		done({ err = { "norg-diagram: " .. tostring(err) } }, decode, want, link_want)
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

	M.gen[buf] = (M.gen[buf] or 0) + 1
	local gen = M.gen[buf]

	for _, block in ipairs(blocks) do
		render_block(buf, block, function(out, decode, want, link_want)
			if M.gen[buf] ~= gen then
				return
			end
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
				place(buf, block, blocks, out.lines, want, link_want, M.config.hl)
			else
				place(buf, block, blocks, out.err, want, link_want, M.config.err_hl)
			end
			block.art = out.lines
			block.links = link_want
			M.blocks[buf] = blocks
			apply_folds(buf, blocks)
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
	classes.reset()
	colorize.reset()
	M.render()
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
	ansi.map = {}

	local group = vim.api.nvim_create_augroup("NorgDiagram", { clear = true })
	local timers = {}

	watch_conceal()

	local function schedule(buf)
		if timers[buf] then
			timers[buf]:stop()
		end
		timers[buf] = vim.defer_fn(function()
			timers[buf] = nil
			M.render(buf)
		end, M.config.debounce_ms)
	end

	vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged" }, {
		group = group,
		pattern = "*.norg",
		callback = function(ev)
			schedule(ev.buf)
		end,
	})
	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		pattern = "norg",
		callback = function(ev)
			M.last_conceal = M.last_conceal or {}
			M.last_conceal[ev.buf] = conceal_on(ev.buf)
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
	vim.api.nvim_create_user_command("NorgDiagramFloat", function()
		local buf = vim.api.nvim_get_current_buf()
		local row = vim.api.nvim_win_get_cursor(0)[1] - 1

		for _, b in ipairs(M.blocks[buf] or {}) do
			if row >= b.start_row and row <= b.end_row + 1 and b.art then
				local plain = {}
				for i, l in ipairs(b.art) do
					plain[i] = ansi.strip(l)
				end
				local hits = links.locate(plain, b.links or {})
				local lines, spans = links.inject(plain, hits)
				float.open(lines, spans, b.lang, buf)
				return
			end
		end

		vim.notify("norg-diagram: no diagram under cursor", vim.log.levels.WARN)
	end, { desc = "Open the diagram under the cursor in a float" })
end

return M
