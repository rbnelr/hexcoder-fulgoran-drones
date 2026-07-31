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

function check_distance(a, b, r)
	local x = a.x - b.x
	local y = a.y - b.y
	return x*x + y*y <= r*r
end
