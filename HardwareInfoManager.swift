import SwiftUI
import Combine


struct ContentView: View {
    private let manager: HardwareInfoManager = HardwareInfoManager()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    @State private var cpuUsage: HardwareInfoManager.CPUUsage
    @State private var diskInfo: HardwareInfoManager.DiskStorageInfo
    @State private var memory: HardwareInfoManager.MemoryInfo

    init() {
        self.cpuUsage = manager.getCPUUsage()
        self.diskInfo = manager.getDiskStorageInfo()
        self.memory = manager.getMemoryInfo()
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section("CPU Usage") {
                    VStack(alignment: .leading) {
                        Text("User: \(cpuUsage.user.percentageString)")
                        Text("System: \(cpuUsage.system.percentageString)")
                        Text("Idle: \(cpuUsage.idle.percentageString)")
                        Text("Nice: \(cpuUsage.nice.percentageString)")
                    }

                }
                
                Section("Memory") {
                    VStack(alignment: .leading) {
                        Text("VM: \(memory.virtualSize.formattedBytes)")
                        Text("RSS: \(memory.residentSize.formattedBytes)")
                        Text("MaxRSS: \(memory.maxResidentSize.formattedBytes)")
                    }
                }
                
                Section("Storage") {
                    VStack(alignment: .leading) {
                        Text("Total: \(diskInfo.total.formattedBytes)")
                        Text("Used: \(diskInfo.used.formattedBytes)")
                        Text("Free: \(diskInfo.free.formattedBytes)")
                        
                        ProgressView(value: Float(diskInfo.used), total: Float(diskInfo.total))
                            .progressViewStyle(.linear)
                            .overlay(alignment: .topTrailing, content: {
                                Text((Double(diskInfo.free) / Double(diskInfo.total)).percentageString)
                                    .foregroundStyle(.secondary)
                                    .offset(y: -24)
                            })
                    }
                }

            }
            .navigationTitle("Hardware Information")
            .onReceive(timer) { input in
                self.cpuUsage = manager.getCPUUsage()
                self.diskInfo = manager.getDiskStorageInfo()
                self.memory = manager.getMemoryInfo()
            }


        }
    }
}


extension Dictionary<FileAttributeKey, Any> {
    func uInt64ForKey(_ key: FileAttributeKey) -> UInt64? {
        if let nsNumber = self[key] as? NSNumber {
            return nsNumber.uint64Value
        }
        return nil
    }
}

extension UInt64 {
    static let byteCountFormatter = ByteCountFormatter()

    var formattedBytes: String {
        Self.byteCountFormatter.string(fromByteCount: Int64(self))
    }
}

extension Double {
    var percentageString: String {
        self.formatted(.percent.precision(.fractionLength(2)))
    }
}


class HardwareInfoManager {

    // CPU usage. Ranged from 0 to 1.
    struct CPUUsage {

        var user: Double
        var system: Double
        var idle: Double
        var nice: Double
                
        init(_ new: host_cpu_load_info, _ previous: host_cpu_load_info) {
            let userDiff = Double(new.cpu_ticks.0 - previous.cpu_ticks.0)
            let sysDiff  = Double(new.cpu_ticks.1 - previous.cpu_ticks.1)
            let idleDiff = Double(new.cpu_ticks.2 - previous.cpu_ticks.2)
            let niceDiff = Double(new.cpu_ticks.3 - previous.cpu_ticks.3)
            
            let totalTicks = sysDiff + userDiff + idleDiff + niceDiff
            
            self.user = userDiff / totalTicks
            self.system  = sysDiff / totalTicks
            self.idle = idleDiff / totalTicks
            self.nice = niceDiff / totalTicks
        }
    }
    
    // memory info in bytes
    struct MemoryInfo {
        var virtualSize: UInt64
        var residentSize: UInt64
        var maxResidentSize: UInt64

        init(_ memoryInfo: mach_task_basic_info) {
            self.virtualSize = memoryInfo.virtual_size
            self.residentSize = memoryInfo.resident_size
            self.maxResidentSize = memoryInfo.resident_size_max
        }
    }
    
    // Disk Storage Info In bytes
    struct DiskStorageInfo {
        var total: UInt64
        var used: UInt64
        var free: UInt64
        
        init(_ fileSystemAttributes: [FileAttributeKey: Any]) {
            let free = fileSystemAttributes.uInt64ForKey(.systemFreeSize) ?? 0
            let total = fileSystemAttributes.uInt64ForKey(.systemSize) ?? 0
            let used = total - free
            self.total = total
            self.free = free
            self.used = used
        }
        
    }
    
        
    private var previousLoadInfo: host_cpu_load_info = host_cpu_load_info()
    
    private let hostCPULoadInfoMemoryCount: mach_msg_type_number_t = UInt32(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)

    private let machineTaskBasicInfoMemoryCount: mach_msg_type_number_t = UInt32(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)

    
    private func getHostCPULoadInfo() -> host_cpu_load_info {
        var count: mach_msg_type_number_t = hostCPULoadInfoMemoryCount
        var hostInfo = host_cpu_load_info()

        let kernResult: kern_return_t = withUnsafeMutablePointer(to: &hostInfo, {
            host_statistics(
                mach_host_self(),
                HOST_CPU_LOAD_INFO,
                $0.withMemoryRebound(to: integer_t.self, capacity: 1, { $0 }),
                &count
            )
        })

        if kernResult != KERN_SUCCESS { return host_cpu_load_info() }
        return hostInfo
    }

    
    func getCPUUsage() -> CPUUsage {
        let newLoadInfo = self.getHostCPULoadInfo()
        let cpuUsage = CPUUsage(newLoadInfo, previousLoadInfo)
        previousLoadInfo = newLoadInfo
        return cpuUsage
    }
    
    func getMemoryInfo() -> MemoryInfo {
        var count: mach_msg_type_number_t = machineTaskBasicInfoMemoryCount
        var memoryInfo = mach_task_basic_info()

        let kernResult: kern_return_t = withUnsafeMutablePointer(to: &memoryInfo, {
            task_info(mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                $0.withMemoryRebound(to: integer_t.self, capacity: 1, { $0 }),
                &count)
        })
        
        if kernResult != KERN_SUCCESS { return MemoryInfo(mach_task_basic_info()) }
        return MemoryInfo(memoryInfo)
    }
    
    func getDiskStorageInfo() -> DiskStorageInfo {
        let attributes = (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())) ?? [:]
        return DiskStorageInfo(attributes)
    }
}
