@testable import AdaMessaging
import Foundation
import Testing
import UIKit
import WebKit

@Suite(.serialized)
@MainActor
struct ViewVisibilitySceneTests {
    @Test func `scene lifecycle of the view's own scene reports visibility changes`() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.isHidden = false
        let center = NotificationCenter()
        let scene = NSObject()
        let view = AdaRecoverableWebView(
            frame: window.bounds,
            lifecycleNotificationCenter: center,
            windowScene: { scene },
        )
        window.addSubview(view)
        var reports: [Bool] = []
        view.onVisibilityChanged = { reports.append($0) }
        for name in [
            UIScene.didEnterBackgroundNotification,
            UIScene.willEnterForegroundNotification,
            UIScene.didEnterBackgroundNotification,
            UIScene.didActivateNotification,
            UIScene.didEnterBackgroundNotification,
        ] {
            center.post(name: name, object: scene)
            await drainVisibilityReports()
        }
        #expect(reports == [false, true, false, true, false])
        let nextWindow = UIWindow(frame: window.frame)
        nextWindow.isHidden = false
        nextWindow.addSubview(view)
        await drainVisibilityReports()
        #expect(view.isVisibleInWindow)
        #expect(reports == [false, true, false, true, false, true])
    }

    @Test func `scene lifecycle of another scene does not report`() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.isHidden = false
        let center = NotificationCenter()
        let scene = NSObject()
        let view = AdaRecoverableWebView(
            frame: window.bounds,
            lifecycleNotificationCenter: center,
            windowScene: { scene },
        )
        window.addSubview(view)
        var reports: [Bool] = []
        view.onVisibilityChanged = { reports.append($0) }
        center.post(name: UIScene.didEnterBackgroundNotification, object: NSObject())
        center.post(name: UIScene.didEnterBackgroundNotification, object: nil)
        await drainVisibilityReports()
        #expect(reports.isEmpty)
        #expect(view.isVisibleInWindow)
        center.post(name: UIScene.didEnterBackgroundNotification, object: scene)
        await drainVisibilityReports()
        #expect(reports == [false])
    }

    @Test func `translated view waits until it intersects the window`() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.isHidden = false
        let view = AdaRecoverableWebView(frame: window.bounds)
        view.transform = CGAffineTransform(translationX: 0, y: 640)
        var reports: [Bool] = []
        view.onVisibilityChanged = { reports.append($0) }
        window.addSubview(view)
        await drainVisibilityReports()
        #expect(!view.isVisibleInWindow)
        #expect(reports == [false])
        view.transform = .identity
        await drainVisibilityReports()
        #expect(view.isVisibleInWindow)
        #expect(reports == [false, true])
    }

    @Test func `clipped view waits until it intersects the container`() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.isHidden = false
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        container.clipsToBounds = true
        let view = AdaRecoverableWebView(frame: CGRect(x: 0, y: 200, width: 160, height: 160))
        var reports: [Bool] = []
        view.onVisibilityChanged = { reports.append($0) }
        container.addSubview(view)
        window.addSubview(container)
        await drainVisibilityReports()
        #expect(!view.isVisibleInWindow)
        #expect(reports == [false])
        container.clipsToBounds = false
        await drainVisibilityReports()
        #expect(reports == [false, true])
        container.clipsToBounds = true
        await drainVisibilityReports()
        #expect(reports == [false, true, false])
        view.frame.origin.y = 0
        await drainVisibilityReports()
        #expect(view.isVisibleInWindow)
        #expect(reports == [false, true, false, true])
    }

    private func drainVisibilityReports() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
