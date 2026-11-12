local const = require("const")
local common = require("control.common")

local dead_bots = {}

function dead_bots.update_unlocked_qualities()
	local highest = 1
	local player_force = game.forces["player"]
	if player_force then
		--for i,q in ipairs(const.QUALITY_IDS) do
		for i=2,const.MAX_QUALITY_ID do -- don't bother checking normal, it's also safer this way
			local q = const.QUALITY_IDS[i]
			if not player_force.is_quality_unlocked(q) then
				break
			end
			highest = i
		end
	end
	storage.highest_quality_unlocked = highest
end

script.on_nth_tick(10*60, dead_bots.update_unlocked_qualities) -- catch research_all_technologies() etc.

---@param res_name string bot_resource_name
---@return string
function dead_bots.downgrade_locked_qualities(res_name)
	local t = const.DRONE_RES_QUALITY_TABLE[res_name]
	local downgraded = math.min(t.level, storage.highest_quality_unlocked)
	return t.from_level[downgraded]
end

---@param surface LuaSurface
---@param position MapPosition
---@param res_name string
function dead_bots.add_dead_bot_resource(surface, position, res_name, count)
	position = { x=math.floor(position.x)+0.5, y=math.floor(position.y)+0.5 } -- find_entity doesn't seem to work with floored ints, unless rounding to 0.5 centers?
	
	res_name = dead_bots.downgrade_locked_qualities(res_name)
	
	local resource = surface.find_entity(res_name, position)
	if resource then
		-- existing resource, increase amount
		resource.amount = resource.amount + count
		
		--local p = resource.position
		--rendering.draw_rectangle{left_top={p.x-0.5, p.y-0.5}, right_bottom={p.x+0.5, p.y+0.5}, surface=surface, filled=false, color={0,0,1}, time_to_live=60*5}
	--else
	-- not really needed resource no longer deletes cliffs due to cliff_removal_probability,
	-- but probably still don't want to spawn under cliff
	elseif surface.count_entities_filtered{position=position, collision_mask="cliff"} == 0 then
		resource = surface.create_entity{name=res_name, position=position, snap_to_grid=true,
			--raise_built=true,
			preserve_ghosts_and_corpses=true, -- ??
		}
		if resource then
			resource.amount = count
			
			common.update_drill_connections_near(surface, position)
			
			--local p = position
			--rendering.draw_rectangle{left_top=area[1], right_bottom=area[2], surface=surface, filled=false, color={0,1,0}, time_to_live=60*5}
		end
	end
end

if const.HARVESTABLE_BOTS then -- was const.HARVEST_BOTS (nil, handler never registered)
	-- only triggers for hostile prototypes
	script.on_event(const.MOD_NAME.."-on-create-combat-bot-remnant", function(event)
		local surface = game.get_surface(event.surface_index) ---@diagnostic disable-line
		if surface and surface.name == "fulgora" then
			--init()
			dead_bots.add_dead_bot_resource(surface, event.target_position, event.effect_id, 1) ---@diagnostic disable-line
			-- could selectively spawn normal corpse here, but not needed right now
		end
	end)
	
	script.on_event(const.MOD_NAME.."-on-combat-bot-died", function(event)
		local surface = game.get_surface(event.surface_index) ---@diagnostic disable-line
		if surface and surface.name == "fulgora" then
			--init()
			local bot = event.source_entity -- is source_entity always the same as target_entity?
			local pos = bot and bot.position or event.source_position
			local vel = bot and bot.get_movement() or {0,0}
			local quality = bot and bot.quality.name or event.quality
			local name = const.DRONE_DYING_PARTICLE[event.effect_id][quality]
			-- original create-particle:
			--  initial_height=1.8
			--  initial_vertical_speed=0
			--  frame_speed = 1 for dying_trigger_effect,  0.5 for destroy_action
			--  frame_speed_deviation = 0.5
			--  speed_from_center = 0
			--  speed_from_center_deviation = 0.2 for dying_trigger_effect,  0.1 for destroy_action
			--  offset_deviation = {-0.01,-0.01}, {0.01,0.01}
			--  offsets = {0, 0.5}
			-- not sure why the numbers don't fit, but these seem ok
			pos.y = pos.y + 0.5
			vel[1] = vel[1]*0.333 + 0.025*(math.random()*2-1)
			vel[2] = vel[2]*0.333 + 0.025*(math.random()*2-1)
			surface.create_particle{name=name,
				position = pos,
				movement = vel,
				height = 1.8,
				vertical_speed = 0,
				frame_speed = 0.5 + math.random()
			}
		end
	end)
	
end

return dead_bots
