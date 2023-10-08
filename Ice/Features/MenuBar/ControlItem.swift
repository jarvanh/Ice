//
//  ControlItem.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

/// A status item that controls the visibility of a section in
/// the menu bar.
final class ControlItem: ObservableObject {
    /// A value representing the hiding state of a control item.
    enum HidingState: Int, Hashable, Codable {
        /// Status items in the control item's section are hidden.
        case hideItems
        /// Status items in the control item's section are visible.
        case showItems
    }

    /// Possible lengths of a control item.
    enum Lengths {
        /// The length of a control item when its section is visible.
        static let standard: CGFloat = 25
        /// The length of a control item when its section is hidden.
        static let expanded: CGFloat = 10_000
    }

    /// Valid modifiers that can be used to trigger the control
    /// item's secondary action.
    ///
    /// The user chooses which of these they would like to use
    /// in the app's settings.
    static let clickModifiers: [Hotkey.Modifiers] = [.control, .option, .shift]

    /// Storage to temporarily associate menu bar sections with
    /// specific menu items.
    private static let sectionStorage = ObjectAssociation<MenuBarSection>()

    /// The modifier that the user has selected from the various
    /// options in ``clickModifiers`` to trigger the control item's
    /// secondary action.
    ///
    /// Defaults to ``Hotkey/Modifiers-swift.struct/option`` if
    /// the user has not made a selection.
    private static var userSelectedClickModifier: Hotkey.Modifiers {
        guard let rawValue = UserDefaults.standard.object(forKey: Defaults.alwaysHiddenModifier) as? Int else {
            return .option
        }
        return Hotkey.Modifiers(rawValue: rawValue)
    }

    /// Observers for key aspects of the control item's state.
    private var cancellables = Set<AnyCancellable>()

    /// The control item's underlying status item.
    private let statusItem: NSStatusItem

    /// The position of the control item in the menu bar.
    @Published private(set) var position: CGFloat?

    /// A Boolean value that indicates whether the control item
    /// is visible.
    ///
    /// This value corresponds to whether the item's section is
    /// enabled.
    @Published var isVisible: Bool

    /// The hiding state of the control item.
    ///
    /// Setting this value marks the item as needing an update.
    @Published var state: HidingState

    /// The menu bar associated with the control item.
    weak var menuBar: MenuBar? {
        didSet {
            updateStatusItem(with: state)
        }
    }

    /// The control item's autosave name.
    var autosaveName: String {
        statusItem.autosaveName
    }

    /// The identifier of the control item's window.
    var windowID: CGWindowID? {
        guard let windowNumber = statusItem.button?.window?.windowNumber else {
            return nil
        }
        return CGWindowID(windowNumber)
    }

    /// The frame of the control item's window.
    var windowFrame: CGRect? {
        statusItem.button?.window?.frame
    }

    /// The menu bar section associated with the control item.
    var section: MenuBarSection? {
        menuBar?.sections.first { $0.controlItem == self }
    }

    /// A Boolean value indicating whether the control item 
    /// expands when hiding its section.
    var expandsOnHide: Bool {
        guard
            let section,
            let index = menuBar?.sections.firstIndex(of: section)
        else {
            return false
        }
        // all items except for the first one expand on hide
        return index != 0
    }

    /// A Boolean value that indicates whether the control item
    /// is expanded.
    ///
    /// Expanded control items have a length that is equal to the
    /// ``Lengths/expanded`` constant, while non-expanded control
    /// items have a length that is equal to the ``Lengths/standard``
    /// constant.
    var isExpanded: Bool {
        get {
            statusItem.length == Lengths.expanded
        }
        set {
            objectWillChange.send()
            if newValue {
                statusItem.length = Lengths.expanded
            } else {
                statusItem.length = Lengths.standard
            }
        }
    }

    /// Creates a control item with the given autosave name, position,
    /// and hiding state.
    ///
    /// - Parameters:
    ///   - autosaveName: The control item's autosave name.
    ///   - position: The position of the control item in the menu bar.
    ///   - state: The hiding state of the control item.
    init(
        autosaveName: String,
        position: CGFloat?,
        state: HidingState? = nil
    ) {
        // if the isVisible property has been previously set, it will have
        // been stored in user defaults; if a status item is created in an
        // invisible state, its preferred position is deleted; to prevent
        // this, cache the current visibility, if any, and delete it from
        // defaults; then, initialize the status item and set its visibility
        // to the cached value
        let cachedIsVisible = StatusItemDefaults[.isVisible, autosaveName]
        StatusItemDefaults[.isVisible, autosaveName] = nil

        if let position {
            // set the preferred position first to ensure that
            // the status item appears in the correct position
            StatusItemDefaults[.preferredPosition, autosaveName] = position
        }

        self.statusItem = NSStatusBar.system.statusItem(withLength: Lengths.standard)
        self.statusItem.autosaveName = autosaveName
        self.position = position
        self.isVisible = statusItem.isVisible
        self.state = state ?? .showItems

        // NOTE: this needs to happen after the status item is
        // created, but before the call to configureStatusItem()
        if let cachedIsVisible {
            self.isVisible = cachedIsVisible
        }

        configureStatusItem()
    }

    deinit {
        // removing the status item has the unwanted side effect 
        // of deleting the preferred position; cache and restore
        // after removing
        let autosaveName = autosaveName
        let cached = StatusItemDefaults[.preferredPosition, autosaveName]
        defer {
            StatusItemDefaults[.preferredPosition, autosaveName] = cached
        }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Sets the initial configuration for the status item.
    private func configureStatusItem() {
        defer {
            configureCancellables()
            updateStatusItem(with: state)
        }
        guard let button = statusItem.button else {
            return
        }
        button.target = self
        button.action = #selector(performAction)
        button.sendAction(on: [.leftMouseDown, .rightMouseUp])
    }

    /// Sets up a series of cancellables to respond to changes in
    /// the control item's state.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        $state
            .sink { [weak self] state in
                self?.updateStatusItem(with: state)
            }
            .store(in: &c)

        $isVisible
            .removeDuplicates()
            .sink { [weak self] isVisible in
                guard let self else {
                    return
                }
                var deferredBlock: (() -> Void)?
                if !isVisible {
                    // setting the status item to invisible has the unwanted
                    // side effect of deleting the preferred position; cache
                    // and restore afterwards
                    let autosaveName = autosaveName
                    let cached = StatusItemDefaults[.preferredPosition, autosaveName]
                    deferredBlock = {
                        StatusItemDefaults[.preferredPosition, autosaveName] = cached
                    }
                }
                statusItem.isVisible = isVisible
                menuBar?.needsSave = true
                deferredBlock?()
            }
            .store(in: &c)

        statusItem.publisher(for: \.isVisible)
            .removeDuplicates()
            .sink { [weak self] isVisible in
                self?.isVisible = isVisible
            }
            .store(in: &c)

        if let window = statusItem.button?.window {
            window.publisher(for: \.frame)
                .combineLatest(window.publisher(for: \.screen))
                .compactMap { [weak self] frame, screen in
                    // only publish when the item is not expanded and the
                    // window is at least partially onscreen
                    guard
                        self?.isExpanded == false,
                        let screenFrame = screen?.frame,
                        screenFrame.intersects(frame)
                    else {
                        return nil
                    }
                    // calculate position relative to trailing edge of screen
                    return screenFrame.maxX - frame.maxX
                }
                .removeDuplicates()
                .sink { [weak self] position in
                    self?.position = position
                }
                .store(in: &c)
        }

        cancellables = c
    }

    /// Updates the control item's status item to match the given
    /// state.
    func updateStatusItem(with state: HidingState) {
        guard
            let name = section?.name,
            let button = statusItem.button
        else {
            return
        }

        defer {
            menuBar?.needsSave = true
        }

        switch state {
        case .hideItems where expandsOnHide:
            isExpanded = true
            // prevent the cell from highlighting while expanded
            button.cell?.isEnabled = false
            // cell still sometimes briefly flashes on expansion
            // unless manually unhighlighted
            button.isHighlighted = false
            button.image = nil
        case .hideItems, .showItems:
            isExpanded = false
            // enable cell, as it may have been previously disabled
            button.cell?.isEnabled = true
            // set the image based on section name and state
            button.image = switch name {
            case .visible:
                switch state {
                case .hideItems:
                    ControlItemImages.Circle.filled
                case .showItems:
                    ControlItemImages.Circle.stroked
                }
            case .hidden:
                ControlItemImages.Chevron.large
            case .alwaysHidden:
                ControlItemImages.Chevron.small
            }
        }
    }

    @objc private func performAction() {
        guard
            let menuBar,
            let event = NSApp.currentEvent
        else {
            return
        }
        switch event.type {
        case .leftMouseDown:
            if
                let alwaysHiddenSection = menuBar.section(withName: .alwaysHidden),
                alwaysHiddenSection.isEnabled,
                NSEvent.modifierFlags == Self.userSelectedClickModifier.nsEventFlags
            {
                alwaysHiddenSection.show()
            } else {
                section?.toggle()
            }
        case .rightMouseUp:
            statusItem.showMenu(createMenu(with: menuBar))
        default:
            break
        }
    }

    /// Creates and returns a menu to show when the control item is
    /// right-clicked.
    private func createMenu(with menuBar: MenuBar) -> NSMenu {
        let menu = NSMenu(title: Constants.appName)

        // add menu items to toggle the hidden and always-hidden 
        // sections, if each section is enabled
        let sectionNames: [MenuBarSection.Name] = [.hidden, .alwaysHidden]
        for name in sectionNames {
            guard
                let section = menuBar.section(withName: name),
                section.isEnabled
            else {
                continue
            }
            let item = NSMenuItem(
                title: "\(section.isHidden ? "Show" : "Hide") \"\(name.rawValue)\" Section",
                action: #selector(toggleMenuBarSection),
                keyEquivalent: ""
            )
            item.target = self
            Self.sectionStorage[item] = section
            if let hotkey = section.hotkey {
                item.keyEquivalent = hotkey.key.keyEquivalent
                item.keyEquivalentModifierMask = hotkey.modifiers.nsEventFlags
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit \(Constants.appName)",
            action: #selector(NSApp.terminate),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)

        return menu
    }

    /// Action for a menu item in the control item's menu to perform.
    @objc private func toggleMenuBarSection(for menuItem: NSMenuItem) {
        Self.sectionStorage[menuItem]?.toggle()
    }
}

// MARK: ControlItem: Codable
extension ControlItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case autosaveName
        case state
    }

    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            autosaveName: container.decode(String.self, forKey: .autosaveName),
            position: nil,
            state: container.decode(HidingState.self, forKey: .state)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(autosaveName, forKey: .autosaveName)
        try container.encode(state, forKey: .state)
    }
}

// MARK: ControlItem: Equatable
extension ControlItem: Equatable {
    static func == (lhs: ControlItem, rhs: ControlItem) -> Bool {
        lhs.statusItem == rhs.statusItem &&
        lhs.autosaveName == rhs.autosaveName &&
        lhs.position == rhs.position &&
        lhs.state == rhs.state
    }
}

// MARK: ControlItem: Hashable
extension ControlItem: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(statusItem)
        hasher.combine(autosaveName)
        hasher.combine(position)
        hasher.combine(state)
    }
}

// MARK: - StatusItemDefaultsKey

private struct StatusItemDefaultsKey<Value> {
    let rawValue: String
}

extension StatusItemDefaultsKey<CGFloat> {
    static let preferredPosition = StatusItemDefaultsKey(rawValue: "Preferred Position")
}

extension StatusItemDefaultsKey<Bool> {
    static let isVisible = StatusItemDefaultsKey(rawValue: "Visible")
}

// MARK: - StatusItemDefaults

/// Proxy getters and setters for a status item's user default values.
private enum StatusItemDefaults {
    private static func stringKey<Value>(
        forKey key: StatusItemDefaultsKey<Value>,
        autosaveName: String
    ) -> String {
        return "NSStatusItem \(key.rawValue) \(autosaveName)"
    }

    /// Accesses the preferred position associated with the specified 
    /// key and autosave name.
    static subscript<Value>(
        key: StatusItemDefaultsKey<Value>, 
        autosaveName: String
    ) -> Value? {
        get {
            // use object(forKey:) because double(forKey:) returns 0 if no value
            // is stored; we need to differentiate between "a stored value of 0"
            // and "no stored value"
            let key = stringKey(forKey: key, autosaveName: autosaveName)
            return UserDefaults.standard.object(forKey: key) as? Value
        }
        set {
            let key = stringKey(forKey: key, autosaveName: autosaveName)
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }
}

// MARK: - ControlItemImages

/// Namespaces for control item images.
enum ControlItemImages {
    /// Namespace for circle-shaped control item images.
    enum Circle {
        static let filled: NSImage = {
            let image = NSImage(size: CGSize(width: 8, height: 8), flipped: false) { bounds in
                NSColor.black.setFill()
                NSBezierPath(ovalIn: bounds).fill()
                return true
            }
            image.isTemplate = true
            return image
        }()

        static let stroked: NSImage = {
            let image = NSImage(size: CGSize(width: 8, height: 8), flipped: false) { bounds in
                let lineWidth: CGFloat = 1.5
                let insetBounds = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
                let path = NSBezierPath(ovalIn: insetBounds)
                path.lineWidth = lineWidth
                NSColor.black.setStroke()
                path.stroke()
                return true
            }
            image.isTemplate = true
            return image
        }()
    }

    /// Namespace for chevron-shaped control item images.
    enum Chevron {
        private static func chevron(size: CGSize, lineWidth: CGFloat) -> NSImage {
            let image = NSImage(size: size, flipped: false) { bounds in
                let insetBounds = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
                let path = NSBezierPath()
                path.move(to: CGPoint(x: (insetBounds.midX + insetBounds.maxX) / 2, y: insetBounds.maxY))
                path.line(to: CGPoint(x: (insetBounds.minX + insetBounds.midX) / 2, y: insetBounds.midY))
                path.line(to: CGPoint(x: (insetBounds.midX + insetBounds.maxX) / 2, y: insetBounds.minY))
                path.lineWidth = lineWidth
                path.lineCapStyle = .butt
                NSColor.black.setStroke()
                path.stroke()
                return true
            }
            image.isTemplate = true
            return image
        }

        static let large = chevron(size: CGSize(width: 12, height: 12), lineWidth: 2)

        static let small = chevron(size: CGSize(width: 9, height: 9), lineWidth: 2)
    }
}

// MARK: - Logger
extension Logger {
    static let controlItem = mainSubsystem(category: "ControlItem")
}