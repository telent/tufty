local tftp = {}
local TIMEOUT = .1
local ACK_RETRIES = math.huge or 1000
local TFTP_PORT = 6969
local BLKSIZE = 512

local OP_RRQ = 1
local OP_WRQ = 2
local OP_DATA = 3
local OP_ACK = 4
local OP_ERR = 5
local ACKSIZE = 4

local ERR_NOTFOUND = 1
local ERR_ACCESS = 2
local ERR_ALLOC = 3
local ERR_ILLEGAL_OP = 4
local ERR_UNKNOWN_ID = 5
local ERR_EXISTS = 6
local ERR_WHO = 7

pcall(require, 'pl')
local log=print
local p=pretty and pretty.dump or print

local time = (function()
    local okay, nixio = pcall(require, "nixio")
    if okay then
        local gettimeofday = nixio.gettimeofday
        return function()
            local secs, usecs = gettimeofday()
            return secs + (usecs / 1e6)
        end
    else
        local socket = require("socket")
        local gettime = socket.gettime
        return function()
            return gettime()
        end
    end
end)()

local poll = (function()
    --[[
    ``poll`` is expected to accept and return a list of sockets keyed by backend file descriptor formatted as follows:
    {
        [low level socket lib userdata file descriptor]{
            fd=(low level socket lib userdata file descriptor)
            wantread=(bool)
            wantwrite=(bool)
            readable=(bool)
            writeable=(bool)
            ...arbitrary ignored extra fields
        },
        ...
    }]]

    local okay, nixio = pcall(require, "nixio")
    if okay then 
        return function(fds, timeout)
            --[[
                wait for the events in ``waitfor`` to become available on on or more sockets given in ``fds``
            
            POLLOUT writing to the socket is now possible
            POLLIN there is data to read
            ]]
            timeout = timeout or -1
            waitfor = waitfor or {}
            
            for _, fd in pairs(fds) do
                fds[#fds+1] = {fd=fd.fd, events=nixio.poll_flags(unpack{fd.wantread and 'in', fd.wantwrite and 'out'})}
            end
            local count, ready = nixio.poll(fds, timeout)
            p{count=count, ready=ready}
            if count == 0 then   --timeout
                return {}
            end
            if ready == nil then return {} end
            for i,fd  in ipairs(ready) do
                local revents = nixio.poll_flags(fd.revents)
                fd.revents = nil
                fds[fd.fd].readable = revents["in"]
                fds[fd.fd].writable = revents["out"]
                fds[i] = nil
            end
            return fds
        end
    end

    local luasocket = require("socket")
    return function(fds, timeout)
        local wantread = {}
        local wantwrite = {}
        for _, fd  in pairs(fds) do
            fd.readable=false
            fd.writable=false
            if fd.wantwrite then wantwrite[#wantwrite + 1] = fd.fd end
            if fd.wantread then  wantread[#wantread + 1] = fd.fd end
        end
        local readable, writeable, timedout = luasocket.select(wantread, wantwrite, timeout)
        if timedout then return nil end
        for key, val in pairs(fds) do
            if readable[key] == 1 then fds[key].readable = true end
            if writeable[key] == 1 then fds[key].writeable = true end
        end
        return fds
    end
end)()

local function UDPSocket()
    --[[ We want to support the basic functionality required for TFTP operation over
        UDP with either nixio (OpenWRT LuCI) or luasocket (everywhere else).
        This wraps only the required functionality and in no way represents a
        complete UDP socket implementation.
        see http://w3.impa.br/~diego/software/luasocket/udp.html for the luasocket UDP API
        and http://luci.subsignal.org/api/nixio/modules/nixio.Socket.html for nixio.
    ]]
    local okay, luasocket = pcall(require, "socket")
    if okay then return {
        fd = luasocket.udp(),
        bind = function(self, address, port)
            return self.fd:setsockname(address, port)
        end,
        sendto = function(self, data, address, port)
            return self.fd:sendto(data, address, port)
        end,
        recvfrom = function(self, length)
            return self.fd:receivefrom(length)
        end,
        close = function(self)
            return self.fd:close()
        end,
    }
    end
    local nixio = require("nixio")
    return {fd=nixio.socket("inet", "dgram"),
        bind = function(self, address, port)
            return self.fd:bind(address, port)
        end,
        sendto = function(self, data, address, port)
            return self.fd:sendto(data, address, port)
        end,
        recvfrom = function(self, length)
            return self.fd:recvfrom(length)
        end,
        close = function(self)
            return self.fd:close()
        end,
    }
end

local function is_netascii(s)
    --[[Check whether a string contains only characters from the RFC764 ascii 
    subset. see https://tools.ietf.org/html/rfc764#page-11
    ]]
    local ctrls = {[0]=1, [10]=1, [13]=1, [7]=1, [8]=1, [9]=1, [11]=1, [12]=1}
    for i=1, #s do
        local byte = s:sub(i, i):byte()
        if (byte < 31 and ctrls[byte] == nil) or byte > 127 then
            return false
        end
    end
    return true
end

local function create_opcode(val)
    if val < 0 or val > 2^16-1 then error("opcodes must fit into a 16bit integer") end
    local high = math.floor(val / 256)
    -- RFC1350 doesn't mention byte order.  Assume network order (big-endian).
    return string.char(high, val - (high * 256))
end

local function parse_opcode(packet)
    local opcode = string.byte(packet:sub(2, 2)) --assume big endian
    return ({"RRQ", "WRQ", "DATA", "ACK", "ERROR"})[opcode]
end

function tftp:handle_RRQ(socket, host, port, source)
    local sequence_no = 1
    local time = time
    local started = time()
    local err = self.ERROR
    local error = error
    local yield = coroutine.yield
    local success = error -- to terminate the coroutine immediately, raise an error

    return coroutine.create(function()
        while true do
            if sequence_no >= 2^16 then 
                socket:sendto(err("File too big."), host, port)
                error("File too big.")
            end
            local okay, continue, data = pcall(source)
            if not okay then
                packet = socket:sendto(err("An unknown error occurred"), host, port)
                error("generator failure")
            end
            if data == nil and not continue then
                socket:sendto(err("Transfer complete."), host, port)
                success()
            end
            if data == nil and continue then
                --[[ 
                    The generator ``source`` can be async and return `true, nil`
                    if no data is ready, but things are going well.
                ]]
                print("generator not ready. Will defer...")
                yield(false, true)              
            end
            socket:sendto(self.DATA(data, sequence_no), host, port)
            if #data < 512 then
                log(("transfer completed in %.2fs"):format(time() - started))
                success()
            end
            yield(true, false) -- we need to wait until the socket is readable again
            --[[  Now check for an ACK.
                RFC1350 requires that for every packet sent, an ACK is received 
                before the next packet can be sent.
            ]]
            local acked
            local retried = 0
            local timeout = time() + TIMEOUT
            local timedout = false
            repeat
                local ack, ackhost, ackport = socket:recvfrom(ACKSIZE)
                if ack == false then -- wouldblock
                    yield(true, false)  --we want to be able to read on the scoket.
                elseif ackhost ~= host or ackport ~= port or self.parse_ACK(ack) ~= sequence_no then
                   --[[https://tools.ietf.org/html/rfc1350#page-5
                       "If a source TID does not match, the packet should be
                       discarded as erroneously sent from somewhere else.
                       An error packet should be sent to the source of the 
                       incorrect packet, while not disturbing the transfer."
                   ]]
                   log("RECEIVED UNKOWN PACKET", ack, ackhost, ackport, 'TID:', self.parse_ACK(ack))
                   socket:sendto(err(ERR_UNKNOWN_ID), ackhost, ackport)
                   yield(true, false)
                else 
                    acked = true
                end
                retried = retried + 1
                timedout = time() > timeout
            until acked or retried > ACK_RETRIES or timedout
            if timedout or retried > ACK_RETRIES then
                --There doesn't seem to be a standard error for timeout
                socket:sendto(err("Ack timeout"), host, port)
                error("Timeout waiting for ACK")
            end
            --Okay, we've been acked in reasonable time.
            sequence_no = sequence_no + 1
            yield(true, true)
        end 
    end)
end

function tftp:handle_WRQ(socket, host, port, sink)
    error"Not Implemented"
end

function tftp:listen(rrq_generator_callback, wrq_generator_callback, hosts, port)
--[[--
    Listen for TFTP requests on UDP ```bind``:`port`` (0.0.0.0:69 by default)
    and get data from / send data to user-generated source/sink functions.
    Data is generated/received by functions returned by the the user-supplied 
    ``rrq_generator_callback``/``wrq_generator_callback`` factory functions.
    For every valid request packet received the generator function returned by 
    ``xrq_generator_callback`` will be called expecting data.
    
    When called with a single argument,
        (the requested resource as a C-style string (no embedded NUL chars)) 
    ``xrq_generator_callback`` should return a source or sink function that: 
        (SOURCE) takes no arguments and returns blocks of data until complete.
            must return as follows
                `true, data` on success
                `true, nil` on wouldblock but should continue, 
                `false` on finished
        (SINK) takes two arguments
            ``data`` to write
            ``done`` (truthy), whether all data has been received and backends can cleanup.
    
    The (SOURCE) model therefore supports both blocking and non-blocking behaviour.
    If the given function blocks, however, it will block the whole process as Lua
    is single threaded. That may or may not be acceptable depending on your needs.
    If the requested resource is invalid or other termination conditions are met,
    (SOURCE) and (SINK) functions should raise an error.
    @return This method never returns unless interrupted.
]]

    local function create_handler(callbacks, request, requestsocket, host, port)
         --[[ Given a parsed request, instantiate the generator function from the given callbacks,
            and create a new coroutine to be called when the state of the handler's
            new socket changes to available.
            On success, returns a table of the form:
            ```
            {
                handler=coroutine to call,
                socket= new socket on a random port on which all new communication will happen,
                fd=socket.fd as above fd
                host=remote host,
                port = remote port,
                request = the original parsed request,
            }
            ```
            On error, responds to the client with an ERROR packet, and returns nil.
        ]]
        local okay, generator = pcall(callbacks[request.opcode], request.filename)
        if not okay then
            requestsocket:sendto(self.ERROR(ERR_ACCESS), host, port)
            return nil
        else
            local handlersocket = UDPSocket()
            local handler = self['handle_' .. request.opcode](self, handlersocket, host, port, generator)
            return {
                handler=handler,
                socket=handlersocket,
                fd=handlersocket.fd,
                host=host,
                port=port,
                request=request
            }
        end
    end

    local function accept(socket)
        --[[ Read an incoming request from ``socket``, parse, and ACK as appropriate.
            If the request is invalid, responds to the client with error and returns `nil` 
            otherwise returns the parsed request.
        ]]
        local msg, host, port = socket:recvfrom(-1)
        if msg ~= false then
            local okay, xRQ = pcall(self.parse_XRQ, msg)
            if not okay or xRQ.mode ~= 'octet' then
                log("invalid request", pretty.write(xRQ))
                socket:sendto(self.ERROR("Unsupported Mode. Please use 'octet'"), host, port)
                return nil
            else
                --RFC1350 requires WRQ requests to be responded to with a zero TID before transfer commences
                if xRQ.opcode == "WRQ" then socket:sendto(self.ACK(0), host, port) end
                return host, port, xRQ
            end                  
        end
    
    end

    local socket = UDPSocket()
    local user_generator_callbacks = {RRQ=rrq_generator_callback, WRQ=wrq_generator_callback}
    local port = port or TFTP_PORT
    
    --listen on all given addresses, default to localhost if not given
    for i, address in pairs((type(hosts) == 'table' and hosts) or (hosts ~= nil and{hosts}) or {'127.0.0.1'}) do
        socket:bind(address, port)
    end
    
    --[[The main event loop does two things:
        1. Accepts new connections.
        2. Handles events occurring on all sockets by despatching to an associated coroutine.
        3. Removes finished requests from the queue and destroys the sockets.
    ]]
    local handlers = {[socket.fd]={fd=socket.fd, socket=socket, listener=true, wantread=true}}
    while true do
        print"poll"
        ready_handlers = poll(handlers)
        print"poll return "
        p(ready_handlers)
--        print(string.rep("*", 80)..("\npoll returned %d handlers\n"):format(#ready_handlers)..string.rep("*", 80))
--        pretty.dump({handlers=handlers, ready_handlers=ready_handlers})
        
        for _, ready in pairs(ready_handlers) do
            if ready.listener then --we've got a listener and should accept a new connection
                if ready.readable then
                    log("request received:", pretty.write(ready))
                    local host, port, request = accept(ready.socket)
                    if host ~= nil then
                        local handler = create_handler(
                            user_generator_callbacks,
                            request,
                            ready.socket,
                            host, 
                            port
                        )
                        handlers[handler.socket.fd] = handler --always index by socket
                    end
                end
            elseif ready.handler then--We've received an event on a socket associated with an existing handler coroutine.
                local status = coroutine.status(ready.handler)
                local okay, wantread, wantwrite
                if status ~= 'dead' then
                    okay, wantread, wantwrite = coroutine.resume(ready.handler)
                end
                if (not okay) or status == 'dead' then 
                         --- the handler is finished; cleanup
                         ready.socket:close()
                         handlers[ready.fd] = nil
                         ready.fd = nil
                         ready = nil   
                    else
                        ready.wantread = wantread
                        ready.wantwrite = wantwrite
                    end
            else 
                error("understood conditions not met") 
            end
        end
    end
end


--[[ RRQ/ZRQ read/write request packets
    https://tools.ietf.org/html/rfc1350
    2 bytes     string    1 byte     string   1 byte
    ------------------------------------------------
   | Opcode |  Filename  |   0  |    Mode    |   0  |
    ------------------------------------------------
           Figure 5-1: RRQ/WRQ packet
]]
function tftp.RRQ(filename)
--  RFC1350:"The mail mode is obsolete and should not be implemented or used."
--  We don't support netascii, which leaves 'octet' mode only
    return table.concat({create_opcode(OP_RRQ), filename, '\0', "octet", '\0'}, '')
end

function tftp.parse_XRQ(request)
    local opcode = assert(parse_opcode(request), "Invalid opcode")
    assert(({RRQ=1, XRQ=1})[opcode], "Not an xRQ")
    assert(request:sub(#request) == '\0', "Invalid request: expected ASCII NUL terminated request")

    --get the filename by walking backwards to find the second  ASCII NUL.
    --FIXME Walking backwards precludes support for Options Extension: 
    --https://tools.ietf.org/html/rfc1782
    local terminator
    for i = #request -1, 3, -1 do
        local byte = request:sub(i, i)
        if byte == '\0' then
            terminator = i
        end
    end

    assert(terminator ~= nil, "Invalid request: expected NUL terminated filename")
    local filename = request:sub(3, terminator-1)
    assert(is_netascii(filename), "Requested filename must be netascii")
    local mode = request:sub(terminator + 1, #request - 1)
    return {
        opcode = opcode,
        filename = filename,
        mode = mode,
        timeout = TIMEOUT,    --TODO support parsing RFC2349 options
        blksize = BLKSIZE,
    }
end

--[[ ACK functions
     2 bytes     2 bytes
     ---------------------
    | Opcode |   Block #  |
     ---------------------
     Figure 5-3: ACK packet
]]
function tftp.parse_ACK(ack)
    --get the sequence number from an ACK or raise a error if not valid
    assert(#ack == ACKSIZE, "invalid ack")
    assert(parse_opcode(ack) == 'ACK', "invalid ack")
    
    -- extract the low and high order bytes and convert to an integer
    local high, low = ack:byte(3, 4)
    return (high * 256) + low
end

function tftp.ACK(sequence_no)
    return table.concat({create_opcode(OP_ACK), create_opcode(sequence_no)}, '')
end


--[[ DATA functions
   2 bytes     2 bytes      n bytes
   ----------------------------------
  | Opcode |   Block #  |   Data     |
   ----------------------------------
        Figure 5-2: DATA packet
]]
function tftp.DATA(data, sequence_no)
    local opcode = create_opcode(OP_DATA)
    local block = create_opcode(sequence_no)
    return table.concat({opcode, block, data}, '')
end

function tftp.parse_DATA(data)
    assert(#data <= 512, "tftp data packets must be 512 bytes or less")
    assert(parse_opcode(data) == OP_DATA, "Invalid opcode")
    return {sequence_no=parse_opcode(data:sub(3, 4)), data=data:sub(5)}
end

--[[ ERROR Functions
    2 bytes     2 bytes      string    1 byte
    -----------------------------------------
    | Opcode |  ErrorCode |   ErrMsg   |   0  |
    -----------------------------------------
        Figure 5-4: ERROR packet
]]
function tftp.ERROR(err)
    local defined_errors = {
        --https://tools.ietf.org/html/rfc1350#page-10
        [0] = type(err) == 'string' and err or "Not defined",
        "File not found.",
        "Access violation.",
        "Disk full or allocation exceeded.",
        "Illegal TFTP operation.",
        "Unknown transfer ID.",
        "File already exists.",
        "No such user.",  
    }

    local errno = type(err) == 'string' and 0 or err
    return table.concat({
        create_opcode(OP_ERR),
        create_opcode(errno),
        defined_errors[errno],
        '\0'
    }, '')
end

function tftp.parse_ERROR(err)
    assert(parse_opcode(err) == OP_ERR)
    local error_code = parse_opcode(err:sub(3, 4))
    return {errcode=error_code, errmsg=err:sub(5, #err-1)}
end

return tftp

