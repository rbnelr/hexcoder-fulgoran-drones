local const = {}
const.MOD_NAME = "hexcoder-fulgoran-drones"
const.MOD_DIR = "__"..const.MOD_NAME.."__"
const.PRINT_PREFIX = "[Vault Drones] " -- prefix for all prints and log lines of this mod

---- Startup settings
const.DEBUG = settings.startup[const.MOD_NAME.."-debug"].value --[[@as boolean]]
const.VAULT_DEFENSE_RADIUS = settings.startup[const.MOD_NAME.."-vault-defense-radius"].value --[[@as number]]
const.INF_SCRAP_ENABLED = settings.startup[const.MOD_NAME.."-inf-scrap"].value --[["@as boolean"]]
const.HARVESTABLE_BOTS = settings.startup[const.MOD_NAME.."-dead-bot-resource"].value --[["@as boolean"]]
const.BUFFED_DRONES = settings.startup[const.MOD_NAME.."-buff-drones"].value --[["@as boolean"]]
const.NERF_TURRETS = settings.startup[const.MOD_NAME.."-nerf-turret-turn"].value --[["@as boolean"]]

---- Hardcoded settings, some of these could be made settings
-- TODO: make this a setting or experiment with it so it's not anti-QOL
const.ALLOW_DRILLS_WITHOUT_ORE = true

-- expired drones (time_to_live ran out, destroy_action) leave dead-<bot> wrecks like killed ones (dying_trigger_effect)
-- off: expired drones drop the vanilla remnants, wrecks only pile up where drones were actually killed
-- you have to kill them, this avoids bot buildup on vaults without turrets
const.EXPIRED_DRONES_HARVESTABLE = false
-- drones fly back into the vault shaft before their time_to_live runs out, so they don't expire
const.DRONES_TRY_TO_RETURN = true

const.BOT_RESOURCE_QUALITY_BADGES = true

-- 20M patch, at 20% min has 16M available
-- 24 Drills 1.25 mining speed / 0.5s mining time = 60 mining/s at 50% drain = 1800/min
-- 1800/s*10 = 1M/h = ~16h to deplete (more due to mining deed bots and <100% drain slowing down)
-- at 50% drain it takes 1/50%=2x as long to drain, integral from 0.2 to 1 for (1/x) is 1.61, so at 100% initial yield it takes 50% longer than expected
-- with any ore above 100%, it will actually take closer to the expected
const.INF_DEPLETION_RATE = 10

----
const.SCRAP_TYPES = {"scrap", "vault-scrap"} -- vault-scrap always defined, hidden if inf scrap is off
-- inf scrap is a hard toggle and vault islands get converted on load, so ore tracking only looks at this type
-- both types (SCRAP_TYPES) only in the conversion code and when reading fake fulgora
const.ACTIVE_SCRAP = const.INF_SCRAP_ENABLED and "vault-scrap" or "scrap"

const.VAULT_NAME = "fulgoran-ruin-vault"
const.VAULT_NEAR_WALL_NAME = "fulgoran-ruin-vault-near-wall"
const.WAYPOINT = const.MOD_NAME.."-waypoint"

--const.DRONES = {
--	"fulgoran-defender",
--	"fulgoran-distractor",
--	"fulgoran-destroyer",
--}
const.IS_DRONE = {
	["fulgoran-defender"] = true,
	["fulgoran-distractor"] = true,
	["fulgoran-destroyer"] = true,
}

const.DRONE_FORCE = "enemy-fulgoran-drones"

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

----
const.VAULT_SHAFT_CENTER = {x=-0.25, y=0.25} -- shaft visually is an ellipse and not perfectly centered
const.VAULT_SHAFT_RADIUS = 4
const.VAULT_SPAWN_RADIUS = 3.75
const.VAULT_SHAFT_ELLIPSE_K = 0.65 -- shaft is an ellipse, due to perspective

const.BOT_FLOAT_HEIGHT = 0.9 -- bots are rendererd higher than their actual y position, need to account for when spawning

const.EMERGE_PARTICLES = {
	["fulgoran-defender"  ] = "hexcoder-defender-emerge",
	["fulgoran-distractor"] = "hexcoder-distractor-emerge",
	["fulgoran-destroyer" ] = "hexcoder-destroyer-emerge",
}
const.EMERGE_SPEEDS = {
	["defender"] = 4.5,
	["distractor"] = 2.5,
	["destroyer"] = 3.0,
}

if const.DRONES_TRY_TO_RETURN then
	const.DESCEND_PROJECTILES = {
		["fulgoran-defender"  ] = "hexcoder-defender-descend",
		["fulgoran-distractor"] = "hexcoder-distractor-descend",
		["fulgoran-destroyer" ] = "hexcoder-destroyer-descend",
	}
	const.DESCEND_SPEEDS = {
		["defender"] = 7,
		["distractor"] = 4,
		["destroyer"] = 5,
	}
end

const.DRONE_TINT = {
	["defender"  ] = {0.29, 0.64, 0.82}, ["fulgoran-defender"  ] = {0.29, 0.64, 0.82},
	["distractor"] = {0.57, 0.78, 0.21}, ["fulgoran-distractor"] = {0.57, 0.78, 0.21},
	["destroyer" ] = {0.85, 0.25, 0.14}, ["fulgoran-destroyer" ] = {0.85, 0.25, 0.14},
}
--const.DRONE_CORPSE = {
--	["fulgoran-defender"  ] = "defender-remnant",
--	["fulgoran-distractor"] = "distractor-remnant",
--	["fulgoran-destroyer" ] = "destroyer-remnant",
--}

if prototypes then -- only in control
	const.QUALITY_IDS = {}
	do
		local q = prototypes.quality["normal"]
		while q do
			table.insert(const.QUALITY_IDS, q.name)
			q = q.next
		end
	end
	const.MAX_QUALITY_ID = #const.QUALITY_IDS
	
	local function quality_variants_table(name)
		local table = {}
		for _,qn in pairs(const.QUALITY_IDS) do
			table[qn] = name.."-"..qn
		end
		return table
	end
	const.DRONE_DYING_PARTICLE = {
		["fulgoran-defender"  ] = quality_variants_table("fulgoran-defender-dying-particle"),
		["fulgoran-distractor"] = quality_variants_table("fulgoran-distractor-dying-particle"),
		["fulgoran-destroyer" ] = quality_variants_table("fulgoran-destroyer-dying-particle"),
	}
	
	local function quality_levels(tbl, name)
		local to_level = {}
		local from_level = {}
		tbl[name] = { level=1, from_level=from_level }
		from_level[1] = name
		for i=2,#const.QUALITY_IDS do
			local n = name.."-"..const.QUALITY_IDS[i]
			tbl[n] = { level=i, from_level=from_level }
			from_level[i] = n
		end
	end
	const.DRONE_RES_QUALITY_TABLE = {}
	quality_levels(const.DRONE_RES_QUALITY_TABLE, "dead-defender")
	quality_levels(const.DRONE_RES_QUALITY_TABLE, "dead-distractor")
	quality_levels(const.DRONE_RES_QUALITY_TABLE, "dead-destroyer")
end

const.RETARGET_DIST = 15
const.RETURN_TIME = 8*60

const.ORE_POLL_PERIOD = 60*10
const.REPAIR_POLL_LIMIT = 8 -- max per tick

return const
