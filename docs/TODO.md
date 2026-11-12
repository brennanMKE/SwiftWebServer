> **Historical.** The original to-do list of the legacy server (deleted in #0086). Work is tracked
> in [`issues/`](../issues/Issues.md) and planned in [ROADMAP.md](ROADMAP.md). The "Implemented"
> list below described the legacy server and was partly wrong (HEAD sent bodies, #0016).

# To Do List

## ✅ Implemented

* GET requests
* HEAD requests
* ETag support

## 🔨 In Progress

* [ ] Define Middleware interface
* [ ] Refactor connection handler to call middleware chain
* [ ] Register middleware in `RuntimeConfiguration`
* [ ] Create LoggerMiddleware for testing

## 🌐 Web Sockets

* [ ] Create WebSocketMiddleware
* [ ] Handle Upgrade: websocket handshake
* [ ] Implement basic WebSocketSession (frame parsing, pings, etc.)
* [ ] Route WebSocket messages to handler

## 🔒 Authentication

* [ ] Add AuthenticationMiddleware
* [ ] HMAC validation for JWT tokens
* [ ] Add PasskeyMiddleware placeholder

## 🌍 Virtual Hosting

* [x] Define HostConfig mapping domains to roots (#0092: `hosts` key)
* [x] Route requests based on Host header (#0092: `VirtualHosts`)

## 🧩 Extension Support

* [ ] Define ExtensionHost interface
* [ ] Integrate with ExtensionKit (macOS-only)

## 🧪 Testing

* [ ] Add unit tests with modern Swift Testing framework
* [ ] Enable tests via CLI option
