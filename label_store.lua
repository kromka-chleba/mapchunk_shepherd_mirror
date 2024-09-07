--[[
    This is a part of "Perfect City".
    Copyright (C) 2024 Jan Wielkiewicz <tona_kosmicznego_smiecia@interia.pl>

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

ms.label_store = {}
local label_store = ms.label_store
label_store.__index = label_store

-- We're in mapgen env when 'minetest.save_gen_notify' is a function.
-- In the ordinary env 'minetest.save_gen_notify' is nil.
local mapgen_env = minetest.save_gen_notify
local mod_storage

if not mapgen_env then
    mod_storage = minetest.get_mod_storage()
end

function label_store.new(hash)
    local ls = setmetatable({}, label_store)
    ls.hash = hash
    ls.labels = {}
    ls.added_labels = {}
    ls.removed_labels = {}
    ls:read_from_disk()
    return ls
end

function label_store:reset_labels()
    self.added_labels = {}
    self.removed_labels = {}
    self.labels = {}
end

function label_store:set_hash(hash)
    self.hash = hash
    self:reset_labels()
end

function label_store:push_added_labels(...)
    local tags = ms.unpack_args(...)
    for _, tag in ipairs(tags) do
        self.added_labels[tag] = true
    end
end

function label_store:push_removed_labels(...)
    local tags = ms.unpack_args(...)
    for _, tag in ipairs(tags) do
        self.removed_labels[tag] = true
    end
end

function label_store:unpush_added_labels(...)
    local tags = ms.unpack_args(...)
    for _, tag in ipairs(tags) do
        self.added_labels[tag] = nil
    end
end

function label_store:unpush_removed_labels(...)
    local tags = ms.unpack_args(...)
    for _, tag in ipairs(tags) do
        self.removed_labels[tag] = nil
    end
end

function label_store:set_added()
    for name, _ in pairs(self.added_labels) do
        self.labels[name] = ms.label.new(name)
    end
    self.added_labels = {}
end

function label_store:set_removed()
    for name, _ in pairs(self.removed_labels) do
        self.labels[name] = nil
    end
    self.removed_labels = {}
end

-- Saves labels marked for addition and removal in 'self.labels' which
-- is the label buffer that can eventually get written into mod storage.
function label_store:set_labels()
    self:set_added()
    self:set_removed()
end

function label_store:add_labels(...)
    if mapgen_env then
        return
    end
    self:push_added_labels(...)
    self:set_added()
end

function label_store:remove_labels(...)
    if mapgen_env then
        return
    end
    self:push_removed_labels(...)
    self:set_removed()
end

-- Imports labels mod storage for the mapchunk.
function label_store:read_from_disk()
    if mapgen_env then
        return
    end
    local encoded = mod_storage:get_string(self.hash)
    local raw_labels = ms.label.decode(encoded)
    for _, raw in ipairs(raw_labels) do
        local label = ms.label.from_raw(raw)
        self.labels[label.name] = label
    end
end

-- Saves labels from 'self.labels' to mod storage for the mapchunk
-- with hash 'self.hash'.
function label_store:save_to_disk()
    if mapgen_env then
        return
    end
    self:set_labels()
    local encoded = ms.label.encode(self.labels)
    mod_storage:set_string(self.hash, encoded)
end

function label_store:contains_labels(...)
    local tags = ms.unpack_args(...)
    for _, tag in ipairs(tags) do
        if not self.labels[tag] then
            return false
        end
    end
    return true
end

function label_store:has_one_of(...)
    local tags = ms.unpack_args(...)
    if not next(tags) then
        return true
    end
    for _, tag in ipairs(tags) do
        if self.labels[tag] then
            return true
        end
    end
    return false
end

function label_store:get_labels()
    local labels = {}
    for _, label in pairs(self.labels) do
        table.insert(labels, label)
    end
    return labels
end

-- Returns labels from the label store filtered by tag, or 'nil' if no
-- labels with given tags were found. '...' is either a table of tags
-- or any number of tags (unpacked table).
function label_store:filter_labels(...)
    local tags = ms.unpack_args(...)
    local labels = {}
    for _, tag in ipairs(tags) do
        table.insert(labels, self.labels[tag])
    end
    return next(labels) and labels
end

function label_store:oldest_label(...)
    local labels = self:filter_labels(...) or self:get_labels()
    local oldest = labels[1]
    for _, label in ipairs(labels) do
        if oldest.timestamp < label.timestamp then
            oldest = label
        end
    end
    return oldest
end
