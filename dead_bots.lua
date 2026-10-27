local g = require("common")
---@class Vault
local Vault = require("vault")

-- This is super dodgy, if there are modded drills with high radius we may miss to update them (they won't mine the newly added bot resource)
local max_drill_radius = 0
for _,drill in pairs(prototypes.get_entity_filtered{{filter="type", type="mining-drill"}}) do
	for quality,_ in pairs(prototypes.quality) do
		local radius = drill.get_mining_drill_radius(quality)
		if radius > max_drill_radius then max_drill_radius = radius end
	end
end

local dead_bots = {}

-- TODO: quality support, I think I'll have to add quality variants manually
---@param surface LuaSurface
---@param position MapPosition
---@param type string
function dead_bots.add_dead_bot_resource(surface, position, type, count)
	--TODO: check for oil ocean etc?
	
	position = { x=math.floor(position.x)+0.5, y=math.floor(position.y)+0.5 } -- find_entity doesn't seem to work with floored ints, unless rounding to 0.5 centers?
	
	local resource = surface.find_entity("resource-dead-"..type, position)
	if resource then
		-- existing resource, increase amount
		resource.amount = resource.amount + count
		
		local p = resource.position
		--rendering.draw_rectangle{left_top={p.x-0.5, p.y-0.5}, right_bottom={p.x+0.5, p.y+0.5}, surface=surface, filled=false, color={0,0,1}, time_to_live=60*5}
	else
		resource = surface.create_entity{name="resource-dead-"..type, position=position, snap_to_grid=true,
			--quality = "rare", -- test
			raise_built=true,
			preserve_ghosts_and_corpses=true, -- ??
		}
		if resource then
			resource.amount = count
			
			local r = max_drill_radius -- square radius!
			local area = {{position.x-r, position.y-r},
			              {position.x+r, position.y+r}}
			-- this includes collision box of drill, not really what we want, but I would have added 1 to radius to make sure anyway
			for _,drill in pairs(surface.find_entities_filtered{area=area, type="mining-drill"}) do
				--local p = drill.position
				--rendering.draw_rectangle{left_top={p.x-2.5, p.y-2.5}, right_bottom={p.x+2.5, p.y+2.5}, surface=surface, filled=false, color={0,0,1}, time_to_live=60*5}
				drill.update_connections()
			end
			
			--local p = position
			--rendering.draw_rectangle{left_top=area[1], right_bottom=area[2], surface=surface, filled=false, color={0,1,0}, time_to_live=60*5}
		end
	end
end

return dead_bots
