// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

#if canImport(Darwin)
import Darwin
#endif

struct ProcessMemorySnapshot: Equatable {
    let physicalFootprintBytes: UInt64

    var physicalFootprintMegabytes: Double {
        Double(physicalFootprintBytes) / 1_048_576.0
    }
}

enum ProcessMemoryReader {
    static func current() -> ProcessMemorySnapshot? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_,
                          task_flavor_t(TASK_VM_INFO),
                          reboundPointer,
                          &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }
        return ProcessMemorySnapshot(physicalFootprintBytes: info.phys_footprint)
        #else
        return nil
        #endif
    }
}
