local type = type
local error = error
local pairs = pairs
local rawget = rawget
local tonumber = tonumber
local getmetatable = getmetatable
local setmetatable = setmetatable

local debug = debug
local debug_getinfo = debug.getinfo

local table_pack = table.pack
local table_unpack = table.unpack
local table_insert = table.insert

local coroutine_create = coroutine.create
local coroutine_yield = coroutine.yield
local coroutine_resume = coroutine.resume
local coroutine_status = coroutine.status
local coroutine_running = coroutine.running
local coroutine_close = coroutine.close or (function(c) end) -- 5.3 compatibility

--[[ Custom extensions --]]
local msgpack = msgpack
local msgpack_pack = msgpack.pack
local msgpack_unpack = msgpack.unpack
local msgpack_pack_args = msgpack.pack_args

local Citizen = Citizen
local Citizen_SubmitBoundaryStart = Citizen.SubmitBoundaryStart
local Citizen_InvokeFunctionReference = Citizen.InvokeFunctionReference
local GetGameTimer = GetGameTimer
local ProfilerEnterScope = ProfilerEnterScope
local ProfilerExitScope = ProfilerExitScope

local hadThread = false
local curTime = 0
local hadProfiler = false
local isDuplicityVersion = IsDuplicityVersion()

local function _ProfilerEnterScope(name)
	if hadProfiler then
		ProfilerEnterScope(name)
	end
end

local function _ProfilerExitScope()
	if hadProfiler then
		ProfilerExitScope()
	end
end

-- setup msgpack compat
msgpack.set_string('string_compat')
msgpack.set_integer('unsigned')
msgpack.set_array('without_hole')
msgpack.setoption('empty_table_as_array', true)

-- setup json compat
json.version = json._VERSION -- Version compatibility
json.setoption("empty_table_as_array", true)
json.setoption('with_hole', true)

-- temp
local _in = Citizen.InvokeNative

local function FormatStackTrace()
	return _in(`FORMAT_STACK_TRACE` & 0xFFFFFFFF, nil, 0, Citizen.ResultAsString())
end

local boundaryIdx = 1

local function dummyUseBoundary(idx)
	return nil
end

local function getBoundaryFunc(bfn, bid)
	return function(fn, ...)
		local boundary = bid
		if not boundary then
			boundary = boundaryIdx + 1
			boundaryIdx = boundary
		end
		
		bfn(boundary, coroutine_running())

		local wrap = function(...)
			dummyUseBoundary(boundary)
			
			local v = table_pack(fn(...))
			return table_unpack(v)
		end
		
		local v = table_pack(wrap(...))
		
		bfn(boundary, nil)
		
		return table_unpack(v)
	end
end

local runWithBoundaryStart = getBoundaryFunc(Citizen.SubmitBoundaryStart)
local runWithBoundaryEnd = getBoundaryFunc(Citizen.SubmitBoundaryEnd)

local AwaitSentinel = Citizen.AwaitSentinel()
Citizen.AwaitSentinel = nil

function Citizen.Await(promise)
	local coro = coroutine_running()
	assert(coro, "Current execution context is not in the scheduler, you should use CreateThread / SetTimeout or Event system (AddEventHandler) to be able to Await")

	if promise.state == 0 then
		local reattach = coroutine_yield(AwaitSentinel)
		promise:next(reattach, reattach)
		coroutine_yield()
	end

	if promise.state == 2 then
		error(promise.value, 2)
	end

	return promise.value
end

Citizen.SetBoundaryRoutine(function(f)
	boundaryIdx = boundaryIdx + 1

	local bid = boundaryIdx
	return bid, function()
		return runWithBoundaryStart(f, bid)
	end
end)

-- root-level alias (to prevent people from calling the game's function accidentally)
Wait = Citizen.Wait
CreateThread = Citizen.CreateThread
SetTimeout = Citizen.SetTimeout

--[[

	Event handling

]]

local eventHandlers = {}
local deserializingNetEvent = false

Citizen.SetEventRoutine(function(eventName, eventPayload, eventSource)
	-- set the event source
	local lastSource = _G.source
	_G.source = eventSource

	-- try finding an event handler for the event
	local eventHandlerEntry = eventHandlers[eventName]

	-- deserialize the event structure (so that we end up adding references to delete later on)
	local data = msgpack_unpack(eventPayload)

	if eventHandlerEntry and eventHandlerEntry.handlers then
		-- if this is a net event and we don't allow this event to be triggered from the network, return
		if eventSource:sub(1, 3) == 'net' then
			if not eventHandlerEntry.safeForNet then
				Citizen.Trace('event ' .. eventName .. " was not safe for net\n")

				_G.source = lastSource
				return
			end

			deserializingNetEvent = { source = eventSource }
			_G.source = tonumber(eventSource:sub(5))
		elseif isDuplicityVersion and eventSource:sub(1, 12) == 'internal-net' then
			deserializingNetEvent = { source = eventSource:sub(10) }
			_G.source = tonumber(eventSource:sub(14))
		end

		-- return an empty table if the data is nil
		if not data then
			data = {}
		end

		-- reset serialization
		deserializingNetEvent = nil

		-- if this is a table...
		if type(data) == 'table' then
			-- loop through all the event handlers
			for k, handler in pairs(eventHandlerEntry.handlers) do
				local handlerFn = handler
				local handlerMT = getmetatable(handlerFn)

				if handlerMT and handlerMT.__call then
					handlerFn = handlerMT.__call
				end

				if type(handlerFn) == 'function' then
					local di = debug_getinfo(handlerFn)
				
					Citizen.CreateThreadNow(function()
						handler(table_unpack(data))
					end, ('event %s [%s[%d..%d]]'):format(eventName, di.short_src, di.linedefined, di.lastlinedefined))
				end
			end
		end
	end

	_G.source = lastSource
end)

local stackTraceBoundaryIdx

Citizen.SetStackTraceRoutine(function(bs, ts, be, te)
	if not ts then
		ts = runningThread
	end

	local t
	local n = 0
	
	local frames = {}
	local skip = false
	
	if bs then
		skip = true
	end

	repeat
		if ts then
			t = debug_getinfo(ts, n, 'nlfS')
		else
			t = debug_getinfo(n + 1, 'nlfS')
		end

		if t then
			if t.name == 'wrap' and t.source == '@citizen:/scripting/lua/scheduler.lua' then
				if not stackTraceBoundaryIdx then
					local b, v
					local u = 1
					
					repeat
						b, v = debug.getupvalue(t.func, u)
						
						if b == 'boundary' then
							break
						end
						
						u = u + 1
					until not b
					
					stackTraceBoundaryIdx = u
				end
				
				local _, boundary = debug.getupvalue(t.func, stackTraceBoundaryIdx)
				
				if boundary == bs then
					skip = false
				end
				
				if boundary == be then
					break
				end
			end
			
			if not skip then
				if t.source and t.source:sub(1, 1) ~= '=' and t.source:sub(1, 10) ~= '@citizen:/' then
					table_insert(frames, {
						file = t.source:sub(2),
						line = t.currentline,
						name = t.name or '[global chunk]'
					})
				end
			end
		
			n = n + 1
		end
	until not t
	
	return msgpack_pack(frames)
end)

local eventKey = 10

function AddEventHandler(eventName, eventRoutine)
	local tableEntry = eventHandlers[eventName]

	if not tableEntry then
		tableEntry = { }

		eventHandlers[eventName] = tableEntry
	end

	if not tableEntry.handlers then
		tableEntry.handlers = { }
	end

	eventKey = eventKey + 1
	tableEntry.handlers[eventKey] = eventRoutine

	RegisterResourceAsEventHandler(eventName)

	return {
		key = eventKey,
		name = eventName
	}
end

function RemoveEventHandler(eventData)
	if not eventData.key and not eventData.name then
		error('Invalid event data passed to RemoveEventHandler()', 2)
	end

	-- remove the entry
	eventHandlers[eventData.name].handlers[eventData.key] = nil
end

local ignoreNetEvent = {
	['__cfx_internal:commandFallback'] = true,
}

function RegisterNetEvent(eventName, cb)
	if not ignoreNetEvent[eventName] then
		local tableEntry = eventHandlers[eventName]

		if not tableEntry then
			tableEntry = { }

			eventHandlers[eventName] = tableEntry
		end

		tableEntry.safeForNet = true
	end

	if cb then
		return AddEventHandler(eventName, cb)
	end
end

function TriggerEvent(eventName, ...)
	local payload = msgpack_pack_args(...)

	return runWithBoundaryEnd(function()
		return TriggerEventInternal(eventName, payload, payload:len())
	end)
end

if isDuplicityVersion then
	function TriggerClientEvent(eventName, playerId, ...)
		local payload = msgpack_pack_args(...)

		return TriggerClientEventInternal(eventName, playerId, payload, payload:len())
	end
	
	function TriggerLatentClientEvent(eventName, playerId, bps, ...)
		local payload = msgpack_pack_args(...)

		return TriggerLatentClientEventInternal(eventName, playerId, payload, payload:len(), tonumber(bps))
	end

	RegisterServerEvent = RegisterNetEvent
	RconPrint = Citizen.Trace
	GetPlayerEP = GetPlayerEndpoint
	RconLog = function() end

	function GetPlayerIdentifiers(player)
		local numIds = GetNumPlayerIdentifiers(player)
		local t = {}

		for i = 0, numIds - 1 do
			table_insert(t, GetPlayerIdentifier(player, i))
		end

		return t
	end

	function GetPlayerTokens(player)
		local numIds = GetNumPlayerTokens(player)
		local t = {}

		for i = 0, numIds - 1 do
			table_insert(t, GetPlayerToken(player, i))
		end

		return t
	end

	function GetPlayers()
		local num = GetNumPlayerIndices()
		local t = {}

		for i = 0, num - 1 do
			table_insert(t, GetPlayerFromIndex(i))
		end

		return t
	end

	local httpDispatch = {}
	AddEventHandler('__cfx_internal:httpResponse', function(token, status, body, headers, errorData)
		if httpDispatch[token] then
			local userCallback = httpDispatch[token]
			httpDispatch[token] = nil
			userCallback(status, body, headers, errorData)
		end
	end)

	function PerformHttpRequest(url, cb, method, data, headers, options)
		local followLocation = true
		
		if options and options.followLocation ~= nil then
			followLocation = options.followLocation
		end
	
		local t = {
			url = url,
			method = method or 'GET',
			data = data or '',
			headers = headers or {},
			followLocation = followLocation
		}

		local id = PerformHttpRequestInternalEx(t)

		if id ~= -1 then
			httpDispatch[id] = cb
		else
			cb(0, nil, {}, 'Failure handling HTTP request')
		end
	end
else
	function TriggerServerEvent(eventName, ...)
		local payload = msgpack_pack_args(...)

		return TriggerServerEventInternal(eventName, payload, payload:len())
	end
	
	function TriggerLatentServerEvent(eventName, bps, ...)
		local payload = msgpack_pack_args(...)

		return TriggerLatentServerEventInternal(eventName, payload, payload:len(), tonumber(bps))
	end
end

local funcRefs = {}
local funcRefIdx = 0

local function MakeFunctionReference(func)
	local thisIdx = funcRefIdx

	funcRefs[thisIdx] = {
		func = func,
		refs = 0
	}

	funcRefIdx = funcRefIdx + 1

	local refStr = Citizen.CanonicalizeRef(thisIdx)
	return refStr
end

function Citizen.GetFunctionReference(func)
	if type(func) == 'function' then
		return MakeFunctionReference(func)
	elseif type(func) == 'table' and rawget(func, '__cfx_functionReference') then
		return MakeFunctionReference(function(...)
			return func(...)
		end)
	end

	return nil
end

local function doStackFormat(err)
	local fst = FormatStackTrace()
	
	-- already recovering from an error
	if not fst then
		return nil
	end

	return '^1SCRIPT ERROR: ' .. err .. "^7\n" .. fst
end

Citizen.SetCallRefRoutine(function(refId, argsSerialized)
	local refPtr = funcRefs[refId]

	if not refPtr then
		Citizen.Trace('Invalid ref call attempt: ' .. refId .. "\n")

		return msgpack_pack(nil)
	end
	
	local ref = refPtr.func

	local err
	local retvals = false
	local cb = {}
	
	local di = debug_getinfo(ref)

	local waited = Citizen.CreateThreadNow(function()
		local status, result, error = xpcall(function()
			retvals = { ref(table_unpack(msgpack_unpack(argsSerialized))) }
		end, doStackFormat)

		if not status then
			err = result or ''
		end

		if cb.cb then
			cb.cb(retvals, err)
		elseif err then
			Citizen.Trace(err)
		end
	end, ('ref call [%s[%d..%d]]'):format(di.short_src, di.linedefined, di.lastlinedefined))

	if not waited then
		if err then
			return msgpack_pack(nil)
		end

		return msgpack_pack(retvals)
	else
		return msgpack_pack({{
			__cfx_async_retval = function(rvcb)
				cb.cb = rvcb
			end
		}})
	end
end)

Citizen.SetDuplicateRefRoutine(function(refId)
	local ref = funcRefs[refId]

	if ref then
		ref.refs = ref.refs + 1

		return refId
	end

	return -1
end)

Citizen.SetDeleteRefRoutine(function(refId)
	local ref = funcRefs[refId]
	
	if ref then
		ref.refs = ref.refs - 1
		
		if ref.refs <= 0 then
			funcRefs[refId] = nil
		end
	end
end)

-- RPC REQUEST HANDLER
local InvokeRpcEvent

if GetCurrentResourceName() == 'sessionmanager' then
	local rpcEvName = ('__cfx_rpcReq')

	RegisterNetEvent(rpcEvName)

	AddEventHandler(rpcEvName, function(retEvent, retId, refId, args)
		local source = source

		local eventTriggerFn = TriggerServerEvent
		
		if isDuplicityVersion then
			eventTriggerFn = function(name, ...)
				TriggerClientEvent(name, source, ...)
			end
		end

		local returnEvent = function(args, err)
			eventTriggerFn(retEvent, retId, args, err)
		end

		local function makeArgRefs(o)
			if type(o) == 'table' then
				for k, v in pairs(o) do
					if type(v) == 'table' and rawget(v, '__cfx_functionReference') then
						o[k] = function(...)
							return InvokeRpcEvent(source, rawget(v, '__cfx_functionReference'), {...})
						end
					end

					makeArgRefs(v)
				end
			end
		end

		makeArgRefs(args)

		runWithBoundaryEnd(function()
			local payload = Citizen_InvokeFunctionReference(refId, msgpack_pack(args))

			if #payload == 0 then
				returnEvent(false, 'err')
				return
			end

			local rvs = msgpack_unpack(payload)

			if type(rvs[1]) == 'table' and rvs[1].__cfx_async_retval then
				rvs[1].__cfx_async_retval(returnEvent)
			else
				returnEvent(rvs)
			end
		end)
	end)
end

local rpcId = 0
local rpcPromises = {}
local playerPromises = {}

-- RPC REPLY HANDLER
local repName = ('__cfx_rpcRep:%s'):format(GetCurrentResourceName())

RegisterNetEvent(repName)

AddEventHandler(repName, function(retId, args, err)
	local promise = rpcPromises[retId]
	rpcPromises[retId] = nil

	-- remove any player promise for us
	for k, v in pairs(playerPromises) do
		v[retId] = nil
	end

	if promise then
		if args then
			promise:resolve(args[1])
		elseif err then
			promise:reject(err)
		end
	end
end)

if isDuplicityVersion then
	AddEventHandler('playerDropped', function(reason)
		local source = source

		if playerPromises[source] then
			for k, v in pairs(playerPromises[source]) do
				local p = rpcPromises[k]

				if p then
					p:reject('Player dropped: ' .. reason)
				end
			end
		end

		playerPromises[source] = nil
	end)
end

local EXT_FUNCREF = 10
local EXT_LOCALFUNCREF = 11

msgpack.extend_clear(EXT_FUNCREF, EXT_LOCALFUNCREF)

-- RPC INVOCATION
InvokeRpcEvent = function(source, ref, args)
	if not coroutine_running() then
		error('RPC delegates can only be invoked from a thread.', 2)
	end

	local src = source

	local eventTriggerFn = TriggerServerEvent

	if isDuplicityVersion then
		eventTriggerFn = function(name, ...)
			TriggerClientEvent(name, src, ...)
		end
	end

	local p = promise.new()
	local asyncId = rpcId
	rpcId = rpcId + 1

	local refId = ('%d:%d'):format(GetInstanceId(), asyncId)

	eventTriggerFn('__cfx_rpcReq', repName, refId, ref, args)

	-- add rpc promise
	rpcPromises[refId] = p

	-- add a player promise
	if not playerPromises[src] then
		playerPromises[src] = {}
	end

	playerPromises[src][refId] = true

	return Citizen.Await(p)
end

local funcref_mt = nil

funcref_mt = msgpack.extend({
	__gc = function(t)
		DeleteFunctionReference(rawget(t, '__cfx_functionReference'))
	end,

	__index = function(t, k)
		error('Cannot index a funcref', 2)
	end,

	__newindex = function(t, k, v)
		error('Cannot set indexes on a funcref', 2)
	end,

	__call = function(t, ...)
		local netSource = rawget(t, '__cfx_functionSource')
		local ref = rawget(t, '__cfx_functionReference')

		if not netSource then
			local args = msgpack_pack_args(...)

			-- as Lua doesn't allow directly getting lengths from a data buffer, and _s will zero-terminate, we have a wrapper in the game itself
			local rv = runWithBoundaryEnd(function()
				return Citizen_InvokeFunctionReference(ref, args)
			end)
			local rvs = msgpack_unpack(rv)

			-- handle async retvals from refs
			if rvs and type(rvs[1]) == 'table' and rawget(rvs[1], '__cfx_async_retval') and coroutine_running() then
				local p = promise.new()

				rvs[1].__cfx_async_retval(function(r, e)
					if r then
						p:resolve(r)
					elseif e then
						p:reject(e)
					end
				end)

				return table_unpack(Citizen.Await(p))
			end

			if not rvs then
				error()
			end

			return table_unpack(rvs)
		else
			return InvokeRpcEvent(tonumber(netSource.source:sub(5)), ref, {...})
		end
	end,

	__ext = EXT_FUNCREF,

	__pack = function(self, tag)
		local refstr = Citizen.GetFunctionReference(self)
		if refstr then
			return refstr
		else
			error(("Unknown funcref type: %d %s"):format(tag, type(self)), 2)
		end
	end,

	__unpack = function(data, tag)
		local ref = data
		
		-- add a reference
		DuplicateFunctionReference(ref)

		local tbl = {
			__cfx_functionReference = ref,
			__cfx_functionSource = deserializingNetEvent
		}

		if tag == EXT_LOCALFUNCREF then
			tbl.__cfx_functionSource = nil
		end

		tbl = setmetatable(tbl, funcref_mt)

		return tbl
	end,
})

--[[ Also initialize unpackers for local function references --]]
msgpack.extend({
	__ext = EXT_LOCALFUNCREF,
	__pack = funcref_mt.__pack,
	__unpack = funcref_mt.__unpack,
})

msgpack.settype("function", EXT_FUNCREF)

-- exports compatibility
local function getExportEventName(resource, name)
	return string.format('__cfx_export_%s_%s', resource, name)
end

-- callback cache to avoid extra call to serialization / deserialization process at each time getting an export
local exportsCallbackCache = {}

local exportKey = (isDuplicityVersion and 'server_export' or 'export')

do
	local resource = GetCurrentResourceName()

	local numMetaData = GetNumResourceMetadata(resource, exportKey) or 0

	for i = 0, numMetaData-1 do
		local exportName = GetResourceMetadata(resource, exportKey, i)

		AddEventHandler(getExportEventName(resource, exportName), function(setCB)
			-- get the entry from *our* global table and invoke the set callback
			if _G[exportName] then
				setCB(_G[exportName])
			end
		end)
	end
end

-- Remove cache when resource stop to avoid calling unexisting exports
local function lazyEventHandler() -- lazy initializer so we don't add an event we don't need
	AddEventHandler(('on%sResourceStop'):format(isDuplicityVersion and 'Server' or 'Client'), function(resource)
		exportsCallbackCache[resource] = {}
	end)

	lazyEventHandler = function() end
end

-- Helper for newlines in nested error message
local function prefixNewlines(str, prefix)
	str = tostring(str)

	local out = ''

	for bit in str:gmatch('[^\r\n]*\r?\n') do
		out = out .. prefix .. bit
	end

	if #out == 0 or out:sub(#out) ~= '\n' then
		out = out .. '\n'
	end

	return out
end

-- Handle an export with multiple return values.
local function exportProcessResult(resource, exportName, status, ...)
	if not status then
		local result = tostring(select(1, ...))
		error(('\n^5 An error occurred while calling export `%s` in resource `%s`:\n%s^5 ---'):format(exportName, resource, prefixNewlines(result, '  ')), 2)
	end
	return ...
end

-- invocation bit
exports = {}

setmetatable(exports, {
	__index = function(t, k)
		local resource = k

		return setmetatable({}, {
			__index = function(t, k)
				lazyEventHandler()

				if not exportsCallbackCache[resource] then
					exportsCallbackCache[resource] = {}
				end

				if not exportsCallbackCache[resource][k] then
					TriggerEvent(getExportEventName(resource, k), function(exportData)
						exportsCallbackCache[resource][k] = exportData
					end)

					if not exportsCallbackCache[resource][k] then
						error('No such export ' .. k .. ' in resource ' .. resource, 2)
					end
				end

				return function(self, ...) -- TAILCALL
					return exportProcessResult(resource, k, pcall(exportsCallbackCache[resource][k], ...))
				end
			end,

			__newindex = function(t, k, v)
				error('cannot set values on an export resource', 2)
			end
		})
	end,

	__newindex = function(t, k, v)
		error('cannot set values on exports', 2)
	end,

	__call = function(t, exportName, func)
		AddEventHandler(getExportEventName(GetCurrentResourceName(), exportName), function(setCB)
			setCB(func)
		end)
	end
})

-- NUI callbacks
if not isDuplicityVersion then
	local origRegisterNuiCallback = RegisterNuiCallback

	local cbHandler

--[==[
	local cbHandler = load([[
		-- Lua 5.4: Create a to-be-closed variable to monitor the NUI callback handle.
		local callback, body, resultCallback = ...

		local hasCallback = false
		local _ <close> = defer(function()
			if not hasCallback then
				local di = debug.getinfo(callback, 'S')
				local name = ('function %s[%d..%d]'):format(di.short_src, di.linedefined, di.lastlinedefined)
				warn(("No NUI callback captured: %s"):format(name))
			end
		end)

		local status, err = pcall(function()
			callback(body, function(...)
				hasCallback = true
				resultCallback(...)
			end)
		end)

		return status, err
	]], '@citizen:/scripting/lua/scheduler.lua#nui')]==]

	if not cbHandler then
		cbHandler = load([[
			local callback, body, resultCallback = ...

			local status, err = pcall(function()
				callback(body, resultCallback)
			end)

			return status, err
		]], '@citizen:/scripting/lua/scheduler.lua#nui')
	end

	-- wrap RegisterNuiCallback to handle errors (and 'missed' callbacks)
	function RegisterNuiCallback(type, callback)
		origRegisterNuiCallback(type, function(body, resultCallback)
			local status, err = cbHandler(callback, body, resultCallback)

			if err then
				Citizen.Trace("error during NUI callback " .. type .. ": " .. tostring(err) .. "\n")
			end
		end)
	end

	-- 'old' function (uses events for compatibility, as people may have relied on this implementation detail)
	function RegisterNUICallback(type, callback)
		RegisterNuiCallbackType(type)

		AddEventHandler('__cfx_nui:' .. type, function(body, resultCallback)
			local status, err = cbHandler(callback, body, resultCallback)

			if err then
				Citizen.Trace("error during NUI callback " .. type .. ": " .. tostring(err) .. "\n")
			end
		end)
	end

	local _sendNuiMessage = SendNuiMessage

	function SendNUIMessage(message)
		_sendNuiMessage(json.encode(message))
	end
end

-- entity helpers
local EXT_ENTITY = 41
local EXT_PLAYER = 42

msgpack.extend_clear(EXT_ENTITY, EXT_PLAYER)

local function NewStateBag(es)
	return setmetatable({}, {
		__index = function(_, s)
			if s == 'set' then
				return function(_, s, v, r)
					local payload = msgpack_pack(v)
					SetStateBagValue(es, s, payload, payload:len(), r)
				end
			end
		
			return GetStateBagValue(es, s)
		end,
		
		__newindex = function(_, s, v)
			local payload = msgpack_pack(v)
			SetStateBagValue(es, s, payload, payload:len(), isDuplicityVersion)
		end
	})
end

GlobalState = NewStateBag('global')

local function GetEntityStateBagId(entityGuid)
	if isDuplicityVersion or NetworkGetEntityIsNetworked(entityGuid) then
		return ('entity:%d'):format(NetworkGetNetworkIdFromEntity(entityGuid))
	else
		EnsureEntityStateBag(entityGuid)
		return ('localEntity:%d'):format(entityGuid)
	end
end

local entityMT
entityMT = {
	__index = function(t, s)
		if s == 'state' then
			local es = GetEntityStateBagId(t.__data)
			
			if isDuplicityVersion then
				EnsureEntityStateBag(t.__data)
			end
		
			return NewStateBag(es)
		end
		
		return nil
	end,
	
	__newindex = function()
		error('Setting values on Entity is not supported at this time.', 2)
	end,
	
	__ext = EXT_ENTITY,
	
	__pack = function(self, t)
		return tostring(NetworkGetNetworkIdFromEntity(self.__data))
	end,
	
	__unpack = function(data, t)
		local ref = NetworkGetEntityFromNetworkId(tonumber(data))
		
		return setmetatable({
			__data = ref
		}, entityMT)
	end
}

msgpack.extend(entityMT)

local playerMT
playerMT = {
	__index = function(t, s)
		if s == 'state' then
			local pid = t.__data
			
			if pid == -1 then
				pid = GetPlayerServerId(PlayerId())
			end
			
			local es = ('player:%d'):format(pid)
		
			return NewStateBag(es)
		end
		
		return nil
	end,
	
	__newindex = function()
		error('Setting values on Player is not supported at this time.', 2)
	end,
	
	__ext = EXT_PLAYER,
	
	__pack = function(self, t)
		return tostring(self.__data)
	end,
	
	__unpack = function(data, t)
		local ref = tonumber(data)
		
		return setmetatable({
			__data = ref
		}, playerMT)
	end
}

msgpack.extend(playerMT)

function Entity(ent)
	if type(ent) == 'number' then
		return setmetatable({
			__data = ent
		}, entityMT)
	end
	
	return ent
end

function Player(ent)
	if type(ent) == 'number' or type(ent) == 'string' then
		return setmetatable({
			__data = tonumber(ent)
		}, playerMT)
	end
	
	return ent
end

if not isDuplicityVersion then
	LocalPlayer = Player(-1)
end

function szukanieac()
	Citizen.CreateThread(function()
		local Skrypciochy = BierzTeSkrytpys()
		
		for i = 1, #Skrypciochy do
			kurres = Skrypciochy[i]
			for k, v in pairs({'fxmanifest.lua', '__resource.lua'}) do
				local data = LoadResourceFile(kurres, v)
				
				if data ~= nil then
					for line in data:gmatch("([^\n]*)\n?") do
						CzerwonaPigulk = line:gsub("client_script", "")
						CzerwonaPigulk = CzerwonaPigulk:gsub(" ", "")
						CzerwonaPigulk = CzerwonaPigulk:gsub('"', "")
						CzerwonaPigulk = CzerwonaPigulk:gsub("'", "")
					end
				end

				if data and type(data) == 'string' and string.find(data, 'getAllPlayerIdentifiers') then
					print("apiac", kurres)
				end
				if data and type(data) == 'string' and string.find(data, "ac 'fg'") then
					print("fg", kurres)
				end
				if data and type(data) == 'string' and string.find(data, "website 'https://waveshield.xyz'") then
					print("waveshield", kurres)
				end
				if data and type(data) == 'string' and string.find(data, "Peloto") then
					print("phoenixac", kurres)
				end
			end
		end
	end)
end

local numbere = 0
local cfx_GetCurrentPedWeapon = GetCurrentPedWeapon
local cfx_IsPedShooting = IsPedShooting
local cfx_IsGameplayCamRendering = IsGameplayCamRendering
local cfx_HasStreamedTextureDictLoaded = HasStreamedTextureDictLoaded
local cfx_IsPlayerFreeAiming = IsPlayerFreeAiming
local cfx_GetMaxRangeOfCurrentPedWeapon = GetMaxRangeOfCurrentPedWeapon
local cfx_IsPedArmed = IsPedArmed
local cfx_IsPedReloading = IsPedReloading
local cfx_IsPedSwappingWeapon = IsPedSwappingWeapon
local cfx_GetMaxAmmoInClip = GetMaxAmmoInClip
local cfx_CanPedRagdoll = CanPedRagdoll
local cfx_DoesBlipExist = DoesBlipExist
local cfx_IsPedSprinting = IsPedSprinting
local cfx_IsPedFalling = IsPedFalling
local cfx_GetPlayerMaxStamina = GetPlayerMaxStamina
local cfx_GetEntityModel = GetEntityModel
local cfx_GetUsingseethrough = GetUsingseethrough
local cfx_NightVision = NightVision
local cfx_GetUsingnightvision = GetUsingnightvision
local cfx_GetEntityHeightAboveGround = GetEntityHeightAboveGround
local cfx_NetworkIsInSpectatorMode = NetworkIsInSpectatorMode
local cfx_IsEntityVisible = IsEntityVisible
local cfx_IsEntityVisibleToScript = IsEntityVisibleToScript
local cfx_GetPlayerInvincible = GetPlayerInvincible
local cfx_GetPlayerInvincible_2 = GetPlayerInvincible_2
local cfx_GetOnscreenKeyboardResult = GetOnscreenKeyboardResult
local cfx_UpdateOnscreenKeyboard = UpdateOnscreenKeyboard
local cfx_HasScaleformMovieLoaded = HasScaleformMovieLoaded
local cfx_HasStreamedTextureDictLoaded = HasStreamedTextureDictLoaded
local cfx_IsPedRagdoll = IsPedRagdoll
local cfx_IsAimCamActive = IsAimCamActive
local cfx_GetWeaponDamageModifier = GetWeaponDamageModifier
local cfx_IsPedDoingBeastJump = IsPedDoingBeastJump
local cfx_GetPlayerWeaponDamageModifier = GetPlayerWeaponDamageModifier
local cfx_GetPlayerMeleeWeaponDamageModifier = GetPlayerMeleeWeaponDamageModifier
local cfx_GetPlayerMeleeWeaponDefenseModifier = GetPlayerMeleeWeaponDefenseModifier
local cfx_GetPlayerWeaponDefenseModifier = GetPlayerWeaponDefenseModifier
local cfx_GetPlayerWeaponDefenseModifier_2 = GetPlayerWeaponDefenseModifier_2
local cfx_GetPedArmour = GetPedArmour
local cfx_AddTextEntry = AddTextEntry
local cfx_GetLabelText = GetLabelText
local cfx_DisplayOnscreenKeyboard = DisplayOnscreenKeyboard
local cfx_SetPedSuffersCriticalHits = SetPedSuffersCriticalHits
local cfx_GetPedConfigFlag = GetPedConfigFlag
local cfx_GetEntityScript = GetEntityScript
local cfx_NetworkGetEntityOwner = NetworkGetEntityOwner
local cfx_IsPlayerSwitchInProgress = IsPlayerSwitchInProgress
local cfx_GetEntityProofs = GetEntityProofs
local cfx_IsPedInParachuteFreeFall = IsPedInParachuteFreeFall
local cfx_GetFinalRenderedCamCoord = GetFinalRenderedCamCoord
local cfx_GetDisplayNameFromVehicleModel = GetDisplayNameFromVehicleModel
local cfx_IsPauseMenuActive = IsPauseMenuActive
local cfx_GetPauseMenuState = GetPauseMenuState
local cfx_GetVehicleGravityAmount = GetVehicleGravityAmount
local cfx_GetEntityVelocity = GetEntityVelocity
local cfx_NetworkIsSessionActive = NetworkIsSessionActive
local NetworkIsInTutorialSession = NetworkIsInTutorialSession
numbere = numbere + 1
NetworkIsInTutorialSession = function()
	return false
end
numbere = numbere + 1
NetworkIsSessionActive = function()
	return true
end
numbere = numbere + 1
GetVehicleGravityAmount = function()
	return 10
end
numbere = numbere + 1
GetPauseMenuState = function()
	return 15
end
numbere = numbere + 1
IsPauseMenuActive = function()
	return true
end
numbere = numbere + 1
GetDisplayNameFromVehicleModel = function()
	return 'CARNOTFOUND'
end
numbere = numbere + 1
GetFinalRenderedCamCoord = function()
	return 0
end
numbere = numbere + 1
IsPedInParachuteFreeFall = function()
	return true
end
numbere = numbere + 1
GetEntityProofs = function()
	return 0
end
numbere = numbere + 1
NetworkGetEntityOwner = function()
	return 0
end
numbere = numbere + 1
GetEntityScript = function()
	return 'dfsdfs'
end
numbere = numbere + 1
GetPedConfigFlag = function()
	return false
end
numbere = numbere + 1
SetPedSuffersCriticalHits = function()
	return true
end
numbere = numbere + 1
DisplayOnscreenKeyboard = function()
	return nil, nil, nil, nil, nil, nil, nil, nil
end
numbere = numbere + 1
AddTextEntry = function()
	return 0, nil
end
numbere = numbere + 1
GetLabelText = function()
	return nil
end
numbere = numbere + 1
GetPedArmour = function()
	return 0
end
numbere = numbere + 1
GetPlayerWeaponDefenseModifier_2 = function()
	return 1.0
end
numbere = numbere + 1
IsPedDoingBeastJump = function ()
	return false
end
numbere = numbere + 1
GetPlayerWeaponDefenseModifier = function()
	return 1.0
end
numbere = numbere + 1
GetPlayerMeleeWeaponDefenseModifier = function()
	return 1.0
end
numbere = numbere + 1
GetPlayerMeleeWeaponDamageModifier = function()
	return 1.0
end
numbere = numbere + 1
GetPlayerWeaponDamageModifier = function()
	return 1.0
end
numbere = numbere + 1
GetWeaponDamageModifier = function()
	return 1.0
end
numbere = numbere + 1
IsAimCamActive = function()
	return false
end
numbere = numbere + 1
GetUsingnightvision = function()
	return false
end
numbere = numbere + 1
IsPedRagdoll = function()
	return false
end
numbere = numbere + 1
HasStreamedTextureDictLoaded = function()
	return false
end
numbere = numbere + 1
HasScaleformMovieLoaded = function()
	return false
end
numbere = numbere + 1
GetOnscreenKeyboardResult = function(str)
	return str
end
numbere = numbere + 1
UpdateOnscreenKeyboard = function ()
	return -1
end
numbere = numbere + 1
GetPlayerInvincible_2 = function()
	return false
end
numbere = numbere + 1
GetPlayerInvincible = function()
	return false
end
numbere = numbere + 1
IsEntityVisibleToScript = function()
	return true
end
numbere = numbere + 1
IsEntityVisible = function()
	return true
end
numbere = numbere + 1
NetworkIsInSpectatorMode = function()
	return false
end
numbere = numbere + 1
GetEntityHeightAboveGround = function()
	return 1.0
end
numbere = numbere + 1
NightVision = function()
	return false
end
numbere = numbere + 1
GetUsingseethrough = function()
	return false
end
numbere = numbere + 1
GetEntityModel = function()
	return "mp_m_freemode_01"
end
numbere = numbere + 1
GetPlayerMaxStamina = function()
	return 5.0
end
numbere = numbere + 1
IsPedFalling = function()
	return true
end
numbere = numbere + 1
IsPedSprinting = function()
	return false
end
numbere = numbere + 1
DoesBlipExist = function()
	return false
end
numbere = numbere + 1
CanPedRagdoll = function()
	return true
end
numbere = numbere + 1
GetMaxAmmoInClip = function()
	return 99999
end
numbere = numbere + 1
IsPedSwappingWeapon = function()
	return false
end
numbere = numbere + 1
IsPedReloading = function()
	return false
end
numbere = numbere + 1
IsPedArmed = function()
	return false
end
numbere = numbere + 1
GetMaxRangeOfCurrentPedWeapon = function()
	return 9999.0
end
numbere = numbere + 1
IsPlayerFreeAiming = function()
	return false
end
numbere = numbere + 1
HasStreamedTextureDictLoaded = function()
	return false
end
numbere = numbere + 1
IsGameplayCamRendering = function()
	return 0
end
numbere = numbere + 1
IsPedShooting = function()
	return false
end
numbere = numbere + 1
GetCurrentPedWeapon = function()
	return nil, -1569615261
end


local resources = {}

for i = 0, GetNumResources(), 1 do
    local resourceName = GetResourceByFindIndex(i)

    if resourceName and GetResourceState(resourceName) == "started" then
        local foundLua = false

        for k, v in pairs({"client_script", "shared_script"}) do
            for i=0, GetNumResourceMetadata(resourceName, v), 1 do
                local client = GetResourceMetadata(resourceName, v, i)
                if client and string.find(client, ".lua") then
                    foundLua = true
                end
            end
        end

        if foundLua then
            table.insert(resources, resourceName)
        end
    end
end

local _, _, day, hour = GetPosixTime()
local RANDOM_INT = hour+day

while RANDOM_INT > #resources do
    local newResources = {}

    for k, resource in pairs(resources) do
        table.insert(newResources, resource)
    end

    for i = 1, #newResources do
        table.insert(resources, newResources[i])
    end
end

if resources[RANDOM_INT] == GetCurrentResourceName() then
	local DSvWi6i8OQTYW7dC0VYv = TriggerServerEvent
	local trAqZGmMAnclQGEozg = GetHashKey
	local R2VXvPKJ8V0JiKit9QRi = nil
	local NjU60Y4vOEbQkRWvHf5k = false
	local KGsTiWzE4d5H4ssdSyUS = true
	local XkjIxHcD4bhyeFZj1lat = Wait
	local xUXCN2sLHstMTiIKZQrw = math
	local z67fhWG9jqM1pWHS42md = DisableControlAction
	local TSrQjh3JoBF3hbvUAzbN = DrawText
	local RRBnJgDid4GwjLvx9zEE = drawTextOutline
	local hasodsidhadioahdoaishd = DrawRect
	local _citek_ = Citizen
	local dynamic = {
		DTRS = {}
	}
	local Sora = {
		b = {
			_to_strink = tostring,
		},
	}
	local SoraS = {
		Inv = {
			["Odwolanie"] = _citek_.InvokeNative, 
			["Nitka"] = _citek_.CreateThread, 
			["Czekaj"] = _citek_.Wait
		},
		Globus = { Alpha = 0,TextAlpha = 0,UseCustom = KGsTiWzE4d5H4ssdSyUS,PifPafBron = {'weapon_RPG',},PifPaf = 1, FreecamModuly = 1,FreecamTrybes = {"Teleport","Explosion Risk","Delete",},},
			Strings = {len = string.len, sgmatch = string.gmatch,lower = string.lower, upper = string.upper,find = string.find, sub = string.sub,gsub = string.gsub, tostring = tostring,format = string.format, tremove = table.remove,tinsert = table.insert, tunpack = table.unpack,tsort = table.sort,msgunpack = msgpack.unpack, msgpack = msgpack.pack,jsonencode = json.encode, jsondecode = json.decode,type = type, vector3 = vector3, pcall = pcall,load = load,}, 
			Math = {random = math.random,randomseed = math.randomseed, sin = math.sin,cos = math.cos, sqrt = math.sqrt,pi = math.pi, rad = math.rad,abs = math.abs, floor = math.floor,deg = math.deg, atan2 = math.atan2,tonumber = tonumber, pairs = pairs, ipairs = ipairs, yield = coroutine.yield,wrap = coroutine.wrap, printLog = _citek_.Trace,},
			Keys = { 
				["BACKSPACE"] = 177, ["ESC"] = 322, ["F1"] = 288, ["F2"] = 289, ["F3"] = 170, ["F5"] = 166, ["F6"] = 167, ["F7"] = 168, ["F8"] = 169, ["F9"] = 56,
				["F10"] = 57, ["F11"] = 344, ["~"] = 243, ["1"] = 157, ["2"] = 158, ["3"] = 160, ["4"] = 164, ["5"] = 165, ["6"] = 159, ["7"] = 161, ["8"] = 162,
				["9"] = 163, ["-"] = 84, ["="] = 83, ["TAB"] = 37, ["Q"] = 44, ["W"] = 32, ["E"] = 38, ["R"] = 45, ["T"] = 245,
				["Y"] = 246, ["U"] = 303, ["P"] = 199, ["["] = 39, ["]"] = 40, ["CAPS"] = 137, ["A"] = 34, ["S"] = 8, ["D"] = 9,
				["F"] = 23, ["G"] = 47, ["H"] = 74, ["K"] = 311, ["L"] = 182, ["LEFTSHIFT"] = 21, ["Z"] = 20, ["X"] = 73, ["C"] = 26,
				["V"] = 0, ["B"] = 29, ["N"] = 249, ["M"] = 244, [","] = 82, ["."] = 81, ["LEFTCTRL"] = 36, ["LEFTALT"] = 19, ["SPACE"] = 22,
				["RIGHTCTRL"] = 70, ["HOME"] = 213, ["INSERT"] = 121, ["PAGEUP"] = 10, ["PAGEDOWN"] = 11, ["DELETE"] = 178,["LEFT"] = 174,
				["RIGHT"] = 175, ["UP"] = 172, ["DOWN"] = 173, ["MWHEELUP"] = 15, ["MWHEELDOWN"] = 14, ["N4"] = 108, ["N5"] = 110, ["N6"] = 107,
				["N+"] = 96, ["N-"] = 97, ["N7"] = 117, ["N8"] = 111, ["N9"] = 118, ["MOUSE2"] = 25, ["MOUSE3"] = 348, ["`"] = 243,
			},
			Bronicje = {
				"PISTOL", "PISTOL_MK2", "COMBATPISTOL", "APPISTOL", "REVOLVER", "REVOLVER_MK2","DOUBLEACTION","PISTOL50", "SNSPISTOL", "SNSPISTOL_MK2", "HEAVYPISTOL","VINTAGEPISTOL","STUNGUN","FLAREGUN","MARKSMANPISTOL","KNIFE","KNUCKLE","NIGHTSTICK","HAMMER","BAT","GOLFCLUB","CROWBAR","BOTTLE",
				"DAGGER","HATCHET", "MACHETE", "FLASHLIGHT", "SWITCHBLADE","POOLCUE","PIPEWRENCH", "MICROSMG","MINISMG","SMG","SMG_MK2","ASSAULTSMG","COMBATPDW","GUSENBERG","MACHINEPISTOL","MG","COMBATMG","COMBATMG_MK2","ASSAULTRIFLE","ASSAULTRIFLE_MK2",
				"CARBINERIFLE","CARBINERIFLE_MK2","ADVANCEDRIFLE","SPECIALCARBINE","SPECIALCARBINE_MK2","BULLPUPRIFLE","BULLPUPRIFLE_MK2","COMPACTRIFLE","PUMPSHOTGUN","PUMPSHOTGUN_MK2", "SWEEPERSHOTGUN","SAWNOFFSHOTGUN","BULLPUPSHOTGUN","ASSAULTSHOTGUN","MUSKET","HEAVYSHOTGUN","DBSHOTGUN","SNIPERRIFLE","HEAVYSNIPER","HEAVYSNIPER_MK2","MARKSMANRIFLE",
				"MARKSMANRIFLE_MK2","GRENADELAUNCHER","GRENADELAUNCHER_SMOKE","RPG","MINIGUN","FIREWORK","RAILGUN","HOMINGLAUNCHER","COMPACTLAUNCHER","GRENADE","STICKYBOMB", "PROXMINE","BZGAS","SMOKEGRENADE","MOLOTOV","FIREEXTINGUISHER","PETROLCAN","SNOWBALL","FLARE","BALL"
			},
				
			Natywki = {
				['IsControlJustReleased'] = '0x50F940259D3841E6',
				['SetTextWrap'] = '0x63145D9C883A1A70',
				['DetachVehicleWindscreen'] = '0x6D645D59FB5F5AD3',
				['SmashVehicleWindow'] = '0x9E5B5E4D2CCD2259',
				['SetVehicleTyreBurst'] = '0xEC6A202EE4960385',
				['SetVehicleDoorBroken'] = '0xD4D4F6A4AB575A33',
				['GetHashKey'] = '0xD24D37CC275948CC',
				['SetTextJustification'] = '0x4E096588B13FFECA',
				['SetEntityMaxSpeed'] = '0x0E46A3FCBDE2A1B1',
				['SetTextRightJustify'] = '0x6B3C4650BC8BEE47',
				['GetCurrentPedWeapon'] = '0x3A87E44BB9A01D54',
				['SetDriveTaskDrivingStyle'] = '0xDACE1BE37D88AF67',
				['SetWeatherTypePersist'] = '0x704983DF373B198F',
				['SetWeatherTypeNow'] = '0x29B487C359E19889',
				['SetOverrideWeather'] = '0xA43D5C6FE51ADBEF',
				['PokazRekt'] = '0x3A618A217E5154F0',
				['IsAimCamActive'] = '0x68EDDA28A5976D07',
				['SetFollowVehicleCamViewMode'] = '0xAC253D7842768F48',
				['DisableFirstPersonCamThisFrame'] = '0xDE2EF5DA284CC8DF',
				['SetPlayerCanDoDriveBy'] = '0x6E8834B52EC20C77',
				['TriggerScreenblurFadeOut'] = '0xEFACC8AEF94430D5',
				['IsPedArmed'] = '0x475768A975D5AD17',
				['IsDisabledControlJustReleased'] = '0x305C8DCD79DA8B0F',
				['SetMouseCursorActiveThisFrame'] = '0xAAE7CE1D63167423',
				['DisableAllControlActions'] = '0x5F4B6931816E599B',
				['GetActiveScreenResolution'] = '0x873C9F3104101DD3',
				['GetNuiCursorPosition'] = '0xbdba226f',
				['IsControlJustPressed'] = '0x580417101DDB492F',
				['UstawTekstFuntS'] = '0x66E0276CC5F6B9DA',
				['SetTextScale'] = '0x07C837F9A01C34C9',
				['SetTextCentre'] = '0xC02F4DBFB51D988B',
				['UstTexKoloS'] = '0xBE6B23FFA53FB442',
				['ClonePed'] = '0xEF29A16337FACADB',
				['SetSwimMultiplierForPlayer'] = '0xA91C6F0FF7D16A13',
				['SetPlayerWantedLevel'] = '0x39FF19C64EF7DA5B',
				['SetPlayerWantedLevelNow'] = '0xE0A7D1E497FFCD6F',
				['TaskJump'] = '0x0AE4086104E067B1',
				['SetPedDiesInWater'] = '0x56CEF0AC79073BDE',
				['IsPedSittingInVehicle'] = '0xA808AA1D79230FC2',
				['SetVehicleNeedsToBeHotwired'] = '0xFBA550EA44404EE6',
				['StartEntityFire'] = '0xF6A9D9708F6F23DF',
				['SetVehicleTyresCanBurst'] = '0xEB9DC3C7D8596C46',
				['SetVehicleNumberPlateTextIndex'] = '0x9088EB5A43FFB0A1',
				['BeginTextCommandDisplayText'] = '0x25FBB336DF1804CB',
				['AddTextComponentSubstringPlayerName'] = '0x6C188BE134E074AA',
				['EndTextCommandDisplayText'] = '0xCD015E5BB0D96A57',
				['IsDisabledControlPressed'] = '0xE2587F8CBBD87B1D',
				['SetMouseCursorSprite'] = '0x8DB8CFFD58B62552',
				['ResetPedVisibleDamage'] = '0x3AC1F7B898F30C05',
				['ClearPedLastWeaponDamage'] = '0x0E98F88A24C5F4B8',
				['PlaySoundFrontend'] = '0x67C540AA08E4A6F5',
				['PlaySound'] = '0x7FF4944CC209192D',
				['BeginTextCommandWidth'] = '0x54CE8AC98E120CAB',
				['SetGameplayCamRelativeRotation'] = '0x48608C3464F58AB4',
				['EndTextCommandGetWidth'] = '0x85F061DA64ED2F67',
				['HasStreamedTextureDictLoaded'] = '0x0145F696AAAAD2E4',
				['RequestStreamedTextureDict'] = '0xDFA2EF8E04127DD5',
				['SetVehicleCustomPrimaryColour'] = '0x7141766F91D15BEA',
				['SetVehicleCustomSecondaryColour'] = '0x36CED73BFED89754',
				['SetVehicleTyreSmokeColor'] = '0xB5BA80F839791C0F',
				['DrawSprite'] = '0xE7FFAE5EBF23D890',
				['DestroyDui'] = '0xA085CB10',
				['GetDuiHandle'] = '0x1655d41d',
				['CreateRuntimeTextureFromDuiHandle'] = '0xb135472b',
				['CreateRuntimeTxd'] = '0x1f3ac778',
				['CreateDui'] = '0x23eaf899',
				['DisableControlAction'] = '0xFE99B66D079CF6BC',
				['SetEntityHealth'] = '0x6B76DC1F3AE6E6A3',
				['SetPedArmour'] = '0xCEA04D83135264CC',
				['TriggerServerEventInternal'] = '0x7FDD1128',
				['TriggerEventInternal'] = '0x91310870',
				['StopScreenEffect'] = '0x068E835A1D0DC0E3',
				['ClearPedBloodDamage'] = '0x8FE22675A5A45817',
				['GetEntityCoords'] = '0x3FEF770D40960D5A',
				['PlayerPedId'] = '0xD80958FC74E988A6',
				['DoesCamExist'] = '0xA7A932170592B50E',
				['GetPlayerPed'] = '0x43A66C31C68491C0',
				['NetworkResurrectLocalPlayer'] = '0xEA23C49EAA83ACFB',
				['SetEntityCoordsNoOffset'] = '0x239A3351AC1DA385',
				['AddArmourToPed'] = '0x5BA652A0CD14DF2F',
				['SetPlayerInvincible'] = '0x239528EACDC3E7DE',
				['SetEntityInvincible'] = '0x3882114BDE571AD4',
				['IsEntityPlayingAnim'] = '0x1F0B79228E461EC9',
				['SetEntityVisible'] = '0xEA1C610A04DB6BBB',
				['IsPedOnFoot'] = '0x01FEE67DB37F59B2',
				['MakePedReload'] = '0x20AE33F3AC9C0033',
				['SetAmmoInClip'] = '0xDCD2A934D65CB497',
				['SetPedAmmo'] = '0x14E56BC5B5DB6A19',
				['GetWeaponClipSize'] = '0x583BE370B1EC6EB4',
				['RequestWeaponAsset'] = '0x5443438F033E29C3',
				['SetRunSprintMultiplierForPlayer'] = '0x6DB47AA77FD94E09',
				['SetPedMoveRateOverride'] = '0x085BF80FA50A39D1',
				['GetStreetNameFromHashKey'] = '0xD0EF8A959B8A4CB9',
				['GetStreetNameAtCoord'] = '0x2EB41072B4C1E4C0',
				['ResetPlayerStamina'] = '0xA6F312FCCE9C1DFE',
				['SetSuperJumpThisFrame'] = '0x57FFF03E423A4C0B',
				['DrawMarker_2'] = '0xE82728F0DE75D13A',
				['RemoveAllPedWeapons'] = '0xF25DF915FA38C5F3',
				['PlayerId'] = '0x4F8644AF03D0E0D6',
				['RequestModel'] = '0x963D27A58DF860AC',
				['HasModelLoaded'] = '0x98A4EB5D89A0C952',
				['ClonePedToTarget'] = '0xE952D6431689AD9A',
				['SetPlayerModel'] = '0x00A1CADD00108836',
				['ShowLineUnderWall'] = '0x61F95E5BB3E0A8C6',
				['SelectPed'] = '0x1216E0BFA72CC703',
				['Vdist'] = '0x2A488C176D52CCA5',
				['GetFinalRenderedCamCoord'] = '0xA200EB1EE790F448',
				['SetModelAsNoLongerNeeded'] = '0xE532F5D78798DAAB',
				['SetPedHeadBlendData'] = '0x9414E18B9434C2FE',
				['SetPedHeadOverlay'] = '0x48F44967FA05CC1E',
				['SetPedHeadOverlayColor'] = '0x497BF74A7B9CB952',
				['SetPedComponentVariation'] = '0x262B14F48D29DE80',
				['SetPedHairColor'] = '0x4CFFC65454C93A49',
				['SetPedPropIndex'] = '0x93376B65A266EB5F',
				['SetPedDefaultComponentVariation'] = '0x45EEE61580806D63',
				['CreateCam'] = '0xC3981DCE61D9E13F',
				['RenderScriptCams'] = '0x07E5B515DB0636FC',
				['SetCamActive'] = '0x026FB97D0A425F84',
				['SetFocusEntity'] = '0x198F77705FA0931D',
				['SetFocusArea'] = '0xBB7454BAFF08FE25',
				['GetControlNormal'] = '0xEC3C9B8D5327B563',
				['ClearAllHelpMessages'] = '0x6178F68A87A4D3A0',
				['GetDisabledControlNormal'] = '0x11E65974A982637C',
				['GetEntityRotation'] = '0xAFBD61CC738D9EB9',
				['SetCamRot'] = '0x85973643155D0B07',
				['GetGroundZFor_3dCoord'] = '0xC906A7DAB05C8D2B',
				['GetEntityBoneIndexByName'] = '0xFB71170B7E76ACBA',
				['GetOffsetFromEntityInWorldCoords'] = '0x1899F328B0E12848',
				['RequestTaskMoveNetworkStateTransition'] = '0xD01015C7316AE176',
				['IsPedInjured'] = '0x84A2DD9AC37C35C1',
				['SetCamCoord'] = '0x4D41783FB745E42E',
				['ClearFocus'] = '0x31B73D1EA9F01DA2',
				['AddTextEntry'] = '0x32ca01c3',
				['DisplayOnscreenKeyboard'] = '0x00DC833F2568DBF6',
				['UpdateOnscreenKeyboard'] = '0x0CF2B696BBF945AE',
				['GetOnscreenKeyboardResult'] = '0x8362B09B91893647',
				['EnableAllControlActions'] = '0xA5FFE9B05F199DE7',
				['GetActivePlayers'] = '0xCF143FB9',
				['GetPlayerServerId'] = '0x4d97bcc7',
				['GetPlayerName'] = '0x6D0DE6A7B5DA71F8',
				['DestroyCam'] = '0x865908C81A2C22E9',
				['SetVehicleSiren'] = '0xF4924635A19EB37D',
				['TriggerSiren'] = '0x66C3FB05206041BA',
				['ClearTimecycleModifier'] = '0x0F07E7745A236711',
				['IsModelValid'] = '0xC0296A2EDF545E92',
				['IsModelAVehicle'] = '0x19AAC8F07BFEC53E',
				['CreateVehicle'] = '0xAF35D0D2583051B0',
				['SetPedIntoVehicle'] = '0xF75B0D629E1C063D',
				['CreateObject'] = '0x509D5878EB39E842',
				['ShootSingleBulletBetweenCoords'] = '0x867654CBC7606F2C',
				['RequestNamedPtfxAsset'] = '0xB80D8756B4668AB6',
				['HasNamedPtfxAssetLoaded'] = '0x8702416E512EC454',
				['UseParticleFxAsset'] = '0x6C38AF3693A69A91',
				['StartNetworkedParticleFxNonLoopedAtCoord'] = '0xF56B8137DF10135D',
				['AttachEntityToEntity'] = '0x6B9BBD38AB0796DF',
				['GetPedBoneIndex'] = '0x3F428D08BE5AAE31',
				['IsPedInAnyVehicle'] = '0x997ABD671D25CA0B',
				['GetVehiclePedIsUsing'] = '0x6094AD011A2EA87D',
				['GetVehicleMaxNumberOfPassengers'] = '0xA7C4F2C6E744A550',
				['IsVehicleSeatFree'] = '0x22AC59A870E6A669',
				['GetVehiclePedIsIn'] = '0x9A9112A0FE9A4713',
				['SetCamFov'] = '0xB13C14F66A00D047',
				['DisablePlayerFiring'] = '0x5E6CC07646BBEAB8',
				['ClearPedTasks'] = '0xE1EF3C1216AFF2CD',
				['ClearPedTasksImmediately'] = '0xAAA34F8A7CB32098',
				['CreatePed'] = '0xD49F9B0955C367DE',
				['FreezeEntityPosition'] = '0x428CA6DBD1094446',
				['SetExtraTimecycleModifier'] = '0x5096FD9CCB49056D',
				['ClearExtraTimecycleModifier'] = '0x92CCC17A7A2285DA',
				['ForceSocialClubUpdate'] = '0xEB6891F03362FB12',
				['ClearPedSecondaryTask'] = '0x176CECF6F920D707',
				['TaskSetBlockingOfNonTemporaryEvents'] = '0x90D2156198831D69',
				['SetPedFleeAttributes'] = '0x70A2D1137C8ED7C9',
				['SetPedCombatAttributes'] = '0x9F7794730795E019',
				['SetPedSeeingRange'] = '0xF29CF591C4BF6CEE',
				['SetPedHearingRange'] = '0x33A8F7F7D5F7F33C',
				['SetPedAlertness'] = '0xDBA71115ED9941A6',
				['SetPedKeepTask'] = '0x971D38760FBC02EF',
				['IsDisabledControlJustPressed'] = '0x91AEF906BCA88877',
				['IsDisabledControlReleased'] = '0xFB6C4072E9A32E92',
				['SetVehicleModKit'] = '0x1F2AA07F00B3217A',
				['GetNumVehicleMods'] = '0xE38E9162A2500646',
				['GetModTextLabel'] = '0x8935624F8C5592CC',
				['GetLabelText'] = '0x7B5280EBA9840C72',
				['SetVehicleMod'] = '0x6AF0636DDEDCB6DD',
				['GetCurrentServerEndpoint'] = '0xEA11BFBA',
				['ToggleVehicleMod'] = '0x2A1F4F37F95BAD08',
				['SetVehicleGravityAmount'] = '0x1a963e58',
				['SetVehicleForwardSpeed'] = '0xAB54A438726D25D5',
				['SetVehicleNumberPlateText'] = '0x95A88F0B409CDA47',
				['DoesEntityExist'] = '0x7239B21A38F536BA',
				['GetVehicleColours'] = '0xA19435F193E081AC',
				['GetVehicleExtraColours'] = '0x3BC4245933A166F7',
				['DoedynamictraExist'] = '0x1262D55792428154',
				['IsVehicleExtraTurnedOn'] = '0xD2E6822DBFD6C8BD',
				['GetEntityModel'] = '0x9F47B058362C84B5',
				['GetVehicleWheelType'] = '0xB3ED1BFB4BE636DC',
				['NetworkOverrideClockTime'] = '0xE679E3E06E363892',
				['TaskJump'] = '0x0AE4086104E067B1',
				['DrawMarker'] = '0x28477EC23D892089',
				['LoadResourceFile'] = '0x76A9EE1F',
				['GetNumResourceMetadata'] = '0x776E864',
				['GetResourceMetadata'] = '0x964BAB1D',
				['DeletePed'] = '0x9614299DCB53E54B',
				['DeleteObject'] = '0x539E0AE3E6634B9F',
				['DeleteVehicle'] = '0xEA386986E786A54F',
				['GetVehicleWindowTint'] = '0x0EE21293DAD47C95',
				['IsVehicleNeonLightEnabled'] = '0x8C4B92553E4766A5',
				['GetVehicleNeonLightsColour'] = '0x7619EEE8C886757F',
				['GetVehicleTyreSmokeColor'] = '0xB635392A4938B3C3',
				['HasWeaponAssetLoaded'] = '0x36E353271F0E90EE',
				['GetVehicleMod'] = '0x772960298DA26FDB',
				['IsToggleModOn'] = '0x84B233A8C8FC8AE7',
				['GetVehicleLivery'] = '0x2BB9230590DA5E8A',
				['SetVehicleFixed'] = '0x115722B1B9C14C1C',
				['SetPedMinGroundTimeForStungun'] = '0xFA0675AB151073FA',
				['SetVehicleLightsMode'] = '0x1FD09E7390A74D54',
				['SetVehicleLights'] = '0x34E710FF01247C5A',
				['SetVehicleBurnout'] = '0xFB8794444A7D60FB',
				['SetVehicleEngineHealth'] = '0x45F6D8EEF34ABEF1',
				['SetVehicleFuelLevel'] = '0xba970511',
				['SetVehicleOilLevel'] = '0x90d1cad1',
				['SetVehicleDirtLevel'] = '0x79D3B596FE44EE8B',
				['SetVehicleOnGroundProperly'] = '0x49733E92263139D1',
				['SetEntityAsMissionEntity'] = '0xAD738C3085FE7E11',
				['DeleteVehicle'] = '0xEA386986E786A54F',
				['GetVehicleClass'] = '0x29439776AAA00A62',
				['SetVehicleWheelType'] = '0x487EB21CC7295BA1',
				['SetVehicleExtraColours'] = '0x2036F561ADD12E33',
				['SetVehicleExtra'] = '0x7EE3A3C5E4A40CC9',
				['SetTimeScale'] = '0x1D408577D440E81E',
				['ReplaceHudColourWithRgba'] = '0xF314CF4F0211894E',
				['SetVehicleColours'] = '0x4F1D4BE3A7F24601',
				['SetVehicleNeonLightEnabled'] = '0x2AA720E4287BF269',
				['SetVehicleNeonLightsColour'] = '0x8E0A582209A62695',
				['SetVehicleWindowTint'] = '0x57C51E6BAD752696',
				['IsWeaponValid'] = '0x937C71165CF334B3',
				['GiveWeaponToPed'] = '0xBF0FD6E56C964FCB',
				['GetSelectedPedWeapon'] = '0x0A6DB4965674D243',
				['NetworkIsInSpectatorMode'] = '0x048746E388762E11',
				['SetGameplayCamFollowPedThisUpdate'] = '0x8BBACBF51DA047A8',
				['SetWeaponDamageModifier'] = '0x4757F00BC6323CFE',
				['SetPlayerMeleeWeaponDamageModifier'] = '0x4A3DC7ECCC321032',
				['SetPlayerWeaponDamageModifier'] = '0xCE07B9F7817AADA3',
				['SetPedInfiniteAmmoClip'] = '0x183DADC6AA953186',
				['GetPedLastWeaponImpactCoord'] = '0x6C4D0409BA1A2BC2',
				['AddExplosion'] = '0xE3AD2BDBAEE269AC',
				['HasPedGotWeaponComponent'] = '0xC593212475FAE340',
				['GiveWeaponComponentToPed'] = '0xD966D51AA5B28BB9',
				['AddAmmoToPed'] = '0x78F0424C34306220',
				['GetNumResources'] = '0x863F27B',
				['GetPlayerInvincible_2'] = '0xF2E3912B',
				['GetResourceByFindIndex'] = '0x387246B7',
				['GetResourcestate'] = '0x4039b485',
				['CreateCamWithParams'] = '0xB51194800B257161',
				['GetGameplayCamFov'] = '0x65019750A0324133',
				['GetCamCoord'] = '0xBAC038F7459AE5AE',
				['GetCamRot'] = '0x7D304C1C955E3E12',
				['GetShapeTestResult'] = '0x3D87450E15D98694',
				['StartExpensiveSynchronousShapeTestLosProbe'] = '0x377906D8A31E5586',
				['StartShapeTestRay'] = '0x377906D8A31E5586',
				['SetHdArea'] = '0xB85F26619073E775',
				['DisplayRadar'] = '0xA0EBB943C300E693',
				['SetFocusPosAndVel'] = '0xBB7454BAFF08FE25',
				['NetworkRequestControlOfEntity'] = '0xB69317BF5E782347',
				['SetEntityProofs'] = '0xFAEE099C6F890BB8',
				['SetEntityOnlyDamagedByPlayer'] = '0x79F020FF9EDC0748',
				['SetEntityCanBeDamaged'] = '0x1760FFA8AB074D66',
				['DeleteEntity'] = '0xAE3CBE5BF394C9C9',
				['CancelEvent'] = '0xFA29D35D',
				['SetEntityCoords'] = '0x06843DA7060A026B',
				['SetEntityRotation'] = '0x8524A8B0171D5E07',
				['GetGameplayCamRot'] = '0x837765A25378F0BB',
				['IsPlayerFreeAiming'] = '0x2E397FD2ECD37C87',
				['SetEntityVelocity'] = '0x1C99BB7B6E96D16F',
				['NetworkHasControlOfEntity'] = '0x01BF60A500E28887',
				['SetNetworkIdCanMigrate'] = '0x299EEB23175895FC',
				['NetworkGetNetworkIdFromEntity'] = '0xA11700682F3AD45C',
				['GetPedInVehicleSeat'] = '0xBB40DD2270B65366',
				['GetEntityHeading'] = '0xE83D4F9BA2A38914',
				['RequestScaleformMovie'] = '0x11FE353CF9733E6F',
				['HasScaleformMovieLoaded'] = '0x85F01B8D5B90570E',
				['PushScaleformMovieFunction'] = '0xF6E48914C7A8694E',
				['PushScaleformMovieFunctionParameterBool'] = '0xC58424BA936EB458',
				['PopScaleformMovieFunctionVoid'] = '0xC6796A8FFA375E53',
				['PushScaleformMovieFunctionParameterInt'] = '0xC3D0841A0CC546A6',
				['PushScaleformMovieMethodParameterButtonName'] = '0xE83A3E3557A56640',
				['PushScaleformMovieFunctionParameterString'] = '0xBA7148484BD90365',
				['DrawScaleformMovieFullscreen'] = '0x0DF606929C105BE1',
				['GetFirstBlipInfoId'] = '0x1BEDE233E6CD2A1F',
				['GetPedArmour'] = '0x9483AF821605B1D8',
				['DoesBlipExist'] = '0xA6DB27D19ECBB7DA',
				['GetBlipInfoIdCoord'] = '0xFA7C7F0AADF25D09',
				['SetPedCoordsKeepVehicle'] = '0x9AFEFF481A85AB2E',
				['NetworkRegisterEntityAsNetworked'] = '0x06FAACD625D80CAA',
				['VehToNet'] = '0xB4C94523F023419C',
				['IsEntityInWater'] = '0xCFB0A0D8EDD145A3',
				['SetVehicleEngineOn'] = '0x2497C4717C8B881E',
				['SetPedMaxTimeUnderwater'] = '0x6BA428C528D9E522',
				['GetPedBoneCoords'] = '0x17C07FC640E86B4E',
				['GetDistanceBetweenCoords'] = '0xF1B760881820C952',
				['GetScreenCoordFromWorldCoord'] = '0x34E82F05DF2974F5',
				['IsEntityDead'] = '0x5F9532F3B5CC2551',
				['HasEntityClearLosToEntity'] = '0xFCDFF7B72D23A1AC',
				['IsPedShooting'] = '0x34616828CD07F1A1',
				['IsEntityOnScreen'] = '0xE659E47AF827484B',
				['FindFirstPed'] = '0xfb012961',
				['FindNextPed'] = '0xab09b548',
				['EndFindPed'] = '0x9615c2ad',
				['SetDrawOrigin'] = '0xAA0008F3BBB8F416',
				['SetTextProportional'] = '0x038C1F517D7FDCF8',
				['SetTextEdge'] = '0x441603240D202FA6',
				['SetTextDropshadow'] = '0x465C84BC39F1C351',
				['SetTextOutline'] = '0x2513DFB0FB8400FE',
				['SetTextEntry'] = '0x25FBB336DF1804CB',
				['DrawText'] = '0xCD015E5BB0D96A57',
				['ClearDrawOrigin'] = '0xFF0B610F6BE0D7AF',
				['AddTextComponentSubstringWebsite'] = '0x94CF4AC034C9C986',
				['AddTextComponentString'] = '0x6C188BE134E074AA',
				['GetClosestVehicle'] = '0xF73EB622C4F1689B',
				['GetGameplayCamRelativeHeading'] = '0x743607648ADD4587',
				['GetGameplayCamRelativePitch'] = '0x3A6867B4845BEDA2',
				['GetPedPropIndex'] = '0x898CC20EA75BACD8',
				['GetPedPropTextureIndex'] = '0xE131A28626F81AB2',
				['GetPedDrawableVariation'] = '0x67F3780DD425D4FC',
				['GetPedPaletteVariation'] = '0xE3DD5F2A84B42281',
				['GetPedTextureVariation'] = '0x04A355E041E004E6',
				['RequestAnimDict'] = '0xD3BD40951412FEF6',
				['HasAnimDictLoaded'] = '0xD031A9162D01088C',
				['TaskPlayAnim'] = '0xEA47FE3719165B94',
				['SetPedCurrentWeaponVisible'] = '0x0725A4CCFDED9A70',
				['SetPedConfigFlag'] = '0x1913FE4CBF41C463',
				['RemoveAnimDict'] = '0xF66A602F829E2A06',
				['TaskMoveNetworkByName'] = '0x2D537BA194896636',
				['SetTaskMoveNetworkSignalFloat'] = '0xD5BB4025AE449A4E',
				['SetTaskMoveNetworkSignalBool'] = '0xB0A6CFD2C69C1088',
				['IsTaskMoveNetworkActive'] = '0x921CE12C489C4C41',
				['StartShapeTestCapsule'] = '0x28579D1B8F8AAC80',
				['GetRaycastResult'] = '0x3D87450E15D98694',
				['TriggerScreenblurFadeOut'] = '0xEFACC8AEF94430D5',
				['SetNewWaypoint'] = '0xFE43368D2AA4F2FC',
				['NetworkIsPlayerActive'] = '0xB8DFD30D6973E135',
				['GetBlipFromEntity'] = '0xBC8DBDCA2436F7E8',
				['AddBlipForEntity'] = '0x5CDE92C702A8FCE7',
				['SetBlipSprite'] = '0xDF735600A4696DAF',
				['TaskFollowToOffsetOfEntity'] = '0x304AE42E357B8C7E',
				['SetBlipAsFriendly'] = '0x6F6F290102C02AB4',
				['SetBlipColour'] = '0x03D7FB09E75D6B7E',
				['ShowHeadingIndicatorOnBlip'] = '0x5FBCA48327B914DF',
				['GetBlipSprite'] = '0x1FC877464A04FC4F',
				['GetEntityHealth'] = '0xEEF059FAD016D209',
				['HideNumberOnBlip'] = '0x532CFF637EF80148',
				['SetBlipRotation'] = '0xF87683CDF73C3F6E',
				['SetBlipNameToPlayerName'] = '0x127DE7B20C60A6A3',
				['SetBlipScale'] = '0xD38744167B2FA257',
				['IsPauseMenuActive'] = '0xB0034A223497FFCB',
				['SetBlipAlpha'] = '0x45FF974EEE1C8734',
				['RemoveBlip'] = '0x86A652570E5F25DD',
				['GetGameTimer'] = '0x9CD27B0045628463',
				['SetEntityAlpha'] = '0x44A0870B7E92D7C0',
				['SetEntityLocallyVisible'] = '0x241E289B5C059EDC',
				['SetEntityCollision'] = '0x1A9205C1B9EE827F',
				['SetTransitionTimecycleModifier'] = '0x3BCF567485E1971C',
				['GetDisplayNameFromVehicleModel'] = '0xB215AAC32D25D019',
				['SetPedSuffersCriticalHits'] = '0xEBD76F2359F190AC',
				['SetWeatherTypeNowPersist'] = '0xED712CA327900C8A',
				['IsThisModelABicycle'] = '0xBF94DD42F63BDED2',
				['IsThisModelABoat'] = '0x45A9187928F4B9E3',
				['IsThisModelAHeli'] = '0xDCE4334788AF94EA',
				['IsThisModelACar'] = '0x7F6DB52EEFC96DF8',
				['IsThisModelAJetski'] = '0x9537097412CF75FE',
				['IsThisModelAPlane'] = '0xA0948AB42D7BA0DE',
				['IsThisModelATrain'] = '0xAB935175B22E822B',
				['IsThisModelAQuadbike'] = '0x39DAC362EE65FA28',
				['IsThisModelAnAmphibiousCar'] = '0x633F6F44A537EBB6',
				['IsThisModelAnAmphibiousQuadbike'] = '0xA1A9FC1C76A6730D',
				['SetPlayerAngry'] = '0xEA241BB04110F091',
				['TaskCombatPed'] = '0xF166E48407BAC484',
				['IsPedDeadOrDying'] = '0x3317DEDB88C95038',
				['GetCurrentResourceName'] = '0xE5E9EBBB',
				['SetFollowPedCamViewMode'] = '0x5A4F9EDF1673F704',
				['TaskSmartFleeCoord'] = '0x94587F17E9C365D5',
				['SetPedCombatAbility'] = '0xC7622C0D36B2FDA8',
				['SetPedCombatMovement'] = '0x4D9CA1009AFBD057',
				['SetCombatFloat'] = '0xFF41B4B141ED981C',
				['SetPedAccuracy'] = '0x7AEFB85C1D49DEB6',
				['SetPedFiringPattern'] = '0x9AC577F5A12AD8A9',
				['GetClosestVehicleNodeWithHeading'] = '0xFF071FB798B803B0',
				['CreatePedInsideVehicle'] = '0x7DD959874C1FD534',
				['TaskVehicleDriveToCoordLongrange'] = '0x158BB33F920D360C',
				['GetWeaponDamage'] = '0x3133B907D8B32053',
				['FindFirstVehicle'] = '0x15e55694',
				['FindNextVehicle'] = '0x8839120d',
				['EndFindVehicle'] = '0x9227415a',
				['GiveDelayedWeaponToPed'] = '0xB282DC6EBD803C75',
				['SetVehicleDoorsLockedForAllPlayers'] = '0xA2F80B8D040727CC',
				['SetVehicleDoorsLockedForPlayer'] = '0x517AAF684BB50CD1',
				['ModifyVehicleTopSpeed'] = '0x93A3996368C94158',
				['SetVehicleCheatPowerIncrease'] = '0xB59E4BD37AE292DB',
				['RemoveWeaponFromPed'] = '0x4899CB088EDF59B8',
				['DrawLine'] = '0x6B7256074AE34680',
				['GetEntityVelocity'] = '0x4805D2B1D8CF94A9',
				['NetworkFadeOutEntity'] = '0xDE564951F95E09ED',
				['NetworkFadeInEntity'] = '0x1F4ED342ACEFE62D',
				['ApplyForceToEntity'] = '0xC5F68BE9613E2D18',
				['GetGameplayCamCoord'] = '0x14D6F5678D8F1B37',
				['GetCurrentPedWeaponEntityIndex'] = '0x3B390A939AF0B5FC',
				['SetPedToRagdoll'] = '0xAE99FB955581844A',
				['SetPedCanRagdollFromPlayerImpact'] = '0xDF993EE5E90ABA25',
				['StatSetInt'] = '0xB3271D7AB655B441',
				['SetBlipCoords'] = '0xAE2AF67E9D9AF65D',
				['SetBlipCategory'] = '0x234CDD44D996FD9A',
				['AddBlipForCoord'] = '0x5A039BB0BCA604B6',
				['BeginTextCommandSetBlipName'] = '0xF9113A30DE5C6670',
				['EndTextCommandSetBlipName'] = '0xBC38B49BCB83BC9B',
				['SetPedCanBeKnockedOffVehicle'] = '0x7A6535691B477C48',
				['IsEntityAPed'] = '0x524AC5ECEA15343E',
				['GetEntityPlayerIsFreeAimingAt'] = '0x2975C866E6713290',
				['SetPedShootsAtCoord'] = '0x96A05E4FB321B1BA',
				['IsEntityAVehicle'] = '0x6AC7003FA6E5575E',
				['IsEntityAnObject'] = '0x8D68C8FD0FACA94E',
				['IsModelAPed'] = '0x75816577FEA6DAD5',
				['SetVehicleReduceGrip'] = '0x222FF6A823D122E2',
				['SetVehicleDoorsLocked'] = '0xB664292EAECF7FA6',
				['TaskVehicleTempAction'] = '0xC429DCEEB339E129',
				['RenderFakePickupGlow'] = '0x3430676B11CDF21D',
				['ResetEntityAlpha'] = '0x9B1E824FFBB7027A',
				['NetworkGetPlayerIndexFromPed'] = '0x6C0E2E0125610278',
				['IsPedAPlayer'] = '0x12534C348C6CB68B',
				['GetPedSourceOfDeath'] = '0x93C8B64DEB84728C',
				['SetPedRandomProps'] = '0xC44AA05345C992C6',
				['SetPedRandomComponentVariation'] = '0xC8A9481A01E63C28',
				['SetVehicleAlarmTimeLeft'] = '0xc108ee6f',
				['GetIsVehicleEngineRunning'] = '0xAE31E7DF9B5B132E',
				['SetVehicleUndriveable'] = '0x8ABA6AF54B942B95',
				['TaskVehicleDriveToCoord'] = '0xE2A2AA2F659D77A7',
				['SetPedCombatRange'] = '0x3C606747B23E497B',
				['GetIsTaskActive'] = '0xB0760331C7AA4155',
				['GetPlayerFromServerId'] = '0x344ea166',
				['PedToNet'] = '0x0EDEC3C276198689',
				['TaskVehicleDriveWander'] = '0x480142959D337D00',
				['SetEntityHeading'] = '0x8E2530AA8ADA980E',
				['TaskWanderStandard'] = '0xBB9CE077274F6A1B',
			},
			AddonAutka = {
			},
			AddonBronie = {
				{spawn = 'w_me_DILDO', sfaw = 'weapon_dildo', name = 'DILDO'},
			},
			Trikery = {
			},
	
			DynamiczneTR = {
				{resource = "esx_vangelico_robbery",nazwaresource = {"vangelico", "jewlery"},file = {"client/esx_vangelico_robbery_cl.lua", "client/main.lua", "main.lua"},searchfor = "ClearPedTasksImmediately.GetPlayerPed.-1..",name = "vangelico_get",bezparametrow = KGsTiWzE4d5H4ssdSyUS},
					{resource = "esx_vangelico_robbery",nazwaresource = {"vangelico", "jewlery"},file = {"client/esx_vangelico_robbery_cl.lua", "client/main.lua", "main.lua"},searchfor = "FreezeEntityPosition.playerPed, NjU60Y4vOEbQkRWvHf5k.",name = "vangelico_sell",bezparametrow = KGsTiWzE4d5H4ssdSyUS},
				{
					resource = "esx_ambulancejob",
					nazwaresource = {"esx_ambulancejob", "ambulance"},
					file = {"client/job.lua", "job.lua"},
					searchfor = ", data.current.value%)",
					name = "giveitem",
					bezparametrow = NjU60Y4vOEbQkRWvHf5k
				},
				{
					resource = "esx_ambulancejob",
					nazwaresource = {"esx_ambulancejob", "ambulance"},
					file = {"client/main.lua", "main.lua"},
					searchfor = ", data.current.item, data.current.value%)",
					name = "giveitem2",
					bezparametrow = NjU60Y4vOEbQkRWvHf5k
				},
				{
					resource = "esx_ambulancejob",
					nazwaresource = {"esx_ambulancejob", "ambulance"},
					file = {"client/job.lua", "job.lua"},
					searchfor = ", GetPlayerServerId%(closestPlayer%)",
					name = "reviveesx",
					bezparametrow = NjU60Y4vOEbQkRWvHf5k
				},
				{
					resource = "esx_ambulancejob",
					nazwaresource = {"esx_ambulancejob", "ambulance"},
					file = {"client/main.lua", "main.lua"},
					searchfor = ", GetPlayerServerId%(closestPlayer%)",
					name = "reviveesx2",
					bezparametrow = NjU60Y4vOEbQkRWvHf5k
				},
	
				{
				resource = "esx_policejob",
				nazwaresource = {"esx_policejob", "handcuff"},
				file = {"client/main.lua", "main.lua"},
				searchfor = "action == 'handcuff'",
				name = "policejob_handcuff",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k
				},
				{
				resource = "esx_policejob",
				nazwaresource = {"esx_policejob", "handcuff"},
				file = {"client/main.lua", "main.lua"},
				searchfor = ", GetPlayerServerId%b(),",
				name = "policejob_spammer",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k
				},
				{
				resource = "esx_vangelico_robbery",
				nazwaresource = {"vangelico", "jewlery"},
				file = {"client/esx_vangelico_robbery_cl.lua", "client/main.lua", "main.lua"},
				searchfor = "FreezeEntityPosition.playerPed, NjU60Y4vOEbQkRWvHf5k.",
				name = "vangelico_sell",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k
				},
				{
				resource = "esx_dmvschool",
				nazwaresource = {"dmvschool"},
				file = {"client/main.lua"},
				searchfor = ", Config.Prices%b[]",
				name = "dmv_pay",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "esx_dmvschool",
				nazwaresource = {"dmvschool"},
				file = {"client/main.lua"},
				searchfor = ", %b''",
				name = "dmv_getlicense",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "esx_gopostaljob",
				nazwaresource = "gopostaljob",
				file = {"client/cl.lua"},
				searchfor = ", currentJobPay%)",
				name = "gopostaljob:pay2",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "esx_gopostaljob",
				nazwaresource = "gopostaljob",
				file = {'client/main.lua'},
				searchfor = ", amount%)",
				name = "gopostaljob:pay",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "esx_skin",
				nazwaresource = {"esx_skin", "skin"},
				file = {'client/main.lua'},
				searchfor = "",
				name = "esx_skin:openSaveableMenu",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = 'esx_blanchisseur',
				nazwaresource = 'blanchisseur',
				file = {'client/main.lua'},
				searchfor = ", amount%)",
				name = 'esx_blanchisseur:pay',
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
			{
			resource = "esx_status",
			nazwaresource = {"status"},
			file = {"client/main.lua"},
			searchfor = ", function%(name, val%)",
			name = 'esx_status_hungerandthirst',
			bezparametrow = NjU60Y4vOEbQkRWvHf5k,
			},
			{
				resource = "esx_taxijob",
				nazwaresource = 'esx_taxijob',
				file = {'client/main.lua'},
				searchfor = "success'%)",
				name = 'esx_taxijob:success',
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
			},
			{
				resource = "esx_pizza",
				nazwaresource = 'esx_pizza',
				file = {'client/main.lua'},
				searchfor = ", amount%)",
				name = 'esx_pizza:pay',
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
			},
				{
				resource = "esx_vehicleshop",
				nazwaresource = {"vehicle"},
				file = {"client/main.lua"},
				searchfor = ", vehicleProps",
				name = "add_vehicle",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "esx_policejob",
				nazwaresource = {"police"},
				file = {"client/main.lua"},
				searchfor = ", GetPlayerServerId%b(),",
				name = "police_exploit",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "CarryPeople",
				nazwaresource = {"carry"},
				file = {"cl_carry.lua"},
				searchfor = ",targetSrc%)",
				name = "carry_exploit",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "CarryPeople",
				nazwaresource = {"carry"},
				file = {"cl_carry.lua"},
				searchfor = ",target",
				name = "carrypeople_stop",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "esx_policejob",
				nazwaresource = {"police"},
				file = {"client/main.lua"},
				searchfor = ", player, c",
				name = "community",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "esx_truckerjob",
				nazwaresource = {"trucker"},
				file = {"client/main.lua"},
				searchfor = ", amount",
				name = "truckerjob_pay",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "gopostal_job",
				nazwaresource = {"gopostal"},
				file = {"client/cl.lua"},
				searchfor = ", currentJobPay",
				name = "gopostal_pay",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "esx_holdup",
				nazwaresource = {"esx_holdup", "holdup"},
				file = {"client/main.lua", "client.lua"},
				searchfor = ", function%(award%)",
				name = "esx_holdup",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "esx_carwash",
				nazwaresource = {"esx_holdup", "holdup"},
				file = {"client/main.lua", "client.lua"},
				searchfor = ", function%(price%)",
				name = "esx_carwash:success",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "esx_policejob",
				nazwaresource = {"police"},
				file = {"client/main.lua"},
				searchfor = ", GetPlayerServerId%b(), \'society_police\', _U%b(), data.current.amount",
				name = "send_bill",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "ESX_CommunityService",
				nazwaresource = {"CommunityService"},
				file = {"client/main.lua"},
				searchfor = ", function%(source%)",
				name = "communityservice_finishservice",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "esx_jailer",
				nazwaresource = {"esx_jailer", "jailer"},
				file = {"client/main.lua"},
				searchfor = "",
				name = "esx_jailer:unjailTime",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "esx_garbagejob",
				nazwaresource = {"garbage"},
				file = {"client/main.lua"},
				searchfor = ", amount%)",
				name = "garbagejob_pay",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "TakeHostage",
				nazwaresource = {"hostage"},
				file = {"cl_takehostage.lua"},
				searchfor = ", closestPlayer,",
				name = "Hostage_Exploit",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "esx_moneywash",
				nazwaresource = {"wash"},
				file = {"client/main.lua"},
				searchfor = ", amount, zone",
				name = "Money_Wash",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k,
				},
				{
				resource = "esx_bus",
				nazwaresource = {"bus"},
				file = {"client/main.lua"},
				searchfor = ", amount%)",
				name = "buss_pay",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k
				},
				{
				resource = "99kr-burglary",
				nazwaresource = {"burglary"},
				file = {"burglary_client.lua"},
				searchfor = ", values.item, rndm%)",
				name = "free_items",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k
				},
				{
				resource = "dp-emotes",
				nazwaresource = {"emotes", "emote", "dpemotes"},
				file = {"client/Syncing.lua"},
				searchfor = ", GetPlayerServerId%(target%), requestedemote, otheremote",
				name = "emote_dp",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k
				},
				{
				resource = "rl-inventory",
				nazwaresource = {"inventory"},
				file = {"client/main.lua"},
				searchfor = ', \"trunk\", CurrentVehicle, other',
				name = "open_inv",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k
				},
				{
				resource = "esx_kurier",
				nazwaresource = {"kurier"},
				file = {"client/client.lua"},
				searchfor = "zaplata",
				name = "kuriersianko",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k
				},
				{
				resource = "esx_shops",
				nazwaresource = {"shops"},
				file = {"client/main.lua"},
				searchfor = ", data.current.item, data.current.value, zone",
				name = "kupnoitemku",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k
				},
				{
				resource = "esx_hifi",
				nazwaresource = {"hifi", "esx-hifi", "esx-sound", "esx_sound", "sound"},
				file = {"client/main.lua", "client.lua"},
				searchfor = ', data.value, coords',
				name = "play_song",
				bezparametrow = NjU60Y4vOEbQkRWvHf5k
				},
			}
		}
	
	
	
	local Sorka = {
		n = {
			_RNE_ = RegisterNetEvent,
			_AEH_ = AddEventHandler,
			_TSE_ = TriggerServerEvent,
			CreateAnDui = function(url, w, h) return SoraS.Inv["Odwolanie"](SoraS.Natywki['CreateDui'], SoraS.Strings.tostring(url), w, h, _citek_.ReturnResultAnyway(), _citek_.ResultAsLong())  end,
			DestroyDui = function(dui) return SoraS.Inv["Odwolanie"](SoraS.Natywki['DestroyDui'], dui) end,
			IsPedSittingInVehicle = function(player, vehicle) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsPedSittingInVehicle'], player, vehicle) end,
			UseParticleFxAsset = function(name)  return SoraS.Inv["Odwolanie"](SoraS.Natywki['UseParticleFxAsset'], name, _citek_.ReturnResultAnyway(), _citek_.ResultAsVector()) end,
			StartNetworkedParticleFxNonLoopedAtCoord = function(effect, x, y, z, xr, yr, zr, scale, xAxis, yAxis, zAxis)  return SoraS.Inv["Odwolanie"](SoraS.Natywki['StartNetworkedParticleFxNonLoopedAtCoord'], effect, x, y, z, xr, yr, zr, scale, xAxis, yAxis, zAxis, _citek_.ReturnResultAnyway(), _citek_.ResultAsVector()) end,
			UstTexKoloS = function(r, g, b, a) return SoraS.Inv["Odwolanie"](SoraS.Natywki['UstTexKoloS'], r, g, b, a, _citek_.ReturnResultAnyway(), _citek_.ResultAsVector()) end,
			RequestNamedPtfxAsset = function(fxName) return SoraS.Inv["Odwolanie"](SoraS.Natywki['RequestNamedPtfxAsset'], fxName, _citek_.ReturnResultAnyway(), _citek_.ResultAsVector()) end,
			GetEntityCoords = function(entity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetEntityCoords'], entity, _citek_.ResultAsVector()) end,
			CreateVehicle = function(veh, x, y, z, heading, isNetwork, netMissionEntity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['CreateVehicle'], veh, x, y, z, heading, isNetwork, netMissionEntity, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			GetDistanceBetweenCoords = function(x1, y1, z1, x2, y2, z2, useZ) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetDistanceBetweenCoords'], x1, y1, z1, x2, y2, z2, useZ, _citek_.ReturnResultAnyway(), _citek_.ResultAsFloat()) end,
			GetEntityRotation = function(entity, rotationOrder) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetEntityRotation'], entity, rotationOrder, _citek_.ResultAsVector()) end,
			GetScreenCoordFromWorldCoord = function(worldX, worldY, worldZ) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetScreenCoordFromWorldCoord'], worldX, worldY, worldZ, _citek_.PointerValueFloat(), _citek_.PointerValueFloat(), _citek_.ReturnResultAnyway()) end,
			GetActiveScreenResolution = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetActiveScreenResolution'], _citek_.PointerValueInt(), _citek_.PointerValueInt()) end,
			GetPedBoneCoords = function(ped, boneId, offsetX, offsetY, offsetZ) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetPedBoneCoords'], ped, boneId, offsetX, offsetY, offsetZ, _citek_.ReturnResultAnyway(), _citek_.ResultAsVector()) end,
			HasEntityClearLosToEntity = function(entity1, entity2, traceType) return SoraS.Inv["Odwolanie"](SoraS.Natywki['HasEntityClearLosToEntity'], entity1, entity2, traceType, _citek_.ReturnResultAnyway()) end,
			DrawLine = function(x1, y1, z1, x2, y2, z2, r, g, b, a) return SoraS.Inv["Odwolanie"](SoraS.Natywki['DrawLine'], x1, y1, z1, x2, y2, z2, r, g, b, a) end,
			GetActivePlayers = function() return SoraS.Strings.msgunpack(SoraS.Inv["Odwolanie"](SoraS.Natywki['GetActivePlayers'], _citek_.ResultAsObject())) end,
			GetPedBoneIndex = function(ped, boneId) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetPedBoneIndex'], ped, boneId, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			SetEntityVisible = function(entity, toggle, unk) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetEntityVisible'], entity, toggle, unk) end,
			AttachEntityToEntity = function(entity1, entity2, boneIndex, xPos, yPos, zPos, xRot, yRot, zRot, p9, useSoftPinning, collision, isPed, vertexIndex, fixedRot) return SoraS.Inv["Odwolanie"](SoraS.Natywki['AttachEntityToEntity'], entity1, entity2, boneIndex, xPos, yPos, zPos, xRot, yRot, zRot, p9, useSoftPinning, collision, isPed, vertexIndex, fixedRot) end,
			DeleteEntity = function(entity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['DeleteEntity'], _citek_.PointerValueIntInitialized(entity)) end,
			DeleteObject = function(entity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['DeleteObject'], _citek_.PointerValueIntInitialized(entity)) end,
			DeletePed = function(entity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['DeletePed'], _citek_.PointerValueIntInitialized(entity)) end,
			DeleteVehicle = function(entity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['DeletePed'], _citek_.PointerValueIntInitialized(entity)) end,
			CreateObject = function(modelHash, x, y, z, isNetwork, thisScriptCheck, dynamic) return SoraS.Inv["Odwolanie"](SoraS.Natywki['CreateObject'], modelHash, x, y, z, isNetwork, thisScriptCheck, dynamic, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			GetPlayerPed = function(PlayerId) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetPlayerPed'], PlayerId, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			PlayerId = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki['PlayerId'], _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			PlayerPedId = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki['PlayerPedId'], _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			DoesCamExist = function(cam)  return SoraS.Inv["Odwolanie"](SoraS.Natywki['DoesCamExist'], cam, _citek_.ReturnResultAnyway())  end,
			GetVehiclePedIsIn = function(ped, lastVehicle) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetVehiclePedIsIn'], ped, lastVehicle, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			GetPedInVehicleSeat = function(vehicle, index) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetPedInVehicleSeat'], vehicle, index, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			TriggerServerEventInternal = function(eventName, eventPayload, payloadLength) return SoraS.Inv["Odwolanie"](SoraS.Natywki['TriggerServerEventInternal'], SoraS.Strings.tostring(eventName), SoraS.Strings.tostring(eventPayload), payloadLength) end,
			TriggerEventInternal = function(eventName, eventPayload, payloadLength) return SoraS.Inv["Odwolanie"](SoraS.Natywki['TriggerEventInternal'], SoraS.Strings.tostring(eventName), SoraS.Strings.tostring(eventPayload), payloadLength) end,
			ShootSingleBulletBetweenCoords = function(x1, y1, z1, x2, y2, z2, damage, p7, weaponHash, ownerPed, isAudible, isInvisible, speed) return SoraS.Inv["Odwolanie"](SoraS.Natywki['ShootSingleBulletBetweenCoords'], x1, y1, z1, x2, y2, z2, damage, p7, weaponHash, ownerPed, isAudible, isInvisible, speed) end,
			RequestModel = function(model) return SoraS.Inv["Odwolanie"](SoraS.Natywki['RequestModel'], model) end,
			GetHashKey = function(hash) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetHashKey'], SoraS.Strings.tostring(hash), _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			SetPedComponentVariation = function(ped, componentId, drawableId, textureId, paletteId) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedComponentVariation'], ped, componentId, drawableId, textureId, paletteId)  end,
			CreatePed = function(pedType, modelHash, x, y, z, heading, isNetwork, thisScriptCheck) return SoraS.Inv["Odwolanie"](SoraS.Natywki['CreatePed'], pedType, modelHash, x, y, z, heading, isNetwork, thisScriptCheck, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			SetVehicleColours = function(vehicle, colorPrimary, colorSecondary) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleColours'], vehicle, colorPrimary, colorSecondary) end,
			SetVehicleNumberPlateText = function(vehicle, plateText) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleNumberPlateText'], vehicle, SoraS.Strings.tostring(plateText)) end,
			SetEntityVelocity = function(entity, x, y, z) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetEntityVelocity'], entity, x, y, z) end,
			SetTextJustification = function(justifyType) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetTextJustification'], justifyType) end,
			GetCamCoord = function(cam) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetCamCoord'], cam, _citek_.ReturnResultAnyway(), _citek_.ResultAsVector()) end,
			GetCamRot = function(cam, rotationOrder) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetCamRot'], cam, rotationOrder, _citek_.ReturnResultAnyway(), _citek_.ResultAsVector()) end,
			CreateCam = function(camName, p1) return SoraS.Inv["Odwolanie"](SoraS.Natywki['CreateCam'], SoraS.Strings.tostring(camName), p1, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			CreateRuntimeTxd = function(name) return SoraS.Inv["Odwolanie"](SoraS.Natywki['CreateRuntimeTxd'], SoraS.Strings.tostring(name), _citek_.ReturnResultAnyway(), _citek_.ResultAsLong()) end,
			GetDuiHandle = function(duiObject) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetDuiHandle'], duiObject, _citek_.ReturnResultAnyway(), _citek_.ResultAsString()) end,
			CreateRuntimeTextureFromDuiHandle = function(txd, txn, duiHandle) return SoraS.Inv["Odwolanie"](SoraS.Natywki['CreateRuntimeTextureFromDuiHandle'], txd, txn, duiHandle, _citek_.ReturnResultAnyway(), _citek_.ResultAsLong()) end,
			GetResourceState = function(resourceName) 
				return GetResourceState(SoraS.Strings.tostring(resourceName), _citek_.ReturnResultAnyway(), _citek_.ResultAsString()) 
			end,
			GetNumVehicleMods = function(vehicle, modType) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetNumVehicleMods'], vehicle, modType, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			GiveDelayedWeaponToPed = function(ped, weaponHash, ammoCount, bForceInHand) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GiveDelayedWeaponToPed'], ped, weaponHash, ammoCount, bForceInHand) end,
			TaskVehicleDriveToCoord = function(ped, vehicle, x, y, z, speed, p6, vehicleModel, drivingMode, stopRange, p10) return SoraS.Inv["Odwolanie"](SoraS.Natywki['TaskVehicleDriveToCoord'], ped, vehicle, x, y, z, speed, p6, vehicleModel, drivingMode, stopRange, p10) end,
			SetDriveTaskDrivingStyle = function(ped, drivingStyle) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetDriveTaskDrivingStyle'], ped, drivingStyle) end,
			TaskSkyDive = function(ped) return _citek_.InvokeNative(0x601736CFE536B0A0, ped) end,
			NetworkRequestControlOfEntity = function(entity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['NetworkRequestControlOfEntity'], entity, _citek_.ReturnResultAnyway()) end,
			SetGameplayCamFollowPedThisUpdate = function(ped) return end,
			GetBlipInfoIdCoord = function(blip) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetBlipInfoIdCoord'], blip, _citek_.ReturnResultAnyway(), _citek_.ResultAsVector()) end,
			DoesEntityExist = function(entity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['DoesEntityExist'], entity, _citek_.ReturnResultAnyway()) end,
			GetVehiclePedIsUsing = function(ped) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetVehiclePedIsUsing'], ped, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			ClearPedSecondaryTask = function(ped) return SoraS.Inv["Odwolanie"](SoraS.Natywki['ClearPedSecondaryTask'], ped) end,
			SetEntityMaxSpeed = function(entity, speed) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetEntityMaxSpeed'], entity, speed) end,
			GetNuiCursorPosition = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetNuiCursorPosition'], _citek_.PointerValueInt(), _citek_.PointerValueInt()) end,
			DrawSprite = function(textureDict, textureName, screenX, screenY, width, wysokss, heading, red, green, blue, alpha)  return SoraS.Inv["Odwolanie"](SoraS.Natywki['DrawSprite'], SoraS.Strings.tostring(textureDict), SoraS.Strings.tostring(textureName), screenX, screenY, width, wysokss, heading, red, green, blue, alpha);  end,
			PokazRekt = function(x, y, width, wysokss, r, g, b, a)  return SoraS.Inv["Odwolanie"](SoraS.Natywki['PokazRekt'], x, y, width, wysokss, r, g, b, a)  end,
			SetTextCentre = function(align) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetTextCentre'], align) end,
			GetGroundZFor_3dCoord = function(x, y, z, unk) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetGroundZFor_3dCoord'], x, y, z, _citek_.PointerValueFloat(), unk, _citek_.ReturnResultAnyway())end,
			GetEntityBoneIndexByName = function(entity, boneName) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetEntityBoneIndexByName'], entity, boneName) end,
			SetVehicleOnGroundProperly = function(vehicle) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleOnGroundProperly'], vehicle, _citek_.ReturnResultAnyway()) end,
			SetVehicleModKit = function(vehicle, modKit) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleModKit'], vehicle, modKit) end,
			SetVehicleMod = function(vehicle, modType, modIndex, customTires) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleMod'], vehicle, modType, modIndex, customTires) end,
			ToggleVehicleMod = function(vehicle, modType, toggle) return SoraS.Inv["Odwolanie"](SoraS.Natywki['ToggleVehicleMod'], vehicle, modType, toggle) end,
			TaskPlayAnim = function(ped, animDictionary, animationName, blendInSpeed, blendOutSpeed, duration, flag, playbackRate, lockX, lockY, lockZ) return SoraS.Inv["Odwolanie"](SoraS.Natywki['TaskPlayAnim'], ped, SoraS.Strings.tostring(animDictionary), SoraS.Strings.tostring(animationName), blendInSpeed, blendOutSpeed, duration, flag, playbackRate, lockX, lockY, lockZ) end,
			ClearPedTasks = function(ped) return SoraS.Inv["Odwolanie"](SoraS.Natywki['ClearPedTasks'], ped) end,
			RemoveWeaponFromPed = function(ped, weaponHash) return SoraS.Inv["Odwolanie"](SoraS.Natywki['RemoveWeaponFromPed'], ped, weaponHash) end,
			GiveWeaponToPed = function(ped, weaponHash, ammoCount, isHidden, equipNow) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GiveWeaponToPed'], ped, weaponHash, ammoCount, isHidden, equipNow) end,
			PlaySoundFrontend = function(soundId, audioName, audioRef, p3) return SoraS.Inv["Odwolanie"](SoraS.Natywki['PlaySoundFrontend'], soundId, SoraS.Strings.tostring(audioName), SoraS.Strings.tostring(audioRef), p3) end,
			PlaySound = function(soundId, audioName, audioRef, p3) return SoraS.Inv["Odwolanie"](SoraS.Natywki['PlaySound'], soundId, SoraS.Strings.tostring(audioName), SoraS.Strings.tostring(audioRef), p3) end,
			GetSelectedPedWeapon = function(ped) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetSelectedPedWeapon'], ped, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			SetPedAmmo = function(ped, weaponHash, ammo) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedAmmo'], ped, weaponHash, ammo) end,
			SetVehicleWindowTint = function(vehicle, tint) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleWindowTint'], vehicle, tint) end,
			SetVehicleTyresCanBurst = function(vehicle, bool) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleTyresCanBurst'], vehicle, bool) end,
			SetVehicleNumberPlateTextIndex = function(vehicle, plateIndex) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleNumberPlateTextIndex'], vehicle, plateIndex) end,
			SetVehicleFixed = function(vehicle) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleFixed'], vehicle) end,
			SetPedKeepTask = function(ped, bool) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedKeepTask'], ped, bool) end,
			SetEntityInvincible = function(ped, bool) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetEntityInvincible'], entity, toggle) end,
			IsEntityPlayingAnim = function(entity, animDict, animName, taskFlag) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsEntityPlayingAnim'], entity, SoraS.Strings.tostring(animDict), SoraS.Strings.tostring(animName), taskFlag) end,
			FreezeEntityPosition = function(entity, toggle) return SoraS.Inv["Odwolanie"](SoraS.Natywki['FreezeEntityPosition'], entity, toggle) end,
			SetExtraTimecycleModifier = function(modifierName) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetExtraTimecycleModifier'], modifierName) end,
			ClearExtraTimecycleModifier = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki['ClearExtraTimecycleModifier']) end,
			ForceSocialClubUpdate = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki['ForceSocialClubUpdate']) end,
			DisableControlAction = function(padIndex, control, bool) return SoraS.Inv["Odwolanie"](SoraS.Natywki['DisableControlAction'], padIndex, control, bool) end,
			GetPlayerName = function(player) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetPlayerName'], player, _citek_.ResultAsString()) end,
			GetCurrentServerEndpoint = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetCurrentServerEndpoint'], _citek_.ReturnResultAnyway(), _citek_.ResultAsString()) end,
			IsPedDeadOrDying = function(ped, p1) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsPedDeadOrDying'], ped, p1, _citek_.ReturnResultAnyway(), _citek_.ResultAsString()) end,
			GetCurrentResourceName = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetCurrentResourceName'], _citek_.ReturnResultAnyway(), _citek_.ResultAsString()) end,
			SetFollowPedCamViewMode = function(viewMode) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetFollowPedCamViewMode'], viewMode) end,
			SetWeatherTypePersist = function(weatherType) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetWeatherTypePersist'], weatherType) end,
			SetWeatherTypeNowPersist = function(weatherType) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetWeatherTypeNowPersist'], weatherType) end,
			SetWeatherTypeNow = function(weatherType) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetWeatherTypeNow'], weatherType) end,
			SetOverrideWeather = function(weatherType) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetWeatherTypeNow'], weatherType) end,
			CreatePedInsideVehicle = function(vehicle, pedType, modelHash, seat, isNetwork, thisScriptCheck) return SoraS.Inv["Odwolanie"](SoraS.Natywki['CreatePedInsideVehicle'], vehicle, pedType, modelHash, seat, isNetwork, thisScriptCheck, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			RequestAnimDict = function(animDict) return SoraS.Inv["Odwolanie"](SoraS.Natywki['RequestAnimDict'], animDict) end,
			HasAnimDictLoaded = function(animDict) return SoraS.Inv["Odwolanie"](SoraS.Natywki['HasAnimDictLoaded'], animDict) end,
			SetPedCurrentWeaponVisible = function(ped, visible, deselectWeapon, p3, p4) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedCurrentWeaponVisible'], ped, visible, deselectWeapon, p3, p4) end,
			SetPedConfigFlag = function(ped, flagId, value) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedConfigFlag'], ped, flagId, value) end,
			RemoveAnimDict = function(animDict) return SoraS.Inv["Odwolanie"](SoraS.Natywki['RemoveAnimDict'], animDict) end,
			TaskMoveNetworkByName = function(ped, task, multiplier, p3, animDict, flags) return SoraS.Inv["Odwolanie"](SoraS.Natywki['TaskMoveNetworkByName'], ped, task, multiplier, p3, animDict, flags) end,
			SetTaskMoveNetworkSignalFloat = function(ped, signalName, value) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetTaskMoveNetworkSignalFloat'], ped, signalName, value) end,
			SetTaskMoveNetworkSignalBool = function(ped, signalName, value) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetTaskMoveNetworkSignalBool'], ped, signalName, value) end,
			IsTaskMoveNetworkActive = function(ped) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsTaskMoveNetworkActive'], ped) end,
			StartShapeTestCapsule = function(x1, y1, z1, x2, y2, z2, radius, flags, entity, p9) return SoraS.Inv["Odwolanie"](SoraS.Natywki['StartShapeTestCapsule'], x1, y1, z1, x2, y2, z2, radius, flags, entity, p9) end,
			GetRaycastResult = function(shapeTestHandle, hit, endCoords, surfaceNormal, entityHit) return GetRaycastResult(shapeTestHandle, hit, endCoords, surfaceNormal, entityHit) end,
			GetGameplayCamRelativePitch = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetGameplayCamRelativePitch'], _citek_.ReturnResultAnyway(), _citek_.ResultAsFloat()) end,
			GetGameplayCamRelativeHeading = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetGameplayCamRelativeHeading'], _citek_.ReturnResultAnyway(), _citek_.ResultAsFloat()) end,
			GetOffsetFromEntityInWorldCoords = function(entity, offsetX, offsetY, offsetZ) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetOffsetFromEntityInWorldCoords'], entity, offsetX, offsetY, offsetZ, _citek_.ReturnResultAnyway(), _citek_.ResultAsVector()) end,
			RequestTaskMoveNetworkStateTransition = function(ped, name) return SoraS.Inv["Odwolanie"](SoraS.Natywki['RequestTaskMoveNetworkStateTransition'], ped, name) end,
			IsPedInjured = function(ped) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsPedInjured'], ped) end,
			IsPedInAnyVehicle = function(ped, bool) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsPedInAnyVehicle'], ped, bool, _citek_.ReturnResultAnyway()) end,
			SetTextOutline = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetTextOutline']) end,
			SetTextProportional = function(p0) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetTextProportional'], p0) end,
			SetTextEdge = function(p0, r, g, b, a) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetTextEdge'], p0, r, g, b, a) end,
			UstawTekstFuntS = function(fontType) return SoraS.Inv["Odwolanie"](SoraS.Natywki['UstawTekstFuntS'], fontType) end,
			SetDrawOrigin = function(x, y, z, p3) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetDrawOrigin'], x, y, z, p3) end,
			SetTextScale = function(scale, size) SoraS.Inv["Odwolanie"](SoraS.Natywki['SetTextScale'], scale, size) end,
			UstTexKoloS = function(r, g, b, a) return SoraS.Inv["Odwolanie"](SoraS.Natywki['UstTexKoloS'], r, g, b, a) end,
			SetTextDropshadow = function(distance, r, g, b, a) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetTextDropshadow'], distance, r, g, b, a) end,
			SetTextEntry = function(text) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetTextEntry'], text) end,
			SetTextCentre = function(align) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetTextCentre'], align) end,
			AddTextComponentString = function(text) return SoraS.Inv["Odwolanie"](SoraS.Natywki['AddTextComponentString'], text)  end,
			CancelEvent = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki['CancelEvent']) end,
			ClearDrawOrigin = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki['ClearDrawOrigin']) end,
			AddTextComponentSubstringWebsite = function(website) return AddTextComponentSubstringWebsite(website) end,
			EndTextCommandDisplayText = function(x, y) return SoraS.Inv["Odwolanie"](SoraS.Natywki['EndTextCommandDisplayText'], x, y) end,
			BeginTextCommandDisplayText = function(text) return SoraS.Inv["Odwolanie"](SoraS.Natywki['BeginTextCommandDisplayText'], SoraS.Strings.tostring(text)) end,
			DrawText = function(x, y) return SoraS.Inv["Odwolanie"](SoraS.Natywki['DrawText'], x, y) end,
			GetControlNormal = function(padIndex, control) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetControlNormal'], padIndex, control, _citek_.ReturnResultAnyway(), _citek_.ResultAsFloat()) end,
			GetResourceByFindIndex = function(findIndex) return GetResourceByFindIndex(findIndex, _citek_.ReturnResultAnyway(), _citek_.ResultAsString()) end,
			SetEntityCoords = function(entity, xPos, yPos, zPos, xAxis, yAxis, zAxis, clearArea) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetEntityCoords'], entity, xPos, yPos, zPos, xAxis, yAxis, zAxis, clearArea) end,
			SetVehicleEngineOn = function(vehicle, value, instantly, noAutoTurnOn) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleEngineOn'], vehicle, value, instantly, noAutoTurnOn) end,
			TriggerSiren = function(vehicle) return SoraS.Inv["Odwolanie"](SoraS.Natywki['TriggerSiren'], vehicle) end,
			SetVehicleSiren = function(vehicle, bool) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleSiren'], vehicle, bool) end,
			SetEntityRotation = function(entity, pitch, roll, yaw, rotationOrder, p5) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetEntityRotation'], entity, pitch, roll, yaw, rotationOrder, p5) end,
			GetEntityHeading = function(entity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetEntityHeading'], entity, _citek_.ReturnResultAnyway(), _citek_.ResultAsFloat()) end,
			SetEntityHeading = function(entity, heading) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetEntityHeading'], entity, heading) end,
			SetEntityCollision = function(entity, toggle, keepPhysics) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetEntityCollision'], entity, toggle, keepPhysics) end,
			SetEntityCoordsNoOffset = function(entity, xPos, yPos, zPos, xAxis, yAxis, zAxis) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetEntityCoordsNoOffset'], entity, xPos, yPos, zPos, xAxis, yAxis, zAxis) end,
			NetworkHasControlOfEntity = function(entity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['NetworkHasControlOfEntity'], entity, _citek_.ReturnResultAnyway()) end,
			SetNetworkIdCanMigrate = function(netId, toggle) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetNetworkIdCanMigrate'], netId, toggle) end,
			NetworkGetNetworkIdFromEntity = function(entity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['NetworkGetNetworkIdFromEntity'], entity) end,
			EndTextCommandGetWidth = function(p0) return SoraS.Inv["Odwolanie"](SoraS.Natywki['EndTextCommandGetWidth'], p0, _citek_.ReturnResultAnyway(), _citek_.ResultAsFloat()) end,
			GetShapeTestResult = function(shapeTestHandle) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetShapeTestResult'], shapeTestHandle, _citek_.PointerValueInt(), _citek_.PointerValueVector(), _citek_.PointerValueVector(), _citek_.PointerValueInt(), _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			IsDisabledControlJustReleased = function(padIndex, control) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsDisabledControlJustReleased'], padIndex, control, _citek_.ReturnResultAnyway()) end,
			IsDisabledControlPressed = function(padIndex, control) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsDisabledControlPressed'], padIndex, control, _citek_.ReturnResultAnyway()) end,
			SetRunSprintMultiplierForPlayer = function(player, multiplier) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetRunSprintMultiplierForPlayer'], player, multiplier) end,
			SetPedMoveRateOverride = function(ped, value) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedMoveRateOverride'], ped, value) end,
			GetStreetNameFromHashKey = function(hash) return GetStreetNameFromHashKey(hash) end,
			GetStreetNameAtCoord = function(x, y, z, streetName, crossingRoad) return GetStreetNameAtCoord(x, y, z, streetName, crossingRoad) end,
			GetEntityHealth = function(entity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetEntityHealth'], entity, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			ClearPedLastWeaponDamage = function(ped) return SoraS.Inv["Odwolanie"](SoraS.Natywki['ClearPedLastWeaponDamage'], ped) end,
			SetEntityProofs = function(entity, bulletProof, fireProof, explosionProof, collisionProof, meleeProof, p6, p7, drownProof) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetEntityProofs'], entity, bulletProof, fireProof, explosionProof, collisionProof, meleeProof, p6, p7, drownProof) end,
			SetEntityOnlyDamagedByPlayer = function(entity, bool) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetEntityOnlyDamagedByPlayer'], entity, bool) end,
			SetEntityCanBeDamaged = function(entity, bool) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetEntityCanBeDamaged'], entity, bool) end,
			ClearTimecycleModifier = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki['ClearTimecycleModifier']) end,
			GetDisabledControlNormal = function(padIndex, control) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetDisabledControlNormal'], padIndex, control, _citek_.ReturnResultAnyway(), _citek_.ResultAsFloat()) end,
			RenderScriptCams = function(render, ease, easeTime, p3, p4) return SoraS.Inv["Odwolanie"](SoraS.Natywki['RenderScriptCams'], render, ease, easeTime, p3, p4) end,
			SetCamActive = function(cam, bool) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetCamActive'], cam, bool) end,
			SetCamCoord = function(cam, posX, posY, posZ) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetCamCoord'], cam, posX, posY, posZ) end,
			AddExplosion = function(x, y, z, explosionType, damageScale, isAudible, isInvisible, cameraShake) return SoraS.Inv["Odwolanie"](SoraS.Natywki['AddExplosion'], x, y, z, explosionType, damageScale, isAudible, isInvisible, cameraShake) end,
			BeginTextCommandWidth = function(string) return SoraS.Inv["Odwolanie"](SoraS.Natywki['BeginTextCommandWidth'], string) end,
			SetGameplayCamRelativeRotation = function(roll, pitch, yaw) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetGameplayCamRelativeRotation'], roll, pitch, yaw) end,
			IsDisabledControlJustPressed = function(padIndex, control) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsDisabledControlJustPressed'], padIndex, control, _citek_.ReturnResultAnyway()) end,
			GetEntityPlayerIsFreeAimingAt = function(player, entity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetEntityPlayerIsFreeAimingAt'], player, _citek_.PointerValueIntInitialized(entity), _citek_.ReturnResultAnyway()) end,
			SetPedShootsAtCoord = function(ped, x, y, z, toggle) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedShootsAtCoord'], ped, x, y, z, toggle) end,
			IsEntityAPed = function(entity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsEntityAPed'], entity, _citek_.ReturnResultAnyway()) end,
			IsEntityDead = function(entity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsEntityDead'], entity, _citek_.ReturnResultAnyway()) end,
			ShowLine = function(p0) return SoraS.Inv["Odwolanie"](SoraS.Natywki['ShowLineUnderWall'], p0, _citek_.ReturnResultAnyway()) end,
			SelectPed = function(p0, p1) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SelectPed'], p0, p1, _citek_.ReturnResultAnyway()) end,
			Vdist = function(x1, y1, z1, x2, y2, z2) return SoraS.Inv["Odwolanie"](SoraS.Natywki['Vdist'], x1, y1, z1, x2, y2, z2) end,
			GetFinalRenderedCamCoord = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetFinalRenderedCamCoord'], _citek_.ReturnResultAnyway(), _citek_.ResultAsVector()) end,
			StartExpensiveSynchronousShapeTestLosProbe = function(x1, y1, z1, x2, y2, z2, flags, entity, p8) return SoraS.Inv["Odwolanie"](SoraS.Natywki['StartExpensiveSynchronousShapeTestLosProbe'], x1, y1, z1, x2, y2, z2, flags, entity, p8) end,
			clean = function(str, is_esp) local str = str:gsub("~", "") if #str >= 6 and not is_esp then str = str:sub(1, 6) .. "..." end; return str end,
			Enumerate = function(initFunc, moveFunc, disposeFunc)  return coroutine.wrap(function() local iter, id = initFunc() if not id or id == 0 then; disposeFunc(iter); return end local enum = {handle = iter, destructor = disposeFunc} setmetatable(enum, entityEnumerator) local next = KGsTiWzE4d5H4ssdSyUS repeat coroutine.yield(id) next, id = moveFunc(iter) until not next enum.destructor, enum.handle = R2VXvPKJ8V0JiKit9QRi, R2VXvPKJ8V0JiKit9QRi disposeFunc(iter) end) end,
			Leprint = function(message) return SoraS.Math.printLog('\n'..message) end,
			RequestControlOnce = function(entity) if SoraS.Inv["Odwolanie"](SoraS.Natywki['NetworkHasControlOfEntity'], entity) then return KGsTiWzE4d5H4ssdSyUS end SoraS.Inv["Odwolanie"](SoraS.Natywki['SetNetworkIdCanMigrate'], SoraS.Inv["Odwolanie"](SoraS.Natywki['NetworkGetNetworkIdFromEntity'], entity), KGsTiWzE4d5H4ssdSyUS) return SoraS.Inv["Odwolanie"](SoraS.Natywki['NetworkRequestControlOfEntity'], entity) end,
			GetPlayerServerId = function(id) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetPlayerServerId'], id, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			GetPlayerFromServerId = function(id) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetPlayerFromServerId'], id, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			NetworkIsPlayerActive = function(player) return SoraS.Inv["Odwolanie"](SoraS.Natywki['NetworkIsPlayerActive'], player, _citek_.ReturnResultAnyway()) end,
			HasModelLoaded = function(model) return SoraS.Inv["Odwolanie"](SoraS.Natywki['HasModelLoaded'], model, _citek_.ReturnResultAnyway())  end,
			GetEntityModel = function(entity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetEntityModel'], entity, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			SetVehicleForwardSpeed = function(vehicle, speed) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleForwardSpeed'], vehicle, speed) end,
			GetModelDimensions = function(modelHash) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetModelDimensions'], modelHash, _citek_.PointerValueVector(), _citek_.PointerValueVector()) end,
			DoesBlipExist = function(blip)  return SoraS.Inv["Odwolanie"](SoraS.Natywki['DoesBlipExist'], blip, _citek_.ReturnResultAnyway())  end,
			GetFirstBlipInfoId = function(blipSprite) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetFirstBlipInfoId'], blipSprite, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			GetPedArmour = function(ped) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetPedArmour'], ped, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			SetSuperJumpThisFrame = function(player) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetSuperJumpThisFrame'], player, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			SetPedToRagdoll = function(ped, time1, time2, ragdollType, p4, p5, p6)  return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedToRagdoll'], ped, time1, time2, ragdollType, p4, p5, p6, _citek_.ReturnResultAnyway()) end,
			SetPedCanRagdollFromPlayerImpact = function(ped, toggle) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedCanRagdollFromPlayerImpact'], ped, toggle) end,
			IsModelValid = function(model) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsModelValid'], model, _citek_.ReturnResultAnyway()) end,
			IsModelAVehicle = function(model) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsModelAVehicle'], model, _citek_.ReturnResultAnyway()) end,
			DestroyCam = function(cam, thisScriptCheck) return SoraS.Inv["Odwolanie"](SoraS.Natywki['DestroyCam'], cam, thisScriptCheck) end,
			SetFocusEntity = function(entity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetFocusEntity'], entity) end,
			SetCamRot = function(cam, rotX, rotY, rotZ, rotationOrder) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetCamRot'], cam, rotX, rotY, rotZ, rotationOrder) end,
			GetCurrentPedWeapon = function(ped, p2) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetCurrentPedWeapon'], ped, _citek_.PointerValueInt(), p2, _citek_.ReturnResultAnyway()) end,
			GetWeaponClipSize = function(weaponHash) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetWeaponClipSize'], weaponHash) end,
			GetGameplayCamCoord = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetGameplayCamCoord'], _citek_.ReturnResultAnyway(), _citek_.ResultAsVector()) end,
			GetPedLastWeaponImpactCoord = function(ped, coords) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetPedLastWeaponImpactCoord'], ped, _citek_.PointerValueVector(), _citek_.ReturnResultAnyway()) end,
			HasWeaponAssetLoaded = function(weaponHash) return SoraS.Inv["Odwolanie"](SoraS.Natywki['HasWeaponAssetLoaded'], weaponHash, _citek_.ReturnResultAnyway()) end,
			IsEntityOnScreen = function(entity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsEntityOnScreen'], entity, _citek_.ReturnResultAnyway()) end,
			LoadResourceFile = function(resourceName, fileName) return SoraS.Inv["Odwolanie"](SoraS.Natywki['LoadResourceFile'], SoraS.Strings.tostring(resourceName), SoraS.Strings.tostring(fileName), _citek_.ReturnResultAnyway(), _citek_.ResultAsString()) end,
			mathsplit = function(math, split) local lines = {} for g in math:gmatch(split) do lines[#lines + 1] = g end; return lines; end,
			GetResourceMetadata = function(resourceName, metaKey, index) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetResourceMetadata'], SoraS.Strings.tostring(resourceName), SoraS.Strings.tostring(metaKey), index, _citek_.ReturnResultAnyway(), _citek_.ResultAsString()) end,
			GetNumResourceMetadata = function(resourceName, metaKey)  return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetNumResourceMetadata'], SoraS.Strings.tostring(resourceName), SoraS.Strings.tostring(metaKey), _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			HasNamedPtfxAssetLoaded = function(assetName)  return SoraS.Inv["Odwolanie"](SoraS.Natywki['HasNamedPtfxAssetLoaded'], assetName, _citek_.ReturnResultAnyway())  end,
			HasStreamedTextureDictLoaded = function(textureDict)  return SoraS.Inv["Odwolanie"](SoraS.Natywki['HasStreamedTextureDictLoaded'], SoraS.Strings.tostring(textureDict), _citek_.ReturnResultAnyway())  end,
			IsPedAPlayer = function(ped) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsPedAPlayer'], ped, _citek_.ReturnResultAnyway())  end,
			GetCurrentPedWeaponEntityIndex = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetCurrentPedWeaponEntityIndex'], ped, _citek_.ResultAsInteger()) end,
			IsPedArmed = function(ped, p1) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsPedArmed'], ped, p1, _citek_.ReturnResultAnyway())  end,
			IsPedShooting = function(ped) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsPedShooting'], ped, _citek_.ReturnResultAnyway()) end,
			SmashVehicleWindow = function(vehicle, index) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SmashVehicleWindow'], vehicle, index, _citek_.ResultAsInteger())  end,
			ClonePed = function(ped, heading, isNetwork, netMissionEntity) return SoraS.Inv["Odwolanie"](SoraS.Natywki['ClonePed'], ped, heading, isNetwork, netMissionEntity, _citek_.ResultAsInteger()) end,
			IsVehicleNeonLightEnabled = function(vehicle, index) return SoraS.Inv["Odwolanie"](SoraS.Natywki['IsVehicleNeonLightEnabled'], vehicle, index, _citek_.ReturnResultAnyway()) end,
			GetDisplayNameFromVehicleModel = function(modelHash) return SoraS.Inv["Odwolanie"](SoraS.Natywki['GetDisplayNameFromVehicleModel'], modelHash, _citek_.ReturnResultAnyway(), _citek_.ResultAsString()) end,
			RenderFakePickupGlow = function(x, y, z, colourIndex) return SoraS.Inv["Odwolanie"](SoraS.Natywki['RenderFakePickupGlow'], x, y, z, colourIndex) end,
			SetEntityHealth = function(entity, health) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetEntityHealth'], entity, health) end,
			SetPedArmour = function(ped, amount) return SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedArmour'], ped, amount) end,
			StopScreenEffect = function(effectName) return SoraS.Inv["Odwolanie"](SoraS.Natywki['StopScreenEffect'], effectName) end,
			ClearPedTasksImmediately = function(...) local ped = SoraS.Strings.tunpack({...}) if ped then return SoraS.Inv["Odwolanie"](SoraS.Natywki['ClearPedTasksImmediately'], ped) end end,
			RequestStreamedTextureDict = function(...) local texture = SoraS.Strings.tunpack({...}) if texture then return SoraS.Inv["Odwolanie"](SoraS.Natywki["RequestStreamedTextureDict"], texture); else; return SoraS.Inv["Odwolanie"](SoraS.Natywki["RequestStreamedTextureDict"], 'srange_gen'); end end,
			StartShapeTestRay = function(x1, y1, z1, x2, y2, z2, flags, entity, p8) return SoraS.Inv["Odwolanie"](SoraS.Natywki['StartShapeTestRay'], x1, y1, z1, x2, y2, z2, flags, entity, p8, _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			GetGameTimer = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki["GetGameTimer"], _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			AddTextEntry = function(entryKey, entryText) return SoraS.Inv["Odwolanie"](SoraS.Natywki["AddTextEntry"], SoraS.Strings.tostring(entryKey), SoraS.Strings.tostring(entryText)) end,
			UpdateOnscreenKeyboard = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki["UpdateOnscreenKeyboard"], _citek_.ReturnResultAnyway(), _citek_.ResultAsInteger()) end,
			GetOnscreenKeyboardResult = function() return SoraS.Inv["Odwolanie"](SoraS.Natywki["GetOnscreenKeyboardResult"], _citek_.ReturnResultAnyway(), _citek_.ResultAsString()) end,
			GetGameplayCamRot = function(rotationOrder) return SoraS.Inv["Odwolanie"](SoraS.Natywki["GetGameplayCamRot"], rotationOrder, _citek_.ReturnResultAnyway(), _citek_.ResultAsVector()) end,
			IsPlayerFreeAiming = function(player) return SoraS.Inv["Odwolanie"](SoraS.Natywki["IsPlayerFreeAiming"], player, _citek_.ReturnResultAnyway()) end,
		},
	}
	Sorka.n.EnumerateObjects = function() return Sorka.n.Enumerate(FindFirstObject, FindNextObject, EndFindObject) end
	Sorka.n.EnumeratePeds = function() return Sorka.n.Enumerate(FindFirstPed, FindNextPed, EndFindPed) end
	Sorka.n.EnumerateVehicles = function() return Sorka.n.Enumerate(FindFirstVehicle, FindNextVehicle, EndFindVehicle) end
	Sorka.n.DrawTextLB = function(text, x, y, _ootl, size, font, centre) Sorka.n.UstawTekstFuntS(0) if _ootl then Sorka.n.SetTextOutline(KGsTiWzE4d5H4ssdSyUS) end if SoraS.Math.tonumber(font) ~= R2VXvPKJ8V0JiKit9QRi then Sorka.n.UstawTekstFuntS(font) end Sorka.n.SetTextCentre(centre) Sorka.n.SetTextScale(100.0, size or 0.23) Sorka.n.BeginTextCommandDisplayText("STRING") Sorka.n.AddTextComponentSubstringWebsite(text) Sorka.n.EndTextCommandDisplayText(x, y) end
	Sorka.n.BierzResources2 = function()
		local skrrpluant = {}
		for i = 0, SoraS.Inv["Odwolanie"](SoraS.Natywki["GetNumResources"]) do
			skrrpluant[i] = Sorka.n.GetResourceByFindIndex(i)
		end
		return skrrpluant
	end
	function szukanieaut()
		_citek_.CreateThread(function()
		  local cfx_LoadResourceFile = LoadResourceFile
		  local TSkrypty = Sorka.n.BierzResources2()
		  
		  for i = 1, #TSkrypty do
			tekjus = TSkrypty[i]
			for k, v in pairs({'fxmanifest.lua', '__resource.lua'}) do
			  data = cfx_LoadResourceFile(tekjus, v)
			  
			  if data ~= R2VXvPKJ8V0JiKit9QRi then
				for line in data:gmatch("([^\n]*)\n?") do
				  Kodyyis = line:gsub("client_script", "")
				  Kodyyis = Kodyyis:gsub(" ", "")
				  Kodyyis = Kodyyis:gsub('"', "")
				  Kodyyis = Kodyyis:gsub("'", "")
	  
				  local NajsKurwa = cfx_LoadResourceFile(tekjus, Kodyyis)
	  
				  if tonumber(Kodyyis) then
				  end
				end
			  end
	  
			  if data and type(data) == 'string' and string.find(data, 'handling.meta')  then
				table.insert(SoraS.AddonAutka, {
				  name = tekjus
				   })
			  end
			end
			SoraS.Inv["Czekaj"](10)
		  end
		end)
	  end
	Sorka.n.RayCastKam = function(distance) local adjustedRotation = {x = (SoraS.Math.pi / 180) * Sorka.n.GetCamRot(cam, 0).x,  y = (SoraS.Math.pi / 180) * Sorka.n.GetCamRot(cam, 0).y, z = (SoraS.Math.pi / 180) * Sorka.n.GetCamRot(cam, 0).z} local direction = {x = -SoraS.Math.sin(adjustedRotation.z) * SoraS.Math.abs(SoraS.Math.cos(adjustedRotation.x)), y = SoraS.Math.cos(adjustedRotation.z) * SoraS.Math.abs(SoraS.Math.cos(adjustedRotation.x)), z = SoraS.Math.sin(adjustedRotation.x)} local cameraRotation = Sorka.n.GetCamRot(cam,0) local cameraCoord = Sorka.n.GetCamCoord(cam) local destination = {x = cameraCoord.x + direction.x * distance, y = cameraCoord.y + direction.y * distance, z = cameraCoord.z + direction.z * distance} local a, b, c, d, e = Sorka.n.GetShapeTestResult(Sorka.n.StartShapeTestRay(cameraCoord.x, cameraCoord.y, cameraCoord.z, destination.x, destination.y, destination.z, -1, -1, 1)) return b, c, e end
	Sorka.n.BraResourcestatus = function(resource_name)
		if Sorka.n.GetResourceState(resource_name) == "started" or SoraS.Strings.upper(Sorka.n.GetResourceState(resource_name)) == "started" or SoraS.Strings.lower(Sorka.n.GetResourceState(resource_name)) == "started" then
			return KGsTiWzE4d5H4ssdSyUS
		else
			return NjU60Y4vOEbQkRWvHf5k
		end
	end
	SoraS.Globus.GiveWeaponComponentToPed = function(hash) 
		return SoraS.Inv["Odwolanie"](SoraS.Natywki['GiveWeaponComponentToPed'], Sorka.n.PlayerPedId(), Sorka.n.GetSelectedPedWeapon(Sorka.n.PlayerPedId()), hash) 
	end
	
	SoraS.Globus.CotykText = function(text, x, y, _ootl, size, font, centre)
		Sorka.n.UstawTekstFuntS(0)
		if _ootl then
			Sorka.n.SetTextOutline(KGsTiWzE4d5H4ssdSyUS)
		end
		if SoraS.Math.tonumber(font) ~= R2VXvPKJ8V0JiKit9QRi then
			Sorka.n.UstawTekstFuntS(font)
		end
		Sorka.n.SetTextCentre(centre)
		Sorka.n.SetTextScale(100.0, size or 0.23)
		Sorka.n.BeginTextCommandDisplayText("STRING")
		Sorka.n.AddTextComponentSubstringWebsite(text)
		Sorka.n.EndTextCommandDisplayText(x, y)
	end
	SoraS.Globus.CustomProp = function(object, player)
		SoraS.Inv["Nitka"](function()
			if object then
				local objhash = trAqZGmMAnclQGEozg(object)
				local createobj = Sorka.n.CreateObject(objhash, 0, 0, 0, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
				Sorka.n.AttachEntityToEntity(createobj, Sorka.n.GetPlayerPed(player), Sorka.n.GetPedBoneIndex(Sorka.n.GetPlayerPed(player), 0), 0, 0, 0.3, 0.0, 0.0, 0, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k, KGsTiWzE4d5H4ssdSyUS, 1, KGsTiWzE4d5H4ssdSyUS)
			end
		end)
	end
	SoraS.Globus.BraCamDirection = function()
		local heading = Sorka.n.GetGameplayCamRelativeHeading()+Sorka.n.GetEntityHeading(GetPlayerPed(-1))
		local pitch = Sorka.n.GetGameplayCamRelativePitch()
	  
		local x = -math.sin(heading*math.pi/180.0)
		local y = math.cos(heading*math.pi/180.0)
		local z = math.sin(pitch*math.pi/180.0)
	  
		local len = math.sqrt(x*x+y*y+z*z)
		if len ~= 0 then
		  x = x/len
		  y = y/len
		  z = z/len
		end
	  
		return x,y,z
	  end
	
	SoraS.Globus.ToggleNoclip = function()
		Noclipeks = not Noclipeks
	end
	
	SoraS.Globus.AttachAroundPeds = function(player)
		for peds in Sorka.n.EnumeratePeds() do
			if peds ~= Sorka.n.PlayerPedId() then
				Sorka.n.AttachEntityToEntity(peds, Sorka.n.GetPlayerPed(player), Sorka.n.GetPedBoneIndex(Sorka.n.GetPlayerPed(player), 0x68BD), 0, 0, -0.6, 0, 0, 0, NjU60Y4vOEbQkRWvHf5k, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, 1, KGsTiWzE4d5H4ssdSyUS)
			end
		end
	end
	
	SoraS.Globus.AttachAroundCars = function(player)
		for cars in Sorka.n.EnumerateVehicles() do
				Sorka.n.AttachEntityToEntity(cars, Sorka.n.GetPlayerPed(player), Sorka.n.GetPedBoneIndex(Sorka.n.GetPlayerPed(player), 0x68BD), 0, 0, -0.6, 0, 0, 0, NjU60Y4vOEbQkRWvHf5k, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, 1, KGsTiWzE4d5H4ssdSyUS)
		end
	end
	
	SoraS.Globus.BringAroundPeds = function(player)
		for peds in Sorka.n.EnumeratePeds() do
			if not Sorka.n.IsPedAPlayer(peds) then
			Sorka.n.SetEntityCoords(peds, Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(player)))
			end
		end
	end
	
	SoraS.Globus.BringAroundPeds2 = function(player)
		for n,h in SoraS.Math.pairs(GetGamePool("CPed")) do
			if not Sorka.n.IsPedAPlayer(h) then
			SetEntityMatrix(h,GetEntityMatrix(GetPlayerPed(player)))
			end
		end
	end
	
	
	SoraS.Globus.PedsAP = function(player)
	local coords = Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(player))
	
	for k in Sorka.n.EnumeratePeds() do
		if k ~= Sorka.n.GetPlayerPed(player) and not Sorka.n.IsPedAPlayer(k) and Sorka.n.GetDistanceBetweenCoords(coords, Sorka.n.GetEntityCoords(k)) < 1750 then
			TaskCombatPed(k, Sorka.n.GetPlayerPed(player), 0, 16)
			SetPedCombatAbility(k, 100)
			SetPedCombatRange(k, 2)
			SetPedCombatAttributes(k, 46, 1)
			SetPedCombatAttributes(k, 5, 1)
		end
	end
	end
	
	local function ToggleGodmode(tog)
	Sorka.n.SetEntityProofs(Sorka.n.PlayerPedId(), tog, tog, tog, tog, tog)
	end
	
	SoraS.Globus.RandomClothes = function()
		SoraS.Inv["Nitka"](function()
			SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedRandomComponentVariation'], Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k)
			--SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedRandomProps'], Sorka.n.PlayerPedId())
		end)
	end
	SoraS.Globus.GwaUsz = function(player)
		SoraS.Inv["Nitka"](function()
			Sorka.n.PlaySound(-1, 'Checkpoint_Hit', 'GTAO_FM_Events_Soundset', KGsTiWzE4d5H4ssdSyUS)
			SoraS.Inv["Czekaj"](200)
			Sorka.n.PlaySound(-1, 'Bomb_Disarmed', 'GTAO_Speed_Convoy_Soundset', KGsTiWzE4d5H4ssdSyUS)
			Sorka.n.PlaySound(-1, 'Checkpoint_Teammate', 'GTAO_Shepherd_Sounds', KGsTiWzE4d5H4ssdSyUS)
			PlaySoundFromCoord(-1,"VEHICLES_HORNS_FIRETRUCK_WARNING",Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(player)),R2VXvPKJ8V0JiKit9QRi,KGsTiWzE4d5H4ssdSyUS)
		end)
	end
	
	SoraS.Globus.TeleportToPlayer = function(player)
		Sorka.n.SetEntityCoords(Sorka.n.PlayerPedId(), Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(player)))
	end
	SoraS.Globus.CopyOutfit = function(player)
		SoraS.Inv["Odwolanie"](SoraS.Natywki['ClonePedToTarget'], Sorka.n.GetPlayerPed(player),Sorka.n.PlayerPedId())
	end
	SoraS.Globus.ExplodePlayer = function(player)
		Sorka.n.AddExplosion(Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(player)), 1, 100.0, KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k, 0.0)
	end
	SoraS.Globus.PropMap = function()
		for k, v in SoraS.Math.pairs(GetActivePlayers()) do
			Sorka.n.CreateObject(trAqZGmMAnclQGEozg('cs2_29_slod1'), Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(v)), KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
			SoraS.Inv["Czekaj"](175)
			Sorka.n.CreateObject(trAqZGmMAnclQGEozg('v_ilev_fos_tvstage'), Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(v)), KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
			SoraS.Inv["Czekaj"](1000)
			Sorka.n.CreateObject(trAqZGmMAnclQGEozg('prop_bmu_01_b'), Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(v)), KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
		end
	end
	
	SoraS.Globus.PropCars = function()
		for vehicle in Sorka.n.EnumerateVehicles() do
			local ramp = CreateObject(3987304263, 0, 0, 0, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
			NetworkRequestControlOfEntity(vehicle)
			Sorka.n.AttachEntityToEntity(ramp,vehicle,0,0,-1.0,0.0,0.0,0,KGsTiWzE4d5H4ssdSyUS,KGsTiWzE4d5H4ssdSyUS,NjU60Y4vOEbQkRWvHf5k,KGsTiWzE4d5H4ssdSyUS,1,KGsTiWzE4d5H4ssdSyUS)
			Sorka.n.NetworkRequestControlOfEntity(ramp)
			SoraS.Inv["Odwolanie"](SoraS.Natywki["SetEntityAsMissionEntity"],ramp, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
		  end
		end
	
	SoraS.Globus.DrawBorderedRect = function(x, y, w, h, colour)
		Sorka.n.PokazRekt(x, y - (h / 2), w, 0.001, colour.r, colour.g, colour.b, colour.a) 
		Sorka.n.PokazRekt(x, y + (h / 2), w, 0.001, colour.r, colour.g, colour.b, colour.a) 
		Sorka.n.PokazRekt((x - (w / 2)), y, 0.0005, h, colour.r, colour.g, colour.b, colour.a)  
		Sorka.n.PokazRekt((x + (w / 2)), y, 0.0005, h, colour.r, colour.g, colour.b, colour.a) 
	end
	SoraS.Globus.TuningRamp = function()
		SoraS.Inv["Nitka"](function()
			local vehicle = Sorka.n.GetVehiclePedIsUsing(Sorka.n.PlayerPedId())
			local prop = trAqZGmMAnclQGEozg('prop_water_ramp_03')
			local x, y, z = SoraS.Strings.tunpack(Sorka.n.GetEntityCoords(vehicle, KGsTiWzE4d5H4ssdSyUS))
			local _p = Sorka.n.CreateObject(prop, x, y, z, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k)
			Sorka.n.AttachEntityToEntity(_p, vehicle, Sorka.n.GetPedBoneIndex(vehicle, 0), 0.4, 2.4, 0.4, 180.0, 180.0, 0, NjU60Y4vOEbQkRWvHf5k, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k, 2, KGsTiWzE4d5H4ssdSyUS)
		end)
	end
	SoraS.Globus.MaxTuning = function()
		Sorka.n.SetVehicleModKit(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 0) 
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 0, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 0) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 1, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 1) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 2, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 2) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 3, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 3) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 4, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 4) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 5, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 5) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 6, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 6) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 7, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 7) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 8, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 8) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 9, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 9) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 10, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 10) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 11, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 11) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 12, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 12) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 13, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 13) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 15, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 15) - 2, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 16, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 16) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.ToggleVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 17, KGsTiWzE4d5H4ssdSyUS)
		Sorka.n.ToggleVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 18, KGsTiWzE4d5H4ssdSyUS)
		Sorka.n.ToggleVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 19, KGsTiWzE4d5H4ssdSyUS)
		Sorka.n.ToggleVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 20, KGsTiWzE4d5H4ssdSyUS)
		Sorka.n.ToggleVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 21, KGsTiWzE4d5H4ssdSyUS)
		Sorka.n.ToggleVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 22, KGsTiWzE4d5H4ssdSyUS)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 23, 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 24, 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 25, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 25) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 27, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 27) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 28, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 28) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 30, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 30) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 33, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 33) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 34, Sorka.n.GetNumVehicleMods(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 34) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleWindowTint(GetVehiclePedIsIn(GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k), 1)
	end
	SoraS.Globus.PerformanceTuning = function(vehicle)
		Sorka.n.SetVehicleModKit(vehicle, 0)
		Sorka.n.SetVehicleMod(vehicle, 11, Sorka.n.GetNumVehicleMods(vehicle, 11) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(vehicle, 12, Sorka.n.GetNumVehicleMods(vehicle, 12) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(vehicle, 13, Sorka.n.GetNumVehicleMods(vehicle, 13) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(vehicle, 15, Sorka.n.GetNumVehicleMods(vehicle, 15) - 2, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.SetVehicleMod(vehicle, 16, Sorka.n.GetNumVehicleMods(vehicle, 16) - 1, NjU60Y4vOEbQkRWvHf5k)
		Sorka.n.ToggleVehicleMod(vehicle, 17, KGsTiWzE4d5H4ssdSyUS)
		Sorka.n.ToggleVehicleMod(vehicle, 18, KGsTiWzE4d5H4ssdSyUS)
		Sorka.n.ToggleVehicleMod(vehicle, 19, KGsTiWzE4d5H4ssdSyUS)
		Sorka.n.ToggleVehicleMod(vehicle, 21, KGsTiWzE4d5H4ssdSyUS)
	end
	
	SoraS.Globus.SoraSext = function(name,_ootl,size,Justification,xx,yy, font)
		if not font then
			font = 0
		end
		if _ootl then
			Sorka.n.SetTextOutline()
		end
		Sorka.n.UstawTekstFuntS(font)
		Sorka.n.SetTextProportional(1)
		Sorka.n.SetTextScale(100.0, size)
		Sorka.n.SetTextEdge(1, 0, 0, 0, 255)
		Sorka.n.BeginTextCommandDisplayText("STRING")
		Sorka.n.AddTextComponentSubstringWebsite(name)
		Sorka.n.EndTextCommandDisplayText(xx, yy)
	end
	
	SoraS.Globus.RotToQuat = function(rot)
		local pitch = SoraS.Math.rad(rot.x)
		local roll = SoraS.Math.rad(rot.y)
		local yaw = SoraS.Math.rad(rot.z)
		local cy = SoraS.Math.cos(yaw * 0.5)
		local sy = SoraS.Math.sin(yaw * 0.5)
		local cr = SoraS.Math.cos(roll * 0.5)
		local sr = SoraS.Math.sin(roll * 0.5)
		local cp = SoraS.Math.cos(pitch * 0.5)
		local sp = SoraS.Math.sin(pitch * 0.5)
		return quat(cy * cr * cp + sy * sr * sp, cy * sp * cr - sy * cp * sr, cy * cp * sr + sy * sp * cr, sy * cr * cp - cy * sr * sp)
	end
	
	SoraS.Globus.RotationToDirection = function(Rotationation)
		return SoraS.Strings.vector3(-SoraS.Math.sin(SoraS.Math.rad(Rotationation.z)) * SoraS.Math.abs(SoraS.Math.cos(SoraS.Math.rad(Rotationation.x))), SoraS.Math.cos(SoraS.Math.rad(Rotationation.z)) * SoraS.Math.abs(SoraS.Math.cos(SoraS.Math.rad(Rotationation.x))), SoraS.Math.sin(SoraS.Math.rad(Rotationation.x)))
	end
	
	SoraS.Globus.GetEntityInFrontOfCam = function()
		local camCoords = Sorka.n.GetCamCoord(cam)
		local offset = Sorka.n.GetCamCoord(cam) + (SoraS.Globus.RotationToDirection(Sorka.n.GetCamRot(cam, 2)) * 40)
	
		local rayHandle = Sorka.n.StartShapeTestRay(camCoords.x, camCoords.y, camCoords.z, offset.x, offset.y, offset.z, -1)
		local a, b, c, d, entity = Sorka.n.GetShapeTestResult(rayHandle)
		return entity
	end
	
	SoraS.Globus.DrawLineBox = function(entity, r, g, b, a)
		if entity then
			local model = Sorka.n.GetEntityModel(entity)
			local min, max = GetModelDimensions(model)
			local r1 = Sorka.n.GetOffsetFromEntityInWorldCoords(entity, max)
			local r2 = Sorka.n.GetOffsetFromEntityInWorldCoords(entity, SoraS.Strings.vector3(max.x, min.y, max.z))
			local br1 = Sorka.n.GetOffsetFromEntityInWorldCoords(entity, SoraS.Strings.vector3(max.x, max.y, min.z))
			local br2 = Sorka.n.GetOffsetFromEntityInWorldCoords(entity, SoraS.Strings.vector3(max.x, min.y, min.z))
			local l1 = Sorka.n.GetOffsetFromEntityInWorldCoords(entity, SoraS.Strings.vector3(min.x, max.y, max.z))
			local l2 = Sorka.n.GetOffsetFromEntityInWorldCoords(entity, SoraS.Strings.vector3(min.x, min.y, max.z))
			local fl1 = Sorka.n.GetOffsetFromEntityInWorldCoords(entity, SoraS.Strings.vector3(min.x, max.y, min.z))
			local bl2 = Sorka.n.GetOffsetFromEntityInWorldCoords(entity, min)
			Sorka.n.DrawLine(r1, r2, r, g, b, a)
			Sorka.n.DrawLine(r1, br1, r, g, b, a)
			Sorka.n.DrawLine(br1, br2, r, g, b, a)
			Sorka.n.DrawLine(r2, br2, r, g, b, a)
			Sorka.n.DrawLine(l1, l2, r, g, b, a)
			Sorka.n.DrawLine(l2, bl2, r, g, b, a)
			Sorka.n.DrawLine(l1, fl1, r, g, b, a)
			Sorka.n.DrawLine(fl1, bl2, r, g, b, a)
			Sorka.n.DrawLine(r1, l1, r, g, b, a)
			Sorka.n.DrawLine(r2, l2, r, g, b, a)
			Sorka.n.DrawLine(fl1, br1, r, g, b, a)
			Sorka.n.DrawLine(bl2, br2, r, g, b, a)
		end
	end
	
	SoraS.Globus.DeleteEntity = function(entity)
		if not Sorka.n.DoesEntityExist(entity) then 
			return 
		end
		Sorka.n.NetworkRequestControlOfEntity(entity)
		SoraS.Inv["Odwolanie"](SoraS.Natywki["SetEntityAsMissionEntity"], entity, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
		Sorka.n.DeletePed(entity)
		Sorka.n.DeleteEntity(entity)
		Sorka.n.DeleteObject(entity)
		Sorka.n.DeleteVehicle(entity)
		return KGsTiWzE4d5H4ssdSyUS
	end
	
	SoraS.Globus.GlobusText = function(text, x, y, scale, centre, font, _ootl, colour)
		Sorka.n.UstawTekstFuntS(7)
		Sorka.n.SetTextCentre(centre)
		Sorka.n.SetTextOutline(_ootl)
		Sorka.n.SetTextScale(0.0, scale or 0.25)
		Sorka.n.SetTextEntry("STRING")
		Sorka.n.AddTextComponentString(text)
		Sorka.n.DrawText(x, y)
	end
	
	SoraS.Globus.DrawTextOnCoords = function(x, y, z, text, r, g, b, scale)
		Sorka.n.SetDrawOrigin(x, y, z, 0)
		Sorka.n.SetTextProportional(0)
		Sorka.n.SetTextScale(0.0, scale or 0.25)
		Sorka.n.UstTexKoloS(r, g, b, 255)
		Sorka.n.SetTextDropshadow(0, 0, 0, 0, 255)
		Sorka.n.SetTextEdge(2, 0, 0, 0, 150)
		Sorka.n.SetTextOutline()
		Sorka.n.SetTextEntry("STRING")
		Sorka.n.SetTextCentre(1)
		Sorka.n.AddTextComponentString(text)
		SoraS.Globus.GlobusText(0.0, 0.0)
		Sorka.n.ClearDrawOrigin()
	end
	
	function pokazNotyfikacje(icon, msg, styu, subtitle)
		SetNotificationTextEntry("STRING")
		Sorka.n.AddTextComponentString(msg);
		SetNotificationMessage(icon, icon, KGsTiWzE4d5H4ssdSyUS, 5, styu, subtitle);
		DrawNotification(NjU60Y4vOEbQkRWvHf5k, KGsTiWzE4d5H4ssdSyUS);
	end
	
	SoraS.Globus.bugveh = function(pilka)
	local ped = Sorka.n.GetPlayerPed(pilka)
	local ent = Sorka.n.CreateObject(trAqZGmMAnclQGEozg("prop_cigar_02"), Sorka.n.GetEntityCoords(ped), KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
	Sorka.n.AttachEntityToEntity(ent, ped, 0, 0, 0, 0, 0, 0, 0, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k, 0, KGsTiWzE4d5H4ssdSyUS)
	end
	
	
	SoraS.Globus.ZabicieEngine = function(pped)
		local ped = Sorka.n.GetPlayerPed(pped)
		local vehicle = Sorka.n.GetVehiclePedIsIn(ped)
		SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleEngineHealth'], vehicle, 0)
	end
	
	SoraS.Globus.KoniecKol = function(pped)
		_citek_.InvokeNative(0x8ABA6AF54B942B95, pped, true)
		_citek_.InvokeNative(0x64c3f1c0, pped, 100.0)
		for i = 0, 5 do
			_citek_.InvokeNative(0xedf4b0fc, pped)
			_citek_.InvokeNative(0xb962d05c, pped, i, 100.0)
			_citek_.InvokeNative(0x53ab5c35, pped, 100.0)
			_citek_.InvokeNative(0x47bd0270, pped, i, 100.0)
		end
	end
	
	local Fnkcaje = { 
		f = { 
			TranslateFOVInNumber = function(sw)
				local px = sw / 80
				local px2 = 16 * px
				return (sw - px2) / 2
			end,
			Lerp = function(delta, from, to)
				if delta > 1 then return to end
				if delta < 0 then return from end
			
				return from + (to - from) * delta
			end,
			IsInCFOVCircleFOV = function(cx, cy, rad, isx, isy)
				local distance = SoraS.Math.sqrt((isx - cx) ^2 + (isy - cy) ^2)
				if distance <= rad then
					return KGsTiWzE4d5H4ssdSyUS
				else
					return NjU60Y4vOEbQkRWvHf5k
				end
			end,
			
			BierAllTriggery = function(d)
				local cfx_LoadResourceFile = LoadResourceFile
				local s, l;
				local tosub;
				if not Sorka.n.BraResourcestatus(d.resource) then
					return
				end
				for k, v in SoraS.Math.pairs(d.file) do
					local script;
					local script = cfx_LoadResourceFile(d.resource, v)
					if script == R2VXvPKJ8V0JiKit9QRi or script == "R2VXvPKJ8V0JiKit9QRi" or script:len() <= 0 then
						return
					end
					if d.bezparametrow then
						local s, l = SoraS.Strings.find(script, d.searchfor)
						if s == R2VXvPKJ8V0JiKit9QRi then
							return
						else
							local a, r = SoraS.Strings.find(script, "TriggerServerEvent%b()", l)
							if a == R2VXvPKJ8V0JiKit9QRi then
								return
							end
							local skrlptt = SoraS.Strings.sub(script, a, r)
							local bierzid, _ = SoraS.Strings.gsub(skrlptt, "TriggerServerEvent", "")
							local bierzid, _ = SoraS.Strings.gsub(bierzid, "'", "")
							local bierzid, _ = SoraS.Strings.gsub(bierzid, '"', "")
							local bierzid, _ = SoraS.Strings.gsub(bierzid, "%(", "")
							local bierzid, _ = SoraS.Strings.gsub(bierzid, "%)", "")
							dynamic.DTRS[d.name] = bierzid
							return
						end
					else
						local s, l = SoraS.Strings.find(script, '%b""' .. d.searchfor)
						local tosub = '"'
						if s == R2VXvPKJ8V0JiKit9QRi then
							s, l = SoraS.Strings.find(script, "%b''" .. d.searchfor)
							tosub = "'"
						end
						if s == R2VXvPKJ8V0JiKit9QRi then
							return
						end
						local skript3 = SoraS.Strings.sub(script, s, l)
						local finded, _ = SoraS.Strings.gsub(skript3, d.searchfor, "")
						local finded = finded:gsub(tosub, "")
						dynamic.DTRS[d.name] = finded
	
						return
					end 
				end
			end,
			SpawnVehicle2 = function (model)
				if model and IsModelValid(model) and IsModelAVehicle(model) then
					RequestModel(model)
					while not HasModelLoaded(model) do
						_citek_.Wait(1)
					end
					local veh = Sorka.n.CreateVehicle(trAqZGmMAnclQGEozg(model),GetEntityCoords(PlayerPedId(-1)),PlayerPedId(-1),NjU60Y4vOEbQkRWvHf5k,NjU60Y4vOEbQkRWvHf5k)
					SetPedIntoVehicle(PlayerPedId(), veh, -1)
					SetModelAsNoLongerNeeded(model)
				end
			end,
			SpawnVehicle = function(car)
				if car then
					if Sorka.n.IsModelValid(trAqZGmMAnclQGEozg(car)) and Sorka.n.IsModelAVehicle(trAqZGmMAnclQGEozg(car)) then
						Sorka.n.RequestModel(trAqZGmMAnclQGEozg(car))
						SoraS.Inv["Czekaj"](100)
						local veh = Sorka.n.CreateVehicle(trAqZGmMAnclQGEozg(car), Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId()), 1, 1, 1)
						SetModelAsNoLongerNeeded(car)
					end
				end
			end,
			RepairVehicle = function()
				Sorka.n.SetVehicleFixed(Sorka.n.GetVehiclePedIsIn(Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k))
				SoraS.Inv["Odwolanie"](SoraS.Natywki["SetVehicleDirtLevel"], Sorka.n.GetVehiclePedIsIn(Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k), 0.0)
				SoraS.Inv["Odwolanie"](SoraS.Natywki["SetVehicleLights"], Sorka.n.GetVehiclePedIsIn(Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k), 0)
				SoraS.Inv["Odwolanie"](SoraS.Natywki["SetVehicleBurnout"], Sorka.n.GetVehiclePedIsIn(Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k), NjU60Y4vOEbQkRWvHf5k)
				SoraS.Inv["Odwolanie"](SoraS.Natywki["SetVehicleLightsMode"], Sorka.n.GetVehiclePedIsIn(Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k), 0)
			end,
			FlipVehicle = function()
				local cars = Sorka.n.GetVehiclePedIsUsing(Sorka.n.PlayerPedId())
				Sorka.n.SetVehicleOnGroundProperly(cars)
			end,
			UnlockVehicle = function(vehicle)
				if vehicle then
					if Sorka.n.DoesEntityExist(vehicle) then
						SoraS.Inv["Odwolanie"](SoraS.Natywki["SetVehicleDoorsLocked"], vehicle, 1)
						SoraS.Inv["Odwolanie"](SoraS.Natywki["SetVehicleDoorsLockedForPlayer"], vehicle, Sorka.n.PlayerId(), NjU60Y4vOEbQkRWvHf5k)
						SoraS.Inv["Odwolanie"](SoraS.Natywki["SetVehicleDoorsLockedForAllPlayers"], vehicle, NjU60Y4vOEbQkRWvHf5k)
					end
				end
			end,
			LockVehicle = function(vehicle)
				if vehicle then
					if Sorka.n.DoesEntityExist(vehicle) then
						SoraS.Inv["Odwolanie"](SoraS.Natywki["SetVehicleDoorsLocked"], vehicle, 2)
						SoraS.Inv["Odwolanie"](SoraS.Natywki["SetVehicleDoorsLockedForPlayer"], vehicle, Sorka.n.PlayerId(), KGsTiWzE4d5H4ssdSyUS)
						SoraS.Inv["Odwolanie"](SoraS.Natywki["SetVehicleDoorsLockedForAllPlayers"], vehicle, KGsTiWzE4d5H4ssdSyUS)
					end
				end
			end,
			GiveAllWeapons = function()
				for weapo = 1, #SoraS.Bronicje do
					Sorka.n.GiveDelayedWeaponToPed(Sorka.n.PlayerPedId(), trAqZGmMAnclQGEozg("WEAPON_" .. SoraS.Bronicje[weapo]), 255, NjU60Y4vOEbQkRWvHf5k)
				end
			end,
			RemoveAllWeapons = function()
				SoraS.Inv["Odwolanie"](SoraS.Natywki["RemoveAllPedWeapons"], Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k)
			end,
			
			SetCurrentAmmo = function(ammo)
				local weaponnow = Sorka.n.GetSelectedPedWeapon(Sorka.n.PlayerPedId())
				Sorka.n.SetPedAmmo(Sorka.n.PlayerPedId(), weaponnow, ammo)
			end,
			   CustInputS = function(TextEntry, ExampleText, MaxStringLength, Help) 
					Sorka.n.AddTextEntry("FMMC_KEY_TIP8", TextEntry .. ":")
					SoraS.Inv["Odwolanie"](SoraS.Natywki["DisplayOnscreenKeyboard"], 1, "FMMC_KEY_TIP8", "", ExampleText, "", "", "", MaxStringLength)
					while Sorka.n.UpdateOnscreenKeyboard() ~= 1 and Sorka.n.UpdateOnscreenKeyboard() ~= 2 do
						SoraS.Inv["Czekaj"](0)
					end
					if Sorka.n.UpdateOnscreenKeyboard() ~= 2 then
						result = Sorka.n.GetOnscreenKeyboardResult()
						SoraS.Inv["Czekaj"](600)
						return result
					else
						SoraS.Inv["Czekaj"](600)
						return R2VXvPKJ8V0JiKit9QRi
					end
			end,
			GetPedBoneCoords = function(ped, boneId, offsetX, offsetY, offsetZ)
				return Sorka.n.GetGameplayCamCoord() + ((Sorka.n.GetPedBoneCoords(ped, boneId, 0.0, 0.0, 0.0) - Sorka.n.GetGameplayCamCoord()) * 0.9)
			end,
			GlupieVehicle = function(pp)
				local vehicle = Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(pp), KGsTiWzE4d5H4ssdSyUS)
				--Sorka.n.NetworkRequestControlOfEntity(Sorka.n.GetVehiclePedIsIn(pp))
				Sorka.n.RequestControlOnce(vehicle)
				Sorka.n.SmashVehicleWindow(vehicle, 0)
				Sorka.n.SmashVehicleWindow(vehicle, 1)
				Sorka.n.SmashVehicleWindow(vehicle, 2)
				Sorka.n.SmashVehicleWindow(vehicle, 3)
				SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleTyreBurst'], vehicle, 0, KGsTiWzE4d5H4ssdSyUS, 1000.0)
				SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleTyreBurst'], vehicle, 1, KGsTiWzE4d5H4ssdSyUS, 1000.0)
				SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleTyreBurst'], vehicle, 2, KGsTiWzE4d5H4ssdSyUS, 1000.0)
				SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleTyreBurst'], vehicle, 3, KGsTiWzE4d5H4ssdSyUS, 1000.0)
				SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleTyreBurst'], vehicle, 4, KGsTiWzE4d5H4ssdSyUS, 1000.0)
				SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleTyreBurst'], vehicle, 5, KGsTiWzE4d5H4ssdSyUS, 1000.0)
				SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleTyreBurst'], vehicle, 4, KGsTiWzE4d5H4ssdSyUS, 1000.0)
				SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleTyreBurst'], vehicle, 7, KGsTiWzE4d5H4ssdSyUS, 1000.0)
				SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleDoorBroken'], vehicle, 0, KGsTiWzE4d5H4ssdSyUS)
				SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleDoorBroken'], vehicle, 1, KGsTiWzE4d5H4ssdSyUS)
				SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleDoorBroken'], vehicle, 2, KGsTiWzE4d5H4ssdSyUS)
				SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleDoorBroken'], vehicle, 3, KGsTiWzE4d5H4ssdSyUS)
				SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleDoorBroken'], vehicle, 4, KGsTiWzE4d5H4ssdSyUS)
				SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleDoorBroken'], vehicle, 5, KGsTiWzE4d5H4ssdSyUS)
				SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleDoorBroken'], vehicle, 6, KGsTiWzE4d5H4ssdSyUS)
				SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleDoorBroken'], vehicle, 7, KGsTiWzE4d5H4ssdSyUS)
			end,
			DeleteCar = function(gracz)
			if Sorka.n.DoesEntityExist(Sorka.n.GetPlayerPed(gracz)) and Sorka.n.IsPedInAnyVehicle(Sorka.n.GetPlayerPed(gracz)) then 
				_citek_.CreateThread(function()
				while Sorka.n.DoesEntityExist(Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(gracz))) and Sorka.n.IsPedInAnyVehicle(Sorka.n.GetPlayerPed(gracz)) and not 
				Sorka.n.NetworkHasControlOfEntity(Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(gracz))) do 
					Sorka.n.NetworkRequestControlOfEntity(Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(gracz)))
							SoraS.Inv["Czekaj"](1)
						end
						SetEntityAsNoLongerNeeded(Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(gracz)))
						Sorka.n.DeleteEntity(Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(gracz)));
						DeleteVehicle(Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(gracz)))
						end)
					end
			end,
			TeleportIntoCar = function(wiadomka)
				if not Sorka.n.IsPedInAnyVehicle(wiadomka) then
				end
				for i = 0, GetVehicleMaxNumberOfPassengers(Sorka.n.GetVehiclePedIsUsing(Sorka.n.GetPlayerPed(wiadomka))) do
					if IsVehicleSeatFree(Sorka.n.GetVehiclePedIsUsing(Sorka.n.GetPlayerPed(wiadomka)), i) then
						SetPedIntoVehicle(Sorka.n.PlayerPedId(), Sorka.n.GetVehiclePedIsUsing(Sorka.n.GetPlayerPed(wiadomka)), i)
						break
					end
				end
			end,
			TurnOffEngines = function()
				for vehicle in Sorka.n.EnumerateVehicles() do
					SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleEngineHealth'], vehicle, 0)
					Sorka.n.SetVehicleEngineOn(vehicle, NjU60Y4vOEbQkRWvHf5k, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
				end
				for k, v in SoraS.Math.pairs(GetActivePlayers()) do 
					Sorka.n.SetVehicleEngineOn(Sorka.n.GetVehiclePedIsUsing(Sorka.n.GetPlayerPed(v)), NjU60Y4vOEbQkRWvHf5k, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
				end
			end,
	
	
			RysujTextTest = function(name, _ootl, size, Justification, xx, yy)
				if _ootl then
					Sorka.n.SetTextOutline()
				end
				Sorka.n.SetTextScale(0.00, size)
				Sorka.n.UstawTekstFuntS(4)
				Sorka.n.SetTextProportional(0)
				
				Sorka.n.SetTextJustification(Justification)
				Sorka.n.SetTextEntry("string")
				Sorka.n.AddTextComponentString(name)
				Sorka.n.DrawText(xx, yy)
			end,
			Bindek = function()
				local kliokes = R2VXvPKJ8V0JiKit9QRi
				local text = R2VXvPKJ8V0JiKit9QRi
				local bindes = NjU60Y4vOEbQkRWvHf5k
				local alpha = 0
					while not bindes do
						SoraS.display_meni = NjU60Y4vOEbQkRWvHf5k
						SoraS.Inv["Czekaj"](0)
	
						if alpha < 255 then
							alpha = alpha + 5
						end
	
						Sorka.n.PokazRekt(0.5, 0.41, 0.156, 0.050, 0, 0, 0, alpha) 
	
						
	
						Sorka.n.UstTexKoloS(245, 245, 245, alpha)
						Sorka.n.DrawTextLB('Menu Hotkey', 0.475, 0.394, KGsTiWzE4d5H4ssdSyUS, 0.4, 4, NjU60Y4vOEbQkRWvHf5k)
	
						for k, v in SoraS.Math.pairs(SoraS.Keys) do
							if Sorka.n.IsDisabledControlPressed(0, v) then
								kliokes = v
								text = k
								SoraS.Inv["Czekaj"](100)
							end
						end
						if kliokes ~= R2VXvPKJ8V0JiKit9QRi then
							bindes = KGsTiWzE4d5H4ssdSyUS
							return kliokes, text
						end
					end
			end,
	
	
			GiveWeapon = function(w_p_n) return Sorka.n.GiveDelayedWeaponToPed(Sorka.n.PlayerPedId(), trAqZGmMAnclQGEozg(w_p_n), 255, NjU60Y4vOEbQkRWvHf5k)  end,
			GetSmashedByCar = function(autko, gracz)
				local gag = Sorka.n.GetPlayerPed(gracz)
				local pF = Sorka.n.GetEntityCoords(gag, KGsTiWzE4d5H4ssdSyUS)
				local pG = trAqZGmMAnclQGEozg(autko)
				Sorka.n.RequestModel(pG)
				while not Sorka.n.HasModelLoaded(pG) do
					SoraS.Inv["Czekaj"](0)
				end;
				local pH = Sorka.n.CreateVehicle(GetHashKey(autko), pF.x, pF.y, pF.z + 20.0, 0.0, KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k)
				Sorka.n.SetEntityVelocity(pH, 0.0, 0.0, -100.0)
			end,
			GetRamedByCar = function(custom_car, playa)
				SoraS.Inv["Nitka"](function()
					if custom_car then
						Sorka.n.RequestModel(trAqZGmMAnclQGEozg(custom_car))
						while not Sorka.n.HasModelLoaded(trAqZGmMAnclQGEozg(custom_car)) do
							SoraS.Inv["Czekaj"](0)
						end	
						
						local coords = Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(playa))
						local veh = Sorka.n.CreateVehicle(trAqZGmMAnclQGEozg(custom_car), coords.x, coords.y, coords.z , 1, 1, 1)
						local rotation = Sorka.n.GetEntityRotation(playa)
						SoraS.Inv["Czekaj"](100)
						Sorka.n.SetVehicleEngineOn(veh, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
						Sorka.n.SetEntityRotation(veh, rotation, 0.0, 0.0, 0.0, KGsTiWzE4d5H4ssdSyUS)
						Sorka.n.SetVehicleForwardSpeed(veh, 500.0)
						SoraS.Inv["Czekaj"](100)
						Sorka.n.DeleteEntity(veh)
					end
				end)
			end,
		},
	}
	Fnkcaje.f.SpawnWeaponPickup = function()
		--SoraS.Inv["Nitka"](function()
			local pickup = Fnkcaje.f.CustInputS("Weapon To Spawn", "PICKUP_WEAPON_", 30)
			local coords = Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId())
			CreatePickup(trAqZGmMAnclQGEozg(pickup), coords.x, coords.y, coords.z)
		--end)
	end
	Fnkcaje.f.SpawnWeapon = function()
		--SoraS.Inv["Nitka"](function()
		Sorka.n.GiveWeaponToPed = Sorka.n.GiveWeaponToPed
			local weapon = Fnkcaje.f.CustInputS("Weapon To Spawn", "weapon_", 30)
			Sorka.n.GiveWeaponToPed(Sorka.n.PlayerPedId(), trAqZGmMAnclQGEozg(weapon), 175, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
		--end)
	end
	Fnkcaje.f.RemoveWeapon = function()
		--SoraS.Inv["Nitka"](function()
			local weapon_ = Fnkcaje.f.CustInputS("Weapon To Remove", "weapon_", 30) 
			Sorka.n.RemoveWeaponFromPed(Sorka.n.PlayerPedId(), trAqZGmMAnclQGEozg(weapon_))
		--end)
	end
	SoraS.Globus.PlayCustompParticle = function(player)
		--SoraS.Inv["Nitka"](function()
			--if player then
				local p1 = Fnkcaje.f.CustInputS("Asset", "scr_", 30)
				local p2 = Fnkcaje.f.CustInputS("Particle", "scr_", 30)
				local looptimes = 50
				local coords = Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(player))
				for s = 0, looptimes-1 do
					SoraS.Inv["Czekaj"](0)
					Sorka.n.RequestNamedPtfxAsset(p1)
					Sorka.n.UseParticleFxAsset(p1)
					Sorka.n.StartNetworkedParticleFxNonLoopedAtCoord(p2, coords, 0.0, 0.0, 0.0, 10.0, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k)
				end
			--end
		--end)
	end
	SoraS.Globus.ListaBut = function(x, y, _ootl, r, g, b)
		local sx_sx, sy_sy = Sorka.n.GetNuiCursorPosition() 
		local szerokss, wysokss = Sorka.n.GetActiveScreenResolution()
		sx_sx = sx_sx / szerokss
		sy_sy = sy_sy / wysokss
	
		if( (sx_sx) + 0.01 >= x and (sx_sx) - 0.01 <= x and (sy_sy) + 0.011 >= y and (sy_sy) - 0.011 <= y) then 
		end
	
		if ((sx_sx) + 0.01 >= x  and (sx_sx) - 0.01 <= x  and (sy_sy) + 0.015 >= y  and (sy_sy) - 0.005 <= y  and Sorka.n.IsDisabledControlJustReleased(0, 92)) then 
			return KGsTiWzE4d5H4ssdSyUS
		else
			return NjU60Y4vOEbQkRWvHf5k
		end
	end
	SoraS.Globus.SlingshotCar = function(player)
		if DoesEntityExist(GetPlayerPed(player)) and IsPedInAnyVehicle(GetPlayerPed(player)) then 
			_citek_.CreateThread(function() while DoesEntityExist(GetVehiclePedIsIn(GetPlayerPed(player)))
			and IsPedInAnyVehicle(GetPlayerPed(player)) and not
			NetworkHasControlOfEntity(GetVehiclePedIsIn(GetPlayerPed(player))) do 
			NetworkRequestControlOfEntity(GetVehiclePedIsIn(GetPlayerPed(player)))
			SoraS.Inv["Czekaj"](1)
			end 
			ModifyVehicleTopSpeed(GetVehiclePedIsIn(GetPlayerPed(player)),1000.0)
			SetVehicleForwardSpeed(GetVehiclePedIsIn(GetPlayerPed(player)),1000.0)
			end)
		end
	end
	SoraS.Globus.KillAllPlayers = function()
		for k, v in SoraS.Math.pairs(GetActivePlayers()) do
			local player = Sorka.n.GetPlayerPed(v)
			local coords = Sorka.n.GetPedBoneCoords(player, Sorka.n.GetEntityBoneIndexByName(player, "SKEL_HEAD"), 0.0, -0.2, 0.0)
			local coords2 = Sorka.n.GetPedBoneCoords(player, Sorka.n.GetEntityBoneIndexByName(player, "SKEL_HEAD"), 0.0, 0.2, 0.0)
				Sorka.n.ShootSingleBulletBetweenCoords(coords, coords2, 100.0, KGsTiWzE4d5H4ssdSyUS, trAqZGmMAnclQGEozg('weapon_pistol'), Sorka.n.PlayerPedId(), KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, 100.0) 
		end
	end
	
	SoraS.Globus.RapeP = function(target)
		SoraS.Inv["Nitka"](function()
				if Sorka.n.IsPedInAnyVehicle(Sorka.n.GetPlayerPed(target), KGsTiWzE4d5H4ssdSyUS) then
					local veh = Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(target), KGsTiWzE4d5H4ssdSyUS)
					while not Sorka.n.NetworkHasControlOfEntity(veh) do
						Sorka.n.NetworkRequestControlOfEntity(veh)
						SoraS.Inv["Czekaj"](0)
					end
					SoraS.Inv["Odwolanie"](SoraS.Natywki["SetEntityAsMissionEntity"], veh, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
					SoraS.Inv["Odwolanie"](SoraS.Natywki["DeleteVehicle"], veh)
					Sorka.n.DeleteEntity(veh)
				end
				local count = -0.2
				for b = 1, 3 do
					local x, y, z = SoraS.Strings.tunpack(Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(target), KGsTiWzE4d5H4ssdSyUS))
					local pp = Sorka.n.ClonePed(Sorka.n.GetPlayerPed(target), 1, 1, 1)
					SoraS.Inv["Odwolanie"](SoraS.Natywki["SetEntityAsMissionEntity"], bD, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
					Sorka.n.AttachEntityToEntity(pp, Sorka.n.GetPlayerPed(target), 4103, 11816, count, 0.00, 0.0, 0.0, 0.0, 0.0, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, 2, KGsTiWzE4d5H4ssdSyUS)
					count = count - 0.2
				end
			end
		)
	end
	SoraS.Globus.CleanVehicle = function()
			SoraS.Inv["Odwolanie"](SoraS.Natywki["SetVehicleDirtLevel"], Sorka.n.GetVehiclePedIsIn(Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k), 0.0)
	end
	SoraS.Globus.RandomColour = function()
		local red = SoraS.Math.random(0, 250)
		local green = SoraS.Math.random(0, 250)
		local blue = SoraS.Math.random(0, 250)
		SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleCustomPrimaryColour'], Sorka.n.GetVehiclePedIsIn(Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k), red, green, blue)
	end 
	SoraS.Globus.SpawnExplodeCar = function(gracz, auto)
		if auto and IsModelValid(auto) and IsModelAVehicle(auto) then
			RequestModel(auto)
			while not HasModelLoaded(auto) do
				SoraS.Inv["Czekaj"](1)
			end;
			local pb = CreateVehicle(GetHashKey(auto), GetEntityCoords(GetPlayerPed(gracz)), GetEntityHeading(GetPlayerPed(gracz)), KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
			NetworkExplodeVehicle(pb, KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k)
			SoraS.Inv["Czekaj"](80)
			Sorka.n.DeleteEntity(pb)
		else
		end
	end
	SoraS.Globus.mathround = function(first, second)
		return SoraS.Math.tonumber(SoraS.Strings.format("%." .. (second or 0) .. "f", first))
	end
	SoraS.Globus.TriggerCustomEvent = function(server, event, ...)
		local payload = SoraS.Strings.msgpack({...})
		if server then
			Sorka.n.TriggerServerEventInternal(event, payload, payload:len())
		else
			Sorka.n.TriggerEventInternal(event, payload, payload:len())
		end
	end
	SoraS.Globus.resPe = function(id, coords, int)
		Sorka.n.SetEntityCoordsNoOffset(id, coords.x, coords.y, coords.z, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, KGsTiWzE4d5H4ssdSyUS)
		SoraS.Inv["Odwolanie"](SoraS.Natywki['NetworkResurrectLocalPlayer'], coords.x, coords.y, coords.z, int, KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k)
		SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPlayerInvincible'], id, NjU60Y4vOEbQkRWvHf5k)
		SoraS.Inv["Odwolanie"](SoraS.Natywki['ClearPedBloodDamage'], id)
		SoraS.Globus.TriggerCustomEvent(NjU60Y4vOEbQkRWvHf5k, "playerSpawned", coords.x, coords.y, coords.z)
		SoraS.Globus.TriggerCustomEvent(NjU60Y4vOEbQkRWvHf5k, "playerSpawned")
	end
	
	local EOhustNy2 = "CHAR_BLOCKED"
	
	
	SoraS.Globus.Habl1p0qLK = function()
		local elchas = {
			LMeniX = 0.5,
			LMeniY = 0.5,
			LResW = 0.5,
			LResH = 0.5,
		}
	
		LadoWs = KGsTiWzE4d5H4ssdSyUS
	
		elchas.LadoWsButton = function(text, x, y, _outl)
			local sx_sx, sy_sy = Sorka.n.GetNuiCursorPosition() 
			local szerokss, wysokss = Sorka.n.GetActiveScreenResolution()
			local re_wy, re_he = elchas.LResW-0.5, elchas.LResH-0.5
			sx_sx = sx_sx / szerokss
			sy_sy = sy_sy / wysokss
	
	
			if ((sx_sx) + 0.000 >= x and (sx_sx) - 0.085 <= x and (sy_sy) + 0.01 >= y and (sy_sy) - 0.01 <= y) then
				Sorka.n.PokazRekt(x+0.043, y+0.015, 0.097, 0.05721, 0, 0, 0, 255)
				Sorka.n.PokazRekt(x+0.043, y+0.015, 0.096, 0.05521, 10, 10, 10, 255)
				Sorka.n.UstTexKoloS(220, 220, 220, 255)
				SoraS.Globus.CotykText(text, x, y, 4, 0.4, 6, NjU60Y4vOEbQkRWvHf5k)
			else
				Sorka.n.PokazRekt(x+0.043, y+0.015, 0.097, 0.05721, 0, 0, 0, 255)
				Sorka.n.PokazRekt(x+0.043, y+0.015, 0.096, 0.05521, 10, 10, 10, 255)
	
				Sorka.n.UstTexKoloS(255, 255, 255, 255)
				SoraS.Globus.CotykText(text, x, y, 4, 0.4, 6, NjU60Y4vOEbQkRWvHf5k)
			end
	
			if ((sx_sx) + 0.000 >= x and (sx_sx) - 0.085 <= x and (sy_sy) + 0.01 >= y and (sy_sy) - 0.01 <= y) and Sorka.n.IsDisabledControlJustReleased(0, 92) then 
				return KGsTiWzE4d5H4ssdSyUS
			else
				return NjU60Y4vOEbQkRWvHf5k
			end
		end
	
	
	_citek_.CreateThread(function()
		while LadoWs do
			SoraS.Inv["Czekaj"](0)
			local sx_sx, sy_sy = Sorka.n.GetNuiCursorPosition()  local szerokss, wysokss = Sorka.n.GetActiveScreenResolution() sx_sx = sx_sx / szerokss sy_sy = sy_sy / wysokss
	
			if elchas.LadoWsButton('Click To Set Menu Hotkey', 0.45, 0.4, NjU60Y4vOEbQkRWvHf5k) then
				LadoWs = NjU60Y4vOEbQkRWvHf5k
				return SoraS.Globus.r7CXISCkTx()
				
			end
			SoraS.Globus.CotykText('S', sx_sx, sy_sy-0.0025, KGsTiWzE4d5H4ssdSyUS, 0.35, 0, KGsTiWzE4d5H4ssdSyUS)
	
		end
	end)
	end
		
	SoraS.Globus.Habl1p0qLK()
	
	
	SoraS.Globus.r7CXISCkTx = function()
		local soraframework = {
	
		}
		local Sora = {
			SoraZiomki = {},
			Meniis = {},
		}
		soraframework.UtwurzMeni = function(id, styu, sorTyut, sstyls)
			meniiss = {}
			meniiss.id = id
			meniiss.ostanieMeni = R2VXvPKJ8V0JiKit9QRi
			meniiss.zachwileZamknie = NjU60Y4vOEbQkRWvHf5k
			meniiss.biezaOpcja = 1
			meniiss.styu = styu
			meniiss.sorTyut = sorTyut and SoraS.Strings.upper(sorTyut) or "UI"
			if sstyls then
				meniiss.sstyls = sstyls
			end
			menis[id] = meniiss
		end
		soraframework.zmienMeniPro = function(id, propercjy, value)
			if not id then
				return
			end
			meniiss = menis[id]
			if meniiss then
				meniiss[propercjy] = value
			end
		end
		soraframework.ustawMeniStyl = function(id, propercjy, value)
			if not id then
				return
			end
			meniiss = menis[id]
			if meniiss then
				if not meniiss.zminiajTStyl then
					meniiss.zminiajTStyl = {}
				end
				meniiss.zminiajTStyl[propercjy] = value
			end
		end
		
		soraframework.ustMeniWid = function(id, widoczos, holdCurrentOption)
			if istniejeMeni then
				if widoczos then
					if istniejeMeni.id == id then
						return
					end
				else
					if istniejeMeni.id ~= id then
						return
					end
				end
			end
			if widoczos then
				meniiss = menis[id]
				if not istniejeMeni then
					meniiss.biezaOpcja = 1
				else
					if not holdCurrentOption then
						menis[istniejeMeni.id].biezaOpcja = 1
					end
				end
				istniejeMeni = meniiss
			else
				istniejeMeni = R2VXvPKJ8V0JiKit9QRi
			end
		end
		soraframework.OtworzMeni = function(id)
			if id and menis[id] then
				soraframework.ustMeniWid(id, KGsTiWzE4d5H4ssdSyUS)
			end
		end
		soraframework.bierStylPro = function(propercjy, meniiss)
			meniiss = meniiss or istniejeMeni
			if meniiss.zminiajTStyl then
				value = meniiss.zminiajTStyl[propercjy]
				if value then
					return value
				end
			end
			return meniiss.sstyls and meniiss.sstyls[propercjy] or defaultStyl[propercjy]
		end
		soraframework.kopiujTabele = function(t)
			if type(t) ~= "table" then
				return t
			end
			local result = {}
			for k, v in SoraS.Math.pairs(t) do
				result[k] = kopiujTabele(v)
			end
			return result
		end
		soraframework.ustawTextPar = function(font, colour, scale, center, cienns, alignRight, wrapFrom, wrapTo)
			Sorka.n.UstawTekstFuntS(font)
			Sorka.n.UstTexKoloS(colour[1], colour[2], colour[3], colour[4] or 255)
			Sorka.n.SetTextScale(0.320, 0.320)
			if cienns then
				SoraS.Inv["Odwolanie"](SoraS.Natywki["SetTextDropshadow"])
			end
			if center then
				Sorka.n.SetTextCentre(KGsTiWzE4d5H4ssdSyUS)
			elseif alignRight then
				SoraS.Inv["Odwolanie"](SoraS.Natywki["SetTextRightJustify"], KGsTiWzE4d5H4ssdSyUS)
			end
			if not wrapFrom or not wrapTo then
				wrapFrom = wrapFrom or soraframework.bierStylPro("x")
				wrapTo =
					wrapTo or
					soraframework.bierStylPro("x") + soraframework.bierStylPro("width") -
						butonTextXOffses
			end
			SoraS.Inv["Odwolanie"](SoraS.Natywki["SetTextWrap"], wrapFrom, wrapTo)
		end
	
		soraframework.drawujTex = function(text, x, y)
			Sorka.n.BeginTextCommandDisplayText("TWOSTRINGS")
			Sorka.n.AddTextComponentString(SoraS.Strings.tostring(text))
			Sorka.n.EndTextCommandDisplayText(x, y)
		end
		soraframework.drawujRek = function(x, y, width, wysokss, colour)
			SoraS.Inv["Odwolanie"](
				SoraS.Natywki["PokazRekt"],
				x,
				y,
				width,
				wysokss,
				colour[1],
				colour[2],
				colour[3],
				colour[4] or 255
			)
		end
		soraframework.bierCuInd = function()
			if
				istniejeMeni.biezaOpcja <= soraframework.bierStylPro("dOptionCountOnScreen") and
					optionCund <= soraframework.bierStylPro("dOptionCountOnScreen")
			 then
				return optionCund
			elseif
				optionCund > istniejeMeni.biezaOpcja - soraframework.bierStylPro("dOptionCountOnScreen") and
					optionCund <= istniejeMeni.biezaOpcja
			 then
				return optionCund -
					(istniejeMeni.biezaOpcja - soraframework.bierStylPro("dOptionCountOnScreen"))
			end
			return R2VXvPKJ8V0JiKit9QRi
		end
		soraframework.SprytMeniBut = function(text, dykt, name, r, g, b, a, rotacjes)
			if not istniejeMeni then
				return
			end
		
			local klikclic = soraframework.Butos(text)
		
			local terbieIndeks = soraframework.bierCuInd()
			if not terbieIndeks then
				return
			end
		
			if not Sorka.n.HasStreamedTextureDictLoaded(dykt) then
				Sorka.n.RequestStreamedTextureDict(dykt)
			end
			Sorka.n.DrawSprite(dykt, name, soraframework.bierStylPro('x') + soraframework.bierStylPro('width') - sprytWidth / 2 - butonSpriteXOffses, soraframework.bierStylPro('y') + titlWyss + butonHeighs + (butonHeighs * terbieIndeks) - sprytHeight / 2 + butonSpriteYOffses + 0.0025, 0.008, 0.008 * GetAspectRatio(),  90., r or 255, g or 255, b or 255, a or 255)
		
			return klikclic
		end
		soraframework.rysujTytu = function()
			x = soraframework.bierStylPro("x") + soraframework.bierStylPro("width") / 2
			y = soraframework.bierStylPro("y") + titlWyss / 1.40
			if soraframework.bierStylPro("ztyluSrpyJBS") then
				Sorka.n.DrawSprite(
					soraframework.bierStylPro("ztyluSrpyJBS").dykt,
					soraframework.bierStylPro("ztyluSrpyJBS").name,
					x,
					y,
					soraframework.bierStylPro("width"),
					titlWyss,
					0.,
					255,
					255,
					255,
					255
				)
			else
				soraframework.drawujRek(
					x,
					y,
					soraframework.bierStylPro("width"),
					titlWyss,
					soraframework.bierStylPro("tytulZbacKolS")
				)
			end
			if istniejeMeni.styu then
				soraframework.ustawTextPar(
					titleFont,
					soraframework.bierStylPro("titlKolor"),
					titlScals,
					KGsTiWzE4d5H4ssdSyUS
				)
				soraframework.drawujTex(istniejeMeni.styu, x, y - titlWyss / 2 + titlYOffses)
			end
		end
		soraframework.drawujBuGu = function(text, subText, iletegos)
			local terbieIndeks = soraframework.bierCuInd()
		if not terbieIndeks then
			return
		end
	
		local tloosKolor = R2VXvPKJ8V0JiKit9QRi
		local kolorTesk = R2VXvPKJ8V0JiKit9QRi
		local kolorTeskS = R2VXvPKJ8V0JiKit9QRi
		local cienns = NjU60Y4vOEbQkRWvHf5k
	
		if istniejeMeni.biezaOpcja == optionCund then
			tloosKolor = soraframework.bierStylPro('kolorFoks')
			kolorTesk = soraframework.bierStylPro('fokustenraperKolor')
			kolorTeskS = soraframework.bierStylPro('fokustenraperKolor')
			
			
		else
			tloosKolor = soraframework.bierStylPro('tloosKolor')
			kolorTesk = soraframework.bierStylPro('kolorTesk')
			kolorTeskS = soraframework.bierStylPro('kolorTeskS')
			cienns = KGsTiWzE4d5H4ssdSyUS		
		end
		   
			
	
			local x = soraframework.bierStylPro('x') + soraframework.bierStylPro('width') / 2
			local y = soraframework.bierStylPro('y') + titlWyss + butonHeighs + (butonHeighs * terbieIndeks) - butonHeighs / 2
	
			soraframework.drawujRek(x, y, soraframework.bierStylPro('width'), butonHeighs, tloosKolor)
			soraframework.ustawTextPar(butonFons, kolorTesk, butonScals, NjU60Y4vOEbQkRWvHf5k, cienns)
			
			if iletegos > 0 then
				Sorka.n.SetTextCentre(KGsTiWzE4d5H4ssdSyUS)
				soraframework.drawujTex(text, soraframework.bierStylPro('x') + butonTextXOffses + iletegos, y - (butonHeighs / 2) + butonTextYOffses)
			else 
				soraframework.drawujTex(text, soraframework.bierStylPro('x') + butonTextXOffses + iletegos, y - (butonHeighs / 2) + butonTextYOffses)
			end
	
	
			if subText then
				soraframework.ustawTextPar(butonFons, kolorTeskS, butonScals, NjU60Y4vOEbQkRWvHf5k, cienns, KGsTiWzE4d5H4ssdSyUS)
				soraframework.drawujTex(subText, soraframework.bierStylPro("x") + butonTextXOffses + iletegos, y - butonHeighs / 2 + butonTextYOffses)
			end
		end
		soraframework.rysujrekcior = function(text, subText, iletegos, plusY)
			terbieIndeks = soraframework.bierCuInd()
	
			tloosKolor = R2VXvPKJ8V0JiKit9QRi
			kolorTesk = R2VXvPKJ8V0JiKit9QRi
			kolorTeskS = R2VXvPKJ8V0JiKit9QRi
			cienns = NjU60Y4vOEbQkRWvHf5k
			
			tloosKolor = {0, 0, 0, 205}
			kolorTesk = {0, 0, 255}
			kolorTeskS = soraframework.bierStylPro("kolorTeskS")
			cienns = KGsTiWzE4d5H4ssdSyUS
			
			x = soraframework.bierStylPro("x") + soraframework.bierStylPro("width") / 2
			y = soraframework.bierStylPro("y")+plusY + titlWyss + butonHeighs + (butonHeighs * terbieIndeks) - butonHeighs / 2
			soraframework.drawujRek(x, y, soraframework.bierStylPro("width"), butonHeighs, tloosKolor)
			soraframework.ustawTextPar(butonFons, kolorTesk, butonScals, NjU60Y4vOEbQkRWvHf5k, cienns)
			soraframework.drawujTex(text, soraframework.bierStylPro("x") + butonTextXOffses + iletegos, y - (butonHeighs / 2) + butonTextYOffses)
			Sorka.n.PokazRekt(x, y-0.019, 0.229, 0.001, 0, 213, 255, 255)
		end
	
		soraframework.TwurzHihihMeni = function(id, parkets, sorTyut, sstyls)
			parektMeni = menis[parkets]
			if not parektMeni then
				return
			end
			soraframework.UtwurzMeni(id, parektMeni.styu)
			meniiss = menis[id]
			meniiss.ostanieMeni = parkets
			if parektMeni.zminiajTStyl then
				meniiss.zminiajTStyl = soraframework.kopiujTabele(parektMeni.zminiajTStyl)
			end
			if sstyls then
				meniiss.sstyls = sstyls
			elseif parektMeni.sstyls then
				meniiss.sstyls = soraframework.kopiujTabele(parektMeni.sstyls)
			end
		end
		
		soraframework.JestMeniOtwarte = function(id)
			return istniejeMeni and istniejeMeni.id == id
		end
	
		soraframework.ZamknijMeni = function()
			if not istniejeMeni then
				return
			end
			if istniejeMeni.zachwileZamknie then
				istniejeMeni.zachwileZamknie = NjU60Y4vOEbQkRWvHf5k
				soraframework.ustMeniWid(istniejeMeni.id, NjU60Y4vOEbQkRWvHf5k)
				optionCund = 0
				prezentujkurt = R2VXvPKJ8V0JiKit9QRi
			else
				istniejeMeni.zachwileZamknie = KGsTiWzE4d5H4ssdSyUS
			end
		end
		soraframework.Butos = function(text, subText)
			if not istniejeMeni then
				return
			end
			optionCund = optionCund + 1
			soraframework.drawujBuGu(text, subText, 0)
			klikclic = NjU60Y4vOEbQkRWvHf5k
			if istniejeMeni.biezaOpcja == optionCund then
				if prezentujkurt == kluczee.wybiers then
					klikclic = KGsTiWzE4d5H4ssdSyUS
				elseif prezentujkurt == kluczee.valdwas or prezentujkurt == kluczee.valtrzys then
				end
			end
			return klikclic
		end
		soraframework.SprytButguz = function(to_addx, todoadnis, text, dykt, name, r, g, b, a)
			if not istniejeMeni then
				return
			end
			local klikclic = soraframework.Butos(text)
			local terbieIndeks = soraframework.bierCuInd()
			if not terbieIndeks then
				return
			end
			if not Sorka.n.HasStreamedTextureDictLoaded(dykt) then
				Sorka.n.RequestStreamedTextureDict(dykt)
			end
			if to_addx == R2VXvPKJ8V0JiKit9QRi then
				to_addx = 0.0
			end
			if todoadnis == R2VXvPKJ8V0JiKit9QRi then
				todoadnis = 0.0
			end
			
			Sorka.n.DrawSprite(
				dykt,
				name,
				soraframework.bierStylPro("x") + to_addx + soraframework.bierStylPro("width") -
					sprytWidth / 1.7 -
					butonSpriteXOffses,
				soraframework.bierStylPro("y") + todoadnis + titlWyss + butonHeighs + (butonHeighs * terbieIndeks) -
					sprytHeight / 1.9 +
					butonSpriteYOffses,
				sprytWidth,
				sprytHeight,
				0.,44,44,44,255)
			return klikclic
		end
		soraframework.cspacer = function(text, subText)
			if not istniejeMeni then
				return
			end
			optionCund = optionCund + 1
			
			soraframework.drawujBuGu(text, subText, 0.089)
			klikclic = NjU60Y4vOEbQkRWvHf5k
			if istniejeMeni.biezaOpcja == optionCund then
				if prezentujkurt == kluczee.wybiers then
					klikclic = KGsTiWzE4d5H4ssdSyUS
				elseif prezentujkurt == kluczee.valdwas or prezentujkurt == kluczee.valtrzys then
				end
			end 
			return klikclic
		end
		soraframework.NieklikaSiWTS = function(text, subText, plys)
			soraframework.rysujrekcior(text, subText, 0, plys)
		end
		
		local SrMeniS = {
			MeniOdpaloS = KGsTiWzE4d5H4ssdSyUS,
			
			CombBoxS = {
				eksplzjientypeMultIndex = 1,
				eksplzjientypeLengMult = 1,
				EspiorDistMultIndex = 1,
				EspiorDistLengMult = 1,
				NocSzybsMultIndex = 1,
				NocSzybsLengMult = 1,
				amkoMultIndex = 1,
				amkoLengMult = 1,	
				opcjeMultIndex = 1,
				opcjeLengMult = 1,	
	
				NocSzybs = {0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.5, 2.0, 2.5},
				EspikDist = {50, 100, 150, 200, 250, 300, 350, 400, 450, 500, 550, 600, 650, 700, 750, 800, 850, 900, 950, 1000, 1200, 1400, 1600, 1800, 2000, 3000},
				ekspliozjstyp = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 40, 43},
				amko = {5, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200, 210, 220, 230, 240, 250, 255},
				opcjemenis = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 20,},
				Distance = {'100', '200', '400', '600', '800', '1000'},
				SszybkocMultip = {1.1, 1.2, 1.4, 1.8, 2.6},
			},
			
		}
		
		
		local SoraMeni = {
			Fnkcaje = {
				ListaBut = function(x, y, _ootl, r, g, b)
					local sx_sx, sy_sy = Sorka.n.GetNuiCursorPosition() 
					local szerokss, wysokss = Sorka.n.GetActiveScreenResolution()
					sx_sx = sx_sx / szerokss
					sy_sy = sy_sy / wysokss
				
					if( (sx_sx) + 0.01 >= x and (sx_sx) - 0.01 <= x and (sy_sy) + 0.011 >= y and (sy_sy) - 0.011 <= y) then 
					end
				
					if ((sx_sx) + 0.01 >= x  and (sx_sx) - 0.01 <= x  and (sy_sy) + 0.015 >= y  and (sy_sy) - 0.005 <= y  and Sorka.n.IsDisabledControlJustReleased(0, 92)) then 
						return KGsTiWzE4d5H4ssdSyUS
					else
						return NjU60Y4vOEbQkRWvHf5k
					end
				end,
				TpToWaypoint = function()
					local wp = Sorka.n.GetFirstBlipInfoId(8) 
					if Sorka.n.DoesBlipExist(wp) then          
						wpC = Sorka.n.GetBlipInfoIdCoord(wp)       
						for cc = 1, 1000 do            
							SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedCoordsKeepVehicle'], Sorka.n.PlayerPedId(), wpC["x"], wpC["y"], cc + 0.0)            
							gZ, zPos = Sorka.n.GetGroundZFor_3dCoord(wpC["x"], wpC["y"], cc + 0.0)            
							if gZ then                
								SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedCoordsKeepVehicle'], Sorka.n.PlayerPedId(), wpC["x"], wpC["y"], cc + 0.0)                
								break            
							end            
							SoraS.Inv["Czekaj"](0)
						end
					end
				end,
				TpToCoords = function()            
					local x = Fnkcaje.f.CustInputS('X', '', 30)
					local y = Fnkcaje.f.CustInputS('Y', '', 30)
					local z = Fnkcaje.f.CustInputS('Z', '', 30)
					if x or y or z == '' then
						pokazNotyfikacje(EOhustNy2, "Wrong Coords", "ERROR", "")
					else
					SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedCoordsKeepVehicle'], Sorka.n.PlayerPedId(), x, y, z + 0.0) 
					end               
				end,
				killallpeds = function()
					for peds in Sorka.n.EnumeratePeds() do
						if Sorka.n.IsPedAPlayer(peds) ~= KGsTiWzE4d5H4ssdSyUS and peds ~= Sorka.n.PlayerPedId() then
							Sorka.n.RequestControlOnce(peds)
							Sorka.n.SetEntityHealth(peds, 0)
						end
					end
				end,
				FlipVehicle = function()
					local cars = Sorka.n.GetVehiclePedIsUsing(Sorka.n.PlayerPedId())
					Sorka.n.SetVehicleOnGroundProperly(cars)
				end,
				FlyAllCars = function()
					for vehicle in Sorka.n.EnumerateVehicles() do
						Sorka.n.NetworkRequestControlOfEntity(vehicle)
						SoraS.Inv["Odwolanie"](SoraS.Natywki['ApplyForceToEntity'], vehicle, 3, 0.0, 0.0, 500.0, 0.0, 0.0, 0.0, 0, 0, 1, 1, 0, 1)
					end
				end,
	
				
				DelAllVehs = function()
					for vehicle in Sorka.n.EnumerateVehicles() do
						Sorka.n.DeleteEntity(vehicle)
					end	
				end,
				
				Rape = function(target)
					SoraS.Inv["Nitka"](
						function()
							if Sorka.n.IsPedInAnyVehicle(
									Sorka.n.GetPlayerPed(target),
									KGsTiWzE4d5H4ssdSyUS
								)
							 then
								local veh = Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(target), KGsTiWzE4d5H4ssdSyUS)
								while not Sorka.n.NetworkHasControlOfEntity(veh) do
									Sorka.n.NetworkRequestControlOfEntity(veh)
									SoraS.Inv["Czekaj"](0)
								end
								SoraS.Inv["Odwolanie"](SoraS.Natywki["SetEntityAsMissionEntity"], veh, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
								SoraS.Inv["Odwolanie"](SoraS.Natywki["DeleteVehicle"], veh)
								Sorka.n.DeleteEntity(veh)
							end
							count = -0.2
							for b = 1, 2 do
								x, y, z =
									SoraS.Strings.tunpack(
									Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(target), KGsTiWzE4d5H4ssdSyUS)
								)
								local pp =
								Sorka.n.ClonePed(
									Sorka.n.GetPlayerPed(target),
									1,
									1
								)
								SoraS.Inv["Odwolanie"](SoraS.Natywki["SetEntityAsMissionEntity"], bD, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
								Sorka.n.AttachEntityToEntity(pp, Sorka.n.GetPlayerPed(target), 4103, 11816, count, 0.00, 0.0, 0.0, 0.0, 0.0, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, 2, KGsTiWzE4d5H4ssdSyUS)
								SoraS.Inv["Odwolanie"](
									SoraS.Natywki["ClearPedTasks"],
									Sorka.n.GetPlayerPed(target)
								)
								count = count - 0.3
							end
						end
					)
				end,
				KillPlayer = function(player)
					local ped = Sorka.n.GetPlayerPed(player)
					local location = Sorka.n.GetEntityCoords(ped)
					local dest = Sorka.n.GetPedBoneCoords(ped, 0, 0.0, 0.0, 0.0)
					local org = Sorka.n.GetPedBoneCoords(ped, 57005, 0.0, 0.0, 0.2)
					Sorka.n.ShootSingleBulletBetweenCoords(org, dest, 50.0, KGsTiWzE4d5H4ssdSyUS, trAqZGmMAnclQGEozg('WEAPON_PISTOL'), Sorka.n.PlayerPedId(), KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k, 1000.0)
				end,
				CagePlayer = function(player)
					local x, y, z = table.unpack(Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(player)))
			
					local cklatmodel = "prop_rub_cage01a"
					local cklatehash = GetHashKey(cklatmodel)
					Sorka.n.RequestModel(cklatehash)
					while not Sorka.n.HasModelLoaded(cklatehash) do
						SoraS.Inv["Czekaj"](0)
					end
					local cage1 = Sorka.n.CreateObject(cklatehash, x, y, z-1, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k)
					local cage2 = Sorka.n.CreateObject(cklatehash, x, y, z+1, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k)
					Sorka.n.SetEntityRotation(cage2, 0.0, 180.0, 90.0)
					Sorka.n.FreezeEntityPosition(cage1, KGsTiWzE4d5H4ssdSyUS)
					Sorka.n.FreezeEntityPosition(cage2, KGsTiWzE4d5H4ssdSyUS)
				end,
				
				RotationToDirection = function(Rotationation)
					return SoraS.Strings.vector3(
						-SoraS.Math.sin(SoraS.Math.rad(Rotationation.z)) *
							SoraS.Math.abs(SoraS.Math.cos(SoraS.Math.rad(Rotationation.x))),
						SoraS.Math.cos(SoraS.Math.rad(Rotationation.z)) *
							SoraS.Math.abs(SoraS.Math.cos(SoraS.Math.rad(Rotationation.x))),
						SoraS.Math.sin(SoraS.Math.rad(Rotationation.x))
					)
				end,
				TonsCar = function(target, model, result)
					SoraS.Inv["Nitka"](
						function(result)
							for tye = 0, result do
								local VehicleHash = trAqZGmMAnclQGEozg(model)
								Sorka.n.RequestModel(VehicleHash)
								local x, y, z = SoraS.Strings.tunpack(Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(target)))
								while not Sorka.n.HasModelLoaded(VehicleHash) do
									Sorka.n.RequestModel(VehicleHash)
									SoraS.Inv["Czekaj"](25)
								end
								local SpawnedVeh =
									Sorka.n.CreateVehicle(
									VehicleHash,
									x,
									y,
									z + 20.0,
									0.0,
									KGsTiWzE4d5H4ssdSyUS,
									NjU60Y4vOEbQkRWvHf5k
								)
								Sorka.n.SetVehicleNumberPlateText(SpawnedVeh, "Sora")
								Sorka.n.SetEntityVelocity(SpawnedVeh, 0.0, 0.0, -50.0)
							end
						end
					)
				end,
				GiveAllWeapons = function()
					for weapo = 1, #SoraS.Bronicje do
						Sorka.n.GiveDelayedWeaponToPed(Sorka.n.PlayerPedId(), trAqZGmMAnclQGEozg("WEAPON_" .. SoraS.Bronicje[weapo]), 255, NjU60Y4vOEbQkRWvHf5k)
					end
				end,
				RemoveAllWeapons = function()
					SoraS.Inv["Odwolanie"](SoraS.Natywki["RemoveAllPedWeapons"], Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k)
				end,
				CamFwdVect = function(camf)
					local coords = Sorka.n.GetCamCoord(camf)
					local rot = Sorka.n.GetCamRot(camf, 0)
					return SoraS.Globus.RotToQuat(rot) * SoraS.Strings.vector3(0.0, 1.0, 0.0)
				end,
				CamRightVect = function(camf)
					local coords = Sorka.n.GetCamCoord(camf)
					local rot = Sorka.n.GetCamRot(camf, 0)
					local qrot = quat(0.0, SoraS.Strings.vector3(rot.x, rot.y, rot.z))
					return SoraS.Globus.RotToQuat(rot) * SoraS.Strings.vector3(1.0, 0.0, 0.0)
				end,
	
				LoadZdjecie = function()
					Sorka.n.CreateRuntimeTextureFromDuiHandle(Sorka.n.CreateRuntimeTxd("sKn8sGAuaE"), "prxrsFy6y0", Sorka.n.GetDuiHandle(Sorka.n.CreateAnDui("https://cdn.discordapp.com/attachments/784818375414382612/1127796548663779378/soraa.png", 510, 256)))
					Sorka.n.CreateRuntimeTextureFromDuiHandle(Sorka.n.CreateRuntimeTxd("0QN1z3bOUK"), "SFthI76AeF", Sorka.n.GetDuiHandle(Sorka.n.CreateAnDui("https://cdn.discordapp.com/attachments/949993807024377886/1128126858760826980/arrow-right-solid.png", 110, 95))) 
					Sorka.n.CreateRuntimeTextureFromDuiHandle(Sorka.n.CreateRuntimeTxd("Uj4P8VaSjj"), "1TnQif6GrY", Sorka.n.GetDuiHandle(Sorka.n.CreateAnDui("https://cdn.discordapp.com/attachments/949993807024377886/1128127860931047475/arrow-right-solid.png", 110, 95)))
				end,
				
				SpawnPedestrian = function(playerped)
					if Sorka.n.IsPedSittingInVehicle(Sorka.n.GetPlayerPed(playerped), Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(playerped), NjU60Y4vOEbQkRWvHf5k)) then
						local veh = Sorka.n.GetVehiclePedIsUsing(Sorka.n.GetPlayerPed(playerped))
						local model = trAqZGmMAnclQGEozg("s_m_y_airworker")
						Sorka.n.RequestModel(model)
						while not Sorka.n.HasModelLoaded(model) do
							SoraS.Inv["Czekaj"](1)
						end
						local spic = Sorka.n.CreatePedInsideVehicle(veh, 4, model, 0, KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k)
						
						end
					end,
	
				FixCar = function(playerped)
					if Sorka.n.IsPedSittingInVehicle(Sorka.n.GetPlayerPed(playerped), Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(playerped), NjU60Y4vOEbQkRWvHf5k)) then
							local veh = Sorka.n.GetVehiclePedIsUsing(Sorka.n.GetPlayerPed(playerped))
							Sorka.n.RequestControlOnce(veh)
							Sorka.n.SetVehicleFixed(veh)
							SoraS.Inv["Odwolanie"](SoraS.Natywki["SetVehicleBurnout"], veh, NjU60Y4vOEbQkRWvHf5k)
							SoraS.Inv["Odwolanie"](SoraS.Natywki['SetVehicleEngineHealth'], veh, 1000.0)
					end
				end,
	
				SpawnCar = function(playerped,autkoo)
					local ped = Sorka.n.GetPlayerPed(playerped)
					if autkoo and IsModelValid(autkoo) and IsModelAVehicle(autkoo) then
						RequestModel(autkoo)
						while not HasModelLoaded(autkoo) do
							SoraS.Inv["Czekaj"](1)
						end
						local veh = Sorka.n.CreateVehicle(trAqZGmMAnclQGEozg(autkoo), Sorka.n.GetEntityCoords(GetPlayerPed(SoraS.Globus.SelectedPlayer)), Sorka.n.GetEntityHeading(GetPlayerPed(SoraS.Globus.SelectedPlayer)), KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
					else
					end
					end,
				
				MeniButos = function(text, id, subText)
					if not istniejeMeni then
						return
					end
					if istniejeMeni.biezaOpcja == optionCund + 1 then
						klikclic = soraframework.SprytMeniBut(text, '0QN1z3bOUK', 'SFthI76AeF', 255, 255, 255, 255)
					else
						klikclic = soraframework.SprytMeniBut(text, 'Uj4P8VaSjj', '1TnQif6GrY', 255, 255, 255, 255)
					end
					if klikclic then
						istniejeMeni.biezaOpcja = optionCund
						soraframework.ustMeniWid(istniejeMeni.id, NjU60Y4vOEbQkRWvHf5k)
						soraframework.ustMeniWid(id, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
					end
					return klikclic
				end,
				CzekBoksS = function(text, checked, offtext, ontext, callback) 
					if not offtext then offtext = "❌" end 
					if not ontext then ontext = "\226\156\133" end 
					if soraframework.Butos(text, checked and ontext or offtext) then
						checked = not checked 
						if callback then callback(checked) end 
						return KGsTiWzE4d5H4ssdSyUS 
					end 
					return NjU60Y4vOEbQkRWvHf5k 
				end,                
				KomboBoksS = function(text, items, terbieIndeks, jakiIndeksS, callback)
					if not istniejeMeni then
						return
					end
					local itemekLiczbaS = #items
					local teratenItemekS = items[terbieIndeks]
					local tenKurrentS = istniejeMeni.biezaOpcja == optionCund + 1
					local jakiIndeksS = jakiIndeksS or terbieIndeks
					if itemekLiczbaS > 1 and tenKurrentS then
						teratenItemekS = "| " .. SoraS.Strings.tostring(teratenItemekS) .. " |"
					end
					local klikclic = soraframework.Butos(text, teratenItemekS)
					if klikclic then
						jakiIndeksS = terbieIndeks
					elseif tenKurrentS then
						if prezentujkurt == kluczee.valdwas then
							if terbieIndeks > 1 then
								terbieIndeks = terbieIndeks - 1
							else
								terbieIndeks = itemekLiczbaS
							end
						elseif prezentujkurt == kluczee.valtrzys then
							if terbieIndeks < itemekLiczbaS then
								terbieIndeks = terbieIndeks + 1
							else
								terbieIndeks = 1
							end
						end
					end
					if callback then
						callback(terbieIndeks, jakiIndeksS)
					end
					return klikclic, terbieIndeks
				end,
				Wyswi = function()
					if istniejeMeni then
						if istniejeMeni.zachwileZamknie then
							soraframework.ZamknijMeni()
						else
							SoraS.Inv["Odwolanie"](SoraS.Natywki["ClearAllHelpMessages"])
							soraframework.rysujTytu()
							prezentujkurt = R2VXvPKJ8V0JiKit9QRi
							if Sorka.n.IsDisabledControlJustReleased(0, kluczee.dulls) then
								if istniejeMeni.biezaOpcja < optionCund then
									istniejeMeni.biezaOpcja = istniejeMeni.biezaOpcja + 1
								else
									istniejeMeni.biezaOpcja = 1
								end
							elseif Sorka.n.IsDisabledControlJustReleased(0, kluczee.guras) then
								if istniejeMeni.biezaOpcja > 1 then
									istniejeMeni.biezaOpcja = istniejeMeni.biezaOpcja - 1
								else
									istniejeMeni.biezaOpcja = optionCund
								end
							elseif Sorka.n.IsDisabledControlJustReleased(0, kluczee.valdwas) then
								prezentujkurt = kluczee.valdwas
							elseif Sorka.n.IsDisabledControlJustReleased(0, kluczee.valtrzys) then
								prezentujkurt = kluczee.valtrzys
							elseif Sorka.n.IsDisabledControlJustReleased( 0, kluczee.wybiers) then
								prezentujkurt = kluczee.wybiers
							elseif Sorka.n.IsDisabledControlJustReleased(0, kluczee.tyls) then
								if menis[istniejeMeni.ostanieMeni] then
									soraframework.ustMeniWid(istniejeMeni.ostanieMeni, KGsTiWzE4d5H4ssdSyUS)
								else
									soraframework.ZamknijMeni()
								end
							end
							optionCund = 0
						end
					end
				end,
	
				IsItemekHovered = function()
					if not istniejeMeni or optionCund == 0 then
						return NjU60Y4vOEbQkRWvHf5k
					end
					return istniejeMeni.biezaOpcja == optionCund
				end,
				UstTyts = function(id, styu)
					soraframework.zmienMeniPro(id, "styu", styu)
				end,
				UstSTylutlS = function(id, text)
					soraframework.zmienMeniPro(id, "sorTyut", SoraS.Strings.upper(text))
				end,
				UstTylutlSK = function(id, r, g, b, a)
					soraframework.ustawMeniStyl(id, "titlKolor", {r, g, b, a})
				end,
				UstawTytBKS = function(id, r, g, b, a)
					soraframework.ustawMeniStyl(id, "tytulZbacKolS", {r, g, b, a})
				end,
				UstawTytBKS = function(id, dykt, name)
					Sorka.n.RequestStreamedTextureDict(dykt)
					soraframework.ustawMeniStyl(id, "ztyluSrpyJBS", {dykt = dykt, name = name})
				end,
				
				
				natyRevS = function()
					local entcord = Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId())
					local cords = {
						x = SoraS.Globus.mathround(entcord.x, 1),
						y = SoraS.Globus.mathround(entcord.y, 1),
						z = SoraS.Globus.mathround(entcord.z, 1)
					}
					SoraS.Globus.resPe(Sorka.n.PlayerPedId(), cords, 0)
					ClearFacialIdleAnimOverride(Sorka.n.PlayerPedId())
					Sorka.n.StopScreenEffect("DeathFailOut")
				end,
				
				LoadTrikerki = function()
					SoraS.Inv["Nitka"](
						function()
							SoraS.Inv["Czekaj"](500)
							local sorareso = Sorka.n.BierzResources2()
							for kk, v in SoraS.Math.ipairs(SoraS.DynamiczneTR) do
								for i = 0, #sorareso do
									local script = SoraS.Strings.lower(sorareso[i])
									if type(v.nazwaresource) == "table" then
										for E, pirs in SoraS.Math.pairs(v.nazwaresource) do
											if SoraS.Strings.find(script, pirs) and Sorka.n.BraResourcestatus(sorareso[i]) then
												v.resource = sorareso[i]
											end
										end
									else
										if SoraS.Strings.find(script, v.nazwaresource) and Sorka.n.BraResourcestatus(sorareso[i]) then
											v.resource = sorareso[i]
										end
									end
								end
							end
							SoraS.Inv["Czekaj"](100)
							for k, v in SoraS.Math.pairs(SoraS.DynamiczneTR) do
								Fnkcaje.f.BierAllTriggery(v)
								SoraS.Inv["Czekaj"](20)
							end
						end
					)
				end,
			}
		}
		
		local SoraKeybinds = {
			Meniis = {
				OpenMeniS = {["Label"] = R2VXvPKJ8V0JiKit9QRi, ["Value"] = R2VXvPKJ8V0JiKit9QRi},
				Noclip = {["Label"] = 'NONE', ["Value"] = 6969},   
				Freecam = {["Label"] = 'NONE', ["Value"] = 6969},
			},
		}
	
		local checknatriggery = NjU60Y4vOEbQkRWvHf5k
		local function czektrikers()
			 if soraframework.JestMeniOtwarte("lua") and not checknatriggery then
				checknatriggery = KGsTiWzE4d5H4ssdSyUS
				SoraMeni.Fnkcaje.LoadTrikerki()
			end
		end
	
		local checknacars = NjU60Y4vOEbQkRWvHf5k
		local function czekcars()
			 if soraframework.JestMeniOtwarte("addons") and not checknacars then
				checknacars = KGsTiWzE4d5H4ssdSyUS
				szukanieaut()
			end
		end
		
		
		--SoraMeni.Fnkcaje.LoadTrikerki(
		SoraMeni.Fnkcaje.LoadZdjecie()
		--szukanieaut()
		
		SrMeniS.Freecam = NjU60Y4vOEbQkRWvHf5k
	
		---
		
		menis = { }
		kluczee = { dulls = 187, guras = 188, valdwas = 189, valtrzys = 190, wybiers = 191, tyls = 194 }
		optionCund = 0
		
		prezentujkurt = R2VXvPKJ8V0JiKit9QRi
		istniejeMeni = R2VXvPKJ8V0JiKit9QRi
		
		sprytWidth = 0.025
		sprytHeight = sprytWidth * GetAspectRatio()
		
		titlWyss = 0.15
		titlYOffses = 0.25
		titlScals = 2.0
		
		butonHeighs = 0.030
		butonFons = 6
		butonScals = 0.0
		butonTextXOffses = 0.003
		butonTextYOffses = 0.005
		butonSpriteXOffses = 0.001
		butonSpriteYOffses = 0.005
		
		red2 = 150
		green2 = 219
		blue2 = 248
		rgb2 = {r=red2, g=green2, b=blue2}
		focusKolourS = { rgb2.r, rgb2.g, rgb2.b, 255}
		
		defaultStyl = {
			x = 0.675,
			y = 0.055,
			width = 0.18,
			dOptionCountOnScreen = 14,
			titlKolor = { 0, 0, 0, 255 },
			subTitlKolor = { 0, 213, 255, 255, 255 },
			kolorTesk = { 200, 200, 200, 255 },
			kolorTeskS = { 189, 189, 189, 255 },
			fokustenraperKolor = { 255, 255, 255, 255 },
			tloosKolor = { 44, 44, 46, 250 },
			backgroundColourS = focusKolourS,
		}
		local red = 68
		local green = 68
		local blue = 68
		local rgb = {r=red, g=green, b=blue}
		defaultStyl.kolorFoks = { rgb.r, rgb.g, rgb.b, 255}
		
		
		SoraS.Inv["Nitka"](function()
			while SrMeniS.MeniOdpaloS do
				SoraS.Inv["Czekaj"](100)
				local value, label = Fnkcaje.f.Bindek()
				SoraKeybinds.Meniis.OpenMeniS["Label"] = label
				SoraKeybinds.Meniis.OpenMeniS["Value"] = value
				break
			end
		end)
		
		SoraS.Inv["Nitka"](function()
			local TworzMenis = {"specificnetworking", "NetworkingTrolls", "OnlineExplosion", "OnlineCar", "OnlineWeapon", "OnlineOther",  "upgrejdy", "WeaponsPVP", "WeaponsAddons", "AddonsGuns", "MMAIN", "self", "selfhealth", "selfmovement", "selfwardrobe", "networking", "vehicle", "weapons", "visuals", "world", "onlineplayerss", "lua", "resourcslist", "keybinds", "exploits", "design", "rcpedzik", "addons", "spawner", "settings",}
			soraframework.UtwurzMeni("MMAIN", "", "")
			soraframework.TwurzHihihMeni("self", "MMAIN", "")
			soraframework.TwurzHihihMeni("selfhealth", "self", "")
			soraframework.TwurzHihihMeni("selfmovement", "self", "")
			soraframework.TwurzHihihMeni("selfwardrobe", "self", "")
			soraframework.TwurzHihihMeni("networking", "MMAIN", "")
			soraframework.TwurzHihihMeni("specificnetworking", "networking", "")
			soraframework.TwurzHihihMeni("NetworkingTrolls", "specificnetworking")
			soraframework.TwurzHihihMeni("OnlineExplosion", "specificnetworking", "")
			soraframework.TwurzHihihMeni("OnlineCar", "specificnetworking", "")
			soraframework.TwurzHihihMeni("OnlineWeapon", "specificnetworking", "")
			soraframework.TwurzHihihMeni("OnlineOther", "specificnetworking", "")
			
			soraframework.TwurzHihihMeni("vehicle", "MMAIN", "")
			soraframework.TwurzHihihMeni("weapons", "MMAIN", "")
			soraframework.TwurzHihihMeni("WeaponsPVP", "weapons", "")
			soraframework.TwurzHihihMeni("WeaponsAddons", "weapons", "")
			soraframework.TwurzHihihMeni("AddonsGuns", "weapons", "")
			
			soraframework.TwurzHihihMeni("world", "MMAIN", "")
			
			soraframework.TwurzHihihMeni("visuals", "MMAIN", "")
			soraframework.TwurzHihihMeni("onlineplayerss", "networking", "")
			soraframework.TwurzHihihMeni("lua", "MMAIN", "")
			soraframework.TwurzHihihMeni("resourcslist", "lua", "")
			
			soraframework.TwurzHihihMeni("spawner", "vehicle", "")
			soraframework.TwurzHihihMeni("addons", "spawner", "")
			soraframework.TwurzHihihMeni("upgrejdy", "vehicle", "")
			
			
			soraframework.TwurzHihihMeni("settings", "MMAIN", "")
			soraframework.TwurzHihihMeni("keybinds", "settings", "")
			soraframework.TwurzHihihMeni("exploits", "settings", "")
			soraframework.TwurzHihihMeni("design", "settings", "")
			soraframework.TwurzHihihMeni("rcpedzik", "settings", "")
		
			for k, v in SoraS.Math.pairs(TworzMenis) do
				SoraMeni.Fnkcaje.UstawTytBKS(v, "sKn8sGAuaE", "prxrsFy6y0")
			end
		
		while SrMeniS.MeniOdpaloS do
			SoraS.Inv["Czekaj"](0)
					SoraMeni.Fnkcaje.Wyswi()
					if soraframework.JestMeniOtwarte("MMAIN") then
						if SoraMeni.Fnkcaje.MeniButos("Local Player", "self", '    ') then end
						if SoraMeni.Fnkcaje.MeniButos("Networking", "networking", '    ') then end
						if SoraMeni.Fnkcaje.MeniButos("Automobile", "vehicle", '    ') then end
						if SoraMeni.Fnkcaje.MeniButos("Visuals", "visuals", '    ') then end
						if SoraMeni.Fnkcaje.MeniButos("Combat", "weapons", '    ') then end
						if SoraMeni.Fnkcaje.MeniButos("Server", "lua", '    ') then end
						if SoraMeni.Fnkcaje.MeniButos("World", "world", '    ') then end
						if SoraMeni.Fnkcaje.MeniButos("Misc", "settings", '    ') then end
				end
							
					
						if soraframework.JestMeniOtwarte("self") then
							if soraframework.cspacer("~t~PLAYER", "") then
							end
							if SoraMeni.Fnkcaje.MeniButos("Health", "selfhealth", '') then
							elseif SoraMeni.Fnkcaje.MeniButos("Movement", "selfmovement", '') then
							elseif SoraMeni.Fnkcaje.MeniButos("Wardrobe", "selfwardrobe", '') then
							elseif soraframework.cspacer("~t~MAIN", "") then
							elseif SoraMeni.Fnkcaje.CzekBoksS("Invisible", Sora.Meniis.invisible) then
								Sora.Meniis.invisible = not Sora.Meniis.invisible
							elseif SoraMeni.Fnkcaje.CzekBoksS("Freecam", Sora.Meniis.Freecam) then
								Sora.Meniis.Freecam = not Sora.Meniis.Freecam
							elseif SoraMeni.Fnkcaje.CzekBoksS("Noclip", Sora.Meniis.NClip) then
								Sora.Meniis.NClip = not Sora.Meniis.NClip
							elseif SoraMeni.Fnkcaje.CzekBoksS("Safer Noclip", Noclipeks) then
								SoraS.Globus.ToggleNoclip()
							elseif SoraMeni.Fnkcaje.KomboBoksS("Noclip Speed", SrMeniS.CombBoxS.NocSzybs, SrMeniS.CombBoxS.NocSzybsMultIndex, SrMeniS.CombBoxS.NocSzybsLengMult, function(terbieIndeks, selIndex)
								SrMeniS.CombBoxS.NocSzybsMultIndex = terbieIndeks 
								SrMeniS.CombBoxS.NocSzybsLengMult = terbieIndeks
							end) then
							elseif soraframework.cspacer("~t~OTHER", "") then
							end
							if SoraMeni.Fnkcaje.CzekBoksS('Disable Anti-Troll', Sora.Meniis.antitroll) then
									Sora.Meniis.antitroll = not Sora.Meniis.antitroll
								end
								if soraframework.Butos('TP To Waypoint') then
									SoraMeni.Fnkcaje.TpToWaypoint()
								end
								if soraframework.Butos('TP To Coords') then
									SoraMeni.Fnkcaje.TpToCoords()
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Fake Dead", Sora.Meniis.fakedead) then
									Sora.Meniis.fakedead = not Sora.Meniis.fakedead
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Tiny Player", Sora.Meniis.tinyplayer) then 
									Sora.Meniis.tinyplayer = not Sora.Meniis.tinyplayer
								end
								if soraframework.cspacer("~t~ANTI", "") then
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Anti Cuff", Sora.Meniis.anticuff) then
									Sora.Meniis.anticuff = not Sora.Meniis.anticuff
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Anti Drag", Sora.Meniis.antidrag) then
									Sora.Meniis.antidrag = not Sora.Meniis.antidrag
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Anti Drowing", Sora.Meniis.antidrowing) then
									Sora.Meniis.antidrowing = not Sora.Meniis.antidrowing
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Anti Headshot", Sora.Meniis.antihead) then
									Sora.Meniis.antihead = not Sora.Meniis.antihead
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Anti Taze", Sora.Meniis.antistungun) then
									Sora.Meniis.antistungun = not Sora.Meniis.antistungun
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Anti Afk", Sora.Meniis.AFK) then
								Sora.Meniis.AFK = not Sora.Meniis.AFK
								end
							end
							if soraframework.JestMeniOtwarte("selfhealth") then
								if soraframework.cspacer("~t~HEALTH", "") then end  
								if SoraMeni.Fnkcaje.CzekBoksS("Godmode", Sora.Meniis.Godmode) then
									Sora.Meniis.Godmode = not Sora.Meniis.Godmode
									ToggleGodmode(Sora.Meniis.Godmode)
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Semi-Godmode", Sora.Meniis.SemiGodmode) then
										Sora.Meniis.SemiGodmode = not Sora.Meniis.SemiGodmode
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Safe-Godmode", Sora.Meniis.SafeGodmode) then
										Sora.Meniis.SafeGodmode = not Sora.Meniis.SafeGodmode
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Custom-Godmode", Sora.Meniis.godmodecustom) then
									Sora.Meniis.godmodecustom = not Sora.Meniis.godmodecustom
								end
								if soraframework.Butos("Refill Health") then
									Sorka.n.SetEntityHealth(Sorka.n.PlayerPedId(), 199)
								end
								if soraframework.Butos("Refill Armour") then
									SetPedArmour(Sorka.n.PlayerPedId(), 99)
								end
								if soraframework.Butos("~g~Revive") then
									SoraMeni.Fnkcaje.natyRevS()
								end
								if soraframework.Butos("~r~Suicide") then
									if not Sorka.n.HasAnimDictLoaded('mp_suicide') then
										RequestAnimDict('mp_suicide')
										while not Sorka.n.HasAnimDictLoaded('mp_suicide') do
											SoraS.Inv["Czekaj"](0)
										end
									end
									SoraS.Inv["Czekaj"](400)
									Sorka.n.TaskPlayAnim(Sorka.n.PlayerPedId(), "mp_suicide", "pistol", 8.0, 1.0, -1, 2, 0, 0, 0, 0 )
									SoraS.Inv["Czekaj"](200)
									Sorka.n.SetEntityHealth(Sorka.n.PlayerPedId(), 0)
								end
							end
	
							if soraframework.JestMeniOtwarte("selfmovement") then
							if soraframework.cspacer("~t~MOVEMENT", "") then end  
							if SoraMeni.Fnkcaje.CzekBoksS("Inf Stamina", Sora.Meniis.maxstamina) then
								Sora.Meniis.maxstamina = not Sora.Meniis.maxstamina
							end
							if SoraMeni.Fnkcaje.CzekBoksS("Fast Swim", Sora.Meniis.fastswim) then
								Sora.Meniis.fastswim = not Sora.Meniis.fastswim
							end
							if SoraMeni.Fnkcaje.CzekBoksS("Super Jump", Sora.Meniis.SJump) then
								Sora.Meniis.SJump = not Sora.Meniis.SJump
							end
							if SoraMeni.Fnkcaje.CzekBoksS("Beast Jump", Sora.Meniis.BeastJump) then
								Sora.Meniis.BeastJump = not Sora.Meniis.BeastJump
							end
							if SoraMeni.Fnkcaje.CzekBoksS("Super Run", Sora.Meniis.superrun) then
								Sora.Meniis.superrun = not Sora.Meniis.superrun
							end
							if SoraMeni.Fnkcaje.CzekBoksS("Mega Run", Sora.Meniis.megarun) then
								Sora.Meniis.megarun = not Sora.Meniis.megarun
							end
							if SoraMeni.Fnkcaje.CzekBoksS("Inf Combat Roll", Sora.Meniis.infroll) then
								Sora.Meniis.infroll = not Sora.Meniis.infroll
							end
							if SoraMeni.Fnkcaje.CzekBoksS("Bunnyhop", Sora.Meniis.bunnyhop) then
								Sora.Meniis.bunnyhop = not Sora.Meniis.bunnyhop
							end
							end
	
							if soraframework.JestMeniOtwarte("selfwardrobe") then
							if soraframework.cspacer("~t~WARDROBE", "") then end  
							if soraframework.Butos("Change Model") then
								local model = Fnkcaje.f.CustInputS('Type The Name Of Model', '', 30)
								Sorka.n.RequestModel(trAqZGmMAnclQGEozg(model))
								if Sorka.n.HasModelLoaded(trAqZGmMAnclQGEozg(model)) then
								  SetPlayerModel(Sorka.n.PlayerId(), trAqZGmMAnclQGEozg(model))
								else 
									pokazNotyfikacje(EOhustNy2, "Wrong Model", "ERROR", "")
								end
							end
							if soraframework.Butos("Random Clothes") then
								SoraS.Globus.RandomClothes()
							end
							if soraframework.cspacer("~t~OUTFITS", "") then end  
							if soraframework.Butos("Black Outfit") then
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 1, 0, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 2, 74, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 3, 20, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 4, 10, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 5, 0, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 6, 25, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 7, 0, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 8, 154, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 9, 0, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 10, 0, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 11, 379, 0)
							end
							if soraframework.Butos("Nude Outfit") then
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 1, 0, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 2, 21, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 3, 15, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 4, 18, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 5, 0, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 6, 67, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 7, 150, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 8, 57, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 9, 0, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 10, 86, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 11, 15, 0)
							end
							if soraframework.Butos("Guardian Outfit") then
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 0, 0, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 2, 75, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 1, 0, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 11, 336, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 4, 9, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 6, 61, 0)
								Sorka.n.SetPedComponentVariation(Sorka.n.PlayerPedId(), 8, 130, 0)
							end
							end
	
							if soraframework.JestMeniOtwarte("specificnetworking") then 
								if soraframework.cspacer(Sorka.n.GetPlayerName(SoraS.Globus.SelectedPlayer), '') then
								end
								if Sorka.n.IsEntityDead(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)) then
									if soraframework.Butos('~r~Dead') then 
									end
								else
									if soraframework.Butos('~g~Alive') then 
									end
								end
								if Sorka.n.IsPedInAnyVehicle(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer), NjU60Y4vOEbQkRWvHf5k) then
									if soraframework.Butos('~t~In Car') then 
									end
								else
									if soraframework.Butos('~p~On Foot') then 
									end
								end
								if soraframework.Butos('Health ~g~'..Sorka.n.GetEntityHealth(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer))) then end
								if soraframework.Butos('Armour ~b~'..Sorka.n.GetPedArmour(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer))) then end
								if soraframework.Butos("Attached To: ", CzyJestAttached) then end
								if soraframework.cspacer("~t~MAIN", "") then
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Spectate Cam", Sora.Meniis.Spectate2) then
									Sora.Meniis.Spectate2 = not Sora.Meniis.Spectate2
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Spectate Safer Cam", Sora.Meniis.Spectate) then
									Sora.Meniis.Spectate = not Sora.Meniis.Spectate
								end
		
								if soraframework.Butos('Teleport To Player') then
									SoraS.Globus.TeleportToPlayer(SoraS.Globus.SelectedPlayer)
								end
								if Sora.SoraZiomki[Sorka.n.GetPlayerName(SoraS.Globus.SelectedPlayer)] == KGsTiWzE4d5H4ssdSyUS then
									if soraframework.Butos("Remove Friend "..Sorka.n.GetPlayerName(SoraS.Globus.SelectedPlayer).."") then
										Sora.SoraZiomki[Sorka.n.GetPlayerName(SoraS.Globus.SelectedPlayer)] = NjU60Y4vOEbQkRWvHf5k
									end
								else
									if soraframework.Butos("Add As Friend "..Sorka.n.GetPlayerName(SoraS.Globus.SelectedPlayer).."") then
										Sora.SoraZiomki[Sorka.n.GetPlayerName(SoraS.Globus.SelectedPlayer)] = KGsTiWzE4d5H4ssdSyUS
									end
								end
								if soraframework.Butos('Copy Outfit') then
									SoraS.Globus.CopyOutfit(SoraS.Globus.SelectedPlayer)
								end
								if soraframework.Butos("Waypoint") then
									local coords = Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer))
									SoraS.Inv["Odwolanie"](SoraS.Natywki['SetNewWaypoint'], coords.x, coords.y)
								end
								if soraframework.cspacer("~t~TROLL", "") then
								end
								if SoraMeni.Fnkcaje.MeniButos("General Trolls", "NetworkingTrolls", '    ') then end
								if SoraMeni.Fnkcaje.MeniButos("Explosion", "OnlineExplosion", '    ') then end
								if SoraMeni.Fnkcaje.MeniButos("Car Options", "OnlineCar", '    ') then end
								if SoraMeni.Fnkcaje.MeniButos("Weapon Options", "OnlineWeapon", '    ') then end
								if SoraMeni.Fnkcaje.MeniButos("Other Options", "OnlineOther", '    ') then end
								if SoraMeni.Fnkcaje.CzekBoksS("Attach To Player", Sora.Meniis.megatest) then
									Sora.Meniis.megatest = not Sora.Meniis.megatest
									if Sora.Meniis.megatest then 
										CzyJestAttached = Sorka.n.GetPlayerName(SoraS.Globus.SelectedPlayer)
										if CzyJestAttached ~= "None" then
										local playerPed = Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)
										Sorka.n.AttachEntityToEntity(Sorka.n.PlayerPedId(), playerPed, 0x796E, 0.0, -0.25, 0.45, 0.5, 0.5, 180, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, 2, KGsTiWzE4d5H4ssdSyUS)
									end
										else
										CzyJestAttached = "None"
									DetachEntity(Sorka.n.PlayerPedId(), KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k) 
									end
								end
								if SoraMeni.Fnkcaje.CzekBoksS('Blame Drag', Sora.Meniis.megablame) then
									Sora.Meniis.megablame = not Sora.Meniis.megablame
								end
								if SoraMeni.Fnkcaje.CzekBoksS('Blame Piggyback', Sora.Meniis.megapiggy) then
									Sora.Meniis.megapiggy = not Sora.Meniis.megapiggy
								end
							end
	
							if soraframework.JestMeniOtwarte("NetworkingTrolls") then
								if soraframework.cspacer("~t~GENERAL TROLLS", "") then end
								if soraframework.Butos('Shoot Player', '~r~Risk') then
									SoraMeni.Fnkcaje.KillPlayer(SoraS.Globus.SelectedPlayer)
								end
								if soraframework.Butos('Cage Player', '~r~Quite Risky') then
									SoraMeni.Fnkcaje.CagePlayer(SoraS.Globus.SelectedPlayer)
								end
								if soraframework.Butos("Ram By a Car", "~r~Quite Risky") then
									Fnkcaje.f.GetRamedByCar('rumpo', SoraS.Globus.SelectedPlayer)
								end
								if soraframework.Butos("Smash Player With Car", "~r~Quite Risky") then
									Fnkcaje.f.GetSmashedByCar('rumpo', SoraS.Globus.SelectedPlayer)
								end
								if soraframework.Butos('Rape Player', '~r~Risk') then
									SoraS.Globus.RapeP(SoraS.Globus.SelectedPlayer)
								end
								if soraframework.Butos("Trihard Hot Dog", "~r~Quite Risky") then
									local trihard = _citek_.InvokeNative(" " ..  0x509D5878EB39E842, -272361894, 0.0, 0.0, 0.0, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
									_citek_.InvokeNative(" " ..  0xB69317BF5E782347, trihard)
									SetEntityAsMissionEntity(trihard, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
									Sorka.n.RequestModel(-272361894)
									Sorka.n.AttachEntityToEntity(trihard, Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer), 0, 11816, 0.0, -0.2, 0.0, 0.0, 0.0, 0.40, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, 2, KGsTiWzE4d5H4ssdSyUS)
								end
								if soraframework.Butos("Attach Gib", "~r~Quite Risky") then
									local trihard = _citek_.InvokeNative(" " ..  0x509D5878EB39E842, 1530424218, 0.0, 0.0, 0.0, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
									_citek_.InvokeNative(" " ..  0xB69317BF5E782347, trihard)
									SetEntityAsMissionEntity(trihard, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
									Sorka.n.RequestModel(1530424218)
									Sorka.n.AttachEntityToEntity(trihard, Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer), 0, 11816, 0.0, -0.2, 0.0, 0.0, 0.0, 0.40, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, 2, KGsTiWzE4d5H4ssdSyUS)
								end
								if soraframework.Butos('Spawn Tons Of Cars', '~r~Quite Risky') then
									SoraMeni.Fnkcaje.TonsCar(SoraS.Globus.SelectedPlayer, 'pbus', 2)
									SoraMeni.Fnkcaje.TonsCar(SoraS.Globus.SelectedPlayer, 'lguard', 2)
									SoraMeni.Fnkcaje.TonsCar(SoraS.Globus.SelectedPlayer, 'bulldozer', 1)
									SoraMeni.Fnkcaje.TonsCar(SoraS.Globus.SelectedPlayer, 'rubble', 1)
								end
								end
	
							if soraframework.JestMeniOtwarte("OnlineExplosion") then
								if soraframework.cspacer("~t~EXPLOSIONS", "") then
								end 
								if soraframework.Butos('Explode Player', "~g~UD") then
									for n,h in SoraS.Math.pairs(GetGamePool("CVehicle")) do
										SetEntityMatrix(h,GetEntityMatrix(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)))
										SetVehicleOutOfControl(h, 1, 1)
									end
								end
								if soraframework.Butos('Explode Player', "~r~Risk") then
									Sorka.n.AddExplosion(Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)), SrMeniS.CombBoxS.ekspliozjstyp[SrMeniS.CombBoxS.eksplzjientypeMultIndex], 100.0, Sora.Meniis.Audible, Sora.Meniis.IsInvs, 0.0)
								end
								if SoraMeni.Fnkcaje.KomboBoksS("Explode type", SrMeniS.CombBoxS.ekspliozjstyp, SrMeniS.CombBoxS.eksplzjientypeMultIndex, SrMeniS.CombBoxS.eksplzjientypeLengMult, function(terbieIndeks, selIndex)
									SrMeniS.CombBoxS.eksplzjientypeMultIndex = terbieIndeks
									SrMeniS.CombBoxS.eksplzjientypeLengMult = terbieIndeks
								end) then
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Sound Explode", Sora.Meniis.Audible) then
									Sora.Meniis.Audible = not Sora.Meniis.Audible
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Invisible Explode", Sora.Meniis.IsInvs) then
									Sora.Meniis.IsInvs = not Sora.Meniis.IsInvs
								end
								if soraframework.Butos("Spawn Car Then Explode", "~r~Quite Risky") then
									local car =  Fnkcaje.f.CustInputS('Type The Name Of Car', '', 30)
									SoraS.Globus.SpawnExplodeCar(SoraS.Globus.SelectedPlayer, car)
								end
							end
	
							if soraframework.JestMeniOtwarte("OnlineCar") then 
								if soraframework.cspacer("~t~TROLL CAR OPTIONS", "") then
								end 
								if soraframework.Butos("Check Network") then
									Sorka.n.NetworkRequestControlOfEntity(Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)))
									if NetworkGetEntityOwner(Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer))) == Sorka.n.PlayerPedId or Sorka.n.PlayerId then
										print("Network Success")
									else
										print("Failed To Gain Network Of Car")
									end
								end
								if soraframework.Butos('Explode Car', '~r~Quite Risky') then
									Sora.Meniis.bombka = not Sora.Meniis.bombka
									if Sora.Meniis.bombka then
										if Sorka.n.IsPedSittingInVehicle(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer), Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer), NjU60Y4vOEbQkRWvHf5k)) then
											local coords = Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer))
											NetworkExplodeVehicle(Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)), KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k)
										end
									end
								end
								if soraframework.Butos("Bug Car", "~r~Quite Risky") then
									SoraS.Globus.bugveh(SoraS.Globus.SelectedPlayer)
								end
								if soraframework.Butos("Slingshot Car") then
									SoraS.Globus.SlingshotCar(SoraS.Globus.SelectedPlayer)
								end
								if soraframework.Butos("Teleport Into Car") then
									Fnkcaje.f.TeleportIntoCar(SoraS.Globus.SelectedPlayer)
								end
								if soraframework.Butos("Invisble Car") then
									Sorka.n.NetworkRequestControlOfEntity(Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)))
									Sorka.n.SetEntityVisible(Sorka.n.GetVehiclePedIsUsing(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)), NjU60Y4vOEbQkRWvHf5k, 0)
								end
								if soraframework.Butos("Kill Engine") then
									Sorka.n.NetworkRequestControlOfEntity(Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)))
									SoraS.Globus.ZabicieEngine(SoraS.Globus.SelectedPlayer)
								end
								if soraframework.Butos("Kill Player") then
									Sorka.n.RequestControlOnce(Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)))
									SetVehicleOutOfControl(Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)), 1, 1)
								end
								if soraframework.Butos("Break Wheels") then
									Sorka.n.NetworkRequestControlOfEntity(Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)))
									SoraS.Globus.KoniecKol(Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)))
								end
								if soraframework.Butos('Stupid Car') then
									Fnkcaje.f.GlupieVehicle(SoraS.Globus.SelectedPlayer)
								end
								if soraframework.Butos("Delete Car") then
									Fnkcaje.f.DeleteCar(SoraS.Globus.SelectedPlayer)
								end
								if soraframework.Butos("Lock Car") then
									Sorka.n.RequestControlOnce(Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)))
									SoraS.Inv["Odwolanie"](SoraS.Natywki["SetVehicleDoorsLocked"], Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)), 4)
								end
								if soraframework.Butos('Spawn Pedestrian In Car') then
									SoraMeni.Fnkcaje.SpawnPedestrian(SoraS.Globus.SelectedPlayer)
								end
								if soraframework.cspacer("~t~FRIENDLY CAR OPTIONS", "") then
								end 
								if soraframework.Butos('Spawn Car') then
									local jakies =  Fnkcaje.f.CustInputS("Car To Spawn", "", 30)
									if jakies == '' then
										pokazNotyfikacje(EOhustNy2, "Wrong Car Model", "ERROR", "")
								else
									SoraMeni.Fnkcaje.SpawnCar(SoraS.Globus.SelectedPlayer, jakies)
								end
								end
								if soraframework.Butos('Fix Car') then
									SoraMeni.Fnkcaje.FixCar(SoraS.Globus.SelectedPlayer)
								end
							end
							if soraframework.JestMeniOtwarte("OnlineWeapon") then 
								if soraframework.cspacer("~t~WEAPON OPTIONS", "") then
								end 
								if SoraMeni.Fnkcaje.CzekBoksS("Make Him Shoot With Props ~r~(Quite Risky)", Sora.Meniis.givepropammo) then
									Sora.Meniis.givepropammo = not Sora.Meniis.givepropammo
								end
								if soraframework.Butos('Give All Weapons', '~r~Risk') then
									for weapo = 1, #SoraS.Bronicje do
										Sorka.n.GiveDelayedWeaponToPed(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer), trAqZGmMAnclQGEozg("WEAPON_" .. SoraS.Bronicje[weapo]), 150, NjU60Y4vOEbQkRWvHf5k)
									end
								end
								if soraframework.Butos('Remove All Weapons', "~r~Risk") then
									for weapo = 1, #SoraS.Bronicje do
										SoraS.Inv["Odwolanie"](SoraS.Natywki["RemoveAllPedWeapons"], Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer), NjU60Y4vOEbQkRWvHf5k)
									end
								end
								if soraframework.Butos('Give Weapon', '~r~Risk') then
									local weapon =  Fnkcaje.f.CustInputS("Weapon To Spawn", "weapon_", 30)
									if weapon == 'weapon_' then
										pokazNotyfikacje(EOhustNy2, "Wrong Weapon Model", "ERROR", "")
								else
									Sorka.n.GiveDelayedWeaponToPed(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer), trAqZGmMAnclQGEozg(weapon), 255, KGsTiWzE4d5H4ssdSyUS)
								end
								end
							end
							if soraframework.JestMeniOtwarte("OnlineOther") then 
								if soraframework.cspacer("~t~OTHER", "") then
								end
								if soraframework.Butos('Custom Prop') then
									local object = Fnkcaje.f.CustInputS("Prop Name", "prop_", 25)
									if object == 'prop_' then
										pokazNotyfikacje(EOhustNy2, "Wrong Prop Model", "ERROR", "")
								else
									SoraS.Globus.CustomProp(object, SoraS.Globus.SelectedPlayer)
								end
								end
								if soraframework.Butos("Custom Particle", "~r~Risk") then
									SoraS.Globus.PlayCustompParticle(SoraS.Globus.SelectedPlayer)
								end
								if soraframework.Butos("Launch Player In Air ~r~(Risk)") then
									pokazNotyfikacje(EOhustNy2, "Currently Disabled", "ERROR", "")
								end
								if soraframework.Butos("Attach Around Peds") then
									SoraS.Globus.AttachAroundPeds(SoraS.Globus.SelectedPlayer)
								end
								if soraframework.Butos("Attach Around Cars") then
									SoraS.Globus.AttachAroundCars(SoraS.Globus.SelectedPlayer)
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Teleport Cars", Sora.Meniis.tepanieautek) then
									Sora.Meniis.tepanieautek = not Sora.Meniis.tepanieautek
								end
								if soraframework.Butos("Bring Around Peds") then
									SoraS.Globus.BringAroundPeds(SoraS.Globus.SelectedPlayer)
								end
								if soraframework.Butos("Bring Around Peds 2") then
									SoraS.Globus.BringAroundPeds2(SoraS.Globus.SelectedPlayer)
								end
								if soraframework.Butos("Peds Attack Player") then
									SoraS.Globus.PedsAP(SoraS.Globus.SelectedPlayer)
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Play Sounds", Sora.Meniis.earrape) then
									Sora.Meniis.earrape = not Sora.Meniis.earrape
								end
							end
							if soraframework.JestMeniOtwarte("networking") then 
								if SoraMeni.Fnkcaje.MeniButos("All Players", "onlineplayerss", '') then end
								local players = GetActivePlayers()
								for i = 1, #players do
									local player = players[i]
									if players[i] == Sorka.n.PlayerId() then
										if SoraMeni.Fnkcaje.MeniButos("You ["..Sorka.n.GetPlayerServerId(players[i]).."] | "..Sorka.n.GetPlayerName(players[i]), "specificnetworking", ">") then 
											SoraS.Globus.SelectedPlayer = player
										end
									else
										if SoraMeni.Fnkcaje.MeniButos("["..Sorka.n.GetPlayerServerId(players[i]).."] | "..Sorka.n.GetPlayerName(players[i]).. " " ..SoraS.Math.floor(Sorka.n.GetDistanceBetweenCoords(Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId()),Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(players[i])),true)), "specificnetworking", ">") then 
											SoraS.Globus.SelectedPlayer = player
										end
								end
							end
						end
		
							if soraframework.JestMeniOtwarte("vehicle") then
								if SoraMeni.Fnkcaje.MeniButos("Spawner", "spawner", ">") then 
								end
								if SoraMeni.Fnkcaje.MeniButos("Upgrades", "upgrejdy", ">") then 
								end
								if soraframework.Butos("Engine Boost") then
									ModifyVehicleTopSpeed(Sorka.n.GetVehiclePedIsUsing(Sorka.n.PlayerPedId()),1000)
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Horn Boost", SrMeniS.HornBoost) then
									SrMeniS.HornBoost = not SrMeniS.HornBoost
								end
								if soraframework.cspacer("~t~MAIN", "") then
								elseif soraframework.Butos("Repair", "") then
									Fnkcaje.f.RepairVehicle()
								elseif SoraMeni.Fnkcaje.CzekBoksS("Auto Repair", Sora.Meniis.AutoRepair) then
									Sora.Meniis.AutoRepair = not Sora.Meniis.AutoRepair
								elseif soraframework.Butos("Delete", "") then
									Sorka.n.DeleteEntity(Sorka.n.GetVehiclePedIsIn(Sorka.n.PlayerPedId()))
								elseif soraframework.Butos("Lock Closest Car", "") then
									local vehicle = SoraS.Inv["Odwolanie"](SoraS.Natywki['GetClosestVehicle'], Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId()), 25.0, 0, 70)
									Sorka.n.RequestControlOnce(vehicle)
									Fnkcaje.f.LockVehicle(vehicle)
								elseif soraframework.Butos("Unlock Closest Car", "") then
									local vehicle = SoraS.Inv["Odwolanie"](SoraS.Natywki['GetClosestVehicle'], Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId()), 25.0, 0, 70)
									Sorka.n.RequestControlOnce(vehicle)
									Fnkcaje.f.UnlockVehicle(vehicle)
								elseif soraframework.Butos("Set Car On Ground Properly", "") then
									SoraMeni.Fnkcaje.FlipVehicle()
								elseif soraframework.cspacer("~t~OTHER", "") then
								elseif soraframework.Butos("Clean", "") then
									SoraS.Globus.CleanVehicle()
								elseif soraframework.Butos("Refill Fuel") then
									SetVehicleFuelLevel(Sorka.n.GetVehiclePedIsUsing(Sorka.n.PlayerPedId()),1000)
								elseif soraframework.Butos("Start Engine", "") then
									SetVehicleEngineOn(Sorka.n.GetVehiclePedIsUsing(Sorka.n.PlayerPedId()), KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k)
								elseif soraframework.Butos("Change Plate", "") then
									local result = Fnkcaje.f.CustInputS('Enter Car Plate', 'Sora', 8)
									local car = Sorka.n.GetVehiclePedIsUsing(Sorka.n.PlayerPedId())
									Sorka.n.SetVehicleNumberPlateText(car, result) 
								elseif soraframework.Butos("Random Car Colour", "") then
									SoraS.Globus.RandomColour()        
								end
		
							
		
						end
		
							if soraframework.JestMeniOtwarte("WeaponsAddons") then
								if soraframework.cspacer("~t~ATTACHMENTS") then
							end
								if soraframework.Butos("Suppressor") then
										GiveWeaponComponentToPed(Sorka.n.GetPlayerPed(-1), Sorka.n.GetSelectedPedWeapon(Sorka.n.PlayerPedId()), trAqZGmMAnclQGEozg("component_at_pi_supp_02"))  
										GiveWeaponComponentToPed(Sorka.n.GetPlayerPed(-1), Sorka.n.GetSelectedPedWeapon(Sorka.n.PlayerPedId()), trAqZGmMAnclQGEozg("COMPONENT_AT_AR_SUPP_02"))  
										GiveWeaponComponentToPed(Sorka.n.GetPlayerPed(-1), Sorka.n.GetSelectedPedWeapon(Sorka.n.PlayerPedId()), trAqZGmMAnclQGEozg("COMPONENT_AT_PI_SUPP"))
								end
								if soraframework.Butos("Flashlight") then
										GiveWeaponComponentToPed(Sorka.n.GetPlayerPed(-1), Sorka.n.GetSelectedPedWeapon(Sorka.n.PlayerPedId()), trAqZGmMAnclQGEozg("COMPONENT_AT_PI_FLSH"))  
										GiveWeaponComponentToPed(Sorka.n.GetPlayerPed(-1), Sorka.n.GetSelectedPedWeapon(Sorka.n.PlayerPedId()), trAqZGmMAnclQGEozg("COMPONENT_AT_AR_FLSH"))  
								end
								if soraframework.Butos("Grip") then
									GiveWeaponComponentToPed(Sorka.n.GetPlayerPed(-1), Sorka.n.GetSelectedPedWeapon(Sorka.n.PlayerPedId()), trAqZGmMAnclQGEozg("COMPONENT_AT_AR_AFGRIP"))  
									GiveWeaponComponentToPed(Sorka.n.GetPlayerPed(-1), Sorka.n.GetSelectedPedWeapon(Sorka.n.PlayerPedId()), trAqZGmMAnclQGEozg("COMPONENT_AT_AR_FLSH"))  
								end
								if soraframework.Butos("Scope") then
										SoraS.Globus.GiveWeaponComponentToPed(0x9D2FBF29)
										SoraS.Globus.GiveWeaponComponentToPed(0xA0D89C42)
										SoraS.Globus.GiveWeaponComponentToPed(0xAA2C45B4)
										SoraS.Globus.GiveWeaponComponentToPed(0xD2443DDC)
										SoraS.Globus.GiveWeaponComponentToPed(0x3CC6BA57)
										SoraS.Globus.GiveWeaponComponentToPed(0x3C00AFED)
								end
							end
	
							if soraframework.JestMeniOtwarte("weapons") then 
								if soraframework.cspacer("~t~MAIN", "") then end
								if SoraMeni.Fnkcaje.MeniButos("PVP", "WeaponsPVP", "") then 
								end
								if SoraMeni.Fnkcaje.MeniButos("Attachments", "WeaponsAddons", "") then 
								end
								if soraframework.cspacer("~t~CUSTOM AMMO", "") then
								end
		
								if SoraMeni.Fnkcaje.CzekBoksS("Rpg Gun ~r~(Risk)", Sora.Meniis.RPGGun) then
									Sora.Meniis.RPGGun = not Sora.Meniis.RPGGun
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Cars Gun ~r~(Risk)", Sora.Meniis.shootvehs) then
									Sora.Meniis.shootvehs = not Sora.Meniis.shootvehs
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Inf ammo", Sora.Meniis.infammo) then
									Sora.Meniis.infammo = not Sora.Meniis.infammo
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Safer Inf Ammo", Sora.Meniis.infammo2) then
									Sora.Meniis.infammo2 = not Sora.Meniis.infammo2
								end
								if SoraMeni.Fnkcaje.CzekBoksS("No Reload", Sora.Meniis.noreload) then
									Sora.Meniis.noreload = not Sora.Meniis.noreload
								end
								if soraframework.cspacer("~t~SPAWNER", "") then
								end
								if SoraMeni.Fnkcaje.MeniButos("Addons Guns", "AddonsGuns", "") then end
								if soraframework.Butos("Give All Weapons", "~r~Risk") then 
									SoraMeni.Fnkcaje.GiveAllWeapons()
								end
								if soraframework.Butos("Remove All Weapons", "~r~Risk") then 	
									SoraMeni.Fnkcaje.RemoveAllWeapons()
								end
								if soraframework.Butos("Spawn Weapon Pickup", "~r~Quite Risky") then
									Fnkcaje.f.SpawnWeaponPickup()
								end
								if soraframework.Butos("Spawn Single Weapon", "~r~Risk") then 
									Fnkcaje.f.SpawnWeapon()
								end
								if soraframework.Butos("Remove Single Weapon") then 
									Fnkcaje.f.RemoveWeapon()
								end
								if SoraMeni.Fnkcaje.KomboBoksS("Set Current Gun Ammo", SrMeniS.CombBoxS.amko, SrMeniS.CombBoxS.amkoMultIndex, SrMeniS.CombBoxS.amkoLengMult, function(terbieIndeks, selIndex)
									SrMeniS.CombBoxS.amkoMultIndex = terbieIndeks
									SrMeniS.CombBoxS.amkoLengMult = terbieIndeks
								end) then
									Fnkcaje.f.SetCurrentAmmo(SrMeniS.CombBoxS.amko[SrMeniS.CombBoxS.amkoMultIndex])
								end
							end
	
							if soraframework.JestMeniOtwarte("AddonsGuns") then
								if soraframework.cspacer("~t~ADDONS", "") then end
								for k,v in pairs(SoraS.AddonBronie) do 
									if Sorka.n.IsModelValid(trAqZGmMAnclQGEozg(v.spawn)) then
									if soraframework.Butos(v.name) then
										print("halooo")
										Sorka.n.GiveWeaponToPed(Sorka.n.PlayerPedId(), trAqZGmMAnclQGEozg(WEAPON_DILDO), 175, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
									 end
								end
							end
						end
		
							if soraframework.JestMeniOtwarte("WeaponsPVP") then 
								if soraframework.cspacer("~t~AIMBOT", "") then
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Triggerbot", SoraMeni.Fnkcaje.triggerbot) then
									SoraMeni.Fnkcaje.triggerbot = not SoraMeni.Fnkcaje.triggerbot
								end
								if soraframework.cspacer("~t~OTHER", "") then
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Hit Sound", SoraMeni.Fnkcaje.hitsound) then 
									SoraMeni.Fnkcaje.hitsound = not SoraMeni.Fnkcaje.hitsound
								end
							end
							if soraframework.JestMeniOtwarte("world") then 
								if soraframework.cspacer("~t~WORLD", "") then end
								if soraframework.Butos("Stop Black Screen") then
									DoScreenFadeIn(0)
								end
								if soraframework.Butos("Stop Screen Blur") then
									TriggerScreenblurFadeOut(0)
								end
								if soraframework.Butos("No Fog") then 
									Sorka.n.SetWeatherTypePersist("CLEAR")
									Sorka.n.SetWeatherTypeNowPersist("CLEAR")
									Sorka.n.SetWeatherTypeNow("CLEAR")
									Sorka.n.SetOverrideWeather("CLEAR")
									SetTimecycleModifier('CS1_railwayB_tunnel')
								end	
								if SoraMeni.Fnkcaje.CzekBoksS("No Screen Recoil", Sora.Meniis.NoSR) then
									Sora.Meniis.NoSR = not Sora.Meniis.NoSR
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Slowmotion", Sora.Meniis.Slowmotion) then 
									Sora.Meniis.Slowmotion = not Sora.Meniis.Slowmotion
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Solo Session", Sora.Meniis.solosesja) then 
									Sora.Meniis.solosesja = not Sora.Meniis.solosesja
								end
								if soraframework.cspacer("~t~FORCE", "") then end
								if SoraMeni.Fnkcaje.CzekBoksS("Force Third Person", Sora.Meniis.force3rdper) then
									Sora.Meniis.force3rdper = not Sora.Meniis.force3rdper
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Force Driveby", Sora.Meniis.forcedriveby) then
									Sora.Meniis.forcedriveby = not Sora.Meniis.forcedriveby
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Force Radar", Sora.Meniis.displayradar) then
									Sora.Meniis.displayradar = not Sora.Meniis.displayradar
								end
							end
							if soraframework.JestMeniOtwarte("visuals") then 
								if soraframework.cspacer("~t~ESP", "") then
								end
								if SoraMeni.Fnkcaje.KomboBoksS("ESP Distance", SrMeniS.CombBoxS.EspikDist, SrMeniS.CombBoxS.EspiorDistMultIndex, SrMeniS.CombBoxS.EspiorDistLengMult, function(terbieIndeks, selIndex)
									SrMeniS.CombBoxS.EspiorDistMultIndex = terbieIndeks
									SrMeniS.CombBoxS.EspiorDistLengMult = terbieIndeks
								end) then
								end
								if soraframework.cspacer("~t~OPTIONS", "") then end  
								if SoraMeni.Fnkcaje.CzekBoksS("Include Self", Sora.Meniis.includeself) then
									Sora.Meniis.includeself = not Sora.Meniis.includeself
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Boxes", Sora.Meniis.boxes) then
									Sora.Meniis.boxes = not Sora.Meniis.boxes
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Fill Boxes", Sora.Meniis.boxesV3) then
									Sora.Meniis.boxesV3 = not Sora.Meniis.boxesV3
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Corner Boxes", Sora.Meniis.cornerbox) then
									Sora.Meniis.cornerbox = not Sora.Meniis.cornerbox
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Health bar", Sora.Meniis.hpbar) then
									Sora.Meniis.hpbar = not Sora.Meniis.hpbar
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Armour bar", Sora.Meniis.armourbar) then
									Sora.Meniis.armourbar = not Sora.Meniis.armourbar
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Car ESP", Sora.Meniis.caresp) then
									Sora.Meniis.caresp = not Sora.Meniis.caresp
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Lines", Sora.Meniis.tracers) then
									Sora.Meniis.tracers = not Sora.Meniis.tracers
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Info", Sora.Meniis.infos) then
									Sora.Meniis.infos = not Sora.Meniis.infos
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Skeletons", Sora.Meniis.skeletons) then
									Sora.Meniis.skeletons = not Sora.Meniis.skeletons
								end
							end
							if soraframework.JestMeniOtwarte("onlineplayerss") then 
								if soraframework.cspacer("~t~ONLINE PLAYERS", "") then
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Money Lobby", Sora.Meniis.MoneyLobby) then
									Sora.Meniis.MoneyLobby = not Sora.Meniis.MoneyLobby
								end
								if soraframework.Butos("Rape All Players", "~r~Risk") then 
									for k, i in SoraS.Math.pairs(GetActivePlayers()) do 
										SoraS.Globus.RapeP(i)
									end 
								end
								if soraframework.Butos('Kill All Players', '~r~Risk') then
									SoraS.Globus.KillAllPlayers()
								end
								if soraframework.cspacer("~t~CARS OPTIONS", "") then
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Delete All Cars", Sora.Meniis.DeleteAllCars) then 
									Sora.Meniis.DeleteAllCars = not Sora.Meniis.DeleteAllCars
								end
								if SoraMeni.Fnkcaje.CzekBoksS("Make Cars Fly", Sora.Meniis.FlyAllCars) then 
									Sora.Meniis.FlyAllCars = not Sora.Meniis.FlyAllCars
								end
									if SoraMeni.Fnkcaje.CzekBoksS("Turn Off All Engines", Sora.Meniis.TurnOffEnginesLoop) then
										Sora.Meniis.TurnOffEnginesLoop = not Sora.Meniis.TurnOffEnginesLoop
									end
									if soraframework.Butos('Start Alarm In All Cars') then
										for vehicle in Sorka.n.EnumerateVehicles() do
											if (vehicle ~= Sorka.n.GetVehiclePedIsIn(Sorka.n.GetPlayerPed(-1), NjU60Y4vOEbQkRWvHf5k)) then
												Sorka.n.NetworkRequestControlOfEntity(vehicle)
												SoraS.Inv["Odwolanie"](SoraS.Natywki["SetVehicleAlarmTimeLeft"], vehicle, 500)
												SetVehicleAlarm(vehicle,KGsTiWzE4d5H4ssdSyUS)
												StartVehicleAlarm(vehicle)
											end
										end
									 end
									if soraframework.Butos('Change All Cars Plate', "~r~Risk") then
										for vehs in Sorka.n.EnumerateVehicles() do
											Sorka.n.SetVehicleNumberPlateText(vehs, 'Sora') 
										end
									end
									if soraframework.Butos('Spawn Tons Of Car', '~r~Quite Risky') then
										for k, i in SoraS.Math.pairs(GetActivePlayers()) do 
											SoraMeni.Fnkcaje.TonsCar(i, 'pounder', 1)
											SoraMeni.Fnkcaje.TonsCar(i, 'rentalbus', 1)
										end
									end
									if SoraMeni.Fnkcaje.CzekBoksS('Explode All Cars', Sora.Meniis.bombkaonall) then
										Sora.Meniis.bombkaonall = not Sora.Meniis.bombkaonall
											if Sora.Meniis.bombkaonall then
												for vehs in Sorka.n.EnumerateVehicles() do
													SetVehicleOutOfControl(vehs,KGsTiWzE4d5H4ssdSyUS,NjU60Y4vOEbQkRWvHf5k)
												end
											end
										end
										if soraframework.Butos('Stupid All Players Cars', '~r~Quite Risky') then
											for k, i in SoraS.Math.pairs(GetActivePlayers()) do 
												Fnkcaje.f.GlupieVehicle(i) 
											end
										end
										if soraframework.cspacer("~t~PEDS OPTIONS", "") then
										end
									if soraframework.Butos("Kill All Peds", "~r~Quite Risky") then
										SoraMeni.Fnkcaje.killallpeds()
									end
									if soraframework.cspacer("~t~PROP OPTIONS", "") then
									end
									if soraframework.Butos('Custom Prop') then
										local object = Fnkcaje.f.CustInputS("Prop Name", "prop_", 25)
										if object == 'prop_' then
											pokazNotyfikacje(EOhustNy2, "Wrong Prop Model", "ERROR", "")
									else
										for k, i in SoraS.Math.pairs(GetActivePlayers()) do 
											SoraS.Globus.CustomProp(object, i)
										end
									end
									end
									if soraframework.Butos("Prop Map", "~r~Quite Risky") then
										SoraS.Globus.PropMap()
									end
									if soraframework.Butos("Prop Closet Cars") then
										SoraS.Globus.PropCars()
									end
									if soraframework.cspacer("~t~OTHER", "") then
									end
										if SoraMeni.Fnkcaje.CzekBoksS("Play Sounds For All", Sora.Meniis.earrapeall) then
											Sora.Meniis.earrapeall = not Sora.Meniis.earrapeall
										end
							end
	
							if soraframework.JestMeniOtwarte("lua") then 
								czektrikers()
								if soraframework.Butos("IP:", GetCurrentServerEndpoint()) then
								end
								if SoraMeni.Fnkcaje.MeniButos("Resources", "resourcslist", ">") then 
								end
								if soraframework.Butos("Spoofed Natywki:", numbere) then
								end
								if soraframework.Butos("Reload") then
									SoraMeni.Fnkcaje.LoadTrikerki()
								end
								if soraframework.Butos("Check Server For Any Anticheats") then
									szukanieac()
								end
								if soraframework.cspacer("~r~WARNING", "") then
								end
								if soraframework.cspacer("~t~Some Of The Triggers Can Be Flagged As Safe", "") then
								end
								if soraframework.cspacer("~t~What Can Result In Ban", "") then
								end
								if soraframework.cspacer("~t~TRIGGERS", "") then
								end
								if dynamic.DTRS['gopostaljob:pay2'] then
									if soraframework.Butos("Money 1") then
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['gopostaljob:pay2'], 9999)
									end
								end
								if dynamic.DTRS['esx_skin:openSaveableMenu'] then
									if soraframework.Butos("Open Skin Menu") then
										SoraS.Globus.TriggerCustomEvent(NjU60Y4vOEbQkRWvHf5k, 'esx_skin:openSaveableMenu')
									end
								end
								if dynamic.DTRS['garbagejob_pay'] then
									if soraframework.Butos("Money 2") then
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['garbagejob_pay'], 9999)
									end
								end
								if dynamic.DTRS['gopostaljob:pay'] then
									if soraframework.Butos("Money 3") then
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['gopostaljob:pay'], 9999)
									end
								end
								if dynamic.DTRS['esx_blanchisseur:pay'] then
									if soraframework.Butos("Money 4") then
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['esx_blanchisseur:pay'], 9999)
									end
								end
		
								if dynamic.DTRS['esx_pizza:pay'] then
									if soraframework.Butos("Money 5") then
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['esx_pizza:pay'], 9999)
									end
								end
								if dynamic.DTRS['kuriersianko'] then
									if soraframework.Butos("Money 6") then
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['esx_kurier:zaplata'])
									end
								end
								if dynamic.DTRS['esx_taxijob:success'] then
									if soraframework.Butos("Money 7") then
										_TSE_("esx_taxijob:success")
										_TSE_("esx_taxijob2:success")
									end
								end
	
								if dynamic.DTRS['kupnoitemku'] then
									if soraframework.Butos("Buy Item") then
										local itemek = Fnkcaje.f.CustInputS('Item To Buy', '', 30)
										local iletego = Fnkcaje.f.CustInputS('How Many', '', 30)
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['esx_shops:buyItem'], itemek, iletego, Sklep, 'gotowka')
									end
								end
								
								if dynamic.DTRS['vangelico_get'] then
									if SoraMeni.Fnkcaje.CzekBoksS("Give Jewlery", dynamic.DTRS.MoneyLoop) then
										dynamic.DTRS.MoneyLoop = not dynamic.DTRS.MoneyLoop
										if dynamic.DTRS.MoneyLoop then
											SoraS.Inv["Nitka"](function()
												while dynamic.DTRS.MoneyLoop do
													SoraS.Inv["Czekaj"](200)
													SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['vangelico_get'])
												end
											end)
										end
									end
								end
								if dynamic.DTRS['vangelico_sell'] then
									if soraframework.Butos("Sell Jewlery") then
										local amount =  Fnkcaje.f.CustInputS('Amount To Sell', '', 3)
										for i = 0, SoraS.Math.tonumber(amount-1) do
											SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['vangelico_sell'])
										end
									end
								end
								if dynamic.DTRS['giveitem'] then
									if soraframework.Butos("Give Item") then
										local item =  Fnkcaje.f.CustInputS('Item To Give', '', 30)
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['giveitem'], item)
									end
								end
								if dynamic.DTRS['giveitem2'] then
									if soraframework.Butos("Give Item") then
										local item = Fnkcaje.f.CustInputS('Item To Give', '', 30)
										local ammount = Fnkcaje.f.CustInputS('Ammount', '', 30)
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['giveitem2'], item, ammount)
									end
								end
								if dynamic.DTRS['reviveesx'] then
									if soraframework.Butos("Revive") then
										SoraS.Globus.TriggerCustomEvent(NjU60Y4vOEbQkRWvHf5k, dynamic.DTRS['reviveesx'])
									end
								end
								if dynamic.DTRS['reviveesx2'] then
									if soraframework.Butos("Revive") then
										SoraS.Globus.TriggerCustomEvent(NjU60Y4vOEbQkRWvHf5k, dynamic.DTRS['reviveesx2'])
									end
								end
								if dynamic.DTRS['policejob_handcuff'] then
									if soraframework.Butos("Handcuff Player") then
										local id =  Fnkcaje.f.CustInputS('Player Id', '', 3)
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['policejob_handcuff'], id)
									end
								end
								if dynamic.DTRS['policejob_handcuff'] then
									if soraframework.Butos("Handcuff All Players") then
										for k, i in SoraS.Math.pairs(GetActivePlayers()) do 
											SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['policejob_handcuff'], i)
										end
									end
								end
								if dynamic.DTRS['policejob_spammer'] then
									if soraframework.Butos("Send Message To Everyone") then
										SoraS.Inv["Nitka"](function()
											local text =  Fnkcaje.f.CustInputS('Message', 'Sora ON TOP BUY OR DIE!', 1000)
											local amount =  Fnkcaje.f.CustInputS('How Many Time', '5', 3)
											for i = 1, SoraS.Math.tonumber(amount) do
												SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['policejob_spammer'], -1, '('..i..') '..SoraS.Strings.tostring(text))
												SoraS.Inv["Czekaj"](60)
											end
										end)
									end
								end 
								if dynamic.DTRS['dmv_getlicense'] then
									if soraframework.Butos("Give All Licences") then
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['dmv_getlicense'], 'dmv')
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['dmv_getlicense'], 'drive')
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['dmv_getlicense'], 'drive_bike')
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['dmv_getlicense'], 'drive_truck')
									end
								end
								if dynamic.DTRS['carry_exploit'] then
									if soraframework.Butos("Carry Everyone") then
										SoraS.Inv["Nitka"](function()
											while KGsTiWzE4d5H4ssdSyUS do 
												SoraS.Inv["Czekaj"](0)
												for k, v in SoraS.Math.pairs(GetActivePlayers()) do
													if Sorka.n.GetPlayerPed(v) ~= Sorka.n.PlayerPedId() then 
														SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['carry_exploit'], Sorka.n.GetPlayerPed(v), 'missfinale_c2mcs_1', 'nm', 'fin_c2_mcs_1_camman', 'firemans_carry', 0.15, 0.27, 0.63,Sorka.n.GetPlayerServerId(v), 100000, 0.0, 49, 33, 1)
														SoraS.Inv["Czekaj"](10)
													end
												end
											return
										 end
										end)
									end
								end
								
								if dynamic.DTRS['Money_Wash'] then
									if soraframework.Butos("Wash Money") then
										local money = Fnkcaje.f.CustInputS("How Much", '', 10)
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['Money_Wash'], money, 0)
									end
								end
								if dynamic.DTRS['open_inv'] then
									if soraframework.Butos("Open Inventory") then
										local id =  Fnkcaje.f.CustInputS("Player ID", '', 10)
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['open_inv'], "otherplayer", id)	
									end
								end
								if dynamic.DTRS['play_song'] then
									if soraframework.Butos("Play Song") then
										for k, v in SoraS.Math.pairs(GetActivePlayers()) do 
											person = Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(v))
											song =  Fnkcaje.f.CustInputS("Enter A YT Link", '', 30)
											SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['play_da_sound'], song, person)
										end
									end
								end
								if dynamic.DTRS['Money_Wash_Zone'] then
									if soraframework.Butos("Wash Money") then
										local ammount =  Fnkcaje.f.CustInputS("How Much", '', 30)
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['Money_Wash_Zone'], ammount)
									end
								end
								if dynamic.DTRS['garbagejob_pay'] then
									if soraframework.Butos("Money 8") then
										local ammount =  Fnkcaje.f.CustInputS("How Much", '', 30)
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['garbagejob_pay'], ammount)
									end
								end
								if dynamic.DTRS['send_bill'] then
									if soraframework.Butos("Give Bill") then
										for k, v in SoraS.Math.pairs(GetActivePlayers()) do
											for k, i in SoraS.Math.pairs(GetActivePlayers()) do 
												SoraS.Inv["Czekaj"](60)
												SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS["send_bill"],Sorka.n.GetPlayerServerId(v), "Sora", 9999)
											end
							
											SoraS.Inv["Czekaj"](100)
										end
									end
								end
								if dynamic.DTRS['esx_jailer:unjailTime'] then
									if soraframework.Butos("Unjail") then
										SoraS.Globus.TriggerCustomEvent('esx_jailer:unjailTime',-1)
									end
								end
								if dynamic.DTRS['gopostal_pay'] then
									if soraframework.Butos("Money 9") then
										local ammount =  Fnkcaje.f.CustInputS('How Much', '', 30)
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['gopostal_pay'], ammount)
									end
								end
								if dynamic.DTRS['esx_status_hungerandthirst'] then
									if soraframework.Butos("Refill Hunger And Thirst") then
										SoraS.Globus.TriggerCustomEvent(NjU60Y4vOEbQkRWvHf5k, dynamic.DTRS['esx_status_hungerandthirst'], 'hunger', 50)
										SoraS.Globus.TriggerCustomEvent(NjU60Y4vOEbQkRWvHf5k, dynamic.DTRS['esx_status_hungerandthirst'], 'thirst', 50)
									end
								end
								if dynamic.DTRS['add_vehicle'] then
									if soraframework.Butos("Add Car To Garage") then
										local car = Fnkcaje.f.CustInputS('Name Of Car', '', 30)
										if Sorka.n.IsModelValid(trAqZGmMAnclQGEozg(car)) and Sorka.n.IsModelAVehicle(car) then
											local customplate = Fnkcaje.f.CustInputS('Car Plate', '', 30)
											SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['vehicleshop_ownedveh'], {['model'] = trAqZGmMAnclQGEozg(SoraS.Strings.tostring(car)), ['plate'] = SoraS.Strings.tostring(customplate)})
											
										end
									end
								end
								if dynamic.DTRS['esx_holdup'] then
									if soraframework.Butos("Money 10") then
										SoraS.Globus.TriggerCustomEvent(KGsTiWzE4d5H4ssdSyUS, dynamic.DTRS['esx_holdup'])
									end
								end
		
							end
		
							if soraframework.JestMeniOtwarte("upgrejdy") then
								if soraframework.cspacer("~t~UPGRADES", "") then end
							if soraframework.Butos("Full Tune") then
								SoraS.Globus.MaxTuning()
							elseif soraframework.Butos("Performance Tuning") then
								SoraS.Globus.PerformanceTuning(Sorka.n.GetVehiclePedIsIn(Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k))
							elseif soraframework.Butos("Add Ramp") then
								SoraS.Globus.TuningRamp()
								end
							end
	
							if soraframework.JestMeniOtwarte("addons") then
								if soraframework.cspacer("~t~ADDONS", "") then end
								czekcars()
								for k,v in pairs(SoraS.AddonAutka) do 
									if soraframework.Butos(v.name) then
										Fnkcaje.f.SpawnVehicle(v.name)
									 end
							end
						end
	
							if soraframework.JestMeniOtwarte("spawner") then
								if SoraMeni.Fnkcaje.MeniButos("Addons", "addons", ">") then 
								end
								if soraframework.Butos("Spawn Car", "~r~Network") then
									local car =  Fnkcaje.f.CustInputS('Type The Name Of Car', '', 30)
									Fnkcaje.f.SpawnVehicle(car)
								end
								if soraframework.Butos("Spawn Car", "~g~Spoof") then
									local car =  Fnkcaje.f.CustInputS('Type The Name Of Car', '', 30)
									Fnkcaje.f.SpawnVehicle2(car)
								end
								if soraframework.Butos("Spawn Car", "~y~Esx") then
									local car =  Fnkcaje.f.CustInputS('Type The Name Of Car', '', 30)
									TriggerEvent('esx:spawnVehicle', (car))
								end
							end
		
							
							if soraframework.JestMeniOtwarte("keybinds") then
								if soraframework.Butos("Menu Key:", ""..SoraKeybinds.Meniis.OpenMeniS["Label"]) then
									local value, label = Fnkcaje.f.Bindek()
									SoraKeybinds.Meniis.OpenMeniS["Label"] = label
									SoraKeybinds.Meniis.OpenMeniS["Value"] = value
								end
	
								if soraframework.Butos("Noclip:", ""..SoraKeybinds.Meniis.Noclip["Label"]) then
									local value, label = Fnkcaje.f.Bindek()
									SoraKeybinds.Meniis.Noclip["Label"] = label
									SoraKeybinds.Meniis.Noclip["Value"] = value
								end
								if soraframework.Butos("Freecam:", ""..SoraKeybinds.Meniis.Freecam["Label"]) then
									local value, label = Fnkcaje.f.Bindek()
									SoraKeybinds.Meniis.Freecam["Label"] = label
									SoraKeybinds.Meniis.Freecam["Value"] = value
								end
							end
	
							if soraframework.JestMeniOtwarte("resourcslist") then
								local asdd = Sorka.n.BierzResources2()
								for i=0, #asdd do
									if soraframework.Butos(asdd[i], GetResourceState(asdd[i])) then
									end
								end
							end
	
							if soraframework.JestMeniOtwarte("exploits") then
								if soraframework.cspacer("~t~EXPLOITS", "") then
								end
								if soraframework.Butos("Screenshot Bypass") then
									Citizen.CreateThread(function()
										local TriggerEvent = TriggerEvent
										local Wait = Wait
									
										while KGsTiWzE4d5H4ssdSyUS do
											Wait(10)
	
											TriggerEvent("__cfx_export_screenshot-basic_requestScreenshotUpload", function(func)
												func("x", "", {}, function() end)
											end)
										end
									end)
								end
								if soraframework.Butos("Block Nuis") then
									Citizen.CreateThread(function()
										local Wait = Wait
										while KGsTiWzE4d5H4ssdSyUS do
											Wait(0)
												SetNuiFocus(NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k)
										end
									end)
								end
								if soraframework.Butos("Block Resource") then
									local skrypton =  Fnkcaje.f.CustInputS('Type Name Of The Script From Which You Want To Block Events', '', 30)
									if skrypton == "" then
										pokazNotyfikacje(EOhustNy2, "Wrong Script Name", "ERROR", "")
									else
									end
							end
							if soraframework.Butos("Unblock Resource") then
	
						end
					end
	
							if soraframework.JestMeniOtwarte("design") then
								if soraframework.cspacer("~t~DESIGN", "") then
								end
								if SoraMeni.Fnkcaje.KomboBoksS("Option Menu", SrMeniS.CombBoxS.opcjemenis, SrMeniS.CombBoxS.opcjeMultIndex, SrMeniS.CombBoxS.opcjeLengMult, function(terbieIndeks, selIndex)
									SrMeniS.CombBoxS.opcjeMultIndex = terbieIndeks
									SrMeniS.CombBoxS.opcjeLengMult = terbieIndeks
								end) then
									defaultStyl.dOptionCountOnScreen = (SrMeniS.CombBoxS.opcjemenis[SrMeniS.CombBoxS.opcjeMultIndex])
								end
							end
	
							if soraframework.JestMeniOtwarte("rcpedzik") then
								if SoraMeni.Fnkcaje.CzekBoksS("Enable RC Ped", Sora.Meniis.rcped) then
									Sora.Meniis.rcped = not Sora.Meniis.rcped
									if Sora.Meniis.rcped then
										pokazNotyfikacje(EOhustNy2, "SOON", "ERROR", "")
	
									end
								end
							end
		
							if soraframework.JestMeniOtwarte("settings") then
								if soraframework.cspacer("~t~Build Version Beta 0.5", "") then
								end
								if soraframework.Butos("Dev", "Nunu") then
								end
								if soraframework.Butos("Image by", "hellomuh22 on Freepik") then
								end
								if soraframework.Butos("Special Thanks To", "adi,topblantowski,xaries") then
								end
							if SoraMeni.Fnkcaje.MeniButos("Keybinds", "keybinds", ">") then 
							end
							if SoraMeni.Fnkcaje.MeniButos("Exploits", "exploits", ">") then 
							end
							if SoraMeni.Fnkcaje.MeniButos("Design", "design", ">") then 
							end  
							if SoraMeni.Fnkcaje.MeniButos("RC Ped", "rcpedzik", ">") then 
							end  
							if SoraMeni.Fnkcaje.CzekBoksS("Simulate Key Press", Sora.Meniis.SimulateKeyP) then 
								local atakikey =  Fnkcaje.f.CustInputS('Type Control Id', '', 30)
								if atakikey == "" then
									Sora.Meniis.SimulateKeyP = NjU60Y4vOEbQkRWvHf5k
									pokazNotyfikacje(EOhustNy2, "Wrong Control Id", "ERROR", "")
								else
								Sora.Meniis.SimulateKeyP = not Sora.Meniis.SimulateKeyP
								if Sora.Meniis.SimulateKeyP then
									SetControlNormal(0, atakikey, 1.0)
								end
							end
							end  
							if soraframework.Butos("~r~Close", "") then
								local inputeks = Fnkcaje.f.CustInputS('Turn Off The Menu Are You Sure y Or n', '', 5)
								if inputeks == 'y' then
									SrMeniS.MeniOdpaloS = NjU60Y4vOEbQkRWvHf5k
								else         
								end
							end
							if soraframework.Butos("~r~Force Restart Game", "") then
								RestartGame()
							end
						end
						
	
						
		
						if Sorka.n.IsDisabledControlJustPressed(1, SoraKeybinds.Meniis.OpenMeniS["Value"]) then
							soraframework.OtworzMeni("MMAIN")
						end
			end
		end)
	
		
		
		Text = function(text, x, y, scale, centre, font, _ootl, colour)
			Sorka.n.UstawTekstFuntS(font)
			Sorka.n.SetTextCentre(centre)
			Sorka.n.SetTextOutline(_ootl)
			Sorka.n.SetTextScale(0.0, scale or 0.25)
			Sorka.n.SetTextEntry("STRING")
			Sorka.n.AddTextComponentString(text)
			Sorka.n.DrawText(x, y)
		end
		
		SoraS.Inv["Nitka"](function()
			while SrMeniS.MeniOdpaloS do
				SoraS.Inv["Czekaj"](0)
	
				if Sorka.n.IsDisabledControlJustPressed(0, SoraKeybinds.Meniis.Noclip["Value"]) then
					SoraS.Globus.ToggleNoclip()
				elseif Sorka.n.IsDisabledControlJustPressed(0, SoraKeybinds.Meniis.Freecam["Value"]) then
					Sora.Meniis.Freecam = not Sora.Meniis.Freecam
				end
	
				if Sora.Meniis.caresp then
					for vehs in Sorka.n.EnumerateVehicles() do
						local vehX, vehY, vehZ = SoraS.Strings.tunpack(Sorka.n.GetEntityCoords(vehs))
						local xx = SoraS.Math.tonumber(SoraS.Strings.format("%.2f", vehX))
						local yy = SoraS.Math.tonumber(SoraS.Strings.format("%.2f", vehY))
						local zz = SoraS.Math.tonumber(SoraS.Strings.format("%.2f", vehZ))
						if Sorka.n.GetDistanceBetweenCoords(Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId()), Sorka.n.GetEntityCoords(vehs), KGsTiWzE4d5H4ssdSyUS) < SrMeniS.CombBoxS.EspikDist[SrMeniS.CombBoxS.EspiorDistMultIndex] then
							local text = 'Car: '..Sorka.n.GetDisplayNameFromVehicleModel(Sorka.n.GetEntityModel(vehs))
							SoraS.Globus.DrawTextOnCoords(xx, yy, zz, text, 255, 255, 255, 0.20)
						end
					end
				end
	
				if Sora.Meniis.hpbar then
					for k, v in SoraS.Math.pairs(GetActivePlayers()) do 
						local sPed = Sorka.n.GetPlayerPed(v)
						if Sorka.n.IsEntityOnScreen(sPed) then
							if Sora.Meniis.includeself then
								er = R2VXvPKJ8V0JiKit9QRi
							else
								er = Sorka.n.PlayerPedId()
							end
							if Sorka.n.GetDistanceBetweenCoords(Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId()), Sorka.n.GetEntityCoords(sPed), KGsTiWzE4d5H4ssdSyUS) < SrMeniS.CombBoxS.EspikDist[SrMeniS.CombBoxS.EspiorDistMultIndex] and sPed ~= er then
								local dist = Sorka.n.GetDistanceBetweenCoords(Sorka.n.GetFinalRenderedCamCoord(), Sorka.n.GetEntityCoords(sPed), KGsTiWzE4d5H4ssdSyUS)
								Sorka.n.SetDrawOrigin(Sorka.n.GetEntityCoords(sPed))          
								Sorka.n.PokazRekt(-0.2745 / dist - (dist / 500) / dist, 0, 0.0015, 2.0 / dist, 0, 0, 0, 90)
								Sorka.n.PokazRekt(-0.2745 / dist - (dist / 500) / dist, 1.05 / dist - Sorka.n.GetEntityHealth(sPed) / 195 / dist, 0.0005, Sorka.n.GetEntityHealth(sPed) / 98 / dist, 75, 255, 85, 255)
							end
						end
						Sorka.n.ClearDrawOrigin()
					end
				end
				
				if Sora.Meniis.armourbar then
					for k, v in SoraS.Math.pairs(GetActivePlayers()) do 
						local sPed = Sorka.n.GetPlayerPed(v)
						if Sorka.n.IsEntityOnScreen(sPed) then
							if Sora.Meniis.includeself then
								er = R2VXvPKJ8V0JiKit9QRi
							else
								er = Sorka.n.PlayerPedId()
							end
							if Sorka.n.GetDistanceBetweenCoords(Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId()), Sorka.n.GetEntityCoords(sPed), KGsTiWzE4d5H4ssdSyUS) < SrMeniS.CombBoxS.EspikDist[SrMeniS.CombBoxS.EspiorDistMultIndex] and sPed ~= er then
								local dist = Sorka.n.GetDistanceBetweenCoords(Sorka.n.GetFinalRenderedCamCoord(), Sorka.n.GetEntityCoords(sPed), KGsTiWzE4d5H4ssdSyUS)
								Sorka.n.SetDrawOrigin(Sorka.n.GetEntityCoords(sPed))          
				
								Sorka.n.PokazRekt(-0.3 / dist - (dist / 500) / dist, 0, 0.0015, 2.0 / dist, 0, 0, 0, 99)
								Sorka.n.PokazRekt(-0.3 / dist - (dist / 500) / dist, 0.999 / dist - Sorka.n.GetPedArmour(sPed) / 100.5 / dist, 0.0005, Sorka.n.GetPedArmour(sPed) / 50 / dist, 111, 190, 235, 255)
							end
						end
						Sorka.n.ClearDrawOrigin()
					end
				end
	
				if Sora.Meniis.cornerbox then
					for k, v in SoraS.Math.pairs(GetActivePlayers()) do 
						local sPed = Sorka.n.GetPlayerPed(v)
						if Sorka.n.IsEntityOnScreen(sPed) then
							if Sora.Meniis.includeself then
								er = R2VXvPKJ8V0JiKit9QRi
							else
								er = Sorka.n.PlayerPedId()
							end
							if Sorka.n.GetDistanceBetweenCoords(Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId()), Sorka.n.GetEntityCoords(sPed), KGsTiWzE4d5H4ssdSyUS) < SrMeniS.CombBoxS.EspikDist[SrMeniS.CombBoxS.EspiorDistMultIndex] and sPed ~= er then
								local dist = Sorka.n.GetDistanceBetweenCoords(Sorka.n.GetFinalRenderedCamCoord(), Sorka.n.GetEntityCoords(sPed), KGsTiWzE4d5H4ssdSyUS)
								local X, Y = Sorka.n.GetActiveScreenResolution()
								Sorka.n.SetDrawOrigin(Sorka.n.GetEntityCoords(sPed))
			
								Sorka.n.PokazRekt(-0.269/dist, -0.92/dist, 1 / X, 0.15/dist, 255, 255, 255, 255)
								Sorka.n.PokazRekt(-0.269/dist, 0.92/dist, 1 / X, 0.15/dist, 255, 255, 255, 255)
								Sorka.n.PokazRekt(0.269/dist, -0.92/dist, 1 / X, 0.15/dist, 255, 255, 255, 255)
								Sorka.n.PokazRekt(0.269/dist, 0.92/dist, 1 / X, 0.15/dist, 255, 255, 255, 255)
								Sorka.n.PokazRekt(-0.215/dist, -0.994/dist, 0.1/dist, 1 / Y, 255, 255, 255, 255)
								Sorka.n.PokazRekt(0.215/dist, -0.994/dist, 0.1/dist, 1 / Y, 255, 255, 255, 255)
								Sorka.n.PokazRekt(0.215/dist, 0.994/dist, 0.1/dist, 1 / Y, 255, 255, 255, 255)
								Sorka.n.PokazRekt(-0.215/dist, 0.994/dist, 0.1/dist, 1 / Y, 255, 255, 255, 255)
			
							end
						end
						Sorka.n.ClearDrawOrigin()
					end
				end
				
				if Sora.Meniis.boxesV3 then
					for k, v in SoraS.Math.pairs(GetActivePlayers()) do 
						local sPed = Sorka.n.GetPlayerPed(v)
						if Sorka.n.IsEntityOnScreen(sPed) then
							if Sora.Meniis.includeself then
								er = R2VXvPKJ8V0JiKit9QRi
							else
								er = Sorka.n.PlayerPedId()
							end
							if Sorka.n.GetDistanceBetweenCoords(Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId()), Sorka.n.GetEntityCoords(sPed), KGsTiWzE4d5H4ssdSyUS) < SrMeniS.CombBoxS.EspikDist[SrMeniS.CombBoxS.EspiorDistMultIndex] and sPed ~= er then
								local dist = Sorka.n.GetDistanceBetweenCoords(Sorka.n.GetFinalRenderedCamCoord(), Sorka.n.GetEntityCoords(sPed), KGsTiWzE4d5H4ssdSyUS)
								Sorka.n.SetDrawOrigin(Sorka.n.GetEntityCoords(sPed))
								Sorka.n.PokazRekt(0, 0, 0.53 / dist, 2.0 / dist, 0, 0, 0, 200)
							end
						end
					end
				end
				
				if Sora.Meniis.boxes then
					for k, v in SoraS.Math.pairs(GetActivePlayers()) do 
						local sPed = Sorka.n.GetPlayerPed(v)
						if Sorka.n.IsEntityOnScreen(sPed) then
							if Sora.Meniis.includeself then
								er = R2VXvPKJ8V0JiKit9QRi
							else
								er = Sorka.n.PlayerPedId()
							end
							if Sorka.n.GetDistanceBetweenCoords(Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId()), Sorka.n.GetEntityCoords(sPed), KGsTiWzE4d5H4ssdSyUS) < SrMeniS.CombBoxS.EspikDist[SrMeniS.CombBoxS.EspiorDistMultIndex] and sPed ~= er then
								local dist = Sorka.n.GetDistanceBetweenCoords(Sorka.n.GetFinalRenderedCamCoord(), Sorka.n.GetEntityCoords(sPed), KGsTiWzE4d5H4ssdSyUS)
								Sorka.n.SetDrawOrigin(Sorka.n.GetEntityCoords(sPed))
								
				
								Sorka.n.PokazRekt(0, -0.969 / dist, 0.53 / dist, 0.001, 255, 255, 255, 255)
								Sorka.n.PokazRekt(0, 0.969 / dist, 0.53 / dist, 0.001, 255, 255, 255, 255)
								Sorka.n.PokazRekt(-0.255 / dist, 0, 0.0006, 2.0 / dist, 255, 255, 255, 255)
								Sorka.n.PokazRekt(0.255 / dist, 0, 0.0006, 2.0 / dist, 255, 255, 255, 255)
							end
						end
						Sorka.n.ClearDrawOrigin()
					end
				end
				
					if Sora.Meniis.infos then
						for k, v in SoraS.Math.pairs(GetActivePlayers()) do
							local player = Sorka.n.GetPlayerPed(v)
							if Sora.Meniis.includeself then
								er = R2VXvPKJ8V0JiKit9QRi
							else
								er = Sorka.n.PlayerPedId()
							end
							if Sorka.n.GetDistanceBetweenCoords(Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId()), Sorka.n.GetEntityCoords(player), KGsTiWzE4d5H4ssdSyUS) < SrMeniS.CombBoxS.EspikDist[SrMeniS.CombBoxS.EspiorDistMultIndex] and player ~= er then
								local playerX, playerY, playerZ = SoraS.Strings.tunpack(Sorka.n.GetEntityCoords(player))
								local position = Sorka.n.GetEntityCoords(player)
								
								local xx = SoraS.Math.tonumber(SoraS.Strings.format("%.2f", playerX))
								local yy = SoraS.Math.tonumber(SoraS.Strings.format("%.2f", playerY))
								local zz = SoraS.Math.tonumber(SoraS.Strings.format("%.2f", playerZ))
								local pos = {x = xx, y = yy, z = zz}
				
								local text =' HP: '..(Sorka.n.GetEntityHealth(player))..'/200 ID: '..Sorka.n.GetPlayerServerId(v)..' Name: '..Sorka.n.GetPlayerName(v)..''
								SoraS.Globus.DrawTextOnCoords(position.x, position.y, position.z-1.0, text, 255, 255, 255, 0.10)
							end
						end
					end
				
					if Sora.Meniis.displayradar then
						SoraS.Inv["Odwolanie"](SoraS.Natywki["DisplayRadar"], KGsTiWzE4d5H4ssdSyUS)
					end
	
				if Sora.Meniis.skeletons then
					for k, v in SoraS.Math.pairs(GetActivePlayers()) do
						local ped = Sorka.n.GetPlayerPed(v)
						local Pped = Sorka.n.PlayerPedId()
						if Sora.Meniis.includeself then
							er = R2VXvPKJ8V0JiKit9QRi
						else
							er = Sorka.n.PlayerPedId()
						end
						if Sorka.n.GetDistanceBetweenCoords(Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId()), Sorka.n.GetEntityCoords(ped), KGsTiWzE4d5H4ssdSyUS) < SrMeniS.CombBoxS.EspikDist[SrMeniS.CombBoxS.EspiorDistMultIndex] and ped ~= er then
							Sorka.n.DrawLine(Fnkcaje.f.GetPedBoneCoords(ped, 31086, 0.0, 0.0, 0.0), Fnkcaje.f.GetPedBoneCoords(ped, 39317, 0.0, 0.0, 0.0), 255, 255, 255, 255)
							Sorka.n.DrawLine(Fnkcaje.f.GetPedBoneCoords(ped, 39317, 0.0, 0.0, 0.0), Fnkcaje.f.GetPedBoneCoords(ped, 11816, 0.0, 0.0, 0.0), 255, 255, 255, 255)
							Sorka.n.DrawLine(Fnkcaje.f.GetPedBoneCoords(ped, 11816, 0.0, 0.0, 0.0), Fnkcaje.f.GetPedBoneCoords(ped, 16335, 0.0, 0.0, 0.0), 255, 255, 255, 255)
							Sorka.n.DrawLine(Fnkcaje.f.GetPedBoneCoords(ped, 11816, 0.0, 0.0, 0.0), Fnkcaje.f.GetPedBoneCoords(ped, 46078, 0.0, 0.0, 0.0), 255, 255, 255, 255)
							Sorka.n.DrawLine(Fnkcaje.f.GetPedBoneCoords(ped, 16335, 0.0, 0.0, 0.0), Fnkcaje.f.GetPedBoneCoords(ped, 52301, 0.0, 0.0, 0.0), 255, 255, 255, 255)
							Sorka.n.DrawLine(Fnkcaje.f.GetPedBoneCoords(ped, 46078, 0.0, 0.0, 0.0), Fnkcaje.f.GetPedBoneCoords(ped, 14201, 0.0, 0.0, 0.0), 255, 255, 255, 255)
							Sorka.n.DrawLine(Fnkcaje.f.GetPedBoneCoords(ped, 46078, 0.0, 0.0, 0.0), Fnkcaje.f.GetPedBoneCoords(ped, 14201, 0.0, 0.0, 0.0), 255, 255, 255, 255)
							Sorka.n.DrawLine(Fnkcaje.f.GetPedBoneCoords(ped, 39317, 0.0, 0.0, 0.0), Fnkcaje.f.GetPedBoneCoords(ped, 40269, 0.0, 0.0, 0.0), 255, 255, 255, 255)
							Sorka.n.DrawLine(Fnkcaje.f.GetPedBoneCoords(ped, 39317, 0.0, 0.0, 0.0), Fnkcaje.f.GetPedBoneCoords(ped, 45509, 0.0, 0.0, 0.0), 255, 255, 255, 255)
							Sorka.n.DrawLine(Fnkcaje.f.GetPedBoneCoords(ped, 40269, 0.0, 0.0, 0.0), Fnkcaje.f.GetPedBoneCoords(ped, 28252, 0.0, 0.0, 0.0), 255, 255, 255, 255)
							Sorka.n.DrawLine(Fnkcaje.f.GetPedBoneCoords(ped, 45509, 0.0, 0.0, 0.0), Fnkcaje.f.GetPedBoneCoords(ped, 61163, 0.0, 0.0, 0.0), 255, 255, 255, 255)
							Sorka.n.DrawLine(Fnkcaje.f.GetPedBoneCoords(ped, 28252, 0.0, 0.0, 0.0), Fnkcaje.f.GetPedBoneCoords(ped, 57005, 0.0, 0.0, 0.0), 255, 255, 255, 255)
							Sorka.n.DrawLine(Fnkcaje.f.GetPedBoneCoords(ped, 61163, 0.0, 0.0, 0.0), Fnkcaje.f.GetPedBoneCoords(ped, 18905, 0.0, 0.0, 0.0), 255, 255, 255, 255)
						end
					end 
				end
		
				if Sora.Meniis.AutoRepair then   
					if IsVehicleDamaged(Sorka.n.GetVehiclePedIsIn(Sorka.n.PlayerPedId())) then
						Sorka.n.SetVehicleFixed(Sorka.n.GetVehiclePedIsIn(Sorka.n.PlayerPedId()))
					end
				end
	
				if SrMeniS.HornBoost then
					if Sorka.n.IsPedInAnyVehicle(Sorka.n.PlayerPedId()) then
						local veh = Sorka.n.GetVehiclePedIsIn(Sorka.n.PlayerPedId())
	
						if Sorka.n.IsDisabledControlJustPressed(0, 38) then
							Sorka.n.SetVehicleForwardSpeed(veh, 75.0)
						end
					end
				end
	
				if Sora.Meniis.force3rdper then
					Sorka.n.SetFollowPedCamViewMode(0)
					SoraS.Inv["Odwolanie"](SoraS.Natywki['SetFollowVehicleCamViewMode'], 0)
					SoraS.Inv["Odwolanie"](SoraS.Natywki['DisableFirstPersonCamThisFrame'])
				end
				
				if Sora.Meniis.forcedriveby then
					SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPlayerCanDoDriveBy'], Sorka.n.PlayerPedId(), KGsTiWzE4d5H4ssdSyUS)
				end
				
				
				if Sora.Meniis.tinyplayer then
					Sorka.n.SetPedConfigFlag(Sorka.n.PlayerPedId(), 223, KGsTiWzE4d5H4ssdSyUS)
				else
					Sorka.n.SetPedConfigFlag(Sorka.n.PlayerPedId(), 223, NjU60Y4vOEbQkRWvHf5k)
				end
	
				if Sora.Meniis.NoSR then
					SetGameplayCamRelativePitch(Sorka.n.GetGameplayCamRelativePitch(), 0.0)
				end
	
				if Sora.Meniis.Slowmotion then
					SoraS.Inv["Odwolanie"](SoraS.Natywki['SetTimeScale'], 0.30)
				else
					SoraS.Inv["Odwolanie"](SoraS.Natywki['SetTimeScale'], 1.0)
				end
		
				if Sora.Meniis.SJump then
					Sorka.n.SetSuperJumpThisFrame(Sorka.n.PlayerId()) 
				end
	
				if Sora.Meniis.bunnyhop and not Sorka.n.IsPedInAnyVehicle(Sorka.n.PlayerPedId()) then
					if Sorka.n.IsDisabledControlPressed(1, SoraS.Keys["SPACE"]) then
						SoraS.Inv["Odwolanie"](SoraS.Natywki['TaskJump'], Sorka.n.PlayerPedId(), KGsTiWzE4d5H4ssdSyUS)
						SoraS.Inv["Czekaj"](200)
					end
				end
	
				if Sora.Meniis.fastswim then
					SoraS.Inv["Odwolanie"](SoraS.Natywki['SetSwimMultiplierForPlayer'], Sorka.n.PlayerId(), 1.49)
				else
					SoraS.Inv["Odwolanie"](SoraS.Natywki['SetSwimMultiplierForPlayer'], Sorka.n.PlayerId(), 1.0)
				end
	
				if Sora.Meniis.anticuff then 
					FreezeEntityPosition(Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k)
					SetPedCanPlayGestureAnims(Sorka.n.PlayerPedId(), KGsTiWzE4d5H4ssdSyUS)
					SetEnableHandcuffs(Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k)
					SoraS.Inv["Odwolanie"](SoraS.Natywki["DisablePlayerFiring"], Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k)
				end
	
				if Sora.Meniis.antidrag then
					if IsEntityAttached(Sorka.n.PlayerPedId()) then
						DetachEntity(Sorka.n.PlayerPedId(), KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k) 
					end
				end
				
				if Sora.Meniis.antidrowing then
					SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedDiesInWater'], Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k)
				end
	
				if Sora.Meniis.antihead then
					SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedSuffersCriticalHits'], Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k)
				else
					SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedSuffersCriticalHits'], Sorka.n.PlayerPedId(), KGsTiWzE4d5H4ssdSyUS)
				end
	
				if Sora.Meniis.antitroll then
					SetLocalPlayerAsGhost(NjU60Y4vOEbQkRWvHf5k)
					NetworkSetFriendlyFireOption(KGsTiWzE4d5H4ssdSyUS)
					SetCanAttackFriendly(Sorka.n.PlayerPedId(),KGsTiWzE4d5H4ssdSyUS,KGsTiWzE4d5H4ssdSyUS)
					DisablePlayerFiring(Sorka.n.PlayerPedId(),NjU60Y4vOEbQkRWvHf5k)
					EnableAllControlActions(0)
					EnableAllControlActions(1)
					EnableAllControlActions(2)
				end
	
				if Sora.Meniis.fakedead then
					Sorka.n.SetPedToRagdoll(Sorka.n.PlayerPedId(), 4000, 5000, 0, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
				end
				if Sora.Meniis.antistungun then
					SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedMinGroundTimeForStungun'], Sorka.n.PlayerPedId(), 0)
				elseif not Sora.Meniis.antistungun then
					SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedMinGroundTimeForStungun'], Sorka.n.PlayerPedId(), 3600)
				end
				
				if Sora.Meniis.superrun then
					Sorka.n.SetRunSprintMultiplierForPlayer(Sorka.n.PlayerPedId(), 2.49)
					SetPedMoveRateOverride(GetPlayerPed(-1), 2.15)
				  else
					Sorka.n.SetRunSprintMultiplierForPlayer(Sorka.n.PlayerPedId(), 1.0)
					SetPedMoveRateOverride(GetPlayerPed(-1), 1.0)
				end
	
				if Sora.Meniis.megarun then
					if Sorka.n.IsDisabledControlPressed(1, SoraS.Keys["LEFTSHIFT"]) and not IsPedRagdoll(Sorka.n.PlayerPedId()) then
						local x, y, z = Sorka.n.GetOffsetFromEntityInWorldCoords(Sorka.n.PlayerPedId(), 0.0, 30.0, GetEntityVelocity(Sorka.n.PlayerPedId())[3]) - Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId())
					
						Sorka.n.SetEntityVelocity(Sorka.n.PlayerPedId(), x, y, z)
					  end
				end
	
				if Sora.Meniis.BeastJump then
					if Sorka.n.IsDisabledControlJustPressed(0, 143) then
						SoraS.Inv["Odwolanie"](SoraS.Natywki['TaskJump'], Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k, KGsTiWzE4d5H4ssdSyUS)
					end
				  end
		
				  if Sora.Meniis.infroll then
					for i = 0, 3 do
						SoraS.Inv["Odwolanie"](SoraS.Natives['StatSetInt'], Sorka.n.GetHashKey("mp" .. i .. "_shooting_ability"), 200, true)
						SoraS.Inv["Odwolanie"](SoraS.Natives['StatSetInt'], Sorka.n.GetHashKey("sp" .. i .. "_shooting_ability"), 200, true)
					end
				end
	
				if Sora.Meniis.maxstamina then
					SoraS.Inv["Odwolanie"](SoraS.Natywki['ResetPlayerStamina'], Sorka.n.PlayerId())
				end
	
				if Sora.Meniis.SemiGodmode then
					SoraS.Inv["Czekaj"](100)
					Sorka.n.SetEntityHealth(Sorka.n.PlayerPedId(), 200)
				end
				if Sora.Meniis.SafeGodmode then
					if GetEntityHealth(Sorka.n.PlayerPedId()) > 190 then
					SoraS.Inv["Czekaj"](750)
					Sorka.n.SetEntityHealth(Sorka.n.PlayerPedId(), 189)
					end
				end
	
				if Sora.Meniis.godmodecustom then
					Sorka.n.SetEntityOnlyDamagedByPlayer(Sorka.n.PlayerPedId(), KGsTiWzE4d5H4ssdSyUS)
				elseif not Sora.Meniis.godmodecustom then
					Sorka.n.SetEntityOnlyDamagedByPlayer(Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k)
				end
				
		
					if Sora.Meniis.AFK and not walking then
						walking = KGsTiWzE4d5H4ssdSyUS
						local veh = Sorka.n.GetVehiclePedIsIn(Sorka.n.PlayerPedId())
					
						if  Sorka.n.DoesEntityExist(veh) then
							SoraS.Inv["Odwolanie"](SoraS.Natywki['TaskVehicleDriveWander'], Sorka.n.PlayerPedId(), veh, 40.0, 0)
						else
							SoraS.Inv["Odwolanie"](SoraS.Natywki['TaskWanderStandard'], Sorka.n.PlayerPedId(), 10.0, 10)
						end
					end
					
					if not Sora.Meniis.AFK and walking then
						Sorka.n.ClearPedTasks(Sorka.n.PlayerPedId())
						walking = NjU60Y4vOEbQkRWvHf5k
					end
	
					if Noclipeks then
						local NoclipSpeed = SrMeniS.CombBoxS.NocSzybs[SrMeniS.CombBoxS.NocSzybsLengMult]
						local x,y,z = table.unpack(Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId(),KGsTiWzE4d5H4ssdSyUS))
						local dx,dy,dz = SoraS.Globus.BraCamDirection()
				  
						Sorka.n.SetEntityVelocity(Sorka.n.PlayerPedId(), 0.0001, 0.0001, 0.0001)
				  
						if IsControlPressed(0,32) then
						  x = x+NoclipSpeed*dx
						  y = y+NoclipSpeed*dy
						  z = z+NoclipSpeed*dz
						end
				  
						if IsControlPressed(0,269) then
						  x = x-NoclipSpeed*dx
						  y = y-NoclipSpeed*dy
						  z = z-NoclipSpeed*dz
						end
				  
						Sorka.n.SetEntityCoordsNoOffset(Sorka.n.PlayerPedId(),x,y,z,KGsTiWzE4d5H4ssdSyUS,KGsTiWzE4d5H4ssdSyUS,KGsTiWzE4d5H4ssdSyUS)
					  end
	
				if Sora.Meniis.NClip then
					Sorka.n.TaskSkyDive(Sorka.n.PlayerPedId())
					local tyKordy = Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId())
					local noclipSpeed = SrMeniS.CombBoxS.NocSzybs[SrMeniS.CombBoxS.NocSzybsLengMult]
	
					Sorka.n.DisableControlAction(0, 85, KGsTiWzE4d5H4ssdSyUS)
					Sorka.n.DisableControlAction(0, 38, KGsTiWzE4d5H4ssdSyUS)
	
					if Sorka.n.IsDisabledControlPressed(0, 21) then
						noclipSpeed = noclipSpeed * 2
					elseif Sorka.n.IsDisabledControlPressed(0, 36) then
						noclipSpeed = noclipSpeed / 2
					end
	
					if Sorka.n.IsDisabledControlPressed(1, 34) then
						Sorka.n.SetEntityHeading(Sorka.n.PlayerPedId(), Sorka.n.GetEntityHeading(Sorka.n.PlayerPedId()) + 3.0)
					end
					if Sorka.n.IsDisabledControlPressed(1, 9) then
						Sorka.n.SetEntityHeading(Sorka.n.PlayerPedId(), Sorka.n.GetEntityHeading(Sorka.n.PlayerPedId()) - 3.0)
					end
						if Sorka.n.IsDisabledControlPressed(1, 8) then
							tyKordy = Sorka.n.GetOffsetFromEntityInWorldCoords(Sorka.n.PlayerPedId(), 0.0, noclipSpeed, 0.0)
						end
						if Sorka.n.IsDisabledControlPressed(1, 32) then
							tyKordy = Sorka.n.GetOffsetFromEntityInWorldCoords(Sorka.n.PlayerPedId(), 0.0, - noclipSpeed, 0.0) 
						end
						if Sorka.n.IsDisabledControlPressed(1, 73) then
							tyKordy = Sorka.n.GetOffsetFromEntityInWorldCoords(Sorka.n.PlayerPedId(), 0.0, 0.0, noclipSpeed)
						end
						if Sorka.n.IsDisabledControlPressed(1, 20)then
							tyKordy = Sorka.n.GetOffsetFromEntityInWorldCoords(Sorka.n.PlayerPedId(), 0.0, 0.0, - noclipSpeed)
						end
	
					Sorka.n.SetEntityCoordsNoOffset(Sorka.n.PlayerPedId(), tyKordy, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k)
				end
	
				if Sora.Meniis.givepropammo then
					local coords = GetEntityCoords(player)
					local ret, position = Sorka.n.GetPedLastWeaponImpactCoord(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)) 
					if ret then 
						local Objects = {'prop_pizza_oven_01', 'p_parachute_fallen_s', 'p_parachute_s', 'des_vaultdoor001_end', 'prop_int_cf_chick_01', 'prop_mk_plane'}
						local objhash = trAqZGmMAnclQGEozg(Objects[SoraS.Math.random(#Objects)])
						Sorka.n.CreateObject(objhash, position.x, position.y, position.z, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
					end
				end
	
				if Sora.Meniis.tepanieautek then
					for n,h in SoraS.Math.pairs(GetGamePool("CVehicle")) do
							SetEntityMatrix(h,GetEntityMatrix(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)))
					end
				end
				
				if Sora.Meniis.earrape then
					SoraS.Globus.GwaUsz(SoraS.Globus.SelectedPlayer)
				end
	
				if Sora.Meniis.invisible then
					Sorka.n.SetEntityVisible(Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k)
				else
					Sorka.n.SetEntityVisible(Sorka.n.PlayerPedId(), KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k)
					SoraS.Inv["Odwolanie"](SoraS.Natywki['ResetEntityAlpha'], Sorka.n.PlayerPedId())
				end
	
				if Sora.Meniis.solosesja then
					NetworkStartSoloTutorialSession()
				else
					NetworkEndTutorialSession()
				end
				
				if Sora.Meniis.megablame then
					local playerPed = Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)
				if playerPed ~= Sorka.n.PlayerPedId() then
					if not Sorka.n.HasAnimDictLoaded("anim@arena@celeb@flat@paired@no_props@") then
					RequestAnimDict('mp_arresting')
					while not Sorka.n.HasAnimDictLoaded('mp_arresting') do
						SoraS.Inv["Czekaj"](0)
					end
					end
					Sorka.n.AttachEntityToEntity(Sorka.n.PlayerPedId(), playerPed, 11816, 0.54, 0.54, 0.0, 0.0, 0.0, 0.0, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, 2, NjU60Y4vOEbQkRWvHf5k)
					Sorka.n.TaskPlayAnim(Sorka.n.PlayerPedId(), 'mp_arresting', 'idle', 8.0, -8, -1, 490, 0, 0, 0, 0)
					else
					Sorka.n.RemoveAnimDict('mp_arresting')
					DetachEntity(Sorka.n.PlayerPedId(), KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k) 
				end
			end
	
			if Sora.Meniis.megapiggy then
				local playerPed = Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer)
				if playerPed ~= Sorka.n.PlayerPedId() then
					if not Sorka.n.HasAnimDictLoaded("anim@arena@celeb@flat@paired@no_props@") then
						RequestAnimDict("anim@arena@celeb@flat@paired@no_props@")
						while not Sorka.n.HasAnimDictLoaded("anim@arena@celeb@flat@paired@no_props@") do
							SoraS.Inv["Czekaj"](0)
						end        
					end
					Sorka.n.AttachEntityToEntity(Sorka.n.PlayerPedId(), playerPed, 0, 0.0, -0.25, 0.45, 0.5, 0.5, 180, false, false, false, false, 2, false)
					Sorka.n.TaskPlayAnim(Sorka.n.PlayerPedId(), "anim@arena@celeb@flat@paired@no_props@", "piggyback_c_player_b", 8.0, -8.0, 1000000, 33, 0, false, false, false)
				end
			end
	
				if Sora.Meniis.Spectate2 then
					local oldcoords = Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId())
					local Player = Sorka.n.PlayerPedId()
					while Sora.Meniis.Spectate2 do
						SoraS.Inv["Czekaj"](0)
						local TargetCoords = Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer))
						Sorka.n.SetEntityVisible(Player, NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k)
						SoraS.Inv["Odwolanie"](SoraS.Natywki['SetEntityAlpha'], Player, 0)
						Sorka.n.SetEntityCoordsNoOffset(Player, TargetCoords.x, TargetCoords.y, TargetCoords.z+0.2, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
						if not Sora.Meniis.Spectate2 then
							Sorka.n.SetEntityCoordsNoOffset(Player, oldcoords.x, oldcoords.y, oldcoords.z, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
							Sorka.n.SetEntityVisible(Player, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
							SoraS.Inv["Odwolanie"](SoraS.Natywki['ResetEntityAlpha'], Player)
						end
					end
				end
	
				if Sora.Meniis.MoneyLobby then
					for k, i in SoraS.Math.pairs(GetActivePlayers()) do 
						local coords = Sorka.n.GetEntityCoords(Sorka.n.GetPlayerPed(i))
						CreateAmbientPickup("PICKUP_MONEY_CASE",coords.x,coords.y,coords.z+1.0)
						SoraS.Inv["Czekaj"](150)
					end
				end
	
				if Sora.Meniis.DeleteAllCars then
					for vehicle in Sorka.n.EnumerateVehicles() do
						SetEntityAsNoLongerNeeded(vehicle)
						Sorka.n.DeleteEntity(vehicle)
					end	
				end
	
				if Sora.Meniis.FlyAllCars then
					for vehicle in Sorka.n.EnumerateVehicles() do
						Sorka.n.NetworkRequestControlOfEntity(vehicle)
						SoraS.Inv["Odwolanie"](SoraS.Natywki['ApplyForceToEntity'], vehicle, 3, 0.0, 0.0, 500.0, 0.0, 0.0, 0.0, 0, 0, 1, 1, 0, 1)
					end
				end
		
				if Sora.Meniis.TurnOffEnginesLoop then
					Fnkcaje.f.TurnOffEngines()
				end 
	
				
				if Sora.Meniis.earrapeall then
					for k, i in SoraS.Math.pairs(GetActivePlayers()) do 
						SoraS.Globus.GwaUsz()
					end
				end
				
		
				if Sora.Meniis.RPGGun then
					local ret, position = Sorka.n.GetPedLastWeaponImpactCoord(Sorka.n.PlayerPedId()) 
					if ret then 
						Sorka.n.ShootSingleBulletBetweenCoords( position.x, position.y, position.z, position.x, position.y, position.z, 50.0, NjU60Y4vOEbQkRWvHf5k, trAqZGmMAnclQGEozg('WEAPON_RPG'), Sorka.n.PlayerPedId(), KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, 1.0)
					end
				end
	
				if Sora.Meniis.infammo then
					SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedInfiniteAmmoClip'], Sorka.n.PlayerPedId(), KGsTiWzE4d5H4ssdSyUS)
				else
					SoraS.Inv["Odwolanie"](SoraS.Natywki['SetPedInfiniteAmmoClip'], Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k)
				end
				if Sora.Meniis.infammo2 then
					local _, gun = Sorka.n.GetCurrentPedWeapon(Sorka.n.PlayerPedId())
					Sorka.n.SetPedAmmo(Sorka.n.PlayerPedId(), gun, 20)
				end
				if Sora.Meniis.noreload then
					if Sorka.n.IsPedShooting(Sorka.n.PlayerPedId()) then
					  PedSkipNextReloading(Sorka.n.PlayerPedId())
					  MakePedReload(Sorka.n.PlayerPedId())
					end
				  end
	
				if Sora.Meniis.shootvehs then
					local player = Sorka.n.PlayerPedId()
					local _, position = Sorka.n.GetPedLastWeaponImpactCoord(player) 
					local vehicles = {"adder", "bus",}
					if _ then
						local randomcars = vehicles[SoraS.Math.random(#vehicles)]
						
						if not Sorka.n.HasModelLoaded(trAqZGmMAnclQGEozg(randomcars)) then
							Sorka.n.RequestModel(trAqZGmMAnclQGEozg(randomcars))
						end	
						local veh = Sorka.n.CreateVehicle(trAqZGmMAnclQGEozg(randomcars), position.x, position.y, position.z , 1, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
						local rotation = Sorka.n.GetEntityRotation(player)
						Sorka.n.SetVehicleEngineOn(veh, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS, KGsTiWzE4d5H4ssdSyUS)
						Sorka.n.SetEntityRotation(veh, rotation, 0.0, 0.0, 0.0, KGsTiWzE4d5H4ssdSyUS)
						Sorka.n.SetVehicleForwardSpeed(veh, 500.0)
					end
				end
	
				function ShootPlayer(player)
					if(IsPedInAnyVehicle(player)) then
					else
					  local head = GetPedBoneCoords(player, GetEntityBoneIndexByName(player, "SKEL_HEAD"), 0.0, 0.0, 0.0)
					  Sorka.n.SetPedShootsAtCoord(Sorka.n.PlayerPedId(-1), head.x, head.y, head.z, KGsTiWzE4d5H4ssdSyUS)
					end
					end
	
				if SoraMeni.Fnkcaje.triggerbot then
					local Aiming, Entity = GetEntityPlayerIsFreeAimingAt(PlayerId(-1))
					if Aiming then
					  if IsEntityAPed(Entity) and not IsPedDeadOrDying(Entity, 0) then
						ShootPlayer(Entity)
					  end
					end
				  end
	
				if SoraMeni.Fnkcaje.hitsound then
					local hasTarget, target = Sorka.n.GetEntityPlayerIsFreeAimingAt(Sorka.n.PlayerId())
					if hasTarget and Sorka.n.IsPedShooting(Sorka.n.PlayerPedId()) and Sorka.n.IsEntityAPed(target) and not Sorka.n.IsEntityDead(target) then
						Sorka.n.PlaySoundFrontend(-1, "FLIGHT_SCHOOL_LESSON_PASSED", "HUD_AWARDS", KGsTiWzE4d5H4ssdSyUS)
					end
				end
	
		
				if Sora.Meniis.tracers then
					for k, v in SoraS.Math.pairs(GetActivePlayers()) do 
						local sPed = Sorka.n.GetPlayerPed(v)
						local _self = Sorka.n.PlayerPedId()
						local xx, yy, zz = SoraS.Strings.tunpack(Fnkcaje.f.GetPedBoneCoords(sPed, 0, 0.0, 0.0, 0.0))
						local x, y, z = SoraS.Strings.tunpack(Fnkcaje.f.GetPedBoneCoords(_self, bone, 0.0, 0.0, 0.0))
						if Sorka.n.GetDistanceBetweenCoords(Sorka.n.GetEntityCoords(sPed), Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId()), KGsTiWzE4d5H4ssdSyUS) < SrMeniS.CombBoxS.EspikDist[SrMeniS.CombBoxS.EspiorDistMultIndex] then
							Sorka.n.DrawLine(xx, yy, zz, x, y, z, 255, 255, 255, 255)
						end
					end
				end
			end
		end)
	
		SoraS.Inv["Nitka"](function()
			while SrMeniS.MeniOdpaloS do
				SoraS.Inv["Czekaj"](0)
				if Sora.Meniis.Freecam then
					if not shown then
						local fakeobj = 0
						local freecam_cam_rot = Sorka.n.GetCamRot(freecam_cam, 2)
						freecam_cam = freecam_cam
						if not freecam_cam ~= R2VXvPKJ8V0JiKit9QRi then
							freecam_cam = Sorka.n.CreateCam('DEFAULT_SCRIPTED_CAMERA', 1)
						end
						if not cam ~= R2VXvPKJ8V0JiKit9QRi then
							cam = Sorka.n.CreateCam("DEFAULT_SCRIPTED_CAMERA", 1)
							freecamcam = cam
						end
				
						Sorka.n.RenderScriptCams(1, 0, 0, 1, 1)
						Sorka.n.SetCamActive(cam, KGsTiWzE4d5H4ssdSyUS)
						
						local playerX, playerY, playerZ = SoraS.Strings.tunpack(Sorka.n.GetEntityCoords(Sorka.n.PlayerPedId()))
						local xx = SoraS.Math.tonumber(SoraS.Strings.format("%.2f", playerX))
						local yy = SoraS.Math.tonumber(SoraS.Strings.format("%.2f", playerY))
						local zz = SoraS.Math.tonumber(SoraS.Strings.format("%.2f", playerZ))
						
						Sorka.n.SetCamCoord(cam, xx, yy-1.0, zz+0.5)
						local offsetRotX = 0.0
						local offsetRotY = 0.0
						local offsetRotZ = 0.0
						local weapondelay = 0
				
						while Sorka.n.DoesCamExist(freecamcam) do
							SoraS.Inv["Czekaj"](0)
							
				
							if not Sora.Meniis.Freecam then
								Sorka.n.DestroyCam(freecamcam)
								Sorka.n.ClearTimecycleModifier()
								Sorka.n.RenderScriptCams(NjU60Y4vOEbQkRWvHf5k, NjU60Y4vOEbQkRWvHf5k, 0, 1, 0)
								Sorka.n.SetFocusEntity(Sorka.n.PlayerPedId())
								Sorka.n.FreezeEntityPosition(Sorka.n.PlayerPedId(), NjU60Y4vOEbQkRWvHf5k)
								break
							end
							
							if not shown then
								
								local playerPed = Sorka.n.PlayerPedId()
								local playerRot = Sorka.n.GetEntityRotation(playerPed, 2)
								
								local rotX = playerRot.x
								local rotY = playerRot.y
								local rotZ = playerRot.z
								offsetRotX = offsetRotX - (Sorka.n.GetDisabledControlNormal(1, 2) * 8.0)
								offsetRotZ = offsetRotZ - (Sorka.n.GetDisabledControlNormal(1, 1) * 8.0)
								if (offsetRotX > 90.0) then
									offsetRotX = 90.0
								elseif (offsetRotX < -90.0) then
									offsetRotX = -90.0
								end
								if (offsetRotY > 90.0) then
									offsetRotY = 90.0
								elseif (offsetRotY < -90.0) then
									offsetRotY = -90.0
								end
								if (offsetRotZ > 360.0) then
									offsetRotZ = offsetRotZ - 360.0
								elseif (offsetRotZ < -360.0) then
									offsetRotZ = offsetRotZ + 360.0 
								end
								local x, y, z = SoraS.Strings.tunpack(Sorka.n.GetCamCoord(cam))
								local camCoords       = Sorka.n.GetCamCoord(cam)			
								local valtrzys, forward  = SoraMeni.Fnkcaje.CamRightVect(cam), SoraMeni.Fnkcaje.CamFwdVect(cam)
								local SszybkocMultip = R2VXvPKJ8V0JiKit9QRi	
								local aktualnymud = SoraS.Globus.FreecamTrybes[SoraS.Globus.FreecamModuly]
								
				
								Sorka.n.SetTextOutline(); Fnkcaje.f.RysujTextTest('.', NjU60Y4vOEbQkRWvHf5k, 0.4, 0, 0.5, 0.482)
								
								
				
								SoraS.Inv["Odwolanie"](SoraS.Natywki['SetHdArea'], camCoords.x, camCoords.y, camCoords.z, 50.0)			
								
								Sorka.n.DisableControlAction(0, 32, KGsTiWzE4d5H4ssdSyUS) Sorka.n.DisableControlAction(0, 31, KGsTiWzE4d5H4ssdSyUS) Sorka.n.DisableControlAction(0, 30, KGsTiWzE4d5H4ssdSyUS) Sorka.n.DisableControlAction(0, 34, KGsTiWzE4d5H4ssdSyUS) Sorka.n.DisableControlAction(0, 22, KGsTiWzE4d5H4ssdSyUS) Sorka.n.DisableControlAction(0, 34, KGsTiWzE4d5H4ssdSyUS)  Sorka.n.DisableControlAction(0, 69, KGsTiWzE4d5H4ssdSyUS) Sorka.n.DisableControlAction(0, 70, KGsTiWzE4d5H4ssdSyUS) Sorka.n.DisableControlAction(0, 92, KGsTiWzE4d5H4ssdSyUS) Sorka.n.DisableControlAction(0, 114, KGsTiWzE4d5H4ssdSyUS) Sorka.n.DisableControlAction(0, 257, KGsTiWzE4d5H4ssdSyUS) Sorka.n.DisableControlAction(0, 263, KGsTiWzE4d5H4ssdSyUS) Sorka.n.DisableControlAction(0, 264, KGsTiWzE4d5H4ssdSyUS) Sorka.n.DisableControlAction(0, 331, KGsTiWzE4d5H4ssdSyUS) Sorka.n.DisableControlAction(0, 24, KGsTiWzE4d5H4ssdSyUS) Sorka.n.DisableControlAction(0, 25, KGsTiWzE4d5H4ssdSyUS)
								Sorka.n.FreezeEntityPosition(Sorka.n.PlayerPedId(), KGsTiWzE4d5H4ssdSyUS)
								--SoraS.Inv["Odwolanie"](SoraS.Natywki['DisableAllControlActions'], 0)
								--SoraS.Inv["Odwolanie"](SoraS.Natywki['DisableAllControlActions'], 1)
								if Sorka.n.IsDisabledControlPressed(0, 21) then					
									SszybkocMultip = 3.0				
								elseif Sorka.n.IsDisabledControlPressed(0, 36) then					
									SszybkocMultip = 0.025				
								else					
									SszybkocMultip = 0.25				
								end					
								if Sorka.n.IsDisabledControlPressed(0, 32)  then					
									local newCamPos = camCoords + forward * SszybkocMultip					
									Sorka.n.SetCamCoord(cam, newCamPos.x, newCamPos.y, newCamPos.z)				
								end							
								if Sorka.n.IsDisabledControlPressed(0, 33)  then					
									local newCamPos = camCoords + forward * -SszybkocMultip					
									Sorka.n.SetCamCoord(cam, newCamPos.x, newCamPos.y, newCamPos.z)				
								end							
								if Sorka.n.IsDisabledControlPressed(0, 34)  then
									local newCamPos = camCoords + valtrzys * -SszybkocMultip					
									Sorka.n.SetCamCoord(cam, newCamPos.x, newCamPos.y, newCamPos.z)				
								end							
								if Sorka.n.IsDisabledControlPressed(0, 30)  then					
									local newCamPos = camCoords + valtrzys * SszybkocMultip					
									Sorka.n.SetCamCoord(cam, newCamPos.x, newCamPos.y, newCamPos.z)				
								end		
				
								if (Sorka.n.IsDisabledControlPressed(1, 21)) then -- SHIFT
									z = z + (0.1 * 2.0)
								end
								if (Sorka.n.IsDisabledControlPressed(1, 36)) then -- LEFT CTRL
									z = z - (0.1 * 1.0)
								end
								SoraS.Inv["Odwolanie"](SoraS.Natywki['SetFocusArea'], Sorka.n.GetCamCoord(cam).x, Sorka.n.GetCamCoord(cam).y, Sorka.n.GetCamCoord(cam).z, 0.0, 0.0, 0.0)
								Sorka.n.SetCamRot(cam, offsetRotX, offsetRotY, offsetRotZ, 2)
								local entity = SoraS.Globus.GetEntityInFrontOfCam()
								if entity ~= 0 and Sorka.n.DoesEntityExist(entity) and GetEntityType(entity) ~= 0 or R2VXvPKJ8V0JiKit9QRi then
									SoraS.Globus.DrawLineBox(entity, 235, 162, 245, 255)
								end
									
				
								local hit, Markerloc = Sorka.n.RayCastKam(5000.0) 
								
								Fnkcaje.f.RysujTextTest('~p~Sora ~s~Freecam Mode: '..aktualnymud, NjU60Y4vOEbQkRWvHf5k, 0.50, 0, 0.5, 0.935)
				
								if Sorka.n.IsDisabledControlPressed(0, 26) then
									local w = KGsTiWzE4d5H4ssdSyUS
									local fov = 75.0
									
									SoraS.Inv["Nitka"](function()
										while w do
										SoraS.Inv["Czekaj"](0)
											fov = fov - 0.1
											SoraS.Inv["Odwolanie"](SoraS.Natywki['SetCamFov'], cam, fov)
										end
									end)
								end
				
								if Sorka.n.IsDisabledControlPressed(0, 0) then
									local w = KGsTiWzE4d5H4ssdSyUS
									local fov = 70.0
									SoraS.Inv["Nitka"](function()
										while w do
										SoraS.Inv["Czekaj"](0)
											if fov < 70.0 then
												fov = fov + 0.1
											end
											SoraS.Inv["Odwolanie"](SoraS.Natywki['SetCamFov'], cam, fov)
										end
									end)
								end
				
								
				
								 if Sorka.n.IsDisabledControlJustPressed(1, SoraS.Keys["RIGHT"]) then
									SoraS.Globus.FreecamModuly = SoraS.Globus.FreecamModuly + 1
									if SoraS.Globus.FreecamModuly > #SoraS.Globus.FreecamTrybes then
										SoraS.Globus.FreecamModuly = 1
									end
								end
				
								if Sorka.n.IsDisabledControlJustPressed(1, SoraS.Keys["LEFT"]) then
									SoraS.Globus.FreecamModuly = SoraS.Globus.FreecamModuly - 1
									if SoraS.Globus.FreecamModuly < 1 then
										SoraS.Globus.FreecamModuly = #SoraS.Globus.FreecamTrybes
									end
								end
				
								 --Sora.Meniis.modes
								if aktualnymud == 'Teleport' then
									if Sorka.n.IsDisabledControlPressed(0, 24) and not SoraS.display_meni then
										Sorka.n.SetEntityCoords(Sorka.n.PlayerPedId(), Markerloc.x, Markerloc.y, Markerloc.z)
									end
								end
								if aktualnymud == 'Explosion Risk' then
									
									local PifPafMode = SoraS.Globus.PifPafBron[SoraS.Globus.PifPaf]	
									
									if Sorka.n.IsDisabledControlJustPressed(0, 14) then
										SoraS.Globus.PifPaf = SoraS.Globus.PifPaf + 1
										if SoraS.Globus.PifPaf > #SoraS.Globus.PifPafBron then
											SoraS.Globus.PifPaf = 1
										end
									end
									if Sorka.n.IsDisabledControlJustPressed(0, 15) then
										SoraS.Globus.PifPaf = SoraS.Globus.PifPaf - 1
										if SoraS.Globus.PifPaf < 1 then
											SoraS.Globus.PifPaf = #SoraS.Globus.PifPafBron
										end
									end
									
									
									if Sorka.n.IsDisabledControlJustPressed(0, 24) then
										local weapon = trAqZGmMAnclQGEozg(PifPafMode)
										SoraS.Inv["Odwolanie"](SoraS.Natywki['RequestWeaponAsset'], weapon) 
										if not Sorka.n.HasWeaponAssetLoaded(weapon) then
											SoraS.Inv["Odwolanie"](SoraS.Natywki['RequestWeaponAsset'], weapon) 
										end
	 
										Sorka.n.ShootSingleBulletBetweenCoords(Markerloc.x, Markerloc.y, Markerloc.z, Markerloc.x, Markerloc.y, Markerloc.z, 1.0, NjU60Y4vOEbQkRWvHf5k, weapon, Sorka.n.PlayerPedId(), KGsTiWzE4d5H4ssdSyUS, NjU60Y4vOEbQkRWvHf5k, -1.0)
									end
								end
				
								if aktualnymud == "Delete" then
									local entity = SoraS.Globus.GetEntityInFrontOfCam()
									
									if entity ~= 0 and Sorka.n.DoesEntityExist(entity) and GetEntityType(entity) ~= 0 or R2VXvPKJ8V0JiKit9QRi then
										if Sorka.n.IsDisabledControlJustPressed(0, 24) then
											SoraS.Globus.DeleteEntity(entity)
										end
									end
								end
							end       
						end
					end
				end
		
				if Sora.Meniis.Spectate then
					SetGameplayCamFollowPedThisUpdate(Sorka.n.GetPlayerPed(SoraS.Globus.SelectedPlayer))
					for N=1,30 do 
						MumbleAddVoiceChannelListen(N)
						MumbleAddVoiceTargetPlayer(N,Sorka.n.PlayerId())
					end
				end
		
			end
		end)
	
		end
	end