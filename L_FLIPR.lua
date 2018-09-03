-- // This program is free software: you can redistribute it and/or modify
-- // it under the condition that it is for private or home useage and
-- // this whole comment is reproduced in the source code file.
-- // Commercial utilisation is not authorized without the appropriate
-- // written agreement from amg0 / alexis . mermet @ gmail . com
-- // This program is distributed in the hope that it will be useful,
-- // but WITHOUT ANY WARRANTY; without even the implied warranty of
-- // MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE .
local MSG_CLASS		= "FLIPR"
local FLIPR_SERVICE	= "urn:upnp-org:serviceId:flipr1"
local devicetype	= "urn:schemas-upnp-org:device:flipr:1"
-- local this_device	= nil
local DEBUG_MODE	= false -- controlled by UPNP action
local version		= "v0.3"
local JSON_FILE = "D_FLIPR.json"
local UI7_JSON_FILE = "D_FLIPR_UI7.json"
local DEFAULT_REFRESH = 3600
local RAND_DELAY	= 10
-- local hostname		= ""

local json = require("dkjson")
local mime = require('mime')
local socket = require("socket")
local http = require("socket.http")
local https = require ("ssl.https")
local ltn12 = require("ltn12")
local modurl = require ("socket.url")

------------------------------------------------
-- Debug --
------------------------------------------------
function log(text, level)
  luup.log(string.format("%s: %s", MSG_CLASS, text), (level or 50))
end

function debug(text)
  if (DEBUG_MODE) then
	log("debug: " .. text)
  end
end

function warning(stuff)
  log("warning: " .. stuff, 2)
end

function error(stuff)
  log("error: " .. stuff, 1)
end

local function isempty(s)
  return s == nil or s == ""
end

------------------------------------------------
-- VERA Device Utils
------------------------------------------------
local function getParent(lul_device)
  return luup.devices[lul_device].device_num_parent
end

local function getAltID(lul_device)
  return luup.devices[lul_device].id
end

-----------------------------------
-- from a altid, find a child device
-- returns 2 values
-- a) the index === the device ID
-- b) the device itself luup.devices[id]
-----------------------------------
local function findChild( lul_parent, altid )
  -- debug(string.format("findChild(%s,%s)",lul_parent,altid))
  for k,v in pairs(luup.devices) do
	if( getParent(k)==lul_parent) then
	  if( v.id==altid) then
		return k,v
	  end
	end
  end
  return nil,nil
end

local function getParent(lul_device)
  return luup.devices[lul_device].device_num_parent
end

local function getRoot(lul_device)
  while( getParent(lul_device)>0 ) do
	lul_device = getParent(lul_device)
  end
  return lul_device
end

------------------------------------------------
-- Device Properties Utils
------------------------------------------------
local function getSetVariable(serviceId, name, deviceId, default)
  local curValue = luup.variable_get(serviceId, name, deviceId)
  if (curValue == nil) then
	curValue = default
	luup.variable_set(serviceId, name, curValue, deviceId)
  end
  return curValue
end

local function getSetVariableIfEmpty(serviceId, name, deviceId, default)
  local curValue = luup.variable_get(serviceId, name, deviceId)
  if (curValue == nil) or (curValue:trim() == "") then
	curValue = default
	luup.variable_set(serviceId, name, curValue, deviceId)
  end
  return curValue
end

local function setVariableIfChanged(serviceId, name, value, deviceId)
  debug(string.format("setVariableIfChanged(%s,%s,%s,%s)",serviceId, name, value or 'nil', deviceId))
  local curValue = luup.variable_get(serviceId, name, tonumber(deviceId)) or ""
  value = value or ""
  if (tostring(curValue)~=tostring(value)) then
	luup.variable_set(serviceId, name, value or '', tonumber(deviceId))
  end
end

local function setAttrIfChanged(name, value, deviceId)
  debug(string.format("setAttrIfChanged(%s,%s,%s)",name, value or 'nil', deviceId))
  local curValue = luup.attr_get(name, deviceId)
  if ((value ~= curValue) or (curValue == nil)) then
	luup.attr_set(name, value or '', deviceId)
	return true
  end
  return value
end

local function getIP()
  -- local stdout = io.popen("GetNetworkState.sh ip_wan")
  -- local ip = stdout:read("*a")
  -- stdout:close()
  -- return ip
  local mySocket = socket.udp ()
  mySocket:setpeername ("42.42.42.42", "424242")  -- arbitrary IP/PORT
  local ip = mySocket:getsockname ()
  mySocket: close()
  return ip or "127.0.0.1"
end

------------------------------------------------
-- Tasks
------------------------------------------------
local taskHandle = -1
local TASK_ERROR = 2
local TASK_ERROR_PERM = -2
local TASK_SUCCESS = 4
local TASK_BUSY = 1

--
-- Has to be "non-local" in order for MiOS to call it :(
--
local function task(text, mode)
  if (mode == TASK_ERROR_PERM)
  then
	error(text)
  elseif (mode ~= TASK_SUCCESS)
  then
	warning(text)
  else
	log(text)
  end
  
  if (mode == TASK_ERROR_PERM)
  then
	taskHandle = luup.task(text, TASK_ERROR, MSG_CLASS, taskHandle)
  else
	taskHandle = luup.task(text, mode, MSG_CLASS, taskHandle)

	-- Clear the previous error, since they're all transient
	if (mode ~= TASK_SUCCESS)
	then
	  luup.call_delay("clearTask", 15, "", false)
	end
  end
end

function clearTask()
  task("Clearing...", TASK_SUCCESS)
end

local function UserMessage(text, mode)
  mode = (mode or TASK_ERROR)
  task(text,mode)
end

------------------------------------------------
-- LUA Utils
------------------------------------------------
local function Split(str, delim, maxNb)
  -- Eliminate bad cases...
  if string.find(str, delim) == nil then
	return { str }
  end
  if maxNb == nil or maxNb < 1 then
	maxNb = 0	 -- No limit
  end
  local result = {}
  local pat = "(.-)" .. delim .. "()"
  local nb = 0
  local lastPos
  for part, pos in string.gmatch(str, pat) do
	nb = nb + 1
	result[nb] = part
	lastPos = pos
	if nb == maxNb then break end
  end
  -- Handle the last field
  if nb ~= maxNb then
	result[nb + 1] = string.sub(str, lastPos)
  end
  return result
end

function string:fliprsplit(sep) -- from http://lua-users.org/wiki/SplitJoin	 : changed as consecutive delimeters was not returning empty strings
	return Split(self, sep)
end

-- function string:split(sep) -- from http://lua-users.org/wiki/SplitJoin	 : changed as consecutive delimeters was not returning empty strings
  -- return Split(self, sep)
-- end

function string:template(variables)
  return (self:gsub('@(.-)@',
	function (key)
	  return tostring(variables[key] or '')
	end))
end

function string:trim()
  return self:match "^%s*(.-)%s*$"
end

local function tablelength(T)
  local count = 0
  if (T~=nil) then
  for _ in pairs(T) do count = count + 1 end
  end
  return count
end

------------------------------------------------
-- Communication TO FLIPR system
------------------------------------------------
-- POST	/ url	encode		https://apis.goflipr.com/OAuth2/token	
-- GET https://apis.goflipr.com/modules/{serial}/survey/last 

-- local function IOExec(command)
	-- debug(string.format("IOExec(%s)",command))
    -- local result = nil
	-- local file = io.popen(command)
	-- if file then
		-- result = file:read("*a")
		-- file:close()
	-- end
	-- return result
-- end

-- local function MyHttpsRequest( obj )
	-- debug(string.format("MyHttpsRequest(%s)",json.encode(obj)))
	-- local cmd = {}
	-- table.insert(cmd, "curl")
	-- table.insert(cmd, "--request " .. obj.method or 'GET')
	-- table.insert(cmd, "--url " .. obj.url or '')
	-- for key,val in pairs(obj.headers or {}) do
		-- table.insert(cmd, string.format("--header '%s: %s'",key,val ))
	-- end
	-- table.insert(cmd, string.format("--data '%s'",obj.source) )
	-- cmd = table.concat(cmd," " )
	
	-- local result = IOExec(cmd)
	-- if (result == nil) then
		-- warning(string.format("IOExec of commend(%s) returned nil",cmd))
		-- return nil,nil
	-- end
	-- return true,result
-- end

local function FLIPRHttpCall(lul_device,verb,cmd,body)
	local result = {}
	verb = verb or "GET"
	cmd = cmd or ""
	body = body or ""
	debug(string.format("FLIPRHttpCall(%d,%s,%s,%s,%s)",lul_device,verb, cmd,body,serial or ''))
	local serial = getSetVariable(FLIPR_SERVICE, "Serial", lul_device, "")
	local credentials = getSetVariable(FLIPR_SERVICE, "Credentials", lul_device, "")
	local newUrl = (verb=="POST") and string.format("https://apis.goflipr.com/%s",cmd) 
								  or string.format("https://apis.goflipr.com/modules/%s/%s",serial,cmd)
					
	debug(string.format("Calling FLIPR with %s %s , body:%s",verb,newUrl,body))
	local headers = {
		-- ["Connection"]= "keep-alive",
		-- ["Accept"]="text/plain, */*; q=0.01"
		["Content-Length"] = body:len(),
		["Cache-Control"] =  'no-cache',
		["Content-Type"] = "application/x-www-form-urlencoded",
		-- ["Origin"]="http://192.168.1.5",
		-- ["User-Agent"]="Mozilla/5.0 (Windows NT 6.1; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/43.0.2357.134 Safari/537.36",
		-- ["X-Requested-With"]="XMLHttpRequest",
		-- ["Accept-Encoding"]="gzip, deflate",
		-- ["Accept-Language"]= "fr,fr-FR;q=0.8,en;q=0.6,en-US;q=0.4",
	}
	if not (isempty(credentials)) then 
		headers["Authorization"] = string.format("Bearer %s",credentials)
	end
	
	local request, code, data = nil,nil,nil
	
	-- For some reasons https.request ceased to work. I have not figured out why yet, that s a pitty, I fall back on io.popen( curl )
	-- found it, it was protocol restriction TLS 1.2 only
	-- if (true) then
		request, code, headers = https.request({
			protocol="tlsv1_2",		-- mandatory, otherwise it fails ( and curl works )
			method=verb,
			url = newUrl,
			source= ltn12.source.string(body),
			headers = headers,
			sink = ltn12.sink.table(result)
		})

		-- fail to connect
		if (request==nil) then
			error(string.format("failed to connect to %s, http.request returned nil", newUrl))
			return nil,"failed to connect"
		elseif (code==401) then
			warning(string.format("Access requires a user/password: %d", code))
			return nil,"unauthorized access - 401"
		elseif (code~=200) then
			warning(string.format("http.request returned a bad code: %d", code))
			return nil,"unvalid return code:" .. code
		end

		-- everything looks good
		data = table.concat(result)
		debug(string.format("request:%s",request))
		debug(string.format("code:%s",code))
		debug(string.format("headers:%s",json.encode(headers)))
		debug(string.format("data:%s",data or ""))
	-- else
		-- request,data = MyHttpsRequest({
			-- method=verb,
			-- url = newUrl,
			-- source= body,
			-- headers = headers
		-- })
		-- if (request==nil) then
			-- return nil,nil
		-- end
	-- end
	return json.decode(data) ,""
end

local function FLIPR_getToken(lul_device,usr,pwd,serial)
	debug(string.format("FLIPR_getToken(%s,%s,%s,%s)",lul_device,usr,pwd,serial))
	local res,msg = FLIPRHttpCall(lul_device,
		'POST',
		'OAuth2/token',
		string.format('grant_type=password&password=%s&username=%s',pwd,usr) -- MyVariableOne=ValueOne&MyVariableTwo=ValueTwo
	)
	if (res~=nil) then
		setVariableIfChanged(FLIPR_SERVICE, "Credentials", res.access_token, lul_device)
		setVariableIfChanged(FLIPR_SERVICE, "User", usr, lul_device )
		setVariableIfChanged(FLIPR_SERVICE, "Password", pwd, lul_device )
		setVariableIfChanged(FLIPR_SERVICE, "Serial", serial, lul_device )
		setVariableIfChanged(FLIPR_SERVICE, "IconCode", "100", lul_device)
	else
		setVariableIfChanged(FLIPR_SERVICE, "IconCode", "0", lul_device)
	end
	return { result=res, message=msg }
end

local function FLIPR_getData(lul_device)
	debug(string.format("FLIPR_getData(%s)",lul_device))
	local serial = getSetVariable(FLIPR_SERVICE, "Serial", lul_device, "")
	local res,msg = FLIPRHttpCall(lul_device, 'GET', 'survey/last') 
	return { result=res, message=msg }
end

------------------------------------------------------------------------------------------------
-- Http handlers : Communication FROM ALTUI
-- http://192.168.1.5:3480/data_request?id=lr_FLIPR_Handler&command=xxx
-- recommended settings in ALTUI: PATH = /data_request?id=lr_FLIPR_Handler&mac=$M&deviceID=114
------------------------------------------------------------------------------------------------
local function switch( command, actiontable)
  -- check if it is in the table, otherwise call default
  if ( actiontable[command]~=nil ) then
	return actiontable[command]
  end
  warning("FLIPR_Handler:Unknown command received:"..command.." was called. Default function")
  return actiontable["default"]
end

function myFLIPR_Handler(lul_request, lul_parameters, lul_outputformat)
  debug('myFLIPR_Handler: request is: '..tostring(lul_request))
  debug('myFLIPR_Handler: parameters is: '..json.encode(lul_parameters))
  local lul_html = "";	-- empty return by default
  local mime_type = "";
  -- if (hostname=="") then
	-- hostname = getIP()
	-- debug("now hostname="..hostname)
  -- end

  -- find a parameter called "command"
  if ( lul_parameters["command"] ~= nil ) then
	command =lul_parameters["command"]
  else
	  debug("FLIPR_Handler:no command specified, taking default")
	command ="default"
  end

  local deviceID = tonumber( lul_parameters["DeviceNum"] ) -- or findTHISDevice() )

  -- switch table
  local action = {

	  ["default"] =
	  function(params)
		return "default handler / not successful", "text/plain"
	  end,

	  ["get_token"] =
	  function(params)
		local usr = modurl.unescape(lul_parameters["user"] or "")
		local pwd = modurl.unescape(lul_parameters["password"] or "")
		local serial = modurl.unescape(lul_parameters["serial"] or "")
		local result = FLIPR_getToken(deviceID,usr,pwd,serial)
		return json.encode(result or {}), "application/json"
	  end,
	  
	  ["get_data"] =
	  function(params)
		local result = FLIPR_getData(deviceID)
		return json.encode(result or {}), "application/json"
	  end,
	  -- ["config"] =
	  -- function(params)
		-- local url = lul_parameters["url"] or ""
		-- local data,msg = FLIPRHttpCall(deviceID,"GET",url)
		-- return json.encode(data or {}), "application/json"
	  -- end,  
  }
  -- actual call
  lul_html , mime_type = switch(command,action)(lul_parameters)
  if (command ~= "home") and (command ~= "oscommand") then
	debug(string.format("lul_html:%s",lul_html or ""))
  end
  return (lul_html or "") , mime_type
end

------------------------------------------------
-- UPNP Actions Sequence
------------------------------------------------

local function setDebugMode(lul_device,newDebugMode)
  lul_device = tonumber(lul_device)
  newDebugMode = tonumber(newDebugMode) or 0
  debug(string.format("setDebugMode(%d,%d)",lul_device,newDebugMode))
  luup.variable_set(FLIPR_SERVICE, "Debug", newDebugMode, lul_device)
  if (newDebugMode==1) then
	DEBUG_MODE=true
  else
	DEBUG_MODE=false
  end
end


--------------------------------------------------------
-- Core engine 
--------------------------------------------------------
local function PairWithFLIPR(lul_device)
	debug(string.format("PairWithFLIPR(%s)",lul_device))
	local success = true
	local credentials = getSetVariable(FLIPR_SERVICE, "Credentials", lul_device, "")
	if (isempty(credentials)) then
		local user = getSetVariable(FLIPR_SERVICE, "User", lul_device, "")
		local pwd = getSetVariable(FLIPR_SERVICE, "Password", lul_device, "")
		local serial = getSetVariable(FLIPR_SERVICE, "Serial", lul_device, "")
		local data = FLIPR_getToken(lul_device,usr,pwd,serial)
		success = (data.result ~= nil)
	end
	return success
end

local function calculateBattery(value)
	return 100 - tonumber(value)
end

local DataDecodeMap = {
	["OxydoReductionPotentiel.Value"] 	= { variable="OxydoReduction", service=FLIPR_SERVICE },
	["PH.Value"] 						= { variable="PH", service=FLIPR_SERVICE },
	["Desinfectant.Deviation"] 			= { variable="Desinfectant_Deviation", service=FLIPR_SERVICE },
	["UvIndex"]							= { variable="UvIndex", service=FLIPR_SERVICE },
	["Temperature"]						= { variable="CurrentTemperature", service="urn:upnp-org:serviceId:TemperatureSensor1" },
	["CloudCoverage"] 					= { variable="CloudCoverage", service=FLIPR_SERVICE },
	["Battery.Deviation"] 				= { variable="BatteryLevel", service="urn:micasaverde-com:serviceId:HaDevice1", func=calculateBattery }
}

function refreshFLIPRData(lul_device,norefresh)
	local success=false
	norefresh = norefresh or false
	debug(string.format("refreshFLIPRData(%s,%s)",lul_device,tostring(norefresh)))
	lul_device = tonumber(lul_device)
	
	local data = FLIPR_getData(lul_device)
	success = (data.result ~= nil )
	
	if (success==true) then
		-- decoding according to map
		for key,entry in pairs(DataDecodeMap) do
			local flipr_data = data.result
			-- debug(string.format("entry:%s",json.encode(entry)))
			-- debug(string.format("flipr_data:%s",json.encode(flipr_data)))
			local parts = Split(key,'%.')
			-- debug(string.format("parts:%s",json.encode(parts)))
			for i,path in pairs(parts) do
				-- debug(string.format("path:%s",json.encode(path)))
				flipr_data = flipr_data[ path ]
				-- debug(string.format("flipr_data:%s",json.encode(flipr_data)))
			end
			if (entry.variable ~=nil) then
				if (entry.func~=nil) then
					flipr_data = (entry.func)(flipr_data)
				end
				if (flipr_data ~=nil) then
					setVariableIfChanged(entry.service, entry.variable, flipr_data, lul_device )
				end
			end
		end
		-- program next refresh
		luup.variable_set(FLIPR_SERVICE, "LastValidComm", os.time(), lul_device)
		if (norefresh==false) then
			local period= getSetVariable(FLIPR_SERVICE, "RefreshPeriod", lul_device, DEFAULT_REFRESH)
			debug(string.format("programming next refreshFLIPRData(%s) in %s sec",lul_device,period))
			luup.call_delay("refreshFLIPRData",period,tostring(lul_device))
		end
	else
		warning(string.format("FLIPR_getData did not succeed, engine is stopped until the next reload"))
	end
	return success
end

local function startEngine(lul_device)
	debug(string.format("startEngine(%s)",lul_device))
	local success=false
	lul_device = tonumber(lul_device)
	success = PairWithFLIPR(lul_device) and refreshFLIPRData(lul_device)
	return success
end

function startupDeferred(lul_device)
	lul_device = tonumber(lul_device)
	log("startupDeferred, called on behalf of device:"..lul_device)

	local debugmode = getSetVariable(FLIPR_SERVICE, "Debug", lul_device, "0")
	local oldversion = getSetVariable(FLIPR_SERVICE, "Version", lul_device, "")
	local period = getSetVariable(FLIPR_SERVICE, "RefreshPeriod", lul_device, DEFAULT_REFRESH)
	local credentials = getSetVariable(FLIPR_SERVICE, "Credentials", lul_device, "")
	local user = getSetVariable(FLIPR_SERVICE, "User", lul_device, "")
	local pwd = getSetVariable(FLIPR_SERVICE, "Password", lul_device, "")
	local serial = getSetVariable(FLIPR_SERVICE, "Serial", lul_device, "")
	local iconCode = getSetVariable(FLIPR_SERVICE,"IconCode", lul_device, "0")
	local lastvalid = getSetVariable(FLIPR_SERVICE,"LastValidComm", lul_device, "")

	-- sanitize
	local p = tonumber(period)
	if (p<1800) then
		setVariableIfChanged(FLIPR_SERVICE, "RefreshPeriod", DEFAULT_REFRESH, lul_device)
	end

	if (debugmode=="1") then
		DEBUG_MODE = true
		UserMessage("Enabling debug mode for device:"..lul_device,TASK_BUSY)
	end
	local major,minor = 0,0
	local tbl={}

	if (oldversion~=nil) then
		if (oldversion ~= "") then
		  major,minor = string.match(oldversion,"v(%d+)%.(%d+)")
		  major,minor = tonumber(major),tonumber(minor)
		  debug ("Plugin version: "..version.." Device's Version is major:"..major.." minor:"..minor)

		  newmajor,newminor = string.match(version,"v(%d+)%.(%d+)")
		  newmajor,newminor = tonumber(newmajor),tonumber(newminor)
		  debug ("Device's New Version is major:"..newmajor.." minor:"..newminor)

		  -- force the default in case of upgrade
		  if ( (newmajor>major) or ( (newmajor==major) and (newminor>minor) ) ) then
			-- log ("Version upgrade => Reseting Plugin config to default")
		  end
		else
		  log ("New installation")
		end
		luup.variable_set(FLIPR_SERVICE, "Version", version, lul_device)
	end

	luup.register_handler('myFLIPR_Handler','FLIPR_Handler')
	
	local success = startEngine(lul_device)
	setVariableIfChanged(FLIPR_SERVICE, "IconCode", success and "100" or "0", lul_device)

	-- report success or failure
	if( luup.version_branch == 1 and luup.version_major == 7) then
		if (success == true) then
			luup.set_failure(0,lul_device)  -- should be 0 in UI7
		else
			luup.set_failure(1,lul_device)  -- should be 0 in UI7
		end
	else
		luup.set_failure(false,lul_device)	-- should be 0 in UI7
	end

	log("startup completed")
end

------------------------------------------------
-- Check UI7
------------------------------------------------
local function checkVersion(lul_device)
  local ui7Check = luup.variable_get(FLIPR_SERVICE, "UI7Check", lul_device) or ""
  if ui7Check == "" then
	luup.variable_set(FLIPR_SERVICE, "UI7Check", "false", lul_device)
	ui7Check = "false"
	-- luup.attr_set("device_json", JSON_FILE, lul_device)
	-- luup.reload()
  end
  if( luup.version_branch == 1 and luup.version_major == 7) then
	if (ui7Check == "false") then
		-- first & only time we do this
		luup.variable_set(FLIPR_SERVICE, "UI7Check", "true", lul_device)
		luup.attr_set("device_json", UI7_JSON_FILE, lul_device)
		luup.reload()
	end
  else
	-- UI5 specific
  end
end

function initstatus(lul_device)
  lul_device = tonumber(lul_device)
  -- this_device = lul_device
  log("initstatus("..lul_device..") starting version: "..version)
  checkVersion(lul_device)
  -- hostname = getIP()
  local delay = math.random(RAND_DELAY)	-- delaying first refresh by x seconds
  debug("initstatus("..lul_device..") startup for Root device, delay:"..delay)
  luup.call_delay("startupDeferred", delay, tostring(lul_device))
end

-- do not delete, last line must be a CR according to MCV wiki page
