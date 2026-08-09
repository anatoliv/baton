import Foundation

/// A minimal HTTP/1.1 server for the engine tests: serves one byte payload on
/// 127.0.0.1, with the delivery shapes the real server exhibits —
///
/// - **`.wholeFile`**: `Content-Length` + all bytes at wire speed (a warm, fully-encoded
///   stream / a plain podcast enclosure).
/// - **`.chunked`**: `Transfer-Encoding: chunked`, no length — the shape of a cold
///   Navidrome transcode (which is also why such a stream isn't byte-range seekable).
/// - **`.stallAfter(bytes:)`**: sends a prefix, then holds the connection open sending
///   nothing until `releaseStall()` — a slow-but-open connection, the exact stall class
///   the watchdog exists for.
///
/// Plain BSD sockets on a background thread: no frameworks, no entitlements, and the
/// blocking writes make throttling/stalling trivial to express.
final class EngineHTTPServer: @unchecked Sendable {
    enum Delivery {
        case wholeFile
        case chunked
        case stallAfter(bytes: Int)
    }

    private let payload: Data
    private let delivery: Delivery
    private let contentType: String
    private let listenFD: Int32
    let port: UInt16

    private let lock = NSLock()
    private var stallReleased = false
    private var stopped = false
    private var connectionFDs: [Int32] = []

    init(payload: Data, delivery: Delivery = .wholeFile, contentType: String = "audio/mpeg") throws {
        self.payload = payload
        self.delivery = delivery
        self.contentType = contentType

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0 // ephemeral
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &len)
            }
        }
        listenFD = fd
        port = UInt16(bigEndian: bound.sin_port)

        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/stream")! }

    /// Let stalled connections continue (the network "recovered").
    func releaseStall() {
        lock.lock()
        stallReleased = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        stallReleased = true // unblock any stalled writer so its thread can exit
        // `shutdown`, not `close`: each connection's serving thread owns the close (its
        // `defer`). Closing here too would double-close — and once the kernel reuses the
        // fd number, the second close hits somebody else's (guarded) descriptor, which
        // is an EXC_GUARD crash. Measured, not hypothetical.
        for fd in connectionFDs { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        close(listenFD)
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop() {
        while !isStopped {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            // Writing to a socket the client has already closed raises SIGPIPE, whose
            // default disposition kills the process — the whole test runner, not the test.
            //
            // This is exactly what the engine tests do all the time: the decoder stops
            // reading and tears down its connection the moment it has what it needs (a
            // seek that lands in the spool, a track that ends, a stall released), while
            // this server is still mid-write. It is normal client behaviour, and it took
            // out a full-suite run — reported as "0 failures" while the log's own count
            // silently dropped by about 218 tests, because a killed runner stops
            // reporting rather than failing. It passes 5/5 in isolation, which is the
            // signature of a race, not of a broken assertion.
            //
            // SO_NOSIGPIPE turns that into a plain EPIPE from `send`, which the write
            // loop below already handles by giving up on the connection.
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            lock.lock(); connectionFDs.append(fd); lock.unlock()
            Thread.detachNewThread { [weak self] in self?.serve(fd: fd) }
        }
    }

    private func serve(fd: Int32) {
        defer {
            // Deregister under the lock BEFORE closing, so `stop()` can never touch a
            // descriptor that has been (or is being) closed and possibly reused.
            lock.lock()
            connectionFDs.removeAll { $0 == fd }
            lock.unlock()
            close(fd)
        }
        // Read the request head (we serve one resource; the path doesn't matter).
        var head = Data()
        var byte: UInt8 = 0
        while !head.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard recv(fd, &byte, 1, 0) == 1 else { return }
            head.append(byte)
            if head.count > 16 * 1024 { return }
        }
        // A crude no-Range policy, like a cold transcode: any Range request is answered
        // from byte zero with 200 (which is precisely the server behaviour StreamSeek
        // documents — the engine must never rely on ranges for these streams).
        switch delivery {
        case .wholeFile:
            send(fd, "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n")
            sendAll(fd, payload)
        case .chunked:
            send(fd, "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
            var offset = 0
            let chunk = 32 * 1024
            while offset < payload.count, !isStopped {
                let end = min(offset + chunk, payload.count)
                let slice = payload[offset ..< end]
                send(fd, String(format: "%x\r\n", slice.count))
                sendAll(fd, Data(slice))
                send(fd, "\r\n")
                offset = end
            }
            send(fd, "0\r\n\r\n")
        case .stallAfter(let bytes):
            send(fd, "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n")
            let prefix = min(bytes, payload.count)
            sendAll(fd, payload.prefix(prefix))
            // Hold the connection open, sending nothing, until released or stopped.
            while !isStopped {
                lock.lock()
                let released = stallReleased
                lock.unlock()
                if released { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard !isStopped else { return }
            sendAll(fd, payload.suffix(payload.count - prefix))
        }
    }

    private func send(_ fd: Int32, _ string: String) {
        sendAll(fd, Data(string.utf8))
    }

    private func sendAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
                guard n > 0 else { return }
                sent += n
            }
        }
    }
}

// MARK: - Test signal fixtures

enum EngineTestSignals {
    /// A WAV file of a mono sine at `frequency` — deterministic content for spectral
    /// assertions. 16-bit LPCM so the decoder's format-conversion path is exercised.
    static func sineWAV(frequency: Double, seconds: Double, sampleRate: Double = 44_100, amplitude: Double = 0.5) -> Data {
        let frames = Int(seconds * sampleRate)
        var samples = [Int16]()
        samples.reserveCapacity(frames)
        for i in 0 ..< frames {
            let value = amplitude * sin(2 * .pi * frequency * Double(i) / sampleRate)
            samples.append(Int16(max(-32767, min(32767, value * 32767))))
        }
        return wav(samples: samples, sampleRate: Int(sampleRate))
    }

    /// A WAV whose first half is `firstHz` and second half `secondHz` — lets a seek test
    /// prove *which audio* a position maps to, not just that a seek "succeeded".
    static func twoToneWAV(firstHz: Double, secondHz: Double, secondsEach: Double, sampleRate: Double = 44_100) -> Data {
        let framesEach = Int(secondsEach * sampleRate)
        var samples = [Int16]()
        samples.reserveCapacity(framesEach * 2)
        for (hz, range) in [(firstHz, 0 ..< framesEach), (secondHz, 0 ..< framesEach)] {
            for i in range {
                let value = 0.5 * sin(2 * .pi * hz * Double(i) / sampleRate)
                samples.append(Int16(max(-32767, min(32767, value * 32767))))
            }
        }
        return wav(samples: samples, sampleRate: Int(sampleRate))
    }

    /// Same WAV writer, reachable by tests that build their own sample arrays.
    static func wavForTesting(samples: [Int16], sampleRate: Int) -> Data {
        wav(samples: samples, sampleRate: sampleRate)
    }

    private static func wav(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        let byteCount = samples.count * 2
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(16)
        append16(1) // PCM
        append16(1) // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)) // byte rate
        append16(2) // block align
        append16(16) // bits
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// Single-bin DFT (Goertzel) power of `frequency` in `samples` — the spectral
    /// assertion primitive: "how much of this tone is in this audio".
    static func goertzelPower(samples: [Float], sampleRate: Double, frequency: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let omega = 2 * Double.pi * frequency / sampleRate
        let coeff = 2 * cos(omega)
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for sample in samples {
            s0 = Double(sample) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return power / Double(samples.count)
    }

    /// RMS of a float signal.
    static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }
}
