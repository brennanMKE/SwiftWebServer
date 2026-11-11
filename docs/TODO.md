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

* [ ] Define HostConfig mapping domains to roots
* [ ] Route requests based on Host header

## 🧩 Extension Support

* [ ] Define ExtensionHost interface
* [ ] Integrate with ExtensionKit (macOS-only)

## 🧪 Testing

* [ ] Add unit tests with modern Swift Testing framework
* [ ] Enable tests via CLI option
