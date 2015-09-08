local filesystem = require("filesystem")
local inetProxy = require("inetProxy")
local serialization = require("serialization")
local shell = require("shell")

local settings
local home = os.getenv("HOME")
local settingsFilename = filesystem.concat(home, "ftp.settings")
local settingsFile = io.open(settingsFilename, "rb")
if not settingsFile then
  print("Could not find settings.")
  local settingsFile, error = io.open(settingsFilename, "wb")
  if not settingsFile then
    print("Template could not be created (" .. error .. ")")
    print("Please make sure the directory '" .. home .. "' exists")
    return
  end
  
  local t =
  {
    proxy =
    {
      ip = "127.0.0.1",
      port = 16900,
    },
    ftp =
    {
      commandPort = 21,
      minDataPort = 16901,
      maxDataPort = 16950,
    },
    bufferSize = 1024,
  }
  local contents = serialization.serialize(t)
  settingsFile:write(contents)
  settingsFile:close()
  
  print("Template created.")
  print("Please edit '" .. settingsFilename .. "' and restart program")
  return
  
else
  local fileSize = settingsFile:seek("end", 0)
  settingsFile:seek("set", 0)
  
  local contents = settingsFile:read(fileSize)
  settingsFile:close()
  
  settings = serialization.unserialize(contents)
end

local proxyIp = settings.proxy.ip
local proxyIpComma = proxyIp:gsub("%.", ",")
local proxyPort = settings.proxy.port
local minDataPort = settings.ftp.minDataPort
local maxDataPort = settings.ftp.maxDataPort
local nextDataPort = minDataPort

local responses =
{
  r150 = "150 File status okay; about to open data connection.\r\n",
  r200 = "200 Command okay\r\n",
  r220 = "220 Service ready\r\n",
  r226 = "226 Closing data connection.\r\n",
  r230 = "230 User logged in\r\n",
  r250 = "250 Requested file action okay, completed.\r\n",
  r331 = "331 User name ok, need password\r\n",
  r350 = "350 Requested file action pending further information.\r\n",
  r502 = "502 Command not implemented.\r\n",
  r503 = "503 Bad sequence of commands.\r\n",
  r550 = "550 Requested action not taken.\r\n",
  r553 = "553 Requested action not taken.\r\n",
}

local function getPathArgument(msg)
  local space = msg:find(" ")
  local notSpace = msg:find("[^ ]", space)
  return msg:sub(notSpace)
end

local function findAbsolutePath(path, base)
  if path:sub(1, 1) ~= "/" then
    return filesystem.concat(base, path)
  else
    return path
  end
end

local function getNextDataPort()
  local currentPort = nextDataPort

  if nextDataPort == maxDataPort then
    nextDataPort = minDataPort
  else
    nextDataPort = nextDataPort + 1
  end

  return currentPort
end

local function portToComma(port)
  return math.floor(port / 256) .. "," .. (port % 256)
end

local function processDataListener(self, data)
  local dataClient = self:endAccept(data) 
  self:stop()
  
  if self.client.passiveAction then
    local action = self.client.passiveAction
    self.passiveAction = nil
    action(self.client, dataClient)
  else
    self.client.passiveClient = dataClient
  end
end

local function setupPassiveListener(listener, client)
  listener.process = processDataListener
  listener.client = client
end

local defaultActions = {}

defaultActions["USER"] = function(client, msg)
  io.write("> ", msg, "\n")
  client:send(responses.r331)
end

defaultActions["PASS"] = function(client, msg)
  io.write("> ", msg, "\n")
  client:send(responses.r230)
end

defaultActions["TYPE"] = function(client, msg)
  io.write("> ", msg, "\n")
  client:send(responses.r200)
end

defaultActions["MODE"] = function(client, msg)
  io.write("> ", msg, "\n")
  client:send(responses.r200)
end

defaultActions["STRU"] = function(client, msg)
  io.write("> ", msg, "\n")
  client:send(responses.r200)
end

defaultActions["PWD"] = function(client, msg)
  io.write("> ", msg, "\n")
  client:send("257 \"" .. client.currentDirectory .. "\" created.\r\n")
end

defaultActions["CWD"] = function(client, msg)
  io.write("> ", msg, "\n")
  client.currentDirectory = findAbsolutePath(getPathArgument(msg), client.currentDirectory)
  client:send(responses.r250)
end

defaultActions["PASV"] = function(client, msg)
  io.write("> ", msg, "\n")
  
  local port = getNextDataPort()
  local passiveListener = client.proxy:listener(port)
  setupPassiveListener(passiveListener, client)
  passiveListener:acceptOne()
  
  client.passiveListener = passiveListener
  
  local msg = "227 Entering Passive Mode (" .. proxyIpComma .. "," .. portToComma(port) .. ").\r\n"
  client:send(msg)
end

local function passiveList(client, passiveClient)
  client:send(responses.r150)
  local buffer = ""
  local maxSendSize = settings.bufferSize
  for f in filesystem.list(client.currentDirectory) do
    local filename = filesystem.name(f)
    local permission
    if filesystem.isDirectory(f) then
      permission = "drwxr-xr-x"
    else
      permission = "-rw-r--r--"
    end
    local size = filesystem.size(f)
    local msg = string.format("%s 1 user group %d Jan 01  2015 %s\r\n", permission, size, filename)
    buffer = buffer .. msg
    while #buffer > maxSendSize do
      local toSend = buffer:sub(1, maxSendSize)
      buffer = buffer:sub(maxSendSize + 1)
      
      passiveClient:send(toSend)
    end
  end
  
  if #buffer > 0 then
    passiveClient:send(buffer)
  end
  
  passiveClient:close()
  
  client:send(responses.r226)
end

defaultActions["LIST"] = function(client, msg)
  io.write("> ", msg, "\n")
  if client.passiveListener then
    client.passiveListener = nil
    if client.passiveClient then
      local passiveClient = client.passiveClient
      client.passiveClient = nil
      
      passiveList(client, passiveClient)
    else
      client.passiveAction = passiveList
    end
  else
    error("Assuming only passive data transfers")
  end
end

defaultActions["SIZE"] = function(client, msg)
  io.write("> ", msg, "\n")
  local path = findAbsolutePath(getPathArgument(msg), client.currentDirectory)
  local size = filesystem.size(path)
  local m = "213 " .. size .. "\r\n"
  client:send(m)
end

local function passiveRetrieve(client, passiveClient, path)
  client:send(responses.r150)

  local file = filesystem.open(path, "rb")

  local maxReadSize = settings.bufferSize
  
  while true do
    local buff = file:read(maxReadSize)
    if not buff then break end
    passiveClient:send(buff)
  end

  file:close()
  passiveClient:close()
  
  client:send(responses.r226)
end

defaultActions["RETR"] = function(client, msg)
  io.write("> ", msg, "\n")
  
  local path = findAbsolutePath(getPathArgument(msg), client.currentDirectory)
  
  if client.passiveListener then
    client.passiveListener = nil
    if client.passiveClient then
      local passiveClient = client.passiveClient
      client.passiveClient = nil
      
      passiveRetrieve(client, passiveClient, path)
    else
      client.passiveAction = function(client, passiveClient)
        passiveRetrieve(client, passiveClient, path)
      end
    end
  else
    error("Assuming only passive data transfers")
  end
end

local function processPassiveStore(self, data, client, file)
  local receivedData = self:endRead(data)
  if not receivedData then
    self:close()
    file:close()
    print("File written to disk")
    client:send(responses.r226)
  else
    file:write(receivedData)
  end
end

local function passiveStore(client, passiveClient, path)
  client:send(responses.r150)
  
  local file = filesystem.open(path, "wb")
  
  passiveClient.process = function(passiveClient, data)
    processPassiveStore(passiveClient, data, client, file)
  end
  
  passiveClient:readAll()
end

defaultActions["STOR"] = function(client, msg)
  io.write("> ", msg, "\n")
  
  local path = findAbsolutePath(getPathArgument(msg), client.currentDirectory)
  
  if client.passiveListener then
    client.passiveListener = nil
    if client.passiveClient then
      local passiveClient = client.passiveClient
      client.passiveClient = nil
      
      passiveStore(client, passiveClient, path)
    else
      client.passiveAction = function(client, passiveClient)
        passiveStore(client, passiveClient, path)
      end
    end
  else
    error("Assuming only passive data transfers")
  end
end

defaultActions["RNFR"] = function(client, msg)
  io.write("> ", msg, "\n")
  
  local path = findAbsolutePath(getPathArgument(msg), client.currentDirectory)
  
  if path == "/" then
    client:send(responses.r550)
  else
    client.renameFrom = path
    client:send(responses.r350)
  end
end

defaultActions["RNTO"] = function(client, msg)
  io.write("> ", msg, "\n")
  
  local from = client.renameFrom
  if not from then
    client:send(responses.r503)
    return
  end
  
  local to = findAbsolutePath(getPathArgument(msg), client.currentDirectory)
  
  if filesystem.rename(from, to) then
    client:send(responses.r250)
  else
    client:send(responses.r553)
  end
end

defaultActions["DELE"] = function(client, msg)
  io.write("> ", msg, "\n")
  
  local path = findAbsolutePath(getPathArgument(msg), client.currentDirectory)
  
  if path == "/" then
    client:send(responses.r550)
    return
  end
  
  if filesystem.remove(path) then
    client:send(responses.r250)
  else
    client:send(responses.r550)
  end
end

local function processClient(self, data)
  local msg = self:endRead(data)
  
  if not msg then
    self:close()
    return
  end
  
  self.readBuffer = self.readBuffer .. msg
  
  while true do
    local lineEnd = self.readBuffer:find("\r\n")
    if not lineEnd then break end
    
    local line = self.readBuffer:sub(1, lineEnd - 1)
    self.readBuffer = self.readBuffer:sub(lineEnd + 2)
    
    local space = line:find(" ")
    local cmd = line
    if space then
      cmd = line:sub(1, space - 1)
    end
    
    local action = defaultActions[cmd]
    if action then
      defaultActions[cmd](self, line)
    else
      print("Command '" .. cmd .. "' not supported")
      self:send(responses.r502)
    end
  end
end

local function setupClient(client)
  client.process = processClient
  client.currentDirectory = "/"
  client.readBuffer = ""
end

local proxy = inetProxy.connect(proxyIp, proxyPort)
if not proxy then
  print("FTP server interrupted while connecting to proxy")
  return
end

print("FTP server started and connected to proxy")

local cmdListener = proxy:listener(settings.ftp.commandPort)
function cmdListener:process(data)
  local client = self:endAccept(data)
  setupClient(client)
  client:readAll()
  client:send(responses.r220)
end
cmdListener:acceptAll()

while true do
  local s, data = proxy:select()
  if not s then
    print("FTP server interrupted")
    return
  end
  s:process(data)
end