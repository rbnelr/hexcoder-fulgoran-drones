local const = require("const")
local util = require("util")
local common = {}

---@type ModStorage
storage = storage

---- Infinite vault scrap

local INF_SCRAP_PROTO = prototypes.entity["vault-scrap"]
common.INF_SCRAP_NORMAL = INF_SCRAP_PROTO.normal_resource_amount
common.INF_SCRAP_MIN = INF_SCRAP_PROTO.minimum_resource_amount
common.INF_SCRAP_MIN_RATIO = common.INF_SCRAP_MIN / common.INF_SCRAP_NORMAL

-- try to bump such that its not visible in gui (yield floored to %)
common.INF_SCRAP_DEPLETED_BUMP_AMOUNT = math.max(math.floor(INF_SCRAP_PROTO.normal_resource_amount / 100 / 2), 1)

-- we drain faster so inf scrap does not last 100h until it reaches minimum, this does not change yield (other than reducing yield faster)
common.INF_SCRAP_DEPLETION_TO_MINING = 1 / INF_SCRAP_PROTO.infinite_depletion_resource_amount -- == const.INF_DEPLETION_RATE

-- infinite resource minimum amount is actually increased if initial yield > 100%
---@param initial_amount integer
function common.get_inf_scrap_minimum(initial_amount)
	if initial_amount <= common.INF_SCRAP_NORMAL then
		return common.INF_SCRAP_MIN -- 20% of normal
	else
		return math.floor(initial_amount * common.INF_SCRAP_MIN_RATIO) -- 20% of initial amount, is floored correct?
	end
end

-- update drills which touch tile at position, or in position+square radius (for vault)
---@param surface LuaSurface
---@param position MapPosition
---@param radius? number -- default to 0
function common.update_drill_connections_near(surface, position, radius)
	local r = const.max_drill_radius + (radius or 0) -- square radius!
	local area = {{position.x-r, position.y-r}, {position.x+r, position.y+r}}
	-- this includes collision box of drill, not really what we want, but I would have added 1 to radius to make sure anyway
	for _,drill in pairs(surface.find_entities_filtered{area=area, type="mining-drill"}) do
		--local p = drill.position
		--rendering.draw_rectangle{left_top={p.x-2.5, p.y-2.5}, right_bottom={p.x+2.5, p.y+2.5}, surface=surface, filled=false, color={0,0,1}, time_to_live=60*5}
		drill.update_connections()
	end
end

-- merge tables (copy of tbl1 with the values of tbl2 appended), used for event filters
function common.merge(tbl1, tbl2)
	local t = util.table.deepcopy(tbl1)
	for k,v in pairs(tbl2) do
		table.insert(t, v)
	end
	return t
end

-- factorio libs don't have this?
---@param vec Vector
---@return number
function common.vector_length(vec)
	local x = vec.x or vec[1]
	local y = vec.y or vec[2]
	return math.sqrt(x*x + y*y)
end
-- factorio libs don't have this?
---@param vec Vector
---@return Vector
---@return number
function common.normalized_vector(vec)
	local x = vec.x or vec[1]
	local y = vec.y or vec[2]
	local length = math.sqrt(x*x + y*y)
	if length == 0 then return { x=0, y=-1 }, 0 end
	return { x=x/length, y=y/length }, length
end

function common.get_distance(a, b)
	local x = a.x - b.x
	local y = a.y - b.y
	return math.sqrt(x*x + y*y)
end
function common.check_distance2(ax, ay, bx, by, r)
	local x = ax - bx
	local y = ay - by
	return x*x + y*y <= r*r
end
function common.check_distance(a, b, r)
	local x = a.x - b.x
	local y = a.y - b.y
	return x*x + y*y <= r*r
end

function common.random_in_ellipse_center_bias(center, radius)
	local r = math.random()
	local theta = math.random() * 6.28318530 -- 2PI
	
	return { x = center.x + radius.x*r * math.cos(theta),
	         y = center.y + radius.y*r * math.sin(theta) }
end
function common.random_in_ellipse(center, radius)
	local r = math.sqrt(math.random())
	local theta = math.random() * 6.2831853 -- 2PI
	
	return { x = center.x + radius.x*r * math.cos(theta),
	         y = center.y + radius.y*r * math.sin(theta) }
end
function common.random_in_circle(center, radius)
	radius = radius * math.sqrt(math.random())
	local theta = math.random() * 6.2831853 -- 2PI
	
	return { x = center.x + radius * math.cos(theta),
	         y = center.y + radius * math.sin(theta) }
end
---@param target ScriptRenderTarget
---@param surface LuaSurface
---@param offset Vector
---@param radius Vector
function common.draw_ellipse(target, surface, offset, radius, color)
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
function common.int_position_key(pos)
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

---@param list table
---@param items table<integer, table>
---@param period integer
---@param func fun(item)
function common.stagger_tick(list, items, period, func)
	local ok, val
	local key = list.prev_key
	local amount = list.amount or 0
	local count = list.count
	if count == nil or (count == 0 and next(items) ~= nil) then -- init count and handle edge case of empty list that fills again
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
		end
		if key ~= nil then -- edge case of list being empty but still iterating
			func(val)
		end
		amount = amount - 1
	end
	
	list.prev_key, list.amount, list.count = key, amount, count
end

return common
