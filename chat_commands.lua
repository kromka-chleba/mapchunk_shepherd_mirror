--[[
    This is a part of "Mapchunk Shepherd".
    Copyright (C) 2026 Jan Wielkiewicz <tona_kosmicznego_smiecia@interia.pl>

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

local function parse_tags(param)
    local tags = {}
    for token in string.gmatch(param or "", "[^,%s]+") do
        table.insert(tags, token)
    end
    return tags
end

local function default_getters(args)
    return {
        get_workers = args.get_workers or function()
            return {}
        end,
        get_work_queue = args.get_work_queue or function()
            return {}
        end,
        get_min_working_time = args.get_min_working_time or function()
            return 0
        end,
        get_max_working_time = args.get_max_working_time or function()
            return 0
        end,
        get_median_working_time = args.get_median_working_time or function()
            return 0
        end,
        get_average_working_time = args.get_average_working_time or function()
            return 0
        end,
    }
end

local function get_player_hash(name)
    local player = core.get_player_by_name(name)
    if not player then
        return nil
    end
    local pos = player:get_pos()
    return ms.mapchunk_hash(pos)
end

local function worker_names(get_workers)
    local names = {}
    for _, worker in pairs(get_workers()) do
        table.insert(names, worker.name)
    end
    local serialized = core.serialize(names)
    return serialized:gsub("return ", "")
end

local function work_time_status(getters)
    return S("Working time: ")..
        S("Min: ")..math.ceil(getters.get_min_working_time()).." ms | "..
        S("Max: ")..math.ceil(getters.get_max_working_time()).." ms | "..
        S("Moving median: ")..getters.get_median_working_time().." ms | "..
        S("Moving average: ")..getters.get_average_working_time().." ms"
end

local function label_string(labels)
    local result = ""
    for _, label in pairs(labels) do
        result = result..label:description()..", "
    end
    return result
end

local function first_unregistered_tag(tags)
    for _, tag in ipairs(tags) do
        if not ms.tag.check(tag) then
            return tag
        end
    end
    return nil
end

local function register_shepherd_status(getters)
    core.register_chatcommand(
        "shepherd_status", {
            description = S("Prints status of the Mapchunk Shepherd."),
            privs = {},
            func = function(name, param)
                local tracked_chunks_status = S("Tracked chunks: ")..
                    ms.tracked_chunk_counter()
                local work_queue_status = S("Work queue: ")..#getters.get_work_queue()
                local worker_status = S("Workers: ")..worker_names(getters.get_workers)
                return true, tracked_chunks_status.."\n"..
                    work_queue_status.."\n"..work_time_status(getters).."\n"..
                    worker_status.."\n"
            end,
    })
end

local function register_chunk_labels()
    core.register_chatcommand(
        "chunk_labels", {
            description = S("Prints labels of the chunk where the player stands."),
            privs = {},
            func = function(name, param)
                local hash = get_player_hash(name)
                if not hash then
                    return false, S("Player not found.")
                end
                local ls = ms.label_store.new(hash)
                local labels = ls:get_labels()
                local last_changed = ms.time_since_last_change(hash)
                return true, S("hash: ")..hash.."\n"
                    ..S("last changed: ")..last_changed..S(" seconds ago").."\n"
                    ..S("labels: ")..label_string(labels).."\n "
            end,
    })
end

local function register_chunk_label_add()
    core.register_chatcommand(
        "chunk_label_add", {
            description = S("Adds one or more labels to the chunk where the player stands."),
            privs = {},
            params = S("<label>[, <label2> ...]"),
            func = function(name, param)
                local tags = parse_tags(param)
                if #tags == 0 then
                    return false, S("No labels provided.")
                end
                local unregistered = first_unregistered_tag(tags)
                if unregistered then
                    return false, S("Unregistered label: ")..unregistered
                end
                local hash = get_player_hash(name)
                if not hash then
                    return false, S("Player not found.")
                end
                local ls = ms.label_store.new(hash)
                ls:add_labels(tags)
                ls:save_to_disk()
                return true, S("Added labels to chunk: ")..table.concat(tags, ", ")
            end,
    })
end

function ms.register_chat_commands(args)
    local getters = default_getters(args or {})
    register_shepherd_status(getters)
    register_chunk_labels()
    register_chunk_label_add()
end
