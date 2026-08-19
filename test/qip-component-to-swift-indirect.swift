var memory = [UInt8](repeating: 0, count: memorySize)
var dirty = [UInt64](repeating: 0, count: requiredDirtyWords(memorySize))
var generation: UInt64 = 0
var instance = Instance()
memory.withUnsafeMutableBytes { m in
    dirty.withUnsafeMutableBufferPointer { d in
        withUnsafeMutablePointer(to: &generation) { g in
            precondition(initialize(&instance, memory: m, dirtyPages: d, generation: g, inputSize: 1) == .ok)
            func check(_ byte: UInt8, _ expected: Status) {
                m[Int(inputOffset)] = byte
                var offset: UInt32 = 0, size: UInt32 = 0
                precondition(render(&instance, inputSize: 1, outputOffset: &offset, outputSize: &size) == expected)
                if expected == .ok { precondition(Array(m[Int(offset)..<Int(offset + size)]) == Array("ok".utf8)) }
            }
            check(118, .ok); check(110, .trapIndirectNull); check(118, .ok)
            check(111, .trapTableOutOfBounds); check(118, .ok)
            check(116, .trapIndirectType); check(118, .ok)
            check(114, .trapCallDepth); check(118, .ok)
        }
    }
}

