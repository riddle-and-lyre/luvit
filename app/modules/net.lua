--[[

Copyright 2014 The Luvit Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS-IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

--]]

local uv = require('uv')
local timer = require('timer')
local utils = require('utils')
local table = require('table')
local core = require('core')
local Emitter = core.Emitter
local iStream = core.iStream
local Duplex = require('stream_duplex').Duplex

--[[ Socket ]]--

local Socket = Duplex:extend()

function Socket:initialize(handle)
  Duplex.initialize(self)
  self._handle = handle or uv.new_tcp()
  self._connecting = false
  self._reading = false
  self._destroyed = false

  self:on('finish', utils.bind(self._onSocketFinish, self))
  self:on('_socketEnd', utils.bind(self._onSocketEnd, self))
end

function Socket:_onSocketFinish()
  if self._connecting then
    return self:once('connect', utils.bind(self._onSocketFinish, self))
  end
  if not self.readable then
    return self:destroy()
  end
end

function Socket:_onSocketEnd()
  self:once('end', function()
    self:destroy()
  end)
end

function Socket:bind(ip, port)
  uv.tcp_bind(self._handle, ip, tonumber(port))
end

function Socket:_onTimeoutReal()
  self:emit('timeout')
end

function Socket:address()
  return uv.tcp_getpeername(self._handle)
end

function Socket:setTimeout(msecs, callback)
  if msecs > 0 then
    timer.enroll(self, msecs)
    timer.active(self)
    if callback then self:once('timeout', callback) end
  elseif msecs == 0 then
    timer.unenroll(self)
  end
end

function Socket:_write(data, encoding, callback)
  timer.active(self)
  uv.write(self._handle, data, function(err)
    timer.active(self)
    if err then
      return self:destroy(err)
    end
  end)
  callback()
end

function Socket:_read(n)
  local onRead
  timer.active(self)

  function onRead(err, data)
    timer.active(self)
    if err then
      return self:destroy(err)
    elseif data then
      self:push(data)
    else
      self:push(nil)
      self:emit('_socketEnd')
    end
  end

  if self.connecting then
    self:once('connect', utils.bind(self._read, self, n))
  elseif not self._reading then
    self._reading = true
    uv.read_start(self._handle, onRead)
  end
end

function Socket:shutdown(callback)
  if self.destroyed == true then
    return
  end
  
  if uv.is_closing(self._handle) then
    return callback()
  end

  uv.shutdown(self._handle, callback)
end

function Socket:nodelay(enable)
  uv.tcp_nodelay(self._handle, enable)
end

function Socket:keepalive(enable, delay)
  uv.tcp_keepalive(self._handle, enable, delay)
end

function Socket:pause()
  uv.read_stop(self._handle)
end

function Socket:done()
  self.writable = false

  self:shutdown(function()
    self:destroy(function()
      self:emit('close')
    end)
  end)
end

function Socket:connect(...)
  local args = {...}
  local options = {}
  local callback

  if type(args[1]) == 'table' then
    -- connect(options, [cb])
    options = args[1]
    callback = args[2]
  else
    -- connect(port, [host], [cb])
    options.port = args[1]
    if type(args[2]) == 'string' then
      options.host = args[2];
      callback = args[3]
    else
      callback = args[2]
    end
  end

  callback = callback or function() end

  if not options.host then
    options.host = '0.0.0.0'
  end

  timer.active(self)
  self._connecting = true

  uv.getaddrinfo(options.host, options.port, { socktype = "STREAM" }, function(err, res)
    timer.active(self)
    if err then
      return callback(err)
    end
    if not self._handle then
      return
    end
    timer.active(self)
    uv.tcp_connect(self._handle, res[1].addr, res[1].port, function(err)
      timer.active(self)
      if err then
        return callback(err)
      end
      self._connecting = false
      self:emit('connect')
      if callback then callback() end
    end)
  end)

  return self
end

function Socket:destroy(exception, callback)
  callback = callback or function() end
  if self.destroyed == true or self._handle == nil then
    return callback()
  end

  timer.unenroll(self)
  self.destroyed = true
  self.readable = false
  self.writable = false
    
  if uv.is_closing(self._handle) then
    return callback(exception)
  end

  uv.close(self._handle)
  self._handle = nil

  if (exception) then
    process.nextTick(function()
      self:emit('error', exception)
    end)
  end
end

function Socket:listen(queueSize)
  local onListen
  queueSize = queueSize or 128
  function onListen()
    local client = uv.new_tcp()
    uv.accept(self._handle, client)
    self:emit('connection', Socket:new(client))
  end
  uv.listen(self._handle, queueSize, onListen)
end

function Socket:getsockname()
  return uv.tcp_getsockname(self._handle)
end

--[[ Server ]]--

local Server = Socket:extend()
function Server:initialize(...)
  local args = {...}
  local options

  if #args == 1 then
    options = {}
    self.connectionCallback = args[1]
  elseif #args == 2 then
    options = args[1]
    self.connectionCallback = args[2]
  end

  if options.handle then
    self._handle = options.handle
  end

  if not self._handle then
    self._handle = Socket:new()
  end
end

function Server:listen(port, ... --[[ ip, callback --]] )
  local args = {...}
  local ip, callback, onConnection

  -- Future proof
  if type(args[1]) == 'function' then
    callback = args[1]
  else
    ip = args[1]
    callback = args[2]
  end

  ip = ip or '0.0.0.0'

  function onConnection(client)
    self.connectionCallback(client)
  end

  self._handle:bind(ip, port)
  self._handle:listen()
  self._handle:on('connection', onConnection)

  if callback then
    process.nextTick(callback)
  end

  return self
end

function Server:address()
  if self._handle then
    return self._handle:getsockname()
  end
  return nil
end

function Server:close(callback)
  self._handle:destroy(nil, callback)
end

-- Exports

exports.Server = Server

exports.Socket = Socket

exports.createConnection = function(port, ... --[[ host, cb --]])
  local args = {...}
  local host
  local options
  local callback

  -- future proof
  if type(port) == 'table' then
    options = port
    port = options.port
    host = options.host
    callback = args[1]
  else
    host = args[1]
    callback = args[2]
  end

  s = Socket:new()
  s:connect(port, host, callback)
  return s
end

exports.create = exports.createConnection

exports.createServer = function(...)
  return Server:new(...)
end
