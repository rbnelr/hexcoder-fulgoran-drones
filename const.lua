local const = {}
const.MOD_NAME = "hexcoder-fulgoran-drones"
const.MOD_DIR = "__"..const.MOD_NAME.."__"
const.PRINT_PREFIX = "[Vault Drones] " -- prefix for all prints and log lines of this mod

---- Startup settings
const.DEBUG = settings.startup[const.MOD_NAME.."-debug"].value --[[@as boolean]]
const.VAULT_DEFENSE_RADIUS = settings.startup[const.MOD_NAME.."-vault-defense-radius"].value --[[@as number]]
const.INF_SCRAP_ENABLED = settings.startup[const.MOD_NAME.."-inf-scrap"].value --[["@as boolean"]]
const.HARVESTABLE_BOTS = settings.startup[const.MOD_NAME.."-dead-bot-resource"].value --[["@as boolean"]]

-- TODO: setting for quality and attack size curve
const.ALLOW_DRILLS_WITHOUT_ORE = true

-- expired drones (time_to_live ran out, destroy_action) leave dead-<bot> wrecks like killed ones (dying_trigger_effect)
-- off: expired drones drop the vanilla remnants, wrecks only pile up where drones were actually killed
-- you have to kill them, this avoids bot buildup on vaults without turrets
const.EXPIRED_DRONES_HARVESTABLE = false
-- drones fly back into the vault shaft before their time_to_live runs out, so they don't expire
const.DRONES_TRY_TO_RETURN = true

-- 20M patch, at 20% min has 16M available
-- 24 Drills 1.25 mining speed / 0.5s mining time = 60 mining/s at 50% drain = 1800/min
-- 1800/s*10 = 1M/h = ~16h to deplete (more due to mining deed bots and <100% drain slowing down)
-- at 50% drain it takes 1/50%=2x as long to drain, integral from 0.2 to 1 for (1/x) is 1.61, so at 100% initial yield it takes 50% longer than expected
-- with any ore above 100%, it will actually take closer to the expected
const.INF_DEPLETION_RATE = 10 -- make setting?

const.SCRAP_TYPES = {"scrap", "vault-scrap"} -- vault-scrap always defined, hidden if inf scrap is off
-- inf scrap is a hard toggle and vault islands get converted on load, so ore tracking only looks at this type
-- both types (SCRAP_TYPES) only in the conversion code and when reading fake fulgora
const.ACTIVE_SCRAP = const.INF_SCRAP_ENABLED and "vault-scrap" or "scrap"

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

if const.DRONES_TRY_TO_RETURN then
	const.DESCEND_PROJECTILES = {
		["fulgoran-defender"  ] = "hexcoder-defender-descend",
		["fulgoran-distractor"] = "hexcoder-distractor-descend",
		["fulgoran-destroyer" ] = "hexcoder-destroyer-descend",
	}
end

const.DRONE_TINT = {
	["defender"  ] = {0.29, 0.64, 0.82},
	["distractor"] = {0.57, 0.78, 0.21},
	["destroyer" ] = {0.85, 0.25, 0.14},
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
const.DESCEND_SPEEDS = {
	["defender"] = 7,
	["distractor"] = 4,
	["destroyer"] = 5,
}

const.RETURN_TIME = 8*60

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

return const
