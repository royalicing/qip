var memory = [UInt8](repeating: 0, count: memorySize)
var dirty = [UInt64](repeating: 0, count: requiredDirtyWords(memorySize))
var generation: UInt64 = 0
var instance = Instance()
let input = Array("world".utf8)
memory.replaceSubrange(Int(inputOffset)..<Int(inputOffset) + input.count, with: input)
let status = memory.withUnsafeMutableBytes { memoryBuffer in
    dirty.withUnsafeMutableBufferPointer { dirtyBuffer in
        withUnsafeMutablePointer(to: &generation) { generationPointer in
            guard initialize(&instance, memory: memoryBuffer, dirtyPages: dirtyBuffer, generation: generationPointer, inputSize: UInt32(input.count)) == .ok else { return Status.invalidArgument }
            var offset: UInt32 = 0
            var size: UInt32 = 0
            let status = render(&instance, inputSize: UInt32(input.count), outputOffset: &offset, outputSize: &size)
            if status == .ok { precondition(String(decoding: memoryBuffer[Int(offset)..<Int(offset + size)], as: UTF8.self) == "Hello, world") }
            return status
        }
    }
}
precondition(status == .ok)

