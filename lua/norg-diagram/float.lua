local M = {}

M.config = {
	border = "rounded",
	jump_next = "<Tab>",
	jump_prev = "<S-Tab>",
	close = { "q", "<Esc>" },
}

-- `lines` is the art with link markup already injected.
-- `spans` are the label positions within it.
function M.open(lines, spans, src_name, src_buf)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Hop resolves relative links against the buffer's path, so give the
	-- scratch buffer a name next to the file the diagram came from.
	if src_buf then
		local src = vim.api.nvim_buf_get_name(src_buf)
		if src ~= "" then
			local dir = vim.fn.fnamemodify(src, ":h")
			pcall(vim.api.nvim_buf_set_name, buf, dir .. "/.norg-diagram-float.norg")
		end
	end

	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false
	-- neorg parses the links and hop can follow them.
	vim.bo[buf].filetype = "norg"

	local width = 0
	for _, l in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(l))
	end

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor((vim.o.lines - #lines) / 2) - 1,
		col = math.floor((vim.o.columns - width) / 2) - 2,
		width = math.min(width + 2, vim.o.columns - 4),
		height = math.min(#lines, vim.o.lines - 6),
		style = "minimal",
		border = M.config.border,
		title = src_name and (" " .. src_name .. " ") or nil,
	})

	vim.wo[win].conceallevel = 2
	vim.wo[win].concealcursor = "nvic" -- keep boxes aligned under the cursor
	vim.wo[win].wrap = false

	local function jump(dir)
		if #spans == 0 then
			return
		end
		local cur = vim.api.nvim_win_get_cursor(win)
		local row, col = cur[1] - 1, cur[2]

		local pick
		for i = 1, #spans do
			local s = spans[dir > 0 and i or (#spans - i + 1)]
			local after = s.row > row or (s.row == row and s.col > col)
			local before = s.row < row or (s.row == row and s.col < col)
			if (dir > 0 and after) or (dir < 0 and before) then
				pick = s
				break
			end
		end
		-- Wrap around.
		pick = pick or spans[dir > 0 and 1 or #spans]
		vim.api.nvim_win_set_cursor(win, { pick.row + 1, pick.col })
	end

	vim.keymap.set("n", M.config.jump_next, function()
		jump(1)
	end, { buffer = buf, nowait = true, desc = "Next diagram node" })

	vim.keymap.set("n", M.config.jump_prev, function()
		jump(-1)
	end, { buffer = buf, nowait = true, desc = "Previous diagram node" })

	for _, k in ipairs(M.config.close) do
		vim.keymap.set("n", k, function()
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end, { buffer = buf, nowait = true })
	end

	-- Following a link replaces the float's buffer
	vim.keymap.set("n", "<CR>", function()
		local prev = vim.fn.win_getid(vim.fn.winnr("#"))

		-- "x" makes this execute now rather than queueing, so by the next
		-- line hop has already navigated (or not).
		vim.api.nvim_feedkeys(
			vim.api.nvim_replace_termcodes(
				"<Plug>(neorg.esupports.hop.hop-link)",
				true,
				false,
				true
			),
			"mx",
			false
		)

		if not vim.api.nvim_win_is_valid(win) then
			return
		end

		local landed = vim.api.nvim_win_get_buf(win)
		local name = vim.api.nvim_buf_get_name(landed)
		local pos = vim.api.nvim_win_get_cursor(win)

		if landed == buf or name == "" then
			return -- hop did nothing; leave the float open
		end

		vim.api.nvim_win_close(win, true)
		if vim.api.nvim_win_is_valid(prev) then
			vim.api.nvim_set_current_win(prev)
			vim.cmd.edit(vim.fn.fnameescape(name))
			pcall(vim.api.nvim_win_set_cursor, prev, pos)
		end
	end, { buffer = buf, nowait = true })

	if spans[1] then
		vim.api.nvim_win_set_cursor(win, { spans[1].row + 1, spans[1].col })
	end

	return win, buf
end

return M
