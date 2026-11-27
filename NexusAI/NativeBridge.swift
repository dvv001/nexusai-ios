import Foundation
import EventKit
import UserNotifications
import AVFoundation

/// Native capability bridge for the bundled web app (handler name "nativeBridge").
///
/// Fixed contract with js/native.js:
///   request  { "api": "calendar"|"reminders"|"notify"|"speak",
///              "action": String, "params": { ... } }
///   success  reply value { "ok": true,  "data": ... }
///   failure  reply value { "ok": false, "error": "<message>" }
/// Malformed payloads reply with an error string instead (promise rejects).
/// Permissions are requested lazily on first use of each API; a denial
/// replies { "ok": false, "error": "permission_denied" }.
final class NativeBridge {
    private let eventStore = EKEventStore()
    private let synthesizer = AVSpeechSynthesizer()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Entry point

    func handle(body: [String: Any], replyHandler: @escaping (Any?, String?) -> Void) {
        guard let api = body["api"] as? String,
              let action = body["action"] as? String else {
            replyHandler(nil, "invalid native bridge payload")
            return
        }
        let params = body["params"] as? [String: Any] ?? [:]

        switch (api, action) {
        case ("calendar", "today"):
            calendarToday(replyHandler)
        case ("calendar", "create"):
            calendarCreate(params: params, replyHandler)
        case ("reminders", "list"):
            remindersList(replyHandler)
        case ("reminders", "create"):
            remindersCreate(params: params, replyHandler)
        case ("notify", "now"):
            notify(title: params["title"] as? String,
                   body: params["body"] as? String,
                   delay: 1,
                   replyHandler)
        case ("notify", "schedule"):
            let delay = (params["delaySeconds"] as? NSNumber)?.doubleValue ?? 0
            notify(title: params["title"] as? String,
                   body: params["body"] as? String,
                   delay: delay,
                   replyHandler)
        case ("speak", "say"):
            speak(text: params["text"] as? String,
                  lang: params["lang"] as? String,
                  replyHandler)
        default:
            replyFail(replyHandler, "unsupported: \(api)/\(action)")
        }
    }

    // MARK: - Reply helpers

    private func replyOK(_ replyHandler: @escaping (Any?, String?) -> Void, _ data: Any) {
        replyHandler(["ok": true, "data": data], nil)
    }

    private func replyFail(_ replyHandler: @escaping (Any?, String?) -> Void, _ message: String) {
        replyHandler(["ok": false, "error": message], nil)
    }

    // MARK: - Permissions (lazy, per API)

    private func ensureEventsAccess(_ completion: @escaping (Bool) -> Void) {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            completion(true)
        case .notDetermined:
            if #available(iOS 17, *) {
                eventStore.requestFullAccessToEvents { granted, _ in completion(granted) }
            } else {
                eventStore.requestAccess(to: .event) { granted, _ in completion(granted) }
            }
        default:
            completion(false)
        }
    }

    private func ensureRemindersAccess(_ completion: @escaping (Bool) -> Void) {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            completion(true)
        case .notDetermined:
            if #available(iOS 17, *) {
                eventStore.requestFullAccessToReminders { granted, _ in completion(granted) }
            } else {
                eventStore.requestAccess(to: .reminder) { granted, _ in completion(granted) }
            }
        default:
            completion(false)
        }
    }

    private func ensureNotifyAccess(_ completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                completion(true)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    completion(granted)
                }
            default:
                completion(false)
            }
        }
    }

    // MARK: - Calendar

    private func calendarToday(_ replyHandler: @escaping (Any?, String?) -> Void) {
        ensureEventsAccess { [self] granted in
            guard granted else {
                replyFail(replyHandler, "permission_denied")
                return
            }
            let cal = Calendar.current
            let start = cal.startOfDay(for: Date())
            let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = eventStore.events(matching: predicate)
                .sorted { $0.startDate < $1.startDate }
            let data: [[String: Any]] = events.map { ev in
                var item: [String: Any] = [
                    "title": ev.title ?? "",
                    "startISO": Self.isoFormatter.string(from: ev.startDate),
                    "endISO": Self.isoFormatter.string(from: ev.endDate),
                    "allDay": ev.isAllDay
                ]
                if let location = ev.location, !location.isEmpty {
                    item["location"] = location
                } else {
                    item["location"] = NSNull()
                }
                return item
            }
            replyOK(replyHandler, data)
        }
    }

    private func calendarCreate(params: [String: Any],
                                _ replyHandler: @escaping (Any?, String?) -> Void) {
        guard let title = params["title"] as? String, !title.isEmpty,
              let start = Self.parseISO(params["startISO"] as? String),
              let end = Self.parseISO(params["endISO"] as? String) else {
            replyFail(replyHandler, "invalid_params")
            return
        }
        ensureEventsAccess { [self] granted in
            guard granted else {
                replyFail(replyHandler, "permission_denied")
                return
            }
            let event = EKEvent(eventStore: eventStore)
            event.title = title
            event.startDate = start
            event.endDate = end
            if let notes = params["notes"] as? String { event.notes = notes }
            event.calendar = eventStore.defaultCalendarForNewEvents
            do {
                try eventStore.save(event, span: .thisEvent)
                replyOK(replyHandler, ["id": event.eventIdentifier ?? ""])
            } catch {
                replyFail(replyHandler, error.localizedDescription)
            }
        }
    }

    // MARK: - Reminders

    private func remindersList(_ replyHandler: @escaping (Any?, String?) -> Void) {
        ensureRemindersAccess { [self] granted in
            guard granted else {
                replyFail(replyHandler, "permission_denied")
                return
            }
            let predicate = eventStore.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: nil)
            eventStore.fetchReminders(matching: predicate) { [self] reminders in
                let items: [[String: Any]] = (reminders ?? []).prefix(100).map { reminder in
                    var item: [String: Any] = [
                        "id": reminder.calendarItemIdentifier,
                        "title": reminder.title ?? "",
                        "list": reminder.calendar?.title ?? ""
                    ]
                    if let due = reminder.dueDateComponents?.date {
                        item["dueISO"] = Self.isoFormatter.string(from: due)
                    } else {
                        item["dueISO"] = NSNull()
                    }
                    return item
                }
                replyOK(replyHandler, items)
            }
        }
    }

    private func remindersCreate(params: [String: Any],
                                 _ replyHandler: @escaping (Any?, String?) -> Void) {
        guard let title = params["title"] as? String, !title.isEmpty else {
            replyFail(replyHandler, "invalid_params")
            return
        }
        ensureRemindersAccess { [self] granted in
            guard granted else {
                replyFail(replyHandler, "permission_denied")
                return
            }
            guard let calendar = eventStore.defaultCalendarForNewReminders() else {
                replyFail(replyHandler, "no_reminder_calendar")
                return
            }
            let reminder = EKReminder(eventStore: eventStore)
            reminder.title = title
            reminder.calendar = calendar
            if let notes = params["notes"] as? String { reminder.notes = notes }
            if let due = Self.parseISO(params["dueISO"] as? String) {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: due)
            }
            do {
                try eventStore.save(reminder, commit: true)
                replyOK(replyHandler, ["id": reminder.calendarItemIdentifier])
            } catch {
                replyFail(replyHandler, error.localizedDescription)
            }
        }
    }

    // MARK: - Notifications

    private func notify(title: String?, body: String?, delay: TimeInterval,
                        _ replyHandler: @escaping (Any?, String?) -> Void) {
        guard let title = title, let body = body, delay > 0 else {
            replyFail(replyHandler, "invalid_params")
            return
        }
        ensureNotifyAccess { [self] granted in
            guard granted else {
                replyFail(replyHandler, "permission_denied")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request) { [self] error in
                if let error = error {
                    replyFail(replyHandler, error.localizedDescription)
                } else {
                    replyOK(replyHandler, ["scheduled": true])
                }
            }
        }
    }

    // MARK: - Speech

    private func speak(text: String?, lang: String?,
                       _ replyHandler: @escaping (Any?, String?) -> Void) {
        guard let text = text, !text.isEmpty else {
            replyFail(replyHandler, "invalid_params")
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: lang ?? "zh-CN")
        // AVSpeechSynthesizer is retained on self: a deallocated synthesizer
        // stops mid-utterance, so speak through the long-lived instance.
        DispatchQueue.main.async { [self] in
            // The default audio session (.soloAmbient) is muted by the
            // silent switch, which swallowed speech entirely (build 8 and
            // earlier: speak returned success but nothing was audible).
            // .playback ignores the silent switch; .spokenAudio is the
            // TTS-tuned mode; duckOthers lowers the run music meanwhile.
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio,
                                     options: [.duckOthers])
            try? session.setActive(true, options: [])
            synthesizer.speak(utterance)
        }
        replyOK(replyHandler, ["speaking": true])
    }

    // MARK: - Helpers

    private static func parseISO(_ string: String?) -> Date? {
        guard let string = string, !string.isEmpty else { return nil }
        return isoFormatter.date(from: string) ?? isoFractionalFormatter.date(from: string)
    }
}
