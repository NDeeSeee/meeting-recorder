// calquery <YYYY-MM-DD> <HH-MM> <duration_seconds>
// Finds the macOS Calendar event that best overlaps the recording window and
// prints it as JSON on stdout. Exit 2 == Calendar access not granted.
import Foundation
import EventKit

let a = CommandLine.arguments
guard a.count >= 4, let dur = Double(a[3]) else {
    FileHandle.standardError.write("usage: calquery <YYYY-MM-DD> <HH-MM> <duration_seconds>\n".data(using: .utf8)!)
    exit(64)
}

let df = DateFormatter()
df.locale = Locale(identifier: "en_US_POSIX")
df.timeZone = TimeZone.current            // recording folder names are local time
df.dateFormat = "yyyy-MM-dd HH-mm"
guard let recStart = df.date(from: "\(a[1]) \(a[2])") else {
    FileHandle.standardError.write("calquery: unparseable start '\(a[1]) \(a[2])'\n".data(using: .utf8)!)
    exit(64)
}
let recEnd = recStart.addingTimeInterval(dur)

let store = EKEventStore()

func haveAccess() -> String? {   // nil == access OK, else a human-readable reason
    let st = EKEventStore.authorizationStatus(for: .event)
    if #available(macOS 14.0, *) {
        if st == .fullAccess { return nil }
        if st == .writeOnly { return "Calendar access is write-only (full access required to read events)" }
    } else {
        if st == .authorized { return nil }
    }
    if st == .denied { return "Calendar access was explicitly denied for this process" }
    if st == .restricted { return "Calendar access is restricted by policy (MDM / parental controls)" }

    // .notDetermined — ask. A non-GUI / background process usually gets refused
    // outright or never answers; don't hang the pipeline on it.
    var granted = false
    let sem = DispatchSemaphore(value: 0)
    if #available(macOS 14.0, *) {
        store.requestFullAccessToEvents { ok, _ in granted = ok; sem.signal() }
    } else {
        store.requestAccess(to: .event) { ok, _ in granted = ok; sem.signal() }
    }
    if sem.wait(timeout: .now() + 20) == .timedOut {
        return "Calendar access request timed out (no one can answer the prompt from a background process)"
    }
    if granted { return nil }
    return "Calendar access request was refused (status was 'not determined'; a background/non-GUI process cannot raise the permission prompt)"
}

if let reason = haveAccess() {
    FileHandle.standardError.write("\(reason)\n".data(using: .utf8)!)
    exit(2)
}

let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime]
iso.timeZone = TimeZone.current

func email(_ p: EKParticipant?) -> String? {
    guard let u = p?.url else { return nil }
    let s = u.absoluteString
    return s.hasPrefix("mailto:") ? String(s.dropFirst(7)) : s
}
func person(_ p: EKParticipant?) -> [String: Any]? {
    guard let p = p else { return nil }
    var d: [String: Any] = [:]
    if let n = p.name, !n.isEmpty { d["name"] = n }
    if let e = email(p) { d["email"] = e }
    d["is_you"] = p.isCurrentUser
    switch p.participantStatus {
    case .accepted:  d["status"] = "accepted"
    case .declined:  d["status"] = "declined"
    case .tentative: d["status"] = "tentative"
    case .pending:   d["status"] = "pending"
    default:         d["status"] = "unknown"
    }
    if p.participantRole == .optional { d["optional"] = true }
    return d.isEmpty ? nil : d
}

// Widen the search a little: people join late, recordings start early.
let pad: TimeInterval = 3 * 3600
let pred = store.predicateForEvents(withStart: recStart.addingTimeInterval(-pad),
                                    end: recEnd.addingTimeInterval(pad),
                                    calendars: nil)
let candidates = store.events(matching: pred).filter { !$0.isAllDay && $0.status != .canceled }

func overlap(_ ev: EKEvent) -> TimeInterval {
    guard let s = ev.startDate, let e = ev.endDate else { return 0 }
    return max(0, min(e, recEnd).timeIntervalSince(max(s, recStart)))
}

// Best = most seconds overlapping the recording; tie-break on the event whose
// length is closest to the recording's length.
let scored = candidates.map { (ev: $0, ov: overlap($0)) }.filter { $0.ov > 0 }
let best = scored.max { l, r in
    if l.ov != r.ov { return l.ov < r.ov }
    func fit(_ e: EKEvent) -> TimeInterval {
        abs((e.endDate?.timeIntervalSince(e.startDate ?? recStart) ?? 0) - dur)
    }
    return fit(l.ev) > fit(r.ev)
}

var out: [String: Any] = [
    "recording_start": iso.string(from: recStart),
    "recording_end":   iso.string(from: recEnd),
    "recording_duration_seconds": Int(dur.rounded()),
    "candidates_considered": candidates.count,
    "source": "EventKit",
]

if let b = best, let evStart = b.ev.startDate {
    let ev = b.ev
    var attendees: [[String: Any]] = []
    for p in ev.attendees ?? [] { if let d = person(p) { attendees.append(d) } }
    out["matched"] = true
    out["title"] = ev.title ?? "(untitled)"
    out["start"] = iso.string(from: evStart)
    out["end"] = ev.endDate.map { iso.string(from: $0) } ?? NSNull()
    out["calendar"] = ev.calendar?.title ?? NSNull()
    out["event_id"] = ev.eventIdentifier ?? NSNull()
    out["organizer"] = person(ev.organizer) ?? NSNull()
    out["attendees"] = attendees
    out["attendee_count"] = attendees.count
    out["location"] = (ev.location?.isEmpty == false) ? ev.location! : NSNull()
    out["url"] = ev.url?.absoluteString ?? NSNull()
    out["notes"] = (ev.notes?.isEmpty == false) ? ev.notes! : NSNull()
    out["overlap_seconds"] = Int(b.ov.rounded())
    out["overlap_fraction_of_recording"] = dur > 0 ? (b.ov / dur * 1000).rounded() / 1000 : 0
} else {
    out["matched"] = false
    out["reason"] = candidates.isEmpty
        ? "no calendar events near the recording window"
        : "no calendar event overlaps the recording window"
}

let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write("\n".data(using: .utf8)!)
