import Foundation

/// Process facts from the kernel, read with sysctl.
package struct Proc {
    package let pid: pid_t, ppid: pid_t, pgid: pid_t, tpgid: pid_t
    package let stopped: Bool
    package let start: Double
    package let tty: String?
    package let name: String

    package init?(_ pid: pid_t) {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard pid > 0, sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        self.init(kp)
    }

    init(_ kp: kinfo_proc) {
        pid = kp.kp_proc.p_pid
        ppid = kp.kp_eproc.e_ppid
        pgid = kp.kp_eproc.e_pgid
        tpgid = kp.kp_eproc.e_tpgid
        stopped = kp.kp_proc.p_stat == CChar(SSTOP)
        start = Double(kp.kp_proc.p_starttime.tv_sec) + Double(kp.kp_proc.p_starttime.tv_usec) / 1e6
        let dev = kp.kp_eproc.e_tdev
        tty = dev == -1 ? nil : devname(dev, S_IFCHR).map { "/dev/" + String(cString: $0) }
        name = withUnsafeBytes(of: kp.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// The Claude Code process above this hook. Hooks run as claude -> hook, or claude -> sh -> hook.
    /// This user's processes.
    package static func all() -> [Proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        var list = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)  // room for new ones
        size = list.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &list, &size, nil, 0) == 0 else { return [] }
        return list.prefix(size / MemoryLayout<kinfo_proc>.stride).map(Proc.init)
    }

    /// The working folder, with symlinks resolved, or nil when the kernel won't say.
    package var cwd: String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// The arguments and the environment the process started with (KERN_PROCARGS2: argc, the executable
    /// path, padding, argv, envp, each a C string). Works for this user's processes.
    package var launch: (args: [String], env: [String: String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return ([], [:]) }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return ([], [:]) }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        // ponytail: an empty argument collapses with the padding; Cue reads only terminal variables.
        let strings = buffer[4..<size].split(separator: 0).dropFirst().map { String(decoding: $0, as: UTF8.self) }
        var env: [String: String] = [:]
        for pair in strings.dropFirst(argc) {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            env[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        return (Array(strings.prefix(argc)), env)
    }

    package static func claude() -> Proc? {
        var pid = getppid()
        for _ in 0..<6 {
            guard let p = Proc(pid) else { return nil }
            if p.name == "claude" { return p }
            pid = p.ppid
        }
        return nil
    }
}
