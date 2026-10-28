local g = require("common")

-- projectile that looks like a drone, to create illusion of drones acending out of hole before they actually become active
-- TODO: tinting doesn't work for these yet

-- projectiles can be covered up by fulgoran-ruin-vault-near-wall
-- what was also suggested was rendering manually with LuaRendering (allow for fading in from black etc.)
-- and using smoke-with-trigger (which has features for fade in, but possibly can't actually move in a line?)
--- slow projectiles that look like bots and spawn bots on "hit", used to make it look like bots are ascending before actually being spawned
for name,bot in pairs(data.raw["combat-robot"]) do
	local animation = util.table.deepcopy(bot.idle)
	local animation_shadow = util.table.deepcopy(bot.shadow_idle)
	local tint = g.DRONE_TINT["fulgoran-"..name]
	
	assert(animation.layers and animation.layers[2] and animation.layers[2].filename:find("-mask"))
	animation.layers[2].apply_runtime_tint = false
	animation.layers[2].tint = tint
	animation.layers[2].tint_as_overlay = true
	
	data:extend{
		{
			type = "projectile",
			name = "hexcoder-"..name.."-emerge",
			flags = { "not-on-map" },
			hidden = true,
			acceleration = 0.01,
			max_speed = g.EMERGE_SPEEDS[name] / 60,
			rotatable = true, -- Does this allow me to spawn the projectile with an orientation?
			action = {
				type = "direct",
				action_delivery = {
					type = "instant",
					target_effects = {
						{
							type = "create-entity",
							entity_name = "fulgoran-"..name,
							trigger_created_entity = true,
						}
					}
				}
			},
			light = { intensity = 0.5, size = 4 },
			enable_drawing_with_mask = true,
			animation = animation,
			shadow = animation_shadow,
		},
	}
end

-- hidden entity to act as a waypoint around the vault for random drone movement, since drone can't move to arbitrary positions
data:extend{
	{
		name = g.WAYPOINT,
		type = "simple-entity",
		--picture = g.DEBUG and data.raw["container"]["wooden-chest"].picture or nil,
	}
}

local meld = require("__core__.lualib.meld")
-- Fits in data-update, but there we don't get automatic recylcling recipies!

if settings.startup[g.MOD_NAME.."-buff-drones"].value then
	-- buff HP and resistances by a lot, otherwise very few turret completely defeat even huge swarms
	-- lengthen time to live
	-- adjust friction and max_speed to prevent drones moving at unlimited speeds, make movements a bit more visually followable
	-- separation_range/range_from_player adjust distance from target and each other
	-- both both player and enemy versions for now
	
	meld(data.raw["combat-robot"]["defender"], {
		resistances = meld.overwrite{
			{ type = "acid",     percent = 50 }, -- was 80 eff HP  400
			{ type = "fire",     percent = 90 }, -- was 95 eff HP 2000
			{ type = "physical", percent = 70 }, -- was 0  eff HP  667
			{ type = "laser",    percent = 80 }, -- was 0  eff HP 1000
			{ type = "electric", percent = 50 }, -- was 0  eff HP  400
		},
		max_health = 200, -- was 60
		--time_to_live = 65*60, -- was 45sec
		
		separation_range = 2,
		range_from_player = 5,
		--friction = 0.016,
		max_speed = 0.3,
		selection_priority = 55, -- make selectable over buildings, was 35, normal buildings are 50, ore is 40
		-- can spawn item like this, could probably trigger script too, to add scrap resource, but I don't actually want that anymore
		--loot =
		--{
		--	{
		--		type = "item",
		--		name = "stone",
		--		amount_min = 2,
		--		amount_max = 10,
		--		independent_probability = 1
		--	}
		--}
	})
	meld(data.raw["combat-robot"]["distractor"], {
		resistances = meld.overwrite{
			{ type = "acid",     percent = 50 }, -- was 80               eff HP  1100
			{ type = "fire",     percent = 90 }, -- was 95               eff HP  5500
			{ type = "physical", percent = 70 }, -- was 0                eff HP  1833
			{ type = "laser",    percent = 80, decrease = 5 }, -- was 0  eff HP ~2750
			{ type = "electric", percent = 50 }, -- was 0                eff HP  1100
		},
		max_health = 550, -- was 180
		--time_to_live = 125*60, -- was 90sec
		selection_priority = 55, -- was 35, normal buildings are 50, ore is 40
	})
	meld(data.raw["combat-robot"]["destroyer"], {
		resistances = meld.overwrite{
			{ type = "acid",     percent = 50 }, -- was 80                eff HP   800
			{ type = "fire",     percent = 90 }, -- was 95                eff HP  4000
			{ type = "physical", percent = 85, decrease = 5 }, -- was 0   eff HP ~2667
			{ type = "laser",    percent = 80, decrease = 3 }, -- was 0   eff HP ~2000
			{ type = "electric", percent = 90, decrease = 20 }, -- was 0  eff HP ~4000
		},
		max_health = 400, -- was 60, now same as a turret
		--time_to_live = 120*60, -- was 120sec
		time_to_live = 70*60, -- shorter than distractors, distractors feel like they should last longest
		
		separation_range = 3,
		range_from_player = 4,
		friction = 0.020,
		max_speed = 0.2,
		selection_priority = 55, -- was 35, normal buildings are 50, ore is 40
	})
end

local HARVEST_BOTS = settings.startup[g.MOD_NAME.."-dead-bot-resource"].value
if HARVEST_BOTS then

	-- distractor capsule takes 3 defenders, spawns 3 distractors
	meld(data.raw["recipe"]["distractor-capsule"], {
		ingredients = meld.overwrite{
			{ type="item", name="advanced-circuit", amount=3 },
			-- personal battery recycles into ~ 1.25 batteries and steel
			-- battery since it's a laser turret drone, and to give more batteries for sci
			-- 1 distractor recycles into 0.9375 batteries
			{ type="item", name="battery-equipment", amount=3 },
			{ type="item", name="defender-capsule", amount=3 },
		}
	})
	meld(data.raw["technology"]["distractor"], {
		prerequisites = g.meld_append_unique{"battery-equipment"}
	})

	-- destroyer capsule takes 4 distractors, spawns 4 destroyers now instead of 5
	data.raw["projectile"]["destroyer-capsule"].action.action_delivery.target_effects.offsets = {
		{ 0, 0 },
		{ 0, 0.7 },
		{ 0.87*0.7, -0.5*0.7 },
		{-0.87*0.7, -0.5*0.7 } -- 0.87 ~= sin(120)   -0.5 ~= cos(120)
	} -- was {{-0.7, -0.7},{-0.7, 0.7},{0.7, -0.7},{0.7, 0.7},{0, 0}} ie. X
	meld(data.raw["recipe"]["destroyer-capsule"], {
		ingredients = meld.overwrite{
			{ type="item", name="steel-plate", amount=4 },
			{ type="item", name="processing-unit", amount=1 },
			{ type="item", name="supercapacitor", amount=2 }, -- supercapacitor since it has a electric attack, and to help sci
			{ type="item", name="distractor-capsule", amount=4 },
		}
	})
	meld(data.raw["technology"]["destroyer"], {
		prerequisites = g.meld_append_unique{"electromagnetic-plant"}
	})
	
	data:extend{{
		type = "custom-event",
		name = g.MOD_NAME.."-on-create-combat-bot-remnant",
	}}

	local order = {
		["defender"]="a[defender]",
		["distractor"]="b[distractor]",
		["destroyer"]="c[destroyer]"
	}
	local robot_resource_sprites = {
		["defender"] = {
			base = { width = 98, height = 94, shift = util.by_pixel(0.5, 0), },
			mask = { width = 98, height = 54, shift = util.by_pixel(0.5, -2.5), },
		},
		["distractor"] = {
			base = { width = 112, height = 110, shift = util.by_pixel(-0.5, 0), },
			mask = { width = 112, height = 60, shift = util.by_pixel(-0.5, -2.5), },
		},
		["destroyer"] = {
			base = { width = 120, height = 108, shift = util.by_pixel(1.5, 0), },
			mask = { width = 120, height =  64, shift = util.by_pixel(1.5, -11), },
		},
	}
	for _, name in pairs({"defender", "distractor", "destroyer"}) do
		local capsule = data.raw["capsule"][name.."-capsule"]
		local robot = data.raw["combat-robot"][name]
		local corpse = data.raw["corpse"][name.."-remnants"]
		local hostile_dying_particle = table.deepcopy(data.raw["optimized-particle"][name.."-dying-particle"])
		local tint = g.DRONE_TINT["fulgoran-"..name]
		
		-- spawn dead bot resource (or regular remnant) via particle and custom event
		-- this will look nicer than reacting to on_entity_died|on_combat_robot_expired and also avoid spawning it on oil ocean
		-- only apply this to hostile version of bot, player version could also want this
		-- if future bot-on-bot fights are desirable, if so should only spawn resource on fulgora?
		hostile_dying_particle.name = "fulgoran-"..hostile_dying_particle.name
		
		local trigger = hostile_dying_particle.ended_on_ground_trigger_effect
		assert(trigger and trigger[1].type == "create-entity")
		trigger[1] = {
			type = "script",
			effect_id = "fulgoran-"..name,
			custom_event = g.MOD_NAME.."-on-create-combat-bot-remnant",
		}
		
		for _,pictures in pairs(hostile_dying_particle.pictures) do
			assert(pictures.layers and pictures.layers[2] and pictures.layers[2].filename:find("-mask"))
			local mask = pictures.layers[2]
			mask.apply_runtime_tint = false
			mask.tint = tint
			mask.tint_as_overlay = true
		end
		
		local wreck_icon = corpse.icon
		
		local item = table.deepcopy(capsule)
		meld(item, {
			name = "dead-"..name.."-capsule",
			type = "item",
			icon = wreck_icon,
			--subgroup = corpse.subgroup,
			--order = capsule.order,
			subgroup = "fulgora-processes",
			order = "z[dead-bots]-"..order[name],
			capsule_action = meld.delete(),
			stack_size = 50,
		})
		
		local sprite = robot_resource_sprites[name]
		local resource = table.deepcopy(data.raw["resource"]["scrap"])
		meld(resource, {
			--type = "resource",
			name = "resource-dead-"..name,
			icon = wreck_icon,
			--flags = {"placeable-neutral"},
			
			subgroup = corpse.subgroup,
			order = robot.order,
			
			cliff_removal_probability = 0, -- do not delete cliffs!
			tree_removal_probability = 0,
			tree_removal_max_distance = 0,
			
			autoplace = meld.delete(),
			
			minable = meld.overwrite{
				mining_time = 3.5,
				results = {{
					type="item",
					name=item.name,
					amount=1,
					ignored_by_productivity=1
				}},
			},
			stages = meld.overwrite{ sheets = {
				--{
				--	-- for resources variations (each tile looking different) are frames in animation sheet
				--	-- mining depletion advances vertially (variation)
				--	filename = "__base__/graphics/entity/destroyer-robot/destroyer-robot.png",
				--	priority = "extra-high",
				--	width = 88, height = 77,
				--	y = 77,
				--	shift = util.by_pixel(2.5, -1.25),
				--	scale = 0.5,
				--	frame_count = 32,
				--	variation_count = 1,
				--},
				--{
				--	filename = "__base__/graphics/entity/destroyer-robot/destroyer-robot-mask.png",
				--	priority = "extra-high",
				--	width = 52, height = 42,
				--	y = 42,
				--	shift = util.by_pixel(2.5, -7),
				--	scale = 0.5,
				--	frame_count = 32,
				--	variation_count = 1,
				--	tint = {1,0,0}
				--},
				{
					-- for resources variations (each tile looking different) are frames in animation sheet
					-- mining depletion advances vertically (variation)
					filename = g.MOD_DIR.."/graphics/"..name.."-resource.png",
					priority = "extra-high",
					width = sprite.base.width, height = sprite.base.height,
					shift = sprite.base.shift,
					scale = 0.5,
					frame_count = 3,
					variation_count = 1,
				},
				{
					filename = g.MOD_DIR.."/graphics/"..name.."-resource-mask.png",
					priority = "extra-high",
					width = sprite.mask.width, height = sprite.mask.height,
					shift = sprite.mask.shift,
					scale = 0.5,
					frame_count = 3,
					variation_count = 1,
					tint = tint,
					tint_as_overlay = true,
				},
			} },
			stage_counts = meld.overwrite{1},
			map_color = meld.overwrite{ 0.85, 0.4, 0.6 },
			
			factoriopedia_simulation = meld.overwrite(corpse.factoriopedia_simulation), -- actually just nil, but either way works
			factoriopedia_description = meld.overwrite(corpse.factoriopedia_description),
			--factoriopedia_alternative = item.name,
		})
		
		data:extend{hostile_dying_particle, resource, item}
	end
end

-- Add hostile versions of combat bot entities to be able to color them individually instead of one color per force
-- and to allow hostile ones to spawn resource and player ones not
for _, name in pairs({"defender", "distractor", "destroyer"}) do
	local hostile_bot = table.deepcopy(data.raw["combat-robot"][name])
	hostile_bot.name = "fulgoran-"..hostile_bot.name
	hostile_bot.localised_name = {"", {"entity-name."..name}, " (Fulgoran)"}
	-- If seperate stats, then don't hide?
	hostile_bot.hidden = true
	hostile_bot.hidden_in_factoriopedia = true
	hostile_bot.factoriopedia_alternative = name
	
	if HARVEST_BOTS then
		local dying_trigger = hostile_bot.dying_trigger_effect
		assert(dying_trigger and dying_trigger[1].type == "create-particle")
		local new_name = "fulgoran-"..dying_trigger[1].particle_name
		
		dying_trigger[1].particle_name = new_name
		
		local destroy_action = hostile_bot.destroy_action
		assert(destroy_action and destroy_action.action_delivery)
		local src_effects = destroy_action.action_delivery.source_effects
		assert(src_effects and src_effects[1] and src_effects[1].type == "create-particle")
		src_effects[1].particle_name = new_name
	end
	
	local mask = hostile_bot.idle.layers[2]
	mask.apply_runtime_tint = false -- I think this means no force based tinting
	mask.tint = g.DRONE_TINT[hostile_bot.name]
	mask.tint_as_overlay = true
	
	mask = hostile_bot.in_motion.layers[2]
	mask.apply_runtime_tint = false -- I think this means no force based tinting
	mask.tint = g.DRONE_TINT[hostile_bot.name]
	mask.tint_as_overlay = true
	
	data:extend{hostile_bot}
end
