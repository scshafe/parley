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
        /// Registered with the relay; `relayCanPush` is false until the relay has an APNs key.
        case registered(relayCanPush: Bool)
        case failed(String)
    }

    static let pushEnabledInBuild =
        (Bundle.main.object(forInfoDictionaryKey: "ParleyPushEnabled") as? String)?.uppercased() == "YES"

    /// The relay's name for the APNs environment this build's tokens belong
    /// to, from the embedded provisioning profile: `sandbox` for a
    /// development-signed build, `production` for one with no profile (App
    /// Store, TestFlight) or a distribution profile. The simulator is sandbox.
    static let relayEnvironment: String = {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
        return APSEnvironment.relayName(profile: profile)
        #endif
    }()

    /// A watched turn is dropped after this long: the relay gives up on a
    /// turn after 30 minutes.
    static let watchLimit: TimeInterval = 35 * 60

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var pushState: PushState = Notifier.pushEnabledInBuild ? .notRegistered : .offInThisBuild
    /// The conversation on screen: its notifications are not shown as banners.
    var visibleConversationID: String?

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var deviceToken: String?
    @ObservationIgnored private var registeredFor: String?
    /// Unfinished turns the app has seen, by turn id.
    @ObservationIgnored private var watched: [String: (conversationID: String, since: Date)] = [:]
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

    /// Send the device token to the relay, once per relay and sign-in, and
    /// keep the device id the relay answers for that relay.
    func registerWithRelay() async {
        guard Self.pushEnabledInBuild, let token = deviceToken, let model, let client = model.client else { return }
        let key = model.connectionKey + "|" + token
        if registeredFor == key { return }
        pushState = .registering
        do {
            let device = try await client.registerDevice(token: token, environment: Self.relayEnvironment)
            DeviceIDs.set(device.id, for: model.relayURLString)
            registeredFor = key
            pushState = .registered(relayCanPush: device.push ?? true)
        } catch {
            pushState = .failed(error.localizedDescription)
        }
    }

    /// Stop pushes from a relay: delete this phone's device there (with that
    /// relay's client, so before its credentials go). Best effort.
    func unregister(from relay: String, using client: RelayClient?) async {
        guard let id = DeviceIDs.get(relay) else { return }
        if let client, (try? await client.unregisterDevice(id: id)) == nil { return }  // keep the id to retry
        DeviceIDs.set(nil, for: relay)
        registeredFor = nil
        if Self.pushEnabledInBuild { pushState = .notRegistered }
    }

    /// The relay or the sign-in changed: what was watched belongs to the old one.
    func connectionChanged() {
        watched.removeAll()
        endBackgroundWork()
    }

    func presentationOptions(for route: NotificationRoute?) -> UNNotificationPresentationOptions {
        if let route, route.conversationID == visibleConversationID { return [] }
        return [.banner, .list, .sound]
    }

    // MARK: Local notifications

    /// Every turn the app sees comes through here.
    func observe(_ turn: ParleyKit.Turn) {
        pruneWatched()
        guard turn.state.isFinished else {
            if watched[turn.id] == nil { watched[turn.id] = (turn.conversationId, Date()) }
            return
        }
        guard watched.removeValue(forKey: turn.id) != nil, turn.state == .ready,
              UIApplication.shared.applicationState != .active, !pushWillNotify, isAllowed else { return }
        let content = UNMutableNotificationContent()
        content.body = "Reply ready"
        content.sound = .default
        content.userInfo = ["conversation_id": turn.conversationId, "turn_id": turn.id]
        let request = UNNotificationRequest(identifier: "turn-\(turn.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// The relay will push this turn itself: no local notification as well.
    private var pushWillNotify: Bool { pushState == .registered(relayCanPush: true) }

    private func pruneWatched() {
        let cutoff = Date().addingTimeInterval(-Self.watchLimit)
        watched = watched.filter { $0.value.since > cutoff }
    }

    func enteredBackground() {
        pruneWatched()
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
                self.pruneWatched()
                for (turnID, entry) in self.watched {
                    if let turn = try? await client.turn(conversationID: entry.conversationID, turnID: turnID) {
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

/// The device id each relay gave this phone, by relay URL (UserDefaults).
enum DeviceIDs {
    private static let key = "pushDeviceIDs"

    static func get(_ relay: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[relay]
    }

    static func set(_ id: String?, for relay: String) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[relay] = id
        UserDefaults.standard.set(all, forKey: key)
    }
}
