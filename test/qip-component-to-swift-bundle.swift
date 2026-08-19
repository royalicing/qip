import HelloComponent
import TrimComponent

let memorySize = max(HelloComponent.memorySize, TrimComponent.memorySize)
var memory = [UInt8](repeating: 0, count: memorySize)
var dirty = [UInt64](repeating: 0, count: HelloComponent.requiredDirtyWords(memorySize))
var generation: UInt64 = 0
var first = HelloComponent.Instance()
var second = TrimComponent.Instance()
let input = Array("  Swift  ".utf8)
memory.replaceSubrange(Int(HelloComponent.inputOffset)..<Int(HelloComponent.inputOffset) + input.count, with: input)

memory.withUnsafeMutableBytes { m in
    dirty.withUnsafeMutableBufferPointer { d in
        withUnsafeMutablePointer(to: &generation) { g in
            precondition(HelloComponent.initialize(&first, memory: m, dirtyPages: d, generation: g, inputSize: UInt32(input.count)) == .ok)
            var offset: UInt32 = 0, size: UInt32 = 0
            precondition(HelloComponent.render(&first, inputSize: UInt32(input.count), outputOffset: &offset, outputSize: &size) == .ok)
            let intermediate = Array(m[Int(offset)..<Int(offset + size)])
            for (n, byte) in intermediate.enumerated() { m[Int(TrimComponent.inputOffset) + n] = byte }
            precondition(TrimComponent.initialize(&second, memory: m, dirtyPages: d, generation: g, inputSize: size) == .ok)
            precondition(TrimComponent.render(&second, inputSize: size, outputOffset: &offset, outputSize: &size) == .ok)
            precondition(HelloComponent.render(&first, inputSize: UInt32(input.count), outputOffset: &offset, outputSize: &size) == .staleInstance)
            precondition(String(decoding: m[Int(offset)..<Int(offset + size)], as: UTF8.self) == "Hello,   Swift")
        }
    }
}

