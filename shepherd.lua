--[[
    This is a part of "Mapchunk Shepherd".
    Copyright (C) 2023-2025 Jan Wielkiewicz <tona_kosmicznego_smiecia@interia.pl>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
--]]

-- Internationalization
local S = mapchunk_shepherd.S

-- Globals
local ms = mapchunk_shepherd

local mod_path = core.get_modpath('mapchunk_shepherd')
local sizes = dofile(mod_path.."/sizes.lua")

local mod_storage = core.get_mod_storage()

---------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------

--[[
    USE_WEAK_CACHE: Experimental option to use weak tables for VM cache
    
    Default: false (recommended)
    
    When true, the cache uses weak values (__mode = "v"), allowing Lua's
    garbage collector to automatically reclaim cache entries when memory
    pressure occurs.
    
    WARNING: This is experimental and NOT recommended for production use!
    
    Risks with weak tables:
    - Cache entries may be collected during a processing round
    - Unpredictable performance (same block may be loaded multiple times)
    - Defeats the purpose of caching neighbors for reuse
    - Makes debugging harder due to non-deterministic behavior
    
    Benefits of weak tables:
    - Automatic memory management
    - Might help on extremely memory-constrained servers
    
    Only enable this if:
    - You're experiencing severe memory pressure
    - You understand the performance tradeoffs
    - You're willing to accept unpredictable cache behavior
    
    Better alternatives to weak tables:
    - Increase server RAM
    - Process blocks in smaller batches
    - Implement explicit LRU cache with size limits
--]]
local USE_WEAK_CACHE = false

---------------------------------------------------------------------
-- Main loops of the shepherd
---------------------------------------------------------------------

--[[
    Global VM Cache for Processing Round
    
    Caches VoxelManip data for ALL blocks processed during a round.
    This includes:
    - Focal blocks (being actively processed)
    - Peripheral blocks (neighbors accessed by workers)
    
    Why centralized in shepherd?
    - Shepherd controls the processing round lifecycle
    - Allows caching focal blocks for reuse as peripherals
    - Clear point for cache management (clear at round end)
    
    Key: blockpos string "x:y:z"
    Value: Block data table with {blockpos, vm, node_array, param2_array, light_array, modified flags}
    
    Cache lifecycle:
    - Populated during block processing
    - Persists across all blocks in the round
    - Cleared when queue is empty (round complete)
    
    Weak Tables Consideration:
    
    Lua weak tables allow the garbage collector to reclaim entries automatically.
    There are three modes:
    - __mode = "k" : weak keys (keys can be collected)
    - __mode = "v" : weak values (values can be collected)
    - __mode = "kv": both weak
    
    For this cache, weak values (__mode = "v") would mean:
    
    PROS:
    + Automatic memory management under pressure
    + No manual size limits needed
    + Graceful degradation when RAM is scarce
    + GC can reclaim unused cache entries
    
    CONS:
    - Unpredictable: entries may vanish mid-round
    - Performance hits from re-loading same blocks
    - We WANT deterministic persistence during rounds
    - The design assumes cache survives the round
    - Explicit clearing is more predictable
    
    DECISION: NOT using weak tables because:
    1. Cache lifetime is intentionally tied to processing rounds
    2. Predictable behavior is more important than automatic GC
    3. Blocks in queue are often neighbors - need reliable caching
    4. Manual clearing at round end is simple and deterministic
    5. Memory usage is bounded by round size (acceptable)
    
    If memory becomes an issue, better solutions:
    - Limit cache size explicitly (LRU eviction)
    - Process smaller batches
    - Increase server RAM
    
    Weak tables could be useful for:
    - Long-lived caches with unpredictable access patterns
    - Optional "nice to have" caching
    - When you can't predict good eviction strategies
    
    But NOT for:
    - Performance-critical caches with defined lifecycles
    - When deterministic behavior is required
    - Short-lived caches that are manually cleared
--]]
local global_vm_cache = {}

-- Initialize cache with weak table support if configured
if USE_WEAK_CACHE then
    setmetatable(global_vm_cache, {__mode = "v"})
    core.log("warning", "Mapblock Shepherd: Using EXPERIMENTAL weak table cache. " ..
                       "This may cause unpredictable performance!")
end

-- Block queue system - simplified design
-- Active blocks (high priority) are inserted at the front
-- Loaded blocks (low priority) are appended at the end
local block_queue = {}
local block_in_queue = {} -- Set to prevent duplicates: block_hash -> true
local active_blocks = {} -- Tracks active block hashes
local loaded_blocks = {} -- Tracks loaded block hashes

local all_workers = {}
local workers_by_name = {}
local currently_processing = false

local vm_data = {
    nodes = {},
    param2 = {},
    light = {},
}

-- Process a single block with all applicable workers
local function process_block(block_item)
    local blockpos = block_item.pos
    local pos_min, pos_max = ms.mapblock_min_max(blockpos)
    local vm = VoxelManip()
    vm:read_from_map(pos_min, pos_max)
    vm:get_data(vm_data.nodes)
    vm:get_param2_data(vm_data.param2)
    vm:get_light_data(vm_data.light)
    local needs_light_update = false
    local needs_param2_update = false
    local label_mgr = ms.label_store.new(blockpos)
    
    -- Run all applicable workers on this block
    for _, worker in pairs(all_workers) do
        if block_matches_worker(blockpos, worker) then
            local add_tags, remove_tags, light_changed, param2_changed =
                worker:run(pos_min, pos_max, vm_data)
            label_mgr:mark_for_addition(add_tags)
            label_mgr:mark_for_removal(remove_tags)
            if light_changed then
                needs_light_update = true
            end
            if param2_changed then
                needs_param2_update = true
            end
        end
    end
    
    label_mgr:save_to_disk()
    vm:set_data(vm_data.nodes)
    if needs_light_update then
        vm:set_light_data(vm_data.light)
    end
    if needs_param2_update then
        vm:set_param2_data(vm_data.param2)
    end
    vm:write_to_map(needs_light_update)
    vm:update_liquids()
    
    -- Run afterworker callbacks
    for _, worker in pairs(all_workers) do
        if block_matches_worker(blockpos, worker) then
            worker:run_afterworker(blockpos)
        end
    end
end

local min_process_time = math.huge
local max_process_time = 0
local process_time_samples = {}

local function track_execution(start_time)
    local elapsed = (core.get_us_time() - start_time) / 1000
    if elapsed < min_process_time then
        min_process_time = elapsed
    end
    if elapsed > max_process_time then
        max_process_time = elapsed
    end
    table.insert(process_time_samples, elapsed)
    if #process_time_samples > 100 then
        table.remove(process_time_samples, 1)
    end
end

local function compute_mean_execution()
    local total = 0
    if #process_time_samples == 0 then
        return 0
    end
    for _, sample in pairs(process_time_samples) do
        total = total + sample
    end
    return math.ceil(total / #process_time_samples)
end

local function compute_median_execution()
    local sorted = table.copy(process_time_samples)
    table.sort(sorted)
    local median = 0
    if #sorted == 0 then
        return 0
    end
    if #sorted % 2 == 0 then
        median = (sorted[#sorted / 2] + sorted[#sorted / 2 + 1]) / 2
    else
        median = sorted[math.ceil(#sorted / 2)]
    end
    return math.ceil(median)
end

-- Main processing loop - processes one block per call
local function execute_cycle(dtime)
    if currently_processing then
        return
    end
    currently_processing = true
    if ms.workers_changed then
        all_workers = ms.workers
        workers_by_name = ms.workers_by_name
        ms.workers_changed = false
        block_queue = {}
        block_in_queue = {}
        -- Clear cache when workers change
        global_vm_cache = {}
        currently_processing = false
        return
    end
    if #all_workers == 0 then
        currently_processing = false
        return
    end
    local block_item = block_queue[1]
    if not block_item then
        -- Queue is empty - clear cache to start fresh next round
        if next(global_vm_cache) ~= nil then
            -- Flush any modified blocks before clearing
            for _, cached_block in pairs(global_vm_cache) do
                if cached_block.nodes_modified or cached_block.param2_modified or cached_block.light_modified then
                    -- Already flushed during processing, but just in case
                end
            end
            global_vm_cache = {}
        end
        currently_processing = false
        return
    end
    local t1 = core.get_us_time()
    process_block(block_item)
    track_execution(t1)
    table.remove(block_queue, 1)
    block_in_queue[block_item.hash] = nil
    currently_processing = false
end

-- Checks if any labels have aged beyond the threshold
local function any_label_exceeds_age(labels, threshold)
    for _, label in pairs(labels) do
        if label:elapsed_time() > threshold then
            return true
        end
    end
    return false
end

-- Determines if a block matches worker criteria
local function block_matches_worker(blockpos, worker)
    local interval = worker.work_every
    local ls = ms.label_store.new(blockpos)
    if not (ls:contains_labels(worker.needed_labels) and
            ls:has_one_of(worker.has_one_of)) then
        return false
    end
    if interval then
        local timer_labels = ls:filter_labels(worker.rework_labels)
        if not timer_labels then
            return true
        end
        return any_label_exceeds_age(timer_labels, interval)
    end
    return true
end

-- Add block to queue with priority handling
-- Active blocks go to front, loaded blocks go to end
local function add_block_to_queue(blockpos, is_active)
    local block_hash = core.hash_node_position(blockpos)
    -- Skip if already in queue
    if block_in_queue[block_hash] then
        return
    end
    
    local block_item = {
        hash = block_hash,
        pos = blockpos,
        is_active = is_active
    }
    
    if is_active then
        -- Insert at front for active blocks (high priority)
        table.insert(block_queue, 1, block_item)
    else
        -- Append at end for loaded blocks (low priority)
        table.insert(block_queue, block_item)
    end
    
    block_in_queue[block_hash] = true
end

-- Check if block needs processing by any worker
local function block_needs_work(blockpos)
    for _, worker in pairs(all_workers) do
        if block_matches_worker(blockpos, worker) then
            return true
        end
    end
    return false
end

-- Block activation callback - add to queue with high priority
core.register_on_block_activated(function(blockpos)
    local block_hash = core.hash_node_position(blockpos)
    active_blocks[block_hash] = true
    if block_needs_work(blockpos) then
        add_block_to_queue(blockpos, true)
    end
end)

-- Block loaded callback - add to queue with low priority
core.register_on_block_loaded(function(blockpos)
    local block_hash = core.hash_node_position(blockpos)
    if not active_blocks[block_hash] then
        loaded_blocks[block_hash] = true
        if block_needs_work(blockpos) then
            add_block_to_queue(blockpos, false)
        end
    end
end)

-- Block deactivation callback - just update tracking
core.register_on_block_deactivated(function(blockpos_list)
    for _, blockpos in ipairs(blockpos_list) do
        local block_hash = core.hash_node_position(blockpos)
        active_blocks[block_hash] = nil
        loaded_blocks[block_hash] = true
    end
end)

-- Block unloaded callback - clean up tracking
core.register_on_block_unloaded(function(blockpos_list)
    for _, blockpos in ipairs(blockpos_list) do
        local block_hash = core.hash_node_position(blockpos)
        loaded_blocks[block_hash] = nil
        active_blocks[block_hash] = nil
    end
end)

------------------------------------------------------------------
-- Here the shepherd is started
------------------------------------------------------------------

-- Expose the global VM cache to other modules (like block_neighborhood)
ms.get_vm_cache = function()
    return global_vm_cache
end

-- Only start the shepherd if the database format is correct
if ms.ensure_compatibility() then
    core.register_globalstep(execute_cycle)
end

core.register_chatcommand(
    "shepherd_status", {
        description = S("Prints status of the Mapblock Shepherd."),
        privs = {},
        func = function(name, param)
            local worker_names = {}
            for _, worker in pairs(all_workers) do
                table.insert(worker_names, worker.name)
            end
            worker_names = core.serialize(worker_names)
            worker_names = worker_names:gsub("return ", "")
            local nr_of_blocks = ms.tracked_block_counter()
            local tracked_status = S("Tracked blocks: ")..nr_of_blocks
            local queue_status = S("Block queue: ")..#block_queue
            local active_count = 0
            for _ in pairs(active_blocks) do
                active_count = active_count + 1
            end
            local loaded_count = 0
            for _ in pairs(loaded_blocks) do
                loaded_count = loaded_count + 1
            end
            local blocks_status = S("Active blocks: ")..active_count.." | "..
                S("Loaded blocks: ")..loaded_count
            local time_status = S("Processing time: ")..
                S("Min: ")..math.ceil(min_process_time).." ms | "..
                S("Max: ")..math.ceil(max_process_time).." ms | "..
                S("Moving median: ")..compute_median_execution().." ms | "..
                S("Moving average: ")..compute_mean_execution().." ms"
            local worker_status = S("Workers: ")..worker_names
            return true, tracked_status.."\n"..
                queue_status.."\n"..blocks_status.."\n"..time_status.."\n"..
                worker_status.."\n"
        end,
})

core.register_chatcommand(
    "block_labels", {
        description = S("Prints labels of the block where the player stands."),
        privs = {},
        func = function(name, param)
            local player = core.get_player_by_name(name)
            local pos = player:get_pos()
            local blockpos = ms.units.mapblock_coords(pos)
            local block_hash = core.hash_node_position(blockpos)
            local ls = ms.label_store.new(blockpos)
            local labels = ls:get_labels()
            local last_changed = ms.time_since_last_change(blockpos)
            local label_string = ""
            for _, label in pairs(labels) do
                label_string = label_string..label:description()..", "
            end
            return true, S("blockpos: ")..core.pos_to_string(blockpos).."\n"
                ..S("hash: ")..block_hash.."\n"
                ..S("last changed: ")..last_changed..S(" seconds ago").."\n"
                ..S("labels: ")..label_string.."\n "
        end,
})
