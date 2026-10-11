local g = {}
g.MOD_NAME = "hexcoder-fulgoran-drones"
g.MOD_DIR = "__"..g.MOD_NAME.."__"

g.DEBUG = settings.startup[g.MOD_NAME.."-debug"].value --[[@as boolean]]

---@type ModStorage
storage = storage

g.DRONE_FORCE = "enemy-fulgoran-drones"
g.WAYPOINT = g.MOD_NAME.."-waypoint"
g.VAULT_NAME = "fulgoran-ruin-vault"
g.VAULT_NEAR_WALL_NAME = "fulgoran-ruin-vault-near-wall"

g.DRONES = {
	"defender",
	"distractor",
	"destroyer",
}
g.IS_DRONE = {
	["defender"] = true,
	["distractor"] = true,
	["destroyer"] = true,
}

-- restrict buildings being attacked to drills, assemblers and military targets, leave inserters, trains, roboports etc alone,
-- so repair and defense can be safely automated
g.TARGETS = {
	"mining-drill",
	"assembling-machine", "furnace",
	"radar",
	--"roboport" -- dont want to be disabled, but can't be anyway?
	--"lab",
	--"inserter", "pump",
	--"lamp", "arithmetic-combinator", "decider-combinator", "selector-combinator",
	"ammo-turret", "electric-turret",
}
g.IS_TARGET = {}
for _,name in pairs(g.TARGETS) do
	g.IS_TARGET[name] = true
end
function g.VAULT_DEFENSE_RADIUS()
	return settings.global[g.MOD_NAME.."-vault-defense-radius"].value --[[@as number]]
end
g.RETARGET_DIST = 15

g.EMERGE_SPEEDS = {
	["defender"] = 4.5,
	["distractor"] = 2.5,
	["destroyer"] = 3.0,
}
g.VAULT_SHAFT_CENTER = {x=-0.25, y=0.25}
g.VAULT_SHAFT_RADIUS = 4
g.VAULT_SHAFT_ELLIPSE_K = 0.65 -- shaft is an ellipse, due to perspective

g.BOT_FLOAT_HEIGHT = 0.9 -- bots are rendererd higher than their actual y position, need to account for when spawning

g.VAULT_SPAWN_RADIUS = 3.75
g.ORE_POLL_PERIOD = 60*10
g.REPAIR_POLL_LIMIT = 8 -- max per tick

g.TRY_SPAWN_MISSING_VAULTS = false

function g.check_distance2(ax, ay, bx, by, r)
	local x = ax - bx
	local y = ay - by
	return x*x + y*y <= r*r
end
function g.check_distance(a, b, r)
	local x = a.x - b.x
	local y = a.y - b.y
	return x*x + y*y <= r*r
end

function g.random_in_ellipse_center_bias(center, radius)
	local r = math.random()
	local theta = math.random() * 6.28318530 -- 2PI
	
	return { x = center.x + radius.x*r * math.cos(theta),
	         y = center.y + radius.y*r * math.sin(theta) }
end
function g.random_in_ellipse(center, radius)
	local r = math.sqrt(math.random())
	local theta = math.random() * 6.2831853 -- 2PI
	
	return { x = center.x + radius.x*r * math.cos(theta),
	         y = center.y + radius.y*r * math.sin(theta) }
end
function g.random_in_circle(center, radius)
	radius = radius * math.sqrt(math.random())
	local theta = math.random() * 6.2831853 -- 2PI
	
	return { x = center.x + radius * math.cos(theta),
	         y = center.y + radius * math.sin(theta) }
end
---@param target ScriptRenderTarget
---@param surface LuaSurface
---@param offset Vector
---@param radius Vector
function g.draw_ellipse(target, surface, offset, radius, color)
	local vertices = {}
	for i=1,32 do
		local theta = (i/32) * 6.28318530 -- 2PI
		local p = { offset.x + radius.x * math.cos(theta),
		            offset.y + radius.y * math.sin(theta) }
		table.insert(vertices, p)
	end
	rendering.draw_polygon{target=target, surface=surface, vertices=vertices, color=color, time_to_live=1 }
end

---@param list table
---@param items table<integer, table>
---@param period integer
---@param func fun(item)
function g.stagger_tick(list, items, period, func)
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

return g