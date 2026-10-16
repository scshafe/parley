import Observation
import ParleyKit
import SwiftUI
import UIKit
import UserNotifications

/// What a "reply ready" notification carries, a push or a local one alike:
/// ids only, never reply text.
struct NotificationRoute: Hashable, Sendable {
    var conversationID: String
    var turnID: String?

    init(conversationID: String, turnID: String?) {
        self.conversationID = conversationID
        self.turnID = turnID
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let conversation = userInfo["conversation_id"] as? String, !conversation.isEmpty else { return nil }
        conversationID = conversation
        turnID = (userInfo["turn_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The app delegate, for what SwiftUI has no hook for: the APNs device token,
/// and the notification center's delegate (set at launch, so a tap that
/// launched the app is delivered).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { await AppModel.shared.notifier.launched() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await AppModel.shared.notifier.didRegister(deviceToken: hex) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppModel.shared.notifier.didFailToRegister(error.localizedDescription)
    }

    // The completion-handler forms, finished on the main queue: UIKit asserts
    // when the async forms complete off the main thread (a crash on tap).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let route = NotificationRoute(userInfo: notification.request.content.userInfo)
        DispatchQueue.main.async {
            let options = MainActor.assumeIsolated { AppModel.shared.notifier.presentationOptions(for: route) }
            completionHandler(options)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let route = NotificationRoute(userInfo: response.notification.request.content.userInfo)
        DispatchQueue.main.async {
            if let route { MainActor.assumeIsolated { AppModel.shared.open(route) } }
            completionHandler()
        }
    }
}

/// Notification permission, push registration and the local "reply ready"
/// notification.
///
/// - **Push (opt-in).** Only a build with `PARLEY_PUSH = YES` (a paid team;
///   `ios/project.yml`) registers for remote notifications. It sends the
///   device token to the relay, again whenever the relay or the sign-in changes.
/// - **Local, without push.** A turn the app is following that becomes ready
///   while the app is in the background but still running gets a local
///   notification with the same ids. On leaving the app with a turn
///   unfinished, the app asks iOS for background time (about half a minute)
///   and polls that turn; while a reply plays in the background it keeps
///   running anyway. Once push is registered, the local one is not sent.
@Observable
@MainActor
final class Notifier {
    enum PushState: Equatable {
        case offInThisBuild
        case notRegistered
        case registering
        case registered
        case failed(String)
    }

    static let pushEnabledInBuild =
        (Bundle.main.object(forInfoDictionaryKey: "ParleyPushEnabled") as? String)?.uppercased() == "YES"

    /// The relay's name for the APNs environment this build's tokens belong
    /// to: `sandbox` for a development build, `production` for a release.
    static let relayEnvironment: String = {
        let aps = Bundle.main.object(forInfoDictionaryKey: "ParleyAPSEnvironment") as? String
        return aps == "production" ? "production" : "sandbox"
    }()

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var pushState: PushState = Notifier.pushEnabledInBuild ? .notRegistered : .offInThisBuild
    /// The conversation on screen: its notifications are not shown as banners.
    var visibleConversationID: String?

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var deviceToken: String?
    @ObservationIgnored private var registeredFor: String?
    /// Unfinished turns the app has seen: turn id -> conversation id.
    @ObservationIgnored private var watched: [String: String] = [:]
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var backgroundPoll: Task<Void, Never>?
    @ObservationIgnored private var pollGeneration = 0

    private var isAllowed: Bool {
        authorization == .authorized || authorization == .provisional || authorization == .ephemeral
    }

    // MARK: Permission and push

    func launched() async {
        await refreshAuthorization()
        if Self.pushEnabledInBuild && isAllowed && !AppModel.isUITesting {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await launched()
    }

    func didRegister(deviceToken: String) async {
        self.deviceToken = deviceToken
        await registerWithRelay()
    }

    func didFailToRegister(_ message: String) {
        pushState = .failed(message)
    }

    /// Send the device token to the relay, once per relay and sign-in.
    func registerWithRelay() async {
        guard Self.pushEnabledInBuild, let token = deviceToken, let model, let client = model.client else { return }
        let key = model.connectionKey + "|" + token
        if registeredFor == key { return }
        pushState = .registering
        do {
            try await client.registerDevice(token: token, environment: Self.relayEnvironment)
            registeredFor = key
            pushState = .registered
        } catch {
            pushState = .failed(error.localizedDescription)
        }
    }

    func presentationOptions(for route: NotificationRoute?) -> UNNotificationPresentationOptions {
        if let route, route.conversationID == visibleConversationID { return [] }
        return [.banner, .list, .sound]
    }

    // MARK: Local notifications

    /// Every turn the app sees comes through here.
    func observe(_ turn: ParleyKit.Turn) {
        guard turn.state.isFinished else {
            watched[turn.id] = turn.conversationId
            return
        }
        guard watched.removeValue(forKey: turn.id) != nil, turn.state == .ready,
              UIApplication.shared.applicationState != .active, pushState != .registered, isAllowed else { return }
        let content = UNMutableNotificationContent()
        content.body = "Reply ready"
        content.sound = .default
        content.userInfo = ["conversation_id": turn.conversationId, "turn_id": turn.id]
        let request = UNNotificationRequest(identifier: "turn-\(turn.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    func enteredBackground() {
        guard !watched.isEmpty, backgroundPoll == nil, model?.client != nil else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "parley.turns") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundWork() }
        }
        pollGeneration += 1
        let generation = pollGeneration
        backgroundPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, !self.watched.isEmpty, let client = self.model?.client else { break }
                for (turnID, conversationID) in self.watched {
                    if let turn = try? await client.turn(conversationID: conversationID, turnID: turnID) {
                        self.observe(turn)
                    }
                }
            }
            // Unless a newer poll has replaced this one.
            if self?.pollGeneration == generation { self?.endBackgroundWork() }
        }
    }

    func becameActive() {
        endBackgroundWork()
        Task { await refreshAuthorization() }
    }

    private func endBackgroundWork() {
        backgroundPoll?.cancel()
        backgroundPoll = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
