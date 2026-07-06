import Metal
import Foundation

print("🚀 Starting GPU Metal Acceleration Test in Swift Script...")

// 1. Get the paravirtualized GPU device
guard let device = MTLCreateSystemDefaultDevice() else {
    print("❌ Error: Metal (GPU acceleration) is not supported or enabled on this system.")
    exit(1)
}
print("✨ Found Metal GPU Device Name: \(device.name)")

// 2. Define the Metal Shading Language kernel shader code
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

kernel void add_arrays(device const float* inA [[buffer(0)]],
                       device const float* inB [[buffer(1)]],
                       device float* outC [[buffer(2)]],
                       uint id [[thread_position_in_grid]]) {
    outC[id] = inA[id] + inB[id];
}
"""

// 3. Compile the shader dynamically from our string
print("🔨 Compiling Metal Shader...")
do {
    let library = try device.makeLibrary(source: shaderSource, options: nil)
    guard let addFunction = library.makeFunction(name: "add_arrays") else {
        print("❌ Error: Could not find function 'add_arrays' in compiled library.")
        exit(1)
    }
    
    // 4. Create Compute Pipeline State
    let pipelineState = try device.makeComputePipelineState(function: addFunction)
    
    // 5. Create mock data
    let count = 100_000
    let size = count * MemoryLayout<Float>.size
    print("📦 Initializing test buffers of size \(count) elements (\(size) bytes)...")
    
    var arrayA = (0..<count).map { Float($0) }
    var arrayB = (0..<count).map { Float($0 * 2) }
    
    // 6. Create GPU shared buffers (accessible by both CPU and VM's virtualized GPU)
    guard let bufferA = device.makeBuffer(bytes: &arrayA, length: size, options: .storageModeShared),
          let bufferB = device.makeBuffer(bytes: &arrayB, length: size, options: .storageModeShared),
          let bufferC = device.makeBuffer(length: size, options: .storageModeShared) else {
        print("❌ Error: Could not allocate shared GPU buffers.")
        exit(1)
    }
    
    // 7. Command queue and encoding
    print("🏁 Creating command encoder and dispatching threads to GPU...")
    guard let commandQueue = device.makeCommandQueue(),
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
        print("❌ Error: Could not initialize command queue or encoder.")
        exit(1)
    }
    
    computeEncoder.setComputePipelineState(pipelineState)
    computeEncoder.setBuffer(bufferA, offset: 0, index: 0)
    computeEncoder.setBuffer(bufferB, offset: 0, index: 1)
    computeEncoder.setBuffer(bufferC, offset: 0, index: 2)
    
    // Determine thread configuration
    let threadsPerGroup = min(pipelineState.maxTotalThreadsPerThreadgroup, count)
    let gridSize = MTLSize(width: count, height: 1, depth: 1)
    let threadgroupSize = MTLSize(width: threadsPerGroup, height: 1, depth: 1)
    
    computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
    computeEncoder.endEncoding()
    
    // 8. Commit command buffer and wait for completion
    print("⏳ Executing kernel on GPU...")
    let startTime = CFAbsoluteTimeGetCurrent()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    let duration = CFAbsoluteTimeGetCurrent() - startTime
    
    // 9. Read back and verify the results
    let resultPointer = bufferC.contents().assumingMemoryBound(to: Float.self)
    print("🎉 Success! Compute task completed on paravirtualized GPU in \(duration) seconds.")
    
    // Verify first 5 elements
    print("\nVerification (First 5 elements):")
    for i in 0..<5 {
        let expected = arrayA[i] + arrayB[i]
        let actual = resultPointer[i]
        let status = expected == actual ? "✅ OK" : "❌ MISMATCH"
        print("  Index [\(i)]: \(arrayA[i]) + \(arrayB[i]) = \(actual) (\(status))")
    }
    
} catch {
    print("❌ Unexpected Error during shader compilation or pipeline setup: \(error)")
    exit(1)
}
