//
//  DeviceArchitecture.swift
//  Pindrop
//
//  Created on 2026-07-31.
//

import Foundation

enum DeviceArchitecture {
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
}
