local component = require("component")
local event = require("event")

local net = component.internet

---------------------------------------------------------

local function blockingRead(pSock, max)
  while true do
    local r = pSock:read(max)
    if #r > 0 then return r end
    local ev = event.pull(0, "interrupted")
    if ev == "interrupted" then
      return nil
    end
  end
end

local function readAll(pSock, bytesToRead)
  local res = ""
  while #res < bytesToRead do
    local r = blockingRead(pSock, bytesToRead - #res)
    if not r then return nil end
    res = res .. r
  end
  return res
end

local function readLine(pSock)
  local line = ""
  while true do
    local char = blockingRead(pSock, 1)
    if not char then return nil end

    if #char ~= 1 then error("reading 1 byte returned " .. #char .. " bytes") end

    if char == "\n" then
      return line
    else
      line = line .. char
    end
  end
end

local function readCmd(pSock)
  local msg = readLine(pSock)
  if not msg then return nil end

  local fields = {}
  msg:gsub("([^%s]+)", function(c) fields[#fields+1] = c end)
  return fields
end

---------------------------------------------------------

local SocketProxy = {type = "SocketProxy"}

function SocketProxy:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  return o
end

function SocketProxy:send(data)
  self.proxy:sendData(self, data)
end

function SocketProxy:readOnce(maxBytes)
  self.proxy:sendReadOnce(self, maxBytes)
end

function SocketProxy:readAll()
  self.proxy:sendReadAll(self)
end

function SocketProxy:endRead(data)
  return data["data"], data["error"]
end

function SocketProxy:close()
  self.proxy:closeSocketProxy(self)
end

---------------------------------------------------------

local Listener = {type = "Listener"}

function Listener:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  return o
end

function Listener:acceptOne()
  self.proxy:sendAcceptOne(self.port)
end

function Listener:acceptAll()
  self.proxy:sendAcceptAll(self.port)
end

function Listener:endAccept(data)
  local s = SocketProxy:new{id = data[3], proxy = self.proxy}
  self.proxy:addSocketProxy(s)
  return s
end

function Listener:stop()
  self.proxy:stopListener(self)
end

---------------------------------------------------------

local Proxy = {type = "Proxy"}

function Proxy:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  o.listeners = {}
  o.socketProxies = {}
  return o
end

function Proxy:listener(port)
  if self.listeners[port] then error("Already listening on port " .. port) end
  
  local l = Listener:new{port = port, proxy = self}
  self.listeners[port] = l
  self:send("LISTEN " .. port .. "\n")
  return l
end

function Proxy:stopListener(listener)
  self.listeners[listener.port] = nil
  self:send("STOP_LISTEN " .. listener.port .. "\n")
end

function Proxy:addSocketProxy(socketProxy)
  self.socketProxies[socketProxy.id] = socketProxy
end

function Proxy:closeSocketProxy(socketProxy)
  if self.socketProxies[socketProxy.id] then
    self.socketProxies[socketProxy.id] = nil
    self:send("CLOSE_CONNECTION " .. socketProxy.id .. "\n")
  end
end

function Proxy:sendAcceptOne(port)
  self:send("ACCEPT_ONE " .. port .. "\n")
end

function Proxy:sendAcceptAll(port)
  self:send("ACCEPT_ALL " .. port .. "\n")
end

function Proxy:sendData(socketProxy, data)
  if self.socketProxies[socketProxy.id] then
    self:send("SEND " .. socketProxy.id .. " " .. #data .. "\n")
    self:send(data)
  else
    error("Cannot send on a closed socket")
  end
end

function Proxy:sendReadOnce(socketProxy, maxBytes)
  self:send("READ_ONCE " .. socketProxy.id .. " " .. maxBytes .. "\n")
end

function Proxy:sendReadAll(socketProxy)
  self:send("READ_ALL " .. socketProxy.id .. "\n")
end

function Proxy:send(msg)
  self.socket.write(msg)
end

function Proxy:select()
  while true do
    local cmd = readCmd(self.socket)
    if not cmd then return nil, "interrupted" end
    
    if cmd[1] == "CONNECTION" then
      local l = self.listeners[tonumber(cmd[2])]
      if l then
        return l, cmd
      end
    elseif cmd[1] == "DATA" then
      local d = readAll(self.socket, tonumber(cmd[3]))
      if not d then return nil, "interrupted" end
      cmd["data"] = d
      
      local s = self.socketProxies[cmd[2]]
      if s then
        return s, cmd
      end
    elseif cmd[1] == "CLOSED" then
      cmd["error"] = "Connection closed"
      
      local s = self.socketProxies[cmd[2]]
      if s then
        self.socketProxies[cmd[2]] = nil
        return s, cmd
      end
    else
      error("Unknow command " .. cmd[1])
    end
  end
end

---------------------------------------------------------

local inetProxy = {}

function inetProxy.connect(host, port, period)
  period = period or 1

  local proxySock = net.connect(host, port)
  while not proxySock:finishConnect() do
    local ev = event.pull(period, "interrupted")
    if ev == "interrupted" then
      return nil, "interrupted"
    end
  end
  
  return Proxy:new{socket = proxySock}
end

---------------------------------------------------------

return inetProxy
