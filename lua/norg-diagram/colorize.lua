local classes = require("norg-diagram.classes")

local M = {}

local edge_chars = {}
local function add_chars(s)
	for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		edge_chars[ch] = true
	end
end
add_chars("─│┌┐└┘├┤┬┴┼╭╮╰╯━┃┏┓┗┛╌╎┄┆") -- lines and corners
add_chars("►◄▲▼→←↑↓▶◀") -- arrowheads
add_chars("|-+<>^v*.'`") --ascii / d2 standard mode

-- Corner characters, square / rounded / heavy.
local TL = { ["┌"] = true, ["╭"] = true, ["┏"] = true }
local TR = { ["┐"] = true, ["╮"] = true, ["┓"] = true }
local BL = { ["└"] = true, ["╰"] = true, ["┗"] = true }

function M.split_glyphs(chunks, fallback, edge_hl)
	if not edge_hl or edge_hl == fallback then
		return chunks
	end

	local out = {}
	for _, chunk in ipairs(chunks) do
		local s, hl = chunk[1], chunk[2]
		if hl ~= fallback or s == "" then
			table.insert(out, chunk)
		else
			local buf, is_edge = {}, nil
			local function flush()
				if #buf > 0 then
					table.insert(out, { table.concat(buf), is_edge and edge_hl or fallback })
					buf = {}
				end
			end
			for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
				local e = edge_chars[ch] or false
				if is_edge == nil or e == is_edge then
					is_edge = e
					table.insert(buf, ch)
				else
					flush()
					is_edge = e
					buf = { ch }
				end
			end
			flush()
		end
	end
	return out
end

-- Pull `#color` / `%%color` directives out of `source`.
--
--   #color <label> <color>        -> the label text
--   #color <label> <color> box    -> the whole box around it
--
-- Returns cleaned source and { { label, color, box }, ... }.
function M.extract(source)
	local lines, keep, want = vim.split(source, "\n"), {}, {}

	for _, l in ipairs(lines) do
		local body = l:match("^%s*[#%%]+%s*color%s+(.+)$")
		if body then
			-- Trailing `box` is a target, not part of the color.
			local rest, target = body:match("^(.-)%s+(box)%s*$")
			rest = rest or body
			local label, color = rest:match("^(.-)%s+([%w_#-]+)%s*$")
			if label and color then
				table.insert(want, {
					label = vim.trim(label),
					color = color,
					box = target == "box",
				})
			else
				table.insert(keep, l)
			end
		else
			table.insert(keep, l)
		end
	end

	return table.concat(keep, "\n"), want
end

local literal_groups = {}

-- Resolve a color name to a highlight group.
local function group_for(color)
	if color:match("^#%x%x%x%x%x%x$") then
		if not literal_groups[color] then
			local name = "NorgDiagramLit" .. color:sub(2)
			vim.api.nvim_set_hl(0, name, { fg = color })
			literal_groups[color] = name
		end
		return literal_groups[color]
	end

	local themed = classes.color_group(color)
	if themed then
		return themed
	end

	-- Otherwise assume the user named a highlight group.
	if vim.fn.hlexists(color) == 1 then
		return color
	end
	return nil
end

-- Cells for one line: character, byte offset, display column.
local function cells_of(line)
	local cells, col, x = {}, 0, 0
	for ch in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		table.insert(cells, { ch = ch, col = col, x = x, bytes = #ch })
		col = col + #ch
		x = x + 1
	end
	return cells
end

local function x_of_byte(cells, byte)
	for _, c in ipairs(cells) do
		if byte >= c.col and byte < c.col + c.bytes then
			return c.x
		end
	end
	return nil
end

local function byte_of_x(cells, x)
	for _, c in ipairs(cells) do
		if c.x == x then
			return c.col, c.bytes
		end
	end
	return nil
end

-- Find every box. Geometry is in character columns, not bytes.
-- Returns boxes and the per-row cell grid (needed to convert back).
function M.find_boxes(lines)
	local grid = {}
	for i, line in ipairs(lines) do
		grid[i] = cells_of(line)
	end

	local boxes = {}
	for row, cells in ipairs(grid) do
		for i, c in ipairs(cells) do
			if TL[c.ch] then
				local right_x
				for j = i + 1, #cells do
					if TR[cells[j].ch] then
						right_x = cells[j].x
						break
					end
				end

				local bottom
				for r = row + 1, #grid do
					for _, c2 in ipairs(grid[r]) do
						if c2.x == c.x and BL[c2.ch] then
							bottom = r - 1
							break
						end
					end
					if bottom then
						break
					end
				end

				if right_x and bottom then
					table.insert(boxes, {
						top = row - 1,
						bottom = bottom,
						left_x = c.x,
						right_x = right_x,
					})
				end
			end
		end
	end

	return boxes, grid
end

-- Regions covering the smallest box containing `hit`, else just `hit`.
function M.box_regions(boxes, grid, hit)
	local cells = grid[hit.row + 1]
	local hit_x = cells and x_of_byte(cells, hit.col)
	if not hit_x then
		return { hit }
	end

	local best
	for _, b in ipairs(boxes) do
		if
			hit.row >= b.top
			and hit.row <= b.bottom
			and hit_x >= b.left_x
			and hit_x <= b.right_x
		then
			local area = (b.bottom - b.top + 1) * (b.right_x - b.left_x + 1)
			if not best or area < best.area then
				best = { box = b, area = area }
			end
		end
	end
	if not best then
		return { hit }
	end

	local b = best.box
	local out = {}
	for row = b.top, b.bottom do
		local rc = grid[row + 1]
		if rc then
			local left_byte = byte_of_x(rc, b.left_x)
			local right_byte, right_bytes = byte_of_x(rc, b.right_x)
			if left_byte and right_byte then
				table.insert(out, {
					row = row,
					col = left_byte,
					len = right_byte + right_bytes - left_byte,
					hl = hit.hl,
					box = true,
				})
			end
		end
	end
	return out
end

function M.regions(lines, want)
	local order = {}
	for i, w in ipairs(want) do
		local e = vim.deepcopy(w)
		e.id = i -- distinguishes two directives for the same label
		table.insert(order, e)
	end
	table.sort(order, function(a, b)
		return #a.label > #b.label
	end)

	-- Only pay for box detection if something asks for it.
	local boxes, grid
	for _, w in ipairs(order) do
		if w.box then
			boxes, grid = M.find_boxes(lines)
			break
		end
	end

	local out, claimed = {}, {}
	for _, w in ipairs(order) do
		local hl = group_for(w.color)
		if hl then
			for row, line in ipairs(lines) do
				local from = 1
				while true do
					local s, e = line:find(w.label, from, true)
					if not s then
						break
					end

					local pos = row .. ":" .. s
					local key = w.id .. "\0" .. pos

					-- `pos` records which label took this spot, so a second
					-- directive for the SAME label still matches while a
					-- shorter, different label cannot steal the span.
					if not claimed[key] and (claimed[pos] == nil or claimed[pos] == w.label) then
						claimed[key] = true
						claimed[pos] = w.label

						local hit = { row = row - 1, col = s - 1, len = e - s + 1, hl = hl }
						if w.box and boxes then
							vim.list_extend(out, M.box_regions(boxes, grid, hit))
						else
							table.insert(out, hit)
						end
						break
					end

					from = s + 1
				end
			end
		end
	end

	return out
end

function M.reset()
	literal_groups = {}
end

function M.apply_regions(chunks, row, regions, fallback)
	local here = {}
	for _, r in ipairs(regions) do
		if r.row == row then
			table.insert(here, r)
		end
	end
	if #here == 0 then
		return chunks
	end

	local function cover_at(abs)
		local box_hit
		for _, r in ipairs(here) do
			if abs >= r.col and abs < r.col + r.len then
				if not r.box then
					return r -- a label region always beats a box region
				end
				box_hit = box_hit or r
			end
		end
		return box_hit
	end

	local out, col = {}, 0
	for _, c in ipairs(chunks) do
		local s, hl = c[1], c[2]
		if #s == 0 then
			table.insert(out, c)
		elseif hl ~= fallback then
			-- Already colored by the renderer (mermaid :::), so leave it.
			table.insert(out, c)
			col = col + #s
		else
			local pos = 1
			while pos <= #s do
				local cover = cover_at(col + pos - 1)
				local stop = pos
				while stop <= #s and cover_at(col + stop - 1) == cover do
					stop = stop + 1
				end
				table.insert(out, { s:sub(pos, stop - 1), cover and cover.hl or hl })
				pos = stop
			end
			col = col + #s
		end
	end

	return out
end

return M
