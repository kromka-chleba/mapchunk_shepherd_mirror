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

-- Globals
local ms = mapchunk_shepherd

ms.workers = {}
ms.workers_by_name = {}
ms.workers_changed = true

local placeholder_id_pairs = {}
local placeholder_id_finder_pairs = {}
local ignore_id = minetest.get_content_id("ignore")
local air_id = minetest.get_content_id("air")

local blocks_per_chunk = tonumber(minetest.get_mapgen_setting("chunksize"))
local chunk_side = blocks_per_chunk * 16

-- iterate over ids of all possible existing nodes
for i = 1, 32768 do
    placeholder_id_finder_pairs[i] = false
    placeholder_id_pairs[i] = false
end

placeholder_id_pairs[ignore_id] = false

function ms.placeholder_id_pairs()
    return table.copy(placeholder_id_pairs)
end

function ms.placeholder_id_finder_pairs()
    return table.copy(placeholder_id_finder_pairs)
end

-- fun needs to be a function fun(pos_min, pos_max)
-- where pos_min is minimal position in a mapchunk,
-- pos_max is maximal position in a mapchunk,
-- fun() needs to return two variables: labels_added,
-- labels_removed; labels to remove or add to a mapchunk

local function is_worker_registered(name)
    for i = 1, #ms.workers do
        if ms.workers[i] and ms.workers[i].name == name then
            return true
        end
    end
    return false
end

function ms.remove_worker(name)
    for i = 1, #ms.workers do
        if ms.workers[i] and ms.workers[i].name == name then
            ms.workers_by_name[name] = nil
            table.remove(ms.workers, i)
            ms.workers_changed = true
        end
    end
end

ms.worker = {}
local worker = ms.worker
worker.__index = worker

function worker.new(args)
    local w = {}
    local args = table.copy(args)
    if type(args.fun) ~= "function" then
        minetest.log("error", "Mapchunk shepherd: Trying to register worker \""..
                     args.name.."\" but argument \"fun\" is not a function!")
        return
    end
    w.name = args.name
    w.fun = args.fun
    w.needed_labels = args.needed_labels or {}
    w.has_one_of = args.has_one_of or {}
    w.rework_labels = args.rework_labels or {}
    w.work_every = args.work_every
    w.chance = args.chance
    w.catch_up = args.catch_up
    w.catch_up_function = args.catch_up_function
    w.afterworker = args.afterworker
    return setmetatable(w, worker)
end

function worker:register()
    if is_worker_registered(self.name) then
        ms.workers_changed = true
        return
    end
    table.insert(ms.workers, self)
    ms.workers_by_name[self.name] = self
end

function worker:unregister()
    ms.remove_worker(self.name)
end

-- function worker:worker_function(pos_min, pos_max, vm_data)
function worker:run(pos_min, pos_max, vm_data)
    if self.catch_up then
        local hash = ms.mapchunk_hash(pos_min)
        local new_chance = self:run_catch_up(hash, self.chance)
        return self.fun(pos_min, pos_max, vm_data, new_chance)
    end
    return self.fun(pos_min, pos_max, vm_data, self.chance)
end

function worker:basic_catch_up(hash, chance)
    local labels = ms.get_labels(hash)
    local elapsed = ms.labels.oldest_elapsed_time(labels, self.rework_labels)
    if elapsed == 0 then
        return chance
    end
    local missed_cycles = elapsed / self.work_every
    local new_chance = chance * missed_cycles
    return new_chance
end

-- function worker:catch_up_function()
function worker:run_catch_up()
    if self.catch_up_function then
        return self.catch_up_function(hash, chance)
    end
    return self:basic_catch_up(hash, chance)
end

function worker:run_afterworker(hash)
    if self.afterworker then
        self.afterworker(hash)
    end
end

function ms.create_simple_replacer(args)
    local args = table.copy(args)
    local find_replace_pairs = args.find_replace_pairs
    local labels_to_add = args.add_labels or {}
    local labels_to_remove = args.remove_labels or {}
    table.insert(labels_to_remove, "worker_failed")
    local not_found = args.not_found_labels
    local not_found_remove = args.not_found_remove
    local ids = table.copy(placeholder_id_pairs)
    for to_find, replacement in pairs(find_replace_pairs) do
        local find_id = minetest.get_content_id(to_find)
        local replacement_id = minetest.get_content_id(replacement)
        ids[find_id] = replacement_id
    end
    return function(pos_min, pos_max, vm_data, chance)
        local chance = chance or 1
        local found = false
        local data = vm_data.nodes
        for i = 1, #data do
            local replacement = ids[data[i]]
            if replacement then
                if chance >= math.random() then
                    data[i] = replacement
                end
                found = true
            elseif data[i] == ignore_id then
                return {"worker_failed"}
            end
        end
        if found then
            return labels_to_add, labels_to_remove, true
        else
            return not_found, not_found_remove
        end
    end
end

function ms.create_param2_aware_replacer(args)
    local args = table.copy(args)
    local find_replace_pairs = args.find_replace_pairs
    local labels_to_add = args.add_labels or {}
    local labels_to_remove = args.remove_labels or {}
    table.insert(labels_to_remove, "worker_failed")
    local not_found = args.not_found_labels
    local not_found_remove = args.not_found_remove
    local lower_than = args.lower_than or 257
    local higher_than = args.higher_than or -1
    local ids = table.copy(placeholder_id_pairs)
    for to_find, replacement in pairs(find_replace_pairs) do
        local find_id = minetest.get_content_id(to_find)
        local replacement_id = minetest.get_content_id(replacement)
        ids[find_id] = replacement_id
    end
    return function(pos_min, pos_max, vm_data, chance)
        local chance = chance or 1
        --local t1 = minetest.get_us_time()
        local found = false
        local data = vm_data.nodes
        local data_param2 = vm_data.param2
        for i = 1, #data do
            local replacement = ids[data[i]]
            if replacement then
                if data_param2[i] > higher_than and
                    data_param2[i] < lower_than then
                    if chance >= math.random() then
                        data[i] = replacement
                    end
                    found = true
                elseif data[i] == ignore_id then
                    return {"worker_failed"}
                end
            end
        end
        if found then
            --minetest.log("error", string.format("elapsed time: %g ms", (minetest.get_us_time() - t1) / 1000))
            return labels_to_add, labels_to_remove, true
        else
            return not_found, not_found_remove
        end
    end
end

function ms.create_light_aware_replacer(args)
    local args = table.copy(args)
    local find_replace_pairs = args.find_replace_pairs
    local labels_to_add = args.add_labels or {}
    local labels_to_remove = args.remove_labels or {}
    table.insert(labels_to_remove, "worker_failed")
    local not_found = args.not_found_labels
    local not_found_remove = args.not_found_remove
    local lower_than = args.lower_than or 16
    local higher_than = args.higher_than or -1
    local ids = table.copy(placeholder_id_pairs)
    for to_find, replacement in pairs(find_replace_pairs) do
        local find_id = minetest.get_content_id(to_find)
        local replacement_id = minetest.get_content_id(replacement)
        ids[find_id] = replacement_id
    end
    return function(pos_min, pos_max, vm_data, chance)
        local chance = chance or 1
        --local t1 = minetest.get_us_time()
        local found = false
        local data = vm_data.nodes
        local data_light = vm_data.light
        for i = 1, #data do
            local replacement = ids[data[i]]
            if replacement then
                local above_index = i + chunk_side
                local random_pick = false
                if not data_light[above_index] then
                    above_index = i
                    random_pick = true
                    -- we can't read pos above at the top boundary
                    -- that's why we're picking randomly lol
                end
                if data_light[above_index] > higher_than and
                    data_light[above_index] < lower_than or random_pick
                then
                    if chance >= math.random() then
                        data[i] = replacement
                    end
                    found = true
                elseif data[i] == ignore_id then
                    return {"worker_failed"}
                end
            end
        end
        if found then
            --minetest.log("error", string.format("elapsed time: %g ms", (minetest.get_us_time() - t1) / 1000))
            return labels_to_add, labels_to_remove, true
        else
            return not_found, not_found_remove
        end
    end
end

-- Places nodes on top of a node if light above the node is good
function ms.create_light_aware_top_placer(args)
    local args = table.copy(args)
    -- Labels
    local labels_to_add = args.add_labels or {}
    local labels_to_remove = args.remove_labels or {}
    table.insert(labels_to_remove, "worker_failed")
    local not_found = args.not_found_labels
    local not_found_remove = args.not_found_remove
    -- Node properties
    local lower_than = args.lower_than or 16
    local higher_than = args.higher_than or -1
    -- Find ids
    local nodes_to_find = args.to_find
    local find_ids = table.copy(placeholder_id_finder_pairs)
    for _, name in pairs(nodes_to_find) do
        table.insert(find_ids, minetest.get_content_id(name))
        local f_id = minetest.get_content_id(name)
        find_ids[f_id] = f_id
    end
    -- Replace ids
    local find_replace_pairs = args.find_replace_pairs
    local replace_ids = table.copy(placeholder_id_pairs)
    for to_find, replacement in pairs(find_replace_pairs) do
        local find_id = minetest.get_content_id(to_find)
        local replacement_id = minetest.get_content_id(replacement)
        replace_ids[find_id] = replacement_id
    end
    return function(pos_min, pos_max, vm_data, chance)
        local chance = chance or 1
        --local t1 = minetest.get_us_time()
        local found = false
        local data = vm_data.nodes
        local data_light = vm_data.light
        for i = 1, #data do
            local find_id = find_ids[data[i]]
            if find_id then
                if data[i] == find_id then
                    local above_index = i + chunk_side
                    local replacement = replace_ids[data[above_index]]
                    if data_light[above_index] and
                        data_light[above_index] > higher_than and
                        data_light[above_index] < lower_than
                    then
                        if chance >= math.random() and replacement then
                            data[above_index] = replacement
                            found = true
                        end
                    end
                elseif data[i] == ignore_id then
                    return {"worker_failed"}
                end
            end
        end
        if found then
            --minetest.log("error", string.format("elapsed time: %g ms", (minetest.get_us_time() - t1) / 1000))
            return labels_to_add, labels_to_remove
        else
            return not_found, not_found_remove
        end
    end
end

-- ideally logic from this file minetest/src/mapgen/mg_decoration.cpp
-- should be replicated in this function but I'm too lazy to do that
local function get_corners(deco, size)
    local corners = {}
    for z = 0, size.z, size.z do
        for y = 0, size.y, size.y do
            for x = 0, size.x, size.x do
                local v = vector.new(x, y, z)
                table.insert(corners, v)
            end
        end
    end
    local place_center_x = string.find(deco.flags, "place_center_x")
    local place_center_y = string.find(deco.flags, "place_center_y")
    local place_center_z = string.find(deco.flags, "place_center_z")
    local x_offset = 0
    local y_offset = 0
    local z_offset = 0
    if place_center_x then
        x_offset = math.floor(size.x / 2)
    end
    if place_center_y then
        y_offset = math.floor(size.y / 2)
    elseif deco.place_offset_y then
        y_offset = - deco.place_offset_y
    end
    if place_center_z then
        z_offset = math.floor(size.z / 2)
    end
    local offset = vector.new(x_offset, y_offset, z_offset)
    local corners_with_offset = {}
    for _, corner in pairs(corners) do
        local corner = corner
        corner = vector.subtract(corner, offset)
        table.insert(corners_with_offset, corner)
    end
    return corners_with_offset
end

function ms.create_neighbor_aware_replacer(args)
    local args = table.copy(args)
    local find_replace_pairs = args.find_replace_pairs
    local neighbors = args.neighbors
    local labels_to_add = args.add_labels or {}
    local labels_to_remove = args.remove_labels or {}
    table.insert(labels_to_remove, "worker_failed")
    local not_found = args.not_found_labels
    local not_found_remove = args.not_found_remove
    local ids = table.copy(placeholder_id_pairs)
    for to_find, replacement in pairs(find_replace_pairs) do
        local find_id = minetest.get_content_id(to_find)
        local replacement_id = minetest.get_content_id(replacement)
        ids[find_id] = replacement_id
    end
    local neighbor_ids = {}
    for _, neighbor in pairs(neighbors) do
        local id = minetest.get_content_id(neighbor)
        neighbor_ids[id] = true
    end
    return function(pos_min, pos_max, vm_data, chance)
        local chance = chance or 1
        --local t1 = minetest.get_us_time()
        local found = false
        local data = vm_data.nodes
        for i = 1, #data do
            local replacement = ids[data[i]]
            if replacement then
                if neighbor_ids[data[i - 1]] or
                    neighbor_ids[data[i + 1]] or
                    neighbor_ids[data[i - chunk_side]] or
                    neighbor_ids[data[i + chunk_side]] or
                    neighbor_ids[data[i - chunk_side^2]] or
                    neighbor_ids[data[i + chunk_side^2]] then
                    if chance >= math.random() then
                        data[i] = replacement
                    end
                end
                found = true
            elseif data[i] == ignore_id then
                return {"worker_failed"}
            end
        end
        if found then
            --minetest.log("error", string.format("elapsed time: %g ms", (minetest.get_us_time() - t1) / 1000))
            return labels_to_add, labels_to_remove, true
        else
            return not_found, not_found_remove
        end
    end
end

function ms.create_deco_finder(args)
    local args = table.copy(args)
    local deco_list = args.deco_list
    local labels_to_add = args.add_labels or {}
    local labels_to_remove = args.remove_labels or {}
    for _, deco in pairs(deco_list) do
        local id = minetest.get_decoration_id(deco.name)
        minetest.set_gen_notify({decoration = true}, {id})
        local corners = false
        if deco.schematic then
            local schematic = minetest.read_schematic(deco.schematic, {})
            corners = get_corners(deco, schematic.size)
        end
        minetest.register_on_generated(
            function(minp, maxp, blockseed)
                local gennotify = minetest.get_mapgen_object("gennotify")
                local pos_list = gennotify["decoration#"..id] or {}
                if #pos_list <= 0 then
                    return
                end
                local hash = ms.mapchunk_hash(minp)
                if not corners then
                    local ls = ms.label_store.new(hash)
                    ls:push_added_labels(labels_to_add)
                    ls:push_removed_labels(labels_to_remove)
                    ls:save_to_disk()
                    return
                end
                local label_stores = {}
                for _, pos in pairs(pos_list) do
                    for _, corner in pairs(corners) do
                        --add a 5% margin for schematic just in case
                        local wide = vector.multiply(corner, 1.05)
                        wide = vector.add(wide, 1)
                        wide = vector.floor(wide)
                        wide = vector.subtract(wide, 1)
                        local corner_pos = vector.add(pos, wide)
                        local corner_hash = ms.mapchunk_hash(corner_pos)
                        local ls = label_stores[corner_hash] or ms.label_store.new(corner_hash)
                        label_stores[corner_hash] = ls
                        ls:push_added_labels(labels_to_add)
                        ls:push_removed_labels(labels_to_remove)
                    end
                end
                for _, ls in pairs(label_stores) do
                    ls:save_to_disk()
                end
            end
        )
    end
end
