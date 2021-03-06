//
//  readers.swift
//  CPU
//
//  Created by Serhiy Mytrovtsiy on 10/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import StatsKit
import ModuleKit
import os.log

internal class LoadReader: Reader<CPU_Load> {
    public var store: UnsafePointer<Store>? = nil
    
    private var cpuInfo: processor_info_array_t!
    private var prevCpuInfo: processor_info_array_t?
    private var numCpuInfo: mach_msg_type_number_t = 0
    private var numPrevCpuInfo: mach_msg_type_number_t = 0
    private var numCPUs: uint = 0
    private let CPUUsageLock: NSLock = NSLock()
    private var previousInfo = host_cpu_load_info()
    private var hasHyperthreadingCores = false
    
    private var response: CPU_Load = CPU_Load()
    private var numCPUsU: natural_t = 0
    private var usagePerCore: [Double] = []
    
    public override func setup() {
        self.hasHyperthreadingCores = SysctlByName("hw.physicalcpu") != SysctlByName("hw.logicalcpu")
        [CTL_HW, HW_NCPU].withUnsafeBufferPointer() { mib in
            var sizeOfNumCPUs: size_t = MemoryLayout<uint>.size
            let status = sysctl(processor_info_array_t(mutating: mib.baseAddress), 2, &numCPUs, &sizeOfNumCPUs, nil, 0)
            if status != 0 {
                self.numCPUs = 1
            }
        }
    }
    
    public override func read() {
        let result: kern_return_t = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &self.numCPUsU, &self.cpuInfo, &self.numCpuInfo)
        if result == KERN_SUCCESS {
            self.CPUUsageLock.lock()
            self.usagePerCore = []
            
            for i in 0 ..< Int32(numCPUs) {
                var inUse: Int32
                var total: Int32
                if let prevCpuInfo = self.prevCpuInfo {
                    inUse = self.cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_USER)]
                        - prevCpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_USER)]
                        + self.cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_SYSTEM)]
                        - prevCpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_SYSTEM)]
                        + self.cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_NICE)]
                        - prevCpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_NICE)]
                    total = inUse + (self.cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_IDLE)]
                        - prevCpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_IDLE)])
                } else {
                    inUse = self.cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_USER)]
                        + self.cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_SYSTEM)]
                        + self.cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_NICE)]
                    total = inUse + self.cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_IDLE)]
                }
                
                if total != 0 {
                    self.usagePerCore.append(Double(inUse) / Double(total))
                }
            }
            self.CPUUsageLock.unlock()
            
            let showHyperthratedCores = self.store?.pointee.bool(key: "CPU_hyperhreading", defaultValue: false) ?? false
            if showHyperthratedCores || !self.hasHyperthreadingCores {
                self.response.usagePerCore = self.usagePerCore
            } else {
                var i = 0
                var a = 0
                
                self.response.usagePerCore = []
                while i < Int(self.usagePerCore.count/2) {
                    a = i*2
                    if self.usagePerCore.indices.contains(a) && self.usagePerCore.indices.contains(a+1) {
                        self.response.usagePerCore.append((Double(self.usagePerCore[a]) + Double(self.usagePerCore[a+1])) / 2)
                    }
                    i += 1
                }
            }
            
            if let prevCpuInfo = self.prevCpuInfo {
                let prevCpuInfoSize: size_t = MemoryLayout<integer_t>.stride * Int(self.numPrevCpuInfo)
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prevCpuInfo), vm_size_t(prevCpuInfoSize))
            }
            
            self.prevCpuInfo = self.cpuInfo
            self.numPrevCpuInfo = self.numCpuInfo
            
            self.cpuInfo = nil
            self.numCpuInfo = 0
        } else {
            os_log(.error, log: log, "host_processor_info(): %s", "\((String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))")
        }
        
        let cpuInfo = hostCPULoadInfo()
        if cpuInfo == nil {
            self.callback(nil)
            return
        }
        
        let userDiff = Double(cpuInfo!.cpu_ticks.0 - self.previousInfo.cpu_ticks.0)
        let sysDiff  = Double(cpuInfo!.cpu_ticks.1 - self.previousInfo.cpu_ticks.1)
        let idleDiff = Double(cpuInfo!.cpu_ticks.2 - self.previousInfo.cpu_ticks.2)
        let niceDiff = Double(cpuInfo!.cpu_ticks.3 - self.previousInfo.cpu_ticks.3)
        let totalTicks = sysDiff + userDiff + niceDiff + idleDiff
        
        let system = sysDiff  / totalTicks
        let user = userDiff  / totalTicks
        let idle = idleDiff  / totalTicks
        
        if !system.isNaN {
            self.response.systemLoad  = system
        }
        if !user.isNaN {
            self.response.userLoad = user
        }
        if !idle.isNaN {
            self.response.idleLoad = idle
        }
        self.previousInfo = cpuInfo!
        self.response.totalUsage = self.response.systemLoad + self.response.userLoad
        
        self.callback(self.response)
    }
    
    private func hostCPULoadInfo() -> host_cpu_load_info? {
        let HOST_CPU_LOAD_INFO_COUNT = MemoryLayout<host_cpu_load_info>.stride/MemoryLayout<integer_t>.stride
        var size = mach_msg_type_number_t(HOST_CPU_LOAD_INFO_COUNT)
        var cpuLoadInfo = host_cpu_load_info()
        
        let result: kern_return_t = withUnsafeMutablePointer(to: &cpuLoadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: HOST_CPU_LOAD_INFO_COUNT) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        if result != KERN_SUCCESS {
            os_log(.error, log: log, "kern_result_t: %s", "\(result)")
            return nil
        }
        
        return cpuLoadInfo
    }
}

public class ProcessReader: Reader<[TopProcess]> {
    private let store: UnsafePointer<Store>
    private let title: String
    
    private var numberOfProcesses: Int {
        get {
            return self.store.pointee.int(key: "\(self.title)_processes", defaultValue: 8)
        }
    }
    
    init(_ title: String, store: UnsafePointer<Store>) {
        self.title = title
        self.store = store
        super.init()
    }
    
    public override func setup() {
        self.popup = true
    }
    
    public override func read() {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-Aceo pid,pcpu,comm", "-r"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        
        do {
            try task.run()
        } catch let error {
            os_log(.error, log: log, "error read ps: %s", "\(error.localizedDescription)")
            return
        }
        
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
        _ = String(decoding: errorData, as: UTF8.self)
        
        if output.isEmpty {
            return
        }
        
        var index = 0
        var processes: [TopProcess] = []
        output.enumerateLines { (line, stop) -> () in
            if index != 0 {
                var str = line.trimmingCharacters(in: .whitespaces)
                let pidString = str.findAndCrop(pattern: "^\\d+")
                let usageString = str.findAndCrop(pattern: "^[0-9,.]+ ")
                let command = str.trimmingCharacters(in: .whitespaces)
                
                let pid = Int(pidString) ?? 0
                let usage = Double(usageString.replacingOccurrences(of: ",", with: ".")) ?? 0
                
                var name: String? = nil
                var icon: NSImage? = nil
                if let app = NSRunningApplication(processIdentifier: pid_t(pid) ) {
                    name = app.localizedName ?? nil
                    icon = app.icon
                }
                
                processes.append(TopProcess(pid: pid, command: command, name: name, usage: usage, icon: icon))
            }
            
            if index == self.numberOfProcesses { stop = true }
            index += 1
        }
        
        self.callback(processes)
    }
}

public class AdditionalReader: Reader<CPU_additional> {
    private let smc: UnsafePointer<SMCService>?
    private var data: CPU_additional = CPU_additional()
    
    init(_ smc: UnsafePointer<SMCService>) {
        self.smc = smc
        super.init()
        self.popup = true
    }
    
    public override func setup() {
        PG_getCPUFrequency()
        PG_getCPUFrequency()
    }
    
    public override func read() {
        if let readFrequency = PG_getCPUFrequency() {
            self.data.frequency = readFrequency.pointee
        }
        
        self.data.temperature = self.smc?.pointee.getValue("TC0C") ?? self.smc?.pointee.getValue("TC0D") ?? self.smc?.pointee.getValue("TC0P") ?? self.smc?.pointee.getValue("TC0E")
        
        self.callback(self.data)
    }
}
