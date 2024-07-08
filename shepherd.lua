--[[
    This is a part of "Perfect City".
    Copyright (C) 2023 Jan Wielkiewicz <tona_kosmicznego_smiecia@interia.pl>

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

local modpath = minetest.get_modpath('mapchunk_shepherd')
local dimensions = dofile(modpath.."/chunk_dimensions.lua")

local mapchunk_offset = dimensions.mapchunk_offset
local chunk_side = dimensions.chunk_side
local old_chunksize = dimensions.old_chunksize
local blocks_per_chunk = dimensions.blocks_per_chunk

local function loaded_or_active(pos)
    return minetest.compare_block_status(pos, "loaded") or
        minetest.compare_block_status(pos, "active")
end

local function neighboring_mapchunks(hash)
    local pos = minetest.get_position_from_hash(hash)
    local hashes = {}
    local diameter = tonumber(minetest.settings:get("viewing_range")) * 2
    local nr = math.ceil(diameter / chunk_side)
    for z = -nr, nr do
        for y = -nr, nr do
            for x = -nr, nr do
                local v = vector.new(x, y, z)
                v = vector.multiply(v, chunk_side)
                local mapchunk_pos = vector.add(pos, v)
                table.insert(hashes, ms.mapchunk_hash(mapchunk_pos))
            end
        end
    end
    return hashes
end

---------------------------------------------------------------------
-- Main loops of the shepherd
---------------------------------------------------------------------

local scan_queue = {}
local work_queue = {}

local scanners = {}
local scanners_by_name = {}

local longer_break = 2 -- two seconds
local previous_failure = false
local small_break = 0.005

local scanner_running = false

local function scanner_break()
    scanner_running = false
end

local function run_scanners(dtime)
    if scanner_running then
        return
    end
    scanner_running = true
    if ms.scanners_changed then
        scanners = table.copy(ms.scanners)
        scanners_by_name = table.copy(ms.scanners_by_name)
        ms.scanners_changed = false
        scan_queue = {}
        minetest.after(longer_break, scanner_break)
        return
    end
    if #scanners == 0 then
        minetest.after(longer_break, scanner_break)
        return
    end
    local chunk = scan_queue[1]
    if not chunk then
        minetest.after(small_break, scanner_break)
        return
    end
    --minetest.log("error", "scan queue: "..#scan_queue)
    local hash = chunk.hash
    local failed = ms.contains_labels(hash, {"scanner_failed"})
    if failed then
        if previous_failure == hash and math.random() < 0.7 then
            -- 70% chance to remove recurrent failure
            table.remove(scan_queue, 1)
            minetest.after(small_break, scanner_break)
            return
        else
            previous_failure = hash
        end
    end
    local pos_min, pos_max = ms.mapchunk_borders(hash)
    for scanner_name, _ in pairs(chunk.scanners) do
        local scanner = scanners_by_name[scanner_name]
        local labels_added, labels_removed =
            scanner.scanner_function(pos_min, pos_max)
        ms.handle_labels(hash, labels_added, labels_removed)
    end
    if loaded_or_active(pos1) and not ms.was_scanned(hash) then
        ms.add_labels(hash, {"scanned"})
    end
    table.remove(scan_queue, 1)
    scanner_running = false
end

local workers = {}
local workers_by_name = {}
local worker_running = false

local function worker_break()
    worker_running = false
end

local function process_chunk(chunk)
    local hash = chunk.hash
    local pos_min, pos_max = ms.mapchunk_borders(hash)
    local vm = VoxelManip()
    vm:read_from_map(pos_min, pos_max)
    local vm_data = {
        nodes = vm:get_data(),
        param2 = vm:get_param2_data(),
        light = vm:get_light_data(),
    }
    local light_changed = false
    local param2_changed = false
    for worker_name, _ in pairs(chunk.workers) do
        local worker = workers_by_name[worker_name]
        local labels_added, labels_removed, light_chd, param2_chd =
            worker.worker_function(pos_min, pos_max, vm_data)
        ms.handle_labels(hash, labels_added, labels_removed)
        if light_chd then
            light_changed = true
        end
        if param2_chd then
            param2_changed = true
        end
    end
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
        local afterworker = workers_by_name[worker_name].afterworker
        if afterworker then
            afterworker(hash)
        end
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
        workers = table.copy(ms.workers)
        workers_by_name = table.copy(ms.workers_by_name)
        ms.workers_changed = false
        work_queue = {}
        minetest.after(longer_break, worker_break)
        return
    end
    if #workers == 0 then
        minetest.after(longer_break, worker_break)
        return
    end
    local chunk = work_queue[1]
    if not chunk then
        minetest.after(small_break, worker_break)
        return
    end
    --minetest.log("error", "work queue: "..#work_queue)
    local t1 = minetest.get_us_time()
    process_chunk(chunk)
    record_worker_stats(t1)
    table.remove(work_queue, 1)
    worker_running = false
end

local function add_to_scan_queue(hash, scanner_name)
    local exists = false
    for _, chunk in pairs(scan_queue) do
        if chunk.hash == hash then
            chunk.scanners[scanner_name] = true
            exists = true
            break
        end
    end
    if not exists then
        local chunk = {hash = hash,
                       scanners = {}}
        chunk.scanners[scanner_name] = true
        table.insert(scan_queue, chunk)
    end
end

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

-- returns true if at least one label has its elapsed time
-- greater than time
local function labels_baked(labels, time)
    for _, label in pairs(labels) do
        if ms.labels.time_elapsed(label) > time then
            return true
        end
    end
    return false
end

local function pick_labels(labels, wanted_names)
    local clean = {}
    for _, label in pairs(labels) do
        for _, name in pairs(wanted_names) do
            if label[1] == name then
                table.insert(clean, label)
                break
            end
        end
    end
    return clean
end

local function good_for_scanner(hash, scanner, labels)
    local labels = labels or ms.get_labels(hash)
    local scan_every = scanner.scan_every
    local has_labels = ms.contains_labels(hash, scanner.needed_labels) and
        ms.has_one_of(hash, scanner.has_one_of)
    local timer_labels = pick_labels(labels, scanner.rescan_labels)
    if has_labels then
        if scan_every and labels_baked(timer_labels, scan_every) or
            scan_every and #timer_labels == 0 then
            return true
        elseif not ms.was_scanned(hash) then
            return true
        elseif ms.contains_labels(hash, {"scanner_failed"}) then
            if math.random() < 0.2 then
                -- 20% chance of rescanning on failure
                return true
            end
        end
    end
    return false
end

local function good_for_worker(hash, worker, labels)
    local labels = labels or ms.get_labels(hash)
    local work_every = worker.work_every
    local has_labels = ms.contains_labels(hash, worker.needed_labels) and
        ms.has_one_of(hash, worker.has_one_of)
    if has_labels or
        has_labels and ms.contains_labels(hash, {"worker_failed"})
    then
        if work_every then
            local timer_labels = pick_labels(labels, worker.rework_labels)
            if #timer_labels == 0 then
                return true
            end
            return labels_baked(timer_labels, work_every)
        else
            return true
        end
    end
    return false
end

-- Part of the tracker
local function save_scan_work(hash)
    local labels = ms.get_labels(hash)
    if not ms.is_tracked(hash) then
        ms.save_mapchunk(hash)
        return
    end
    for _, scanner in pairs(scanners) do
        if good_for_scanner(hash, scanner, labels) then
            add_to_scan_queue(hash, scanner.name)
        end
    end
    for _, worker in pairs(workers) do
        if good_for_worker(hash, worker, labels) then
            add_to_work_queue(hash, worker.name)
        end
    end
end

-- Player tracker - responsible for saving mapchunks
-- and adding chunks into scan and work queues.
local function player_tracker()
    local players = minetest.get_connected_players()
    for _, player in pairs(players) do
        local pos = player:get_pos()
        if not pos then
            return
        end
        local hash = ms.mapchunk_hash(pos)
        local neighbors = neighboring_mapchunks(hash)
        --minetest.log("error", dump(ms.get_labels(hash)))
        for _, neighbor in pairs(neighbors) do
            local pos_min, pos_max = ms.mapchunk_borders(neighbor)
            if loaded_or_active(pos_min) then
                save_scan_work(neighbor)
            end
        end
    end
end

local tracker_timer = 6
local tracker_interval = 10

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

-- Prevent starting Mapchunk Shepherd if chunksize changed for the world.
-- This avoids data corruption.
if ms.chunksize_changed() then
    minetest.log("error", "Mapchunk Shepherd: chunksize changed to "..
                 blocks_per_chunk.." from "..old_chunksize..".")
    minetest.log("error", "Mapchunk Shepherd: Changing chunksize can corrupt stored data."..
                 " Refusing to start.")
else
    -- Start the tracker
    minetest.register_globalstep(player_tracker_loop)
    minetest.register_globalstep(run_scanners)
    minetest.register_globalstep(run_workers)
end

minetest.register_chatcommand(
    "shepherd_status", {
        description = S("Prints status of the Mapchunk Shepherd."),
        privs = {},
        func = function(name, param)
            local scanner_names = {}
            local worker_names = {}
            for _, scanner in pairs(scanners) do
                table.insert(scanner_names, scanner.name)
            end
            scanner_names = minetest.serialize(scanner_names)
            scanner_names = scanner_names:gsub("return ", "")
            for _, worker in pairs(workers) do
                table.insert(worker_names, worker.name)
            end
            worker_names = minetest.serialize(worker_names)
            worker_names = worker_names:gsub("return ", "")
            local nr_of_chunks = ms.tracked_chunk_counter()
            local tracked_chunks_status = S("Tracked chunks: ")..nr_of_chunks
            local scan_queue_status = S("Scan queue: ")..#scan_queue
            local work_queue_status = S("Work queue: ")..#work_queue
            local work_time_status = S("Working time: ")..
                S("Min: ")..math.ceil(min_working_time).." ms | "..
                S("Max: ")..math.ceil(max_working_time).." ms | "..
                S("Moving median: ")..get_median_working_time().." ms | "..
                S("Moving average: ")..get_average_working_time().." ms"
            local scanner_status = S("Scanners: ")..scanner_names
            local worker_status = S("Workers: ")..worker_names
            return true, tracked_chunks_status.."\n"..scan_queue_status.."\n"..
                work_queue_status.."\n"..work_time_status.."\n"..scanner_status..
                "\n"..worker_status.."\n"
        end,
})

minetest.register_chatcommand(
    "chunk_labels", {
        description = S("Prints labels of the chunk where the player stands."),
        privs = {},
        func = function(name, param)
            local player = minetest.get_player_by_name(name)
            local pos = player:get_pos()
            local hash = ms.mapchunk_hash(pos)
            local labels = ms.get_labels(hash)
            local last_changed = ms.time_since_last_change(hash)
            labels = minetest.serialize(labels)
            labels = labels:gsub("return ", "")
            labels = labels:gsub("{{", "{")
            labels = labels:gsub("}}", "}")
            labels = labels:gsub(",", ", ")
            return true, S("hash: ")..hash.."\n"
                ..S("last changed: ")..last_changed..S(" seconds ago").."\n"
                ..S("labels: ")..labels.."\n "
        end,
})
