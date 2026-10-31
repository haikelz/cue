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
        self.pid = pid
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
