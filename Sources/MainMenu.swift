import AppKit

/// Application main menu, installed only in Dock mode. The status-bar menu keeps its
/// own copy of these actions; both route to the same controllers.
@MainActor
enum MainMenu {
    private static let appName = "ntfyx"

    static func install() {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenu())
        mainMenu.addItem(fileMenu())
        mainMenu.addItem(editMenu())
        mainMenu.addItem(windowMenu())
        mainMenu.addItem(helpMenu())
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menus

    private static func appMenu() -> NSMenuItem {
        let menu = NSMenu(title: appName)
        menu.addItem(item("关于 \(appName)", #selector(StatusBarController.showAbout), "", target: StatusBarController.shared))
        menu.addItem(.separator())
        menu.addItem(item("设置…", #selector(StatusBarController.openSettings), ",", target: StatusBarController.shared))
        menu.addItem(.separator())

        let services = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "服务")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())

        menu.addItem(item("隐藏 \(appName)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]))
        menu.addItem(item("显示全部", #selector(NSApplication.unhideAllApplications(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("退出 \(appName)", #selector(NSApplication.terminate(_:)), "q"))

        return container(title: appName, submenu: menu)
    }

    private static func fileMenu() -> NSMenuItem {
        let menu = NSMenu(title: "文件")
        menu.addItem(item("通知历史…", #selector(StatusBarController.openHistory), "h", modifiers: [.command, .shift], target: StatusBarController.shared))
        menu.addItem(.separator())
        menu.addItem(item("重载配置", #selector(StatusBarController.reloadConfig), "r", target: StatusBarController.shared))
        menu.addItem(item("在 Finder 中显示配置", #selector(StatusBarController.showConfigInFinder), "", target: StatusBarController.shared))
        menu.addItem(item("查看日志…", #selector(StatusBarController.viewLogs), "l", modifiers: [.command, .shift], target: StatusBarController.shared))
        menu.addItem(.separator())
        menu.addItem(item("关闭", #selector(NSWindow.performClose(_:)), "w"))
        return container(title: "文件", submenu: menu)
    }

    /// Present so the field editor gets Cut/Copy/Paste and the history search field
    /// keeps working; every action travels the responder chain.
    private static func editMenu() -> NSMenuItem {
        let menu = NSMenu(title: "编辑")
        menu.addItem(item("撤销", Selector(("undo:")), "z"))
        menu.addItem(item("重做", Selector(("redo:")), "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("剪切", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("拷贝", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("粘贴", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("全选", #selector(NSText.selectAll(_:)), "a"))
        return container(title: "编辑", submenu: menu)
    }

    private static func windowMenu() -> NSMenuItem {
        let menu = NSMenu(title: "窗口")
        menu.addItem(item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("缩放", #selector(NSWindow.performZoom(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("前置全部窗口", #selector(NSApplication.arrangeInFront(_:)), ""))
        NSApp.windowsMenu = menu
        return container(title: "窗口", submenu: menu)
    }

    private static func helpMenu() -> NSMenuItem {
        let menu = NSMenu(title: "帮助")
        menu.addItem(item("ntfyx 项目主页", #selector(MainMenuActions.openProjectHomepage), "", target: MainMenuActions.shared))
        return container(title: "帮助", submenu: menu)
    }

    // MARK: - Helpers

    private static func container(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private static func item(_ title: String,
                            _ action: Selector?,
                            _ keyEquivalent: String,
                            modifiers: NSEvent.ModifierFlags = .command,
                            target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }
}

@MainActor
final class MainMenuActions: NSObject {
    static let shared = MainMenuActions()

    @objc func openProjectHomepage() {
        guard let url = URL(string: "https://github.com/Felix2yu/ntfyx") else { return }
        NSWorkspace.shared.open(url)
    }
}
