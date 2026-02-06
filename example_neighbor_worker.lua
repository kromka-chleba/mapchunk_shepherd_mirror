--[[
    Example: Cross-Block Worker Using Block Neighborhood
    
    This demonstrates how to create a worker that can read/write
    nodes across mapblock boundaries. The example shows a moisture
    spreading mechanism that moves water between adjacent blocks.
--]]

-- This example is disabled by default. Uncomment to enable.
local ENABLE_EXAMPLE = false

if not ENABLE_EXAMPLE then
    return
end

local ms = mapchunk_shepherd
local bn = ms.block_neighborhood

-- Example: Moisture spreader that can move water across block boundaries
-- This worker looks for water sources and spreads them to adjacent air nodes,
-- even if those air nodes are in neighboring mapblocks.

local water_id = core.get_content_id("default:water_source")
local air_id = core.get_content_id("air")

-- Register a tag for blocks that might contain spreadable water
ms.tag.register("has_moisture_source")

-- The worker function with neighborhood access
local function moisture_spreader_worker(pos_min, pos_max, vm_data, chance, neighborhood)
    local labels_to_add = {}
    local labels_to_remove = {}
    local modified_focal = false
    
    -- Scan the focal block for water sources
    local water_positions = {}
    local focal_node_min = pos_min
    
    for z = 0, 15 do
        for y = 0, 15 do
            for x = 0, 15 do
                local idx = 1 + z * 16 * 16 + y * 16 + x
                if vm_data.nodes[idx] == water_id then
                    local world_pos = vector.add(focal_node_min, vector.new(x, y, z))
                    table.insert(water_positions, world_pos)
                end
            end
        end
    end
    
    -- For each water source, try to spread to adjacent positions
    local spread_count = 0
    for _, water_pos in ipairs(water_positions) do
        -- Check all 6 adjacent positions (including across boundaries)
        local adjacent = neighborhood:get_adjacent_positions(water_pos)
        
        for _, adj_pos in ipairs(adjacent) do
            local adj_node = neighborhood:read_node(adj_pos)
            
            -- If adjacent is air and we hit our chance threshold, spread water
            if adj_node == air_id and math.random() < (chance or 0.1) then
                -- Write water to the adjacent position (may be in neighbor block!)
                if neighborhood:write_node(adj_pos, water_id) then
                    spread_count = spread_count + 1
                    
                    -- Mark our focal block as modified if the write was internal
                    local block_offset = neighborhood:decompose_position(adj_pos)
                    if block_offset.x == 0 and block_offset.y == 0 and block_offset.z == 0 then
                        modified_focal = true
                    end
                end
            end
        end
    end
    
    -- Update labels based on results
    if spread_count > 0 then
        table.insert(labels_to_add, "has_moisture_source")
        core.log("action", string.format("Moisture spreader: spread water to %d positions", spread_count))
    end
    
    return labels_to_add, labels_to_remove, false, false
end

-- Wrap the worker function to enable neighborhood access
local wrapped_worker_fn = bn.wrap_worker_function(moisture_spreader_worker, true)

-- Create and register the worker
local moisture_worker = ms.worker.new({
    name = "example_moisture_spreader",
    fun = wrapped_worker_fn,
    needed_labels = {"has_moisture_source"},
    work_every = 60,  -- Run every 60 game seconds
    chance = 0.1,     -- 10% chance per water-air pair
})

moisture_worker:register()

core.log("action", "Moisture spreader example worker registered")


--[[
    Alternative Example: Simple node copier across boundaries
    
    This shows a simpler case - copying a node from the edge of
    one block to the edge of the next block.
--]]

local function edge_copier_worker(pos_min, pos_max, vm_data, chance, neighborhood)
    -- Copy the node at +X edge to +X neighbor's -X edge
    local edge_pos = vector.add(pos_min, vector.new(15, 8, 8))  -- Right edge, middle
    local neighbor_pos = vector.add(edge_pos, vector.new(1, 0, 0))  -- One node into neighbor
    
    local edge_node = neighborhood:read_node(edge_pos)
    
    if edge_node and edge_node ~= air_id then
        -- Copy it to the neighbor
        neighborhood:write_node(neighbor_pos, edge_node)
        
        return {"edge_copied"}, {}, false, false
    end
    
    return {}, {}, false, false
end

-- Note: This second example is not registered, just shown for reference
