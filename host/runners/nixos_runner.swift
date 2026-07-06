import Cocoa
import Virtualization
import Darwin

// Native Apple Virtualization.framework Runner in Pure Swift (CLI & Native macOS GUI)
// Compilation: swiftc -O -parse-as-library nixos_runner.swift -o nixos_runner
// Usage (Headless): ./nixos_runner --kernel vmlinux --initrd initrd.img --disk disk.img
// Usage (GUI):      ./nixos_runner --kernel vmlinux --initrd initrd.img --disk disk.img --gui

@main
@MainActor
class NixOSRunner: NSObject, NSApplicationDelegate, NSWindowDelegate, @preconcurrency VZVirtualMachineDelegate {
    
    static func main() {
        _ = umask(0o077)
        
        print("🍏 Native macOS Virtualization.framework NixOS/Linux Runner")
        print("──────────────────────────────────────────────────────────")
        
        let arguments = CommandLine.arguments
        var useGUI = false
        for arg in arguments {
            if arg == "--gui" {
                useGUI = true
                break
            }
        }
        
        if useGUI {
            let app = NSApplication.shared
            let delegate = NixOSRunner()
            delegate.parseCommandLine()
            app.delegate = delegate
            app.setActivationPolicy(.regular) // Enables Dock icon and standard menu behavior
            app.run()
        } else {
            let delegate = NixOSRunner()
            delegate.parseCommandLine()
            Task {
                do {
                    try await delegate.setupAndRunVMHeadless()
                } catch {
                    print("❌ Fatal headless error: \(error.localizedDescription)")
                    exit(1)
                }
            }
            RunLoop.main.run()
        }
    }
    
    // Command line arguments
    private var kernelPath = ""
    private var initrdPath = ""
    private var diskPaths: [String] = []
    private var cpus = 0
    private var memoryMB = 0
    private var cmdline = "console=hvc0 root=/dev/ram0 rw"
    private var useGUI = false
    private var width = 1024
    private var height = 768
    private var sharedDirPath = ""
    private var sharedTag = "shared"
    private var enableAudio = false
    private var macIdPath = ""
    
    private var vm: VZVirtualMachine?
    private var window: NSWindow?
    private var isStopping = false
    private var activityToken: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []
    
    func parseCommandLine() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
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
            case "--kernel": kernelPath = value(for: "--kernel")
            case "--initrd": initrdPath = value(for: "--initrd")
            case "--disk": diskPaths.append(value(for: "--disk"))
            case "--cpus": cpus = Int(value(for: "--cpus")) ?? 0
            case "--memory": memoryMB = Int(value(for: "--memory")) ?? 0
            case "--cmdline": cmdline = value(for: "--cmdline")
            case "--gui":
                useGUI = true
                i += 1
            case "--width": width = Int(value(for: "--width")) ?? 1024
            case "--height": height = Int(value(for: "--height")) ?? 768
            case "--shared-dir": sharedDirPath = value(for: "--shared-dir")
            case "--shared-tag": sharedTag = value(for: "--shared-tag")
            case "--audio":
                enableAudio = true
                i += 1
            case "--mac-id": macIdPath = value(for: "--mac-id")
            default:
                print("⚠️ Unknown argument: \(arguments[i])")
                exit(1)
            }
        }
        
        guard !kernelPath.isEmpty else {
            print("❌ Error: --kernel is required")
            exit(1)
        }
        
        // Host-Aware Resource Auto-Scaling
        let hostCores = ProcessInfo.processInfo.activeProcessorCount
        let defaultCPUs = max(2, min(4, hostCores / 2))
        
        let hostMemoryBytes = ProcessInfo.processInfo.physicalMemory
        let hostMemoryMB = Int(hostMemoryBytes / 1024 / 1024)
        let defaultMemoryMB = max(2048, min(8192, hostMemoryMB / 4))
        
        if cpus == 0 {
            cpus = defaultCPUs
            print("ℹ️ Auto-scaled vCPUs to \(cpus) (Host logical cores: \(hostCores))")
        }
        if memoryMB == 0 {
            memoryMB = defaultMemoryMB
            print("ℹ️ Auto-scaled memory to \(memoryMB) MB (Host physical memory: \(hostMemoryMB) MB)")
        }
        
        // If mac-id is empty but we have a disk, default to <disk_path>.id for stable platform identifier
        if macIdPath.isEmpty && !diskPaths.isEmpty {
            macIdPath = diskPaths[0] + ".id"
        }
    }
    
    private func printUsageAndExit() -> Never {
        print("""
        Usage: ./nixos_runner --kernel <path> [options]
        
        Options:
          --kernel <path>      Path to guest Linux kernel (vmlinux/Image) [Required]
          --initrd <path>      Path to guest ramdisk (initrd.img)
          --disk <path>        Path to guest filesystem image (rootfs.img) [Can be specified multiple times]
          --cpus <count>       Number of virtual CPUs (default: 2)
          --memory <MB>        Memory allocation in MB (default: 2048)
          --cmdline <string>   Kernel boot arguments (default: console=hvc0 root=/dev/ram0 rw)
          --gui                Boot inside a native macOS hardware-accelerated window
          --width <pixels>     Width of VM display in GUI mode (default: 1024)
          --height <pixels>    Height of VM display in GUI mode (default: 768)
          --shared-dir <path>  Path to host directory to share via VirtioFS
          --shared-tag <tag>   VirtioFS mount tag (default: shared)
          --audio              Enable virtual audio device (stereo output stream)
          --mac-id <path>      Path to save/load stable machine identifier data
        """)
        exit(1)
    }
    
    private func buildConfiguration() throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        
        // Clamp vCPU count and memory within Virtualization.framework minimum and maximum limits
        let allowedCPUs = max(
            VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            min(cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        )
        config.cpuCount = allowedCPUs
        
        let allowedMemoryBytes = max(
            VZVirtualMachineConfiguration.minimumAllowedMemorySize,
            min(UInt64(memoryMB) * 1024 * 1024, VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        )
        config.memorySize = allowedMemoryBytes
        
        let kernelURL = URL(fileURLWithPath: kernelPath)
        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        if !initrdPath.isEmpty {
            bootLoader.initialRamdiskURL = URL(fileURLWithPath: initrdPath)
        }
        bootLoader.commandLine = cmdline
        config.bootLoader = bootLoader
        
        // 1. Interactive Serial Console Attachment (stdin & stdout)
        let serialAttachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: FileHandle.standardInput,
            fileHandleForWriting: FileHandle.standardOutput
        )
        let consoleConfiguration = VZVirtioConsoleDeviceSerialPortConfiguration()
        consoleConfiguration.attachment = serialAttachment
        config.serialPorts = [consoleConfiguration]
        
        // 1.5. SPICE Agent Console Device Configuration (clipboard & dynamic resolution)
        if useGUI {
            let consoleDevice = VZVirtioConsoleDeviceConfiguration()
            let spiceAgentPort = VZVirtioConsolePortConfiguration()
            spiceAgentPort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
            spiceAgentPort.attachment = VZSpiceAgentPortAttachment()
            consoleDevice.ports[0] = spiceAgentPort
            config.consoleDevices = [consoleDevice]
        }
        
        // 2. Disk Storage Attachment
        var storageDevices: [VZStorageDeviceConfiguration] = []
        for path in diskPaths {
            let diskURL = URL(fileURLWithPath: path)
            let isReadOnly = path.lowercased().hasSuffix(".iso")
            let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: isReadOnly)
            let diskConfig = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
            storageDevices.append(diskConfig)
        }
        config.storageDevices = storageDevices
        
        // 3. High Performance NAT Networking
        let networkAttachment = VZNATNetworkDeviceAttachment()
        let networkConfig = VZVirtioNetworkDeviceConfiguration()
        networkConfig.attachment = networkAttachment
        
        let seed = diskPaths.first ?? "nixos-default"
        let mac = generateStableMACAddress(from: seed)
        networkConfig.macAddress = mac
        print("   - Persistent MAC Address: \(mac.string)")
        
        config.networkDevices = [networkConfig]
        
        // 4. Entropy Device (Fast cryptography)
        let entropyConfig = VZVirtioEntropyDeviceConfiguration()
        config.entropyDevices = [entropyConfig]
        
        // 5. GUI Devices (Graphics, Keyboard, Pointer)
        if useGUI {
            let graphicsConfig = VZVirtioGraphicsDeviceConfiguration()
            let scanoutConfig = VZVirtioGraphicsScanoutConfiguration(widthInPixels: width, heightInPixels: height)
            graphicsConfig.scanouts = [scanoutConfig]
            config.graphicsDevices = [graphicsConfig]
            
            config.keyboards = [VZUSBKeyboardConfiguration()]
            config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }
        
        // 6. Directory Sharing Configuration (VirtioFS)
        if !sharedDirPath.isEmpty {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sharedDirPath, isDirectory: &isDir), isDir.boolValue else {
                throw NSError(domain: "NixOSRunner", code: 4, userInfo: [NSLocalizedDescriptionKey: "Shared directory does not exist or is not a directory: \(sharedDirPath)"])
            }
            
            let sharedDirURL = URL(fileURLWithPath: sharedDirPath)
            let sharedDirectory = VZSharedDirectory(url: sharedDirURL, readOnly: false)
            let share = VZSingleDirectoryShare(directory: sharedDirectory)
            
            let fileSystemDeviceConfig = VZVirtioFileSystemDeviceConfiguration(tag: sharedTag)
            fileSystemDeviceConfig.share = share
            config.directorySharingDevices = [fileSystemDeviceConfig]
        }
        
        // 7. Audio Configuration (Stereo output stream)
        if enableAudio {
            let soundConfig = VZVirtioSoundDeviceConfiguration()
            let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
            outputStream.sink = VZHostAudioOutputStreamSink()
            soundConfig.streams = [outputStream]
            config.audioDevices = [soundConfig]
        }
        
        // 8. Platform Configuration (Generic Machine ID support with self-healing)
        let platform = VZGenericPlatformConfiguration()
        if !macIdPath.isEmpty {
            let fm = FileManager.default
            let macIdURL = URL(fileURLWithPath: macIdPath)
            let macIdBakURL = URL(fileURLWithPath: macIdPath + ".bak")
            var machineIdentifier: VZGenericMachineIdentifier?
            
            // Try loading from main path first
            if fm.fileExists(atPath: macIdPath) {
                if let attrs = try? fm.attributesOfItem(atPath: macIdPath),
                   let fileSize = attrs[.size] as? UInt64, fileSize > 0 {
                    if let idData = try? Data(contentsOf: macIdURL) {
                        machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: idData)
                    }
                }
            }
            
            // Self-healing: if loading failed but backup exists, restore backup
            if machineIdentifier == nil && fm.fileExists(atPath: macIdBakURL.path) {
                print("⚠️ Machine identifier at \(macIdPath) is corrupted. Restoring from backup...")
                if let idBakData = try? Data(contentsOf: macIdBakURL),
                   let id = VZGenericMachineIdentifier(dataRepresentation: idBakData) {
                    machineIdentifier = id
                    try? fm.removeItem(at: macIdURL)
                    try? fm.copyItem(at: macIdBakURL, to: macIdURL)
                    print("✅ Restored machine identifier from backup.")
                }
            }
            
            // If still nil, generate a brand-new one
            if machineIdentifier == nil {
                let newIdentifier = VZGenericMachineIdentifier()
                try? newIdentifier.dataRepresentation.write(to: macIdURL, options: [.atomic])
                try? newIdentifier.dataRepresentation.write(to: macIdBakURL, options: [.atomic])
                
                if fm.fileExists(atPath: macIdPath) {
                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: macIdPath)
                }
                if fm.fileExists(atPath: macIdBakURL.path) {
                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: macIdBakURL.path)
                }
                
                machineIdentifier = newIdentifier
                print("📝 Created new machine identifier at: \(macIdPath)")
            }
            
            if let machineIdentifier = machineIdentifier {
                platform.machineIdentifier = machineIdentifier
            }
        }
        config.platform = platform
        
        try config.validate()
        return config
    }
    
    func setupAndRunVMHeadless() async throws {
        self.activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.latencyCritical, .userInitiated],
            reason: "Running high-performance Virtual Machine session"
        )
        
        let config = try buildConfiguration()
        print("✅ VM Configuration validated successfully.")
        
        let virtualMachine = VZVirtualMachine(configuration: config)
        virtualMachine.delegate = self
        self.vm = virtualMachine
        
        setupSignalHandlers()
        
        print("🚀 Booting Headless NixOS Virtual Machine...")
        printVMDetails()
        
        try await virtualMachine.start()
        print("🟢 Headless Virtual Machine active. Output starts here:")
        print("──────────────────────────────────────────────────")
    }
    
    private func printVMDetails() {
        print("   - vCPUs: \(cpus)")
        print("   - Memory: \(memoryMB) MB")
        print("   - Kernel: \(kernelPath)")
        if !initrdPath.isEmpty { print("   - Initrd: \(initrdPath)") }
        if !diskPaths.isEmpty { print("   - Disks: \(diskPaths.joined(separator: ", "))") }
        print("   - Console Mode: \(useGUI ? "Native macOS GUI Window" : "Headless CLI")")
        if useGUI { print("   - GUI Resolution: \(width)x\(height)") }
        if !sharedDirPath.isEmpty { print("   - Shared Directory: \(sharedDirPath) (tag: '\(sharedTag)')") }
        if enableAudio { print("   - Audio Device: Enabled (Stereo Output)") }
        print("──────────────────────────────────────────────────")
    }
    
    // MARK: - NSApplicationDelegate
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                self.activityToken = ProcessInfo.processInfo.beginActivity(
                    options: [.latencyCritical, .userInitiated],
                    reason: "Running high-performance Virtual Machine session"
                )
                
                let config = try buildConfiguration()
                print("✅ VM Configuration validated successfully.")
                
                let virtualMachine = VZVirtualMachine(configuration: config)
                virtualMachine.delegate = self
                self.vm = virtualMachine
                
                setupSignalHandlers()
                setupWindow()
                
                print("🚀 Booting NixOS Virtual Machine...")
                printVMDetails()
                
                try await virtualMachine.start()
                print("🟢 NixOS Guest GUI is active and rendering.")
                print("──────────────────────────────────────────────────")
            } catch {
                print("❌ Fatal setup error: \(error.localizedDescription)")
                terminateApp()
            }
        }
    }
    
    private func setupWindow() {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        win.title = "NixOS Virtual Machine Console"
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
        
        NSApp.activate(ignoringOtherApps: true)
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
            terminateApp()
            return
        }
        
        if isStopping { return }
        isStopping = true
        
        print("\n🛑 Signal received. Initiating graceful VM shutdown...")
        initiateGracefulShutdown()
    }
    
    private func initiateGracefulShutdown() {
        guard let vm = self.vm else {
            terminateApp()
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
                    print("⚠️ NixOS guest failed to halt within 15s. Escalating to forced stop...")
                    try await vm.stop()
                }
                
                terminateApp()
            } catch {
                print("⚠️ ACPI shutdown request failed: \(error.localizedDescription). Forcing stop...")
                try? await vm.stop()
                terminateApp()
            }
        }
    }
    
    private func terminateApp() {
        if let token = self.activityToken {
            ProcessInfo.processInfo.endActivity(token)
            self.activityToken = nil
        }
        if useGUI {
            NSApp.terminate(self)
        } else {
            exit(0)
        }
    }
    
    // Utility to generate a stable, valid locally administered unicast MAC address from a stable string
    private func generateStableMACAddress(from stableSeed: String) -> VZMACAddress {
        let hash = stableSeed.utf8.reduce(5381) { ($0 << 5) &+ $0 + UInt32($1) }
        
        // Locally administered unicast MAC address format:
        // First byte must have its least significant bit as 0 (unicast) and second-least as 1 (locally administered).
        // E.g., x2, x6, xA, xE (where x is any hex digit). Let's use 0x02.
        let b1 = UInt8(0x02)
        let b2 = UInt8((hash >> 24) & 0xFF)
        let b3 = UInt8((hash >> 16) & 0xFF)
        let b4 = UInt8((hash >> 8) & 0xFF)
        let b5 = UInt8(hash & 0xFF)
        let b6 = UInt8((hash ^ 0xAA) & 0xFF)
        
        let macString = String(format: "%02x:%02x:%02x:%02x:%02x:%02x", b1, b2, b3, b4, b5, b6)
        return VZMACAddress(string: macString) ?? VZMACAddress.randomLocallyAdministered()
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
    
    // MARK: - VZVirtualMachineDelegate
    
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("\n⚠️ Guest operating system stopped.")
        terminateApp()
    }
    
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        print("\n❌ Virtual machine encountered a fatal runtime error: \(error.localizedDescription)")
        terminateApp()
    }
}
