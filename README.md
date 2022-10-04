# Evented Lua TFTP server

## About
tufty is a TFTP server intended primarily for booting large PXE images from memory constrained consumer grade routers running [OpenWrt](https://openwrt.org/)

**Another TFTP server?  What? Seriously, there are loads of TFTP servers about; OpenWrt has `dnsmasq` built in which exposes a robust TFTP server. What's the point?**

While OpenWrt is extraordinarily powerful, (it's Linux with a package manager after-all), it's often found on the most memory-constrained devices. Storing the files needed to PXE boot even a single workstation becomes an excercise in futility.
All OpenWrt installations I've seen have Lua with a sockets library installed by default. This enables us to remedy the situation.

The intention is that a user-supplied function fetches data as needed like a _generator function_, allowing you to boot from an off-world network, generate your own responses programmatically, or simply serve files from the local filesystem using an `io.open()` call (assuming you actually do have some space available).

Thus, on my memory constrained device, I can create something like this `server.lua`:

```Lua
local base_url = assert(arg[1], "base url required")
local tftp = require('tftp') -- This project
local http = require('http') -- hypothetical http client

os.exit(tftp:listen(
    function(file)
        local response = assert(http.get(base_url .. file))
        local bytesread = 1;
        local function handler(length)
            local data, continue = response.next(length)
            return continue, data
        end
        --return a function that yields the given number of bytes, as well as the response length.
        return handler, #response
    end
))
```
The code above enables the user to stream massive files from the base HTTP url given on the command-line by utilizing something like a [generator](https://en.wikipedia.org/wiki/Generator_(computer_programming)), without having to store any intermediate responses in memory.

Run it like so:

`lua server.lua 'http://ftp.nl.debian.org/debian/dists/stable/main/installer-amd64/current/images/netboot/'`

...and Debian stable is bootstrapped to all machines who make a GET request for `pxelinux.0`.

**Why evented?**

This project was also an excuse to learn Lua's very powerful [coroutines](http://www.lua.org/manual/5.2/manual.html#2.6), which I'd always skipped-over in a hurry when reading PiL.  This project allowed me to do learn what I'd missed.  Using coroutines makes it trivial to do event-based programming in a single thread.

## Requirements
**Hard requirements**
* [Lua5.1, Lua5.2](http://lua.org), or [LuaJIT](http://luajit.org/) (Lua5.3 _may_ work, but has not been tested)
* [nixio](http://luci.subsignal.org/api/nixio/modules/nixio.html) or [luasocket](http://w3.impa.br/~diego/software/luasocket/reference.html)

**Optional requirements**
* [penlight](https://github.com/stevedonovan/Penlight) (for prettier logs)

## API
At the moment I don't have documentation prepared, but the source is _very well_ documented.

## Conforming to
Hopefully,
[RFC1350](https://tools.ietf.org/html/rfc1350),
[RFC2347](https://tools.ietf.org/html/rfc2347),
[RFC2348](https://tools.ietf.org/html/rfc2348),
[RFC2349](https://tools.ietf.org/html/rfc2349),
[RFC1782](https://tools.ietf.org/html/rfc1782),
[RFC3247](https://tools.ietf.org/html/rfc3247)


## Bugs
Probably many.
* Timeout handling is very poor, and will probably hang until the next client makes a request at the moment.
* Use with `luasocket` is pretty much untested at this point, though should work just fine.
