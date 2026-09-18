-- mermaid-ascii can only express color, not class identity, so we inject a
-- unique sentinel RGB per class before rendering and decode it afterwards.
local M = {}

-- Groups used, in order, for classes the user has not configured.
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

-- Sentinel colors live in a corner of the space nobody picks by hand.
local function sentinel(i)
	return string.format("#%02x%02x%02x", 1, math.floor(i / 256) % 256, i % 256)
end

-- Rewrite `source` so every color-less class carries a sentinel.
-- Returns the new source and a { ["#rrggbb"] = "ClassName" } lookup.
function M.preprocess(source)
	local lines = vim.split(source, "\n")
	local declared, used, order = {}, {}, {}

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
			-- an explicit color means hands off
			declared[name] = l:match("color%s*:%s*#%x%x%x%x%x%x") ~= nil
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
		return source, decode
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
			i = i + 1
			group = M.palette[(i - 1) % #M.palette + 1]
		end
		map[e.hex] = group
	end
	return map
end

return M
