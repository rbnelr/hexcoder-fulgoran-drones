local const = require("const")
local common = require("control.common")

local myutil = require("lib.myutil")
local dead_bots = {}

--#region resource spawning and modification

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

---@param res_name string bot_resource_name
---@return string
function dead_bots.downgrade_locked_qualities(res_name)
	local t = const.DRONE_RES_QUALITY_TABLE[res_name]
	local downgraded = math.min(t.level, storage.highest_quality_unlocked)
	return t.from_level[downgraded]
end

--local DRONE_XY = {}
--do
--	local i = 0
--	for k,v in pairs(const.DRONE_RES_QUALITY_TABLE) do
--		DRONE_XY[k] = {x=i%5, y=math.floor(i/5)}
--		i = i + 1
--	end
--end

-- If a bot dies and tries to spawn a resource tile on top of the vault shaft, move it outward
---@param surface LuaSurface
---@param position MapPosition
---@return MapPosition
function dead_bots.decollide_with_vault(surface, position)
	local vault = surface.find_entity(const.VAULT_NAME, position)
	if vault then
		local vault_pos = vault.position
		local vault_x = vault_pos.x + const.VAULT_SHAFT_CENTER.x
		local vault_y = vault_pos.y + const.VAULT_SHAFT_CENTER.y
		
		local offset_x = position.x - vault_x
		local offset_y = position.y - vault_y
		
		-- do math in ellipse coords (1=radius)
		local shaft_r_x = const.VAULT_SHAFT_RADIUS+0.5
		local shaft_r_y = shaft_r_x * const.VAULT_SHAFT_ELLIPSE_K
		
		offset_x = offset_x / shaft_r_x
		offset_y = offset_y / shaft_r_y
		
		local dist_sqr = offset_x*offset_x + offset_y*offset_y
		if dist_sqr < 1 then
			local dist = math.sqrt(dist_sqr)
			local dir_x
			local dir_y
			if dist > 0.05 then
				dir_x = offset_x / dist
				dir_y = offset_y / dist
			else
				local dir = myutil.random_dir()
				dir_x = dir.x
				dir_y = dir.y
			end
			
			-- shift_min* of ellipse radius up to shift_max*
			local shift_min = 1.25
			local shift_max = 1.9
			local shift = shift_min + math.random() * (shift_max - shift_min)
			local new_position = {
				x = vault_x + (dir_x * shift) * shaft_r_x,
				y = vault_y + (dir_y * shift) * shaft_r_y,
			}
			
			--myutil.draw_ellipse(vault, surface, const.VAULT_SHAFT_CENTER, {shaft_r_x,shaft_r_y}, {1,0,0}, 30)
			--rendering.draw_line{surface=surface, from=position, to=new_position, width=1, color={0,1,0}, time_to_live=30}
			--
			--local snapped = { math.floor(new_position.x)+0.5, math.floor(new_position.y)+0.5 }
			--rendering.draw_circle{surface=surface, target=snapped, radius=0.5, color={1,1,0}, time_to_live=600}
			return new_position
		end
	end
	return position
end

---@param surface LuaSurface
---@param position MapPosition
---@param res_name string
---@param count integer
function dead_bots.add_dead_bot_resource(surface, position, res_name, count)
	-- don't drop dead bots on vault shaft
	-- TODO: could try to apply this to on_bot_died instead (corpse actually flies such that it happens to land outside)
	position = dead_bots.decollide_with_vault(surface, position)
	position = { x=math.floor(position.x)+0.5, y=math.floor(position.y)+0.5 } -- find_entity doesn't seem to work with floored ints, unless rounding to 0.5 centers?
	
	res_name = dead_bots.downgrade_locked_qualities(res_name)
	
	--local grid_size = 5
	--local xy = DRONE_XY[res_name]
	--position.x = math.floor(position.x/grid_size)*grid_size + xy.x
	--position.y = math.floor(position.y/grid_size)*grid_size + xy.y
	local resource = surface.find_entity(res_name, position)
	if resource then
		-- existing resource, increase amount
		resource.amount = resource.amount + count
		
		--local p = resource.position
		--rendering.draw_rectangle{left_top={p.x-0.5, p.y-0.5}, right_bottom={p.x+0.5, p.y+0.5}, surface=surface, filled=false, color={0,0,1}, time_to_live=60*5}
	else
	-- not really needed resource no longer deletes cliffs due to cliff_removal_probability,
	-- but probably still don't want to spawn under cliff (but costs perf, so let's avoid it)
	--elseif surface.count_entities_filtered{position=position, collision_mask="cliff"} == 0 then
		resource = surface.create_entity{name=res_name, position=position, snap_to_grid=true,
			--raise_built=true,
			preserve_ghosts_and_corpses=true, -- ??
		}
		if resource then
			resource.amount = count
			
			--common.update_drill_connections_near(surface, position)
			--for _, vault in pairs(find_nearby_vaults(surface, position)) do
			--	vault.update_drill_connections = true
			--end
			dead_bots.queue_drill_update(surface, position)
			
			dead_bots.register_decay(resource)
			
			--local p = position
			--rendering.draw_rectangle{left_top=area[1], right_bottom=area[2], surface=surface, filled=false, color={0,1,0}, time_to_live=60*5}
		end
	end
end

-- chunk based with bounding box optimization
function dead_bots.queue_drill_update(surface, position)
	assert(surface.name == "fulgora")
	
	local key = myutil.chunk_position_key(position)
	local update = storage.update_drill_connections[key] or {}
	
	update.left_top = update.left_top or { x=math.huge, y=math.huge }
	update.right_bottom = update.right_bottom or { x=-math.huge, y=-math.huge }
	
	update.left_top.x = math.min(update.left_top.x, position.x)
	update.left_top.y = math.min(update.left_top.y, position.y)
	update.right_bottom.x = math.max(update.right_bottom.x, position.x)
	update.right_bottom.y = math.max(update.right_bottom.y, position.y)
	
	storage.update_drill_connections[key] = update
end

-- registered in control/events.lua (nth DRILL_CONNECTION_UPDATE_PERIOD)
---@param event NthTickEventData
function dead_bots.update_queued_drill_connections(event)
	--for _,vault in pairs(storage.vaults) do
	--	if vault.update_drill_connections then
	--		for _, drill in pairs(vault.mining_drills) do
	--			if drill.valid then
	--				drill.update_connections()
	--			end
	--		end
	--		vault.update_drill_connections = nil
	--	end
	--end
	
	local surface = game.surfaces["fulgora"]
	local updates = storage.update_drill_connections
	if surface and next(updates) then
		local already_updated = {}
		
		local r = common.max_drill_radius -- square radius!
		local filter = {
			type="mining-drill",
			area = { left_top={}, right_bottom={}}
		}
		
		for chunk_key, update in pairs(updates) do
			filter.area.left_top.x = update.left_top.x - r
			filter.area.left_top.y = update.left_top.y - r
			filter.area.right_bottom.x = update.right_bottom.x + r
			filter.area.right_bottom.y = update.right_bottom.y + r
			
			--rendering.draw_rectangle{left_top=filter.area.left_top, right_bottom=filter.area.right_bottom, surface=surface, filled=false, color={0,1,0}, time_to_live=30}
			
			-- this includes collision box of drill, not really what we want, but I would have added 1 to radius to make sure anyway
			for _,drill in pairs(surface.find_entities_filtered(filter)) do
				local id = drill.unit_number
				if not already_updated[id] then
					--local p = drill.position
					--rendering.draw_rectangle{left_top={p.x-2.5, p.y-2.5}, right_bottom={p.x+2.5, p.y+2.5}, surface=surface, filled=false, color={0,0,1}, time_to_live=30}
					drill.update_connections()
					--drill.disabled_by_script = false
					--drill.disabled_by_script = true
					
					already_updated[id] = true
				end
			end
		end
		
		storage.update_drill_connections = {}
	end
end

-- custom event handlers, registered in control/events.lua
if const.HARVESTABLE_BOTS then -- was const.HARVEST_BOTS (nil, handler never registered)
	-- triggers on custom dying particle landing on land (on oil ocean it creates a splash and does not create a remnant)
	-- manually spawn bit resource that looks like remnant instead of letting engine spawn actual remnant
	---@param event EventData.on_script_trigger_effect
	function dead_bots.on_create_remnant(event)
		local surface = game.get_surface(event.surface_index)
		if surface and surface.name == "fulgora" then
			--init()
			dead_bots.add_dead_bot_resource(surface, event.target_position --[[@as MapPosition]], event.effect_id, 1)
			-- could selectively spawn normal corpse here, but not needed right now
		end
	end
	
	-- Triggers on hostile bot death (either time_to_live expired or killed, or just on killed depending on config)
	-- manually spawn correct dying particle quality variant since engine does not support quality here
	-- (otherwise this would happen automatically via dying_trigger_effect/destroy_action)
	---@param event EventData.on_script_trigger_effect
	function dead_bots.on_bot_died(event)
		local surface = game.get_surface(event.surface_index)
		if surface and surface.name == "fulgora" then
			--init()
			local bot = event.source_entity -- is source_entity always the same as target_entity?
			local pos = bot and bot.position or event.source_position --[[@as MapPosition]]
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
	end
end

--#endregion

--#region dead bot decay

-- Decay dead bot resources via half life (decay half of the amount in DECAY_HALF_LIFE)
-- When spawned and when mining is detected get a protected duration
local DECAY_PROTECTED_MINING = 4*60*60
local DECAY_PROTECTED_CREATE = 1*60*60
local DECAY_PROTECTED_INIT = 20*60
local DECAY_HALF_LIFE = 60*60

---@class DeadBotResource
---@field entity LuaEntity
---@field prev_amount integer -- since last poll (at tick if not protected)
---@field tick MapTick -- protected until tick or tick of last check

---@class PollDecay
---@field resources table<integer, DeadBotResource> -- array with holes
---@field poll StaggerTickState

---@param resource LuaEntity
---@param protected number?
function dead_bots.register_decay(resource, protected)
	local s = storage.poll_decay
	if s then
		table.insert(storage.poll_decay.resources, {
			entity=resource,
			prev_amount=resource.amount,
			tick=game.tick + (protected or DECAY_PROTECTED_CREATE),
		})
	end
end

---@param event EventData.on_tick
function dead_bots.poll_for_decay(event)
	local s = storage.poll_decay
	if s == nil then return end
	
	local cur_tick = event.tick
	
	--if const.DEBUG and (event.tick%60)==0 then
	--	local list_size = table_size(s.resources)
	--	local invalid = 0
	--	local max_idx = 0
	--	for idx,res in pairs(s.resources) do
	--		if not res.entity.valid then invalid = invalid + 1 end
	--		max_idx = math.max(max_idx, idx)
	--	end
	--	
	--	log(dbg_print(string.format("decay resource: current #resources %d invalid %d max_idx %d", list_size, invalid, max_idx)))
	--end
	
	local restarted = myutil.stagger_tick(s.poll, s.resources, 10*60,
		---@param idx integer
		---@param res DeadBotResource
		function(idx, res)
			local entity = res.entity
			if not entity.valid then
				-- delete by setting to nil, stagger_tick handles this fine
				-- swap with last is dodgy as it skip polling for once cycle, so with many invalid entries (regular mining drills mining normally)
				--  we take forever to clear out them out, and most of the table will be invalid entries, so instead just do this and accept holes
				-- (table.insert will fill holes and table_size gives the correct size)
				s.resources[idx] = nil
				return
			end
			
			-- track decrease or increase in each 10sec interval
			local amount = entity.amount
			local amount_delta = amount - res.prev_amount
			res.prev_amount = amount
			
			if amount_delta < 0 then
				-- was mined more than it increased since last poll, make protected
				res.tick = cur_tick + DECAY_PROTECTED_MINING
				return
			end
			-- was not mined or increased more than was mined
			
			local elapsed = cur_tick - res.tick
			if elapsed <= 0 then
				-- still protected
				return
			end
			-- did not decrease since DECAY_PROTECTED_MINING (or increases happened to mask mining perfectly, very unlikely in minute long window)
			
			res.tick = cur_tick
			
			local decayed_amount = amount * 2^(-elapsed / DECAY_HALF_LIFE) -- half life, half is gone after DECAY_HALF_LIFE time
			decayed_amount = common.rand_rounding(decayed_amount)
			assert(decayed_amount <= amount)
			
			if decayed_amount < amount then
				--if const.DEBUG then log(dbg_print(string.format("decay resource: %s %d->%d", serpent.line(entity), amount, decayed_amount))) end
				
				if decayed_amount > 0 then
					entity.amount = decayed_amount
					res.prev_amount = decayed_amount
				else
					entity.destroy{raise_destroy=true} -- raise_destroy because why not(?)
					
					s.resources[idx] = nil
				end
			end
		end
	)
	
	if restarted then -- HACKY, should probably not actually use stagger_tick here and use custom code instead?
		-- compact list, currently holes can really grow it
		local new_list = {}
		local j = 1
		for _,v in pairs(s.resources) do
			new_list[j] = v
			j = j + 1
		end
		s.resources = new_list
	end
end

---@param surface LuaSurface?
function dead_bots.init_decay(surface)
	if not (const.HARVESTABLE_BOTS and common.DECAY_HARVESTABLE_BOTS) then
		storage.poll_decay = nil
		return
	end
	
	if storage.poll_decay then
		return
	end
	
	storage.poll_decay = { resources={}, poll={} }
	
	local resources = surface and surface.find_entities_filtered{type="resource", name=const.DRONE_RES_ALL_NAMES} or {}
	for _,res in pairs(resources) do
		dead_bots.register_decay(res, DECAY_PROTECTED_INIT)
	end
	
	-- shuffle list to avoid visible pattern from find_entities_filtered
	-- (regular additions from drones dying are practically random)
	myutil.shuffle_in_place(storage.poll_decay.resources)
end

--#endregion

return dead_bots
