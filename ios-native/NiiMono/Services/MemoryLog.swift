//
//  MemoryLog.swift — physical memory footprint of the process, for the console log
//  during the heavy stages (the number jetsam judges the app by).
//

import Foundation
import os

enum MemoryLog {
    static let log = Logger(subsystem: "org.niivue.NiiMono", category: "memory")

    /// Resident footprint in bytes (task_vm_info.phys_footprint), or nil if unavailable.
    static var footprint: UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// `memory: <stage>  footprint 2.31 GB  (available 3.90 GB)` in the console.
    static func mark(_ stage: String) {
        let fp = footprint.map { String(format: "%.2f GB", Double($0) / 1e9) } ?? "?"
        #if os(iOS)
        let avail = String(format: "  (available %.2f GB)", Double(os_proc_available_memory()) / 1e9)
        #else
        let avail = ""
        #endif
        log.notice("memory: \(stage, privacy: .public)  footprint \(fp, privacy: .public)\(avail, privacy: .public)")
        print("memory: \(stage)  footprint \(fp)\(avail)")
    }
}
