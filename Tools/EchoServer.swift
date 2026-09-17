// A minimal HTTP/1.1 echo server for the HTTP client tests. Binds 127.0.0.1 on
// the given port (argv[1], default 8199) and relays each request straight back:
// status 200, the request body as the response body, and the request headers
// echoed as response headers (Content-Length recomputed; hop-by-hop headers
// dropped).
//
// Standalone (compiled ad-hoc with `swiftc`, not a SwiftPM target) so it stays
// out of the library/iOS/wasm build graph. It runs as a separate host process;
// the tests reach it over localhost — including the wasm run, where Node's
// `fetch` hits the host. Raw sockets, no Dispatch and no Foundation: POSIX
// everywhere, Winsock on Windows, behind the aliases below.

#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif os(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// Winsock is BSD sockets under other names: a socket is an unsigned handle and
// not a file descriptor, every length is Int32, closesocket replaces close, and
// nothing works before WSAStartup. Alias those four differences here so the
// server below stays one implementation rather than two.
#if os(Windows)
typealias SocketHandle = SOCKET
let invalidSocket = SocketHandle.max
func socketClose(_ s: SocketHandle) { _ = closesocket(s) }
func socketRecv(_ s: SocketHandle, _ buf: UnsafeMutableRawPointer?, _ n: Int) -> Int {
    Int(recv(s, buf?.assumingMemoryBound(to: CChar.self), Int32(n), 0))
}
func socketSend(_ s: SocketHandle, _ buf: UnsafeRawPointer?, _ n: Int) -> Int {
    Int(send(s, buf?.assumingMemoryBound(to: CChar.self), Int32(n), 0))
}
func writeStderr(_ buf: UnsafeRawPointer?, _ n: Int) { _ = _write(2, buf, UInt32(n)) }

var wsaData = WSADATA()
guard WSAStartup(0x0202, &wsaData) == 0 else { fatalError("WSAStartup() failed") }
#else
typealias SocketHandle = Int32
let invalidSocket: SocketHandle = -1
func socketClose(_ s: SocketHandle) { _ = close(s) }
func socketRecv(_ s: SocketHandle, _ buf: UnsafeMutableRawPointer?, _ n: Int) -> Int {
    recv(s, buf, n, 0)
}
func socketSend(_ s: SocketHandle, _ buf: UnsafeRawPointer?, _ n: Int) -> Int {
    send(s, buf, n, 0)
}
func writeStderr(_ buf: UnsafeRawPointer?, _ n: Int) { _ = write(2, buf, n) }
#endif

let port: UInt16 = CommandLine.arguments.count > 1 ? (UInt16(CommandLine.arguments[1]) ?? 8199) : 8199

#if canImport(Glibc) || canImport(Musl) || os(Android)
let streamType = Int32(SOCK_STREAM.rawValue)
#else
let streamType = SOCK_STREAM
#endif

let listenFD = socket(AF_INET, streamType, 0)
guard listenFD != invalidSocket else { fatalError("socket() failed") }

var yes: Int32 = 1
#if os(Windows)
withUnsafeBytes(of: &yes) {
    _ = setsockopt(
        listenFD, SOL_SOCKET, SO_REUSEADDR,
        $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count))
}
#else
setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
#endif

var addr = sockaddr_in()
addr.sin_port = port.bigEndian
#if os(Windows)
addr.sin_family = ADDRESS_FAMILY(AF_INET)
addr.sin_addr.S_un.S_addr = UInt32(0x7f00_0001).bigEndian // 127.0.0.1
#else
addr.sin_family = sa_family_t(AF_INET)
addr.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian // 127.0.0.1
#endif

let didBind = withUnsafePointer(to: &addr) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        #if os(Windows)
            bind(listenFD, $0, Int32(MemoryLayout<sockaddr_in>.size))
        #else
            bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        #endif
    }
}
guard didBind == 0 else { fatalError("bind() failed on port \(port)") }
guard listen(listenFD, 16) == 0 else { fatalError("listen() failed") }

// Clean shutdown: SIGTERM/SIGINT (the task's `kill`) close the socket and exit 0;
// ignore SIGPIPE so a client disconnecting mid-write can't kill the server.
// Windows has neither: there is no SIGPIPE, and the kill that stops this is a
// TerminateProcess, which no handler gets to see. The OS closes the socket.
#if !os(Windows)
signal(SIGPIPE, SIG_IGN)
signal(SIGTERM) { _ in socketClose(listenFD); _exit(0) }
signal(SIGINT) { _ in socketClose(listenFD); _exit(0) }
#endif

FileHandleWriteStderr("echo-server listening on 127.0.0.1:\(port)\n")

// Sequential: handle one connection fully, then accept the next. Fine for a test
// fixture (requests are small; extra connections wait briefly in the backlog),
// and avoids a Dispatch dependency that isn't available under every toolchain.
while true {
    let client = accept(listenFD, nil, nil)
    if client == invalidSocket { break }
    handle(client)
    socketClose(client)
}

func handle(_ fd: SocketHandle) {
    var data = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 4096)
    func recvChunk() -> Int { chunk.withUnsafeMutableBytes { socketRecv(fd, $0.baseAddress, $0.count) } }

    var split = indexOfCRLFCRLF(data)
    while split == nil {
        let n = recvChunk()
        if n <= 0 { return }
        data.append(contentsOf: chunk[0..<n])
        split = indexOfCRLFCRLF(data)
    }
    let headerEnd = split!
    let lines = splitCRLFLines(Array(data[0..<headerEnd]))

    var headers: [(name: String, value: String)] = []
    var contentLength = 0
    for line in lines.dropFirst() {  // drop the request line
        guard let colon = line.firstIndex(of: 0x3A) else { continue }
        let name = String(decoding: line[0..<colon], as: UTF8.self)
        var vs = colon + 1
        while vs < line.count, line[vs] == 0x20 { vs += 1 }
        let value = String(decoding: line[vs...], as: UTF8.self)
        headers.append((name, value))
        if name.lowercased() == "content-length" { contentLength = Int(value) ?? 0 }
    }

    var body = Array(data[(headerEnd + 4)...])
    while body.count < contentLength {
        let n = recvChunk()
        if n <= 0 { break }
        body.append(contentsOf: chunk[0..<n])
    }
    if body.count > contentLength { body = Array(body[0..<contentLength]) }

    let drop: Set<String> = ["content-length", "transfer-encoding", "connection", "host"]
    var head = "HTTP/1.1 200 OK\r\n"
    for (name, value) in headers where !drop.contains(name.lowercased()) {
        head += "\(name): \(value)\r\n"
    }
    head += "Content-Length: \(body.count)\r\n"
    head += "Connection: close\r\n\r\n"

    var out = Array(head.utf8)
    out.append(contentsOf: body)
    sendAll(fd, out)
}

func sendAll(_ fd: SocketHandle, _ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    bytes.withUnsafeBytes { raw in
        var sent = 0
        while sent < raw.count {
            let n = socketSend(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
            if n <= 0 { break }
            sent += n
        }
    }
}

func indexOfCRLFCRLF(_ b: [UInt8]) -> Int? {
    guard b.count >= 4 else { return nil }
    var i = 0
    while i <= b.count - 4 {
        if b[i] == 0x0D, b[i + 1] == 0x0A, b[i + 2] == 0x0D, b[i + 3] == 0x0A { return i }
        i += 1
    }
    return nil
}

func splitCRLFLines(_ b: [UInt8]) -> [[UInt8]] {
    var lines: [[UInt8]] = []
    var start = 0, i = 0
    while i < b.count {
        if b[i] == 0x0D, i + 1 < b.count, b[i + 1] == 0x0A {
            lines.append(Array(b[start..<i])); i += 2; start = i
        } else { i += 1 }
    }
    if start < b.count { lines.append(Array(b[start..<b.count])) }
    return lines
}

func FileHandleWriteStderr(_ s: String) {
    let bytes = Array(s.utf8)
    bytes.withUnsafeBytes { writeStderr($0.baseAddress, $0.count) }
}
