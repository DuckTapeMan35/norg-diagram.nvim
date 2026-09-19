-- mermaid-ascii can only express color, not class identity, so we inject a
-- unique sentinel RGB per class before rendering and decode it afterwards.
local M = {}

M.palette = {
	"Function",
	"String",
	"Constant",
	"Type",
	"Identifier",
	"Special",
	"Keyword",
	"Number",
}

-- Class names that resolve to the colorscheme's own palette.
local named = {
	black = 0,
	red = 1,
	green = 2,
	yellow = 3,
	blue = 4,
	magenta = 5,
	cyan = 6,
	white = 7,
	bright_black = 8,
	bright_red = 9,
	bright_green = 10,
	bright_yellow = 11,
	bright_blue = 12,
	bright_magenta = 13,
	bright_cyan = 14,
	bright_white = 15,
}

-- Fallbacks when the colorscheme sets no terminal colors.
local fallback_group = {
	red = "DiagnosticError",
	yellow = "DiagnosticWarn",
	green = "String",
	blue = "Function",
	magenta = "Keyword",
	cyan = "Type",
	white = "Normal",
	black = "NonText",
}

local color_groups = {}

-- Highlight group for a named color, or nil if the name is not one.
function M.color_group(name)
	local key = name:lower():gsub("^bright%-", "bright_")
	local idx = named[key]
	if idx == nil then
		return nil
	end
	if color_groups[key] then
		return color_groups[key]
	end

	local group = "NorgDiagramColor" .. key:gsub("_", "")
	local fg = vim.g["terminal_color_" .. idx]

	if type(fg) == "string" and fg:match("^#%x%x%x%x%x%x$") then
		vim.api.nvim_set_hl(0, group, { fg = fg })
	else
		-- No terminal colors: borrow from a group that carries this hue.
		local base = fallback_group[key:gsub("^bright_", "")]
		if base then
			vim.api.nvim_set_hl(0, group, { link = base })
		else
			return nil
		end
	end

	color_groups[key] = group
	return group
end

function M.reset()
	color_groups = {}
end

-- Sentinel colors live in a corner of the space nobody picks by hand.
local function sentinel(i)
	return string.format("#%02x%02x%02x", 1, math.floor(i / 256) % 256, i % 256)
end

-- Rewrite `source` so every color-less class carries a sentinel.
-- Returns the new source and a { ["#rrggbb"] = "ClassName" } lookup.
function M.preprocess(source)
	local lines = vim.split(source, "\n")
	local declared, used, order = {}, {}, {}
	local keep = {}

	local function see(name)
		if name and not used[name] then
			used[name] = true
			table.insert(order, name)
		end
	end

	for _, l in ipairs(lines) do
		local name = l:match("^%s*classDef%s+([%w_-]+)")
		if name then
			see(name)
			if l:match("color%s*:%s*#%x%x%x%x%x%x") then
				declared[name] = true
				table.insert(keep, l) -- explicit color: hands off
			end
		else
			table.insert(keep, l)
		end
		for ref in l:gmatch(":::([%w_-]+)") do
			see(ref)
		end
		-- `class A,B name` is the other way to attach a class
		local list, cls = l:match("^%s*class%s+([%w_,%s-]+)%s+([%w_-]+)%s*$")
		if list and cls then
			see(cls)
		end
	end

	local decode, add = {}, {}
	local n = 0
	for _, name in ipairs(order) do
		if not declared[name] then
			n = n + 1
			local hex = sentinel(n)
			decode[hex] = name
			table.insert(add, ("classDef %s color:%s"):format(name, hex))
		end
	end

	if #add == 0 then
		return table.concat(keep, "\n"), decode
	end

	-- Insert after the graph/flowchart header so the directive stays valid.
	local at = 1
	for i, l in ipairs(lines) do
		if l:match("^%s*graph%s") or l:match("^%s*flowchart%s") then
			at = i
			break
		end
	end
	for i, l in ipairs(add) do
		table.insert(lines, at + i, l)
	end

	return table.concat(lines, "\n"), decode
end

-- Build the ansi.map for one block: sentinel hex -> highlight group.
-- `configured` is the user's { className = "HlGroup" } table.
function M.build_map(decode, configured)
	local map, i = {}, 0
	-- Stable order so a given class keeps its palette slot across renders.
	local names = {}
	for hex, name in pairs(decode) do
		table.insert(names, { hex = hex, name = name })
	end
	table.sort(names, function(a, b)
		return a.hex < b.hex
	end)

	for _, e in ipairs(names) do
		local group = configured and configured[e.name]
		if not group then
			group = M.color_group(e.name)
		end
		if not group then
			i = i + 1
			group = M.palette[(i - 1) % #M.palette + 1]
		end
		map[e.hex] = group
	end
	return map
end

return M
