local const = require("const")
local myutil = require("lib.myutil")

local misc = {}

function misc.data()
	-- vault gui threat counter (control/gui.lua ALIVE_FONT), "scenario-message-dialog" family is IBM Plex Mono, no font file needed
	data:extend{
		{type="font", name=const.MOD_NAME.."-counter", from="scenario-message-dialog", size=32},
		-- left click on a vault pins its gui (control/gui.lua on_pin_input), linked controls don't show in the controls settings
		{type="custom-input", name=const.MOD_NAME.."-pin-vault", key_sequence="", linked_game_control="open-gui", consuming="none"},
	}
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
			if myutil.list_contains(drill.resource_categories, "basic-solid") then -- not pumpjack
				drill.require_resources_to_place = false
			end
		end
	end

	if const.NERF_TURRETS then
		-- was 0.015   0.0025 -> very slow against biters (esp turret nests that get surrounded)
		data.raw["ammo-turret"]["gun-turret"].rotation_speed = 0.005 -- was 0.015
		data.raw["electric-turret"]["laser-turret"].rotation_speed = 0.007 -- was 0.01   0.004
	end

	-- rocket scorchmarks: with many rocket turrets they turned the whole vault island uniform brown and covered the scrap and wrecks
	-- own copies so only rockets change, other explosions keep the vanilla scorchmarks
	--  final_render_layer below "resource" (vanilla "ground-patch-higher2", resources have a fixed layer above it), "decals" like biter corpse ground patches
	for proj_name, scorchmark_name in pairs{["rocket"]="small-scorchmark-tintable", ["explosive-rocket"]="medium-scorchmark-tintable"} do
		local scorchmark = table.deepcopy(data.raw["corpse"][scorchmark_name])
		scorchmark.name = "rocket-"..scorchmark_name
		scorchmark.final_render_layer = "decals"
		-- the visible mark is the ground_patch, drawn on ground_patch_render_layer (default "ground-patch", above "resource"), not on final_render_layer
		scorchmark.ground_patch_render_layer = "decals"
		scorchmark.time_before_removed = 90*60
		scorchmark.time_before_shading_off = 45*60
		-- rockets create them with check_buildability = true, stops the scorchmask spam
		-- half the vanilla collision box (small 3x3, medium 5x5), so marks can still overlap up to half and don't leave visible gaps
		scorchmark.collision_box = {{scorchmark.collision_box[1][1] / 2, scorchmark.collision_box[1][2] / 2}, {scorchmark.collision_box[2][1] / 2, scorchmark.collision_box[2][2] / 2}}
		scorchmark.collision_mask.not_colliding_with_itself = false
		data:extend{scorchmark}

		local found = false
		for _,effect in pairs(data.raw["projectile"][proj_name].action.action_delivery.target_effects) do
			if effect.type == "create-entity" and effect.entity_name == scorchmark_name then
				effect.entity_name = scorchmark.name
				found = true
			end
		end
		assert(found, "no "..scorchmark_name.." in "..proj_name)
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
