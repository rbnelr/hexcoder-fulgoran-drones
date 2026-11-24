local util = require("util")

local myutil = {}

-- true if list contains value, or any of values if values is a table
---@param list any[]
---@param values any[]|any
---@return boolean
function myutil.list_contains(list, values)
	if type(values) == "table" then
		for _,value in pairs(values) do
			for _,item in pairs(list) do
				if value == item then
					return true
				end
			end
		end
	else
		local value = values
		for _,item in pairs(list) do
			if value == item then
				return true
			end
		end
	end
	return false
end

-- concat lists into new list
-- does not deduplicate
-----@param list any[]
-----@param list2 any[]
-----@return any[]
--function myutil.list_concat(list, list2)
--	local new_list = {}
--	for _,v in pairs(list) do
--		table.insert(new_list, v)
--	end
--	for _,v in pairs(list2) do
--		table.insert(new_list, v)
--	end
--	return new_list
--end

-- merge tables (copy of tbl1 with the values of tbl2 appended), used for event filters
---@generic T
---@param tbl1 T[]
---@param tbl2 T[]
---@return T[]
function myutil.merge(tbl1, tbl2)
	local t = util.table.deepcopy(tbl1)
	for k,v in pairs(tbl2) do
		table.insert(t, v)
	end
	return t
end

---@param list any[]
function myutil.shuffle_in_place(list)
	for i = #list, 2, -1 do
		local j = math.random(i)
		list[i], list[j] = list[j], list[i]
	end
end

-- why is this not in math lib?
---@param x number
---@return integer
function myutil.round(x)
	return math.floor(x+0.5)
end

-- factorio libs don't have this?
---@param vec Vector
---@return number
function myutil.vector_length(vec)
	local x = vec.x or vec[1]
	local y = vec.y or vec[2]
	return math.sqrt(x*x + y*y)
end
-- factorio libs don't have this?
---@param vec Vector
---@return Vector
---@return number
function myutil.normalized_vector(vec)
	local x = vec.x or vec[1]
	local y = vec.y or vec[2]
	local length = math.sqrt(x*x + y*y)
	if length == 0 then return { x=0, y=-1 }, 0 end
	return { x=x/length, y=y/length }, length
end

---@param a MapPosition.struct
---@param b MapPosition.struct
---@param r number
---@return boolean
function myutil.check_distance(a, b, r)
	local x = a.x - b.x
	local y = a.y - b.y
	return x*x + y*y <= r*r
end
---@param a MapPosition.struct
---@param b MapPosition.struct
---@return number
function myutil.get_distance(a, b)
	local x = a.x - b.x
	local y = a.y - b.y
	return math.sqrt(x*x + y*y)
end
--function myutil.check_distance2(ax, ay, bx, by, r)
--	local x = ax - bx
--	local y = ay - by
--	return x*x + y*y <= r*r
--end

---@param center MapPosition.struct
---@param radius MapPosition.struct -- x/y radii
---@return MapPosition.struct
function myutil.random_in_ellipse(center, radius)
	local r = math.sqrt(math.random())
	local theta = math.random() * 6.2831853 -- 2PI
	
	return { x = center.x + radius.x*r * math.cos(theta),
	         y = center.y + radius.y*r * math.sin(theta) }
end
---@param center MapPosition.struct
---@param radius MapPosition.struct -- x/y radii
---@return MapPosition.struct
function myutil.random_in_ellipse_center_bias(center, radius)
	local r = math.random()
	local theta = math.random() * 6.28318530 -- 2PI
	
	return { x = center.x + radius.x*r * math.cos(theta),
	         y = center.y + radius.y*r * math.sin(theta) }
end
---@param center MapPosition.struct
---@param radius number
---@return MapPosition.struct
function myutil.random_in_circle(center, radius)
	radius = radius * math.sqrt(math.random())
	local theta = math.random() * 6.2831853 -- 2PI
	
	return { x = center.x + radius * math.cos(theta),
	         y = center.y + radius * math.sin(theta) }
end
---@param center MapPosition
---@param radius number
---@param min_radius number?
function myutil.random_in_circle_center_bias(center, radius, min_radius)
	local radius_range = min_radius and radius - min_radius or radius
	radius = radius_range * math.random() + (min_radius or 0)
	local theta = math.random() * 6.2831853 -- 2PI
	
	return { x = center.x + radius * math.cos(theta),
	         y = center.y + radius * math.sin(theta) }
end

---@param target ScriptRenderTarget
---@param surface LuaSurface
---@param offset Vector
---@param radius Vector
function myutil.draw_ellipse(target, surface, offset, radius, color)
	local vertices = {}
	for i=1,32 do
		local theta = (i/32) * 6.28318530 -- 2PI
		local p = { offset.x + radius.x * math.cos(theta),
		            offset.y + radius.y * math.sin(theta) }
		table.insert(vertices, p)
	end
	rendering.draw_polygon{target=target, surface=surface, vertices=vertices, color=color, time_to_live=1 }
end

---@param pos MapPosition
---@return tile_key
function myutil.tile_position_key(pos)
	local x = math.floor(pos.x or pos[1]) ---@cast x integer
	local y = math.floor(pos.y or pos[2]) ---@cast y integer
	-- lua docs largest integer number without rounding arror: 100,000,000,000,000
	-- largest possible double without skipping integers:    9,007,199,254,740,992 (2^53)
	-- factorio coords are int32, but 8 bit fixed point
	-- so 8,388,608 (2^23) should be largest absolute coord
	-- while 16,777,216 (2^24) is the range
	-- turn x,y into unique number in safe int range of double by multiplying with next power of 10 after 2^24 (use clean decimal number for better debuggability)
	-- largest +/- is now 838,860,808,388,608 (>2^49 and <2^50) which is outside lua doc range, but inside actual safe range
	return y * 100000000 + x -- negative x make y part appear smaller
	--return y * 100000000 + (x + 8388608) -- use this to avoid?
end

---@param key tile_key
---@return MapPosition
function myutil.tile_position_key_to_center(key)
	local y = math.floor(key / 100000000 + 0.5)
	return {x = key - y * 100000000 + 0.5, y = y + 0.5}
end

-- iteration state of a staggered poll, kept in storage (plain table, starts as {})
---@class StaggerTickState
---@field prev_key any? -- key of the last polled item, next() continues from here
---@field amount number? -- fractional items owed, carried over between ticks
---@field count integer? -- cached table_size(items), refreshed once per pass

---@generic K, V
---@param state StaggerTickState
---@param items table<K, V>
---@param period integer -- ticks per full pass over items
---@param func fun(key: K, item: V)
---@return boolean restarted
function myutil.stagger_tick(state, items, period, func)
	local ok, val
	local key = state.prev_key
	local amount = state.amount or 0
	local count = state.count
	local restarted = count == nil or (count == 0 and next(items) ~= nil)
	if restarted then -- init count and handle edge case of empty items that fill again
		count = table_size(items)
	end
	-- update count/period items per tick, effectively update each item once every period tick
	amount = amount + count / period
	
	while amount >= 1 do
		-- get next item based on prev key
		-- pcall make it safe even after prev_key was deleted from items and items was rehashed (normally an error)
		ok, key, val = pcall(next, items, key)
		if not (ok and key ~= nil) then -- key not found (!ok) or end of list reached (key==nil), restart iteration
			key, val = next(items)
			-- cache count, and only update once per pass, not every tick
			count = table_size(items)
			restarted = true
		end
		if key ~= nil then -- edge case of items being empty but still iterating
			func(key, val)
		end
		amount = amount - 1
	end
	
	state.prev_key, state.amount, state.count = key, amount, count
	return restarted
end

return myutil
