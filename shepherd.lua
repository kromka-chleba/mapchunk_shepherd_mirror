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

local mod_path = minetest.get_modpath('mapchunk_shepherd')
local sizes = dofile(mod_path.."/sizes.lua")

local mod_storage = minetest.get_mod_storage()
local old_chunksize = mod_storage:get_int("chunksize")

---------------------------------------------------------------------
-- Main loops of the shepherd
---------------------------------------------------------------------

local work_queue = {}

local longer_break = 2 -- two seconds
local previous_failure = false
local small_break = 0.005

local workers = {}
local workers_by_name = {}
local worker_running = false

local function worker_break()
    worker_running = false
end

local vm_data = {
    nodes = {},
    param2 = {},
    light = {},
}

local function process_mapblock(mapblock)
    local hash = mapblock.hash
    local pos_min, pos_max = ms.mapchunk_min_max(hash)
    local vm = VoxelManip()
    vm:read_from_map(pos_min, pos_max)
    vm:get_data(vm_data.nodes)
    vm:get_param2_data(vm_data.param2)
    vm:get_light_data(vm_data.light)
    local light_changed = false
    local param2_changed = false
    local ls = ms.label_store.new(hash)
    for worker_name, _ in pairs(mapblock.workers) do
        local worker = workers_by_name[worker_name]
        local added_labels, removed_labels, light_chd, param2_chd =
            worker:run(pos_min, pos_max, vm_data)
        ls:mark_for_addition(added_labels)
        ls:mark_for_removal(removed_labels)
        if light_chd then
            light_changed = true
        end
        if param2_chd then
            param2_changed = true
        end
    end
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
    for worker_name, _ in pairs(mapblock.workers) do
        local worker = workers_by_name[worker_name]
        worker:run_afterworker(hash)
    end
end

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

local function run_workers(dtime)
    if worker_running then
        return
    end
    worker_running = true
    if ms.workers_changed then
        workers = ms.workers
        workers_by_name = ms.workers_by_name
        ms.workers_changed = false
        work_queue = {}
        minetest.after(longer_break, worker_break)
        return
    end
    if #workers == 0 then
        minetest.after(longer_break, worker_break)
        return
    end
    local mapblock = work_queue[1]
    if not mapblock then
        minetest.after(small_break, worker_break)
        return
    end
    --minetest.log("error", "work queue: "..#work_queue)
    local t1 = minetest.get_us_time()
    process_mapblock(mapblock)
    record_worker_stats(t1)
    table.remove(work_queue, 1)
    worker_running = false
end

local function add_to_work_queue(hash, worker_name)
    local exists = false
    for _, mapblock in pairs(work_queue) do
        if mapblock.hash == hash then
            mapblock.workers[worker_name] = true
            exists = true
            break
        end
    end
    if not exists then
        local mapblock = {hash = hash,
                       workers = {}}
        mapblock.workers[worker_name] = true
        table.insert(work_queue, mapblock)
    end
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

-- Part of the tracker
local function save_and_work(hash)
    for _, worker in pairs(workers) do
        if good_for_worker(hash, worker) then
            add_to_work_queue(hash, worker.name)
        end
    end
end

local shepherd_interval = 10 -- in seconds

local function main_loop()
    core.blocks_callback({
            mode = "quick",
            callback = function(hash)
                save_and_work(hash)
            end,
    })
    minetest.after(shepherd_interval, main_loop)
end

------------------------------------------------------------------
-- Here the shepherd is started
------------------------------------------------------------------

-- Only start the shepherd if the database format is correct and
-- chunksize did not change.
if ms.ensure_compatibility() then
    -- Start the tracker
    minetest.register_globalstep(player_tracker_loop)
    minetest.register_globalstep(run_workers)
end

core.register_privilege(
    "mapchunk_shepherd", {
        description = "Grants access to destructive mapchunk shepherd commands.",
        give_to_singleplayer = false,
        give_to_admin = true,
})

-- minetest.register_chatcommand(
--     "shepherd_status", {
--         description = S("Prints status of the Mapchunk Shepherd."),
--         privs = {},
--         func = function(name, param)
--             local worker_names = {}
--             for _, worker in pairs(workers) do
--                 table.insert(worker_names, worker.name)
--             end
--             worker_names = minetest.serialize(worker_names)
--             worker_names = worker_names:gsub("return ", "")
--             local nr_of_chunks = ms.tracked_chunk_counter()
--             local tracked_chunks_status = S("Tracked chunks: ")..nr_of_chunks
--             local work_queue_status = S("Work queue: ")..#work_queue
--             local work_time_status = S("Working time: ")..
--                 S("Min: ")..math.ceil(min_working_time).." ms | "..
--                 S("Max: ")..math.ceil(max_working_time).." ms | "..
--                 S("Moving median: ")..get_median_working_time().." ms | "..
--                 S("Moving average: ")..get_average_working_time().." ms"
--             local worker_status = S("Workers: ")..worker_names
--             return true, tracked_chunks_status.."\n"..
--                 work_queue_status.."\n"..work_time_status.."\n"..
--                 worker_status.."\n"
--         end,
-- })

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
