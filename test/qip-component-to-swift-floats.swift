func read(_ memory: UnsafeMutableRawBufferPointer, _ offset: Int, _ width: Int) -> UInt64 {
    var value: UInt64 = 0
    for n in 0..<width { value |= UInt64(memory[offset + n]) << UInt64(n * 8) }
    return value
}
var memory = [UInt8](repeating: 0, count: memorySize)
var dirty = [UInt64](repeating: 0, count: requiredDirtyWords(memorySize))
var generation: UInt64 = 0
var instance = Instance()
memory.withUnsafeMutableBytes { m in
    dirty.withUnsafeMutableBufferPointer { d in
        withUnsafeMutablePointer(to: &generation) { g in
            precondition(initialize(&instance, memory: m, dirtyPages: d, generation: g, inputSize: 0) == .ok)
            var offset: UInt32 = 0, size: UInt32 = 0
            precondition(render(&instance, inputSize: 0, outputOffset: &offset, outputSize: &size) == .ok)
            precondition(offset == 64 && size == 88)
            precondition(read(m, 64, 4) == 0x40000000)
            precondition(read(m, 68, 4) == 0x80000000)
            precondition(read(m, 72, 4) == 0x80000000)
            precondition(read(m, 96, 8) == 0x4000000000000000)
            precondition(read(m, 104, 8) == 0x8000000000000000)
        }
    }
}

