local const = require("const")
---@class Vault

local M = {}

---@param original_fulgora LuaSurface
---@param where MapPosition|"all"
---@param radius? number
---@return LuaSurface
function M.recreate_initial_surface_and_load_chunks(original_fulgora, where, radius)
	--game.print("regenerating fulgora entities, please be patient...") obviously this won't be seen until this is done
	
	-- lazy create surface
	local fake_surface = game.surfaces["hexcoder_fake_fulgora"]
	if fake_surface == nil then
		fake_surface = game.create_surface("hexcoder_fake_fulgora", original_fulgora.map_gen_settings)
	end
	
	-- A later find_entities_filtered won't generate chunks for us (I think?)
	if where == "all" then
		for cpos in original_fulgora.get_chunks() do
			if original_fulgora.is_chunk_generated(cpos) then
				fake_surface.request_to_generate_chunks({ cpos.x*32+16, cpos.y*32+16 })
			end
		end
	else
		fake_surface.request_to_generate_chunks(where, radius/32+1)
	end
	fake_surface.force_generate_chunk_requests()
	
	--local test = {}
	--for cpos in fake_surface.get_chunks() do
	--	if fake_surface.is_chunk_generated(cpos) then
	--		table.insert(test, cpos)
	--	end
	--end

	-- do not delete fake fulgora in case multiple requests are made
	-- hopefully better perf? and safer?
	-- actually queued to be deleted, so multiple requests should be fine, maybe just worse perf if used every few seconds
	storage.last_used_fake_fulgora = game.tick

	if const.DEBUG then
		game.print("Created fake fulgora")
	end
	return fake_surface
end
script.on_nth_tick(60, function(event)
	local last_use = storage.last_used_fake_fulgora
	if last_use and event.tick - last_use > 11*60 then
		game.delete_surface("hexcoder_fake_fulgora")
		storage.last_used_fake_fulgora = nil
		
		if const.DEBUG then
			game.print("Deleted fake fulgora")
		end
	end
end)

return M
