import Darwin

public enum ProcessTree {
    public struct Proc: Codable, Sendable {
        public let pid: Int32
        public let comm: String
    }

    /// Parent chain starting at `pid`'s parent, up to `limit` entries (stops at launchd).
    public static func ancestors(of pid: pid_t, limit: Int) -> [Proc] {
        var result: [Proc] = []
        var current = pid
        while result.count < limit, let info = info(for: current), info.ppid > 1 {
            guard let parent = Self.info(for: info.ppid) else { break }
            result.append(Proc(pid: info.ppid, comm: parent.comm))
            current = info.ppid
        }
        return result
    }

    public static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]

    /// argv of `pid` (excluding the executable path), via KERN_PROCARGS2.
    public static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }

        // Layout: argc (Int32), exec path, NUL padding, then argc NUL-terminated args.
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var parts = buf[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true).makeIterator()
        _ = parts.next()  // exec path
        var args: [String] = []
        while args.count < Int(argc), let part = parts.next() {
            args.append(String(decoding: part, as: UTF8.self))
        }
        return Array(args.dropFirst())
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func info(for pid: pid_t) -> (ppid: pid_t, comm: String)? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let comm = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return (kp.kp_eproc.e_ppid, comm)
    }
}
