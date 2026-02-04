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

-- Clears the worker_running flag after a break, allowing the next worker cycle to run.
local function worker_break()
    worker_running = false
end

local vm_data = {
    nodes = {},
    param2 = {},
    light = {},
}

-- Processes a single mapchunk by running all workers assigned to it.
-- Reads mapchunk data via VoxelManip, runs workers, updates labels, and writes changes back.
-- chunk: table with 'hash' (mapchunk hash) and 'workers' (table of worker names)
local function process_chunk(chunk)
    local hash = chunk.hash
    local pos_min, pos_max = ms.mapchunk_min_max(hash)
    local vm = VoxelManip()
    vm:read_from_map(pos_min, pos_max)
    vm:get_data(vm_data.nodes)
    vm:get_param2_data(vm_data.param2)
    vm:get_light_data(vm_data.light)
    local light_changed = false
    local param2_changed = false
    local ls = ms.label_store.new(hash)
    for worker_name, _ in pairs(chunk.workers) do
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
    for worker_name, _ in pairs(chunk.workers) do
        local worker = workers_by_name[worker_name]
        worker:run_afterworker(hash)
    end
end

local min_working_time = math.huge
local max_working_time = 0
local worker_exec_times = {}

-- Records worker execution time statistics for performance monitoring.
-- time: The microsecond timestamp from when the worker started.
local function record_worker_stats(time)
    local elapsed = (core.get_us_time() - time) / 1000
    --core.log("error", string.format("elapsed time: %g ms", elapsed))
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

-- Returns the moving average of worker execution times.
-- Uses the last 100 execution times to compute the average.
-- Returns 0 if no data is available yet.
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

-- Returns the moving median of worker execution times.
-- Uses the last 100 execution times to compute the median.
-- Returns 0 if no data is available yet.
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

-- Main worker loop that processes one chunk from the work queue per call.
-- Called as a globalstep callback. Handles worker registration changes,
-- processes one chunk at a time, and schedules the next run.
-- dtime: Delta time since last call (unused but required by globalstep).
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
        core.after(longer_break, worker_break)
        return
    end
    if #workers == 0 then
        core.after(longer_break, worker_break)
        return
    end
    local chunk = work_queue[1]
    if not chunk then
        core.after(small_break, worker_break)
        return
    end
    --core.log("error", "work queue: "..#work_queue)
    local t1 = core.get_us_time()
    process_chunk(chunk)
    record_worker_stats(t1)
    table.remove(work_queue, 1)
    worker_running = false
end

-- Adds a mapchunk to the work queue for a specific worker.
-- If the chunk is already in the queue, adds the worker to its worker list.
-- hash: Mapchunk hash to add to the work queue.
-- worker_name: Name of the worker that should process this chunk.
local function add_to_work_queue(hash, worker_name)
    local exists = false
    for _, chunk in pairs(work_queue) do
        if chunk.hash == hash then
            chunk.workers[worker_name] = true
            exists = true
            break
        end
    end
    if not exists then
        local chunk = {hash = hash,
                       workers = {}}
        chunk.workers[worker_name] = true
        table.insert(work_queue, chunk)
    end
end

-- Checks if labels have "baked" (aged) beyond a certain time threshold.
-- Used to determine if enough time has passed since label creation/modification.
-- labels: Table of label objects.
-- time: Time threshold in game seconds.
-- Returns true if at least one label has elapsed time greater than the threshold.
local function labels_baked(labels, time)
    for _, label in pairs(labels) do
        if label:elapsed_time() > time then
            return true
        end
    end
    return false
end

-- Determines if a mapchunk is suitable for a specific worker.
-- Checks label requirements (needed_labels, has_one_of) and timing (work_every).
-- hash: Mapchunk hash to check.
-- worker: Worker object to check against.
-- Returns true if the worker should process this mapchunk.
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

-- Checks if a mapchunk should be processed by any workers and adds it to the work queue.
-- Part of the player tracker system.
-- hash: Mapchunk hash to check and potentially add to work queue.
local function save_and_work(hash)
    for _, worker in pairs(workers) do
        if good_for_worker(hash, worker) then
            add_to_work_queue(hash, worker.name)
        end
    end
end

-- Tracks player positions and adds nearby loaded mapchunks to the work queue.
-- Runs periodically to discover mapchunks in players' neighborhoods.
-- Checks if mapchunks are loaded before adding them to the work queue.
local function player_tracker()
    local players = core.get_connected_players()
    for _, player in pairs(players) do
        local pos = player:get_pos()
        if not pos then
            return
        end
        local hash = ms.mapchunk_hash(pos)
        local neighbors = ms.neighboring_mapchunks(hash)
        for _, neighbor in pairs(neighbors) do
            local pos_min, pos_max = ms.mapchunk_min_max(neighbor)
            if ms.loaded_or_active(pos_min) then
                save_and_work(neighbor)
            end
        end
    end
end

local tracker_timer = 6
local tracker_interval = 10

-- Globalstep callback that runs the player tracker at regular intervals.
-- dtime: Delta time since last call.
local function player_tracker_loop(dtime)
    tracker_timer = tracker_timer + dtime
    if tracker_timer > tracker_interval then
        tracker_timer = 0
        player_tracker()
    end
end

------------------------------------------------------------------
-- Here the trackers is started
------------------------------------------------------------------

-- Only start the shepherd if the database format is correct and
-- chunksize did not change.
if ms.ensure_compatibility() then
    -- Start the tracker
    core.register_globalstep(player_tracker_loop)
    core.register_globalstep(run_workers)
end

core.register_chatcommand(
    "shepherd_status", {
        description = S("Prints status of the Mapchunk Shepherd."),
        privs = {},
        func = function(name, param)
            local worker_names = {}
            for _, worker in pairs(workers) do
                table.insert(worker_names, worker.name)
            end
            worker_names = core.serialize(worker_names)
            worker_names = worker_names:gsub("return ", "")
            local nr_of_chunks = ms.tracked_chunk_counter()
            local tracked_chunks_status = S("Tracked chunks: ")..nr_of_chunks
            local work_queue_status = S("Work queue: ")..#work_queue
            local work_time_status = S("Working time: ")..
                S("Min: ")..math.ceil(min_working_time).." ms | "..
                S("Max: ")..math.ceil(max_working_time).." ms | "..
                S("Moving median: ")..get_median_working_time().." ms | "..
                S("Moving average: ")..get_average_working_time().." ms"
            local worker_status = S("Workers: ")..worker_names
            return true, tracked_chunks_status.."\n"..
                work_queue_status.."\n"..work_time_status.."\n"..
                worker_status.."\n"
        end,
})

core.register_chatcommand(
    "chunk_labels", {
        description = S("Prints labels of the chunk where the player stands."),
        privs = {},
        func = function(name, param)
            local player = core.get_player_by_name(name)
            local pos = player:get_pos()
            local hash = ms.mapchunk_hash(pos)
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
