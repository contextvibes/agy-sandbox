import Foundation
import Darwin

// APFS High-Performance Disk Compactor
// Compilation: swiftc -O -parse-as-library host/runners/compact_image.swift -o host/runners/compact_image
// Usage:       ./host/runners/compact_image <disk_image_path> [options]

// Darwin-specific command for hole punching
let F_PUNCHHOLE: Int32 = 99

// Struct used by fcntl F_PUNCHHOLE
struct fpunchhole {
    var fp_flags: UInt32 = 0
    var reserved: UInt32 = 0
    var fp_offset: Int64
    var fp_length: Int64
}

@main
struct CompactImage {
    static func main() {
        print("🍏 APFS High-Performance Disk Compactor")
        print("──────────────────────────────────────────────────────────")
        
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            printUsageAndExit()
        }
        
        let filePath = args[1]
        var dryRun = false
        var verbose = false
        var customBlockSize = 4096
        
        var i = 2
        while i < args.count {
            switch args[i] {
            case "--dry-run":
                dryRun = true
                i += 1
            case "--verbose":
                verbose = true
                i += 1
            case "--block-size":
                guard i + 1 < args.count, let bs = Int(args[i+1]), bs > 0 else {
                    print("❌ Error: --block-size requires a positive integer value.")
                    exit(1)
                }
                customBlockSize = bs
                i += 2
            default:
                print("⚠️ Unknown option: \(args[i])")
                printUsageAndExit()
            }
        }
        
        // Ensure block size is a multiple of 8 for alignment-safe fast UInt64 checking
        if customBlockSize % 8 != 0 {
            print("❌ Error: Block size must be a multiple of 8 bytes for high-performance alignment.")
            exit(1)
        }
        
        // Resolve absolute path
        let fileManager = FileManager.default
        let absolutePath: String
        if filePath.hasPrefix("/") {
            absolutePath = filePath
        } else {
            absolutePath = fileManager.currentDirectoryPath + "/" + filePath
        }
        
        guard fileManager.fileExists(atPath: absolutePath) else {
            print("❌ Error: File does not exist at path: \(filePath)")
            exit(1)
        }
        
        // Open the file
        // If dry-run, we can open as read-only; otherwise, we need read-write
        let openFlags = dryRun ? O_RDONLY : O_RDWR
        let fd = open(absolutePath, openFlags)
        guard fd >= 0 else {
            let errStr = String(cString: strerror(errno))
            print("❌ Error: Failed to open file: \(errStr)")
            exit(1)
        }
        defer {
            close(fd)
        }
        
        // Safety lock check: try to lock the file exclusively
        // This fails if another process (e.g. the NixOS or macOS VM runner) is using it
        let lockResult = flock(fd, LOCK_EX | LOCK_NB)
        if lockResult != 0 {
            let errStr = String(cString: strerror(errno))
            print("❌ Error: Could not acquire exclusive lock on file: \(errStr)")
            print("ℹ️ The disk image might be in use by a running VM. Please shut down the VM before running compaction.")
            exit(1)
        }
        defer {
            _ = flock(fd, LOCK_UN)
        }
        
        // Get initial file statistics
        var st = stat()
        guard stat(absolutePath, &st) == 0 else {
            let errStr = String(cString: strerror(errno))
            print("❌ Error: Failed to stat file: \(errStr)")
            exit(1)
        }
        
        let logicalSize = st.st_size
        let originalPhysicalSize = Int64(st.st_blocks) * 512
        
        print("📂 Target File:    \(filePath)")
        print("📊 Logical Size:   \(formatBytes(logicalSize))")
        print("💾 Physical Size:  \(formatBytes(originalPhysicalSize))")
        let sparsePercentage = logicalSize > 0 ? (1.0 - Double(originalPhysicalSize) / Double(logicalSize)) * 100.0 : 0.0
        print("🔗 Sparseness:     \(String(format: "%.1f%%", sparsePercentage)) (already hollowed out)")
        if dryRun {
            print("🧪 Mode:           DRY RUN (scan only, no holes will be punched)")
        } else {
            print("⚡ Mode:           REAL COMPACTION (write/punchhole active)")
        }
        print("──────────────────────────────────────────────────────────")
        
        if logicalSize % Int64(customBlockSize) != 0 {
            print("ℹ️ Note: File size is not a multiple of \(customBlockSize) bytes. The trailing partial block of \(logicalSize % Int64(customBlockSize)) bytes cannot be APFS hole-punched and will be skipped.")
        }


        
        // Set up high performance sequential scanning
        // 2 MB buffer size, page-aligned to 4096 bytes
        let bufferSize = 2 * 1024 * 1024
        let blockSize = customBlockSize
        
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 4096)
        defer {
            buffer.deallocate()
        }
        
        var currentBufferFileOffset: Int64 = 0
        var totalHolesPunched = 0
        var totalBytesPunched: Int64 = 0
        
        var currentRunStart: Int64 = -1
        var currentRunLength: Int64 = 0
        
        let startTime = Date()
        var lastProgressUpdate = Date()
        
        func commitHole() {
            guard currentRunStart != -1 && currentRunLength > 0 else { return }
            
            if !dryRun {
                var hole = fpunchhole(fp_flags: 0, reserved: 0, fp_offset: currentRunStart, fp_length: currentRunLength)
                let res = fcntl(fd, F_PUNCHHOLE, &hole)
                if res == -1 {
                    let errStr = String(cString: strerror(errno))
                    print("\n⚠️ Failed to punch hole at offset \(currentRunStart) of length \(currentRunLength): \(errStr)")
                } else {
                    totalHolesPunched += 1
                    totalBytesPunched += currentRunLength
                    if verbose {
                        print("\n  [Punch] Offset: \(currentRunStart), Length: \(formatBytes(currentRunLength))")
                    }
                }
            } else {
                totalHolesPunched += 1
                totalBytesPunched += currentRunLength
                if verbose {
                    print("\n  [Dry-Run Hole] Offset: \(currentRunStart), Length: \(formatBytes(currentRunLength))")
                }
            }
            
            currentRunStart = -1
            currentRunLength = 0
        }
        
        // Sequential scan loop
        while true {
            let bytesRead = read(fd, buffer.baseAddress!, bufferSize)
            if bytesRead < 0 {
                let errStr = String(cString: strerror(errno))
                print("\n❌ Error: Read failure: \(errStr)")
                exit(1)
            }
            if bytesRead == 0 {
                break // EOF
            }
            
            let completeBlocks = bytesRead / blockSize
            
            for b in 0..<completeBlocks {
                let blockOffset = b * blockSize
                let blockPtr = buffer.baseAddress! + blockOffset
                let isZero = isAllZero(pointer: blockPtr, size: blockSize)
                
                let blockFileOffset = currentBufferFileOffset + Int64(blockOffset)
                
                if isZero {
                    if currentRunStart == -1 {
                        currentRunStart = blockFileOffset
                        currentRunLength = Int64(blockSize)
                    } else {
                        currentRunLength += Int64(blockSize)
                    }
                } else {
                    if currentRunStart != -1 {
                        commitHole()
                    }
                }
            }
            
            // If the buffer read has a leftover block or is partial, we commit any active run
            if completeBlocks * blockSize < bytesRead {
                if currentRunStart != -1 {
                    commitHole()
                }
            }
            
            currentBufferFileOffset += Int64(bytesRead)
            
            // Throttle progress bar to avoid terminal spam
            let now = Date()
            if now.timeIntervalSince(lastProgressUpdate) >= 0.1 || currentBufferFileOffset == logicalSize {
                printProgressBar(current: currentBufferFileOffset, total: logicalSize, startTime: startTime)
                lastProgressUpdate = now
            }
        }
        
        // Finalize trailing run if any
        if currentRunStart != -1 {
            commitHole()
        }
        
        print("\n──────────────────────────────────────────────────────────")
        let totalDuration = Date().timeIntervalSince(startTime)
        print(String(format: "⏱️ Completed in:   %.2f seconds", totalDuration))
        print("🔍 Scanned Blocks:  \(logicalSize / Int64(blockSize)) blocks")
        print("🕳️ Holes Identified:\(totalHolesPunched)")
        print("📊 Zeroes Scanned:  \(formatBytes(totalBytesPunched))")
        
        // Query final physical size to determine actual space reclaimed on host disk
        var finalSt = stat()
        var finalPhysicalSize = originalPhysicalSize
        if stat(absolutePath, &finalSt) == 0 {
            finalPhysicalSize = Int64(finalSt.st_blocks) * 512
        }
        
        let actualReclaimed = originalPhysicalSize - finalPhysicalSize
        
        if dryRun {
            print("💡 Potential Reclaim:\(formatBytes(totalBytesPunched)) of zeroed blocks could be deallocated.")
        } else {
            print("💾 New Phys. Size:  \(formatBytes(finalPhysicalSize))")
            if actualReclaimed > 0 {
                let reclaimPercent = originalPhysicalSize > 0 ? (Double(actualReclaimed) / Double(originalPhysicalSize)) * 100.0 : 0.0
                print(String(format: "✨ Actual Reclaimed: %@ (Reduced by %.1f%%)", formatBytes(actualReclaimed), reclaimPercent))
            } else {
                print("ℹ️ Reclaimed Space: 0 B (The file was already fully compacted!)")
            }
        }
    }
    
    // Check if block contains only zeros using fast vectorized checking
    @inline(__always)
    private static func isAllZero(pointer: UnsafeRawPointer, size: Int) -> Bool {
        let count = size / 8
        let u64Ptr = pointer.bindMemory(to: UInt64.self, capacity: count)
        for i in 0..<count {
            if u64Ptr[i] != 0 {
                return false
            }
        }
        return true
    }
    
    // Human readable byte formatting
    private static func formatBytes(_ bytes: Int64) -> String {
        let absBytes = abs(bytes)
        let kb = Double(absBytes) / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0
        let tb = gb / 1024.0
        
        let sign = bytes < 0 ? "-" : ""
        
        if tb >= 1.0 {
            return String(format: "%@%.2f TB", sign, tb)
        } else if gb >= 1.0 {
            return String(format: "%@%.2f GB", sign, gb)
        } else if mb >= 1.0 {
            return String(format: "%@%.2f MB", sign, mb)
        } else if kb >= 1.0 {
            return String(format: "%@%.2f KB", sign, kb)
        } else {
            return "\(sign)\(absBytes) B"
        }
    }
    
    // Beautiful interactive progress bar
    private static func printProgressBar(current: Int64, total: Int64, startTime: Date) {
        let width = 30
        let percentage = total > 0 ? Double(current) / Double(total) : 1.0
        let progress = Int(percentage * Double(width))
        let bar = String(repeating: "█", count: progress) + String(repeating: "░", count: width - progress)
        
        let elapsed = Date().timeIntervalSince(startTime)
        let speed = elapsed > 0 ? Double(current) / elapsed : 0.0
        let speedStr = formatBytes(Int64(speed)) + "/s"
        
        let pctStr = String(format: "%.1f%%", percentage * 100)
        
        print(String(format: "\r⌛ Progress: [%@] %@ (%@)", bar, pctStr, speedStr), terminator: "")
        fflush(stdout)
    }
    
    private static func printUsageAndExit() -> Never {
        print("""
        Usage: ./compact_image <disk_image_path> [options]
        
        Options:
          --dry-run             Perform a dry run (scan only, do not punch holes)
          --verbose             Print details of each punched hole range
          --block-size <bytes>  Checking block size in bytes (default: 4096, must be multiple of 8)
        """)
        exit(1)
    }
}
