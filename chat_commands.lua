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

function ms.register_chat_commands(args)
    args = args or {}
    local get_workers = args.get_workers or function()
        return {}
    end
    local get_work_queue = args.get_work_queue or function()
        return {}
    end
    local get_min_working_time = args.get_min_working_time or function()
        return 0
    end
    local get_max_working_time = args.get_max_working_time or function()
        return 0
    end
    local get_median_working_time = args.get_median_working_time or function()
        return 0
    end
    local get_average_working_time = args.get_average_working_time or function()
        return 0
    end

    core.register_chatcommand(
        "shepherd_status", {
            description = S("Prints status of the Mapchunk Shepherd."),
            privs = {},
            func = function(name, param)
                local worker_names = {}
                for _, worker in pairs(get_workers()) do
                    table.insert(worker_names, worker.name)
                end
                worker_names = core.serialize(worker_names)
                worker_names = worker_names:gsub("return ", "")
                local nr_of_chunks = ms.tracked_chunk_counter()
                local tracked_chunks_status = S("Tracked chunks: ")..nr_of_chunks
                local work_queue_status = S("Work queue: ")..#get_work_queue()
                local work_time_status = S("Working time: ")..
                    S("Min: ")..math.ceil(get_min_working_time()).." ms | "..
                    S("Max: ")..math.ceil(get_max_working_time()).." ms | "..
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
                for _, tag in ipairs(tags) do
                    if not ms.tag.check(tag) then
                        return false, S("Unregistered label: ")..tag
                    end
                end
                local player = core.get_player_by_name(name)
                local pos = player:get_pos()
                local hash = ms.mapchunk_hash(pos)
                local ls = ms.label_store.new(hash)
                ls:add_labels(tags)
                ls:save_to_disk()
                return true, S("Added labels to chunk: ")..table.concat(tags, ", ")
            end,
    })
end
