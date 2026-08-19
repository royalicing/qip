var memory = [UInt8](repeating: 0, count: memorySize)
var dirty = [UInt64](repeating: 0, count: requiredDirtyWords(memorySize))
var generation: UInt64 = 0
var instance = Instance()
memory.withUnsafeMutableBytes { m in dirty.withUnsafeMutableBufferPointer { d in withUnsafeMutablePointer(to: &generation) { g in
    precondition(initialize(&instance, memory: m, dirtyPages: d, generation: g, inputSize: 0) == .ok)
    var offset: UInt32 = 0, size: UInt32 = 0
    precondition(render(&instance, inputSize: 0, outputOffset: &offset, outputSize: &size) == .trapUnreachable)
} } }

