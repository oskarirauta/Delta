import PlayDeltaCore
import SwiftUI
import GameController
import DeltaCore

struct GameLibraryView: View {
    @EnvironmentObject var gameManager: TVGameManager
    @EnvironmentObject var webServer: ROMWebServer
    
    @AppStorage("TVGBACore") private var gbaCore = "mgba"
    @State private var selectedSystem: TVSystem? = nil
    @State private var selectedGame: TVGame? = nil
    @State private var connectedControllerCount = 0
    @State private var controllerBadgeFlash = false
    @State private var showUploadInfo = false
    @State private var showSwitch2Controllers = false
    
    let columns = [
        GridItem(.adaptive(minimum: 260, maximum: 280), spacing: 32)
    ]
    
    var filteredGames: [TVGame] {
        if let system = selectedSystem {
            return gameManager.gamesBySystem[system] ?? []
        }
        return gameManager.allGames
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top Header Bar
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Delta")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(colors: [Color(red: 0.65, green: 0.35, blue: 0.95), Color(red: 0.35, green: 0.55, blue: 0.95)], startPoint: .leading, endPoint: .trailing)
                            )
                        Text(selectedSystem?.fullName ?? "All Systems (\(gameManager.allGames.count) games)")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Menu {
                        Picker("GBA Core", selection: $gbaCore) {
                            Text("VBA-M").tag("vba-m")
                            Text("mGBA").tag("mgba")
                        }
                        Text("Separate saves per core. mGBA first copies the VBA-M battery save.")
                    } label: {
                        Text("GBA: \(gbaCore == "mgba" ? "mGBA" : "VBA-M")")
                    }
                    .onChange(of: gbaCore) { _ in Delta.register(TVSystem.gba.core) }
                    Button("Switch 2 Controllers") { showSwitch2Controllers = true }
                        .buttonStyle(.bordered)
                    // Controller Remapping Tool Button in Header
                    if connectedControllerCount > 0 {
                        HeaderRemapButton {
                            self.presentControllerRemapper()
                        }
                    }
                    
                    // Controller Status Indicator with Flash Transition
                    HStack(spacing: 10) {
                        Image(systemName: connectedControllerCount > 0 ? "gamecontroller.fill" : "gamecontroller")
                            .foregroundColor(controllerBadgeFlash ? .black : (connectedControllerCount > 0 ? .green : .yellow))
                        Text(connectedControllerCount > 0 ? (connectedControllerCount == 1 ? "1 Controller Connected" : "\(connectedControllerCount) Controllers Connected") : "Connect a Controller")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(controllerBadgeFlash ? .black : (connectedControllerCount > 0 ? .green : .yellow))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        controllerBadgeFlash ? Color.white : (connectedControllerCount > 0 ? Color.green.opacity(0.18) : Color.white.opacity(0.08))
                    )
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(controllerBadgeFlash ? Color.white : (connectedControllerCount > 0 ? Color.green.opacity(0.6) : Color.clear), lineWidth: 2)
                    )
                    .scaleEffect(controllerBadgeFlash ? 1.12 : 1.0)
                    .shadow(color: controllerBadgeFlash ? Color.white.opacity(0.8) : Color.clear, radius: 12)
                    
                    // Wi-Fi Upload Server Address
                    HStack(spacing: 8) {
                        Image(systemName: "wifi")
                            .foregroundColor(.cyan)
                        Text(webServer.serverAddress)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundColor(.cyan)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }
                .padding(.horizontal, 48)
                .padding(.top, 24)
                .padding(.bottom, 20)
                .focusSection()
                
                // System Filter Tabs
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        LibrarySystemTabButton(
                            title: "All Games",
                            iconName: "square.grid.2x2.fill",
                            isSelected: selectedSystem == nil,
                            action: { selectedSystem = nil }
                        )
                        
                        ForEach(TVSystem.enabledSystems) { system in
                            LibrarySystemTabButton(
                                title: system.shortName,
                                iconName: system.systemIconName,
                                isSelected: selectedSystem == system,
                                action: { selectedSystem = system }
                            )
                        }
                        

                    }
                    .padding(.horizontal, 48)
                    .padding(.vertical, 10)
                }
                .focusSection()
                
                // Active Upload Banner
                if let upload = webServer.activeUpload {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 16) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 26))
                                .foregroundColor(.cyan)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Transferring: \(upload.filename)")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                
                                Text("\(ByteCountFormatter.string(fromByteCount: Int64(upload.receivedBytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(upload.totalBytes), countStyle: .file)) • \(Int(upload.progress * 100))%")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            
                            Spacer()
                        }
                        
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.15))
                                    .frame(height: 6)
                                
                                Capsule()
                                    .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(0, geo.size.width * CGFloat(upload.progress)), height: 6)
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.cyan.opacity(0.5), lineWidth: 1)
                    )
                    .padding(.horizontal, 48)
                    .padding(.vertical, 6)
                }
                
                // Main Games Grid
                if filteredGames.isEmpty {
                    VStack(spacing: 20) {
                        Spacer()
                        Image(systemName: "tray")
                            .font(.system(size: 64))
                            .foregroundColor(.secondary)
                        
                        Text("Your Library Is Empty")
                            .font(.system(size: 28, weight: .bold))
                        
                        Text("Upload ROMs from your computer or phone:\nOpen this address in your browser: \(webServer.serverAddress)")
                            .font(.system(size: 18))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(6)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 36) {
                            ForEach(filteredGames) { game in
                                GameCardView(game: game) {
                                    self.launchGame(game)
                                }
                            }
                        }
                        .padding(.horizontal, 48)
                        .padding(.vertical, 24)
                    }
                    .focusSection()
                }
            }
        }
        .sheet(isPresented: $showSwitch2Controllers) {
            NavigationStack { Switch2ControllersView() }
        }
        .onAppear {
            self.checkControllers()
        }
        .onReceive(NotificationCenter.default.publisher(for: .deltaControllerDidConnect)) { _ in
            self.checkControllers()
        }
        .onReceive(NotificationCenter.default.publisher(for: .deltaControllerDidDisconnect)) { _ in
            self.checkControllers()
        }
    }
    
    private func checkControllers() {
        let count = GameControllerRegistry.shared.connectedControllers.filter {
            ($0 as? MFiGameController)?.controller.extendedGamepad != nil || $0 is Switch2GameController
        }.count
        if count > 0 && self.connectedControllerCount == 0 {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) {
                self.controllerBadgeFlash = true
                self.connectedControllerCount = count
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.easeInOut(duration: 0.35)) {
                    self.controllerBadgeFlash = false
                }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                self.connectedControllerCount = count
            }
        }
    }
    
    private func presentControllerRemapper() {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController,
              root.presentedViewController == nil else { return }
        root.present(ControllerRemapViewController(initialSystem: selectedSystem ?? .n64), animated: true)
    }

    private func launchGame(_ game: TVGame) {
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return
        }
        
        guard rootVC.presentedViewController == nil else { return }
        
        if let upload = webServer.activeUpload {
            let alert = UIAlertController(
                title: "File Transfer in Progress",
                message: "Transferring \"\(upload.filename)\" (\(Int(upload.progress * 100))%). Launching a game will interrupt the transfer. Are you sure you want to proceed?",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Wait for Transfer", style: .cancel))
            alert.addAction(UIAlertAction(title: "Launch Anyway", style: .destructive) { _ in
                self.proceedLaunchGame(game, rootVC: rootVC)
            })
            rootVC.present(alert, animated: true)
            return
        }
        
        self.proceedLaunchGame(game, rootVC: rootVC)
    }

    private func proceedLaunchGame(_ game: TVGame, rootVC: UIViewController) {
        guard game.system.isPlayable else {
            let alert = UIAlertController(title: "System Not Available",
                                          message: game.system == .ps2 ? "PS2 support is disabled in this build." : "The Dolphin frontend adapter is incomplete in this build. Your imported files have been preserved.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            rootVC.present(alert, animated: true)
            return
        }

        if game.system == .ps2 {
            guard ProcessInfo.isJITUserEnabled, PlayEmulatorBridge.canExecuteJIT() else {
                let alert = UIAlertController(title: "PS2 Requires JIT",
                                              message: ProcessInfo.isJITUserEnabled ? (PlayEmulatorBridge.jitUnavailableReason ?? "Play! requires executable memory permission for this app.") : "Enable the JIT preference first. Play! has no interpreter fallback.", preferredStyle: .alert)
                if !ProcessInfo.isJITUserEnabled {
                    alert.addAction(UIAlertAction(title: "Enable JIT Preference", style: .default) { _ in ProcessInfo.isJITUserEnabled = true })
                }
                alert.addAction(UIAlertAction(title: "OK", style: .cancel))
                rootVC.present(alert, animated: true)
                return
            }
        }

        let presentGame: (URL?) -> Void = { resumeURL in
            let emuVC = GameEmulatorViewController(game: game, resumeStateURL: resumeURL)
            emuVC.modalPresentationStyle = .fullScreen
            emuVC.modalTransitionStyle = .crossDissolve
            rootVC.present(emuVC, animated: true)
        }
        if let resumeURL = TVGameStateFiles(romURL: game.fileURL, coreNamespace: game.system.stateNamespace).resumeURL {
            let alert = UIAlertController(title: "Resume Game?",
                                          message: "Continue \(game.name) from your last saved position?", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Resume Game", style: .default) { _ in presentGame(resumeURL) })
            alert.addAction(UIAlertAction(title: "Start from Beginning", style: .default) { _ in presentGame(nil) })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            rootVC.present(alert, animated: true)
        } else {
            presentGame(nil)
        }
    }
}

/// Header Remap Button with proper tvOS focus style
struct HeaderRemapButton: View {
    let action: () -> Void
    @FocusState private var isFocused: Bool
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                Text("Controller Mapping")
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(isFocused ? .black : .white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                isFocused ? Color.white : Color.white.opacity(0.12)
            )
            .clipShape(Capsule())
            .scaleEffect(isFocused ? 1.035 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusEffectDisabled()
    }
}

/// System filter button with high-contrast handling for focused and selected states
struct LibrarySystemTabButton: View {
    let title: String
    let iconName: String?
    let isSelected: Bool
    let action: () -> Void
    
    @FocusState private var isFocused: Bool
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let iconName = iconName {
                    Image(systemName: iconName)
                }
                Text(title)
            }
            .font(.system(size: 18, weight: .bold))
            .foregroundColor(isFocused ? .black : .white)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(
                Group {
                    if isFocused {
                        Color.white
                    } else if isSelected {
                        Color(red: 0.55, green: 0.35, blue: 0.95)
                    } else {
                        Color.white.opacity(0.12)
                    }
                }
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isSelected && !isFocused ? Color.white.opacity(0.6) : Color.clear, lineWidth: 2)
            )
            .scaleEffect(isFocused ? 1.035 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusEffectDisabled()
    }
}
