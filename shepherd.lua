--[[
    This is a part of "Mapblock Shepherd".
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

local mod_path = minetest.get_modpath('mapchunk_shepherd')
local sizes = dofile(mod_path.."/sizes.lua")

local mod_storage = minetest.get_mod_storage()
local old_chunksize = mod_storage:get_int("chunksize")

local workers = {}
local workers_by_name = {}

local min_working_time = math.huge
local max_working_time = 0
local worker_exec_times = {}

local function record_worker_stats(time)
    local elapsed = (minetest.get_us_time() - time) / 1000
    --minetest.log("error", string.format("elapsed time: %g ms", elapsed))
    if elapsed < min_working_time then
        min_working_time = elapsed
    end
    if elapsed > max_working_time then
        max_working_time = elapsed
    end
    table.insert(worker_exec_times, elapsed)
    -- 100 data points for the moving average
    if #worker_exec_times > 100 then
        table.remove(worker_exec_times, 1)
    end
end

-- this gives you the moving average of working time
local function get_average_working_time()
    local sum = 0
    if #worker_exec_times == 0 then
        return 0
    end
    for _, time in pairs(worker_exec_times) do
        sum = sum + time
    end
    return math.ceil(sum / #worker_exec_times)
end

-- this gives you the moving median of working time
local function get_median_working_time()
    local times_copy = table.copy(worker_exec_times)
    table.sort(times_copy)
    local median = 0
    if #times_copy == 0 then
        return 0
    end
    if #times_copy % 2 == 0 then
        median = (times_copy[#times_copy / 2] +
                  times_copy[#times_copy / 2 + 1]) / 2
    else
        median = times_copy[math.ceil(#times_copy / 2)]
    end
    return math.ceil(median)
end

local vm_data = {
    nodes = {},
    param2 = {},
    light = {},
}

local function process_mapblock(hash, vm, worker)
    local pos_min, pos_max = ms.mapblock_min_max(hash)
    local ls = ms.label_store.new(hash)
    local added_labels, removed_labels, light_changed, param2_changed =
        worker:run(pos_min, pos_max, vm_data)
    ls:mark_for_addition(added_labels)
    ls:mark_for_removal(removed_labels)
    ls:save_to_disk()
    vm:set_data(vm_data.nodes)
    if light_changed then
        vm:set_light_data(vm_data.light)
    end
    if param2_changed then
        vm:set_param2_data(vm_data.param2)
    end
    vm:write_to_map(light_changed)
    vm:update_liquids()
    worker:run_afterworker(hash)
end

local function labels_baked(labels, time)
    for _, label in pairs(labels) do
        if label:elapsed_time() > time then
            return true
        end
    end
    return false
end

local function good_for_worker(hash, worker)
    local work_every = worker.work_every
    local ls = ms.label_store.new(hash)
    if not (ls:contains_labels(worker.needed_labels) and
            ls:has_one_of(worker.has_one_of)) then
        return false
    end
    if work_every then
        local timer_labels = ls:filter_labels(worker.rework_labels)
        if not timer_labels then
            -- Bootstrap first run for workers with circular dependencies
            return true
        end
        return labels_baked(timer_labels, work_every)
    end
    return true
end

local function init_voxel_manip(hash)
    local pos_min, pos_max = ms.mapblock_min_max(hash)
    local vm = VoxelManip()
    vm:read_from_map(pos_min, pos_max)
    vm:get_data(vm_data.nodes)
    vm:get_param2_data(vm_data.param2)
    vm:get_light_data(vm_data.light)
    return vm
end

local function run_workers(hash)
    local t1 = minetest.get_us_time()
    local vm
    for _, worker in pairs(workers) do
        if good_for_worker(hash, worker) then
            vm = vm or init_voxel_manip(hash)
            process_mapblock(hash, vm, worker)
        end
    end
    record_worker_stats(t1)
end

local function refresh_workers()
    if ms.workers_changed then
        workers = ms.workers
        workers_by_name = ms.workers_by_name
        ms.workers_changed = false
    end
end

---------------------------------------------------------------------
-- Block tracking and processing
---------------------------------------------------------------------

-- Track blocks that need processing
local blocks_to_process = {}
local blocks_pending = {}

-- Add a block to the processing queue
local function queue_block(blockpos)
    local hash = minetest.hash_node_position(blockpos)
    local our_hash = ms.hash(blockpos)
    if not blocks_pending[hash] then
        blocks_pending[hash] = our_hash
        table.insert(blocks_to_process, {hash = hash, our_hash = our_hash, is_active = false})
    end
end

-- Mark block as active (should be processed first)
local function mark_block_active(blockpos)
    local hash = minetest.hash_node_position(blockpos)
    local our_hash = ms.hash(blockpos)
    blocks_pending[hash] = our_hash
    -- Find existing entry or add new one
    local found = false
    for _, entry in ipairs(blocks_to_process) do
        if entry.hash == hash then
            entry.is_active = true
            found = true
            break
        end
    end
    if not found then
        table.insert(blocks_to_process, {hash = hash, our_hash = our_hash, is_active = true})
    end
end

-- Remove block from processing queue
local function unqueue_block(blockpos)
    local hash = minetest.hash_node_position(blockpos)
    blocks_pending[hash] = nil
    for i = #blocks_to_process, 1, -1 do
        if blocks_to_process[i].hash == hash then
            table.remove(blocks_to_process, i)
        end
    end
end

---------------------------------------------------------------------
-- Block callback registration
---------------------------------------------------------------------

-- Called when a mapblock is loaded from disk or generated
minetest.register_on_block_loaded(function(blockpos)
    queue_block(blockpos)
end)

-- Called when a mapblock becomes active (within active_block_range of player)
minetest.register_on_block_activated(function(blockpos)
    mark_block_active(blockpos)
end)

-- Called when mapblocks are deactivated
minetest.register_on_block_deactivated(function(blockpos_list)
    for _, blockpos in ipairs(blockpos_list) do
        -- Keep in queue but mark as not active
        local hash = minetest.hash_node_position(blockpos)
        for _, entry in ipairs(blocks_to_process) do
            if entry.hash == hash then
                entry.is_active = false
                break
            end
        end
    end
end)

-- Called when mapblocks are completely unloaded from memory
minetest.register_on_block_unloaded(function(blockpos_list)
    for _, blockpos in ipairs(blockpos_list) do
        unqueue_block(blockpos)
    end
end)

---------------------------------------------------------------------
-- Main processing loop
---------------------------------------------------------------------

local shepherd_interval = 1.0 -- in seconds
local max_blocks_per_tick = 5 -- process up to 5 blocks per tick

local function main_loop()
    refresh_workers()
    
    if #blocks_to_process == 0 then
        minetest.after(shepherd_interval, main_loop)
        return
    end
    
    -- Sort blocks: active blocks first (they're closer to players)
    table.sort(blocks_to_process, function(a, b)
        if a.is_active ~= b.is_active then
            return a.is_active -- active blocks come first
        end
        return false -- maintain order for same priority
    end)
    
    -- Process blocks
    local processed = 0
    for i = #blocks_to_process, 1, -1 do
        if processed >= max_blocks_per_tick then
            break
        end
        
        local entry = blocks_to_process[i]
        local hash = entry.hash
        local our_hash = entry.our_hash
        
        -- Check if block is still loaded
        if core.loaded_blocks[hash] then
            run_workers(our_hash)
            processed = processed + 1
        end
        
        -- Remove from queue after processing
        blocks_pending[hash] = nil
        table.remove(blocks_to_process, i)
    end
    
    minetest.after(shepherd_interval, main_loop)
end

------------------------------------------------------------------
-- Here the shepherd is started
------------------------------------------------------------------

-- Only start the shepherd if the database format is correct and
-- chunksize did not change.
if ms.ensure_compatibility() then
    -- Start the main processing loop
    minetest.after(shepherd_interval, main_loop)
end

------------------------------------------------------------------
-- Chat commands
------------------------------------------------------------------

core.register_privilege(
    "mapchunk_shepherd", {
        description = "Grants access to destructive mapblock shepherd commands.",
        give_to_singleplayer = false,
        give_to_admin = true,
})

minetest.register_chatcommand(
    "shepherd_status", {
        description = S("Prints status of the Mapblock Shepherd."),
        privs = {},
        func = function(name, param)
            local worker_names = {}
            for _, worker in pairs(workers) do
                table.insert(worker_names, worker.name)
            end
            worker_names = minetest.serialize(worker_names)
            worker_names = worker_names:gsub("return ", "")
            local nr_of_chunks = ms.tracked_chunk_counter()
            local tracked_chunks_status = S("Tracked blocks: ")..nr_of_chunks
            local work_time_status = S("Working time: ")..
                S("Min: ")..math.ceil(min_working_time).." ms | "..
                S("Max: ")..math.ceil(max_working_time).." ms | "..
                S("Moving median: ")..get_median_working_time().." ms | "..
                S("Moving average: ")..get_average_working_time().." ms"
            local worker_status = S("Workers: ")..worker_names
            return true, tracked_chunks_status.."\n"..work_time_status.."\n"..
                worker_status.."\n"
        end,
})

minetest.register_chatcommand(
    "mapblock_labels", {
        description = S("Prints labels of the mapblock where the player stands."),
        privs = {},
        func = function(name, param)
            local player = minetest.get_player_by_name(name)
            local pos = player:get_pos()
            local hash = ms.mapblock_hash(pos)
            local ls = ms.label_store.new(hash)
            local labels = ls:get_labels()
            local last_changed = ms.time_since_last_change(hash)
            local label_string = ""
            for _, label in pairs(labels) do
                label_string = label_string..label:description()..", "
            end
            return true, S("hash: ")..hash.."\n"
                ..S("last changed: ")..last_changed..S(" seconds ago").."\n"
                ..S("labels: ")..label_string.."\n "
        end,
})

minetest.register_chatcommand(
    "add_labels", {
        description = S("Adds labels to the mapblock where the player stands."),
        privs = {mapchunk_shepherd = true},
        func = function(name, str)
            local labels = str:gsub(" ", ""):split(",")
            local player = minetest.get_player_by_name(name)
            local pos = player:get_pos()
            local hash = ms.mapblock_hash(pos)
            local old_coords = ms.unhash(hash)
            core.log("error", "Old coords: ")
            core.log("error", dump(old_coords))
            local ls = ms.label_store.new(hash)
            ls:add_labels(labels)
            ls:save_to_disk()
            return true
        end,
})

minetest.register_chatcommand(
    "remove_labels", {
        description = S("Removes labels from the mapblock where the player stands."),
        privs = {mapchunk_shepherd = true},
        func = function(name, str)
            local labels = str:gsub(" ", ""):split(",")
            local player = minetest.get_player_by_name(name)
            local pos = player:get_pos()
            local hash = ms.mapblock_hash(pos)
            local ls = ms.label_store.new(hash)
            ls:remove_labels(labels)
            ls:save_to_disk()
            return true
        end,
})
