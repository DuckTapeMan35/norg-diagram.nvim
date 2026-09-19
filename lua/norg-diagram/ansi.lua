local M = {}

-- Optional user mapping: ["#ff0000"] = "DiagnosticError"
M.map = {}

local SGR = "\27%[([%d;]*)m"

local base = {
	[30] = "#000000",
	[31] = "#cc0000",
	[32] = "#4e9a06",
	[33] = "#c4a000",
	[34] = "#3465a4",
	[35] = "#75507b",
	[36] = "#06989a",
	[37] = "#d3d7cf",
	[90] = "#555753",
	[91] = "#ef2929",
	[92] = "#8ae234",
	[93] = "#fce94f",
	[94] = "#729fcf",
	[95] = "#ad7fa8",
	[96] = "#34e2e2",
	[97] = "#eeeeec",
}

local groups = {} -- cache key -> highlight group name

local function group_for(fg, bold, fallback)
	if not fg and not bold then
		return fallback
	end
	if fg and M.map[fg] then
		return M.map[fg]
	end

	local key = (fg or "none") .. (bold and ":b" or "")
	if groups[key] then
		return groups[key]
	end

	local name = "NorgDiagram" .. key:gsub("[#:]", "")
	local opts = { bold = bold or nil }
	if fg then
		opts.fg = fg
	else
		-- no color, just bold: inherit the fallback group's foreground
		local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = fallback, link = false })
		if ok and hl and hl.fg then
			opts.fg = string.format("#%06x", hl.fg)
		end
	end
	vim.api.nvim_set_hl(0, name, opts)
	groups[key] = name
	return name
end

local function cube(n)
	if n < 16 then
		return base[n < 8 and (30 + n) or (82 + n)]
	elseif n < 232 then
		local c, lv = n - 16, { 0, 95, 135, 175, 215, 255 }
		return string.format(
			"#%02x%02x%02x",
			lv[math.floor(c / 36) % 6 + 1],
			lv[math.floor(c / 6) % 6 + 1],
			lv[c % 6 + 1]
		)
	end
	local v = (n - 232) * 10 + 8
	return string.format("#%02x%02x%02x", v, v, v)
end

-- Apply one SGR parameter string to the running state.
local function apply(params, state)
	-- Handle the multi-part extended forms first, then the simple codes.
	local r, g, b = params:match("38;2;(%d+);(%d+);(%d+)")
	if r then
		state.fg = string.format("#%02x%02x%02x", r, g, b)
		return
	end
	local idx = params:match("38;5;(%d+)")
	if idx then
		state.fg = cube(tonumber(idx))
		return
	end
	if params:match("^48") then
		return
	end -- background: ignored

	for p in params:gmatch("%d+") do
		local n = tonumber(p)
		if n == 0 then
			state.fg, state.bold = nil, false
		elseif n == 1 then
			state.bold = true
		elseif n == 22 then
			state.bold = false
		elseif n == 39 then
			state.fg = nil
		elseif base[n] then
			state.fg = base[n]
		end
	end
end

-- Parse one line of ANSI text into { {text, hlgroup}, ... }
function M.parse_line(line, fallback)
	local chunks, pos = {}, 1
	local state = { fg = nil, bold = false }

	while true do
		local s, e, params = line:find(SGR, pos)
		if not s then
			break
		end
		if s > pos then
			table.insert(
				chunks,
				{ line:sub(pos, s - 1), group_for(state.fg, state.bold, fallback) }
			)
		end
		apply(params, state)
		pos = e + 1
	end

	if pos <= #line then
		table.insert(chunks, { line:sub(pos), group_for(state.fg, state.bold, fallback) })
	end
	if #chunks == 0 then
		chunks = { { "", fallback } }
	end
	return chunks
end

function M.strip(s)
	return (s:gsub(SGR, ""))
end

function M.reset()
	groups = {}
end

return M
