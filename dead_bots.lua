local ore = require("ore_tracking")

local dead_bots = {}

-- TODO: quality support, I think I'll have to add quality variants manually
---@param surface LuaSurface
---@param position MapPosition
---@param res_name string
function dead_bots.add_dead_bot_resource(surface, position, res_name, count)
	--TODO: check for oil ocean etc?
	
	position = { x=math.floor(position.x)+0.5, y=math.floor(position.y)+0.5 } -- find_entity doesn't seem to work with floored ints, unless rounding to 0.5 centers?
	
	local resource = surface.find_entity(res_name, position)
	if resource then
		-- existing resource, increase amount
		resource.amount = resource.amount + count
		
		local p = resource.position
		--rendering.draw_rectangle{left_top={p.x-0.5, p.y-0.5}, right_bottom={p.x+0.5, p.y+0.5}, surface=surface, filled=false, color={0,0,1}, time_to_live=60*5}
	--else
	-- not really needed resource no longer deletes cliffs due to cliff_removal_probability,
	-- but probably still don't want to spawn under cliff
	elseif surface.count_entities_filtered{position=position, collision_mask="cliff"} == 0 then
		
		resource = surface.create_entity{name=res_name, position=position, snap_to_grid=true,
			--quality = "rare", -- test
			--raise_built=true,
			preserve_ghosts_and_corpses=true, -- ??
		}
		if resource then
			resource.amount = count
			
			ore.update_drill_connections_near(surface, position)
			
			--local p = position
			--rendering.draw_rectangle{left_top=area[1], right_bottom=area[2], surface=surface, filled=false, color={0,1,0}, time_to_live=60*5}
		end
	end
end

return dead_bots
