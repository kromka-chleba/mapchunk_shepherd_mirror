--[[
    This is a part of "Mapchunk Shepherd".
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

--[[
    Label store is a class of objects that serve as a buffer for
    labels (see labels.lua) for a given mapblock. Label store provides
    two buffers for labels - self.staged_labels and self.labels.  The
    first one keeps labels that were marked for addition or removal in
    the label store, the second keeps the state of the
    mapblock. Labels can be moved from self.staged_labels to
    self.labels by using self:set_labels().  Labels from
    self.staged_labels can be sent from mapgen env to normal env using
    gennotify. Labels from self.labels can be saved to mod storage in
    the ordinary env. By default creating a new label store will get
    labels from mod storage (if available).
--]]

ms.label_store = {}
local label_store = ms.label_store
label_store.__index = label_store

-- We're in mapgen env when 'core.save_gen_notify' is a function.
-- In the ordinary env 'core.save_gen_notify' is nil.
local mapgen_env = core.save_gen_notify
local mod_storage

if not mapgen_env then
    mod_storage = core.get_mod_storage()
end

-- Creates a new label_store object. 'blockpos' is the mapblock position
-- (table with x, y, z coordinates in mapblock units).
-- Initializes the object with labels saved in mod storage (if available).
-- Returns the label store object.
function label_store.new(blockpos)
    local ls = setmetatable({}, label_store)
    ls.blockpos = blockpos
    ls.staged_labels = {} -- stores label state, keyed by tag
    ls.labels = {} -- stores label objects, keyed by tag
    if not mapgen_env then
        ls:read_from_disk()
    end
    return ls
end

-- Clears both label buffers
function label_store:reset_labels()
    self.staged_labels = {}
    self.labels = {}
end

-- Sets the blockpos of the label store.
function label_store:set_blockpos(blockpos)
    self.blockpos = blockpos
    self:reset_labels()
    if not mapgen_env then
        self:read_from_disk()
    end
end

local lab_state = {
    add = "add",
    remove = "remove",
}

-- Marks labels for addition in the self.staged_labels buffer. This
-- means labels were prepared to be added, but need to be set using
-- 'label_store:set_labels' in order to prepare them for writing to
-- mod storage. '...' is a list of tags (either a table or
-- an unpacked table).
function label_store:mark_for_addition(...)
    local tags = ms.unpack_args(...)
    for _, tag in ipairs(tags) do
        if self.staged_labels[tag] == lab_state.remove then
            self.staged_labels[tag] = nil
        else
            self.staged_labels[tag] = lab_state.add
        end
    end
end

-- Marks labels for removal in the self.staged_labels buffer. This
-- means labels were prepared to be removed, but need to be set using
-- 'label_store:set_labels' in order to prepare them for removal from
-- mod storage. '...' is a list of tags (either a table or
-- an unpacked table).
function label_store:mark_for_removal(...)
    local tags = ms.unpack_args(...)
    for _, tag in ipairs(tags) do
        if self.staged_labels[tag] == lab_state.add then
            self.staged_labels[tag] = nil
        else
            self.staged_labels[tag] = lab_state.remove
        end
    end
end

-- Saves labels marked for addition and removal in 'self.labels' which
-- is the label buffer that can eventually get written into mod storage.
function label_store:set_labels()
    for tag, state in pairs(self.staged_labels) do
        if state == lab_state.add then
            self.labels[tag] = ms.label.new(tag)
        elseif state == lab_state.remove then
            self.labels[tag] = nil
        end
        self.staged_labels[tag] = nil
    end
end

-- Checks if a method with name 'method_name' was used in the mapgen
-- env, asserts if so.
local function check_mapgen_env(method_name)
    assert(not mapgen_env,
           string.format(
               "Mapchunk Shepherd: label_store: "..
               "trying to call the '%s' method from the mapgen env.",
               method_name))
end

-- Marks labels for addition in the 'self.labels' buffer. This means
-- they will be added to mod storage if 'label_store:save_to_disk' is
-- ran for the label store. '...' is a list of tags (either a table or
-- an unpacked table).
function label_store:add_labels(...)
    check_mapgen_env("add_labels")
    self:mark_for_addition(...)
    self:set_labels()
end

-- Marks labels for removal in the 'self.labels' buffer. This means
-- they will be removed from mod storage if 'label_store:save_to_disk'
-- is ran for the label store. '...' is a list of tags (either a table or
-- an unpacked table).
function label_store:remove_labels(...)
    check_mapgen_env("remove_labels")
    self:mark_for_removal(...)
    self:set_labels()
end

-- Imports labels mod storage for the mapblock, saves them in 'self.labels'
function label_store:read_from_disk()
    check_mapgen_env("read_from_disk")
    local storage_key = ms.get_storage_key(self.blockpos)
    local encoded = mod_storage:get_string(storage_key)
    local labels = ms.label.decode(encoded)
    for _, label in ipairs(labels) do
        self.labels[label.name] = label
    end
end

-- Saves labels from 'self.labels' to mod storage for the mapblock
-- tracked by the label store.
function label_store:save_to_disk()
    check_mapgen_env("save_to_disk")
    self:set_labels()
    local storage_key = ms.get_storage_key(self.blockpos)
    
    -- Check if this is a new entry (mapblock not previously tracked)
    local existing = mod_storage:get_string(storage_key)
    local is_new_entry = (existing == "" or existing == nil)
    
    -- Check if we have any labels to save
    local has_labels = next(self.labels) ~= nil
    
    local encoded = ms.label.encode(self.labels)
    mod_storage:set_string(storage_key, encoded)
    
    -- Increment counter if this is a new tracked mapblock with labels
    if is_new_entry and has_labels then
        ms.bump_tracked_counter()
    end
end

-- Checks if the label store contains labels given by '...', which is
-- a list of tags (either a table or an unpacked table). It checks
-- only in 'self.labels'. Returns a boolean.
function label_store:contains_labels(...)
    local tags = ms.unpack_args(...)
    for _, tag in ipairs(tags) do
        if not self.labels[tag] then
            return false
        end
    end
    return true
end

-- Checks if the label store contains at least one of the labels given
-- by '...', which is a list of tags (either a table or an unpacked
-- table). It checks only in 'self.labels'. Returns a boolean.
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

-- Gets all labels stored in 'self.labels' of the label store. Returns
-- an ordered list (array) of label objects (see labels.lua).
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

-- Returns the label object from 'self.labels' with the oldest
-- timestamp. '...', is a list of tags (either a table or an unpacked
-- table), if given, it will pick the oldest labels with these tags.
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

-- Checks if a method with name 'method_name' was used not in the
-- mapgen env, if so asserts.
local function check_env(method_name)
    assert(mapgen_env,
           string.format(
               "Mapchunk Shepherd: label_store: "..
               "trying to call the '%s' method from normal env.\n"..
               "This method can be only called fron mapgen env.",
               method_name))
end

-- Saves staged labels into the shepherd's gennotify labeler object
-- "mapchunk_shepherd:labeler". This means labels that were marked as
-- added/removed will be sent as a gennotify to the ordinary env and
-- will get added/removed to/from mod storage.
function label_store:save_gen_notify()
    check_env("save_gen_notify")
    if not next(self.staged_labels) then
        return
    end
    local gennotify = core.get_mapgen_object("gennotify")
    local obj = gennotify.custom["mapchunk_shepherd:labeler"] or {}
    local change = {
        self.blockpos,
        self.staged_labels,
    }
    table.insert(obj, change)
    core.save_gen_notify("mapchunk_shepherd:labeler", obj)
end
