-- Attach neorg links to diagram nodes, for the float view.
--
--   %%link <label> {:some/file:}
--   #link  <label> {:some/file:** Heading}
--
-- Stripped before the renderer runs, then injected back into the rendered
-- art inside a float whose filetype is norg, so neorg's own parser handles
-- highlighting, concealing and following.
local M = {}

local escape_chars = {}
for ch in
	("─│┌┐└┘├┤┬┴┼╭╮╰╯━┃┏┓┗┛"):gmatch(
		"[%z\1-\127\194-\244][\128-\191]*"
	)
do
	escape_chars[ch] = true
end

-- Returns cleaned source and { { label = ..., target = ... }, ... }.
function M.extract(source)
	local lines, keep, want = vim.split(source, "\n"), {}, {}

	for _, l in ipairs(lines) do
		local label, target = l:match("^%s*[#%%]+%s*link%s+(.-)%s+({.+})%s*$")
		if label and target then
			table.insert(want, { label = vim.trim(label), target = target })
		else
			table.insert(keep, l)
		end
	end

	return table.concat(keep, "\n"), want
end

-- Locate each label in the art. Rows are 0-based; cols are byte offsets.
function M.locate(lines, want)
	local order = vim.deepcopy(want)
	table.sort(order, function(a, b)
		return #a.label > #b.label
	end)

	local hits, claimed = {}, {}
	for _, w in ipairs(order) do
		for row, line in ipairs(lines) do
			local from = 1
			local placed = false
			while not placed do
				local s, e = line:find(w.label, from, true)
				if not s then
					break
				end
				local pos = row .. ":" .. s
				if not claimed[pos] then
					claimed[pos] = true
					table.insert(hits, {
						row = row - 1,
						col = s - 1,
						len = e - s + 1,
						target = w.target,
					})
					placed = true
				else
					from = s + 1
				end
			end
			if placed then
				break
			end
		end
	end

	return hits
end

-- Wrap located labels in neorg link markup, right to left per row so
-- untouched columns stay valid. Returns new lines and the label spans in
-- the rewritten text, for cursor jumping.
function M.inject(lines, hits)
	local by_row = {}
	for _, h in ipairs(hits) do
		by_row[h.row] = by_row[h.row] or {}
		table.insert(by_row[h.row], h)
	end

	local out, spans = vim.deepcopy(lines), {}

	for row, hs in pairs(by_row) do
		-- Right to left, so columns we have not reached stay valid.
		table.sort(hs, function(a, b)
			return a.col > b.col
		end)

		local line = out[row + 1]
		if line then
			local targets = {}
			for _, h in ipairs(hs) do
				local label = line:sub(h.col + 1, h.col + h.len)
				line = line:sub(1, h.col)
					.. h.target
					.. "["
					.. label
					.. "]"
					.. line:sub(h.col + h.len + 1)
				targets[label] = h.target
			end

			local parts = {}
			for ch in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
				table.insert(parts, escape_chars[ch] and ("\\" .. ch) or ch)
			end
			line = table.concat(parts)
			out[row + 1] = line

			-- Both rewrites moved the columns, so locate the labels again
			-- in the finished text instead of tracking offsets.
			local from = 1
			while true do
				local s, e = line:find("{[^}]*}%[[^%]]*%]", from)
				if not s then
					break
				end
				local open = line:find("%[", s)
				local close = line:find("%]", open)
				if open and close then
					table.insert(spans, {
						row = row,
						col = open, -- 0-based byte of the first label char
						len = close - open - 1,
						target = line:sub(s, open - 1),
					})
				end
				from = e + 1
			end

			local _ = targets
		end
	end

	table.sort(spans, function(a, b)
		if a.row ~= b.row then
			return a.row < b.row
		end
		return a.col < b.col
	end)

	return out, spans
end

return M
