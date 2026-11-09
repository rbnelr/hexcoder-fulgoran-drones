local g = {}
g.MOD_NAME = "hexcoder-fulgoran-drones"
g.MOD_DIR = "__"..g.MOD_NAME.."__"

g.DEBUG = settings.startup[g.MOD_NAME.."-debug"].value --[[@as boolean]]
g.INF_SCRAP_ENABLED = settings.startup[g.MOD_NAME.."-inf-scrap"].value --[["@as boolean"]]

---@type ModStorage
storage = storage

g.DRONE_FORCE = "enemy-fulgoran-drones"
g.WAYPOINT = g.MOD_NAME.."-waypoint"
g.VAULT_NAME = "fulgoran-ruin-vault"
g.VAULT_NEAR_WALL_NAME = "fulgoran-ruin-vault-near-wall"

g.DRONES = {
	"fulgoran-defender",
	"fulgoran-distractor",
	"fulgoran-destroyer",
}
g.IS_DRONE = {
	["fulgoran-defender"] = true,
	["fulgoran-distractor"] = true,
	["fulgoran-destroyer"] = true,
}

g.EMERGE_PARTICLES = {
	["fulgoran-defender"  ] = "hexcoder-defender-emerge",
	["fulgoran-distractor"] = "hexcoder-distractor-emerge",
	["fulgoran-destroyer" ] = "hexcoder-destroyer-emerge",
}

g.DRONE_TINT = {
	["fulgoran-defender"  ] = {0.29, 0.64, 0.82}, -- TODO: check these tints
	["fulgoran-distractor"] = {0.57, 0.78, 0.21},
	["fulgoran-destroyer" ] = {0.85, 0.25, 0.14},
}
g.DRONE_CORPSE = {
	["fulgoran-defender"  ] = "defender-remnant",
	["fulgoran-distractor"] = "distractor-remnant",
	["fulgoran-destroyer" ] = "destroyer-remnant",
}
g.DRONE_RESOURCE = {
	["fulgoran-defender"  ] = "dead-defender",
	["fulgoran-distractor"] = "dead-distractor",
	["fulgoran-destroyer" ] = "dead-destroyer",
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

-- This is super dodgy, if there are modded drills with high radius we may miss to update them (they won't mine the newly added bot resource)
g.max_drill_radius = 0
if prototypes then
	for _,drill in pairs(prototypes.get_entity_filtered{{filter="type", type="mining-drill"}}) do
		for quality,_ in pairs(prototypes.quality) do
			local radius = drill.get_mining_drill_radius(quality)
			if radius > g.max_drill_radius then g.max_drill_radius = radius end
		end
	end
end

g.SCRAP_TYPES = g.INF_SCRAP_ENABLED and {"scrap", "vault-scrap"} or "scrap"

-- vaults missing from not being generated despite being on an ore island
--g.TRY_SPAWN_MISSING_VAULTS = false

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

---@param pos MapPosition
---@return integer
function g.int_position_key(pos)
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

-- merge tables
function g.merge(tbl1, tbl2)
	local t = util.table.deepcopy(tbl1)
	for k,v in pairs(tbl2) do
		table.insert(t, v)
	end
	return t
end

local meld = require("__core__.lualib.meld")

-- append value if not already exist
-- ex. use instead of meld.append in tech prerequisites, if values could already exist
---@param values string[]
function g.meld_append_unique(values)
	local meld = require("__core__.lualib.meld")
	return { marker = meld.control_marker, op = "append_unique", data = values } ---@diagnostic disable-line
end
meld.control_handlers.append_unique = function(target, k, v) ---@diagnostic disable-line
	local list = target[k] or {}
	local existing_values = {}
	for _, value in pairs(list) do
		table.insert(existing_values, value)
	end
	for _, value in pairs(v.data) do
		if existing_values[value] == nil then
			table.insert(list, util.copy(value))
		end
	end
	target[k] = list
end

return g