local const = require("const")
local common = require("prototypes.common")
local meld = require("__core__.lualib.meld")

-- for disable_on_damage to work
for _,type in pairs(const.TARGETS) do
	for _,e in pairs(data.raw[type]) do
		e.allow_run_time_change_of_is_military_target = true
	end
end

-- non-destroyable vault ruin
meld(data.raw["simple-entity"][const.VAULT_NAME], {
	selection_priority = 45, -- normal buildings are 50, ore is 40
	minable = meld.delete(),--meld.overwrite{minable=false, mining_time=999999999},
	max_health = 1000000, healing_per_tick = 1000000/60,
	loot = meld.delete(),
	-- was {-6.88,-4}, {6.88,4} effectively (14x8)
	-- now effectively (13x8), (a bit cleaner and) which still allows full coverage with big mining drills (but I have to snap it to grid at runtime!)
	collision_box = {{-6.8,-3.8}, {6.8,3.8}},
	selection_box = {{-7,-4}, {7,4}}, -- was 7.08x4.2
})
-- cannot mine vault ruin, need to adjust tech trigger
meld(data.raw["technology"]["recycling"], {
	research_trigger = meld.overwrite{
		type = "mine-entity",
		entities = {"fulgoran-ruin-colossal", "fulgoran-ruin-huge"} -- 2.1
		--entity = "fulgoran-ruin-colossal" -- needed for 2.0
	}
})

-- vault ruin graphic to hide spawning drones, and create illusion that they ascend out of hole
data:extend{
	{
		type = "simple-entity", -- use optimized-decorative instead?
		name = const.VAULT_NEAR_WALL_NAME,
		flags = {"placeable-neutral", "placeable-off-grid"},
		order = "b[decorative]-l[rock]-d[fulgora]-e[ruin]-g[vault]",
		hidden = true,
		selection_priority = 1,
		--minable = {minable=false, mining_time=999999999},
		max_health = 1000000, healing_per_tick = 1000000/60,
		pictures = {
			{width = 960, height = 640, filename = const.MOD_DIR.."/graphics/fulgoran-ruin-vault-near-wall.png",
			shift = util.by_pixel( 18.5/2, -6/2), scale = 0.5}
		},
		--render_layer = "higher-object-under",
		render_layer = "air-object",
		icon = data.raw["simple-entity"][const.VAULT_NAME].icon,
		collision_box = nil,
		collision_mask = { layers = {} },
		selection_box = {{0,0}, {0,0}},
		selectable_in_game = false,
	}
}

local HARVEST_BOTS = settings.startup[const.MOD_NAME.."-dead-bot-resource"].value
if HARVEST_BOTS then
	for _, name in pairs({"defender", "distractor", "destroyer"}) do
		local real_recyc = data.raw["recipe"][name.."-capsule-recycling"]
		local auto_recyc = data.raw["recipe"]["dead-"..name.."-recycling"]
		
		local dead_recyc = meld(table.deepcopy(real_recyc), {
			name = auto_recyc.name,
			-- item to recycle is not craftable and has no autoplace, so maybe game thinks it's not obtainable, so does not show filter or signals
			-- and shows as red in factoriopedia, this fixes that
			flags = meld.overwrite{ "always-show" },
			ingredients = meld.overwrite{{ type="item", name="dead-"..name, amount=1 }},
			icons = auto_recyc.icons,
			localised_name = auto_recyc.localised_name,
			enabled = true,
		})
		for _,v in pairs(dead_recyc.results) do
			if v.name:find("-capsule") then
				v.name = "dead-"..v.name:gsub("-capsule", "")
			end
		end
		data.raw["recipe"]["dead-"..name.."-recycling"] = dead_recyc
	end
	
end

-- allow all drills to be placed on spots without ore so we can actually build mining setups that catch dead bots
-- this may be annoying, would be great as a hotkey or at least toggable at runtime
if const.ALLOW_DRILLS_WITHOUT_ORE then
	for _,drill in pairs(data.raw["mining-drill"]) do
		if common.list_contains(drill.resource_categories, "basic-solid") then -- not pumpjack
			drill.require_resources_to_place = false
		end
	end
end

-- always defined (hidden when off), so turning the setting off does not delete existing vault-scrap, control converts it back
do
	data:extend{
		meld(table.deepcopy(data.raw["resource"]["scrap"]), {
			name = "vault-scrap",
			hidden = not const.INF_SCRAP_ENABLED,
			localised_name = {"", {"entity-name.scrap"}, " (Vault)"},
			order = "a[scrap]-a[scrap]-b[inf-vault]",
			--hidden = true,
			--hidden_from_player_crafting = true,
			--hidden_in_factoriopedia = true,
			--factoriopedia_alternative = "scrap",
			icon = meld.delete(),
			icons = {
				{ icon = data.raw["resource"]["scrap"].icon,
				  icon_size = 64, scale = .5 },
				{ icon = data.raw["simple-entity"][const.VAULT_NAME].icon,
				  icon_size = 64, scale = .5, shift = {0, 12} },
			},
			--minable = {
			--	mining_time = 1.25, -- was 0.5
			--	result = meld.delete(),
			--	results = {{
			--		type="item",
			--		name = "scrap",
			--		amount_min = 1,
			--		amount_max = 4, -- avg 2.5
			--	}}
			--},
			minable = {
				-- keep the same to try and make finite and infine mining similar with the same numbers
				mining_time = 0.5, -- was 0.5
			},

			infinite = true,
			
			-- ~20M vault patches
			-- individual fulgora vault scrap tiles seem to average around 100k
			-- with normal = 50k, we get faster mining initially, then slower mining later
			-- TODO: estimate time until hitting minimum (not too long if quality is tied to this)
			-- TODO: test other mapgen settings (siZe/richness) to see if they break things (low richness giving high quality instantly?)

			minimum = 10000, -- min 20% like crude oil
			normal =  50000,
			-- make reaching minimum yield quicker with same totals and yield curve
			infinite_depletion_amount = const.INF_DEPLETION_RATE,
		})
	}
	
	-- split the scrap autoplace into normal scrap and vault-scrap (vault islands only)
	-- fulgora_vaults_and_starting_vault is 0 or 1 (built only from comparisons), so positions and amounts stay identical, only the type changes
	-- existing surfaces keep their own map_gen_settings, control (recreate_fulgora.update_autoplace_settings) adds/removes vault-scrap there
	local VAULT_MASK_NOISE = "fulgora_vaults_and_starting_vault"
	local scrap = data.raw["resource"]["scrap"]
	local vault_scrap = data.raw["resource"]["vault-scrap"]
	if const.INF_SCRAP_ENABLED and scrap.autoplace then
		local prob = tostring(scrap.autoplace.probability_expression)
		
		vault_scrap.autoplace = table.deepcopy(scrap.autoplace)
		vault_scrap.autoplace.probability_expression = "("..prob..") * "..VAULT_MASK_NOISE
		scrap.autoplace.probability_expression = "("..prob..") * (1 - "..VAULT_MASK_NOISE..")"
		
		local entity_settings = data.raw["planet"]["fulgora"].map_gen_settings.autoplace_settings.entity.settings
		entity_settings["vault-scrap"] = entity_settings["scrap"] or {}
	else
		-- no autoplace when off, the prototype only exists so existing vault-scrap can be converted back
		vault_scrap.autoplace = nil
	end
end

if settings.startup[const.MOD_NAME.."-nerf-turret-turn"].value then
	-- was 0.015   0.0025 -> very slow against biters (esp turret nests that get surrounded)
	data.raw["ammo-turret"]["gun-turret"].rotation_speed = 0.005 -- was 0.015
	data.raw["electric-turret"]["laser-turret"].rotation_speed = 0.007 -- was 0.01   0.004
end

-- TODO: do this in my overhaul?
--for _,planet in pairs{"vulcanus", "fulgora", "gleba", "aquilo"} do
--	data:extend{{
--		type = "item-group",
--		name = planet.."-group",
--		localised_name = {"", {"space-location-name."..planet}},
--		localised_description = {"", {"space-location-description."..planet}},
--		icon = data.raw["planet"][planet].icon,
--		--order = data.raw["item-group"]["intermediate-products"].order.."-b[fulgora]",
--		order = data.raw["item-group"]["combat"].order.."-a[planets]",
--		order_in_recipe = data.raw["item-group"]["intermediate-products"].order_in_recipe,
--	}}
--end
--
--data.raw["item-subgroup"]["vulcanus-processes"].group = "vulcanus-group"
--data.raw["item-subgroup"]["fulgora-processes"].group = "fulgora-group"
--data.raw["item-subgroup"]["agriculture-processes"].group = "gleba-group"
--data.raw["item-subgroup"]["agriculture-products"].group = "gleba-group"
--data.raw["item-subgroup"]["aquilo-processes"].group = "aquilo-group"
--
--data.raw["item-subgroup"]["fluid-recipes"].group = "fluids"

--for _,type in pairs{"entity","item","recipe"} do
--	for name,proto in pairs(data.raw[type]) do
--		if proto.subsgroup_id == "fulgora-processes" then
--			proto.group_id = "fulgora"
--		end
--	end
--end

-- try to fix the missing vaults
-- bumping threshold can fix it, but it's not safe to bump by much without causing duplicate vaults!

-- preventing other ruins from spawning sometimes makes the vault spawn
-- despite the order giving the vault priority!?
-- maybe just bad luck due to rng changing?
--local ruins = {
--	"fulgoran-ruin-small",
--	"fulgoran-ruin-medium",
--	"fulgoran-ruin-big",
--	"fulgoran-ruin-stonehenge",
--	"fulgoran-ruin-colossal",
--	"fulgoran-ruin-huge",
--}
--data.raw["simple-entity"]["fulgoran-ruin-small"].autoplace.probability_expression = "0"
--data.raw["simple-entity"]["fulgoran-ruin-medium"].autoplace.probability_expression = "0"
--data.raw["simple-entity"]["fulgoran-ruin-big"].autoplace.probability_expression = "0"
--data.raw["simple-entity"]["fulgoran-ruin-stonehenge"].autoplace.probability_expression = "0"
--data.raw["simple-entity"]["fulgoran-ruin-colossal"].autoplace.probability_expression = "0"
--data.raw["simple-entity"]["fulgoran-ruin-huge"].autoplace.probability_expression = "0"

--for _,r in pairs(ruins) do
--	local a = data.raw["simple-entity"][VAULT_NAME].autoplace.order
--	local b = data.raw["simple-entity"][r].autoplace.order
--	assert(a < b)
--end

-- Seemingly sometimes this helps, but sometimes it does not
--data.raw["simple-entity"][VAULT_NAME].autoplace.placement_density = 10
--data.raw["simple-entity"][VAULT_NAME].autoplace.probability_expression = "(min(fulgora_spots, (1 - fulgora_starting_vault_cone) / 2) < 0.0175) * min(fulgora_vaults_and_starting_vault, 1 - fulgora_starting_mask)"

--meld(data.raw["simple-entity"][VAULT_NAME], {
--	autoplace = {
--		placement_density = 10, -- was 1
--		-- thres was 0.015
--		--probability_expression = "(min(fulgora_spots, (1 - fulgora_starting_vault_cone) / 2) < 0.020) * min(fulgora_vaults_and_starting_vault, 1 - fulgora_starting_mask)"
--	}
--})
