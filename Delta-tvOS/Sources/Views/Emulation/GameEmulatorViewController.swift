import UIKit
import SwiftUI
import DeltaCore
import GameController
import MelonDSDeltaCore
import DolphinDeltaCore
import PlayDeltaCore
import MGBADeltaCore

class GameEmulatorViewController: GCEventViewController, GameControllerReceiver {
    let game: TVGame

    private let resumeStateURL: URL?
    private let gameContainer = UIView()
    private var containerWidth: NSLayoutConstraint!
    private var containerHeight: NSLayoutConstraint!
    private var gameAspectConstraint: NSLayoutConstraint?
    private var defaultAspectRatio: CGFloat?
    private var imageSize: TVImageSize {
        let value = UserDefaults.standard.object(forKey: "TVImageSize_\(game.system.rawValue)") as? Int
        return TVImageSize(savedValue: value)
    }
    private var resumeAfterActivation = false
    private var pendingResumeError: String?
    private var pendingLaunchError: String?
    private var stateFiles: TVGameStateFiles { TVGameStateFiles(romURL: game.fileURL, coreNamespace: game.system.stateNamespace) }
    private var displayResolution: TVDisplayResolution {
        TVDisplayResolution(savedValue: UserDefaults.standard.integer(forKey: "TVDisplayResolution_\(game.system.rawValue)"))
    }
    private(set) var emulatorCore: EmulatorCore?
    private var gameView: GameView!
    private var isPaused = false
    private var touchTimer: Timer?
    private var touchPointer = DSTouchPointer()
    private let touchCursor = UIView()
    private var attachedControllers: [DeltaCore.GameController] = []
    private var requiredControllerCount = 0
    private weak var controllerDisconnectAlert: UIAlertController?
    private weak var controllerContinueAction: UIAlertAction?

    private var availableGamepads: [DeltaCore.GameController] {
        GameControllerRegistry.shared.connectedControllers.filter { controller in
            if let native = controller as? MFiGameController { return native.controller.extendedGamepad != nil }
            return controller is Switch2GameController
        }
    }

    var onDismiss: (() -> Void)?

    init(game: TVGame, resumeStateURL: URL? = nil) {
        self.game = game
        self.resumeStateURL = resumeStateURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.controllerUserInteractionEnabled = false
        self.view.backgroundColor = .black

        // 1. Setup GameView
        self.gameView = GameView(frame: self.view.bounds)
        self.gameView.backgroundColor = .black
        self.gameView.translatesAutoresizingMaskIntoConstraints = false
        gameContainer.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(gameContainer)
        gameContainer.addSubview(gameView)
        gameView.inputImageSizeDidChange = { [weak self] _ in self?.view.setNeedsLayout() }
        containerWidth = gameContainer.widthAnchor.constraint(equalToConstant: view.bounds.width)
        containerHeight = gameContainer.heightAnchor.constraint(equalToConstant: view.bounds.height)
        NSLayoutConstraint.activate([
            gameContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            gameContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            containerWidth,
            containerHeight
        ])

        if game.system == .ds {
            // melonDS supplies both screens stacked in a 256 × 384 frame.
            NSLayoutConstraint.activate([
                gameView.centerXAnchor.constraint(equalTo: gameContainer.centerXAnchor),
                gameView.centerYAnchor.constraint(equalTo: gameContainer.centerYAnchor),
                gameView.heightAnchor.constraint(equalTo: gameContainer.safeAreaLayoutGuide.heightAnchor),
                gameView.widthAnchor.constraint(equalTo: gameView.heightAnchor, multiplier: 256.0 / 384.0)
            ])
            touchCursor.backgroundColor = .clear
            touchCursor.layer.borderWidth = 2
            touchCursor.layer.borderColor = UIColor.white.cgColor
            touchCursor.layer.cornerRadius = 9
            touchCursor.layer.shadowColor = UIColor.black.cgColor
            touchCursor.layer.shadowOpacity = 1
            touchCursor.layer.shadowRadius = 2
            touchCursor.isUserInteractionEnabled = false
            gameView.addSubview(touchCursor)
            let help = UILabel()
            help.text = "Right Stick: Move Pointer\nTouch: RT / R2 (default)\nClose Lid: LT / L2 (default)"
            help.numberOfLines = 0
            help.textColor = .secondaryLabel
            help.font = .systemFont(ofSize: 18)
            help.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(help)
            NSLayoutConstraint.activate([
                help.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
                help.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
                help.trailingAnchor.constraint(lessThanOrEqualTo: gameView.leadingAnchor, constant: -12)
            ])
        } else if [.gbc, .gba, .genesis].contains(game.system) {
            let ratio: CGFloat = game.system == .gbc ? 160.0 / 144.0 : (game.system == .gba ? 1.5 : 4.0 / 3.0)
            defaultAspectRatio = ratio
            gameAspectConstraint = gameView.widthAnchor.constraint(equalTo: gameView.heightAnchor, multiplier: ratio)
            let preferredHeight = gameView.heightAnchor.constraint(equalTo: gameContainer.safeAreaLayoutGuide.heightAnchor)
            preferredHeight.priority = .defaultHigh
            NSLayoutConstraint.activate([
                gameView.centerXAnchor.constraint(equalTo: gameContainer.centerXAnchor),
                gameView.centerYAnchor.constraint(equalTo: gameContainer.centerYAnchor),
                gameView.heightAnchor.constraint(lessThanOrEqualTo: gameContainer.safeAreaLayoutGuide.heightAnchor),
                gameView.widthAnchor.constraint(lessThanOrEqualTo: gameContainer.safeAreaLayoutGuide.widthAnchor),
                gameAspectConstraint!,
                preferredHeight
            ])
        } else {
            NSLayoutConstraint.activate([
                self.gameView.leadingAnchor.constraint(equalTo: self.gameContainer.leadingAnchor),
                self.gameView.trailingAnchor.constraint(equalTo: self.gameContainer.trailingAnchor),
                self.gameView.topAnchor.constraint(equalTo: self.gameContainer.topAnchor),
                self.gameView.bottomAnchor.constraint(equalTo: self.gameContainer.bottomAnchor)
            ])
        }

        // 2. Initialize EmulatorCore
        ROMWebServer.shared.isEmulating = true
        ROMWebServer.shared.stop()
        
        guard let emulator = EmulatorCore(game: self.game.deltaGame) else {
            ROMWebServer.shared.isEmulating = false
            ROMWebServer.shared.start()
            let alert = UIAlertController(title: "Emulation Error", message: "Failed to initialize emulator core for \(game.name).", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Back", style: .default, handler: { [weak self] _ in
                self?.onDismiss?()
            }))
            self.present(alert, animated: true)
            return
        }

        self.emulatorCore = emulator
        emulator.add(self.gameView)

        configureJITRequest(for: emulator)

        // 3. Connect Game Controllers
        self.connectControllers()

        NotificationCenter.default.addObserver(self, selector: #selector(controllersChanged(_:)), name: .deltaControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllersChanged(_:)), name: .deltaControllerDidDisconnect, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)

        // 4. Start Emulation
        emulator.start()
        if let bridge = emulator.deltaCore.emulatorBridge as? MGBAEmulatorBridge, let error = bridge.lastError {
            pendingLaunchError = error
            emulator.pause()
            return
        }
        if let bridge = emulator.deltaCore.emulatorBridge as? PlayEmulatorBridge, bridge.gameURL == nil {
            pendingLaunchError = bridge.lastError ?? "Play! could not start this game."
            emulator.pause()
            return
        }
        if let resumeStateURL {
            emulator.pause()
            do {
                try emulator.load(SaveState(fileURL: resumeStateURL, gameType: game.system.gameType))
                try checkPlayError()
            } catch {
                pendingResumeError = error.localizedDescription
            }
            emulator.resume()
        }
        if game.system == .ds {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.updateDSTouch()
            }
            touchTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if self.isBeingDismissed {
            self.saveAutomaticState()
            self.touchTimer?.invalidate()
            self.disconnectControllers()
            self.emulatorCore?.stop()
            ROMWebServer.shared.isEmulating = false
            ROMWebServer.shared.start()
        }
    }

    deinit {
        touchTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        self.emulatorCore?.stop()
        ROMWebServer.shared.isEmulating = false
        ROMWebServer.shared.start()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let gameView else { return }
        let screenScale = view.window?.screen.nativeScale ?? traitCollection.displayScale
        let sourceSize = gameView.outputImage?.extent.size ?? game.system.core.videoFormat.dimensions
        let containerSize = imageSize.containerSize(screenSize: view.bounds.size, screenScale: screenScale, sourceSize: sourceSize)
        if containerWidth.constant != containerSize.width || containerHeight.constant != containerSize.height {
            containerWidth.constant = containerSize.width
            containerHeight.constant = containerSize.height
            view.setNeedsLayout()
        }
        if let defaultAspectRatio {
            let ratio = imageSize == .nativePixels && sourceSize.height > 0 ? sourceSize.width / sourceSize.height : defaultAspectRatio
            if gameAspectConstraint?.multiplier != ratio {
                gameAspectConstraint?.isActive = false
                gameAspectConstraint = gameView.widthAnchor.constraint(equalTo: gameView.heightAnchor, multiplier: ratio)
                gameAspectConstraint?.isActive = true
            }
        }
        let size = displayResolution.drawableSize(viewSize: gameView.bounds.size, screenScale: screenScale, coreSize: sourceSize)
        if gameView.preferredDrawableSize != size {
            gameView.preferredDrawableSize = size
        }
    }

    private func showImageSizeMenu() {
        let alert = UIAlertController(title: "Image Size", message: "Native Pixels displays the game without enlargement. It may be small on a 4K screen.", preferredStyle: .actionSheet)
        for size in TVImageSize.allCases {
            alert.addAction(UIAlertAction(title: size.title, style: .default) { [weak self] _ in
                guard let self else { return }
                UserDefaults.standard.set(size.rawValue, forKey: "TVImageSize_\(game.system.rawValue)")
                view.setNeedsLayout()
                view.layoutIfNeeded()
                resumeGameplay()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.resumeGameplay() })
        present(alert, animated: true)
    }

    private func showDisplayResolutionMenu() {
        let current = gameView.preferredDrawableSize ?? .zero
        let message = "Current surface: \(Int(current.width)) × \(Int(current.height)) pixels. Lower settings may improve performance without changing picture size."
        let alert = UIAlertController(title: "Display Resolution", message: message, preferredStyle: .actionSheet)
        for resolution in TVDisplayResolution.allCases {
            let coreSize = gameView.outputImage?.extent.size ?? game.system.core.videoFormat.dimensions
            let title = resolution == .core ? "Core Limit (\(Int(coreSize.width)) × \(Int(coreSize.height)))" : resolution.title
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self else { return }
                UserDefaults.standard.set(resolution.rawValue, forKey: "TVDisplayResolution_\(game.system.rawValue)")
                view.setNeedsLayout()
                view.layoutIfNeeded()
                resumeGameplay()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.resumeGameplay() })
        present(alert, animated: true)
    }

    private func resumeGameplay() {
        if requiredControllerCount > 0 || availableGamepads.isEmpty {
            requiredControllerCount = max(1, requiredControllerCount)
            pauseForMissingController()
            return
        }
        controllerUserInteractionEnabled = false
        emulatorCore?.resume()
        isPaused = false
    }

    private func saveAutomaticState() {
        guard let emulator = emulatorCore, emulator.state != .stopped else { return }
        releaseDSTouch()
        emulator.pause()
        isPaused = true
        do {
            try stateFiles.saveAutomatic { url in
                _ = emulator.saveSaveState(to: url)
                try checkPlayError()
            }
        } catch {
            print("[DeltaTV] Could not save resume point: \(error)")
        }
    }

    @objc private func applicationWillResignActive() {
        guard let emulator = emulatorCore, emulator.state != .stopped else { return }
        resumeAfterActivation = emulator.state == .running && presentedViewController == nil
        saveAutomaticState()
    }

    @objc private func applicationDidBecomeActive() {
        if requiredControllerCount > 0 { pauseForMissingController(); return }
        guard resumeAfterActivation else { return }
        resumeAfterActivation = false
        if presentedViewController == nil { resumeGameplay() }
    }

    private func checkPlayError() throws {
        if let bridge = emulatorCore?.deltaCore.emulatorBridge as? PlayEmulatorBridge, let message = bridge.lastError {
            throw NSError(domain: "PlayDeltaCore", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func configureJITRequest(for emulator: EmulatorCore) {
        // Mupen64Plus manages its own CPU backend. Do not override a working
        // N64 configuration with the DS/Dolphin preference.
        if let bridge = emulator.deltaCore.emulatorBridge as? PlayEmulatorBridge {
            bridge.isJITEnabled = ProcessInfo.isJITUserEnabled
        } else if let bridge = emulator.deltaCore.emulatorBridge as? MelonDSEmulatorBridge {
            bridge.isJITEnabled = bridge.supportsJIT && ProcessInfo.processInfo.shouldRequestJIT
        } else if let bridge = emulator.deltaCore.emulatorBridge as? DolphinEmulatorBridge {
            bridge.isJITEnabled = bridge.supportsJIT && ProcessInfo.processInfo.shouldRequestJIT
        }
    }

    private var currentJITStatus: TVJITStatus? {
        let supported: Bool
        let active: Bool
        if let bridge = emulatorCore?.deltaCore.emulatorBridge as? PlayEmulatorBridge {
            return TVJITStatus(backendSupported: true, debugFlag: PlayEmulatorBridge.canExecuteJIT(), requested: ProcessInfo.isJITUserEnabled, active: bridge.isJITActive)
        } else if let bridge = emulatorCore?.deltaCore.emulatorBridge as? MelonDSEmulatorBridge {
            supported = bridge.supportsJIT
            active = bridge.isJITActive
        } else if let bridge = emulatorCore?.deltaCore.emulatorBridge as? DolphinEmulatorBridge {
            supported = bridge.supportsJIT
            active = bridge.isJITActive
        } else {
            return nil
        }
        return TVJITStatus(backendSupported: supported, debugFlag: ProcessInfo.processInfo.hasJITDebugFlag,
                           requested: ProcessInfo.isJITUserEnabled, active: active)
    }

    private func showJITPreferenceConfirmation() {
        let mode = ProcessInfo.isJITUserEnabled ? "enabled" : "disabled"
        let alert = UIAlertController(title: "JIT Preference Updated",
                                      message: "JIT will be \(mode) on the next game start, if supported and permitted. The current session has not changed.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Continue Game", style: .default) { [weak self] _ in self?.resumeGameplay() })
        present(alert, animated: true)
    }

    private func connectControllers() {
        guard let emulator = self.emulatorCore else { return }
        let previous = self.attachedControllers
        self.disconnectControllers()
        let mapping = TVControllerMappingManager.shared.createDeltaInputMapping(for: self.game.system)
        // The Siri Remote also appears in GCController.controllers(). It must not
        // take player one, otherwise DK64 receives the gamepad on player two.
        let available = availableGamepads
        let retained = previous.filter { old in available.contains { $0 === old } }
        let added = available.filter { current in !previous.contains { $0 === current } }
        let gamepads = Array((retained + added).prefix(game.system == .ps2 ? 2 : 4))
        var usedIndices = Set(gamepads.compactMap { current in previous.first(where: { $0 === current })?.playerIndex })
        for controller in gamepads {
            let index: Int
            if let existing = previous.first(where: { $0 === controller }) {
                index = existing.playerIndex ?? 0
            } else {
                index = (0..<4).first(where: { !usedIndices.contains($0) }) ?? 0
                usedIndices.insert(index)
            }
            for input in controller.activatedInputs.keys {
                controller.deactivate(input)
            }
            controller.playerIndex = index
            controller.addReceiver(emulator, inputMapping: mapping)
            if controller is Switch2GameController { controller.addReceiver(self, inputMapping: nil) }
            self.attachedControllers.append(controller)
        }
    }

    private func disconnectControllers() {
        guard let emulator = self.emulatorCore else { return }
        self.releaseDSTouch()
        for controller in self.attachedControllers {
            for input in controller.activatedInputs.keys {
                controller.deactivate(input)
            }
            controller.removeReceiver(emulator)
            controller.removeReceiver(self)
        }
        self.attachedControllers.removeAll()
    }

    private func releaseDSTouch() {
        guard game.system == .ds, let emulator = emulatorCore, let controller = attachedControllers.first else { return }
        emulator.gameController(controller, didDeactivate: MelonDSGameInput.touchScreenX)
        emulator.gameController(controller, didDeactivate: MelonDSGameInput.touchScreenY)
    }

    private func updateDSTouch() {
        guard !isPaused, presentedViewController == nil,
              let emulator = emulatorCore, let controller = attachedControllers.first else {
            releaseDSTouch()
            touchCursor.isHidden = true
            return
        }
        touchPointer.move(horizontal: TVGamepadButton.rightThumbstickRight.value(in: controller) - TVGamepadButton.rightThumbstickLeft.value(in: controller), vertical: TVGamepadButton.rightThumbstickUp.value(in: controller) - TVGamepadButton.rightThumbstickDown.value(in: controller))
        touchCursor.isHidden = false
        touchCursor.frame = touchPointer.cursorFrame(in: gameView.bounds.size)
        let touchButton = TVControllerMappingManager.shared.mappings[.ds]?["touch"] ?? .rightTrigger
        if touchButton.value(in: controller) > 0.5 {
            emulator.gameController(controller, didActivate: MelonDSGameInput.touchScreenX, value: touchPointer.inputValues.x)
            emulator.gameController(controller, didActivate: MelonDSGameInput.touchScreenY, value: touchPointer.inputValues.y)
        } else {
            releaseDSTouch()
        }
    }

    @objc private func controllersChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !isBeingDismissed, let emulator = emulatorCore, emulator.state != .stopped else { return }
            let previousCount = attachedControllers.count
            let lostController = attachedControllers.contains { old in !self.availableGamepads.contains { $0 === old } }
            connectControllers()
            let count = attachedControllers.count
            if lostController || count < previousCount || (notification.name == .deltaControllerDidDisconnect && count == 0) {
                requiredControllerCount = max(requiredControllerCount, max(1, previousCount))
                pauseForMissingController()
            } else if requiredControllerCount > 0 {
                updateControllerDisconnectAlert()
            }
        }
    }

    private func updateControllerDisconnectAlert() {
        let ready = attachedControllers.count >= requiredControllerCount
        controllerContinueAction?.isEnabled = ready
        controllerDisconnectAlert?.title = ready ? "Controller Connected" : "Controller Disconnected"
        controllerDisconnectAlert?.message = ready
            ? "Select Continue Game when you are ready."
            : "Connect a game controller to continue playing. The game is paused."
    }

    private func pauseForMissingController() {
        releaseDSTouch()
        emulatorCore?.pause()
        isPaused = true
        controllerUserInteractionEnabled = true
        resumeAfterActivation = false
        if controllerDisconnectAlert != nil { updateControllerDisconnectAlert(); return }
        let show = { [weak self] in
            guard let self, !isBeingDismissed, view.window != nil, controllerDisconnectAlert == nil else { return }
            let alert = UIAlertController(title: "Controller Disconnected", message: nil, preferredStyle: .alert)
            alert.isModalInPresentation = true
            let continueAction = UIAlertAction(title: "Continue Game", style: .default) { [weak self] _ in
                guard let self else { return }
                controllerDisconnectAlert = nil
                controllerContinueAction = nil
                guard availableGamepads.count >= requiredControllerCount else {
                    DispatchQueue.main.async { self.pauseForMissingController() }
                    return
                }
                requiredControllerCount = 0
                resumeGameplay()
            }
            alert.addAction(continueAction)
            alert.addAction(UIAlertAction(title: "Return to Library", style: .default) { [weak self] _ in
                guard let self else { return }
                presentingViewController?.dismiss(animated: true) { self.onDismiss?() }
            })
            controllerDisconnectAlert = alert
            controllerContinueAction = continueAction
            updateControllerDisconnectAlert()
            present(alert, animated: true)
        }
        if let presented = presentedViewController {
            presented.dismiss(animated: true, completion: show)
        } else if view.window != nil {
            show()
        }
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.controllerUserInteractionEnabled = false
        self.becomeFirstResponder()
        if let message = pendingLaunchError {
            pendingLaunchError = nil
            let alert = UIAlertController(title: "Could Not Start PS2 Game", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Return to Library", style: .default) { [weak self] _ in
                self?.dismiss(animated: true) { self?.onDismiss?() }
            })
            present(alert, animated: true)
            return
        }
        if requiredControllerCount > 0 {
            pauseForMissingController()
            return
        }
        if let message = pendingResumeError {
            pendingResumeError = nil
            let alert = UIAlertController(title: "Could Not Resume", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    func gameController(_ gameController: DeltaCore.GameController, didActivate input: Input, value: Double) {
        guard input.stringValue == MFiGameController.Input.menu.stringValue, value > 0.5 else { return }
        showPauseMenu()
    }

    func gameController(_ gameController: DeltaCore.GameController, didDeactivate input: Input) {}

    // MARK: - Controller Press Interception
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // GCEventViewController keeps gamepad buttons out of UIKit during play.
        // Only the Siri Remote's Back/Menu opens the pause menu; its other
        // buttons never become emulator input.
        if controllerDisconnectAlert != nil { return }
        if presses.contains(where: { $0.type == .menu }) {
            self.showPauseMenu()
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}
    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}

    private func showPauseMenu() {
        guard self.presentedViewController == nil, let emulator = self.emulatorCore else { return }
        self.releaseDSTouch()
        emulator.pause()
        self.controllerUserInteractionEnabled = true
        self.isPaused = true
        self.saveAutomaticState()

        let alert = UIAlertController(title: "Paused: \(self.game.name)", message: nil, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "Resume Game", style: .cancel, handler: { [weak self] _ in
            self?.resumeGameplay()
        }))

        alert.addAction(UIAlertAction(title: "Controller Mapping", style: .default, handler: { [weak self] _ in
            guard let self = self else { return }
            let remapper = ControllerRemapViewController(initialSystem: self.game.system) { [weak self] in
                self?.connectControllers()
                self?.resumeGameplay()
            }
            self.present(remapper, animated: true)
        }))

        alert.addAction(UIAlertAction(title: "Save State", style: .default, handler: { [weak self] _ in
            guard let self = self, let emulator = self.emulatorCore else { return }
            let saveStateURL = self.stateFiles.manualURL
            _ = emulator.saveSaveState(to: saveStateURL)
            self.resumeGameplay()
        }))

        alert.addAction(UIAlertAction(title: "Load State", style: .default, handler: { [weak self] _ in
            guard let self = self, let emulator = self.emulatorCore else { return }
            let saveStateURL = self.stateFiles.manualURL
            if FileManager.default.fileExists(atPath: saveStateURL.path) {
                let saveState = SaveState(fileURL: saveStateURL, gameType: self.game.system.gameType)
                do {
                    try emulator.load(saveState)
                    try self.checkPlayError()
                } catch {
                    print("Failed to load state: \(error)")
                }
            }
            self.resumeGameplay()
        }))

        alert.addAction(UIAlertAction(title: "Image Size: \(imageSize.title)", style: .default) { [weak self] _ in
            self?.showImageSizeMenu()
        })

        alert.addAction(UIAlertAction(title: "Display Resolution: \(displayResolution.title)", style: .default) { [weak self] _ in
            self?.showDisplayResolutionMenu()
        })

        if let status = currentJITStatus {
            let action = UIAlertAction(title: status.title, style: .default) { [weak self] _ in
                ProcessInfo.isJITUserEnabled.toggle()
                self?.showJITPreferenceConfirmation()
            }
            action.isEnabled = status != .unsupported && game.system != .ps2
            alert.addAction(action)
        }

        alert.addAction(UIAlertAction(title: "Restart Game", style: .destructive, handler: { [weak self] _ in
            guard let self = self, let emulator = self.emulatorCore else { return }
            guard self.availableGamepads.count >= max(1, self.requiredControllerCount) else {
                self.requiredControllerCount = max(1, self.requiredControllerCount)
                self.pauseForMissingController()
                return
            }
            self.controllerUserInteractionEnabled = false
            emulator.stop()
            self.configureJITRequest(for: emulator)
            emulator.start()
            self.isPaused = false
        }))

        alert.addAction(UIAlertAction(title: "Return to Library", style: .destructive, handler: { [weak self] _ in
            self?.dismiss(animated: true) {
                self?.onDismiss?()
            }
        }))

        self.present(alert, animated: true)
    }

}
