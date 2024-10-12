//
//  MenuBarAppearanceManager.swift
//  Ice
//

import Cocoa
import Combine

/// A manager for the appearance of the menu bar.
@MainActor
final class MenuBarAppearanceManager: ObservableObject {
    @Published var configuration: MenuBarAppearanceConfigurationV2 = .defaultConfiguration

    private var cancellables = Set<AnyCancellable>()

    private let encoder = JSONEncoder()

    private let decoder = JSONDecoder()

    private let defaults = UserDefaults.standard

    private(set) weak var appState: AppState?

    private(set) var overlayPanels = Set<MenuBarOverlayPanel>()

    let menuBarInsetAmount: CGFloat = 5

    weak var menuBarManager: MenuBarManager? {
        appState?.menuBarManager
    }

    init(appState: AppState) {
        self.appState = appState
    }

    func performSetup() {
        loadInitialState()
        configureCancellables()
    }

    private func loadInitialState() {
        do {
            if let data = Defaults.data(forKey: .menuBarAppearanceConfigurationV2) {
                configuration = try decoder.decode(MenuBarAppearanceConfigurationV2.self, from: data)
            }
        } catch {
            Logger.appearanceManager.error("Error decoding configuration: \(error)")
        }
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: 0.1, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                while let panel = overlayPanels.popFirst() {
                    panel.orderOut(self)
                }
                if Set(overlayPanels.map { $0.owningScreen }) != Set(NSScreen.screens) {
                    configureOverlayPanels(with: configuration)
                }
            }
            .store(in: &c)

        $configuration
            .encode(encoder: encoder)
            .receive(on: DispatchQueue.main)
            .sink { completion in
                if case .failure(let error) = completion {
                    Logger.appearanceManager.error("Error encoding configuration: \(error)")
                }
            } receiveValue: { data in
                Defaults.set(data, forKey: .menuBarAppearanceConfigurationV2)
            }
            .store(in: &c)

        $configuration
            .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] configuration in
                guard let self else {
                    return
                }
                // overlay panels may not have been configured yet; since some of the
                // properties on the manager might call for them, try to configure now
                if overlayPanels.isEmpty {
                    configureOverlayPanels(with: configuration)
                }
            }
            .store(in: &c)

        cancellables = c
    }

    /// Returns a Boolean value that indicates whether a set of overlay panels
    /// is needed for the given configuration.
    private func needsOverlayPanels(for configuration: MenuBarAppearanceConfigurationV2) -> Bool {
        let current = configuration.current
        if current.hasShadow {
            return true
        }
        if current.hasBorder {
            return true
        }
        if configuration.shapeKind != .none {
            return true
        }
        if current.tintKind != .none {
            return true
        }
        return false
    }

    /// Configures the manager's overlay panels, if required by the given configuration.
    private func configureOverlayPanels(with configuration: MenuBarAppearanceConfigurationV2) {
        guard
            let appState,
            needsOverlayPanels(for: configuration)
        else {
            while let panel = overlayPanels.popFirst() {
                panel.close()
            }
            return
        }

        var overlayPanels = Set<MenuBarOverlayPanel>()
        for screen in NSScreen.screens {
            let panel = MenuBarOverlayPanel(appState: appState, owningScreen: screen)
            overlayPanels.insert(panel)
            panel.needsShow = true
        }

        self.overlayPanels = overlayPanels
    }

    /// Sets the value of ``MenuBarOverlayPanel/isDraggingMenuBarItem`` for each
    /// of the manager's overlay panels.
    func setIsDraggingMenuBarItem(_ isDragging: Bool) {
        for panel in overlayPanels {
            panel.isDraggingMenuBarItem = isDragging
        }
    }
}

// MARK: MenuBarAppearanceManager: BindingExposable
extension MenuBarAppearanceManager: BindingExposable { }

// MARK: - Logger
private extension Logger {
    static let appearanceManager = Logger(category: "MenuBarAppearanceManager")
}
