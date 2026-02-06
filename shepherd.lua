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
-- Main loops of the shepherd
---------------------------------------------------------------------

local processing_queue = {}
local active_registry = {}
local loaded_registry = {}

local cycle_delay = 2
local previous_cycle_failed = false
local fast_cycle = 0.005

local worker_registry = {}
local workers_indexed = {}
local worker_busy = false

local function release_worker()
    worker_busy = false
end

local voxel_cache = {
    nodes = {},
    param2 = {},
    light = {},
}

-- Executes workers on a single mapblock using VoxelManipulator
local function execute_block(work_item)
    local blockpos = work_item.blockpos
    local block_hash = work_item.block_hash
    local pos_min, pos_max = ms.mapblock_min_max(blockpos)
    local vm = VoxelManip()
    vm:read_from_map(pos_min, pos_max)
    vm:get_data(voxel_cache.nodes)
    vm:get_param2_data(voxel_cache.param2)
    vm:get_light_data(voxel_cache.light)
    local light_dirty = false
    local param2_dirty = false
    local ls = ms.label_store.new(block_hash, blockpos)
    for worker_id, _ in pairs(work_item.workers) do
        local worker = workers_indexed[worker_id]
        local added_tags, removed_tags, light_mod, param2_mod =
            worker:run(pos_min, pos_max, voxel_cache)
        ls:mark_for_addition(added_tags)
        ls:mark_for_removal(removed_tags)
        if light_mod then
            light_dirty = true
        end
        if param2_mod then
            param2_dirty = true
        end
    end
    ls:save_to_disk()
    vm:set_data(voxel_cache.nodes)
    if light_dirty then
        vm:set_light_data(voxel_cache.light)
    end
    if param2_dirty then
        vm:set_param2_data(voxel_cache.param2)
    end
    vm:write_to_map(light_dirty)
    vm:update_liquids()
    for worker_id, _ in pairs(work_item.workers) do
        local worker = workers_indexed[worker_id]
        worker:run_afterworker(block_hash, blockpos)
    end
end

local shortest_execution = math.huge
local longest_execution = 0
local execution_samples = {}

local function track_execution(start_time)
    local elapsed = (core.get_us_time() - start_time) / 1000
    if elapsed < shortest_execution then
        shortest_execution = elapsed
    end
    if elapsed > longest_execution then
        longest_execution = elapsed
    end
    table.insert(execution_samples, elapsed)
    if #execution_samples > 100 then
        table.remove(execution_samples, 1)
    end
end

local function compute_mean_execution()
    local total = 0
    if #execution_samples == 0 then
        return 0
    end
    for _, sample in pairs(execution_samples) do
        total = total + sample
    end
    return math.ceil(total / #execution_samples)
end

local function compute_median_execution()
    local sorted = table.copy(execution_samples)
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

-- Main worker execution cycle
local function execute_cycle(dtime)
    if worker_busy then
        return
    end
    worker_busy = true
    if ms.workers_changed then
        worker_registry = ms.workers
        workers_indexed = ms.workers_by_name
        ms.workers_changed = false
        processing_queue = {}
        core.after(cycle_delay, release_worker)
        return
    end
    if #worker_registry == 0 then
        core.after(cycle_delay, release_worker)
        return
    end
    local work_item = processing_queue[1]
    if not work_item then
        core.after(fast_cycle, release_worker)
        return
    end
    local t1 = core.get_us_time()
    execute_block(work_item)
    track_execution(t1)
    table.remove(processing_queue, 1)
    worker_busy = false
end

-- Enqueues a mapblock for processing by specific worker
local function enqueue_block(block_hash, blockpos, worker_id, priority_level)
    for idx, item in pairs(processing_queue) do
        if item.block_hash == block_hash then
            item.workers[worker_id] = true
            -- Update priority if needed
            if priority_level == "active" and item.priority ~= "active" then
                item.priority = "active"
                -- Move to front section
                table.remove(processing_queue, idx)
                local insert_pos = 1
                for i, qi in ipairs(processing_queue) do
                    if qi.priority ~= "active" then
                        insert_pos = i
                        break
                    end
                    insert_pos = i + 1
                end
                table.insert(processing_queue, insert_pos, item)
            end
            return
        end
    end
    
    local work_item = {
        block_hash = block_hash,
        blockpos = blockpos,
        workers = {},
        priority = priority_level
    }
    work_item.workers[worker_id] = true
    
    -- Insert based on priority
    if priority_level == "active" then
        -- Find first loaded item or end
        local insert_pos = 1
        for i, item in ipairs(processing_queue) do
            if item.priority ~= "active" then
                insert_pos = i
                break
            end
            insert_pos = i + 1
        end
        table.insert(processing_queue, insert_pos, work_item)
    else
        table.insert(processing_queue, work_item)
    end
end

-- Checks if labels have aged beyond threshold
local function labels_aged(labels, threshold)
    for _, label in pairs(labels) do
        if label:elapsed_time() > threshold then
            return true
        end
    end
    return false
end

-- Determines if a block is suitable for a worker
local function block_fits_worker(block_hash, blockpos, worker)
    local interval = worker.work_every
    local ls = ms.label_store.new(block_hash, blockpos)
    if not (ls:contains_labels(worker.needed_labels) and
            ls:has_one_of(worker.has_one_of)) then
        return false
    end
    if interval then
        local timer_labels = ls:filter_labels(worker.rework_labels)
        if not timer_labels then
            return true
        end
        return labels_aged(timer_labels, interval)
    end
    return true
end

-- Evaluates and enqueues block for workers
local function evaluate_and_enqueue(block_hash, blockpos, priority_level)
    for _, worker in pairs(worker_registry) do
        if block_fits_worker(block_hash, blockpos, worker) then
            enqueue_block(block_hash, blockpos, worker.name, priority_level)
        end
    end
end

-- Block activation callback - highest priority
core.register_on_block_activated(function(blockpos)
    local block_hash = core.hash_node_position(blockpos)
    active_registry[block_hash] = blockpos
    evaluate_and_enqueue(block_hash, blockpos, "active")
end)

-- Block loaded callback - lower priority
core.register_on_block_loaded(function(blockpos)
    local block_hash = core.hash_node_position(blockpos)
    if not active_registry[block_hash] then
        loaded_registry[block_hash] = blockpos
        evaluate_and_enqueue(block_hash, blockpos, "loaded")
    end
end)

-- Block deactivation callback
core.register_on_block_deactivated(function(blockpos_list)
    for _, blockpos in ipairs(blockpos_list) do
        local block_hash = core.hash_node_position(blockpos)
        active_registry[block_hash] = nil
        loaded_registry[block_hash] = blockpos
    end
end)

-- Block unloaded callback
core.register_on_block_unloaded(function(blockpos_list)
    for _, blockpos in ipairs(blockpos_list) do
        local block_hash = core.hash_node_position(blockpos)
        loaded_registry[block_hash] = nil
    end
end)

------------------------------------------------------------------
-- Here the shepherd is started
------------------------------------------------------------------

-- Only start the shepherd if the database format is correct
if ms.ensure_compatibility() then
    core.register_globalstep(execute_cycle)
end

core.register_chatcommand(
    "shepherd_status", {
        description = S("Prints status of the Mapchunk Shepherd."),
        privs = {},
        func = function(name, param)
            local worker_names = {}
            for _, worker in pairs(worker_registry) do
                table.insert(worker_names, worker.name)
            end
            worker_names = core.serialize(worker_names)
            worker_names = worker_names:gsub("return ", "")
            local nr_of_blocks = ms.tracked_block_counter()
            local tracked_status = S("Tracked blocks: ")..nr_of_blocks
            local queue_status = S("Work queue: ")..#processing_queue
            local active_count = 0
            for _ in pairs(active_registry) do
                active_count = active_count + 1
            end
            local loaded_count = 0
            for _ in pairs(loaded_registry) do
                loaded_count = loaded_count + 1
            end
            local blocks_status = S("Active blocks: ")..active_count.." | "..
                S("Loaded blocks: ")..loaded_count
            local time_status = S("Working time: ")..
                S("Min: ")..math.ceil(shortest_execution).." ms | "..
                S("Max: ")..math.ceil(longest_execution).." ms | "..
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
            local ls = ms.label_store.new(block_hash, blockpos)
            local labels = ls:get_labels()
            local last_changed = ms.time_since_last_change(block_hash, blockpos)
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
