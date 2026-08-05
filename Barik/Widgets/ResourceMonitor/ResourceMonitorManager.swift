import Foundation
import Darwin

struct ResourceConsumer: Identifiable, Equatable {
    let name: String
    let value: Double
    let seenAt: Date

    var id: String { name }
}

class ResourceMonitorManager: ObservableObject {
    static let shared = ResourceMonitorManager()

    @Published private(set) var cpuPercent: Int = 0
    @Published private(set) var memPercent: Int = 0
    @Published private(set) var recentCPUConsumers: [ResourceConsumer] = []
    @Published private(set) var recentMemoryConsumers: [ResourceConsumer] = []

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.barik.resourcemonitor", qos: .utility)
    private var prevCpuInfo: processor_info_array_t? = nil
    private var prevCpuInfoCount: mach_msg_type_number_t = 0
    private var previousProcesses: [pid_t: ProcessCounter] = [:]
    private var previousProcessSampleTime: TimeInterval?
    private var peaks: [String: ResourcePeaks] = [:]

    private struct ProcessCounter {
        let cpuTime: UInt64
        let memoryBytes: UInt64
        let name: String
    }

    private struct ResourcePeaks {
        var cpu: Double = 0
        var cpuSeenAt = Date.distantPast
        var memory: Double = 0
        var memorySeenAt = Date.distantPast
    }

    private static let historyDuration: TimeInterval = 5 * 60

    private init() {
        startTimer()

        #if DEBUG
        assert(Self.appName(for: "/Applications/Safari.app/Contents/MacOS/Safari") == "Safari")
        assert(Self.appName(for: "/Applications/Chrome.app/Contents/Frameworks/Chrome Helper.app/Contents/MacOS/Chrome Helper") == "Chrome")
        #endif

        NotificationCenter.default.addObserver(
            self, selector: #selector(onSleep),
            name: NSNotification.Name("com.barik.willSleep"), object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onWake),
            name: NSNotification.Name("com.barik.didWake"), object: nil)
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer
        timer.resume()
    }

    @objc private func onSleep() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    @objc private func onWake() {
        queue.async { [weak self] in
            self?.previousProcesses.removeAll()
            self?.previousProcessSampleTime = nil
            self?.startTimer()
        }
    }

    private func refresh() {
        let cpu = readCPU()
        let mem = readMemory()
        let consumers = readResourceConsumers()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let cpuPercent = Int(cpu.rounded())
            let memPercent = Int(mem.rounded())
            if self.cpuPercent != cpuPercent { self.cpuPercent = cpuPercent }
            if self.memPercent != memPercent { self.memPercent = memPercent }
            if self.recentCPUConsumers != consumers.cpu {
                self.recentCPUConsumers = consumers.cpu
            }
            if self.recentMemoryConsumers != consumers.memory {
                self.recentMemoryConsumers = consumers.memory
            }
        }
    }

    private func readResourceConsumers() -> (cpu: [ResourceConsumer], memory: [ResourceConsumer]) {
        let sampleTime = ProcessInfo.processInfo.systemUptime
        let now = Date()
        let interval = previousProcessSampleTime.map { sampleTime - $0 }
        var current: [pid_t: ProcessCounter] = [:]
        var cpuByApp: [String: Double] = [:]
        var memoryByApp: [String: UInt64] = [:]

        let capacity = max(1, Int(proc_listallpids(nil, 0)) + 32)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }

        for pid in pids.prefix(max(0, Int(count))) where pid > 0 {
            var usage = proc_taskinfo()
            let usageSize = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(
                pid, PROC_PIDTASKINFO, 0, &usage, usageSize
            ) == usageSize else { continue }

            let name = previousProcesses[pid]?.name ?? processName(pid: pid)
            guard !name.isEmpty else { continue }

            let cpuTime = usage.pti_total_user + usage.pti_total_system
            let sample = ProcessCounter(
                cpuTime: cpuTime,
                memoryBytes: usage.pti_resident_size,
                name: name
            )
            current[pid] = sample
            memoryByApp[name, default: 0] += sample.memoryBytes

            if let previous = previousProcesses[pid],
               let interval, interval > 0,
               cpuTime >= previous.cpuTime {
                cpuByApp[name, default: 0] +=
                    Double(cpuTime - previous.cpuTime) / interval / 10_000_000
            } else if let age = processAge(pid: pid) {
                if age > 0, age <= 2 {
                    cpuByApp[name, default: 0] += Double(cpuTime) / age / 10_000_000
                }
            }
        }

        if let interval, interval > 0 {
            let cutoff = now.addingTimeInterval(-Self.historyDuration)
            let names = Set(cpuByApp.keys).union(memoryByApp.keys)
            for name in names {
                var peak = peaks[name] ?? ResourcePeaks()
                let cpu = cpuByApp[name, default: 0]
                let memory = Double(memoryByApp[name, default: 0])

                if cpu > peak.cpu || peak.cpuSeenAt < cutoff {
                    peak.cpu = cpu
                    peak.cpuSeenAt = now
                }
                if memory > peak.memory || peak.memorySeenAt < cutoff {
                    peak.memory = memory
                    peak.memorySeenAt = now
                }
                peaks[name] = peak
            }
            peaks = peaks.filter {
                $0.value.cpuSeenAt >= cutoff || $0.value.memorySeenAt >= cutoff
            }
        }

        previousProcesses = current
        previousProcessSampleTime = sampleTime

        let cpu = peaks.map {
            ResourceConsumer(name: $0.key, value: $0.value.cpu, seenAt: $0.value.cpuSeenAt)
        }
        .filter { $0.value >= 0.5 }
        .sorted { $0.value > $1.value }
        .prefix(5)

        let memory = peaks.map {
            ResourceConsumer(name: $0.key, value: $0.value.memory, seenAt: $0.value.memorySeenAt)
        }
        .filter { $0.value > 0 }
        .sorted { $0.value > $1.value }
        .prefix(5)

        return (Array(cpu), Array(memory))
    }

    private func processName(pid: pid_t) -> String {
        var path = [CChar](repeating: 0, count: Int(PATH_MAX) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return "" }
        return Self.appName(for: String(cString: path))
    }

    private func processAge(pid: pid_t) -> TimeInterval? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        let startedAt = TimeInterval(info.pbi_start_tvsec)
            + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return Date().timeIntervalSince1970 - startedAt
    }

    private static func appName(for path: String) -> String {
        if let appEnd = path.range(of: ".app/")?.lowerBound {
            let appPath = String(path[..<appEnd]) + ".app"
            return URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func readCPU() -> Double {
        var cpuInfo: processor_info_array_t? = nil
        var cpuInfoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &cpuInfo, &cpuInfoCount) == KERN_SUCCESS,
              let info = cpuInfo else { return 0 }

        var totalUsed: Double = 0
        var totalAll: Double = 0

        if let prev = prevCpuInfo {
            for i in 0..<Int(cpuCount) {
                let base = Int(CPU_STATE_MAX) * i
                let user = Double(info[base + Int(CPU_STATE_USER)]   - prev[base + Int(CPU_STATE_USER)])
                let sys  = Double(info[base + Int(CPU_STATE_SYSTEM)] - prev[base + Int(CPU_STATE_SYSTEM)])
                let idle = Double(info[base + Int(CPU_STATE_IDLE)]   - prev[base + Int(CPU_STATE_IDLE)])
                let nice = Double(info[base + Int(CPU_STATE_NICE)]   - prev[base + Int(CPU_STATE_NICE)])
                let used = user + sys + nice
                totalUsed += used
                totalAll  += used + idle
            }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: prev)),
                vm_size_t(prevCpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        prevCpuInfo = info
        prevCpuInfoCount = cpuInfoCount

        return totalAll > 0 ? min(totalUsed / totalAll * 100, 100) : 0
    }

    private func readMemory() -> Double {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }

        let pageSize = Double(vm_page_size)
        let used = Double(stats.active_count + stats.wire_count + stats.compressor_page_count) * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)

        return min(used / total * 100, 100)
    }
}
