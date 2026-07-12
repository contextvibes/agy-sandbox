import Cocoa
import Virtualization
import Darwin

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @preconcurrency VZVirtualMachineDelegate {
    
    static func main() {
        _ = umask(0o077)
        
        print("🍏 Native macOS Virtualization.framework Runner (Hardened & Modernized)")
        print("────────────────────────────────────────────────────────────────────────")
        
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.parseCommandLine()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
    
    // Command line arguments parsed/passed
    private var ipswPath: String = ""
    private var diskPath: String = ""
    private var auxPath: String = ""
    private var macIdPath: String = ""
    private var hwModelPath: String = ""
    private var cpus: Int = 0
    private var memoryMB: Int = 0
    private var width: Int = 1920
    private var height: Int = 1080
    private var autoDiskSizeGB: Int = 64
    private var thickProvision: Bool = false
    private var sharedDirPath: String = ""
    private var ppi: Int = 110
    
    private var isInstalling: Bool = false
    private var vm: VZVirtualMachine?
    private var installer: VZMacOSInstaller?
    private var progressObservation: NSKeyValueObservation?
    private var window: NSWindow?
    private var isStopping: Bool = false
    private var activityToken: NSObjectProtocol?
    
    private var signalSources: [DispatchSourceSignal] = []
    
    func parseCommandLine() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            printUsageAndExit()
        }
        
        var i = 1
        func value(for option: String) -> String {
            guard i + 1 < arguments.count else {
                print("❌ Error: Missing value for \(option)")
                exit(1)
            }
            let val = arguments[i+1]
            i += 2
            return val
        }
        
        while i < arguments.count {
            switch arguments[i] {
            case "--ipsw": ipswPath = value(for: "--ipsw")
            case "--disk": diskPath = value(for: "--disk")
            case "--aux": auxPath = value(for: "--aux")
            case "--mac-id": macIdPath = value(for: "--mac-id")
            case "--hw-model": hwModelPath = value(for: "--hw-model")
            case "--cpus": cpus = Int(value(for: "--cpus")) ?? 0
            case "--memory": memoryMB = Int(value(for: "--memory")) ?? 0
            case "--width": width = Int(value(for: "--width")) ?? 1920
            case "--height": height = Int(value(for: "--height")) ?? 1080
            case "--disk-size": autoDiskSizeGB = Int(value(for: "--disk-size")) ?? 64
            case "--shared-dir": sharedDirPath = value(for: "--shared-dir")
            case "--ppi": ppi = Int(value(for: "--ppi")) ?? 110
            case "--thick-provision":
                thickProvision = true
                i += 1
            default:
                print("⚠️ Unknown argument: \(arguments[i])")
                exit(1)
            }
        }
        
        guard !diskPath.isEmpty else {
            print("❌ Error: --disk is required")
            exit(1)
        }
        
        // Host-Aware Resource Auto-Scaling
        let hostCores = ProcessInfo.processInfo.activeProcessorCount
        let defaultCPUs = max(4, min(8, hostCores / 2))
        
        let hostMemoryBytes = ProcessInfo.processInfo.physicalMemory
        let hostMemoryMB = Int(hostMemoryBytes / 1024 / 1024)
        let defaultMemoryMB = max(4096, min(16384, hostMemoryMB / 4))
        
        if cpus == 0 {
            cpus = defaultCPUs
            print("ℹ️ Auto-scaled vCPUs to \(cpus) (Host logical cores: \(hostCores))")
        }
        if memoryMB == 0 {
            memoryMB = defaultMemoryMB
            print("ℹ️ Auto-scaled memory to \(memoryMB) MB (Host physical memory: \(hostMemoryMB) MB)")
        }
        
        if auxPath.isEmpty { auxPath = diskPath + ".aux" }
        if macIdPath.isEmpty { macIdPath = diskPath + ".id" }
        if hwModelPath.isEmpty { hwModelPath = diskPath + ".hw" }
        isInstalling = !ipswPath.isEmpty
    }
    
    private func printUsageAndExit() -> Never {
        print("""
        Usage:
          Install: ./vz_macos_runner --ipsw <path_to_ipsw> --disk <path_to_disk> [options]
          Boot:    ./vz_macos_runner --disk <path_to_disk> [options]
        
        Options:
          --ipsw <path>        Path to Apple Restore Image (.ipsw) [Required for Install]
          --disk <path>        Path to guest virtual SSD image [Required]
          --aux <path>         Path to NVRAM auxiliary storage (default: <disk>.aux)
          --mac-id <path>      Path to machine identifier data (default: <disk>.id)
          --hw-model <path>    Path to hardware model data (default: <disk>.hw)
          --cpus <count>       vCPU core allocation (default: 4, best for macOS guests)
          --memory <MB>        RAM allocation in MB (default: 4096)
          --width <pixels>     Display width (default: 1920)
          --height <pixels>    Display height (default: 1080)
          --ppi <density>      Pixels per inch density (e.g. 110 for standard, 220 for Retina/High-DPI)
          --disk-size <GB>     Autocreate sparse disk size in GB if missing (default: 64)
          --thick-provision    Pre-allocate physical disk blocks immediately to prevent host out-of-space crash
          --shared-dir <path>  Path to host directory/drive to share with the guest (automounts in macOS guest)
        """)
        exit(1)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run setup inside a non-blocking MainActor-bound Task
        Task {
            do {
                try await setupAndRunVM()
            } catch {
                print("❌ Fatal setup error: \(error.localizedDescription)")
                if let token = self.activityToken {
                    ProcessInfo.processInfo.endActivity(token)
                    self.activityToken = nil
                }
                NSApp.terminate(self)
            }
        }
    }
    
    private func loadRestoreImage(from url: URL) async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: url) { result in
                switch result {
                case .success(let image):
                    continuation.resume(returning: image)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func setupAndRunVM() async throws {
        // Prevent App Nap and throttling during high-performance VM execution
        self.activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.latencyCritical, .userInitiated],
            reason: "Running high-performance Virtual Machine session"
        )
        
        // 1. Core storage validation & disk creation
        try ensureDiskImageExists(at: diskPath, sizeInGB: autoDiskSizeGB, thickProvision: thickProvision)
        
        let config = VZVirtualMachineConfiguration()
        
        // Clamp vCPU count and memory within Virtualization.framework minimum and maximum limits
        let allowedCPUs = max(
            VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            min(cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        )
        config.cpuCount = allowedCPUs
        
        var targetMemoryMB = memoryMB
        if let hostFreeInactive = getHostFreeAndInactiveMemory() {
            let hostFreeInactiveMB = Int(hostFreeInactive / 1024 / 1024)
            let maxSafeMemoryMB = Int(Double(hostFreeInactiveMB) * 0.75)
            let clampedMemoryMB = max(4096, min(targetMemoryMB, maxSafeMemoryMB))
            if clampedMemoryMB < targetMemoryMB {
                print("⚠️ Host RAM is highly constrained (Free + Inactive: \(hostFreeInactiveMB) MB).")
                print("⚠️ Dynamic memory clamp automatically reduced VM allocation from \(targetMemoryMB) MB to \(clampedMemoryMB) MB to prevent page swap thrashing.")
                targetMemoryMB = clampedMemoryMB
            } else {
                print("ℹ️ Host RAM is healthy (Free + Inactive: \(hostFreeInactiveMB) MB, Safe limit: \(maxSafeMemoryMB) MB). VM allocation: \(targetMemoryMB) MB")
            }
        }
        
        let allowedMemoryBytes = max(
            VZVirtualMachineConfiguration.minimumAllowedMemorySize,
            min(UInt64(targetMemoryMB) * 1024 * 1024, VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        )
        config.memorySize = allowedMemoryBytes
        
        config.bootLoader = VZMacOSBootLoader()
        
        let platform = VZMacPlatformConfiguration()
        let fm = FileManager.default
        let auxURL = URL(fileURLWithPath: auxPath)
        let bakURL = URL(fileURLWithPath: auxPath + ".bak")
        
        if isInstalling {
            print("🛠️ INSTALLATION MODE DETECTED")
            print("────────────────────────────────────────────────────────────────────────")
            let ipswURL = URL(fileURLWithPath: ipswPath)
            
            print("🔍 Loading macOS Restore Image configuration...")
            let restoreImage = try await loadRestoreImage(from: ipswURL)
            
            guard let mostFeaturefulConfig = restoreImage.mostFeaturefulSupportedConfiguration else {
                throw NSError(domain: "VZRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Your Mac hardware does not support virtualizing this macOS restore image."])
            }
            
            let hardwareModel = mostFeaturefulConfig.hardwareModel
            print("📋 Hardware Compatibility details:")
            print("   - macOS Version: \(restoreImage.operatingSystemVersion)")
            print("   - Build Version: \(restoreImage.buildVersion)")
            print("   - Hardware Model Supported: Yes")
            
            // Save hardware model to disk atomically with secure umask permissions (0600)
            try hardwareModel.dataRepresentation.write(to: URL(fileURLWithPath: hwModelPath), options: [.atomic])
            secureFilePermissions(at: hwModelPath)
            try? hardwareModel.dataRepresentation.write(to: URL(fileURLWithPath: hwModelPath + ".bak"), options: [.atomic])
            secureFilePermissions(at: hwModelPath + ".bak")
            print("   - Saved Hardware Model to: \(hwModelPath) (and backup)")
            
            // Generate and save unique machine identifier atomically
            let machineIdentifier = VZMacMachineIdentifier()
            try machineIdentifier.dataRepresentation.write(to: URL(fileURLWithPath: macIdPath), options: [.atomic])
            secureFilePermissions(at: macIdPath)
            try? machineIdentifier.dataRepresentation.write(to: URL(fileURLWithPath: macIdPath + ".bak"), options: [.atomic])
            secureFilePermissions(at: macIdPath + ".bak")
            print("   - Saved Machine Identifier to: \(macIdPath) (and backup)")
            
            // Create raw blank auxiliary NVRAM storage
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: auxURL, hardwareModel: hardwareModel, options: [])
            secureFilePermissions(at: auxPath)
            print("   - Created NVRAM Storage file at: \(auxPath)")
            
            platform.hardwareModel = hardwareModel
            platform.machineIdentifier = machineIdentifier
            platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: auxURL)
        } else {
            print("⚡ RESUMING GUEST SESSION MODE")
            print("────────────────────────────────────────────────────────────────────────")
            
            // Self-healing: Prior to boot, implement shadow restore if current NVRAM is invalid or empty
            if fm.fileExists(atPath: auxPath) {
                if let attrs = try? fm.attributesOfItem(atPath: auxPath),
                   let fileSize = attrs[.size] as? UInt64, fileSize == 0 {
                    print("⚠️ Detected corrupted 0-byte NVRAM storage. Restoring shadow backup...")
                    if fm.fileExists(atPath: bakURL.path) {
                        try? fm.removeItem(at: auxURL)
                        try? fm.copyItem(at: bakURL, to: auxURL)
                        print("✅ Restored NVRAM storage from backup.")
                    } else {
                        print("❌ No shadow backup available to restore.")
                    }
                }
            }
            
            // Self-healing for Hardware Model
            var hardwareModel: VZMacHardwareModel?
            if fm.fileExists(atPath: hwModelPath) {
                if let hwData = try? Data(contentsOf: URL(fileURLWithPath: hwModelPath)) {
                    hardwareModel = VZMacHardwareModel(dataRepresentation: hwData)
                }
            }
            
            if hardwareModel == nil {
                print("⚠️ Hardware model at \(hwModelPath) is missing or corrupted. Restoring from backup...")
                let hwBakURL = URL(fileURLWithPath: hwModelPath + ".bak")
                if fm.fileExists(atPath: hwBakURL.path) {
                    if let hwBakData = try? Data(contentsOf: hwBakURL),
                       let model = VZMacHardwareModel(dataRepresentation: hwBakData) {
                        hardwareModel = model
                        try? fm.removeItem(at: URL(fileURLWithPath: hwModelPath))
                        try? fm.copyItem(at: hwBakURL, to: URL(fileURLWithPath: hwModelPath))
                        secureFilePermissions(at: hwModelPath)
                        print("✅ Restored Hardware Model from backup.")
                    }
                }
            }
            
            // Self-healing for Machine Identifier
            var machineIdentifier: VZMacMachineIdentifier?
            if fm.fileExists(atPath: macIdPath) {
                if let idData = try? Data(contentsOf: URL(fileURLWithPath: macIdPath)) {
                    machineIdentifier = VZMacMachineIdentifier(dataRepresentation: idData)
                }
            }
            
            if machineIdentifier == nil {
                print("⚠️ Machine identifier at \(macIdPath) is missing or corrupted. Restoring from backup...")
                let idBakURL = URL(fileURLWithPath: macIdPath + ".bak")
                if fm.fileExists(atPath: idBakURL.path) {
                    if let idBakData = try? Data(contentsOf: idBakURL),
                       let id = VZMacMachineIdentifier(dataRepresentation: idBakData) {
                        machineIdentifier = id
                        try? fm.removeItem(at: URL(fileURLWithPath: macIdPath))
                        try? fm.copyItem(at: idBakURL, to: URL(fileURLWithPath: macIdPath))
                        secureFilePermissions(at: macIdPath)
                        print("✅ Restored Machine Identifier from backup.")
                    }
                }
            }
            
            guard let validHardwareModel = hardwareModel else {
                print("❌ Error: Missing or corrupted hardware model configuration, and no valid backup was found.")
                exit(1)
            }
            
            guard let validMachineIdentifier = machineIdentifier else {
                print("❌ Error: Missing or corrupted machine identifier configuration, and no valid backup was found.")
                exit(1)
            }
            
            guard fm.fileExists(atPath: auxPath) else {
                print("❌ Error: Missing NVRAM storage auxiliary file at \(auxPath)")
                exit(1)
            }
            
            secureFilePermissions(at: hwModelPath)
            secureFilePermissions(at: macIdPath)
            secureFilePermissions(at: auxPath)
            
            // Copy-on-write APFS clone backup of NVRAM before boot session
            if let attrs = try? fm.attributesOfItem(atPath: auxPath),
               let fileSize = attrs[.size] as? UInt64, fileSize > 0 {
                try? fm.removeItem(at: bakURL)
                try? fm.copyItem(at: auxURL, to: bakURL)
                secureFilePermissions(at: bakURL.path)
            }
            
            platform.hardwareModel = validHardwareModel
            platform.machineIdentifier = validMachineIdentifier
            platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: auxURL)
            print("🔌 Hardware Model, Machine ID & NVRAM session loaded successfully with self-healing.")
        }
        
        config.platform = platform
        
        // 2. Hardware Attachments (SSD, Graphics, Network, Keyboard, Trackpad, Sound)
        let diskURL = URL(fileURLWithPath: diskPath)
        let diskAttachment: VZDiskImageStorageDeviceAttachment
        if #available(macOS 13.0, *) {
            diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false, cachingMode: .cached, synchronizationMode: .fsync)
            print("💾 Configured storage device attachment with host-buffered caching mode (.cached) and sync mode (.fsync).")
        } else {
            diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
            print("💾 Configured storage device attachment with default caching.")
        }
        let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
        config.storageDevices = [blockDevice]
        
        let graphicsConfig = VZMacGraphicsDeviceConfiguration()
        let displayConfig = VZMacGraphicsDisplayConfiguration(widthInPixels: width, heightInPixels: height, pixelsPerInch: ppi)
        graphicsConfig.displays = [displayConfig]
        config.graphicsDevices = [graphicsConfig]
        
        let networkAttachment = VZNATNetworkDeviceAttachment()
        let networkConfig = VZVirtioNetworkDeviceConfiguration()
        networkConfig.attachment = networkAttachment
        
        // Persistent network MAC address
        var macAddress = VZMACAddress.randomLocallyAdministered()
        let macPath = diskPath + ".mac"
        if fm.fileExists(atPath: macPath),
           let macString = try? String(contentsOfFile: macPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let savedMac = VZMACAddress(string: macString) {
            macAddress = savedMac
            print("🛜 Loaded persistent MAC address from \(macPath): \(macAddress.string)")
        } else {
            let macString = macAddress.string
            try? macString.write(toFile: macPath, atomically: true, encoding: .utf8)
            secureFilePermissions(at: macPath)
            print("🛜 Generated and saved new persistent MAC address to \(macPath): \(macString)")
        }
        networkConfig.macAddress = macAddress
        config.networkDevices = [networkConfig]
        
        if #available(macOS 14.0, *) {
            config.keyboards = [VZMacKeyboardConfiguration()]
            print("🎹 Configured high-performance paravirtualized Mac Keyboard.")
        } else {
            config.keyboards = [VZUSBKeyboardConfiguration()]
            print("🎹 Configured standard USB Keyboard.")
        }
        
        if #available(macOS 13.0, *) {
            config.pointingDevices = [VZMacTrackpadConfiguration()]
            print("👉 Configured hardware multi-touch Mac Trackpad.")
        } else {
            config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
            print("👉 Configured standard coordinate pointer device.")
        }
        
        // Memory ballooning device for dynamic RAM recovery
        let balloonConfig = VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
        config.memoryBalloonDevices = [balloonConfig]
        print("🎈 Configured traditional Virtio memory balloon device.")
        
        let soundConfig = VZVirtioSoundDeviceConfiguration()
        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()
        soundConfig.streams = [outputStream]
        config.audioDevices = [soundConfig]
        
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        
        // 3. Directory Sharing Configuration
        if !sharedDirPath.isEmpty {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sharedDirPath, isDirectory: &isDir), isDir.boolValue else {
                print("❌ Error: Shared directory does not exist or is not a directory: \(sharedDirPath)")
                exit(1)
            }
            
            let sharedDirURL = URL(fileURLWithPath: sharedDirPath)
            let sharedDirectory = VZSharedDirectory(url: sharedDirURL, readOnly: false)
            let share = VZSingleDirectoryShare(directory: sharedDirectory)
            let fileSystemDeviceConfig = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            fileSystemDeviceConfig.share = share
            config.directorySharingDevices = [fileSystemDeviceConfig]
            print("📁 Directory Sharing configured: \(sharedDirPath) -> Automount inside Guest")
        }
        
        // Validate configuration
        try config.validate()
        print("✅ VM Configuration validated successfully.")
        
        // Create VM and assign delegate
        let virtualMachine = VZVirtualMachine(configuration: config)
        virtualMachine.delegate = self
        self.vm = virtualMachine
        
        // Configure local console-friendly graceful signal triggers
        setupSignalHandlers()
        
        // Initialize Cocoa GUI Window on Main Thread
        setupWindow()
        
        print("🚀 Booting macOS Virtual Machine...")
        print("   - vCPUs: \(cpus)")
        print("   - Memory: \(memoryMB) MB")
        print("   - Screen Resolution: \(width)x\(height)")
        print("────────────────────────────────────────────────────────────────────────")
        
        if isInstalling {
            try await runInstallation()
        } else {
            try await virtualMachine.start()
            print("🟢 macOS Guest GUI is active and rendering.")
            print("────────────────────────────────────────────────────────────────────────")
        }
    }
    
    private func setupWindow() {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        win.title = "macOS Virtual Machine Console"
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        self.window = win
        
        let vmView = VZVirtualMachineView(frame: win.contentView!.bounds)
        vmView.virtualMachine = self.vm
        vmView.capturesSystemKeys = true
        vmView.autoresizingMask = [.width, .height]
        if #available(macOS 14.0, *) {
            vmView.automaticallyReconfiguresDisplay = true
        }
        win.contentView?.addSubview(vmView)
        
        NSApp.activate()
    }
    
    private func runInstallation() async throws {
        print("💿 Starting macOS Installer Session...")
        guard let vm = self.vm else { return }
        let ipswURL = URL(fileURLWithPath: ipswPath)
        
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipswURL)
        self.installer = installer // RETAINED safely as an instance property on the AppDelegate
        
        // Progress observation (runs on MainActor)
        self.progressObservation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, change in
            guard let fraction = change.newValue else { return }
            let percentage = Int(fraction * 100)
            
            let barWidth = 30
            let filledWidth = Int(fraction * Double(barWidth))
            let emptyWidth = barWidth - filledWidth
            let bar = String(repeating: "█", count: filledWidth) + String(repeating: "░", count: emptyWidth)
            
            print("\r💿 Installing macOS: [\(bar)] \(percentage)% Completed", terminator: "")
            fflush(stdout)
        }
        
        // Asynchronous Installation Waiter
        try await installer.install()
        
        print("\n────────────────────────────────────────────────────────────────────────")
        print("🎉 macOS Installation completed successfully!")
        print("👉 Please remove the '--ipsw' argument from your command line to boot your new system.")
        print("────────────────────────────────────────────────────────────────────────")
        if let token = self.activityToken {
            ProcessInfo.processInfo.endActivity(token)
            self.activityToken = nil
        }
        NSApp.terminate(self)
    }
    
    private func ensureDiskImageExists(at path: String, sizeInGB: Int, thickProvision: Bool) throws {
        let fm = FileManager.default
        let expectedSize = Int64(sizeInGB) * 1024 * 1024 * 1024
        
        if fm.fileExists(atPath: path) {
            let attrs = try fm.attributesOfItem(atPath: path)
            if let actualSize = attrs[.size] as? UInt64 {
                if actualSize == UInt64(expectedSize) {
                    secureFilePermissions(at: path)
                    return // Image exists with matching size
                } else {
                    print("❌ Fatal Error: Disk image exists at \(path) but has a different size than specified (\(Double(actualSize) / 1024.0 / 1024.0 / 1024.0) GB vs expected \(sizeInGB) GB).")
                    print("   To protect your data, the runner will not proceed. Please specify the matching --disk-size or manually move/rename the existing disk image.")
                    exit(1)
                }
            }
        }
        
        // Verify parent volume capacity before generating allocations
        let url = URL(fileURLWithPath: path)
        let parentDir = url.deletingLastPathComponent()
        let parentDirValues = try parentDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let availableBytes = parentDirValues.volumeAvailableCapacityForImportantUsage {
            if availableBytes < expectedSize {
                print(String(format: "❌ Error: Insufficient host disk space. Required: %d GB, Available: %.2f GB", sizeInGB, Double(availableBytes) / 1024.0 / 1024.0 / 1024.0))
                exit(1)
            }
        }
        
        print("💾 Creating \(thickProvision ? "pre-allocated (thick)" : "sparse") virtual SSD image (\(sizeInGB) GB) at: \(path)...")
        let tmpPath = path + ".tmp"
        let tmpURL = URL(fileURLWithPath: tmpPath)
        
        if fm.fileExists(atPath: tmpPath) {
            try? fm.removeItem(atPath: tmpPath)
        }
        
        // Force secure file creation via POSIX umask & attributes
        let success = fm.createFile(atPath: tmpPath, contents: nil, attributes: [.posixPermissions: 0o600])
        guard success else {
            throw NSError(domain: "DiskCreationError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create physical file descriptor at \(tmpPath)"])
        }
        
        let fileHandle = try FileHandle(forWritingTo: tmpURL)
        
        if thickProvision {
            print("   - Reserving physical blocks on APFS to guarantee run-time write availability...")
            var allocVal = fstore_t(fst_flags: UInt32(F_ALLOCATEALL),
                                    fst_posmode: Int32(F_VOLPOSMODE),
                                    fst_offset: 0,
                                    fst_length: off_t(expectedSize),
                                    fst_bytesalloc: 0)
            let fd = fileHandle.fileDescriptor
            let ret = fcntl(fd, F_PREALLOCATE, &allocVal)
            if ret == -1 {
                print("   ⚠️ F_PREALLOCATE failed: \(String(cString: strerror(errno))). Reverting to dynamic sparse expansion.")
            }
        }
        
        try fileHandle.truncate(atOffset: UInt64(expectedSize))
        try fileHandle.synchronize() // Commit structures atomically to disk
        try fileHandle.close()
        
        // Swap file atomically into place
        if fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }
        try fm.moveItem(atPath: tmpPath, toPath: path)
        secureFilePermissions(at: path)
        print("✅ Disk image generated and synchronized securely.")
    }
    
    private func secureFilePermissions(at path: String) {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
    
    private func setupSignalHandlers() {
        signalSources = [SIGINT, SIGTERM].map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                print("\n🛑 Signal \(sig) received. Initiating graceful VM shutdown...")
                self?.gracefulTriggerShutdown()
            }
            signal(sig, SIG_IGN)
            source.resume()
            return source
        }
    }
    
    private func gracefulTriggerShutdown() {
        guard let vm = self.vm, vm.state == .running else {
            NSApp.terminate(self)
            return
        }
        
        if isStopping { return }
        isStopping = true
        
        print("\n🛑 Signal received. Initiating graceful VM shutdown...")
        initiateGracefulShutdown()
    }
    
    private func initiateGracefulShutdown() {
        guard let vm = self.vm else {
            NSApp.terminate(self)
            return
        }
        
        Task {
            do {
                try vm.requestStop()
                print("   - Shutdown request sent to Guest OS. Waiting up to 15s for clean halt...")
                
                // Watchdog: Wait up to 15 seconds for the guest to stop itself
                for _ in 0..<150 { // 150 * 100ms = 15 seconds
                    if vm.state != .running {
                        break
                    }
                    try await Task.sleep(nanoseconds: 100_000_000) // Sleep 100ms
                }
                
                // If still running, force terminate the hypervisor
                if vm.state == .running {
                    print("⚠️ macOS guest failed to halt within 15s. Escalating to forced stop...")
                    try await vm.stop()
                }
                
                if let token = self.activityToken {
                    ProcessInfo.processInfo.endActivity(token)
                    self.activityToken = nil
                }
                NSApp.terminate(self)
            } catch {
                print("⚠️ ACPI shutdown request failed: \(error.localizedDescription). Forcing stop...")
                try? await vm.stop()
                if let token = self.activityToken {
                    ProcessInfo.processInfo.endActivity(token)
                    self.activityToken = nil
                }
                NSApp.terminate(self)
            }
        }
    }
    
    // MARK: - NSWindowDelegate
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let vm = self.vm, vm.state == .running else {
            return true
        }
        
        if isStopping {
            return false // Shutdown sequence is already in progress
        }
        
        isStopping = true
        print("\n🛑 Console window closing. Requesting graceful shutdown...")
        
        sender.standardWindowButton(.closeButton)?.isEnabled = false
        
        initiateGracefulShutdown()
        return false
    }
    
    private func getHostFreeAndInactiveMemory() -> UInt64? {
        let hostPort = mach_host_self()
        var pageSize: vm_size_t = 0
        let hostPageSizeResult = host_page_size(hostPort, &pageSize)
        guard hostPageSizeResult == KERN_SUCCESS else {
            return nil
        }
        
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var vmStats = vm_statistics64()
        
        let result = withUnsafeMutablePointer(to: &vmStats) { vmStatsPtr in
            vmStatsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &count)
            }
        }
        
        guard result == KERN_SUCCESS else {
            return nil
        }
        
        let freeBytes = UInt64(vmStats.free_count) * UInt64(pageSize)
        let inactiveBytes = UInt64(vmStats.inactive_count) * UInt64(pageSize)
        
        return freeBytes + inactiveBytes
    }
    
    // MARK: - VZVirtualMachineDelegate
    
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("\n⚠️ Guest operating system stopped.")
        if let token = self.activityToken {
            ProcessInfo.processInfo.endActivity(token)
            self.activityToken = nil
        }
        NSApp.terminate(nil)
    }
    
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        print("\n❌ Virtual machine encountered a fatal runtime error: \(error.localizedDescription)")
        if let token = self.activityToken {
            ProcessInfo.processInfo.endActivity(token)
            self.activityToken = nil
        }
        NSApp.terminate(nil)
    }
}
