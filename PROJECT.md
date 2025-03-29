## ✅ Project: SwiftWebServer

A lightweight, standalone HTTP/1.1 web server written in **Swift 6** using **Swift Concurrency** and **Network.framework**, compatible with macOS and Linux.

---

## ✅ Implemented Features

### 🧱 Core Server

- Uses `NWListener` to bind to a TCP port and accept connections
- Handles HTTP/1.1 requests with minimal parsing
- Supports HTTP GET requests with proper response formatting
- Graceful shutdown via `SIGINT` and `SIGTERM`, using continuations

### 📁 Static File Hosting

- Serves static files from a specified `Public` directory
- Defaults to `./Public` if no path is provided at launch
- Accepts a custom path via command-line argument
- Supports directory-based fallback to `index.html`

### 🧾 HTTP Headers and Protocol Support

- Sets `Content-Type` based on file extension (`mimeTypes` in `http-config.json`)
- Sets `Content-Length` and `Connection: close`
- Responds with appropriate HTTP status codes (200, 400, 403, 404, 405, 500)

### 🔐 Path Blocking

- Blocks requests for sensitive paths using a `blockList` in `http-config.json`
- Match is based on exact path equality (e.g. `/http-config.json`)

### 📦 Caching Support

- Supports `Cache-Control` and `Last-Modified` headers
- Conditional requests (`If-Modified-Since`) return `304 Not Modified` when valid
- Configurable in `http-config.json` via:

  ```json
  "caching": { "enable": true, "maxAge": 3600 }
  ```

### ⚙️ Configuration

- Loads `http-config.json` as JSON at startup
- Config options:
  - Port
  - Default index file
  - Default MIME type
  - Custom MIME types
  - Block list
  - Caching settings

### 🛠 Build & Run

- Binary name is configurable via `Package.swift` executable product
- Can be launched with:

  ```bash
  ./webserver [directory]
  ```

---

## 🧭 Features Discussed for Next Steps

### 🔒 TLS Support

- Secure the server with HTTPS using Let's Encrypt
- Either:
  - Add direct TLS support via `NWProtocolTLS` or `SwiftNIO + NIOSSL`
  - Or front with a TLS proxy like **nginx** or **Caddy**

### 🧑‍💻 Authentication

- Discussed user auth systems including:
  - JWTs with HMAC for stateless auth
  - Optional OAuth or Passkey support in future

### 📜 HTTP Improvements

- Support for additional HTTP methods (e.g., HEAD, OPTIONS)
- Add support for `ETag` headers for caching
- Add support for custom response headers via config

### 🪪 Logging & Observability

- Log request paths and status codes with timestamps
- Add performance timing and metrics (e.g., response time)
- Optionally log to a file or remote syslog

### Web Sockets

- Add support for Web Sockets

### Virtual Hosting like Apache web server

- Add support for multiple websites
- Use IP address or hostname

### 🌍 Directory Indexing (Optional)

- Option to generate a simple file listing if no index is found

### 💥 Error Handling & Resilience

- Improve error reporting on bad requests or missing headers
- Add crash recovery / auto-restart logic

### 🧪 Testing

- Add unit tests and integration tests using the modern Swift Testing framework
- Test static file responses, cache headers, and signal handling
