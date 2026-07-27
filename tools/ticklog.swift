// Sample a RUNNING helm's idle cost at a known tab count → CSV.
// Usage: swift tools/ticklog.swift <label> <tabs> [--samples N] [--interval S] [--out PATH]
//
// This never launches helm (AGENTS.md forbids agents doing that, and a
// self-launched app has no tabs open anyway). The owner opens the tabs, leaves
// them idle, and runs this; it finds the process and records what it can
// actually observe. Run it once per tab count before the change and again after,
// then diff the two CSVs.
import Foundation

let usage = """
usage: swift tools/ticklog.swift <label> <tabs> [--samples N] [--interval S] [--out PATH]

  <label>       "baseline" or "after" — also picks the default output file
  <tabs>        how many terminal tabs are open right now (you state it; the
                script cannot see inside the app)
  --samples N   CPU/RSS samples to average (default 10)
  --interval S  seconds between samples (default 1.0)
  --out PATH    CSV to append to (default tools/measurements/<label>.csv)

Owner procedure (agents must not run helm):

  1. make app && open .build/DerivedData/Build/Products/Debug/Helm.app
  2. Open exactly 1 tab. Let it sit idle ~10s with no shell running.
     swift tools/ticklog.swift baseline 1
  3. Repeat at 3 tabs and at 6 tabs.
  4. Land the shared-controller change, rebuild, and repeat all three with
     the label "after".
  5. Compare: baseline should climb with tab count, after should stay flat.
     If it does not, say so — a refactor that did not deliver is a finding.

Columns: iso_time,label,tabs,pid,cpu_pct_mean,cpu_pct_max,rss_mib,threads
"""

struct Sample {
    let cpu: Double
    let rssKiB: Double
}

/// Runs a tool and returns its stdout, or nil if it could not be run.
func capture(_ launchPath: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

/// helm's pid, whether it is running as the SPM binary (`swift run helm`) or
/// the bundled app (`make app`). Newest match wins.
func findHelmPID() -> Int32? {
    guard let out = capture("/bin/ps", ["-Ao", "pid=,comm="]) else { return nil }
    var candidates: [Int32] = []
    for line in out.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { continue }
        guard let pid = Int32(trimmed[trimmed.startIndex ..< space]) else { continue }
        let command = String(trimmed[space...]).trimmingCharacters(in: .whitespaces)
        let name = (command as NSString).lastPathComponent
        // The SPM product is lowercase "helm"; the bundle's executable is "Helm".
        guard name == "helm" || name == "Helm" else { continue }
        // Skip this script's own `swift` invocation and any editor/LSP process.
        guard !command.contains("swift-frontend") else { continue }
        candidates.append(pid)
    }
    return candidates.last
}

func sample(pid: Int32) -> Sample? {
    guard let out = capture("/bin/ps", ["-o", "%cpu=,rss=", "-p", String(pid)]) else { return nil }
    let fields = out.split(whereSeparator: { $0 == " " || $0 == "\n" })
    guard fields.count >= 2, let cpu = Double(fields[0]), let rss = Double(fields[1]) else {
        return nil
    }
    return Sample(cpu: cpu, rssKiB: rss)
}

func threadCount(pid: Int32) -> Int {
    guard let out = capture("/bin/ps", ["-M", "-p", String(pid)]) else { return 0 }
    // One header line, then one line per thread.
    return max(0, out.split(separator: "\n").count - 1)
}

// MARK: - Argument parsing

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("--help") || args.contains("-h") {
    print(usage)
    exit(0)
}

func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index ... (index + 1))
    return value
}

let samplesOption = option("--samples")
let intervalOption = option("--interval")
let outOption = option("--out")

guard args.count == 2, let tabs = Int(args[1]), tabs > 0 else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
let label = args[0]
let samples = samplesOption.flatMap(Int.init) ?? 10
let interval = intervalOption.flatMap(Double.init) ?? 1.0
let outPath = outOption ?? "tools/measurements/\(label).csv"

guard samples > 0, interval > 0 else {
    FileHandle.standardError.write(Data("samples and interval must be positive\n".utf8))
    exit(2)
}

// MARK: - Measure

guard let pid = findHelmPID() else {
    FileHandle.standardError.write(Data("""
    no running helm found. Start it first (make app, or swift run helm), open \
    \(tabs) tab(s), let them go idle, then re-run.

    """.utf8))
    exit(1)
}

FileHandle.standardError.write(Data("sampling pid \(pid), \(samples)×\(interval)s…\n".utf8))

var cpus: [Double] = []
var rss: [Double] = []
for index in 0 ..< samples {
    if index > 0 { Thread.sleep(forTimeInterval: interval) }
    guard let reading = sample(pid: pid) else {
        FileHandle.standardError.write(Data("helm exited mid-sample\n".utf8))
        exit(1)
    }
    cpus.append(reading.cpu)
    rss.append(reading.rssKiB)
}

let cpuMean = cpus.reduce(0, +) / Double(cpus.count)
let cpuMax = cpus.max() ?? 0
let rssMiB = (rss.max() ?? 0) / 1024
let threads = threadCount(pid: pid)

let formatter = ISO8601DateFormatter()
let row = [
    formatter.string(from: Date()),
    label,
    String(tabs),
    String(pid),
    String(format: "%.2f", cpuMean),
    String(format: "%.2f", cpuMax),
    String(format: "%.1f", rssMiB),
    String(threads),
].joined(separator: ",")

let header = "iso_time,label,tabs,pid,cpu_pct_mean,cpu_pct_max,rss_mib,threads\n"
let url = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
if !FileManager.default.fileExists(atPath: outPath) {
    try header.write(to: url, atomically: true, encoding: .utf8)
}
let handle = try FileHandle(forWritingTo: url)
handle.seekToEndOfFile()
handle.write(Data((row + "\n").utf8))
try handle.close()

print(row)
FileHandle.standardError.write(Data("appended to \(outPath)\n".utf8))
