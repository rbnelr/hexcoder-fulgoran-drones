local const = require("const")
local meld = require("__core__.lualib.meld")

local vault_ruin = {}

function vault_ruin.data()
	-- hidden entity to act as a waypoint around the vault for random drone movement, since drone can't move to arbitrary positions
	data:extend{
		{
			name = const.WAYPOINT,
			type = "simple-entity",
			--picture = const.DEBUG and data.raw["container"]["wooden-chest"].picture or nil,
			picture = nil,
			hidden = true,
			selection_priority = 1,
			max_health = 1000000, healing_per_tick = 1000000/60,
			collision_box = nil,
			collision_mask = { layers = {} },
			selection_box = {{0,0}, {0,0}},
			selectable_in_game = false,
		}
	}
end

function vault_ruin.data_updates()
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

	-- front wall of the vault drawn over the shaft, hides emerging/descending drones (projectiles, always "projectile") so they seem to rise out of the hole
	-- render_layer is per entity, but simple-entity has a second sprite set with its own layer (vanilla vulcanus chimneys use it):
	--  lower_pictures: the vanilla vault at its usual layer, pictures: the front wall on top at "air-object"
	-- "air-object": beams, gunshots and drones share it and still draw over the wall, dying drones end up behind it (render layers: combat_robots.lua final fixes)
	-- was "smoke" (the only layer between projectile and air-object), which flickered and blurred when zoomed out
	local vault = data.raw["simple-entity"][const.VAULT_NAME]
	local vault_pictures = vault.pictures
	vault.lower_pictures = vault_pictures
	vault.lower_render_layer = vault.render_layer or "object"
	vault.pictures = meld(table.deepcopy(vault_pictures), { -- meld from vault_pictures so flags/mipmap or whatever matches, not sure about dice
		{width = 960, height = 640, filename = const.MOD_DIR.."/graphics/fulgoran-ruin-vault-front-wall.png",
		shift = util.by_pixel( 18.5/2, -6/2), scale = 0.5},
	})
	vault.render_layer = "air-object"

	-- try to fix the missing vaults
	-- bumping threshold can fix it, but it's not safe to bump by much without causing duplicate vaults!

	-- preventing other ruins from spawning sometimes makes the vault spawn
	-- despite the order giving the vault priority!?
	-- maybe just bad luck due to rnd changing?
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
end

return vault_ruin
