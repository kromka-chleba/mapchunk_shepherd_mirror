--[[
    Block Neighborhood - Multi-Block Voxel Accessor for Mapblock Shepherd
    Copyright (C) 2026 Jan Wielkiewicz <tona_kosmicznego_smiecia@interia.pl>
    
    This abstraction enables workers to read/write across mapblock boundaries
    by providing lazy-loaded access to neighboring blocks with smart caching.
    
    Design Philosophy:
    - Primary block: The worker's main target (always loaded)
    - Peripheral blocks: Up to 26 neighbors (loaded on-demand)
    - Retention pool: Keeps recently used peripherals cached
    - Unified coordinates: Seamless access across boundaries
--]]

local ms = mapchunk_shepherd

-- Module table
ms.block_neighborhood = {}
local bn = ms.block_neighborhood

-- Configuration
local BLOCK_DIMENSION = 16  -- nodes per block edge
local RETENTION_POOL_SIZE = 10  -- max cached peripheral blocks
local NEIGHBOR_OFFSETS = {}  -- computed below

-- Pre-compute the 26 neighbor offset vectors (3x3x3 cube minus center)
do
    local offset_idx = 1
    for dx = -1, 1 do
        for dy = -1, 1 do
            for dz = -1, 1 do
                if not (dx == 0 and dy == 0 and dz == 0) then
                    NEIGHBOR_OFFSETS[offset_idx] = vector.new(dx, dy, dz)
                    offset_idx = offset_idx + 1
                end
            end
        end
    end
end

-- Hash function for block positions (different from main shepherd hash)
local function blockpos_key(bpos)
    return string.format("%d:%d:%d", bpos.x, bpos.y, bpos.z)
end

-- Peripheral block tracker
local PeripheralBlock = {}
PeripheralBlock.__index = PeripheralBlock

function PeripheralBlock.load(blockpos)
    local self = setmetatable({}, PeripheralBlock)
    self.blockpos = blockpos
    self.key = blockpos_key(blockpos)
    
    -- Calculate world positions for this block
    local node_min = vector.multiply(blockpos, BLOCK_DIMENSION)
    local node_max = vector.add(node_min, BLOCK_DIMENSION - 1)
    
    -- Create and populate voxel manipulator
    self.vmanip = VoxelManip()
    self.actual_min, self.actual_max = self.vmanip:read_from_map(node_min, node_max)
    
    -- Storage for manipulated data
    self.node_array = {}
    self.param2_array = {}
    self.light_array = {}
    
    self.vmanip:get_data(self.node_array)
    self.vmanip:get_param2_data(self.param2_array)
    self.vmanip:get_light_data(self.light_array)
    
    -- Track modifications
    self.nodes_modified = false
    self.param2_modified = false
    self.light_modified = false
    
    self.last_access_tick = os.clock()
    
    return self
end

function PeripheralBlock:mark_dirty(data_type)
    if data_type == "nodes" then
        self.nodes_modified = true
    elseif data_type == "param2" then
        self.param2_modified = true
    elseif data_type == "light" then
        self.light_modified = true
    end
    self.last_access_tick = os.clock()
end

function PeripheralBlock:flush_changes()
    if not (self.nodes_modified or self.param2_modified or self.light_modified) then
        return false
    end
    
    if self.nodes_modified then
        self.vmanip:set_data(self.node_array)
    end
    if self.param2_modified then
        self.vmanip:set_param2_data(self.param2_array)
    end
    if self.light_modified then
        self.vmanip:set_light_data(self.light_array)
    end
    
    self.vmanip:write_to_map(self.light_modified)
    self.vmanip:update_liquids()
    
    return true
end

-- Main neighborhood accessor
local BlockNeighborhood = {}
BlockNeighborhood.__index = BlockNeighborhood

-- Create a neighborhood accessor centered on a primary block
-- primary_blockpos: The focal block coordinates
-- primary_vm_data: Existing vm_data table from shepherd (optional, for efficiency)
function BlockNeighborhood.new(primary_blockpos, primary_vm_data)
    local self = setmetatable({}, BlockNeighborhood)
    
    self.focal_blockpos = primary_blockpos
    self.focal_key = blockpos_key(primary_blockpos)
    
    -- Store reference to primary block's data
    self.focal_node_data = primary_vm_data and primary_vm_data.nodes or nil
    self.focal_param2_data = primary_vm_data and primary_vm_data.param2 or nil
    self.focal_light_data = primary_vm_data and primary_vm_data.light or nil
    
    -- Peripheral block storage
    self.peripherals = {}  -- key -> PeripheralBlock
    self.access_order = {}  -- for LRU tracking
    
    return self
end

-- Convert world node position to (block_offset, local_index)
function BlockNeighborhood:decompose_position(world_pos)
    local focal_node_min = vector.multiply(self.focal_blockpos, BLOCK_DIMENSION)
    local relative = vector.subtract(world_pos, focal_node_min)
    
    -- Determine which block this falls into
    local block_offset = vector.new(
        math.floor(relative.x / BLOCK_DIMENSION),
        math.floor(relative.y / BLOCK_DIMENSION),
        math.floor(relative.z / BLOCK_DIMENSION)
    )
    
    -- Local position within that block
    local local_pos = vector.new(
        relative.x % BLOCK_DIMENSION,
        relative.y % BLOCK_DIMENSION,
        relative.z % BLOCK_DIMENSION)
    
    -- Convert to flat array index (ZYX order, 0-based to 1-based)
    local flat_idx = 1 + local_pos.z * BLOCK_DIMENSION * BLOCK_DIMENSION +
                        local_pos.y * BLOCK_DIMENSION +
                        local_pos.x
    
    return block_offset, flat_idx
end

-- Ensure a peripheral block is loaded
function BlockNeighborhood:ensure_peripheral(block_offset)
    if block_offset.x == 0 and block_offset.y == 0 and block_offset.z == 0 then
        return nil  -- This is the focal block, not peripheral
    end
    
    local target_blockpos = vector.add(self.focal_blockpos, block_offset)
    local key = blockpos_key(target_blockpos)
    
    -- Already loaded?
    if self.peripherals[key] then
        self.peripherals[key].last_access_tick = os.clock()
        return self.peripherals[key]
    end
    
    -- Enforce retention pool limit
    if #self.access_order >= RETENTION_POOL_SIZE then
        -- Evict oldest
        local oldest_key = table.remove(self.access_order, 1)
        if self.peripherals[oldest_key] then
            self.peripherals[oldest_key]:flush_changes()
            self.peripherals[oldest_key] = nil
        end
    end
    
    -- Load new peripheral
    local periph = PeripheralBlock.load(target_blockpos)
    self.peripherals[key] = periph
    table.insert(self.access_order, key)
    
    return periph
end

-- Read a node at world position
function BlockNeighborhood:read_node(world_pos)
    local block_offset, idx = self:decompose_position(world_pos)
    
    -- Focal block?
    if block_offset.x == 0 and block_offset.y == 0 and block_offset.z == 0 then
        if self.focal_node_data then
            return self.focal_node_data[idx]
        end
        return nil
    end
    
    -- Peripheral block
    local periph = self:ensure_peripheral(block_offset)
    return periph and periph.node_array[idx] or nil
end

-- Write a node at world position
function BlockNeighborhood:write_node(world_pos, node_id)
    local block_offset, idx = self:decompose_position(world_pos)
    
    -- Focal block?
    if block_offset.x == 0 and block_offset.y == 0 and block_offset.z == 0 then
        if self.focal_node_data then
            self.focal_node_data[idx] = node_id
            return true
        end
        return false
    end
    
    -- Peripheral block
    local periph = self:ensure_peripheral(block_offset)
    if periph then
        periph.node_array[idx] = node_id
        periph:mark_dirty("nodes")
        return true
    end
    return false
end

-- Read param2 at world position
function BlockNeighborhood:read_param2(world_pos)
    local block_offset, idx = self:decompose_position(world_pos)
    
    if block_offset.x == 0 and block_offset.y == 0 and block_offset.z == 0 then
        if self.focal_param2_data then
            return self.focal_param2_data[idx]
        end
        return nil
    end
    
    local periph = self:ensure_peripheral(block_offset)
    return periph and periph.param2_array[idx] or nil
end

-- Write param2 at world position
function BlockNeighborhood:write_param2(world_pos, param2_val)
    local block_offset, idx = self:decompose_position(world_pos)
    
    if block_offset.x == 0 and block_offset.y == 0 and block_offset.z == 0 then
        if self.focal_param2_data then
            self.focal_param2_data[idx] = param2_val
            return true
        end
        return false
    end
    
    local periph = self:ensure_peripheral(block_offset)
    if periph then
        periph.param2_array[idx] = param2_val
        periph:mark_dirty("param2")
        return true
    end
    return false
end

-- Finalize - flush all modified peripherals
function BlockNeighborhood:commit_all()
    local flushed_count = 0
    for _, periph in pairs(self.peripherals) do
        if periph:flush_changes() then
            flushed_count = flushed_count + 1
        end
    end
    return flushed_count
end

-- Helper: Get all 6 directly adjacent positions (for moisture spread, etc.)
function BlockNeighborhood:get_adjacent_positions(center_pos)
    return {
        vector.add(center_pos, vector.new(1, 0, 0)),
        vector.add(center_pos, vector.new(-1, 0, 0)),
        vector.add(center_pos, vector.new(0, 1, 0)),
        vector.add(center_pos, vector.new(0, -1, 0)),
        vector.add(center_pos, vector.new(0, 0, 1)),
        vector.add(center_pos, vector.new(0, 0, -1)),
    }
end

-- Export the constructor
function bn.create(primary_blockpos, primary_vm_data)
    return BlockNeighborhood.new(primary_blockpos, primary_vm_data)
end

-- Convenience wrapper for workers that need neighbor access
-- Creates a neighborhood-aware worker function
function bn.wrap_worker_function(worker_fn, needs_neighbors)
    if not needs_neighbors then
        return worker_fn  -- No wrapping needed
    end
    
    return function(pos_min, pos_max, vm_data, chance)
        local blockpos = ms.units.mapblock_coords(pos_min)
        local neighborhood = bn.create(blockpos, vm_data)
        
        -- Call original worker with neighborhood accessor
        local add_labels, remove_labels, light_changed, param2_changed = 
            worker_fn(pos_min, pos_max, vm_data, chance, neighborhood)
        
        -- Commit any neighbor modifications
        neighborhood:commit_all()
        
        return add_labels, remove_labels, light_changed, param2_changed
    end
end

return bn
