mod_name = "hexcoder-fulgoran-drones"

---@type ModStorage
storage = storage

DRONE_FORCE = "enemy-fulgoran-drones"
WAYPOINT = mod_name.."-waypoint"
TARGETS = {
	"mining-drill",
	"assembling-machine", "furnace",
	"radar",
	--"roboport" -- dont want to be disabled, but can't be anyway?
	--"lab",
	--"inserter", "pump",
	--"lamp", "arithmetic-combinator", "decider-combinator", "selector-combinator",
	"ammo-turret", "electric-turret",
}
function VAULT_DEFENSE_RADIUS()
	return settings.global[mod_name.."-vault-defense-radius"].value --[[@as number]]
end
RETARGET_DIST = 15
MAX_POLL = 8 -- rotate through list of damaged buildings, checking MAX_POLL per tick

EMERGE_SPEEDS = {
	["defender"] = 4.5,
	["distractor"] = 2.5,
	["destroyer"] = 3.0,
}
VAULT_SHAFT_CENTER = {x=-0.25, y=0.25}
VAULT_SHAFT_RADIUS = 4
VAULT_SHAFT_ELLIPSE_K = 0.65 -- shaft is an ellipse, due to perspective

BOT_FLOAT_HEIGHT = 0.9 -- bots are rendererd higher than their actual y position, need to account for when spawning

VAULT_SPAWN_RADIUS = 3.75

function check_distance(a, b, r)
	local x = a.x - b.x
	local y = a.y - b.y
	return x*x + y*y <= r*r
end

function random_in_ellipse_center_bias(center, radius)
	local r = math.random()
	local theta  = math.random() * 6.28318530 -- 2PI
	
	return { x = center.x + radius.x*r * math.cos(theta),
	         y = center.y + radius.y*r * math.sin(theta) }
end
function random_in_ellipse(center, radius)
	local r = math.sqrt(math.random())
	local theta  = math.random() * 6.28318530 -- 2PI
	
	return { x = center.x + radius.x*r * math.cos(theta),
	         y = center.y + radius.y*r * math.sin(theta) }
end
function random_in_circle(center, radius)
	radius = radius * math.sqrt(math.random())
	local theta  = math.random() * 6.28318530 -- 2PI
	
	return { x = center.x + radius * math.cos(theta),
	         y = center.y + radius * math.sin(theta) }
end
---@param target ScriptRenderTarget
---@param surface LuaSurface
---@param offset Vector
---@param radius Vector
function draw_ellipse(target, surface, offset, radius, color)
	local vertices = {}
	for i=1,32 do
		local theta = (i/32) * 6.28318530 -- 2PI
		local p = { offset.x + radius.x * math.cos(theta),
		            offset.y + radius.y * math.sin(theta) }
		table.insert(vertices, p)
	end
	rendering.draw_polygon{target=target, surface=surface, vertices=vertices, color=color, time_to_live=1 }
end
