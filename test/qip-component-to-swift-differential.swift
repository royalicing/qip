import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()
precondition(input.count <= Int(inputCapacity))
var memory = [UInt8](repeating: 0, count: memorySize)
var dirty = [UInt64](repeating: 0, count: requiredDirtyWords(memorySize))
var generation: UInt64 = 0
var instance = Instance()
memory.replaceSubrange(Int(inputOffset)..<Int(inputOffset) + input.count, with: input)
let output: Data = memory.withUnsafeMutableBytes { m in
    dirty.withUnsafeMutableBufferPointer { d in
        withUnsafeMutablePointer(to: &generation) { g in
            precondition(initialize(&instance, memory: m, dirtyPages: d, generation: g, inputSize: UInt32(input.count)) == .ok)
            var offset: UInt32 = 0, size: UInt32 = 0
            precondition(render(&instance, inputSize: UInt32(input.count), outputOffset: &offset, outputSize: &size) == .ok)
            return Data(m[Int(offset)..<Int(offset + size)])
        }
    }
}
FileHandle.standardOutput.write(output)

