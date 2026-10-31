import Foundation

/// A program that failed, or that `Command.run` stopped at its timeout.
package struct CommandError: Error {
    package let message: String
    package let timedOut: Bool
}

package enum Command {
    /// Runs a program, feeding `input` on stdin, and kills it after `timeout` seconds. Returns stdout
    /// without its trailing newlines; a failure carries the first line of stderr.
    package static func run(_ exe: String, _ args: [String], input: String? = nil, env: [String: String]? = nil,
                            timeout: Double) throws(CommandError) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let env { p.environment = env }
        let stdin = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = stdin
        p.standardOutput = output
        p.standardError = errors
        do { try p.run() } catch { throw CommandError(message: "\(exe): \(error.localizedDescription)", timedOut: false) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        // The throwing write: a child that exits before reading must not raise an exception here.
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            if p.terminationReason == .uncaughtSignal {
                throw CommandError(message: "no answer in \(Int(timeout)) s", timedOut: true)
            }
            let first = err.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(p.terminationStatus)"
            throw CommandError(message: first, timedOut: false)
        }
        return out.trimmingCharacters(in: .newlines)
    }
}
