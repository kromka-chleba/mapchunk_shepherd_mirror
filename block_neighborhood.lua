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

--[[
    Configuration Constants
    
    BLOCK_DIMENSION: Luanti's fixed mapblock size (16x16x16 nodes)
    
    RETENTION_POOL_SIZE: Maximum number of peripheral blocks to cache (10)
    
    Why 10 blocks?
    - Most workers access only 1-3 neighbors (e.g., moisture spreading to adjacent faces)
    - Complex workers (terrain smoothing) might access up to 6 neighbors (all faces)
    - Extreme cases (particle systems) could access 8 corners or 12 edges
    - Setting to 10 provides headroom above typical usage without excessive memory
    - Each cached block holds ~16KB of data (4096 nodes × 4 bytes/ID)
    - 10 blocks = ~160KB total cache, acceptable for most servers
    - Higher values risk memory pressure; lower values cause thrashing
    - Tuned based on expected worker access patterns in shepherd use cases
--]]
local BLOCK_DIMENSION = 16
local RETENTION_POOL_SIZE = 10
local NEIGHBOR_OFFSETS = {}

--[[
    Pre-compute the 26 neighbor offset vectors
    
    A mapblock has 26 neighbors in a 3x3x3 cube (excluding the center block itself):
    - 6 face neighbors (±X, ±Y, ±Z)
    - 12 edge neighbors (combinations of 2 axes)
    - 8 corner neighbors (combinations of all 3 axes)
    
    These offsets are used to validate neighbor access and could be extended
    for future features like "preload all face neighbors" optimizations.
--]]
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

--[[
    blockpos_key: Convert block position to string key for table lookups
    
    Purpose: Creates a unique string identifier for each block position
    Format: "x:y:z" (e.g., "5:10:-3")
    
    Why not use core.hash_node_position()?
    - That's for the public API (shepherd system uses it)
    - This is internal to neighborhood tracking
    - String keys are more debuggable and don't conflict with shepherd's hashing
    
    Parameters:
        bpos: Block position vector {x, y, z}
    Returns:
        String key suitable for table indexing
--]]
local function blockpos_key(bpos)
    return string.format("%d:%d:%d", bpos.x, bpos.y, bpos.z)
end

--[[
    PeripheralBlock: Represents a single neighbor mapblock
    
    Responsibilities:
    - Load VoxelManip data for a specific neighbor block
    - Track which data arrays have been modified
    - Flush changes back to the map when evicted or committed
    - Track access time for LRU eviction
    
    Why separate class?
    - Encapsulates the complex VoxelManip lifecycle
    - Enables clean tracking of dirty state per block
    - Simplifies the main BlockNeighborhood logic
--]]
local PeripheralBlock = {}
PeripheralBlock.__index = PeripheralBlock

--[[
    PeripheralBlock.load: Create and initialize a peripheral block
    
    Process:
    1. Calculate world node positions from block coordinates
    2. Create VoxelManip and read the block from the map
    3. Extract node, param2, and light data into arrays
    4. Initialize modification tracking flags
    
    Performance note: This is the expensive operation (disk I/O + decompression)
    That's why we cache loaded blocks in the retention pool.
    
    Parameters:
        blockpos: Block position in block coordinates (not node coordinates)
    Returns:
        Initialized PeripheralBlock object
--]]
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

--[[
    PeripheralBlock:mark_dirty: Flag that data has been modified
    
    Purpose: Track which data arrays need to be written back to the map
    This allows us to only write what changed, not all three arrays every time.
    
    Also updates last_access_tick to prevent premature eviction of blocks
    being actively modified.
    
    Parameters:
        data_type: "nodes", "param2", or "light"
--]]
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

--[[
    PeripheralBlock:flush_changes: Write modifications back to the map
    
    Process:
    1. Check if anything was modified (early exit if not)
    2. Set only the modified data arrays back to the VoxelManip
    3. Write the VoxelManip to the map
    4. Update liquid flow if needed
    
    Called when:
    - Block is evicted from retention pool
    - Worker calls commit_all() at the end
    - Manual flush requested
    
    Returns:
        true if changes were flushed, false if nothing was modified
--]]
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

--[[
    BlockNeighborhood: Main API for cross-block operations
    
    This is the primary interface workers use to access nodes across boundaries.
    
    Key features:
    - Transparent access to focal block and neighbors using world coordinates
    - Lazy loading: neighbors only loaded when first accessed
    - LRU caching: keeps recently-used neighbors in memory
    - Automatic flushing: writes changes when blocks are evicted
    
    Design rationale:
    - Workers shouldn't need to know about block boundaries
    - World coordinates are more intuitive than managing multiple VoxelManips
    - Caching prevents repeated expensive loads for the same neighbor
--]]
local BlockNeighborhood = {}
BlockNeighborhood.__index = BlockNeighborhood

--[[
    BlockNeighborhood.new: Create a neighborhood accessor
    
    Parameters:
        primary_blockpos: Block coordinates of the focal block (worker's target)
        primary_vm_data: Optional reference to the focal block's existing vm_data
                        from the shepherd (avoids redundant array creation)
    
    The focal block's data is never loaded separately - we use the shepherd's
    existing arrays for efficiency. Only peripheral neighbors are loaded on demand.
    
    Returns:
        Initialized BlockNeighborhood object
--]]
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

--[[
    BlockNeighborhood:decompose_position: Convert world pos to block + local index
    
    Critical function for coordinate transformation!
    
    Takes a world node position and determines:
    1. Which block it belongs to (relative to focal block)
    2. The flat array index within that block
    
    Algorithm:
    - Calculate position relative to focal block's minimum corner
    - Divide by BLOCK_DIMENSION to get block offset (-1,0,1 in each axis)
    - Take modulo to get local position within that block (0-15)
    - Convert 3D local position to flat array index using ZYX ordering
    
    Why ZYX order?
    - Matches Luanti's VoxelManip internal ordering
    - Z varies slowest, X varies fastest
    - Index = z*256 + y*16 + x (for 16x16x16 blocks)
    
    Parameters:
        world_pos: Absolute node position in the world
    
    Returns:
        block_offset: Vector showing which neighbor (-1,0,1 per axis)
        flat_idx: 1-based array index into that block's data (1-4096)
--]]
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

--[[
    BlockNeighborhood:ensure_peripheral: Load neighbor block if not already cached
    
    Implements the lazy loading + LRU caching strategy.
    
    Flow:
    1. Check if this is actually the focal block (return nil if so)
    2. Check if already in cache (update access time and return)
    3. If cache is full, evict the least-recently-used block
    4. Load the new peripheral block
    5. Add to cache and access tracking
    
    LRU Eviction:
    - access_order array maintains insertion/access order
    - Oldest entry is always at index 1
    - When full, remove from front and flush that block's changes
    - New accesses are appended to the end
    
    Why LRU (Least Recently Used)?
    - Workers often access nearby neighbors repeatedly
    - Recently accessed blocks are more likely to be accessed again
    - Simpler than frequency-based algorithms
    - Performs well for typical worker patterns
    
    Parameters:
        block_offset: Offset from focal block (-1,0,1 per axis)
    
    Returns:
        PeripheralBlock object, or nil if this is the focal block
--]]
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
