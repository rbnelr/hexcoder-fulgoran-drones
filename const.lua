local const = {}
const.MOD_NAME = "hexcoder-fulgoran-drones"
const.MOD_DIR = "__"..const.MOD_NAME.."__"

---- Startup settings
const.DEBUG = settings.startup[const.MOD_NAME.."-debug"].value --[[@as boolean]]
const.INF_SCRAP_ENABLED = settings.startup[const.MOD_NAME.."-inf-scrap"].value --[["@as boolean"]]

-- restrict buildings being attacked to drills, assemblers and military targets, leave inserters, trains, roboports etc alone,
-- so repair and defense can be safely automated
const.TARGETS = {
	"mining-drill",
	"assembling-machine", "furnace",
	"radar",
	--"roboport" -- dont want to be disabled, but can't be anyway?
	--"lab",
	--"inserter", "pump",
	--"lamp", "arithmetic-combinator", "decider-combinator", "selector-combinator",
	"ammo-turret", "electric-turret",
}
const.IS_TARGET = {}
for _,name in pairs(const.TARGETS) do
	const.IS_TARGET[name] = true
end

const.DRONE_FORCE = "enemy-fulgoran-drones"
const.WAYPOINT = const.MOD_NAME.."-waypoint"
const.VAULT_NAME = "fulgoran-ruin-vault"
const.VAULT_NEAR_WALL_NAME = "fulgoran-ruin-vault-near-wall"

const.DRONES = {
	"fulgoran-defender",
	"fulgoran-distractor",
	"fulgoran-destroyer",
}
const.IS_DRONE = {
	["fulgoran-defender"] = true,
	["fulgoran-distractor"] = true,
	["fulgoran-destroyer"] = true,
}

const.EMERGE_PARTICLES = {
	["fulgoran-defender"  ] = "hexcoder-defender-emerge",
	["fulgoran-distractor"] = "hexcoder-distractor-emerge",
	["fulgoran-destroyer" ] = "hexcoder-destroyer-emerge",
}

const.DRONE_TINT = {
	["fulgoran-defender"  ] = {0.29, 0.64, 0.82},
	["fulgoran-distractor"] = {0.57, 0.78, 0.21},
	["fulgoran-destroyer" ] = {0.85, 0.25, 0.14},
}
const.DRONE_CORPSE = {
	["fulgoran-defender"  ] = "defender-remnant",
	["fulgoran-distractor"] = "distractor-remnant",
	["fulgoran-destroyer" ] = "destroyer-remnant",
}
const.DRONE_RESOURCE = {
	["fulgoran-defender"  ] = "dead-defender",
	["fulgoran-distractor"] = "dead-distractor",
	["fulgoran-destroyer" ] = "dead-destroyer",
}

const.RETARGET_DIST = 15

const.EMERGE_SPEEDS = {
	["defender"] = 4.5,
	["distractor"] = 2.5,
	["destroyer"] = 3.0,
}
const.VAULT_SHAFT_CENTER = {x=-0.25, y=0.25}
const.VAULT_SHAFT_RADIUS = 4
const.VAULT_SHAFT_ELLIPSE_K = 0.65 -- shaft is an ellipse, due to perspective

const.BOT_FLOAT_HEIGHT = 0.9 -- bots are rendererd higher than their actual y position, need to account for when spawning

const.VAULT_SPAWN_RADIUS = 3.75
const.ORE_POLL_PERIOD = 60*10
const.REPAIR_POLL_LIMIT = 8 -- max per tick

-- This is super dodgy, if there are modded drills with high radius we may miss to update them (they won't mine the newly added bot resource)
const.max_drill_radius = 0
if prototypes then
	for _,drill in pairs(prototypes.get_entity_filtered{{filter="type", type="mining-drill"}}) do
		for quality,_ in pairs(prototypes.quality) do
			local radius = drill.get_mining_drill_radius(quality)
			if radius > const.max_drill_radius then const.max_drill_radius = radius end
		end
	end
end

const.SCRAP_TYPES = const.INF_SCRAP_ENABLED and {"scrap", "vault-scrap"} or "scrap"

return const
