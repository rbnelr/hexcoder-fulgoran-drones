local const = require("const")
local common = require("prototypes.common")

local misc = {}

function misc.data()
	
end

function misc.data_updates()
	-- for disable_on_damage to work
	for _,type in pairs(const.TARGETS) do
		for _,e in pairs(data.raw[type]) do
			e.allow_run_time_change_of_is_military_target = true
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

	if const.NERF_TURRETS then
		-- was 0.015   0.0025 -> very slow against biters (esp turret nests that get surrounded)
		data.raw["ammo-turret"]["gun-turret"].rotation_speed = 0.005 -- was 0.015
		data.raw["electric-turret"]["laser-turret"].rotation_speed = 0.007 -- was 0.01   0.004
	end

	-- this is what my spage rebalance mod does now
	--for _,planet in pairs{"fulgora"} do -- {"vulcanus", "fulgora", "gleba", "aquilo"}
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
	--data.raw["item-subgroup"]["fulgora-processes"].group = "fulgora-group"
end

return misc
