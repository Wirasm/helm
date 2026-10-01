import AppKit
import SwiftUI

struct BrowserFormPickerView: View {
    @ObservedObject var picker: BrowserFormPicker
    let page: () -> BrowserSurfaceView?

    var body: some View {
        if let pick = picker.current {
            VStack(alignment: .leading, spacing: 8) {
                switch pick.control {
                case let .select(options, _):
                    Text("Choose an option").font(.system(size: 12, weight: .semibold))
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(options, id: \.index) { option in
                                    optionRow(option)
                                }
                            }
                        }
                        .frame(maxHeight: 280)
                        .onChange(of: picker.highlighted) { _, index in proxy.scrollTo(index) }
                    }
                case let .date(value, min, max):
                    BrowserDatePicker(value: value, min: min, max: max) { date in
                        Task {
                            await picker.choose(date: date)
                            if picker.current == nil { returnKeyboard() }
                        }
                    } calendarPage: {
                        page()
                    }
                    .id(pick.id)
                }
                if let failure = picker.failure {
                    Text(failure).font(.system(size: 11)).foregroundStyle(Color.textMuted)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { cancel() }.buttonStyle(.chrome).focusable(false)
                }
            }
            .foregroundStyle(Color.textPrimary)
            .padding(12)
            .frame(width: 310)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.border))
            .padding(12)
            .onExitCommand { cancel() }
        }
    }

    private func optionRow(_ option: BrowserFormPicker.Option) -> some View {
        Button {
            Task {
                await picker.choose(index: option.index)
                if picker.current == nil { returnKeyboard() }
            }
        } label: {
            HStack {
                Image(systemName: option.index == picker.highlighted ? "checkmark" : "circle")
                    .frame(width: 14)
                Text(option.label).multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.chrome)
        .focusable(false)
        .foregroundStyle(option.disabled ? Color.textFaint : Color.textPrimary)
        .disabled(option.disabled)
        .id(option.index)
    }

    private func cancel() {
        picker.dismiss()
        returnKeyboard()
    }

    private func returnKeyboard() {
        guard let page = page(), let window = page.window else { return }
        let calendar = window.firstResponder as? BrowserCalendarControl
        guard
            window.firstResponder == nil || window.firstResponder === page
                || calendar?.page === page
        else { return }
        window.makeFirstResponder(page)
    }
}

private struct BrowserDatePicker: View {
    let min: String
    let max: String
    let choose: (String) -> Void
    let calendarPage: () -> BrowserSurfaceView?
    @State private var date: Date

    init(
        value: String, min: String, max: String, choose: @escaping (String) -> Void,
        calendarPage: @escaping () -> BrowserSurfaceView?
    ) {
        self.min = min
        self.max = max
        self.choose = choose
        self.calendarPage = calendarPage
        _date = State(initialValue: BrowserCivilDate.parse(value) ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a date").font(.system(size: 12, weight: .semibold))
            BrowserCalendar(date: $date, min: min, max: max, page: calendarPage)
                .fixedSize()
            HStack {
                Button("Clear") { choose("") }.buttonStyle(.chrome).focusable(false)
                Spacer()
                Button("Apply") { choose(BrowserCivilDate.string(date)) }.buttonStyle(.chrome)
                    .focusable(false)
            }
        }
    }
}

/// An inline AppKit calendar: no separate panel to activate, and no invisible browser popup.
private struct BrowserCalendar: NSViewRepresentable {
    @Binding var date: Date
    let min: String
    let max: String
    let page: () -> BrowserSurfaceView?

    func makeNSView(context: Context) -> BrowserCalendarControl {
        let view = BrowserCalendarControl()
        view.datePickerStyle = .clockAndCalendar
        view.datePickerElements = .yearMonthDay
        view.backgroundColor = NSColor(Color.surfaceRaised)
        view.textColor = NSColor(Color.textPrimary)
        view.calendar = BrowserCivilDate.calendar
        view.timeZone = BrowserCivilDate.calendar.timeZone
        view.target = context.coordinator
        view.action = #selector(Coordinator.changed(_:))
        return view
    }

    func updateNSView(_ view: BrowserCalendarControl, context: Context) {
        context.coordinator.date = $date
        view.minDate = BrowserCivilDate.parse(min)
        view.maxDate = BrowserCivilDate.parse(max)
        view.dateValue = date
        view.page = page()
    }

    func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

    final class Coordinator: NSObject {
        var date: Binding<Date>
        init(date: Binding<Date>) { self.date = date }
        @objc func changed(_ sender: NSDatePicker) { date.wrappedValue = sender.dateValue }
    }
}

private final class BrowserCalendarControl: NSDatePicker {
    weak var page: BrowserSurfaceView?
}

/// HTML dates are Gregorian civil dates. The calendar and formatter share the Mac's time
/// zone so a chosen day round-trips as that day, and the calendar's Today is the local day.
enum BrowserCivilDate {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func parse(_ value: String) -> Date? {
        guard let date = formatter.date(from: value), string(date) == value else { return nil }
        return date
    }

    static func string(_ date: Date) -> String { formatter.string(from: date) }
}
