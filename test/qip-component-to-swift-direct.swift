var memory = [UInt8](repeating: 0, count: memorySize)
var dirty = [UInt64](repeating: 0, count: requiredDirtyWords(memorySize))
var generation: UInt64 = 0
var instance = Instance()
let input = Array("direct".utf8)
let expected = Array("didire".utf8)
memory.replaceSubrange(Int(inputOffset)..<Int(inputOffset) + input.count, with: input)
memory.withUnsafeMutableBytes { m in dirty.withUnsafeMutableBufferPointer { d in withUnsafeMutablePointer(to: &generation) { g in
    precondition(initialize(&instance, memory: m, dirtyPages: d, generation: g, inputSize: UInt32(input.count)) == .ok)
    var offset: UInt32 = 0, size: UInt32 = 0
    precondition(render(&instance, inputSize: UInt32(input.count), outputOffset: &offset, outputSize: &size) == .ok)
    precondition(Array(m[Int(offset)..<Int(offset + size)]) == expected)
} } }
